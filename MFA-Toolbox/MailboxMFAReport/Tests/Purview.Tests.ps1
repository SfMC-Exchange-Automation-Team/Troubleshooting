#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Parsing.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Holds.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Purview.ps1')

    function New-TestPolicy {
        param($Name, $Locations = @(), $Exceptions = @(), $Applications = 'Exchange', $Restrictive = $false, $Guid = $null)
        [PSCustomObject]@{
            Name                     = $Name
            ExchangeLocation         = $Locations
            ExchangeLocationException = $Exceptions
            Applications             = $Applications
            Mode                     = 'Enforce'
            Enabled                  = $true
            DistributionStatus       = 'Success'
            RestrictiveRetention     = $Restrictive
            Guid                     = $Guid
        }
    }
}

Describe 'Get-MFAReportPurviewPolicyMatch' {

    Context 'regression: Applications -match Exchange matched every mailbox' {

        It 'does not match a policy scoped to someone else' {
            # v0.10 returned this as a match purely because Applications
            # contained 'Exchange', which drove PossiblePurviewOverride tenant-wide.
            $policy = New-TestPolicy -Name 'Finance Only' -Locations @('finance@contoso.com')
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) -IdentityValues @('user@contoso.com')

            $m.Matched.Count | Should -Be 0
        }

        It 'reports that policy as not evaluated rather than not applicable' {
            # Absence of a match is not proof of non-application: ExchangeLocation
            # often stringifies to a display name.
            $policy = New-TestPolicy -Name 'Finance Only' -Locations @('finance@contoso.com')
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) -IdentityValues @('user@contoso.com')

            $m.NotEvaluated.Count | Should -Be 1
            $m.NotEvaluated[0].MatchReason | Should -Be 'ScopedToRecipientsNotResolvable'
            $m.NotEvaluated[0].MatchConfidence | Should -Be 'Unknown'
        }
    }

    Context 'genuine matches' {

        It 'matches an organization-wide policy' {
            $m = Get-MFAReportPurviewPolicyMatch -Policies @(New-TestPolicy -Name 'All' -Locations @('All')) `
                -IdentityValues @('user@contoso.com')
            $m.Matched.Count | Should -Be 1
            $m.Matched[0].MatchReason | Should -Be 'OrganizationWide'
        }

        It 'matches an explicitly scoped recipient' {
            $m = Get-MFAReportPurviewPolicyMatch -Policies @(New-TestPolicy -Name 'Scoped' -Locations @('user@contoso.com')) `
                -IdentityValues @('user@contoso.com')
            $m.Matched.Count | Should -Be 1
            $m.Matched[0].MatchReason | Should -Be 'ExplicitRecipientMatch'
        }

        It 'honours an exception even on an organization-wide policy' {
            $m = Get-MFAReportPurviewPolicyMatch `
                -Policies @(New-TestPolicy -Name 'AllButUser' -Locations @('All') -Exceptions @('user@contoso.com')) `
                -IdentityValues @('user@contoso.com')
            $m.Matched.Count | Should -Be 0
            $m.Excluded.Count | Should -Be 1
        }

        It 'matches on any supplied identity value, not just the primary' {
            $m = Get-MFAReportPurviewPolicyMatch -Policies @(New-TestPolicy -Name 'ByGuid' -Locations @('abc-123-guid')) `
                -IdentityValues @('user@contoso.com', 'abc-123-guid')
            $m.Matched.Count | Should -Be 1
        }
    }

    It 'handles an empty policy set' {
        $m = Get-MFAReportPurviewPolicyMatch -Policies @() -IdentityValues @('user@contoso.com')
        $m.Matched.Count | Should -Be 0
        $m.NotEvaluated.Count | Should -Be 0
    }

    Context 'the mailbox InPlaceHolds reference is authoritative' {

        BeforeAll {
            $script:Guid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
            $script:Dashed = 'a1b2c3d4-e5f6-0718-293a-4b5c6d7e8f90'
        }

        It 'confirms a policy the mailbox is actually held by, without any location match' {
            # Exchange reports this policy against the mailbox. That is evidence,
            # not inference, so it should not land in the unresolvable bucket
            # merely because ExchangeLocation names someone else.
            $policy = New-TestPolicy -Name 'Contoso Legal' -Locations @('someone.else@contoso.com') -Guid $script:Dashed
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) `
                -IdentityValues @('user@contoso.com') -MailboxHoldGuids @($script:Guid)

            $m.Matched.Count | Should -Be 1
            $m.Matched[0].MatchReason | Should -Be 'MailboxInPlaceHoldReference'
            $m.Matched[0].MatchConfidence | Should -Be 'Confirmed'
            $m.NotEvaluated.Count | Should -Be 0
        }

        It 'shrinks the unresolvable bucket when holds resolve the policy' {
            $policies = @(
                New-TestPolicy -Name 'Held' -Locations @('someone.else@contoso.com') -Guid $script:Dashed
                New-TestPolicy -Name 'Unknown scope' -Locations @('another@contoso.com') -Guid '99999999-9999-9999-9999-999999999999'
            )
            $m = Get-MFAReportPurviewPolicyMatch -Policies $policies `
                -IdentityValues @('user@contoso.com') -MailboxHoldGuids @($script:Guid)

            $m.Matched.Count | Should -Be 1
            $m.NotEvaluated.Count | Should -Be 1
            $m.NotEvaluated[0].Name | Should -Be 'Unknown scope'
        }

        It 'outranks a location exception, because Exchange is the source of truth' {
            $policy = New-TestPolicy -Name 'Held despite exception' -Locations @('All') `
                -Exceptions @('user@contoso.com') -Guid $script:Dashed
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) `
                -IdentityValues @('user@contoso.com') -MailboxHoldGuids @($script:Guid)

            $m.Matched.Count | Should -Be 1
            $m.Excluded.Count | Should -Be 0
        }

        It 'ignores hold GUIDs that match no policy' {
            $policy = New-TestPolicy -Name 'Scoped elsewhere' -Locations @('someone.else@contoso.com') `
                -Guid '99999999-9999-9999-9999-999999999999'
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) `
                -IdentityValues @('user@contoso.com') -MailboxHoldGuids @($script:Guid)

            $m.Matched.Count | Should -Be 0
            $m.NotEvaluated.Count | Should -Be 1
        }

        It 'behaves as before when no hold GUIDs are supplied' {
            $policy = New-TestPolicy -Name 'Scoped elsewhere' -Locations @('someone.else@contoso.com') -Guid $script:Dashed
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) -IdentityValues @('user@contoso.com')
            $m.NotEvaluated.Count | Should -Be 1
        }
    }

    Context 'display-name scoped policies' {

        It 'matches when ExchangeLocation carries a display name rather than an address' {
            # Scoped policies commonly stringify to the display name, which is why
            # comparing only addresses and GUIDs left them unresolvable.
            $policy = New-TestPolicy -Name 'Scoped by display name' -Locations @('Ada Lovelace')
            $m = Get-MFAReportPurviewPolicyMatch -Policies @($policy) `
                -IdentityValues @('ada@contoso.com', 'Ada Lovelace')

            $m.Matched.Count | Should -Be 1
            $m.Matched[0].MatchReason | Should -Be 'ExplicitRecipientMatch'
        }
    }
}

