#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Parsing.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Holds.ps1')
}

Describe 'ConvertTo-MFAReportHoldDescription' {

    Context 'regression: the leading - exclusion prefix was ignored' {

        It 'marks a -prefixed hold as an exclusion' {
            $d = ConvertTo-MFAReportHoldDescription -HoldId '-mbxa1b2c3d4'
            $d.IsExclusion | Should -BeTrue
            $d.Scope | Should -Be 'ExchangeMailboxRetentionCompliancePolicy'
        }

        It 'marks a :2 suffixed hold as an exclusion' {
            $d = ConvertTo-MFAReportHoldDescription -HoldId 'skpa1b2c3d4:2'
            $d.IsExclusion | Should -BeTrue
            $d.State | Should -Be 'ExplicitExcluded'
        }

        It 'does not mark a plain hold as an exclusion' {
            (ConvertTo-MFAReportHoldDescription -HoldId 'mbxa1b2c3d4').IsExclusion | Should -BeFalse
        }

        It 'marks a :1 suffixed hold as explicitly included' {
            $d = ConvertTo-MFAReportHoldDescription -HoldId 'skpa1b2c3d4:1'
            $d.State | Should -Be 'ExplicitIncluded'
            $d.IsExclusion | Should -BeFalse
        }
    }

    Context 'scope decoding' {
        It 'decodes <HoldId> as <Scope>' -ForEach @(
            @{ HoldId = 'mbx123';  Scope = 'ExchangeMailboxRetentionCompliancePolicy' }
            @{ HoldId = 'skp123';  Scope = 'SkypeTeamsRetentionCompliancePolicy' }
            @{ HoldId = 'grp123';  Scope = 'Microsoft365GroupRetentionCompliancePolicy' }
            @{ HoldId = 'UniH123'; Scope = 'UnifiedHold' }
            @{ HoldId = 'cld123';  Scope = 'CloudRetentionCompliancePolicy' }
            @{ HoldId = 'zzz123';  Scope = 'UnknownHoldType' }
        ) {
            (ConvertTo-MFAReportHoldDescription -HoldId $HoldId).Scope | Should -Be $Scope
        }
    }

    It 'returns null for blank input' {
        ConvertTo-MFAReportHoldDescription -HoldId '  ' | Should -BeNullOrEmpty
    }
}

