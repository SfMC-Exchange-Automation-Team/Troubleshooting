#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Parsing.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Analysis.ps1')
}

Describe 'Get-MFAReportDiagnosticClassification' {

    Context 'regression: NoEligibleItems was concluded from unmeasured data' {

        It 'does not claim NoEligibleItems when movement was never measured' {
            # This is the multi-mailbox path. v0.10 left the movement counters at
            # zero, so NoMovementDetected was vacuously true and every mailbox
            # was reported as having no eligible items.
            $result = Get-MFAReportDiagnosticClassification `
                -AssistantRanSuccessfully `
                -PolicyIsValid `
                -NoMovementDetected

            $result | Should -Not -Match 'NoEligibleItems'
            $result | Should -Match 'movement was not measured'
        }

        It 'claims NoEligibleItems only when a monitoring window actually sampled movement' {
            Get-MFAReportDiagnosticClassification `
                -AssistantRanSuccessfully `
                -PolicyIsValid `
                -MovementMeasured `
                -NoMovementDetected |
                Should -Match 'NoEligibleItems'
        }

        It 'does not claim NoEligibleItems when movement was measured and found' {
            Get-MFAReportDiagnosticClassification `
                -AssistantRanSuccessfully `
                -PolicyIsValid `
                -MovementMeasured |
                Should -Not -Match 'NoEligibleItems'
        }
    }

    Context 'precedence' {
        It 'prefers a concrete assistant classification over generic warnings' {
            Get-MFAReportDiagnosticClassification `
                -AssistantClassification 'Delay hold / hold cleanup issue' `
                -HealthWarnings @('something else') |
                Should -Be 'Delay hold / hold cleanup issue'
        }

        It 'falls back to warnings when there is no assistant classification' {
            Get-MFAReportDiagnosticClassification -HealthWarnings @('Delay hold evidence detected') |
                Should -Be 'Mailbox health or policy context warnings'
        }

        It 'reports no blocker when there is nothing to report' {
            Get-MFAReportDiagnosticClassification |
                Should -Be 'No diagnostic blocker identified by collected checks'
        }
    }
}

Describe 'Get-MFAReportRecommendedAction' {

    Context 'regression: every mailbox got the same recommendation' {

        It 'reaches the async-monitoring advice for a clean triggered mailbox' {
            # In v0.10 quota context was appended to MailboxHealthWarnings for
            # every mailbox, so HealthWarnings.Count was always > 0 and this
            # branch was unreachable.
            Get-MFAReportRecommendedAction `
                -Status 'TriggeredAwaitingAssistant' `
                -DiagnosticClassification 'No diagnostic blocker identified by collected checks' `
                -HealthWarnings @() |
                Should -Match 'triggered asynchronously'
        }

        It 'still surfaces genuine warnings when there are some' {
            Get-MFAReportRecommendedAction `
                -Status 'TriggeredAwaitingAssistant' `
                -DiagnosticClassification 'Mailbox health or policy context warnings' `
                -HealthWarnings @('Inactive mailbox detected') |
                Should -Be 'Review mailbox health warnings before remediation.'
        }
    }

    Context 'skip reasons that v0.10 left unmapped' {
        It 'maps <SkipReason> to specific advice' -ForEach @(
            @{ SkipReason = 'MailboxLookupFailed' }
            @{ SkipReason = 'NoLicense' }
            @{ SkipReason = 'ArchiveEnableNotConfirmed' }
            @{ SkipReason = 'RetentionTagError' }
            @{ SkipReason = 'RetentionPolicyError' }
        ) {
            $advice = Get-MFAReportRecommendedAction -SkipReason $SkipReason -Status 'Skipped'
            $advice | Should -Not -Be 'No action identified by collected checks.'
            $advice | Should -Not -BeNullOrEmpty
        }
    }

    It 'advises a single-mailbox re-run when movement was not measured' {
        Get-MFAReportRecommendedAction `
            -Status 'TriggeredAwaitingAssistant' `
            -DiagnosticClassification 'Assistant ran and policy is valid, but item movement was not measured in this run.' |
            Should -Match 'mailbox alone'
    }

    It 'prioritises the skip reason over the classification' {
        Get-MFAReportRecommendedAction `
            -SkipReason 'NoArchive' `
            -DiagnosticClassification 'MFA running but throttled or resource unhealthy' |
            Should -Match 'Repair-MailboxMFAPrerequisite'
    }
}

Describe 'Get-MFAReportRecoverableItemsPressure' {

    It 'reports Healthy well under quota' {
        (Get-MFAReportRecoverableItemsPressure `
            -RecoverableItemsBytes 1GB `
            -RecoverableItemsQuota '30 GB (32,212,254,720 bytes)' `
            -RecoverableItemsWarningQuota '20 GB (21,474,836,480 bytes)').State |
            Should -Be 'Healthy'
    }

    It 'reports Critical at or above 95 percent of quota' {
        (Get-MFAReportRecoverableItemsPressure `
            -RecoverableItemsBytes 30GB `
            -RecoverableItemsQuota '30 GB (32,212,254,720 bytes)').State |
            Should -Be 'Critical'
    }

    It 'reports Warning once the warning quota is crossed' {
        (Get-MFAReportRecoverableItemsPressure `
            -RecoverableItemsBytes 21GB `
            -RecoverableItemsQuota '30 GB (32,212,254,720 bytes)' `
            -RecoverableItemsWarningQuota '20 GB (21,474,836,480 bytes)').State |
            Should -Be 'Warning'
    }

    Context 'regression: unlimited quota was treated as a zero quota' {
        It 'reports NoQuotaLimitDetected rather than dividing by zero' {
            (Get-MFAReportRecoverableItemsPressure `
                -RecoverableItemsBytes 5GB `
                -RecoverableItemsQuota 'Unlimited').State |
                Should -Be 'NoQuotaLimitDetected'
        }
    }

    It 'reports NotCalculated when consumption is unknown' {
        (Get-MFAReportRecoverableItemsPressure `
            -RecoverableItemsBytes $null `
            -RecoverableItemsQuota '30 GB (32,212,254,720 bytes)').State |
            Should -Be 'NotCalculated'
    }
}
