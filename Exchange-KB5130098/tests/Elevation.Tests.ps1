BeforeDiscovery {
    $script:packageRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:packageRoot 'KB5130098.psm1') -Force
}

Describe 'Consent-based local elevation boundaries' {
    InModuleScope KB5130098 {
        BeforeEach {
            $script:context = [pscustomobject]@{
                Administrator = $false
                Is64BitProcess = $true
                Is64BitOS = $true
                WindowsPowerShell51 = $true
                Remote = $false
                Interactive = $true
            }
            Mock Get-KBElevationContext { $script:context }
            Mock Test-Path { $true }
            Mock Get-Location { [pscustomobject]@{ Provider = [pscustomobject]@{ Name = 'FileSystem' }; ProviderPath = 'C:\Staging with spaces' } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        }

        It 'does not relaunch an already elevated 64-bit Windows PowerShell process' {
            $script:context.Administrator = $true
            $script:context.Remote = $true
            $script:context.Interactive = $false
            $result = Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} -AsJson
            $result | Should -BeNullOrEmpty
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'uses standard RunAs and waits without changing execution policy' {
            $null = Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{ Mode = 'Detect' }
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $Verb -eq 'RunAs' -and $Wait -and $PassThru -and
                $FilePath -like '*\System32\WindowsPowerShell\v1.0\powershell.exe' -and
                $ArgumentList -like '-NoLogo -NoProfile -EncodedCommand *' -and
                $ArgumentList -notmatch 'ExecutionPolicy|Bypass'
            }
        }

        It 'returns the exact elevated process exit code <Code>' -ForEach @(
            @{ Code = 0 }, @{ Code = 1 }, @{ Code = 10 }, @{ Code = 20 }
        ) {
            Mock Start-Process { [pscustomobject]@{ ExitCode = $Code } }
            (Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{}).ExitCode | Should -Be $Code
        }

        It 'uses Sysnative when relaunching from a 32-bit process' {
            $script:context.Is64BitProcess = $false
            $null = Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{}
            Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -like '*\Sysnative\WindowsPowerShell\v1.0\powershell.exe' }
        }

        It 'refuses JSON capture without an already elevated process' {
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} -AsJson } | Should -Throw '*-AsJson*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'honors the explicit no-elevation flag and prevents a child retry loop' {
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} -NoAutoElevate } | Should -Throw '*-NoAutoElevate*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'refuses automatic elevation inside a pipeline' {
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} -InPipeline } | Should -Throw '*pipelines*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'does not show a UAC prompt from a remote or noninteractive context' {
            $script:context.Remote = $true
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} } | Should -Throw '*remoting*'
            $script:context.Remote = $false
            $script:context.Interactive = $false
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} } | Should -Throw '*noninteractive*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'fails explicitly if Windows cannot supply a 64-bit host' {
            $script:context.Is64BitOS = $false
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} } | Should -Throw '*64-bit Windows*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'reports cancelled UAC rather than returning success or retrying' {
            Mock Start-Process { throw (New-Object ComponentModel.Win32Exception 1223) }
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} } | Should -Throw '*declined or could not be started*'
            Should -Invoke Start-Process -Times 1 -Exactly
        }

        It 'refuses to infer success from an unknown child exit code' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = $null } }
            { Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{} } | Should -Throw '*did not return an exit code*'
        }

        It 'does not let inherited WhatIf suppress the launch of the read-only child preview' {
            Mock Start-Process {
                $script:launchPreferences = @([bool]$WhatIfPreference, [string]$ConfirmPreference)
                [pscustomobject]@{ ExitCode = 0 }
            }
            $WhatIfPreference = $true
            $null = Invoke-KBAutoElevation -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' -BoundParameters @{
                Mode = 'Apply'; WhatIf = [System.Management.Automation.SwitchParameter]$true
            }
            Should -Invoke Start-Process -Times 1 -Exactly
            $script:launchPreferences[0] | Should -BeFalse
            $script:launchPreferences[1] | Should -Be 'None'
        }

        It 'rejects values that cannot safely cross the process boundary' {
            { New-KBElevationCommand -ScriptPath 'C:\Kit\Invoke-KB5130098.ps1' `
                -BoundParameters @{ FutureParameter = [pscustomobject]@{ Value = 'not a scalar' } } `
                -WorkingDirectory 'C:\Kit' } | Should -Throw '*cannot be forwarded safely*'
        }
    }
}

