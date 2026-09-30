BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KoreanRules.psm1') -Force
}

BeforeAll {
    $script:packageRoot = Split-Path $PSScriptRoot -Parent
    $script:legacyRoot = Join-Path $script:packageRoot 'archive\compatibility'
}

Describe 'Guarded package builder' {
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
        Mock Write-Warning {}
    }

    It 'creates a small ZIP with only the named payload and runtime files' {
        $result = & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') -ErrorAction Stop -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work
        (Test-Path -LiteralPath $result.Package) | Should -BeTrue
        $result.SHA256 | Should -Be (Get-FileHash -LiteralPath $result.Package -Algorithm SHA256).Hash
        $expanded = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $result.Package -DestinationPath $expanded
        $files = @(Get-ChildItem -LiteralPath $expanded -File -Recurse)
        $files.Count | Should -Be 12
        @($files | Where-Object { $_.Extension -eq '.ps1' -and $_.Directory.Name -eq 'Exchange-KoreanRules' } |
            Select-Object -ExpandProperty Name | Sort-Object) |
            Should -Be @('Get-KoreanRulesState.ps1','Install-KoreanRules.ps1','Set-KoreanRulesState.ps1')
        $result.PayloadDirectory | Should -Be (Join-Path $result.ExpandedPackage 'payload')
        @($files | Where-Object Name -eq 'servers.csv').Count | Should -Be 1
        @($files | Where-Object Name -eq 'Reporting-and-Splunk.md').Count | Should -Be 1
        @($files | Where-Object Extension -in '.exe', '.msi', '.dll').Count | Should -Be 0
        @($files | Where-Object Name -like '*.bin').Count | Should -Be 2
        $nativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $preview = & $nativePowerShell -NoProfile -NonInteractive -File (Join-Path $result.ExpandedPackage 'Get-KoreanRulesState.ps1') `
            -ComputerName example.invalid -WhatIf -AsJson
        $LASTEXITCODE | Should -Be 0
        $plan = ($preview -join [Environment]::NewLine) | ConvertFrom-Json
        $plan.Status | Should -Be 'NoChanges'
        $plan.Servers | Should -Be 0
        $plan.Targets | Should -Be @('example.invalid')
        Should -Invoke Assert-KBPayload -Times 2 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'refuses an existing output directory' {
        $null = New-Item -Path $script:output -ItemType Directory
        { & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') -ErrorAction Stop -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*already exists*'
    }

    It 'explains missing Microsoft media before writing or executing anything' {
        $missing=Join-Path $TestDrive 'missing-SQLEXPR_x64_ENU.exe'
        { & (Join-Path $script:packageRoot 'Install-KoreanRules.ps1') -ErrorAction Stop -SqlPackagePath $missing -OutputDirectory $script:output -WorkRoot $script:work } |
            Should -Throw '*REQUIRED MICROSOFT MEDIA MISSING*Install-KoreanRules.ps1 -Download*-RuleSourceDirectory*'
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Test-Path -LiteralPath $script:work | Should -BeFalse
        Test-Path -LiteralPath $script:output | Should -BeFalse
    }

    It 'retains a failed download as partial and never executes or publishes it' -ForEach @(
        @{Failure='Transfer'},@{Failure='Identity'}
    ) {
        if($Failure -eq 'Transfer'){
            Mock Invoke-WebRequest {
                'Interrupted fixture' | Set-Content -LiteralPath $OutFile
                throw 'Injected transfer failure'
            }
        } else {
            Mock Invoke-WebRequest { 'Short fixture' | Set-Content -LiteralPath $OutFile }
            Mock Assert-KBIdentity {throw 'Injected identity mismatch'}
        }
        { & (Join-Path $script:packageRoot 'Install-KoreanRules.ps1') -Download -OutputDirectory $script:output -WorkRoot $script:work -ErrorAction Stop } |
            Should -Throw '*Injected*'
        @(Get-ChildItem -LiteralPath $script:work -Filter '*.partial.exe' -File -Recurse).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:work -Filter 'SQLEXPR_x64_ENU.exe' -File -Recurse).Count | Should -Be 0
        Should -Invoke Start-Process -Times 0 -Exactly
        Test-Path -LiteralPath $script:output | Should -BeFalse
    }

    It 'packages verified rules on Exchange without requiring workstation confirmation' -ForEach @(
        @{ LegacySwitch=$false }, @{ LegacySwitch=$true }
    ) {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        $parameters = @{ ErrorAction='Stop'; RuleSourceDirectory=$script:rules; OutputDirectory=$script:output; WorkRoot=$script:work }
        if ($LegacySwitch) { $parameters.ManagementWorkstationConfirmed=$true }
        $result = & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') @parameters
        Test-Path -LiteralPath $result.Package | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*Exchange installation detected*' }
        Should -Invoke Assert-KBAdministrator -Times 1 -Exactly
        Should -Invoke Assert-KBPayload -Times 2 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'allows extract-only media builds on Exchange via <SourceMode> without confirmation' -ForEach @(
        @{ SourceMode='Download' }, @{ SourceMode='ExistingMedia' }
    ) {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status='Valid'; SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'} }
        }
        Mock Invoke-WebRequest { 'Downloaded fixture only' | Set-Content -LiteralPath $OutFile }
        Mock Start-Process {
            $extract = [regex]::Match(($ArgumentList -join ' '), '^/q /x:"([^"]+)"$')
            if ($extract.Success) {
                $setup = Join-Path $extract.Groups[1].Value 'x64\Setup'
                $null = New-Item -Path $setup -ItemType Directory -Force
                'MSI fixture only' | Set-Content -LiteralPath (Join-Path $setup 'SQL_FULLTEXT.MSI')
            } else {
                $adminExtract = [regex]::Match(($ArgumentList -join ' '), '^/a "[^"]+" TARGETDIR="([^"]+)" /qn /norestart /L\*V "[^"]+"$')
                if (-not $adminExtract.Success) { throw 'Unexpected installer arguments.' }
                $rules = Join-Path $adminExtract.Groups[1].Value 'Program Files\Microsoft SQL Server\MSSQL.X\MSSQL\Binn\ftcomponents\wordbreakers'
                $null = New-Item -Path $rules -ItemType Directory -Force
                foreach ($name in @('ko.token.rule.bin','ko.complex.rule.bin')) {
                    'Extracted fixture only' | Set-Content -LiteralPath (Join-Path $rules $name)
                }
            }
            [pscustomobject]@{ ExitCode=0 }
        }
        $parameters = @{ ErrorAction='Stop'; OutputDirectory=$script:output; WorkRoot=$script:work }
        if ($SourceMode -eq 'Download') { $parameters.Download=$true }
        else { $parameters.SqlPackagePath=$media }
        $result = & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') @parameters
        Test-Path -LiteralPath $result.Package | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -Exactly
        Should -Invoke Assert-KBIdentity -Times 1 -Exactly
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly
        Should -Invoke Assert-KBPayload -Times 2 -Exactly
        Should -Invoke Start-Process -Times 2 -Exactly
        Should -Invoke Invoke-WebRequest -Times $(if ($SourceMode -eq 'Download') { 1 } else { 0 }) -Exactly
    }

    It 'still rejects media identity failures on an Exchange host before execution' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        $media = Join-Path $TestDrive 'wrong-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity { throw 'Size or SHA256 mismatch: fixture media' }
        Mock Get-AuthenticodeSignature { throw 'Signature lookup must not run after identity failure.' }
        { & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') -ErrorAction Stop -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work } |
            Should -Throw '*Size or SHA256 mismatch*'
        Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'still rejects untrusted Microsoft media on an Exchange host before execution' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') -ErrorAction Stop -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work } | Should -Throw '*valid Microsoft Authenticode*'
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
        { & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') -ErrorAction Stop -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*extract-only failed*'
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
        { & (Join-Path $script:legacyRoot 'Build-KB5130098Package.ps1') -ErrorAction Stop -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*administrative extraction failed*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like '*\msiexec.exe' -and $ArgumentList -like '/a *' -and $ArgumentList -like '* /qn /norestart /L*V *'
        }
    }
}

Describe 'Serial fleet rollout with mocked remoting' {
    InModuleScope KoreanRules {
    BeforeEach {
        $script:packageRoot = (Get-Module KoreanRules).ModuleBase
        $script:reports = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:KB5130098TestContext = @{
            Events = (New-Object Collections.Generic.List[string])
            Target = ''
            Eligible = $true
        }
        Mock Assert-KBPayload {} -ModuleName KoreanRules
        Mock Write-KBConsoleResult {} -ModuleName KoreanRules
        Mock Get-KBElevationContext { [pscustomobject]@{ Remote=$false; Interactive=$true } } -ModuleName KoreanRules
        Mock New-PSSession {
            $global:KB5130098TestContext.Target = $ComputerName
            $global:KB5130098TestContext.Events.Add("Connect $ComputerName")
            New-MockObject -Type System.Management.Automation.Runspaces.PSSession
        }
        Mock Remove-PSSession {} -ModuleName KoreanRules
        Mock Copy-Item {} -ModuleName KoreanRules
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
        } -ModuleName KoreanRules
        Mock Read-Host {
            $global:KB5130098TestContext.Events.Add("Attest $($global:KB5130098TestContext.Target)")
            "RECOVERED $($global:KB5130098TestContext.Target)"
        } -ModuleName KoreanRules
    }
    AfterEach {
        Remove-Variable -Name KB5130098TestContext -Scope Global
    }

    It 'never connects to the second server before recovery attestation on the first' {
        $ConfirmPreference = 'High'
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com|Attest EX01.example.com|Connect EX02.example.com|Apply EX02.example.com|Attest EX02.example.com'
        $report = Get-Content -LiteralPath $result.Report -Raw | ConvertFrom-Json
        $report.Count | Should -Be 2
        $report[1].Status | Should -Be 'OperatorConfirmedRecovery'
        Should -Invoke Remove-PSSession -ModuleName KoreanRules -Times 2 -Exactly
    }

    It 'stops rollout immediately if recovery is not confirmed' {
        Mock Read-Host { 'STOP' } -ModuleName KoreanRules
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*Recovery was not confirmed*'
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com'
        Should -Invoke Remove-PSSession -ModuleName KoreanRules -Times 1 -Exactly
        $reportFile = (Get-ChildItem -LiteralPath $script:reports -Filter rollout.json -Recurse).FullName
        $records = Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json
        $records[1].Status | Should -Be 'NotRun'
        $exportRoot = Split-Path $reportFile -Parent
        $csv = @(Import-Csv -LiteralPath (Join-Path $exportRoot 'results.csv'))
        $csv[0].Status | Should -Be 'FailedStop'
        $csv[1].Status | Should -Be 'NotRun'
        [IO.File]::ReadAllLines((Join-Path $exportRoot 'results.jsonl')).Count | Should -Be 2
    }

    It 'contacts every target and skips nonapplicable installations without changes or attestation' {
        $global:KB5130098TestContext.Eligible = $false
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Connect EX02.example.com'
        $result.ExitCode | Should -Be 20
        @($result.Results | Where-Object Status -eq 'NotApplicableStop').Count | Should -Be 2
        Should -Invoke Read-Host -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'continues from existing rules to a wrong-build target for <Input> with Restart <Restart>' -ForEach @(
        @{Input='Names';Restart=$false}, @{Input='Names';Restart=$true},
        @{Input='Csv';Restart=$false}, @{Input='Csv';Restart=$true}
    ) {
        Mock Invoke-Command {
            $existing = $global:KB5130098TestContext.Target -eq 'EX02'
            [pscustomobject]@{
                Eligible=$false;Status=$(if($existing){'RuleFilesPresentStop'}else{'NotApplicableStop'})
                ExchangeVersion=$(if($existing){'15.2.2562.49'}else{'15.2.2562.46'})
                DllVersion='16.0.5194.1000';ExistingRules=$(if($existing){@('ko.token.rule.bin','ko.complex.rule.bin')}else{@()})
            }
        } -ParameterFilter { $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Detect') }
        $parameters=@{Mode='Apply';PackageDirectory=$script:packageRoot;ReportDirectory=$script:reports;RestartSearch=$Restart;MaintenanceWindowApproved=$Restart}
        if($Input -eq 'Csv') {
            $csv=Join-Path $TestDrive 'skips.csv'
            "Name`r`nEX02`r`nEX03" | Set-Content -LiteralPath $csv
            $parameters.CsvPath=$csv
        } else { $parameters.ComputerName=@('EX02','EX03') }
        $result=Invoke-KBFleet @parameters
        $result.Servers | Should -Be 2
        $result.ExitCode | Should -Be 20
        $result.Results.Status | Should -Be @('RuleFilesPresentStop','NotApplicableStop')
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX02|Connect EX03'
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Copy-Item -Times 0 -Exactly -ParameterFilter { $LiteralPath -like '*.bin' }
        $rows=@(Import-Csv -LiteralPath $result.ExportFiles.Csv)
        $rows[0].ActionTaken | Should -Match 'Skipped existing rules'
        $rows[1].ApplicabilityReason | Should -Match 'found 15.2.2562.46; required 15.2.2562.49'
        $rows[0].Error | Should -BeNullOrEmpty
        $rows[1].RestartCompleted | Should -Be 'False'
        [IO.File]::ReadAllLines($result.ExportFiles.JsonLines).Count | Should -Be 2
    }

    It 'applies only eligible targets in a mixed list and reports a pending restart over skipped results' {
        Mock Invoke-Command {
            if($global:KB5130098TestContext.Target -eq 'EX02') {
                [pscustomobject]@{Eligible=$true;Status='EligibleMissingBothRules'}
            } else {
                [pscustomobject]@{Eligible=$false;Status='RuleFilesPresentStop';ExistingRules=@('ko.token.rule.bin','ko.complex.rule.bin')}
            }
        } -ParameterFilter { $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Detect') }
        $result=Invoke-KBFleet -Mode Apply -ComputerName EX01,EX02,EX03 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01|Connect EX02|Apply EX02|Connect EX03'
        $result.ExitCode | Should -Be 10
        $result.Results.Status | Should -Be @('RuleFilesPresentStop','FilesStagedRestartRequired','RuleFilesPresentStop')
    }

    It 'still stops later targets on an actual modifying failure after an expected skip' {
        Mock Invoke-Command { [pscustomobject]@{Eligible=$false;Status='RuleFilesPresentStop';ExistingRules=@('ko.token.rule.bin','ko.complex.rule.bin')} } -ParameterFilter {
            $global:KB5130098TestContext.Target -eq 'EX01' -and $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Detect')
        }
        Mock Invoke-Command { throw 'Injected apply failure' } -ParameterFilter { $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Apply') }
        { Invoke-KBFleet -Mode Apply -ComputerName EX01,EX02,EX03 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports } | Should -Throw '*Injected apply failure*'
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01|Connect EX02'
        $file=Get-ChildItem -LiteralPath $script:reports -Filter results.csv -Recurse -File
        $rows=@(Import-Csv -LiteralPath $file.FullName)
        $rows.Status | Should -Be @('RuleFilesPresentStop','FailedStop','NotRun')
    }

    It 'keeps compact skip messages yellow without discarding any target' {
        Mock Write-Host {}
        Mock Invoke-Command { [pscustomobject]@{Eligible=$false;Status='RuleFilesPresentStop';ExistingRules=@('ko.token.rule.bin','ko.complex.rule.bin')} } -ParameterFilter {
            $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Detect')
        }
        $result=Invoke-KBFleet -Mode Apply -ComputerName EX01,EX02,EX03,EX04 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports
        $result.ReportData.Count | Should -Be 4
        Should -Invoke Write-Host -Times 4 -Exactly -ParameterFilter { [string]$Object -like 'SKIPPED EX*' -and $ForegroundColor -eq 'Yellow' }
        Should -Invoke Write-KBConsoleResult -Times 0 -Exactly
    }

    It 'treats an eligibility change during local recheck as a skip without restart attestation' {
        Mock Invoke-Command { [pscustomobject]@{Status='RuleFilesPresentStop';Eligible=$false;ExistingRules=@('ko.token.rule.bin','ko.complex.rule.bin')} } -ParameterFilter {
            $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Apply')
        }
        $result=Invoke-KBFleet -Mode Apply -ComputerName EX01,EX02 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved
        $result.Results.Status | Should -Be @('RuleFilesPresentStop','RuleFilesPresentStop')
        $result.ExitCode | Should -Be 20
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Detect needs no Confirm false and never applies or requests a recovery attestation' {
        $ConfirmPreference = 'High'
        $result = Invoke-KBFleet -Mode Detect -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Connect EX02.example.com'
        $result.Servers | Should -Be 2
        Should -Invoke Read-Host -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'uses the shared default report root and creates a unique report for each run' {
        Mock Assert-KBLocalWritePath { $script:reports } -ModuleName KoreanRules `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        $first = Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -Quiet -Confirm:$false
        $second = Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -Quiet -Confirm:$false
        Should -Invoke Assert-KBLocalWritePath -ModuleName KoreanRules -Times 2 -Exactly `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        $first.Report | Should -Not -Be $second.Report
        Split-Path (Split-Path $first.Report -Parent) -Parent | Should -Be $script:reports
        Test-Path -LiteralPath $first.Report | Should -BeTrue
        Test-Path -LiteralPath $second.Report | Should -BeTrue
    }

    It 'uses the same default for CSV mode without creating reports during preview' {
        Mock Assert-KBLocalWritePath { $script:reports } -ModuleName KoreanRules `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        $csv = Join-Path $TestDrive 'default-report-targets.csv'
        "ComputerName`r`nEX01.example.com" | Set-Content -LiteralPath $csv
        $result = Invoke-KBFleet -CsvPath $csv -PackageDirectory $script:packageRoot -Quiet -WhatIf
        $result.Status | Should -Be 'NoChanges'
        Should -Invoke Assert-KBLocalWritePath -ModuleName KoreanRules -Times 1 -Exactly `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
        Test-Path -LiteralPath $script:reports | Should -BeFalse
    }

    It 'fails explicitly before connecting if the selected default cannot be created' {
        Mock New-Item { throw 'Report directory access denied.' } -ModuleName KoreanRules `
            -ParameterFilter { $Path -eq 'C:\Temp\KB5130098-Reports' }
        { Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -Quiet -Confirm:$false } |
            Should -Throw '*Report directory access denied*'
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
        Should -Invoke New-Item -ModuleName KoreanRules -Times 1 -Exactly
    }

    It 'rejects an explicitly invalid report path without silently falling back' -ForEach @(
        @{ ReportPath = 'relative\reports' }
        @{ ReportPath = ' ' }
    ) {
        { Invoke-KBFleet -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $ReportPath -Quiet -WhatIf } | Should -Throw '*local absolute path*'
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'WhatIf makes no connections and writes no report' {
        Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -WhatIf
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
        (Test-Path -LiteralPath $script:reports) | Should -BeFalse
    }

    It 'requires maintenance approval and explicit unique host names' {
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -RestartSearch -Confirm:$false } | Should -Throw '*MaintenanceWindowApproved*'
        { Invoke-KBFleet -ComputerName 'EX*' -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*explicit DNS*'
        { Invoke-KBFleet -ComputerName EX01,EX01 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*Duplicate*'
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'shared remote Apply needs no Confirm false and stages without an implicit restart or recovery prompt' {
        $ConfirmPreference = 'High'
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com,EX02.example.com `
            -PackageDirectory $script:packageRoot -ReportDirectory $script:reports
        $result.ExitCode | Should -Be 10
        $result.Status | Should -Be 'FilesStagedRestartRequired'
        $global:KB5130098TestContext.LastRestart | Should -BeFalse
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com|Connect EX02.example.com|Apply EX02.example.com'
        Should -Invoke Read-Host -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'uses the entire validated <Header> CSV roster in order without calling local-only elevation' -ForEach @(
        @{ Header='ComputerName' }, @{ Header='Fqdn' }, @{ Header='Name' }
    ) {
        $csv = Join-Path $TestDrive 'targets.csv'
        "$Header,Site`r`nEX02.example.com,A`r`nEX01.example.com,B" | Set-Content -LiteralPath $csv -Encoding UTF8
        $result = Invoke-KBFleet -Mode Detect -CsvPath $csv -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -Confirm:$false
        $result.TargetCount | Should -Be 2
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX02.example.com|Connect EX01.example.com'
    }

    It 'uses compact output only above three targets for <InputKind> <Mode> count <Count>' -ForEach @(
        foreach ($inputKind in @('Names','Csv')) {
            foreach ($mode in @('Detect','Apply')) {
                foreach ($count in @(3,4)) { @{ InputKind=$inputKind; Mode=$mode; Count=$count } }
            }
        }
    ) {
        Mock Write-Host {}
        $targets = @(1..$Count | ForEach-Object { "EX0$_.example.com" })
        $parameters = @{Mode=$Mode;PackageDirectory=$script:packageRoot;ReportDirectory=$script:reports}
        if ($InputKind -eq 'Csv') {
            $csv = Join-Path $TestDrive 'compact-targets.csv'
            @('Fqdn') + $targets | Set-Content -LiteralPath $csv
            $parameters.CsvPath=$csv
        } else { $parameters.ComputerName=$targets }
        $result = Invoke-KBFleet @parameters
        $expectedDetails = if ($Count -gt 3) { 0 } else { $Count }
        Should -Invoke Write-KBConsoleResult -Times $expectedDetails -Exactly
        Should -Invoke Write-Host -Times $expectedDetails -Exactly -ParameterFilter { [string]$Object -match '^\[\d+/\d+\]' }
        $result.Targets | Should -Be $targets
        $result.ReportData.Count | Should -Be $Count
        @(Import-Csv -LiteralPath $result.ExportFiles.Csv).Count | Should -Be $Count
        [IO.File]::ReadAllLines($result.ExportFiles.JsonLines).Count | Should -Be $Count
        $result.ReportData[0].Status | Should -Be $(if ($Mode -eq 'Detect') { 'EligibleMissingBothRules' } else { 'FilesStagedRestartRequired' })
    }

    It 'keeps four-target quiet machine runs free of human output without dropping data' {
        Mock Write-Host {}
        $result = Invoke-KBFleet -ComputerName EX01,EX02,EX03,EX04 -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -Quiet
        Should -Invoke Write-Host -Times 0 -Exactly
        Should -Invoke Write-KBConsoleResult -Times 0 -Exactly
        $result.ReportData.Count | Should -Be 4
        $result.Results.Count | Should -Be 4
    }

    It 'does not hide per-server recovery attestation in a compact restarted rollout' {
        Mock Write-Host {}
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01,EX02,EX03,EX04 -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved
        Should -Invoke Write-KBConsoleResult -Times 0 -Exactly
        Should -Invoke Read-Host -Times 4 -Exactly
        Should -Invoke Write-Host -Times 4 -Exactly -ParameterFilter { [string]$Object -like 'STOP: Validate *' }
        @($result.Results | Where-Object Status -eq 'OperatorConfirmedRecovery').Count | Should -Be 4
    }

    It 'shows errors in compact mode and retains failed plus unvisited targets' {
        Mock Write-Host {}
        Mock Invoke-Command { throw 'Injected compact target failure.' } -ParameterFilter {
            $global:KB5130098TestContext.Target -eq 'EX02' -and $ScriptBlock.ToString().Contains('Invoke-KBLocal -Mode Detect')
        }
        { Invoke-KBFleet -ComputerName EX01,EX02,EX03,EX04 -PackageDirectory $script:packageRoot -ReportDirectory $script:reports } |
            Should -Throw '*Injected compact target failure*'
        Should -Invoke New-PSSession -Times 2 -Exactly
        Should -Invoke Write-KBConsoleResult -Times 0 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            [string]$Object -like 'STOPPED EX02:*Injected compact target failure*' -and $ForegroundColor -eq 'Red'
        }
        $csv = @(Get-ChildItem -LiteralPath $script:reports -Filter results.csv -Recurse -File)
        $rows = @(Import-Csv -LiteralPath $csv[0].FullName)
        $rows.Count | Should -Be 4
        $rows[1].Status | Should -Be 'FailedStop'
        $rows[2].Status | Should -Be 'NotRun'
        $rows[3].Status | Should -Be 'NotRun'
    }

    It 'suppresses four-target preview name dumps but retains the full in-memory plan' {
        Mock Write-Host {}
        $result = Invoke-KBFleet -ComputerName EX01,EX02,EX03,EX04 -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -WhatIf
        $result.Targets | Should -Be @('EX01','EX02','EX03','EX04')
        $result.ReportData.Count | Should -Be 4
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { [string]$Object -match '^\s+EX0[1-4]$' }
        Should -Invoke New-PSSession -Times 0 -Exactly
        Test-Path -LiteralPath $script:reports | Should -BeFalse
    }

    It 'rejects an invalid late <Header> CSV row before any connection or report creation' -ForEach @(
        @{ Header='ComputerName' }, @{ Header='Fqdn' }, @{ Header='Name' }
    ) {
        $csv = Join-Path $TestDrive 'bad-targets.csv'
        "$Header`r`nEX01.example.com`r`nEX*" | Set-Content -LiteralPath $csv -Encoding UTF8
        { Invoke-KBFleet -CsvPath $csv -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*CSV record 3*'
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
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
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'allows a quiet restart preview without connections or pretending recovery was attested' {
        $result = Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Quiet -WhatIf
        $result.Status | Should -Be 'NoChanges'
        $result.Servers | Should -Be 0
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
        Should -Invoke Read-Host -ModuleName KoreanRules -Times 0 -Exactly
    }

    It 'refuses unattended restart rollout before changing the first server' {
        Mock Get-KBElevationContext { [pscustomobject]@{ Remote=$false; Interactive=$false } } -ModuleName KoreanRules
        { Invoke-KBFleet -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -RestartSearch -MaintenanceWindowApproved -Confirm:$false } |
            Should -Throw '*local interactive console*'
        Should -Invoke New-PSSession -ModuleName KoreanRules -Times 0 -Exactly
        Test-Path -LiteralPath $script:reports | Should -BeFalse
    }

    It 'rejects duplicate physical machines reached through different aliases' {
        Mock Invoke-Command {
            [pscustomobject]@{ Path = 'C:\ProgramData\Fixture\shared'; ComputerName = 'ONE-MACHINE' }
        } -ModuleName KoreanRules -ParameterFilter { $ScriptBlock.ToString().Contains('WindowsPrincipal') }
        { Invoke-KBFleet -ComputerName EX01.example.com,Alias01.example.com -PackageDirectory $script:packageRoot `
            -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*same machine*'
        Should -Invoke Remove-PSSession -ModuleName KoreanRules -Times 2 -Exactly
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
        $result = & (Join-Path $script:legacyRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply `
            -ComputerName EX01.example.com -ReportDirectory 'C:\Fixture' -MaintenanceWindowApproved -Confirm:$false
        $result.Servers | Should -Be 1
        Should -Invoke Invoke-KBFleet -Times 1 -Exactly -ParameterFilter { $RestartSearch -and $MaintenanceWindowApproved -and $Mode -eq 'Apply' }
    }

    It 'does not request a restart for legacy Detect' {
        $null = & (Join-Path $script:legacyRoot 'Invoke-KB5130098Fleet.ps1') `
            -ComputerName EX01.example.com -ReportDirectory 'C:\Fixture' -Confirm:$false
        Should -Invoke Invoke-KBFleet -Times 1 -Exactly -ParameterFilter { -not $RestartSearch -and $Mode -eq 'Detect' }
    }
}
