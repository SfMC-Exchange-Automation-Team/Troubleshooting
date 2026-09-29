BeforeAll {
    $script:packageRoot = Split-Path $PSScriptRoot -Parent
    $script:nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:fixtureRoot = Join-Path $TestDrive 'Native entry point fixture'
    $null = New-Item -Path $script:fixtureRoot -ItemType Directory
    Copy-Item -LiteralPath (Join-Path $script:packageRoot 'Invoke-KB5130098.ps1') -Destination $script:fixtureRoot
    Copy-Item -LiteralPath (Join-Path $script:packageRoot 'KB5130098.psd1') -Destination $script:fixtureRoot
    $fixtureModule = @'
$script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'KB5130098.psd1')
$script:fixtureRules = @()
$script:elevationCalls = 0
$script:localCalls = 0
if ($env:KB5130098_TEST_STATUS -eq 'RuleFilesPresentStop' -or $env:KB5130098_TEST_STATUS -like 'RolledBack*') {
    $script:fixtureRules = @('ko.token.rule.bin', 'ko.complex.rule.bin')
}
function Invoke-KBAutoElevation {
    param($ScriptPath, $BoundParameters, [switch]$NoAutoElevate, [switch]$AsJson, [switch]$InPipeline,
        [bool]$PreviewPreference, [string]$ConfirmationPreference)
    $script:elevationPreview = $PreviewPreference
    $script:elevationConfirm = $ConfirmationPreference
    $script:elevationCalls++
    if ($env:KB5130098_TEST_RELAY -eq '1') {
        [pscustomobject]@{
            ExitCode=20
            ReportData=@([pscustomobject]@{ ComputerName='ELEVATED-FIXTURE'; Mode='Detect'; Status='RuleFilesPresentStop'; ActionTaken='Fixture handoff'; LocalCalls=$script:localCalls })
            ExportFiles=$null
        }
    }
}
function New-KBReportContext {
    param([string]$ReportDirectory, [switch]$NoWrite)
    $root = Join-Path $PSScriptRoot 'fixture-reports'
    $id = [guid]::NewGuid().ToString('N')
    $directory = Join-Path $root $id
    if (-not $NoWrite) { $null = New-Item -Path $directory -ItemType Directory -Force }
    [pscustomobject]@{ Root=$root; RunId=$id; Directory=$directory; JsonPath=Join-Path $directory 'rollout.json'; NoWrite=$NoWrite.IsPresent }
}
function Invoke-KBFleet {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$ComputerName, [string]$CsvPath, [string]$Mode,
        [string]$PackageDirectory, [string]$PayloadDirectory, [string]$ReportDirectory,
        [switch]$RestartSearch, [switch]$MaintenanceWindowApproved, [switch]$Quiet, [switch]$NoCsv,
        [int]$TimeoutSeconds, [int]$StabilitySeconds
    )
    $code = 0
    $status = 'Completed'
    if ($Mode -eq 'Apply' -and -not $RestartSearch) { $code=10; $status='FilesStagedRestartRequired' }
    [pscustomobject]@{
        Status=$status; ExitCode=$code; Mode=$Mode; Report='C:\Fixture\rollout.json'
        Servers=0; TargetCount=@($ComputerName).Count; ComputerName=$ComputerName; CsvPath=$CsvPath
        PackageDirectory=$PackageDirectory; PayloadDirectory=$PayloadDirectory
        ReportDirectorySupplied=$PSBoundParameters.ContainsKey('ReportDirectory'); ReportDirectoryValue=$ReportDirectory
        RestartSearch=$RestartSearch.IsPresent; MaintenanceWindowApproved=$MaintenanceWindowApproved.IsPresent
        Quiet=$Quiet.IsPresent; WhatIf=[bool]$WhatIfPreference
        ElevationCalls=$script:elevationCalls; LocalCalls=$script:localCalls
        ReportData=@($ComputerName | ForEach-Object { [pscustomobject]@{ComputerName=$_; Mode=$Mode; Status=$status; ActionTaken='Fixture only'} })
        ExportFiles=$null
    }
}
function Invoke-KBLocal {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Mode, [string]$PayloadDirectory, [string]$StateRoot,
        [string]$ReceiptPath, [switch]$RestartSearch,
        [switch]$MaintenanceWindowApproved, [switch]$MicrosoftSupportApprovedRollback,
        [int]$TimeoutSeconds, [int]$StabilitySeconds
    )
    $script:localCalls++
    $status = $env:KB5130098_TEST_STATUS
    if ($status -eq 'Throw') { throw 'Native fixture failure.' }
    if ($env:KB5130098_TEST_HUMAN -eq '1') {
        if ($Mode -eq 'Detect') {
            $status = 'EligibleMissingBothRules'
            if ($script:fixtureRules.Count -gt 0) { $status = 'RuleFilesPresentStop' }
            if ($env:KB5130098_TEST_STATUS -eq 'NotApplicableStop') { $status = 'NotApplicableStop' }
        } elseif ($WhatIfPreference) {
            $status = 'NoChanges'
        } elseif ($status -eq 'CopyFailed') {
            $script:fixtureRules = @('ko.token.rule.bin')
            $failure = New-Object IO.IOException 'Native fixture partial copy failure.'
            $failure.Data['KB5130098ReceiptPath'] = 'C:\Fixture\receipt.json'
            $failure.Data['KB5130098CreatedFiles'] = @('ko.token.rule.bin')
            throw $failure
        } elseif ($Mode -eq 'Apply' -and $status -ne 'NoChanges') {
            $script:fixtureRules = @('ko.token.rule.bin', 'ko.complex.rule.bin')
        } elseif ($Mode -eq 'Rollback') {
            $script:fixtureRules = @()
        }
    }
    [pscustomobject]@{
        Status = $status
        Mode = $Mode
        PayloadDirectory = $PayloadDirectory
        StateRoot = $StateRoot
        ReceiptPath = $(if ($env:KB5130098_TEST_HUMAN -eq '1' -and $Mode -ne 'Detect') { 'C:\Fixture\receipt.json' } else { $ReceiptPath })
        RestartSearch = $RestartSearch.IsPresent
        WhatIf = [bool]$WhatIfPreference
        Confirm = [bool]$PSBoundParameters['Confirm']
        PowerShellMajor = $PSVersionTable.PSVersion.Major
        PowerShellMinor = $PSVersionTable.PSVersion.Minor
        ComputerName = 'FIXTURE'
        ExchangeVersion = '15.2.2562.49'
        DllVersion = '16.0.5194.1000'
        ExistingRules = $script:fixtureRules
        ElevationPreviewPreference = $script:elevationPreview
        ElevationConfirmationPreference = $script:elevationConfirm
    }
}
'@
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:packageRoot 'KB5130098.psm1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Production module does not parse.' }
    $supportNames = @('Write-KBConsoleResult','Get-KBReportValue','ConvertTo-KBReportRows',
        'Write-KBFleetReport','Save-KBReportExports','Write-KBReportSummary')
    $support = foreach ($name in $supportNames) {
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $false)
        if ($null -eq $function) { throw "Production report helper was not found: $name" }
        $function.Extent.Text
    }
    ($fixtureModule + "`r`n" + ($support -join "`r`n") +
        "`r`nExport-ModuleMember -Function Invoke-KBLocal,Invoke-KBAutoElevation,Write-KBConsoleResult,Invoke-KBFleet,New-KBReportContext,ConvertTo-KBReportRows,Save-KBReportExports,Write-KBReportSummary") |
        Set-Content -LiteralPath (Join-Path $script:fixtureRoot 'KB5130098.psm1') -Encoding ASCII

    function Invoke-NativeFixture {
        param([string]$Arguments, [string]$Status = 'EligibleMissingBothRules',
            [string]$WorkingDirectory = $script:fixtureRoot, [switch]$Human)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $script:nativePowerShell
        $start.Arguments = '-NoProfile -NonInteractive ' + $Arguments
        $start.WorkingDirectory = $WorkingDirectory
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['KB5130098_TEST_STATUS'] = $Status
        $start.EnvironmentVariables['KB5130098_TEST_HUMAN'] = $(if ($Human) { '1' } else { '0' })
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
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -Mode Detect -AsJson' -f $path) -WorkingDirectory $TestDrive
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
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -PayloadDirectory "{1}" -StateRoot "{2}" -AsJson' -f $path, $payload, $state)
        $result.ExitCode | Should -Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.PayloadDirectory | Should -Be $payload
        $json.StateRoot | Should -Be $state
    }

    It 'does not replace an explicitly empty payload override with a success-shaped default' {
        $command = '& ''{0}'' -PayloadDirectory '''' -AsJson; exit $LASTEXITCODE' -f (Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1')
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
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -AsJson' -f $path) -Status $Status
        $result.ExitCode | Should -Be $Code
        $result.Error | Should -BeNullOrEmpty
        ($result.Output | ConvertFrom-Json).Status | Should -Be $Status
    }

    It 'writes an explicit error and exits 1 rather than returning success JSON' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -AsJson' -f $path) -Status Throw
        $result.ExitCode | Should -Be 1
        $result.Output | Should -BeNullOrEmpty
        $result.Error | Should -Match 'Native fixture failure'
    }

    It 'forwards native WhatIf to the module' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -Mode Apply -WhatIf -AsJson' -f $path) -Status NoChanges
        $result.ExitCode | Should -Be 0
        ($result.Output | ConvertFrom-Json).WhatIf | Should -BeTrue
    }

    It 'forwards inherited preview and confirmation preferences even without explicit switches' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $command = '$WhatIfPreference=$true; $ConfirmPreference=''None''; & ''{0}'' -Mode Apply -AsJson; exit $LASTEXITCODE' -f $path
        $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command) -Status NoChanges
        $result.ExitCode | Should -Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.ElevationPreviewPreference | Should -BeTrue
        $json.ElevationConfirmationPreference | Should -Be 'None'
        $json.WhatIf | Should -BeTrue
    }

    Describe 'Native human-readable status and Apply comparisons' {
        It 'makes a default Detect run unmistakably read-only' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1"' -Human
            $result.ExitCode | Should -Be 0
            $result.Error | Should -BeNullOrEmpty
            $result.Output | Should -Match 'CHECK\s+STATUS'
            $result.Output | Should -Not -Match '\bBEFORE\b|\bCURRENT\b'
            $result.Output | Should -Match 'ACTION TAKEN'
            $result.Output | Should -Match 'Checked eligibility only'
            $result.Output | Should -Match 'No files copied or removed\. No services restarted'
            $result.Output | Should -Match '(?m)^ko\.token\.rule\.bin\s+Missing\s*$'
            $result.Output | Should -Match 'NOT applied'
            $result.Output | Should -Not -Match '^\s*\{'
        }

        It 'shows a preview without claiming that files were copied or Search restarted' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -Mode Apply -RestartSearch -MaintenanceWindowApproved -WhatIf' -Human
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'CHECK\s+BEFORE\s+CURRENT'
            $result.Output | Should -Match 'Preview only'
            $result.Output | Should -Match 'ko\.complex\.rule\.bin\s+Missing\s+Missing'
            $result.Output | Should -Not -Match 'Restarted HostControllerService'
        }

        It 'shows staging as a real file change with restart still required' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -Mode Apply' `
                -Status FilesStagedRestartRequired -Human
            $result.ExitCode | Should -Be 10
            $result.Output | Should -Match 'ko\.token\.rule\.bin\s+Missing\s+Present'
            $result.Output | Should -Match 'Search was NOT restarted'
            $result.Output | Should -Match 'Do not rerun Apply'
            $result.Output | Should -Match 'Receipt: C:\\Fixture\\receipt\.json'
        }

        It 'reports a completed restart without claiming workload recovery' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -Mode Apply -RestartSearch -MaintenanceWindowApproved' `
                -Status RestartedWorkloadValidationRequired -Human
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'ko\.complex\.rule\.bin\s+Missing\s+Present'
            $result.Output | Should -Match 'Restarted HostControllerService'
            $result.Output | Should -Match 'Workload recovery is NOT yet proven'
        }

        It 'shows rollback resulting status without an Apply comparison and retains exit 10' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -Mode Rollback -MaintenanceWindowApproved -MicrosoftSupportApprovedRollback' `
                -Status RolledBackRestartRequired -Human
            $result.ExitCode | Should -Be 10
            $result.Output | Should -Match 'CHECK\s+STATUS'
            $result.Output | Should -Not -Match '\bBEFORE\b|\bCURRENT\b'
            $result.Output | Should -Match '(?m)^ko\.token\.rule\.bin\s+Missing\s*$'
            $result.Output | Should -Match 'Backed up and removed'
            $result.Output | Should -Match 'Search was NOT restarted'
        }

        It 'explains an existing-rule stop without presenting it as an Apply success' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1"' -Status RuleFilesPresentStop -Human
            $result.ExitCode | Should -Be 20
            $result.Output | Should -Match 'CHECK\s+STATUS'
            $result.Output | Should -Not -Match '\bBEFORE\b|\bCURRENT\b'
            $result.Output | Should -Match '(?m)^ko\.token\.rule\.bin\s+Present\s*$'
            $result.Output | Should -Match 'Existing rules were not overwritten'
            $result.Output | Should -Match 'Stop and reassess'
        }

        It 'reports a pinned-identity mismatch and returns 20' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1"' -Status NotApplicableStop -Human
            $result.ExitCode | Should -Be 20
            $result.Output | Should -Match '(?m)^Pinned build/DLL match\s+No - stop\s*$'
            $result.Output | Should -Match 'does not match the pinned requirements'
        }

        It 'shows partial failure, current files and receipt without implying a clean rollback' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -Mode Apply' -Status CopyFailed -Human
            $result.ExitCode | Should -Be 1
            $result.Error | Should -Match 'partial copy failure'
            $result.Output | Should -Match 'ko\.token\.rule\.bin\s+Missing\s+Present'
            $result.Output | Should -Match 'ko\.complex\.rule\.bin\s+Missing\s+Missing'
            $result.Output | Should -Match 'No successful completion'
            $result.Output | Should -Match 'Failure receipt records file creation: ko\.token\.rule\.bin'
            $result.Output | Should -Match 'C:\\Fixture\\receipt\.json'
        }
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

    Describe 'Caller report variable and default exports' {
        It 'publishes the elevated result into the original session without running the local operation again' {
            $command = '$env:KB5130098_TEST_RELAY=''1''; & ''.\Invoke-KB5130098.ps1''; $code=$LASTEXITCODE; ''HANDOFF:'' + (@($report) | ConvertTo-Json -Compress); exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
            $result.ExitCode | Should -Be 20
            $match = [regex]::Match($result.Output, '(?m)^HANDOFF:(.+)$')
            $match.Success | Should -BeTrue
            $rows = $match.Groups[1].Value | ConvertFrom-Json
            $rows[0].ComputerName | Should -Be 'ELEVATED-FIXTURE'
            $rows[0].Status | Should -Be 'RuleFilesPresentStop'
            $rows[0].LocalCalls | Should -Be 0
        }

        It 'retains typed rows and export paths in the invoking PowerShell scope' {
            $command = '& ''.\Invoke-KB5130098.ps1'' -AsJson | Out-Null; $code=$LASTEXITCODE; [pscustomobject]@{Rows=@($report);Files=$reportFiles;IsString=($report[0] -is [string])} | ConvertTo-Json -Depth 8; exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
            $result.ExitCode | Should -Be 0
            $capture = $result.Output | ConvertFrom-Json
            $capture.IsString | Should -BeFalse
            $capture.Rows.Count | Should -Be 1
            $capture.Rows[0].Status | Should -Be 'EligibleMissingBothRules'
            $capture.Rows[0].TokenRule | Should -Be 'Missing'
            Test-Path -LiteralPath $capture.Files.Json | Should -BeTrue
            Test-Path -LiteralPath $capture.Files.Csv | Should -BeTrue
            Test-Path -LiteralPath $capture.Files.JsonLines | Should -BeTrue
            @(Import-Csv -LiteralPath $capture.Files.Csv).Count | Should -Be 1
        }

        It 'prints the human report summary but does not replace objects with formatting data' {
            $command = '& ''.\Invoke-KB5130098.ps1''; $code=$LASTEXITCODE; ''CAPTURE:'' + (@($report) | ConvertTo-Json -Compress); exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command) -Human
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match '\$report contains 1 structured server result'
            $result.Output | Should -Match 'CSV:'
            $match = [regex]::Match($result.Output, '(?m)^CAPTURE:(.+)$')
            $match.Success | Should -BeTrue
            $captured = $match.Groups[1].Value | ConvertFrom-Json
            $captured[0].ComputerName | Should -Not -BeNullOrEmpty
            $captured[0].Status | Should -Be 'EligibleMissingBothRules'
            $captured[0].ActionTaken | Should -Be 'Detection only; no Exchange changes'
        }

        It 'supports explicit pipeline capture with PassThru' {
            $command = '$captured=@(& ''.\Invoke-KB5130098.ps1'' -PassThru 6>$null); $code=$LASTEXITCODE; [pscustomobject]@{Count=$captured.Count;Status=$captured[0].Status;IsFormatting=($captured[0].GetType().FullName -like ''*Internal.Format*'')} | ConvertTo-Json -Compress; exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command) -Human
            $result.ExitCode | Should -Be 0
            $data = ($result.Output.Trim() -split "`r?`n")[-1] | ConvertFrom-Json
            $data.Count | Should -Be 1
            $data.Status | Should -Be 'EligibleMissingBothRules'
            $data.IsFormatting | Should -BeFalse
        }

        It 'can omit CSV while retaining structured rows, detailed JSON and JSON Lines' {
            $command = '& ''.\Invoke-KB5130098.ps1'' -AsJson -NoCsv | Out-Null; $code=$LASTEXITCODE; $reportFiles | ConvertTo-Json; exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
            $result.ExitCode | Should -Be 0
            $files = $result.Output | ConvertFrom-Json
            $files.Csv | Should -BeNullOrEmpty
            Test-Path -LiteralPath $files.Json | Should -BeTrue
            Test-Path -LiteralPath $files.JsonLines | Should -BeTrue
        }

        It 'retains preview rows in memory without writing persistent reports' {
            $command = '& ''.\Invoke-KB5130098.ps1'' -Mode Apply -WhatIf -AsJson | Out-Null; $code=$LASTEXITCODE; [pscustomobject]@{Rows=@($report);Files=$reportFiles} | ConvertTo-Json -Depth 6; exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command) -Status NoChanges -Human
            $result.ExitCode | Should -Be 0
            $capture = $result.Output | ConvertFrom-Json
            $capture.Rows[0].Status | Should -Be 'NoChanges'
            $capture.Files.Json | Should -BeNullOrEmpty
            $capture.Files.Csv | Should -BeNullOrEmpty
            $capture.Files.JsonLines | Should -BeNullOrEmpty
        }

        It 'replaces stale caller results with the current failure and preserves native exit 1' {
            $command = '$report=''STALE''; & ''.\Invoke-KB5130098.ps1'' -AsJson | Out-Null; $code=$LASTEXITCODE; @($report) | ConvertTo-Json -Compress; exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command) -Status Throw
            $result.ExitCode | Should -Be 1
            $result.Error | Should -Match 'Native fixture failure'
            $rows = $result.Output | ConvertFrom-Json
            $rows[0].Status | Should -Be 'FailedStop'
            $rows[0].Error | Should -Match 'Native fixture failure'
            $rows[0].TokenRule | Should -Be 'Not observed'
        }

        It 'sets report for remote results without contaminating AsJson output' {
            $command = '& ''.\Invoke-KB5130098.ps1'' -ComputerName EX01,EX02 -AsJson | Out-Null; $code=$LASTEXITCODE; @($report) | ConvertTo-Json -Compress; exit $code'
            $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
            $result.ExitCode | Should -Be 0
            $rows = $result.Output | ConvertFrom-Json
            $rows.Count | Should -Be 2
            $rows.ComputerName | Should -Be @('EX01','EX02')
        }

        It 'refuses ambiguous JSON text and object output before executing the operation' {
            $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -AsJson -PassThru'
            $result.ExitCode | Should -Be 1
            $result.Output | Should -BeNullOrEmpty
            $result.Error | Should -Match 'Choose either'
        }
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

Describe 'Unified native local/remote/CSV dispatch' {
    It 'accepts the minimal one-server command without prompting for a report directory' {
        $result = Invoke-NativeFixture -Arguments '-File ".\Invoke-KB5130098.ps1" -ComputerName EX02'
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $result.Output | Should -Match 'Remote Detect: Completed'
        $result.Output | Should -Not -Match 'Supply values|ReportDirectory:'
    }

    It 'leaves an omitted report directory to the shared default for direct and CSV dispatch' -ForEach @(
        @{ TargetArguments = '-ComputerName EX02' }
        @{ TargetArguments = '-CsvPath "C:\Approved targets.csv"' }
    ) {
        $result = Invoke-NativeFixture -Arguments ('-File ".\Invoke-KB5130098.ps1" {0} -AsJson' -f $TargetArguments)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        ($result.Output | ConvertFrom-Json).ReportDirectorySupplied | Should -BeFalse
    }

    It 'preserves an explicit report-directory override rather than replacing it with the default' {
        $report = 'C:\Chosen reports\'
        $command = '& ''.\Invoke-KB5130098.ps1'' -ComputerName EX02 -ReportDirectory ''{0}'' -AsJson; exit $LASTEXITCODE' -f $report
        $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
        $result.ExitCode | Should -Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.ReportDirectorySupplied | Should -BeTrue
        $json.ReportDirectoryValue | Should -Be $report
    }

    It 'does not silently replace an explicitly empty report directory' {
        $result = Invoke-NativeFixture -Arguments '-Command "$ErrorActionPreference=''Stop''; & ''.\Invoke-KB5130098.ps1'' -ComputerName EX02 -ReportDirectory '''' -AsJson; exit $LASTEXITCODE"'
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'ReportDirectory'
        $result.Output | Should -BeNullOrEmpty
    }

    It 'runs the real primary remote preview without specifying a report directory' {
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -ComputerName example.invalid -WhatIf -AsJson' -f $path)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $json = $result.Output | ConvertFrom-Json
        $json.Status | Should -Be 'NoChanges'
        $json.Servers | Should -Be 0
        $json.TargetCount | Should -Be 1
        $json.Report | Should -BeNullOrEmpty
    }

    It 'runs the real <Header> CSV preview without specifying a report directory' -ForEach @(
        @{ Header='ComputerName' }, @{ Header='Fqdn' }, @{ Header='Name' }
    ) {
        $csv = Join-Path $TestDrive 'defaults.csv'
        "$Header`r`nEX01.example.com" | Set-Content -LiteralPath $csv -Encoding UTF8
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -CsvPath "{1}" -WhatIf -AsJson' -f $path,$csv)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        ($result.Output | ConvertFrom-Json).Targets | Should -Be @('EX01.example.com')
    }

    It 'reads an unrenamed Exchange inventory CSV with type metadata through the actual native entry point' {
        $csv = Join-Path $TestDrive 'exchange-inventory.csv'
        '#TYPE Deserialized.Microsoft.Exchange.Data.Directory.Management.ExchangeServer',
            '"Name","Fqdn","PSComputerName","ServerRole"',
            '"EX02","EX02.example.com","management.example.com","Mailbox"',
            '"EX01","EX01.example.com","management.example.com","Mailbox"' |
            Set-Content -LiteralPath $csv -Encoding UTF8
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098.ps1'
        $report = Join-Path $TestDrive 'No inventory-preview reports'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -CsvPath "{1}" -ReportDirectory "{2}" -WhatIf -AsJson' -f $path,$csv,$report)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $json = $result.Output | ConvertFrom-Json
        $json.Targets | Should -Be @('EX02.example.com','EX01.example.com')
        $json.Servers | Should -Be 0
        $json.TargetCount | Should -Be 2
        Test-Path -LiteralPath $report | Should -BeFalse
    }

    It 'runs the actual legacy wrapper preview without a report-directory prompt' {
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -ComputerName example.invalid -WhatIf' -f $path)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $result.Output | Should -Match 'No remote connections'
        $result.Output | Should -Not -Match 'Supply values|ReportDirectory:'
    }

    It 'routes explicit names to remote file-only Apply without local elevation or local execution' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $command = '& ''{0}'' -ComputerName EX01,EX02 -Mode Apply -ReportDirectory ''C:\Reports'' -AsJson -Confirm:$false; exit $LASTEXITCODE' -f $path
        $result = Invoke-NativeFixture -Arguments ('-Command "{0}"' -f $command)
        $result.ExitCode | Should -Be 10
        $json = $result.Output | ConvertFrom-Json
        $json.ComputerName | Should -Be @('EX01','EX02')
        $json.RestartSearch | Should -BeFalse
        $json.ElevationCalls | Should -Be 0
        $json.LocalCalls | Should -Be 0
        $json.PayloadDirectory | Should -Be (Join-Path $script:fixtureRoot 'payload')
    }

    It 'forwards a CSV path containing spaces to remote dispatch' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $csv = Join-Path $TestDrive 'Approved server list.csv'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -CsvPath "{1}" -ReportDirectory "C:\Reports" -AsJson' -f $path,$csv)
        $result.ExitCode | Should -Be 0
        $json = $result.Output | ConvertFrom-Json
        $json.CsvPath | Should -Be $csv
        $json.ElevationCalls | Should -Be 0
        $json.LocalCalls | Should -Be 0
    }

    It 'rejects ambiguous direct and CSV targeting before dispatch' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -ComputerName EX01 -CsvPath servers.csv -ReportDirectory C:\Reports -AsJson' -f $path)
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'parameter set'
    }

    It 'refuses remote rollback explicitly without local rollback execution' {
        $path = Join-Path $script:fixtureRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -ComputerName EX01 -Mode Rollback -ReportDirectory C:\Reports -AsJson' -f $path)
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'Remote Rollback is not supported'
        $result.Output | Should -BeNullOrEmpty
    }

    It 'validates a real CSV and returns pure JSON WhatIf without admin, connections or reports' {
        $csv = Join-Path $TestDrive 'real targets.csv'
        "ComputerName,Site`r`nEX02.example.com,B`r`nEX01.example.com,A" | Set-Content -LiteralPath $csv -Encoding UTF8
        $report = Join-Path $TestDrive 'No remote report'
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -CsvPath "{1}" -ReportDirectory "{2}" -Mode Detect -WhatIf -AsJson' -f $path,$csv,$report)
        $result.ExitCode | Should -Be 0
        $result.Error | Should -BeNullOrEmpty
        $json = $result.Output | ConvertFrom-Json
        $json.Status | Should -Be 'NoChanges'
        $json.TargetCount | Should -Be 2
        $json.Targets | Should -Be @('EX02.example.com','EX01.example.com')
        $json.Servers | Should -Be 0
        $json.Report | Should -BeNullOrEmpty
        Test-Path -LiteralPath $report | Should -BeFalse
    }

    It 'validates all real <Header> CSV records before reporting a preview plan' -ForEach @(
        @{ Header='ComputerName' }, @{ Header='Fqdn' }, @{ Header='Name' }
    ) {
        $csv = Join-Path $TestDrive 'invalid targets.csv'
        "$Header`r`nEX01.example.com`r`nEX*" | Set-Content -LiteralPath $csv -Encoding UTF8
        $path = Join-Path $script:packageRoot 'Invoke-KB5130098.ps1'
        $result = Invoke-NativeFixture -Arguments ('-File "{0}" -CsvPath "{1}" -ReportDirectory C:\Reports -WhatIf -AsJson' -f $path,$csv)
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match 'CSV record 3'
        $result.Output | Should -BeNullOrEmpty
    }
}