Describe 'Native elevation bootstrap parameter and exit-code fidelity' {
    BeforeAll {
        $script:fixtureRoot = Join-Path $TestDrive "Elevation fixture O'Brien"
        $null = New-Item -Path $script:fixtureRoot -ItemType Directory
        $script:child = Join-Path $script:fixtureRoot 'child.ps1'
        @'
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Mode, [string]$PayloadDirectory, [string]$ReceiptPath,
    [switch]$RestartSearch, [switch]$MaintenanceWindowApproved,
    [switch]$MicrosoftSupportApprovedRollback, [switch]$NoAutoElevate,
    [int]$TimeoutSeconds, [int]$StabilitySeconds, [int]$TestExit
)
[pscustomobject]@{
    Mode = $Mode
    PayloadDirectory = $PayloadDirectory
    ReceiptPath = $ReceiptPath
    RestartSearch = $RestartSearch.IsPresent
    MaintenanceWindowApproved = $MaintenanceWindowApproved.IsPresent
    MicrosoftSupportApprovedRollback = $MicrosoftSupportApprovedRollback.IsPresent
    NoAutoElevate = $NoAutoElevate.IsPresent
    WhatIf = [bool]$WhatIfPreference
    Confirm = [bool]$PSBoundParameters['Confirm']
    ConfirmationPreference = [string]$ConfirmPreference
    TimeoutSeconds = $TimeoutSeconds
    StabilitySeconds = $StabilitySeconds
    WorkingDirectory = (Get-Location).ProviderPath
} | ConvertTo-Json
exit $TestExit
'@ | Set-Content -LiteralPath $script:child -Encoding ASCII
    }

    It 'can inspect the real process context without requiring elevation' {
        $context = & (Get-Module KB5130098) { Get-KBElevationContext }
        $context.Administrator | Should -BeOfType bool
        $context.Interactive | Should -BeOfType bool
        $context.Remote | Should -BeOfType bool
        $context.Is64BitOS | Should -BeTrue
    }

    It 'preserves data and native exit <Code> with inherited preferences <Inherited>' -ForEach @(
        @{ Code = 0; Inherited = $false }, @{ Code = 1; Inherited = $false },
        @{ Code = 10; Inherited = $false }, @{ Code = 20; Inherited = $false },
        @{ Code = 0; Inherited = $true }
    ) {
        $marker = Join-Path $TestDrive 'must-not-be-created'
        $payload = "C:\rules O'Brien\`$(New-Item '$marker')\trailing\"
        $bound = @{
            Mode = 'Rollback'
            PayloadDirectory = $payload
            ReceiptPath = "C:\receipt O'Brien;data.json"
            RestartSearch = [System.Management.Automation.SwitchParameter]$false
            MaintenanceWindowApproved = [System.Management.Automation.SwitchParameter]$true
            MicrosoftSupportApprovedRollback = [System.Management.Automation.SwitchParameter]$true
            Confirm = [System.Management.Automation.SwitchParameter]$false
            WhatIf = [System.Management.Automation.SwitchParameter]$true
            NoAutoElevate = [System.Management.Automation.SwitchParameter]$false
            TimeoutSeconds = 177
            StabilitySeconds = 43
            TestExit = $Code
        }
        if ($Inherited) {
            $bound.Remove('WhatIf')
            $bound.Remove('Confirm')
        }
        $encoded = & (Get-Module KB5130098) {
            param($Path, $Bound, $Working)
            New-KBElevationCommand -ScriptPath $Path -BoundParameters $Bound -WorkingDirectory $Working `
                -WaitForUser:$false -PreviewPreference $true -ConfirmationPreference None
        } $script:child $bound $script:fixtureRoot
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill()
                throw 'Native bootstrap fixture timed out.'
            }
            $process.ExitCode | Should -Be $Code
            $stderr.Result | Should -BeNullOrEmpty
            $result = $stdout.Result | ConvertFrom-Json
            $result.Mode | Should -Be 'Rollback'
            $result.PayloadDirectory | Should -Be $payload
            $result.ReceiptPath | Should -Be $bound.ReceiptPath
            $result.WorkingDirectory | Should -Be $script:fixtureRoot
            $result.RestartSearch | Should -BeFalse
            $result.Confirm | Should -BeFalse
            $result.ConfirmationPreference | Should -Be 'None'
            $result.WhatIf | Should -BeTrue
            $result.MaintenanceWindowApproved | Should -BeTrue
            $result.MicrosoftSupportApprovedRollback | Should -BeTrue
            $result.NoAutoElevate | Should -BeTrue
            $result.TimeoutSeconds | Should -Be 177
            $result.StabilitySeconds | Should -Be 43
            Test-Path -LiteralPath $marker | Should -BeFalse
        } finally { $process.Dispose() }
    }
}
