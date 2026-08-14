#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Parsing.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Resilience.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Diagnostics.ps1')
}

Describe 'Get-MFAReportAssistantClassification' {

    Context 'regression: v0.10 matched on element NAMES in the raw log' {

        It 'does not report throttling when ResourceUnhealthy is False' {
            # The v0.10 regex 'ResourceUnhealthy|throttl|WorkCycleLag|...' matched
            # the literal tag name, so this exact payload classified as throttled.
            $raw = '<ResourceUnhealthy>False</ResourceUnhealthy><WorkCycleLag>00:00:00</WorkCycleLag>'
            $unhealthy = ConvertTo-MFAReportBoolean -Value (Select-MFAReportRegexFlag -Text $raw -Name 'ResourceUnhealthy')
            $lag = ConvertTo-MFAReportTimeSpan -Value (Select-MFAReportRegexFlag -Text $raw -Name 'WorkCycleLag')

            Get-MFAReportAssistantClassification `
                -IsResourceUnhealthy $unhealthy `
                -WorkCycleLag $lag `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'Assistant diagnostics collected'
        }

        It 'does report throttling when ResourceUnhealthy is genuinely True' {
            Get-MFAReportAssistantClassification `
                -IsResourceUnhealthy $true `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'MFA running but throttled or resource unhealthy'
        }

        It 'does not report a delay hold when the flag is a timestamp containing 1' {
            $applied = ConvertTo-MFAReportBoolean -Value '01/01/2024'
            Get-MFAReportAssistantClassification `
                -IsDelayHoldApplied $applied `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'Assistant diagnostics collected'
        }

        It 'does report a delay hold when the flag is genuinely True' {
            Get-MFAReportAssistantClassification `
                -IsDelayHoldApplied $true `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'Delay hold / hold cleanup issue'
        }
    }

    Context 'WorkCycleLag is not a classifier without an explicit baseline' {

        It 'ignores a non-zero lag when no threshold is supplied' {
            Get-MFAReportAssistantClassification `
                -WorkCycleLag ([TimeSpan]::FromHours(6)) `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'Assistant diagnostics collected'
        }

        It 'uses the lag once a threshold is supplied' {
            Get-MFAReportAssistantClassification `
                -WorkCycleLag ([TimeSpan]::FromHours(6)) `
                -WorkCycleLagThreshold ([TimeSpan]::FromHours(1)) `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'MFA running but throttled or resource unhealthy'
        }
    }

    Context 'backlog' {
        It 'treats a zero backlog as healthy' {
            Get-MFAReportAssistantClassification `
                -StoreMaintenanceBacklogCount 0 `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'Assistant diagnostics collected'
        }

        It 'treats a positive backlog as a problem' {
            Get-MFAReportAssistantClassification `
                -StoreMaintenanceBacklogCount 42 `
                -ElcLastSuccessTimestamp '2026-07-01T00:00:00Z' |
                Should -Be 'MFA running but throttled or resource unhealthy'
        }
    }

    It 'reports unknown execution status when no success timestamp was parsed' {
        Get-MFAReportAssistantClassification -ElcLastSuccessTimestamp '' |
            Should -Be 'MFA execution status unknown'
    }
}

