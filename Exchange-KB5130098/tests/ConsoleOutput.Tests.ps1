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

        It 'explains an inapplicable identity and colors it yellow without implying a failure' {
            $ineligible = [pscustomobject]@{
                Status='NotApplicableStop'
                ExchangeVersion='15.2.2562.46'
                DllVersion='16.0.5194.1000'
                ExistingRules=@()
            }
            Write-KBConsoleResult -Mode Detect -Result $ineligible -Before $ineligible -After $ineligible
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Not applicable' -and $ForegroundColor -eq 'Yellow'
            }
            Should -Invoke Write-Host -Times 2 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Missing' -and $ForegroundColor -eq 'Yellow'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                ([string]$Object).Trim() -eq 'Missing' -and $ForegroundColor -eq 'Green'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -match 'Exchange build: found 15.2.2562.46; required 15.2.2562.49' -and $ForegroundColor -eq 'Yellow'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $ForegroundColor -eq 'Red' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { [string]$Object -match 'Microsoft Support' }
        }

        It 'shows existing-rule Apply as a yellow skip, not a red failure or recovery claim' {
            Write-KBConsoleResult -Mode Apply -Before $script:afterState -After $script:afterState -Result $script:afterState
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -like '*SKIPPED: Rule files already present*' -and $ForegroundColor -eq 'Yellow'
            }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -like '*Both rule files are already present*Presence alone does not verify*'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $ForegroundColor -eq 'Red' }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { [string]$Object -match 'Microsoft Support' }
        }

        It 'gives ordinary preflight errors an operator action rather than blanket escalation' {
            Write-KBConsoleResult -Mode Apply -ErrorMessage 'Payload is missing.'
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { [string]$Object -match 'Microsoft Support' }
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { [string]$Object -like '*Correct the reported input*' }
        }

        It 'retains qualified recovery escalation for an incomplete modifying operation' {
            Write-KBConsoleResult -Mode Apply -ErrorMessage 'Partial copy failed.' -Result ([pscustomobject]@{Status='FailedStopAndContactSupport';ReceiptPath='C:\Fixture\receipt.json'})
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { [string]$Object -like '*involve Microsoft Support if recovery is unclear*' }
        }

        It 'shows only mismatched build and DLL versions on separate console lines' {
            $state = [pscustomobject]@{
                Status='NotApplicableStop';ExchangeVersion='15.2.2562.46'
                DllVersion='16.0.5056.1000';DllBytes=251232
                DllSHA256='6BF643CEB094B50803423FB73F15BEE02C5CD30C981117E1DBDCDADD9864F26C'
                ExistingRules=@()
            }
            Write-KBConsoleResult -Mode Detect -Result $state -Before $state -After $state
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                [string]$Object -ceq ('  Exchange build: found 15.2.2562.46; required 15.2.2562.49' +
                    [Environment]::NewLine + '  Korean DLL version: found 16.0.5056.1000; required 16.0.5194.1000') -and
                $ForegroundColor -eq 'Yellow'
            }
            Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter {
                [string]$Object -match 'SHA256|size \(bytes\)|251232|326544|6BF643CE'
            }
        }

        It 'retains a clear console skip reason for a size-only or hash-only mismatch' -ForEach @(
            @{ Bytes=99; Hash='1C6BD8E144BA677EBCC83323AE59DB3881918170F9B3A5189B44611558B92C61' }
            @{ Bytes=326544; Hash='WRONG' }
        ) {
            $state = [pscustomobject]@{Status='NotApplicableStop';ExchangeVersion=$script:Spec.ExchangeVersion;DllVersion=$script:Spec.Dll.Version;DllBytes=$Bytes;DllSHA256=$Hash}
            Get-KBApplicabilityReason $state -ForConsole | Should -Be 'The installation does not match the required Exchange/DLL identity; inspect the detailed detection report.'
            Get-KBApplicabilityReason $state | Should -Match 'Korean DLL (size|SHA256)'
        }

        It 'includes actual and required DLL version size and SHA256 mismatches in reports' {
            $state = [pscustomobject]@{Status='NotApplicableStop';ExchangeVersion='15.2.2562.49';DllVersion='16.0.0.0';DllBytes=99;DllSHA256='WRONG';ExistingRules=@()}
            $reason = Get-KBApplicabilityReason $state
            $reason | Should -Match 'Korean DLL version: found 16.0.0.0; required 16.0.5194.1000'
            $reason | Should -Match 'size \(bytes\): found 99; required 326544'
            $reason | Should -Match ('SHA256: found WRONG; required ' + $script:Spec.Dll.SHA256)
            $reason | Should -Not -Match 'Exchange build:'
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
