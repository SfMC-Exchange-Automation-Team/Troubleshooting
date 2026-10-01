BeforeDiscovery {
    $packageRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $packageRoot 'KoreanRules.psm1') -Force
}

Describe 'Published identity contract' {
    It 'pins the exact Exchange build, DLL and both rule identities' {
        $spec = Get-KBSpecification
        $spec.ExchangeVersion | Should -Be '15.2.2562.49'
        $spec.Dll.Version | Should -Be '16.0.5194.1000'
        $spec.Dll.Bytes | Should -Be 326544
        $spec.Dll.SHA256 | Should -Be '1C6BD8E144BA677EBCC83323AE59DB3881918170F9B3A5189B44611558B92C61'
        $spec.Rules.Count | Should -Be 2
        $spec.Rules[0].Bytes | Should -Be 56132
        $spec.Rules[0].SHA256 | Should -Be '8F2BD853593913EB8F73DCD4FCAC4216F216A0FF76A4569DF071BE3C36773010'
        $spec.Rules[1].Bytes | Should -Be 717792
        $spec.Rules[1].SHA256 | Should -Be '0390D1E9A76EF33283025CF8F164430E311584B9535949C4EA1A74B6BB107B87'
        $spec.SqlPackage.Bytes | Should -Be 748772024
        $spec.SqlPackage.SHA256 | Should -Be '74AA90C11202A5524E769B9BC22531BAEF22D91E9B2D2E8C3CB99E89A65C5297'
    }
}