Describe 'Get-MFAReportHoldPolicyGuid' {

    BeforeAll {
        $script:Guid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
    }

    It 'recovers the GUID from a plain hold id' {
        Get-MFAReportHoldPolicyGuid -HoldId "mbx$script:Guid" | Should -Be $script:Guid
    }

    It 'recovers the GUID despite an exclusion prefix' {
        Get-MFAReportHoldPolicyGuid -HoldId "-mbx$script:Guid" | Should -Be $script:Guid
    }

    It 'recovers the GUID despite an include/exclude suffix' {
        Get-MFAReportHoldPolicyGuid -HoldId "skp${script:Guid}:2" | Should -Be $script:Guid
    }

    It 'recovers the GUID from every known prefix' -ForEach @(
        @{ Prefix = 'mbx' }, @{ Prefix = 'skp' }, @{ Prefix = 'grp' }
        @{ Prefix = 'cld' }, @{ Prefix = 'UniH' }
    ) {
        Get-MFAReportHoldPolicyGuid -HoldId "$Prefix$script:Guid" | Should -Be $script:Guid
    }

    It 'normalises a dashed GUID to compare against a policy Guid property' {
        Get-MFAReportHoldPolicyGuid -HoldId 'mbxa1b2c3d4-e5f6-0718-293a-4b5c6d7e8f90' | Should -Be $script:Guid
    }

    It 'is case insensitive' {
        Get-MFAReportHoldPolicyGuid -HoldId "mbx$($script:Guid.ToUpper())" | Should -Be $script:Guid
    }

    Context 'degrades to undecoded rather than guessing' {
        It 'returns null when the remainder is not a GUID' {
            Get-MFAReportHoldPolicyGuid -HoldId 'mbxnotaguid' | Should -BeNullOrEmpty
        }

        It 'returns null for an unrecognised shape' {
            Get-MFAReportHoldPolicyGuid -HoldId 'SomethingEntirelyNew' | Should -BeNullOrEmpty
        }

        It 'returns null for blank input' {
            Get-MFAReportHoldPolicyGuid -HoldId '' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Resolve-MFAReportHoldPolicyName' {

    BeforeAll {
        $script:Guid = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
        $script:Policies = @(
            [PSCustomObject]@{ Name = 'Contoso Legal Retention'; Guid = 'a1b2c3d4-e5f6-0718-293a-4b5c6d7e8f90' }
            [PSCustomObject]@{ Name = 'Unrelated Policy'; Guid = '11111111-2222-3333-4444-555555555555' }
        )
    }

    It 'names a hold whose GUID matches a known policy' {
        $holds = @(ConvertTo-MFAReportHoldDescription -HoldId "mbx$script:Guid")
        $resolved = @(Resolve-MFAReportHoldPolicyName -Holds $holds -Policies $script:Policies)

        $resolved[0].PolicyName | Should -Be 'Contoso Legal Retention'
        # The opaque identifier alone is not actionable for an operator.
        $resolved[0].Description | Should -Match 'Contoso Legal Retention'
    }

    It 'matches regardless of dash formatting between hold id and policy Guid' {
        $holds = @(ConvertTo-MFAReportHoldDescription -HoldId "-mbx${script:Guid}:1")
        (Resolve-MFAReportHoldPolicyName -Holds $holds -Policies $script:Policies)[0].PolicyName |
            Should -Be 'Contoso Legal Retention'
    }

    It 'leaves an unmatched hold unnamed rather than inventing a name' {
        $holds = @(ConvertTo-MFAReportHoldDescription -HoldId 'mbx999999999999999999999999999999')
        $resolved = @(Resolve-MFAReportHoldPolicyName -Holds $holds -Policies $script:Policies)

        $resolved[0].PolicyName | Should -BeNullOrEmpty
        $resolved[0].Description | Should -Be $resolved[0].Description
    }

    It 'passes holds through unchanged when no policies are available' {
        $holds = @(ConvertTo-MFAReportHoldDescription -HoldId "mbx$script:Guid")
        $resolved = @(Resolve-MFAReportHoldPolicyName -Holds $holds -Policies @())
        $resolved.Count | Should -Be 1
        $resolved[0].PolicyName | Should -BeNullOrEmpty
    }

    It 'is strict-safe against a policy with no Guid property' {
        Set-StrictMode -Version 3.0
        $holds = @(ConvertTo-MFAReportHoldDescription -HoldId "mbx$script:Guid")
        { Resolve-MFAReportHoldPolicyName -Holds $holds -Policies @([PSCustomObject]@{ Name = 'x' }) } |
            Should -Not -Throw
    }
}

Describe 'Test-MFAReportHoldRequirement' {

    BeforeAll {
        $script:NoHolds = [PSCustomObject]@{ LitigationHoldEnabled = $false; InPlaceHolds = @() }
        $script:LitHold = [PSCustomObject]@{ LitigationHoldEnabled = $true;  InPlaceHolds = @() }
        $script:RealHold = [PSCustomObject]@{ LitigationHoldEnabled = $false; InPlaceHolds = @('mbxa1b2c3') }
        $script:OnlyExcluded = [PSCustomObject]@{ LitigationHoldEnabled = $false; InPlaceHolds = @('-mbxa1b2c3', 'skpd4e5f6:2') }
    }

    Context 'regression: an excluding hold satisfied the requirement' {

        It 'does not treat an exclusion-only mailbox as held' {
            $r = Test-MFAReportHoldRequirement -Mailbox $script:OnlyExcluded -RequiredHold 'Any'
            $r.IsSatisfied | Should -BeFalse
            $r.MailboxInPlaceHolds.Count | Should -Be 0
        }

        It 'still records the excluded holds for operator context' {
            $r = Test-MFAReportHoldRequirement -Mailbox $script:OnlyExcluded -RequiredHold 'Any'
            $r.ExcludedHolds.Count | Should -Be 2
        }

        It 'does not satisfy MailboxOrOrgWideHold from an org-wide exclusion' {
            $r = Test-MFAReportHoldRequirement -Mailbox $script:NoHolds -RequiredHold 'MailboxOrOrgWideHold' `
                -OrganizationWideHoldIds @('-mbxorgwide1')
            $r.IsSatisfied | Should -BeFalse
        }
    }

    Context 'satisfaction rules' {
        It 'None is always satisfied' {
            (Test-MFAReportHoldRequirement -Mailbox $script:NoHolds -RequiredHold 'None').IsSatisfied | Should -BeTrue
        }

        It 'Any is satisfied by litigation hold' {
            (Test-MFAReportHoldRequirement -Mailbox $script:LitHold -RequiredHold 'Any').IsSatisfied | Should -BeTrue
        }

        It 'Any is satisfied by a real in-place hold' {
            (Test-MFAReportHoldRequirement -Mailbox $script:RealHold -RequiredHold 'Any').IsSatisfied | Should -BeTrue
        }

        It 'Any is not satisfied with no holds at all' {
            (Test-MFAReportHoldRequirement -Mailbox $script:NoHolds -RequiredHold 'Any').IsSatisfied | Should -BeFalse
        }

        It 'LitigationHold requires litigation hold specifically' {
            (Test-MFAReportHoldRequirement -Mailbox $script:RealHold -RequiredHold 'LitigationHold').IsSatisfied | Should -BeFalse
            (Test-MFAReportHoldRequirement -Mailbox $script:LitHold  -RequiredHold 'LitigationHold').IsSatisfied | Should -BeTrue
        }

        It 'is satisfied by a genuine org-wide hold' {
            $r = Test-MFAReportHoldRequirement -Mailbox $script:NoHolds -RequiredHold 'MailboxOrOrgWideHold' `
                -OrganizationWideHoldIds @('mbxorgwide1')
            $r.IsSatisfied | Should -BeTrue
        }
    }

    It 'is strict-safe against a mailbox lacking InPlaceHolds' {
        Set-StrictMode -Version 3.0
        $bare = [PSCustomObject]@{ LitigationHoldEnabled = $false }
        { Test-MFAReportHoldRequirement -Mailbox $bare -RequiredHold 'Any' } | Should -Not -Throw
    }
}