Describe 'Native builder without a workstation-confirmation requirement' {
    BeforeAll {
        $script:builderRoot = Join-Path $TestDrive 'Native builder fixture'
        $script:builderRules = Join-Path $script:builderRoot 'rules'
        $null = New-Item -Path $script:builderRules -ItemType Directory -Force
        foreach ($name in @('Build-KB5130098Package.ps1','Invoke-KB5130098.ps1','Invoke-KB5130098Fleet.ps1','KB5130098.psd1','README.txt')) {
            Copy-Item -LiteralPath (Join-Path $script:packageRoot $name) -Destination $script:builderRoot
        }
        foreach ($directory in @('examples','docs')) {
            $null = New-Item -Path (Join-Path $script:builderRoot $directory) -ItemType Directory
        }
        Copy-Item -LiteralPath (Join-Path $script:packageRoot 'examples\servers.csv') -Destination (Join-Path $script:builderRoot 'examples')
        Copy-Item -LiteralPath (Join-Path $script:packageRoot 'docs\Reporting-and-Splunk.md') -Destination (Join-Path $script:builderRoot 'docs')
        foreach ($name in @('ko.token.rule.bin','ko.complex.rule.bin')) {
            'Native builder fixture; not Microsoft payload' | Set-Content -LiteralPath (Join-Path $script:builderRules $name)
        }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:packageRoot 'KB5130098.psm1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw 'Production module does not parse.' }
        $helpers = foreach ($name in @('Get-KBSpecification','Assert-KBLocalWritePath','Get-KBIdentity','Assert-KBIdentity','Assert-KBPayload')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $false)
            if ($null -eq $definition) { throw "Missing production helper: $name" }
            $definition.Extent.Text
        }
        $fixture = @'
$script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'KB5130098.psd1')
foreach ($rule in $script:Spec.Rules) {
    $path = Join-Path (Join-Path $PSScriptRoot 'rules') $rule.Name
    $rule.Bytes = (Get-Item -LiteralPath $path).Length
    $rule.SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function Assert-KBAdministrator {}
function Test-Path {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Position=0, ParameterSetName='Path')][string[]]$Path,
        [Parameter(ParameterSetName='LiteralPath')][string[]]$LiteralPath,
        [Alias('Type')][string]$PathType
    )
    if ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup') { return $true }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Start-Process { throw 'Native builder fixtures must never launch installers.' }
