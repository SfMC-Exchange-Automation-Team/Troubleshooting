BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KoreanRules.psm1') -Force
}

Describe 'Korean Rules operator contracts' {
    BeforeAll { $script:packageRoot = Split-Path $PSScriptRoot -Parent }

    It 'exposes three distinct operator commands with appropriate parameters' {
        $get = Get-Command (Join-Path $script:packageRoot 'Get-KoreanRulesState.ps1')
        $set = Get-Command (Join-Path $script:packageRoot 'Set-KoreanRulesState.ps1')
        $install = Get-Command (Join-Path $script:packageRoot 'Install-KoreanRules.ps1')
        $get.Parameters.ContainsKey('Mode') | Should -BeFalse
        $get.Parameters.ContainsKey('RestartSearch') | Should -BeFalse
        $get.Parameters.ContainsKey('Rollback') | Should -BeFalse
        $get.Parameters.ContainsKey('CsvPath') | Should -BeTrue
        $set.Parameters.ContainsKey('Rollback') | Should -BeTrue
        $set.Parameters.ContainsKey('PayloadDirectory') | Should -BeTrue
        $install.Parameters.ContainsKey('Download') | Should -BeTrue
        @($install.Parameters['OutputDirectory'].Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 0
        @($install.Parameters['ManagementWorkstationConfirmed'].Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count | Should -Be 0
    }
}

Describe 'Actionable installation-payload preflight' {
    InModuleScope KoreanRules {
        BeforeEach {
            $script:missingPayload = Join-Path $TestDrive ('missing payload ' + [guid]::NewGuid().ToString('N'))
            Mock Assert-KBIdentity {}
        }

        It 'lists both missing source files and the preparation or override options' {
            $failure = $null
            try { Assert-KBPayload -Directory $script:missingPayload } catch { $failure=$_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -Match ([regex]::Escape($script:missingPayload))
            $failure.Exception.Message | Should -Match 'ko\.token\.rule\.bin'
            $failure.Exception.Message | Should -Match 'ko\.complex\.rule\.bin'
            $failure.Exception.Message | Should -Match 'REQUIRED INSTALLATION FILES MISSING'
            $failure.Exception.Message | Should -Match 'Install-KoreanRules\.ps1 -Download'
            $failure.Exception.Message | Should -Match '-SqlPackagePath / -RuleSourceDirectory'
            $failure.Exception.Message | Should -Match 'returned PayloadDirectory'
            $failure.Exception.Message | Should -Match 'calling computer'
            $failure.Exception.Message | Should -Match 'Detection does not require'
            Should -Invoke Assert-KBIdentity -Times 0 -Exactly
        }

        It 'identifies only the missing file in a partial payload' {
            $null = New-Item -Path $script:missingPayload -ItemType Directory
            'Fixture only' | Set-Content -LiteralPath (Join-Path $script:missingPayload 'ko.token.rule.bin')
            { Assert-KBPayload -Directory $script:missingPayload } |
                Should -Throw '*Missing file(s):*ko.complex.rule.bin*'
            Should -Invoke Assert-KBIdentity -Times 0 -Exactly
        }

        It 'keeps installed-file failure guidance distinct from preparing source media' {
            $failure = $null
            try { Assert-KBPayload -Directory $script:missingPayload -Installed } catch { $failure=$_ }
            $failure.Exception.Message | Should -Match 'Installed Korean Rules files are missing'
            $failure.Exception.Message | Should -Match 'retain the operation receipt'
            $failure.Exception.Message | Should -Not -Match 'Install-KoreanRules|Download'
        }

        It 'still verifies both identities when every file exists' {
            $null = New-Item -Path $script:missingPayload -ItemType Directory
            foreach ($name in @('ko.token.rule.bin','ko.complex.rule.bin')) {
                'Fixture only' | Set-Content -LiteralPath (Join-Path $script:missingPayload $name)
            }
            Assert-KBPayload -Directory $script:missingPayload
            Should -Invoke Assert-KBIdentity -Times 2 -Exactly
        }

        It 'fails remote Apply before any connection or report creation when payload is missing' {
            Mock New-PSSession { throw 'No target should be contacted.' }
            $reports = Join-Path $TestDrive 'no-preflight-reports'
            { Invoke-KBFleet -ComputerName example.invalid -Mode Apply -PackageDirectory (Get-Module KoreanRules).ModuleBase `
                -PayloadDirectory $script:missingPayload -ReportDirectory $reports -Quiet } |
                Should -Throw '*installation payload is missing*'
            Should -Invoke New-PSSession -Times 0 -Exactly
            Test-Path -LiteralPath $reports | Should -BeFalse
        }
    }
}

Describe 'Human summary size boundary' {
    InModuleScope KoreanRules {
        BeforeEach {
            Mock Write-Host {}
            Mock Format-Table {}
            Mock Out-Host {}
        }
        It 'uses the expected summary columns for <Count> targets' -ForEach @(
            @{ Count=3; Compact=$false }, @{ Count=4; Compact=$true }
        ) {
            $rows = @(1..$Count | ForEach-Object {
                [pscustomobject]@{ComputerName="EX$_";Mode='Detect';Status='EligibleMissingBothRules';ActionTaken='No changes';TokenRule='Missing';ComplexRule='Missing'}
            })
            Write-KBReportSummary -Rows $rows
            if ($Compact) {
                Should -Invoke Format-Table -Times 1 -Exactly -ParameterFilter {
                    ($Property -join ',') -eq 'Status,Count' -and -not $Wrap
                }
                Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { [string]$Object -like 'Compact summary*' }
            } else {
                Should -Invoke Format-Table -Times $Count -Exactly -ParameterFilter {
                    ($Property -join ',') -eq 'ComputerName,Mode,Status,ActionTaken' -and $Wrap
                }
            }
        }
    }
}