Describe 'Test-MFAReportPreservationLock' {

    It 'detects RestrictiveRetention' {
        Test-MFAReportPreservationLock -Policy (New-TestPolicy -Name 'Locked' -Restrictive $true) | Should -BeTrue
    }

    It 'returns false when not locked' {
        Test-MFAReportPreservationLock -Policy (New-TestPolicy -Name 'Open' -Restrictive $false) | Should -BeFalse
    }

    It 'is strict-safe against a policy missing every lock property' {
        Set-StrictMode -Version 3.0
        { Test-MFAReportPreservationLock -Policy ([PSCustomObject]@{ Name = 'x' }) } | Should -Not -Throw
    }
}

Describe 'Get-MFAReportPurviewOverrideSignal' {

    It 'reports a definite override for a preservation lock' {
        Get-MFAReportPurviewOverrideSignal -HasPreservationLock | Should -Match 'PurviewOverride:PreservationLocked'
    }

    It 'reports a possible override for a compliance tag hold' {
        Get-MFAReportPurviewOverrideSignal -IsComplianceTagHoldApplied $true |
            Should -Match 'PossiblePurviewOverride:ComplianceTagHoldApplied'
    }

    Context 'confirmed matches are not hedged' {
        It 'states a confirmed match definitively' {
            Get-MFAReportPurviewOverrideSignal -MatchedPolicyCount 1 -ConfirmedPolicyCount 1 |
                Should -Match '^PurviewOverride:1 .*confirmed'
        }

        It 'prefers a confirmed match over a compliance tag hold signal' {
            Get-MFAReportPurviewOverrideSignal -ConfirmedPolicyCount 2 -IsComplianceTagHoldApplied $true |
                Should -Match '^PurviewOverride:2'
        }

        It 'still hedges an inferred-only match' {
            Get-MFAReportPurviewOverrideSignal -MatchedPolicyCount 3 -ConfirmedPolicyCount 0 |
                Should -Match '^PossiblePurviewOverride:3'
        }
    }

    Context 'regression: a False compliance tag flag must not signal an override' {
        It 'ignores a known-false flag' {
            Get-MFAReportPurviewOverrideSignal -IsComplianceTagHoldApplied $false |
                Should -Be 'NoOverrideSignalFromCollectedChecks'
        }

        It 'ignores an undetermined flag' {
            Get-MFAReportPurviewOverrideSignal -IsComplianceTagHoldApplied $null |
                Should -Be 'NoOverrideSignalFromCollectedChecks'
        }

        It 'the negative signal does not itself match an anchored override test' {
            # 'NoPurviewOverrideSignal...' CONTAINS 'PurviewOverride', so callers
            # must anchor. This pins the contract both sides rely on.
            $negative = Get-MFAReportPurviewOverrideSignal -IsComplianceTagHoldApplied $false
            $negative | Should -Not -Match '^(Possible)?PurviewOverride:'

            $positive = Get-MFAReportPurviewOverrideSignal -HasPreservationLock
            $positive | Should -Match '^(Possible)?PurviewOverride:'
        }
    }

    It 'surfaces an inconclusive result when policies could not be evaluated' {
        Get-MFAReportPurviewOverrideSignal -NotEvaluatedPolicyCount 3 | Should -Match 'Inconclusive:3'
    }

    It 'prefers a real match over an inconclusive one' {
        Get-MFAReportPurviewOverrideSignal -MatchedPolicyCount 2 -NotEvaluatedPolicyCount 3 |
            Should -Match 'PossiblePurviewOverride:2'
    }
}

