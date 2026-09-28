BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KB5130098.psm1') -Force
}

BeforeAll {
    $script:packageRoot = Split-Path $PSScriptRoot -Parent
}

Describe 'Management workstation builder' {
    BeforeEach {
        $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:rules = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:rules -ItemType Directory
        foreach ($name in @('ko.token.rule.bin', 'ko.complex.rule.bin')) {
            'Fixture only, not a Microsoft payload' | Set-Content -LiteralPath (Join-Path $script:rules $name)
        }
        Mock Import-Module {}
        Mock Assert-KBAdministrator {}
        Mock Assert-KBPayload {}
        Mock Test-Path { [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath) }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        Mock Start-Process { throw 'Tests must not launch installers' }
        Mock Invoke-WebRequest { throw 'Tests must not download software' }
    }

    It 'creates a small ZIP with only the named payload and runtime files' {
        $result = & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed
        (Test-Path -LiteralPath $result.Package) | Should -BeTrue
        $result.SHA256 | Should -Be (Get-FileHash -LiteralPath $result.Package -Algorithm SHA256).Hash
        $expanded = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $result.Package -DestinationPath $expanded
        $files = @(Get-ChildItem -LiteralPath $expanded -File -Recurse)
        $files.Count | Should -Be 10
        @($files | Where-Object Name -eq 'servers.csv').Count | Should -Be 1
        @($files | Where-Object Name -eq 'Reporting-and-Splunk.md').Count | Should -Be 1
        @($files | Where-Object Extension -in '.exe', '.msi', '.dll').Count | Should -Be 0
        @($files | Where-Object Name -like '*.bin').Count | Should -Be 2
        Should -Invoke Assert-KBPayload -Times 2 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'refuses an existing output directory' {
        $null = New-Item -Path $script:output -ItemType Directory
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*already exists*'
    }

    It 'refuses to extract on an Exchange machine' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*Exchange installation*'
    }

    It 'rejects untrusted Microsoft media before execution' {
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*valid Microsoft Authenticode*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'stops if extract-only reports a nonzero exit code' {
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } }
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 42 } }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*extract-only failed*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -like '/q /x:*' }
    }

    It 'uses administrative extraction and rejects even reboot-success MSI codes' {
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } }
        }
        Mock Start-Process {
            $extract = [regex]::Match(($ArgumentList -join ' '), '^/q /x:"([^"]+)"$')
            if ($extract.Success) {
                $setup = Join-Path $extract.Groups[1].Value 'x64\Setup'
                $null = New-Item -Path $setup -ItemType Directory -Force
                'MSI fixture only' | Set-Content -LiteralPath (Join-Path $setup 'SQL_FULLTEXT.MSI')
                return [pscustomobject]@{ ExitCode = 0 }
            }
            [pscustomobject]@{ ExitCode = 3010 }
        }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*administrative extraction failed*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like '*\msiexec.exe' -and $ArgumentList -like '/a *' -and $ArgumentList -like '* /qn /norestart /L*V *'
        }
    }
}

