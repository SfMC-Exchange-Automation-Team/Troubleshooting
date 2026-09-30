BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KoreanRules.psm1') -Force
}

Describe 'Typed result rows and portable default exports' {
    InModuleScope KoreanRules {
        BeforeEach {
            $script:context = New-KBReportContext -ReportDirectory (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            $script:state = [pscustomobject]@{
                Status='RuleFilesPresentStop'
                ExchangeVersion='15.2.2562.49'
                DllVersion='16.0.5194.1000'
                DllSHA256='fixture-hash'
                ExistingRules=@('ko.token.rule.bin','ko.complex.rule.bin')
            }
            $script:record = [ordered]@{
                Target='EX01.example.com'; Mode='Detect'; Status='RuleFilesPresentStop'
                UTC='2026-09-28T15:00:00.000Z'; RestartSearch=$false
                Detection=$script:state; Current=$script:state; Result=$null
                RecoveryAttestation=$null; Error=$null; ObservationError=$null
            }
        }

        It 'creates flat typed rows with stable metadata rather than formatted text' {
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId `
                -TimestampUtc '2026-09-28T15:01:02.123Z' -DetailReportPath $script:context.JsonPath)
            $rows.Count | Should -Be 1
            $rows[0].SchemaVersion | Should -Be 1
            $rows[0].TimestampUtc | Should -Be '2026-09-28T15:01:02.123Z'
            $rows[0].RunId | Should -Be $script:context.RunId
            $rows[0].ComputerName | Should -Be 'EX01.example.com'
            $rows[0].RestartRequested | Should -BeOfType bool
            $rows[0].RestartCompleted | Should -BeFalse
            $rows[0].RecoveryAttested | Should -BeFalse
            $rows[0].WorkloadValidationRequired | Should -BeNullOrEmpty
            $rows[0].TokenRule | Should -Be 'Present'
            $rows[0].ActionTaken | Should -Be 'Detection only; no Exchange changes'
            @($rows[0].PSObject.Properties | Where-Object {
                $null -ne $_.Value -and $_.Value -isnot [ValueType] -and $_.Value -isnot [string]
            }).Count | Should -Be 0
        }

        It 'exports CSV, full detail JSON and one compact JSON object per result line' {
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId)
            $files = Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows
            $csv = @(Import-Csv -LiteralPath $files.Csv)
            $csv.Count | Should -Be 1
            $csv[0].ComputerName | Should -Be 'EX01.example.com'
            $csv[0].TokenRule | Should -Be 'Present'
            $detail = [IO.File]::ReadAllText($files.Json) | ConvertFrom-Json
            @($detail).Count | Should -Be 1
            $detail[0].Current.DllSHA256 | Should -Be 'fixture-hash'
            $lines = [IO.File]::ReadAllLines($files.JsonLines)
            $lines.Count | Should -Be 1
            $event = $lines[0] | ConvertFrom-Json
            $event.RestartRequested | Should -BeOfType bool
            $event.ComputerName | Should -Be $csv[0].ComputerName
            $bytes = [IO.File]::ReadAllBytes($files.JsonLines)
            $bytes[0] | Should -Be ([byte][char]'{')
            $event.TimestampUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
        }

        It 'round-trips quotes, commas, newlines and Korean text without splitting JSON events' {
            $korean = -join [char[]]@(0xD55C,0xAD6D,0xC5B4)
            $message = "Example, `"$korean`"`r`nSecond line"
            $script:record.Error = $message
            $script:record.Status = 'FailedStop'
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId)
            $files = Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows
            (Import-Csv -LiteralPath $files.Csv).Error | Should -Be $message
            $lines = [IO.File]::ReadAllLines($files.JsonLines)
            $lines.Count | Should -Be 1
            ($lines[0] | ConvertFrom-Json).Error | Should -Be $message
        }

        It 'makes spreadsheet-leading text inert while preserving the original JSON value' -ForEach @(
            @{ Text = '=1+1' }, @{ Text = '+1+1' }, @{ Text = '-1+1' }, @{ Text = '@SUM(1,1)' }
        ) {
            $script:record.Error = $Text
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId)
            $files = Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows
            (Import-Csv -LiteralPath $files.Csv).Error | Should -Be ("'" + $Text)
            ([IO.File]::ReadAllText($files.JsonLines) | ConvertFrom-Json).Error | Should -Be $Text
            $rows[0].Error | Should -Be $Text
        }

        It 'does not confuse a staged or restarted operation with validated workload recovery' {
            $script:record.Mode = 'Apply'
            $script:record.Status = 'RestartedWorkloadValidationRequired'
            $script:record.RestartSearch = $true
            $script:record.Result = [pscustomobject]@{
                Status='RestartedWorkloadValidationRequired'
                ReceiptPath='C:\Fixture\receipt.json'
                WorkloadValidationRequired=$true
            }
            $row = ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId
            $row.RestartCompleted | Should -BeTrue
            $row.ApplicabilityReason | Should -Not -Match 'No .*services restarted'
            $row.WorkloadValidationRequired | Should -BeTrue
            $row.RecoveryAttested | Should -BeFalse
            $row.ReceiptPath | Should -Be 'C:\Fixture\receipt.json'
            $script:record.RecoveryAttestation = [pscustomobject]@{ Statement='RECOVERED EX01.example.com' }
            (ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId).RecoveryAttested | Should -BeTrue
        }

        It 'retains unvisited targets as NotRun with unobserved state' {
            $pending = [ordered]@{ Target='EX02.example.com'; Mode='Apply'; Status='NotRun'; RestartSearch=$true }
            $script:record.Status = 'FailedStop'
            $script:record.Error = 'Injected failure'
            $rows = @(ConvertTo-KBReportRows -Records @($script:record,$pending) -RunId $script:context.RunId)
            $files = Save-KBReportExports -Context $script:context -Records @($script:record,$pending) -Rows $rows
            $rows.Count | Should -Be 2
            $rows[1].Status | Should -Be 'NotRun'
            $rows[1].ActionTaken | Should -Be 'Not contacted'
            $rows[1].TokenRule | Should -Be 'Not observed'
            $rows[1].RestartCompleted | Should -BeFalse
            [IO.File]::ReadAllLines($files.JsonLines).Count | Should -Be 2
            @(Import-Csv -LiteralPath $files.Csv).ComputerName | Should -Be @('EX01.example.com','EX02.example.com')
        }

        It 'does not write exports in a preview context' {
            $root = Join-Path $TestDrive 'preview-only'
            $context = New-KBReportContext -ReportDirectory $root -NoWrite
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $context.RunId)
            $files = Save-KBReportExports -Context $context -Records @($script:record) -Rows $rows
            $files.Json | Should -BeNullOrEmpty
            $files.Csv | Should -BeNullOrEmpty
            $files.JsonLines | Should -BeNullOrEmpty
            Test-Path -LiteralPath $root | Should -BeFalse
        }

        It 'omits only CSV with NoCsv while retaining both JSON representations' {
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId)
            $files = Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows -NoCsv
            $files.Csv | Should -BeNullOrEmpty
            Test-Path -LiteralPath $files.Json | Should -BeTrue
            Test-Path -LiteralPath $files.JsonLines | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:context.Directory 'results.csv') | Should -BeFalse
        }

        It 'refuses to rewrite finalized JSON Lines so file monitors do not reingest checkpoints' {
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId)
            $files = Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows
            $hash = (Get-FileHash -LiteralPath $files.JsonLines).Hash
            { Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows } |
                Should -Throw '*Final result exports already exist*'
            (Get-FileHash -LiteralPath $files.JsonLines).Hash | Should -Be $hash
        }

        It 'surfaces a CSV write failure and retains typed rows plus any completed detail file' {
            Mock Export-Csv { throw 'Injected CSV write failure' }
            $rows = @(ConvertTo-KBReportRows -Records @($script:record) -RunId $script:context.RunId)
            $failure = $null
            try { $null = Save-KBReportExports -Context $script:context -Records @($script:record) -Rows $rows }
            catch { $failure = $_ }
            $failure.Exception.Message | Should -Be 'Injected CSV write failure'
            @($failure.Exception.Data['KB5130098ReportRows']).Count | Should -Be 1
            $files = $failure.Exception.Data['KB5130098ReportFiles']
            Test-Path -LiteralPath $files.Json | Should -BeTrue
            $files.Csv | Should -BeNullOrEmpty
            $files.JsonLines | Should -BeNullOrEmpty
        }

        It 'refuses records missing required identity instead of generating success-shaped empty rows' {
            { ConvertTo-KBReportRows -Records @([pscustomobject]@{Mode='Detect';Status='Completed'}) -RunId 'fixture' } |
                Should -Throw '*missing Target*'
        }
    }
}