Describe 'Local deployment with isolated filesystem fixtures' {
    InModuleScope KoreanRules {
        BeforeAll {
            $script:realGetIdentity = ${function:Get-KBIdentity}
            $script:realCopyNew = ${function:Copy-KBRuleNew}
        }
        BeforeEach {
            $script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path (Get-Module KoreanRules).ModuleBase 'KoreanRules.psd1')
            $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:exchange = Join-Path $script:fixture 'Exchange'
            $script:native = Join-Path $script:exchange 'Bin\Search\Ceres\Native'
            $script:payload = Join-Path $script:fixture 'payload'
            $script:state = Join-Path $script:fixture 'state'
            $null = New-Item -Path $script:native -ItemType Directory -Force
            $null = New-Item -Path $script:payload -ItemType Directory -Force
            foreach ($rule in $script:Spec.Rules) {
                $path = Join-Path $script:payload $rule.Name
                "Fixture for $($rule.Name)" | Set-Content -LiteralPath $path -Encoding ASCII
                $rule.Bytes = (Get-Item -LiteralPath $path).Length
                $rule.SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
            Mock Assert-KBAdministrator {}
            Mock Get-KBExchangePath { $script:exchange }
            Mock Get-KBIdentity { & $script:realGetIdentity -Path $Path -ReadVersion:$ReadVersion }
            Mock Copy-KBRuleNew { & $script:realCopyNew -Source $Source -Destination $Destination }
            Mock Get-KBIdentity {
                [pscustomobject]@{ Version = $script:Spec.ExchangeVersion; Bytes = 1; SHA256 = 'fixture' }
            } -ParameterFilter { $Path -like '*\ExSetup.exe' }
            Mock Get-KBIdentity {
                [pscustomobject]@{ Version = $script:Spec.Dll.Version; Bytes = $script:Spec.Dll.Bytes; SHA256 = $script:Spec.Dll.SHA256 }
            } -ParameterFilter { $Path -like '*\korwbrkr.dll' }
            Mock Get-Service { [pscustomobject]@{ Status = 'Running'; DependentServices = @() } }
            Mock Restart-KBHostController { 12345 }
            Mock New-KBStateDirectory {
                $directory = Join-Path $Root ([guid]::NewGuid().ToString('N'))
                $null = New-Item -Path $directory -ItemType Directory -Force
                $directory
            }
        }

        AfterAll {
            $script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path (Get-Module KoreanRules).ModuleBase 'KoreanRules.psd1')
        }

        It 'detects eligibility without writing Exchange files, state or changing services' {
            $result = Invoke-KBLocal -Mode Detect
            $result.Status | Should -Be 'EligibleMissingBothRules'
            $result.Eligible | Should -BeTrue
            (Test-Path -LiteralPath $script:state) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 0
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'rejects a different build' {
            Mock Get-KBIdentity {
                [pscustomobject]@{ Version = '15.2.2562.46'; Bytes = 1; SHA256 = 'fixture' }
            } -ParameterFilter { $Path -like '*\ExSetup.exe' }
            (Invoke-KBLocal -Mode Detect).Status | Should -Be 'NotApplicableStop'
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state
            $result.Status | Should -Be 'NotApplicableStop'
            $result.ApplicabilityReason | Should -Match 'Exchange build: found 15.2.2562.46; required 15.2.2562.49'
            Should -Invoke Copy-KBRuleNew -Times 0 -Exactly
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
            Test-Path -LiteralPath $script:state | Should -BeFalse
        }

        It 'rejects a different installed DLL hash' {
            Mock Get-KBIdentity {
                [pscustomobject]@{ Version = $script:Spec.Dll.Version; Bytes = $script:Spec.Dll.Bytes; SHA256 = 'WRONG' }
            } -ParameterFilter { $Path -like '*\korwbrkr.dll' }
            (Invoke-KBLocal -Mode Detect).Status | Should -Be 'NotApplicableStop'
        }

        It 'rejects a different installed DLL size or version' {
            Mock Get-KBIdentity {
                [pscustomobject]@{ Version = '16.0.0.0'; Bytes = 10; SHA256 = $script:Spec.Dll.SHA256 }
            } -ParameterFilter { $Path -like '*\korwbrkr.dll' }
            (Invoke-KBLocal -Mode Detect).Status | Should -Be 'NotApplicableStop'
        }

        It 'refuses an existing rule without overwriting it' {
            $existing = Join-Path $script:native 'ko.token.rule.bin'
            'PREEXISTING' | Set-Content -LiteralPath $existing
            (Invoke-KBLocal -Mode Detect).Status | Should -Be 'RuleFilesPresentStop'
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state
            $result.Status | Should -Be 'RuleFilesPresentStop'
            $result.ApplicabilityReason | Should -Match 'partial existing rule set'
            Should -Invoke Copy-KBRuleNew -Times 0 -Exactly
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
            (Get-Content -LiteralPath $existing).Trim() | Should -Be 'PREEXISTING'
        }

        It 'refuses a corrupted staged rule before any Exchange writes' {
            'BAD' | Set-Content -LiteralPath (Join-Path $script:payload 'ko.complex.rule.bin')
            { Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false } | Should -Throw '*mismatch*'
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 0
        }

        It 'refuses a missing staged rule' {
            Remove-Item -LiteralPath (Join-Path $script:payload 'ko.complex.rule.bin')
            { Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false } | Should -Throw
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 0
        }

        It 'accepts an explicit restart without the legacy maintenance approval switch' {
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -Confirm:$false
            $result.Status | Should -Be 'RestartedWorkloadValidationRequired'
            Should -Invoke Restart-KBHostController -Times 1 -Exactly
        }

        It 'WhatIf performs preflight but writes nothing and never restarts' {
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -WhatIf
            $result.Status | Should -Be 'NoChanges'
            (Test-Path -LiteralPath $script:state) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 0
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'copies only two files without requiring Confirm false and records restart pending' {
            $ConfirmPreference = 'High'
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state
            $result.Status | Should -Be 'FilesStagedRestartRequired'
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 2
            Assert-KBPayload -Directory $script:native
            foreach ($rule in $script:Spec.Rules) {
                Assert-KBInheritedRead -Path (Join-Path $script:native $rule.Name)
            }
            $receipt = Get-Content -LiteralPath $result.ReceiptPath -Raw | ConvertFrom-Json
            $receipt.CreatedFiles.Count | Should -Be 2
            $receipt.OriginalRulesAbsent | Should -BeTrue
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'honors inherited WhatIf without creating files, state, or restarting' {
            $WhatIfPreference = $true
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state `
                -RestartSearch -MaintenanceWindowApproved -Confirm:$false
            $result.Status | Should -Be 'NoChanges'
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 0
            (Test-Path -LiteralPath $script:state) | Should -BeFalse
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'repeated Apply stops instead of overwriting or restarting' {
            $null = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -MaintenanceWindowApproved
            $result.Status | Should -Be 'RuleFilesPresentStop'
            $result.ApplicabilityReason | Should -Match 'Both rule files are already present'
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'never calls a startup observation workload recovery' {
            $result = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -MaintenanceWindowApproved -Confirm:$false
            $result.Status | Should -Be 'RestartedWorkloadValidationRequired'
            $result.WorkloadValidationRequired | Should -BeTrue
            Should -Invoke Restart-KBHostController -Times 1 -Exactly
        }

        It 'records partial copy failure and does not restart or silently undo it' {
            Mock Copy-KBRuleNew { throw 'injected copy failure' } -ParameterFilter { $Destination -like '*ko.complex.rule.bin' }
            $failure = $null
            try {
                $null = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -MaintenanceWindowApproved -Confirm:$false
            } catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -Match 'injected copy failure'
            (Test-Path -LiteralPath (Join-Path $script:native 'ko.token.rule.bin')) | Should -BeTrue
            $receiptPath = (Get-ChildItem -LiteralPath $script:state -Filter receipt.json -Recurse).FullName
            $failure.Exception.Data['KB5130098ReceiptPath'] | Should -Be $receiptPath
            @($failure.Exception.Data['KB5130098CreatedFiles']) | Should -Be @('ko.token.rule.bin')
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            $receipt.Status | Should -Be 'FailedStopAndContactSupport'
            $receipt.CreatedFiles.Count | Should -Be 1
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'stops before restart if inherited permissions cannot be confirmed' {
            Mock Assert-KBInheritedRead { throw 'injected ACL failure' }
            { Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*ACL failure*'
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'preserves verified files and records a restart failure' {
            Mock Restart-KBHostController { throw 'injected graceful-stop timeout' }
            { Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -RestartSearch -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*graceful-stop timeout*'
            Assert-KBPayload -Directory $script:native
            $receiptPath = (Get-ChildItem -LiteralPath $script:state -Filter receipt.json -Recurse).FullName
            (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).Status | Should -Be 'FailedStopAndContactSupport'
        }

        It 'refuses a stopped Host Controller without attempting to start it' {
            Mock Get-Service { [pscustomobject]@{ Status = 'Stopped'; DependentServices = @() } }
            { Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false } | Should -Throw '*must be Running*'
            Should -Invoke Restart-KBHostController -Times 0 -Exactly
        }

        It 'rollback still requires Support approval' {
            { Invoke-KBLocal -Mode Rollback -StateRoot $script:state -Confirm:$false } | Should -Throw '*Support approval*'
        }

        It 'rollback only removes the recorded exact files and preserves backups' {
            $apply = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false
            $rollback = Invoke-KBLocal -Mode Rollback -ReceiptPath $apply.ReceiptPath -StateRoot $script:state -MicrosoftSupportApprovedRollback -Confirm:$false
            $rollback.Status | Should -Be 'RolledBackRestartRequired'
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 0
            Assert-KBPayload -Directory $rollback.LogDirectory
        }

        It 'rollback refuses rules modified since deployment' {
            $apply = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false
            'Changed by another update' | Set-Content -LiteralPath (Join-Path $script:native 'ko.token.rule.bin')
            { Invoke-KBLocal -Mode Rollback -ReceiptPath $apply.ReceiptPath -StateRoot $script:state -MicrosoftSupportApprovedRollback -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*mismatch*'
            @(Get-ChildItem -LiteralPath $script:native -File).Count | Should -Be 2
        }

        It 'rollback refuses a receipt for another machine' {
            $apply = Invoke-KBLocal -Mode Apply -PayloadDirectory $script:payload -StateRoot $script:state -Confirm:$false
            $receipt = Get-Content -LiteralPath $apply.ReceiptPath -Raw | ConvertFrom-Json
            $receipt.ComputerName = 'NOT-THIS-SERVER'
            $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $apply.ReceiptPath
            { Invoke-KBLocal -Mode Rollback -ReceiptPath $apply.ReceiptPath -StateRoot $script:state -MicrosoftSupportApprovedRollback -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*Receipt*'
        }

        It 'CreateNew never overwrites a racing destination' {
            $target = Join-Path $script:native 'ko.token.rule.bin'
            'existing' | Set-Content -LiteralPath $target
            { Copy-KBRuleNew -Source (Join-Path $script:payload 'ko.token.rule.bin') -Destination $target } | Should -Throw
            (Get-Content -LiteralPath $target).Trim() | Should -Be 'existing'
        }

        It 'refuses F drive, relative and UNC write paths' {
            { Assert-KBLocalWritePath 'F:\dev\work' } | Should -Throw
            { Assert-KBLocalWritePath 'relative\work' } | Should -Throw
            { Assert-KBLocalWritePath '\\server\share\work' } | Should -Throw
        }
    }
}

Describe 'Correct ContentEngine process selection' {
    InModuleScope KoreanRules {
        It 'requires both exact executable and the ContentEngineNode1 noderoot argument' {
            Mock Get-CimInstance {
                @(
                    [pscustomobject]@{ ProcessId = 1; ExecutablePath = 'C:\Exchange\Bin\Search\Ceres\Runtime\1.0\ResourceProfile\contentengine\NodeRunner.exe'; CommandLine = '"NodeRunner.exe" --noderoot "C:\Exchange\Data\ContentEngineNode1"' }
                    [pscustomobject]@{ ProcessId = 2; ExecutablePath = 'C:\Other\NodeRunner.exe'; CommandLine = 'NodeRunner.exe --noderoot C:\Data\ContentEngineNode1' }
                    [pscustomobject]@{ ProcessId = 3; ExecutablePath = 'C:\Exchange\Bin\Search\Ceres\Runtime\1.0\ResourceProfile\contentengine\NodeRunner.exe'; CommandLine = 'NodeRunner.exe --noderoot C:\Data\ContentEngineNode10' }
                    [pscustomobject]@{ ProcessId = 4; ExecutablePath = 'C:\Exchange\Bin\Search\Ceres\Runtime\1.0\ResourceProfile\contentengine\NodeRunner.exe'; CommandLine = 'NodeRunner.exe --log C:\Data\ContentEngineNode1 --noderoot C:\Data\AdminNode1' }
                )
            }
            $ids = @(Get-KBContentEngine -ExchangePath 'C:\Exchange')
            $ids.Count | Should -Be 1
            $ids[0] | Should -Be 1
        }
    }

    Describe 'Graceful Search restart boundaries' {
        InModuleScope KoreanRules {
            BeforeEach {
                $script:serviceCalls = New-Object Collections.Generic.List[string]
                $script:fakeService = [pscustomobject]@{ Status = 'Running'; DependentServices = @() }
                $script:fakeService | Add-Member ScriptMethod Stop { $script:serviceCalls.Add('Stop') }
                $script:fakeService | Add-Member ScriptMethod Start { $script:serviceCalls.Add('Start') }
                $script:fakeService | Add-Member ScriptMethod Refresh {}
                $script:fakeService | Add-Member ScriptMethod WaitForStatus {
                    param($Status, $Timeout)
                    $script:serviceCalls.Add("Wait:$Status")
                    if ($Status -eq 'Stopped') { throw 'fixture stop timeout' }
                }
                Mock Get-Service { $script:fakeService }
            }

            It 'does not start a service that failed to stop normally' {
                { Restart-KBHostController -ExchangePath 'C:\Fixture' } | Should -Throw '*fixture stop timeout*'
                ($script:serviceCalls -join '|') | Should -Be 'Stop|Wait:Stopped'
            }

            It 'refuses to force-stop running dependent services' {
                $script:fakeService.DependentServices = @([pscustomobject]@{ Status = 'Running' })
                { Restart-KBHostController -ExchangePath 'C:\Fixture' } | Should -Throw '*dependent services*'
                $script:serviceCalls.Count | Should -Be 0
            }

            It 'stops observation if the selected process changes identity' {
                $script:fakeService | Add-Member ScriptMethod WaitForStatus {} -Force
                $script:queries = 0
                Mock Get-KBContentEngine {
                    $script:queries++
                    if ($script:queries -eq 1) { return 100 }
                    200
                }
                Mock Start-Sleep {}
                { Restart-KBHostController -ExchangePath 'C:\Fixture' } | Should -Throw '*exited/restarted*'
                ($script:serviceCalls -join '|') | Should -Be 'Stop|Start'
            }
        }
    }
}