function Invoke-WebRequest { throw 'Native builder fixtures must never download software.' }
'@
        ($fixture + "`r`n" + ($helpers -join "`r`n")) |
            Set-Content -LiteralPath (Join-Path $script:builderRoot 'KB5130098.psm1') -Encoding ASCII
    }

    It 'builds under native -File on an Exchange-host fixture with <ArgumentsLabel>' -ForEach @(
        @{ ArgumentsLabel='no confirmation switch'; Extra='' }
        @{ ArgumentsLabel='the legacy optional switch'; Extra=' -ManagementWorkstationConfirmed' }
    ) {
        $output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $builder = Join-Path $script:builderRoot 'Build-KB5130098Package.ps1'
        $arguments = '-File "{0}" -RuleSourceDirectory "{1}" -OutputDirectory "{2}" -WorkRoot "{3}"{4}' -f `
            $builder,$script:builderRules,$output,$work,$Extra
        $result = Invoke-NativeFixture -Arguments $arguments -WorkingDirectory $TestDrive
        $result.ExitCode | Should -Be 0 -Because ($result.Error + $result.Output)
        $result.Error | Should -BeNullOrEmpty
        $result.Output | Should -Match 'Exchange installation detected'
        $result.Output | Should -Not -Match 'Supply values|missing mandatory parameters'
        $zip = @(Get-ChildItem -LiteralPath $output -Filter '*-deploy.zip' -File)
        $zip.Count | Should -Be 1
        $expected = ([IO.File]::ReadAllText("$($zip[0].FullName).sha256") -split '\s+')[0]
        (Get-FileHash -LiteralPath $zip[0].FullName -Algorithm SHA256).Hash | Should -Be $expected
        foreach ($rule in @('ko.token.rule.bin','ko.complex.rule.bin')) {
            (Get-FileHash -LiteralPath (Join-Path $output "Exchange-KB5130098\payload\$rule")).Hash |
                Should -Be (Get-FileHash -LiteralPath (Join-Path $script:builderRules $rule)).Hash
        }
    }
}