Describe 'Protected elevation report handoff' {
    InModuleScope KoreanRules {
        It 'restricts its temporary directory and prevents replacing the reserved file' {
            $relay = New-KBReportRelay
            try {
                $acl = Get-Acl -LiteralPath $relay.Directory
                $acl.AreAccessRulesProtected | Should -BeTrue
                $rules = @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
                $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
                @($rules | Where-Object { $_.IdentityReference.Value -notin $allowed }).Count | Should -Be 0
                { [IO.File]::Delete($relay.Path) } | Should -Throw
                { Read-KBReportRelay -Relay $relay -ExpectedExitCode 0 } | Should -Throw '*missing or invalid*'
            } finally { Remove-KBReportRelay $relay }
            Test-Path -LiteralPath $relay.Directory | Should -BeFalse
        }

        It 'rejects a handoff for a different exit code rather than trusting mismatched output' {
            $relay = New-KBReportRelay
            try {
                $packet = @{ Schema=1; ExitCode=20; ReportData=@([pscustomobject]@{ComputerName='Fixture'}); ExportFiles=$null }
                $bytes = [Text.Encoding]::UTF8.GetBytes([System.Management.Automation.PSSerializer]::Serialize($packet))
                $relay.Stream.Write($bytes,0,$bytes.Length)
                $relay.Stream.Flush($true)
                { Read-KBReportRelay -Relay $relay -ExpectedExitCode 0 } | Should -Throw '*does not match*'
            } finally { Remove-KBReportRelay $relay }
        }

        It 'does not accept a successful child exit with a null report payload' {
            $relay = New-KBReportRelay
            try {
                $packet = @{ Schema=1; ExitCode=0; ReportData=$null; ExportFiles=$null }
                $bytes = [Text.Encoding]::UTF8.GetBytes([System.Management.Automation.PSSerializer]::Serialize($packet))
                $relay.Stream.Write($bytes,0,$bytes.Length)
                $relay.Stream.Flush($true)
                { Read-KBReportRelay -Relay $relay -ExpectedExitCode 0 } | Should -Throw '*no report data*'
            } finally { Remove-KBReportRelay $relay }
        }
    }
}