Describe 'Get-MFAReportPurviewSignals' {

    Context 'regression: preservation-locked policy that matches nothing' {

        BeforeEach {
            Set-StrictMode -Version 3.0
        }

        It 'does not throw when a locked policy exists but the mailbox matched none' {
            # $match.Matched is an empty List here, and reading .Name off an empty
            # collection is a missing-property error under StrictMode 3.0. The
            # -and short-circuit meant it only fired once a policy was actually
            # preservation-locked, so the whole run died on the first mailbox of
            # exactly the tenants this check exists to serve.
            $locked = New-TestPolicy -Name 'Legal Hold Locked' `
                -Locations @('someone.else@contoso.com') -Restrictive $true `
                -Guid '11111111-2222-3333-4444-555555555555'
            $mailbox = [PSCustomObject]@{
                UserPrincipalName = 'user@contoso.com'
                PrimarySmtpAddress = 'user@contoso.com'
                DisplayName = 'A User'
            }

            { Get-MFAReportPurviewSignals -Identity 'user@contoso.com' `
                -Mailbox $mailbox -Policies @($locked) } | Should -Not -Throw

            $signals = Get-MFAReportPurviewSignals -Identity 'user@contoso.com' `
                -Mailbox $mailbox -Policies @($locked)
            $signals.HasPreservationLockOverride | Should -BeFalse
            @($signals.PreservationLockedPolicies).Count | Should -Be 0
        }

        It 'still reports the override when the locked policy does match the mailbox' {
            $locked = New-TestPolicy -Name 'Org Wide Locked' -Locations @('All') -Restrictive $true
            $mailbox = [PSCustomObject]@{
                UserPrincipalName = 'user@contoso.com'
                PrimarySmtpAddress = 'user@contoso.com'
                DisplayName = 'A User'
            }

            $signals = Get-MFAReportPurviewSignals -Identity 'user@contoso.com' `
                -Mailbox $mailbox -Policies @($locked)

            $signals.HasPreservationLockOverride | Should -BeTrue
            $signals.PreservationLockedPolicies | Should -Contain 'Org Wide Locked'
        }
    }
}
