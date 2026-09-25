BeforeAll {
    $script:packageRoot = Split-Path $PSScriptRoot -Parent
    $script:nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:fixtureRoot = Join-Path $TestDrive 'Native entry point fixture'
    $null = New-Item -Path $script:fixtureRoot -ItemType Directory
    Copy-Item -LiteralPath (Join-Path $script:packageRoot 'Invoke-KB5130098.ps1') -Destination $script:fixtureRoot
    @'
function Invoke-KBLocal {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Mode, [string]$PayloadDirectory, [string]$StateRoot,
        [string]$ReceiptPath, [switch]$RestartSearch,
        [switch]$MaintenanceWindowApproved, [switch]$MicrosoftSupportApprovedRollback,
        [int]$TimeoutSeconds, [int]$StabilitySeconds
    )
    if ($env:KB5130098_TEST_STATUS -eq 'Throw') { throw 'Native fixture failure.' }
    [pscustomobject]@{
        Status = $env:KB5130098_TEST_STATUS
        Mode = $Mode
        PayloadDirectory = $PayloadDirectory
        StateRoot = $StateRoot
        ReceiptPath = $ReceiptPath
        RestartSearch = $RestartSearch.IsPresent
        WhatIf = [bool]$WhatIfPreference
        Confirm = [bool]$PSBoundParameters['Confirm']
        PowerShellMajor = $PSVersionTable.PSVersion.Major
        PowerShellMinor = $PSVersionTable.PSVersion.Minor
    }
}
Export-ModuleMember -Function Invoke-KBLocal
'@ | Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'KB5130098.psm1') -Encoding ASCII

    function Invoke-NativeFixture {
        param([string]$Arguments, [string]$Status = 'EligibleMissingBothRules', [string]$WorkingDirectory = $script:fixtureRoot)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $script:nativePowerShell
        $start.Arguments = '-NoProfile -NonInteractive ' + $Arguments
        $start.WorkingDirectory = $WorkingDirectory
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['KB5130098_TEST_STATUS'] = $Status
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill()
                throw 'Native fixture child process timed out.'
            }
            [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output = $stdout.Result
                Error = $stderr.Result
            }
        } finally {
            $process.Dispose()
        }
    }
}

Describe 'Native Windows PowerShell 5.1 entry points' {
    It 'resolves omitted payload paths under -File even when the working directory differs' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -Mode Detect' -f $path) -WorkingDirectory $TestDrive
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $json = $result.Output | ConvertFrom-Json
        $json.PayloadDirectory | Should -Be (Join-Path $script:fixtureRoot 'payload')
        $json.StateRoot | Should -Be (Join-Path $env:ProgramData 'Exchange-KB5130098')
        $json.PowerShellMajor | Should -Be 5
        $json.PowerShellMinor | Should -Be 1
    }

    It 'preserves an explicitly supplied payload and state path with spaces' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $payload = Join-Path $TestDrive 'Chosen payload'
        $state = Join-Path $TestDrive 'Chosen state'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -PayloadDirectory "{1}" -StateRoot "{2}"' -f $path, $payload, $state)
        $result.ExitCode | Should -Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.PayloadDirectory | Should -Be $payload
        $json.StateRoot | Should -Be $state
    }

    It 'does not replace an explicitly empty payload override with a success-shaped default' {
        $command = '& ''{0}'' -PayloadDirectory ''''; exit $LASTEXITCODE' -f (Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1')
        $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
        $result.ExitCode | Should -Be 0
        ($result.Output | ConvertFrom-Json).PayloadDirectory | Should -BeNullOrEmpty
    }

    It 'returns native exit <Code> and JSON for <Status>' -ForEach @(
        @{ Status = 'EligibleMissingBothRules'; Code = 0 }
        @{ Status = 'NoChanges'; Code = 0 }
        @{ Status = 'RestartedWorkloadValidationRequired'; Code = 0 }
        @{ Status = 'FilesStagedRestartRequired'; Code = 10 }
        @{ Status = 'RolledBackRestartRequired'; Code = 10 }
        @{ Status = 'NotApplicableStop'; Code = 20 }
        @{ Status = 'RuleFilesPresentStop'; Code = 20 }
    ) {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}"' -f $path) -Status $Status
        $result.ExitCode | Should -Be $Code
        $result.Error | Should -BeNullOrEmpty
        ($result.Output | ConvertFrom-Json).Status | Should -Be $Status
    }

    It 'writes an explicit error and exits 1 rather than returning success JSON' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}"' -f $path) -Status Throw
        $result.ExitCode | Should -Be 1
        $result.Output | Should -BeNullOrEmpty
        $result.Error | Should -Match 'Native fixture failure'
    }

    It 'forwards native WhatIf to the module' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -Mode Apply -WhatIf' -f $path) -Status NoChanges
        $result.ExitCode | Should -Be 0
        ($result.Output | ConvertFrom-Json).WhatIf | Should -BeTrue
    }

    It 'preserves exit <Code> in the exact README deployment-agent command' -ForEach @(
        @{ Status = 'FilesStagedRestartRequired'; Code = 10 }
        @{ Status = 'NotApplicableStop'; Code = 20 }
    ) {
        $line = @(Get-Content -LiteralPath (Join-Path $script:packageRoot 'README.txt') |
            Where-Object { $_ -match '^\s+powershell\.exe -NoProfile -NonInteractive -Command ' })[0]
        $arguments = $line.Trim() -replace '^powershell\.exe -NoProfile -NonInteractive ', ''
        $result = Invoke-NativeFixture -Arguments $arguments -Status $Status
        $result.ExitCode | Should -Be $Code
        $result.Error | Should -BeNullOrEmpty
        $json = $result.Output | ConvertFrom-Json
        $json.Mode | Should -Be 'Apply'
        $json.Confirm | Should -BeFalse
        $json.RestartSearch | Should -BeFalse
    }

    It 'resolves fleet package defaults under -File WhatIf without connecting or writing reports' {
        $report = Join-Path $TestDrive 'No fleet report should be created'
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1'
        $result = Invoke-NativeFixture -Arguments (
            '-File "{0}" -Mode Detect -ComputerName example.invalid -ReportDirectory "{1}" -WhatIf' -f $path, $report)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $result.Output | Should -Match 'What if:'
        Test-Path -LiteralPath $report | Should -BeFalse
    }

    It 'does not discard an explicitly supplied invalid fleet package path' {
        $report = Join-Path $TestDrive 'No invalid fleet report'
        $missing = Join-Path $TestDrive 'Nonexistent package'
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1'
        $result = Invoke-NativeFixture -Arguments (
            '-File "{0}" -ComputerName example.invalid -PackageDirectory "{1}" -ReportDirectory "{2}" -WhatIf' -f $path, $missing, $report)
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'Missing package file'
        Test-Path -LiteralPath $report | Should -BeFalse
    }
}
