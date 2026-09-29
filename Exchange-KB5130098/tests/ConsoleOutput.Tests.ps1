BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KoreanRules.psm1') -Force
}

Describe 'Console status columns and contextual colors' {
    InModuleScope KoreanRules {
        BeforeEach {
            $script:beforeState = [pscustomobject]@{
                Status = 'EligibleMissingBothRules'
                ExchangeVersion = '15.2.2562.49'
                DllVersion = '16.0.5194.1000'
                ExistingRules = @()
            }
            $script:afterState = [pscustomobject]@{
                Status = 'RuleFilesPresentStop'
                ExchangeVersion = '15.2.2562.49'
                DllVersion = '16.0.5194.1000'
                ExistingRules = @('ko.token.rule.bin', 'ko.complex.rule.bin')
            }
            Mock Write-Host {}
        }

        It 'uses one status column and green Present values for <Target>' -ForEach @(
            @{ Target = 'EX01' }
            @{ Target = 'EX02.example.com' }
        ) {
            Write-KBConsoleResult -Mode Detect -ComputerName $Target -Result $script:afterState `
                -Before $script:afterState -After $script:afterState
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -match '^CHECK\s+STATUS$'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                [string]$Object -match '\bBEFORE\b|\bCURRENT\b'
            }
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Present' -and $ForegroundColor -eq 'Green'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Yes' -and $ForegroundColor -eq 'Green'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -eq "Korean Rules | DETECT | $Target"
            }
        }

        It 'retains Apply comparison columns and colors the resulting Present values green' {
            Write-KBConsoleResult -Mode Apply -Before $script:beforeState -After $script:afterState `
                -Result ([pscustomobject]@{ Status='FilesStagedRestartRequired' })
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -match '^CHECK\s+BEFORE\s+CURRENT$'
            }
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Missing' -and $NoNewline -and $ForegroundColor -eq 'Green'
            }
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Present' -and $ForegroundColor -eq 'Green'
            }
        }

        It 'colors an identity stop red and missing rules yellow instead of green' {
            $ineligible = [pscustomobject]@{
                Status='NotApplicableStop'
                ExchangeVersion='15.2.2562.46'
                DllVersion='16.0.5194.1000'
                ExistingRules=@()
            }
            Write-KBConsoleResult -Mode Detect -Result $ineligible -Before $ineligible -After $ineligible
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'No - stop' -and $ForegroundColor -eq 'Red'
            }
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Missing' -and $ForegroundColor -eq 'Yellow'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Missing' -and $ForegroundColor -eq 'Green'
            }
        }

        It 'colors Present in both Apply columns while keeping the existing-file stop warning' {
            Write-KBConsoleResult -Mode Apply -Before $script:afterState -After $script:afterState `
                -ErrorMessage 'Existing rules prevent this Apply.'
            Should -Invoke Write-Host -Times 4 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Present' -and $ForegroundColor -eq 'Green'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -match 'STOPPED: Existing rules' -and $ForegroundColor -eq 'Red'
            }
        }

        It 'colors missing rules green when the pinned identity matches' {
            Write-KBConsoleResult -Mode Detect -Result $script:beforeState -Before $script:beforeState -After $script:beforeState
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Missing' -and $ForegroundColor -eq 'Green'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Yes' -and $ForegroundColor -eq 'Green'
            }
        }

        It 'leaves unobserved values neutral when the installation could not be inspected' {
            Write-KBConsoleResult -Mode Detect -ErrorMessage 'The installation could not be inspected.'
            Should -Invoke Write-Host -Times 5 -Exactly -ParameterFilter {
                [string]$Object -eq 'Not observed' -and $null -eq $ForegroundColor
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                [string]$Object -eq 'Not observed' -and $ForegroundColor -eq 'Green'
            }
        }

        It 'shows rollback resulting state without comparison columns' {
            Write-KBConsoleResult -Mode Rollback -Before $script:afterState -After $script:beforeState `
                -Result ([pscustomobject]@{ Status='RolledBackRestartRequired' })
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { [string]$Object -match '^CHECK\s+STATUS$' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { [string]$Object -match '\bBEFORE\b|\bCURRENT\b' }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { [string]$Object -match 'Backed up and removed' }
        }
    }
}