Describe 'Get-MFAReportRecoverableItemsSize' {

    BeforeAll {
        # FolderAndSubfolderSize is cumulative: the root already contains the
        # children. v0.10 concatenated all of these and summed every byte value
        # it found, so this fixture reported 30 MB instead of 20 MB.
        $script:NestedFolders = @(
            [PSCustomObject]@{
                FolderPath              = '/Recoverable Items'
                FolderSize              = '2.0 MB (2,097,152 bytes)'
                FolderAndSubfolderSize  = '20.0 MB (20,971,520 bytes)'
            }
            [PSCustomObject]@{
                FolderPath              = '/Recoverable Items/Deletions'
                FolderSize              = '12.0 MB (12,582,912 bytes)'
                FolderAndSubfolderSize  = '12.0 MB (12,582,912 bytes)'
            }
            [PSCustomObject]@{
                FolderPath              = '/Recoverable Items/Purges'
                FolderSize              = '6.0 MB (6,291,456 bytes)'
                FolderAndSubfolderSize  = '6.0 MB (6,291,456 bytes)'
            }
        )
    }

    It 'uses the root cumulative size rather than summing the hierarchy' {
        Get-MFAReportRecoverableItemsSize -Folders $script:NestedFolders | Should -Be 20971520
    }

    It 'does not inflate the total by the depth of the hierarchy' {
        $summedAll = 20971520 + 12582912 + 6291456
        Get-MFAReportRecoverableItemsSize -Folders $script:NestedFolders | Should -Not -Be $summedAll
    }

    It 'falls back to summing non-cumulative FolderSize when the root has no cumulative size' {
        $folders = @(
            [PSCustomObject]@{ FolderPath = '/Recoverable Items';           FolderSize = '2.0 MB (2,097,152 bytes)';  FolderAndSubfolderSize = 'Unlimited' }
            [PSCustomObject]@{ FolderPath = '/Recoverable Items/Deletions'; FolderSize = '3.0 MB (3,145,728 bytes)';  FolderAndSubfolderSize = 'Unlimited' }
        )
        Get-MFAReportRecoverableItemsSize -Folders $folders | Should -Be (2097152 + 3145728)
    }

    It 'returns null for an empty folder set' {
        Get-MFAReportRecoverableItemsSize -Folders @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-MFAReportParseConfidence' {

    It 'reports High when at least four signals parsed' {
        Get-MFAReportParseConfidence -Values @('a', 'b', 'c', 'd', $null) | Should -Be 'High'
    }

    It 'reports Medium for a partial parse' {
        Get-MFAReportParseConfidence -Values @('a', $null, '', $null) | Should -Be 'Medium'
    }

    It 'reports Low when nothing parsed' {
        Get-MFAReportParseConfidence -Values @($null, '', '   ') | Should -Be 'Low'
    }
}

Describe 'Get-MFAReportFolderEvidence' {

    Context 'regression: member access on an empty collection under StrictMode' {

        BeforeEach {
            Set-StrictMode -Version 3.0
        }

        It 'summarises a mailbox where no folder carries an oldest-item date' {
            # StrictMode 3.0 treats $empty.SomeProperty as a missing property, so
            # interpolating the filtered result directly threw. The catch block
            # then reported PrimaryFolderStatsFailed -- blaming Exchange for a
            # local bug and discarding TaggedFolderDetails entirely.
            function global:Get-MailboxFolderStatistics {
                param($Identity, [switch]$IncludeOldestAndNewestItems, $FolderScope)
                if ($FolderScope -eq 'RecoverableItems') { return @() }
                @([PSCustomObject]@{
                    Name = 'Inbox'; FolderPath = '/Inbox'; ItemsInFolder = 0
                    OldestItemReceivedDate = $null; OldestItemLastModifiedDate = $null
                    ArchivePolicy = 'Archive 2y'; DeletePolicy = $null
                    CompliancePolicy = $null; RetentionFlags = $null
                })
            }
            try {
                $evidence = Get-MFAReportFolderEvidence -Identity 'user@contoso.com'

                $evidence.Summary | Should -Not -Match 'PrimaryFolderStatsFailed'
                $evidence.Summary | Should -Match 'Folders=1'
                $evidence.Summary | Should -Match 'TaggedFolders=1'
                # The tagged-folder detail is the point of -IncludeFolderEvidence
                # and used to be lost with the throw.
                @($evidence.TaggedFolderDetails).Count | Should -Be 1
            }
            finally { Remove-Item function:global:Get-MailboxFolderStatistics -ErrorAction SilentlyContinue }
        }

        It 'still reports the oldest dates when folders carry them' {
            function global:Get-MailboxFolderStatistics {
                param($Identity, [switch]$IncludeOldestAndNewestItems, $FolderScope)
                if ($FolderScope -eq 'RecoverableItems') { return @() }
                @([PSCustomObject]@{
                    Name = 'Inbox'; FolderPath = '/Inbox'; ItemsInFolder = 5
                    OldestItemReceivedDate = [datetime]'2020-01-01'
                    OldestItemLastModifiedDate = [datetime]'2020-01-02'
                    ArchivePolicy = $null; DeletePolicy = $null
                    CompliancePolicy = $null; RetentionFlags = $null
                })
            }
            try {
                $evidence = Get-MFAReportFolderEvidence -Identity 'user@contoso.com'
                $evidence.Summary | Should -Match 'OldestReceived=.*2020'
                $evidence.Summary | Should -Match 'OldestModified=.*2020'
            }
            finally { Remove-Item function:global:Get-MailboxFolderStatistics -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Get-MFAReportDiagnosticSignals' {

    Context 'a terminal primary failure must not cost four round-trips' {

        BeforeEach {
            $global:MFADiagCalls = [System.Collections.Generic.List[string]]::new()
        }

        AfterEach {
            Remove-Item function:global:Export-MailboxDiagnosticLogs -ErrorAction SilentlyContinue
            Remove-Item variable:global:MFADiagCalls -ErrorAction SilentlyContinue
        }

        It 'skips the hold-tracking components when the primary collection failed terminally' {
            function global:Export-MailboxDiagnosticLogs {
                param($Identity, [switch]$ExtendedProperties, $ComponentName, $ErrorAction)
                $global:MFADiagCalls.Add($(if ($ExtendedProperties) { 'ExtendedProperties' } else { [string]$ComponentName }))
                throw 'Access to the requested object was denied.'
            }

            $signals = Get-MFAReportDiagnosticSignals -Identity 'user@contoso.com'

            $signals.Status | Should -Be 'CollectionFailed'
            $global:MFADiagCalls | Should -Not -Contain 'HoldTracking'
            $global:MFADiagCalls | Should -Not -Contain 'SubstrateHoldTracking'
            $signals.HoldTrackingSummary | Should -Be 'NotCollected:PrimaryDiagnosticCollectionFailed'
        }

        It 'still attempts them when the primary failure was transient' {
            # A throttle says nothing about whether these components are readable,
            # so short-circuiting on it would discard evidence unnecessarily.
            function global:Export-MailboxDiagnosticLogs {
                param($Identity, [switch]$ExtendedProperties, $ComponentName, $ErrorAction)
                $global:MFADiagCalls.Add($(if ($ExtendedProperties) { 'ExtendedProperties' } else { [string]$ComponentName }))
                throw 'The server is busy. Please try again.'
            }

            $signals = Get-MFAReportDiagnosticSignals -Identity 'user@contoso.com'

            $signals.Status | Should -Be 'CollectionFailed'
            $global:MFADiagCalls | Should -Contain 'HoldTracking'
            $global:MFADiagCalls | Should -Contain 'SubstrateHoldTracking'
        }
    }
}