Describe 'Serial fleet rollout with mocked remoting' {
    InModuleScope KB5130098 {
    BeforeEach {
        $script:packageRoot = (Get-Module KB5130098).ModuleBase
        $script:reports = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:KB5130098TestContext = @{
            Events = (New-Object Collections.Generic.List[string])
            Target = ''
            Eligible = $true
        }
        Mock Assert-KBPayload {} -ModuleName KB5130098
        Mock Write-KBConsoleResult {} -ModuleName KB5130098
        Mock Get-KBElevationContext { [pscustomobject]@{ Remote=$false; Interactive=$true } } -ModuleName KB5130098
        Mock New-PSSession {
            $global:KB5130098TestContext.Target = $ComputerName
            $global:KB5130098TestContext.Events.Add("Connect $ComputerName")
            New-MockObject -Type System.Management.Automation.Runspaces.PSSession
        }
        Mock Remove-PSSession {} -ModuleName KB5130098
        Mock Copy-Item {} -ModuleName KB5130098
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $context = $global:KB5130098TestContext
            if ($text.Contains('WindowsPrincipal')) {
                return [pscustomobject]@{ Path = "C:\ProgramData\Fixture\$($context.Target)"; ComputerName = $context.Target }
            }
            if ($text.Contains('Get-FileHash')) { return }
            if ($text.Contains('Invoke-KBLocal -Mode Detect')) {
                return [pscustomobject]@{ Eligible = $context.Eligible; Status = $(if ($context.Eligible) { 'EligibleMissingBothRules' } else { 'NotApplicableStop' }) }
            }
            if ($text.Contains('Invoke-KBLocal -Mode Apply')) {
                $context.Events.Add("Apply $($context.Target)")
                $context.LastRestart = [bool]$ArgumentList[3]
                $status = if ($context.LastRestart) { 'RestartedWorkloadValidationRequired' } else { 'FilesStagedRestartRequired' }
                return [pscustomobject]@{ Status = $status; ReceiptPath = 'C:\ProgramData\Fixture\receipt.json' }
            }
            if ($text.Contains('New-Item -Path (Join-Path')) {
                return "C:\ProgramData\Fixture\$($context.Target)\payload"
            }
            throw "Unexpected remoting request in test: $text"
        } -ModuleName KB5130098
        Mock Read-Host {
            $global:KB5130098TestContext.Events.Add("Attest $($global:KB5130098TestContext.Target)")
            "RECOVERED $($global:KB5130098TestContext.Target)"
        } -ModuleName KB5130098
    }
    AfterEach {
        Remove-Variable -Name KB5130098TestContext -Scope Global
    }

    It 'never connects to the second server before recovery attestation on the first' {
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Confirm:$false
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com|Attest EX01.example.com|Connect EX02.example.com|Apply EX02.example.com|Attest EX02.example.com'
        $report = Get-Content -LiteralPath $result.Report -Raw | ConvertFrom-Json
        $report.Count | Should -Be 2
        $report[1].Status | Should -Be 'OperatorConfirmedRecovery'
        Should -Invoke Remove-PSSession -ModuleName KB5130098 -Times 2 -Exactly
    }

    It 'stops rollout immediately if recovery is not confirmed' {
        Mock Read-Host { 'STOP' } -ModuleName KB5130098
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*Recovery was not confirmed*'
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com'
        Should -Invoke Remove-PSSession -ModuleName KB5130098 -Times 1 -Exactly
        $reportFile = (Get-ChildItem -LiteralPath $script:reports -Filter rollout.json -Recurse).FullName
        $records = Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json
        $records[1].Status | Should -Be 'NotRun'
        $exportRoot = Split-Path $reportFile -Parent
        $csv = @(Import-Csv -LiteralPath (Join-Path $exportRoot 'results.csv'))
        $csv[0].Status | Should -Be 'FailedStop'
        $csv[1].Status | Should -Be 'NotRun'
        [IO.File]::ReadAllLines((Join-Path $exportRoot 'results.jsonl')).Count | Should -Be 2
    }

    It 'stops rollout immediately on a nonapplicable installation' {
        $global:KB5130098TestContext.Eligible = $false
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*not eligible*'
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com'
        Should -Invoke Read-Host -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'Detect never applies or requests a recovery attestation' {
        $result = Invoke-KBFleet -Mode Detect -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Connect EX02.example.com'
        $result.Servers | Should -Be 2
        Should -Invoke Read-Host -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'uses the shared default report root and creates a unique report for each run' {
        Mock Assert-KBLocalWritePath { $script:reports } -ModuleName KB5130098 `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        $first = Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -Quiet -Confirm:$false
        $second = Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -Quiet -Confirm:$false
        Should -Invoke Assert-KBLocalWritePath -ModuleName KB5130098 -Times 2 -Exactly `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        $first.Report | Should -Not -Be $second.Report
        Split-Path (Split-Path $first.Report -Parent) -Parent | Should -Be $script:reports
        Test-Path -LiteralPath $first.Report | Should -BeTrue
        Test-Path -LiteralPath $second.Report | Should -BeTrue
    }

    It 'uses the same default for CSV mode without creating reports during preview' {
        Mock Assert-KBLocalWritePath { $script:reports } -ModuleName KB5130098 `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        $csv = Join-Path $TestDrive 'default-report-targets.csv'
        "ComputerName`r`nEX01.example.com" | Set-Content -LiteralPath $csv
        $result = Invoke-KBFleet -CsvPath $csv -PackageDirectory $script:packageRoot -Quiet -WhatIf
        $result.Status | Should -Be 'NoChanges'
        Should -Invoke Assert-KBLocalWritePath -ModuleName KB5130098 -Times 1 -Exactly `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
        Test-Path -LiteralPath $script:reports | Should -BeFalse
    }

    It 'fails explicitly before connecting if the selected default cannot be created' {
        Mock New-Item { throw 'Report directory access denied.' } -ModuleName KB5130098 `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        { Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -Quiet -Confirm:$false } |
            Should -Throw '*Report directory access denied*'
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
        Should -Invoke New-Item -ModuleName KB5130098 -Times 1 -Exactly
    }

    It 'rejects an explicitly invalid report path without silently falling back' -ForEach @(
        @{ ReportPath = 'relative\reports' }
        @{ ReportPath = ' ' }
    ) {
        { Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $ReportPath -Quiet -WhatIf } | Should -Throw '*local absolute path*'
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'WhatIf makes no connections and writes no report' {
        Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -WhatIf
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
        (Test-Path -LiteralPath $script:reports) | Should -BeFalse
    }

    It 'requires maintenance approval and explicit unique host names' {
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -Confirm:$false } | Should -Throw '*MaintenanceWindowApproved*'
        { Invoke-KBFleet -ComputerName 'EX*' -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*explicit DNS*'
        { Invoke-KBFleet -ComputerName EX01,EX01 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*Duplicate*'
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'shared remote Apply stages files without an implicit restart or recovery prompt' {
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com `
            -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false
        $result.ExitCode | Should -Be 10
        $result.Status | Should -Be 'FilesStagedRestartRequired'
        $global:KB5130098TestContext.LastRestart | Should -BeFalse
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com|Connect EX02.example.com|Apply EX02.example.com'
        Should -Invoke Read-Host -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'uses the entire validated CSV roster in order without calling local-only elevation' {
        $csv = Join-Path $TestDrive 'targets.csv'
        "ComputerName,Site`r`nEX02.example.com,A`r`nEX01.example.com,B" | Set-Content -LiteralPath $csv -Encoding UTF8
        $result = Invoke-KBFleet -Mode Detect -CsvPath $csv -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -Confirm:$false
        $result.TargetCount | Should -Be 2
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX02.example.com|Connect EX01.example.com'
    }

    It 'rejects an invalid late CSV row before any connection or report creation' {
        $csv = Join-Path $TestDrive 'bad-targets.csv'
        "ComputerName`r`nEX01.example.com`r`nEX*" | Set-Content -LiteralPath $csv -Encoding UTF8
        { Invoke-KBFleet -CsvPath $csv -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*CSV record 3*'
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
        Test-Path -LiteralPath $script:reports | Should -BeFalse
    }

    It 'returns exit 20 for a detection report containing a stopped eligibility result' {
        $global:KB5130098TestContext.Eligible = $false
        $result = Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -Quiet -Confirm:$false
        $result.ExitCode | Should -Be 20
        $result.Status | Should -Be 'ReviewRequired'
        $result.Results[0].Current.Status | Should -Be 'NotApplicableStop'
        $result.ReportData[0].Status | Should -Be 'NotApplicableStop'
        Test-Path -LiteralPath $result.ExportFiles.Csv | Should -BeTrue
        Test-Path -LiteralPath $result.ExportFiles.JsonLines | Should -BeTrue
    }

    It 'refuses restarted remote Apply in quiet machine-output mode before connecting' {
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Quiet -Confirm:$false } |
            Should -Throw '*interactive human recovery*'
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'allows a quiet restart preview without connections or pretending recovery was attested' {
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Quiet -WhatIf
        $result.Status | Should -Be 'NoChanges'
        $result.Servers | Should -Be 0
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
        Should -Invoke Read-Host -ModuleName KB5130098 -Times 0 -Exactly
    }

    It 'refuses unattended restart rollout before changing the first server' {
        Mock Get-KBElevationContext { [pscustomobject]@{ Remote=$false; Interactive=$false } } -ModuleName KB5130098
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Confirm:$false } |
            Should -Throw '*local interactive console*'
        Should -Invoke New-PSSession -ModuleName KB5130098 -Times 0 -Exactly
        Test-Path -LiteralPath $script:reports | Should -BeFalse
    }

    It 'rejects duplicate physical machines reached through different aliases' {
        Mock Invoke-Command {
            [pscustomobject]@{ Path = 'C:\ProgramData\Fixture\shared'; ComputerName = 'ONE-MACHINE' }
        } -ModuleName KB5130098 -ParameterFilter { $ScriptBlock.ToString().Contains('WindowsPrincipal') }
        { Invoke-KBFleet -ComputerName EX01.example.com,Alias01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*same machine*'
        Should -Invoke Remove-PSSession -ModuleName KB5130098 -Times 2 -Exactly
    }
    }
}

Describe 'Legacy fleet entry-point compatibility' {
    BeforeEach {
        Mock Import-Module {}
        Mock Invoke-KBFleet { [pscustomobject]@{ Status='Completed'; Report='C:\Fixture\rollout.json'; Servers=1; Mode=$Mode; ReportData=@(); ExportFiles=$null } }
        Mock Write-KBReportSummary {}
    }

    It 'retains the legacy explicit maintenance and implicit restart contract for Apply' {
        $result = & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply `
            -ComputerName EX01.example.com -ReportDirectory 'C:\Fixture' -MaintenanceWindowApproved -Confirm:$false
        $result.Servers | Should -Be 1
        Should -Invoke Invoke-KBFleet -Times 1 -Exactly -ParameterFilter { $RestartSearch -and $MaintenanceWindowApproved -and $Mode -eq 'Apply' }
    }

    It 'does not request a restart for legacy Detect' {
        $null = & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') `
            -ComputerName EX01.example.com -ReportDirectory 'C:\Fixture' -Confirm:$false
        Should -Invoke Invoke-KBFleet -Times 1 -Exactly -ParameterFilter { -not $RestartSearch -and $Mode -eq 'Detect' }
    }
}
