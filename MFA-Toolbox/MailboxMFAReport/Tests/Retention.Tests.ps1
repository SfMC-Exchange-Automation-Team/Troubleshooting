#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Parsing.ps1')
    . (Join-Path $PSScriptRoot '..\Private\Retention.ps1')

    # Stubs so Pester has something to Mock; the real cmdlets come from
    # ExchangeOnlineManagement, which is not present on a build agent.
    function Get-RetentionPolicy { param($Identity) }
    function Get-RetentionPolicyTag { param($Identity) }

    # Stands in for ADObjectId, which stringifies to a path-like value rather
    # than the bare tag name.
    function New-TestTagLink {
        param([string]$Name)
        $o = [PSCustomObject]@{ Name = $Name }
        $o | Add-Member -MemberType ScriptMethod -Name ToString -Value { "contoso.com/Configuration/$($this.Name)" }.GetNewClosure() -Force
        $o
    }
}

Describe 'ConvertTo-MFAReportTagLinkName' {

    Context 'regression: ADObjectId links never matched a string tag name' {

        It 'normalises a path-like link to its trailing segment' {
            ConvertTo-MFAReportTagLinkName -TagLinks @(New-TestTagLink -Name 'Default Archive Tag') |
                Should -Be 'Default Archive Tag'
        }

        It 'makes the membership test that v0.10 got wrong succeed' {
            $links = ConvertTo-MFAReportTagLinkName -TagLinks @(New-TestTagLink -Name 'Default Archive Tag')
            # v0.10 evaluated: @(ADObjectId) -notcontains 'Default Archive Tag' -> True
            ($links -notcontains 'Default Archive Tag') | Should -BeFalse
        }

        It 'passes plain strings through unchanged' {
            ConvertTo-MFAReportTagLinkName -TagLinks @('Simple Tag') | Should -Be 'Simple Tag'
        }

        It 'drops blank and null entries' {
            (ConvertTo-MFAReportTagLinkName -TagLinks @('A', '', $null, '  ')).Count | Should -Be 1
        }
    }
}

Describe 'Get-MFAReportRetentionTagApplicability' {

    Context 'regression: tag metadata was split out of a packed colon string' {

        It 'reads the scope of a tag whose NAME contains a colon' {
            # v0.10 packed 'Name:Type:Action:Age' then read index [1], so this
            # tag reported a scope of 'Hold Tag' instead of 'All'.
            $tag = [PSCustomObject]@{
                Name                 = 'Legal:Hold Tag'
                Type                 = 'All'
                RetentionAction      = 'MoveToArchive'
                AgeLimitForRetention = '365'
            }
            Get-MFAReportRetentionTagApplicability -TriggeringTags @($tag) |
                Should -Match 'TriggeringTagScopes=All'
        }
    }

    It 'reports when there are no triggering tags' {
        Get-MFAReportRetentionTagApplicability -TriggeringTags @() |
            Should -Be 'No triggering MRM tags validated.'
    }

    It 'calls out a personal tag as requiring user assignment' {
        $tag = [PSCustomObject]@{ Name = 'Personal 1 year'; Type = 'Personal'; RetentionAction = 'MoveToArchive' }
        Get-MFAReportRetentionTagApplicability -TriggeringTags @($tag) | Should -Match 'user assignment is required'
    }

    It 'calls out a folder-scoped tag' {
        $tag = [PSCustomObject]@{ Name = 'Inbox 30 day'; Type = 'Inbox'; RetentionAction = 'DeleteAndAllowRecovery' }
        Get-MFAReportRetentionTagApplicability -TriggeringTags @($tag) | Should -Match 'only matching folders'
    }

    It 'flags unproven applicability when no folders carry a tag' {
        $tag = [PSCustomObject]@{ Name = 'Inbox 30 day'; Type = 'Inbox'; RetentionAction = 'DeleteAndAllowRecovery' }
        Get-MFAReportRetentionTagApplicability -TriggeringTags @($tag) -TaggedFolderCount 0 |
            Should -Match 'not proven'
    }

    It 'does not flag unproven applicability for an all-folder tag' {
        $tag = [PSCustomObject]@{ Name = 'Default Archive'; Type = 'All'; RetentionAction = 'MoveToArchive' }
        Get-MFAReportRetentionTagApplicability -TriggeringTags @($tag) -TaggedFolderCount 0 |
            Should -Not -Match 'not proven'
    }
}

Describe 'Test-MFAReportRetentionPolicyTrigger' {

    BeforeEach {
        $script:Cache = New-MFAReportRunCache
    }

    It 'returns structured tag objects rather than packed strings' {
        Mock Get-RetentionPolicy { [PSCustomObject]@{ RetentionPolicyTagLinks = @('Default Archive Tag') } }
        Mock Get-RetentionPolicyTag {
            [PSCustomObject]@{ Name = 'Default Archive Tag'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = '365'; RetentionEnabled = $true }
        }

        $r = Test-MFAReportRetentionPolicyTrigger -PolicyName 'P' -RequiredRetentionActions @('MoveToArchive') -Cache $script:Cache
        $r.IsValid | Should -BeTrue
        $r.TriggeringTags[0].Type | Should -Be 'All'
        $r.TriggeringTags[0].Name | Should -Be 'Default Archive Tag'
    }

    It 'ignores a tag whose retention is disabled' {
        Mock Get-RetentionPolicy { [PSCustomObject]@{ RetentionPolicyTagLinks = @('Disabled Tag') } }
        Mock Get-RetentionPolicyTag {
            [PSCustomObject]@{ Name = 'Disabled Tag'; Type = 'All'; RetentionAction = 'MoveToArchive'; RetentionEnabled = $false }
        }

        (Test-MFAReportRetentionPolicyTrigger -PolicyName 'P' -RequiredRetentionActions @('MoveToArchive') -Cache $script:Cache).IsValid |
            Should -BeFalse
    }

    It 'reports a policy that was not found' {
        Mock Get-RetentionPolicy { $null }
        (Test-MFAReportRetentionPolicyTrigger -PolicyName 'Missing' -RequiredRetentionActions @('MoveToArchive') -Cache $script:Cache).Message |
            Should -Match 'was not found'
    }

    Context 'per-run caching' {
        It 'fetches a shared policy once no matter how many mailboxes use it' {
            Mock Get-RetentionPolicy { [PSCustomObject]@{ RetentionPolicyTagLinks = @('T') } }
            Mock Get-RetentionPolicyTag {
                [PSCustomObject]@{ Name = 'T'; Type = 'All'; RetentionAction = 'MoveToArchive'; RetentionEnabled = $true }
            }

            1..25 | ForEach-Object {
                Test-MFAReportRetentionPolicyTrigger -PolicyName 'Shared' -RequiredRetentionActions @('MoveToArchive') -Cache $script:Cache | Out-Null
            }

            # v0.10 issued 25 policy lookups and 25 tag lookups for this run.
            Should -Invoke Get-RetentionPolicy -Times 1 -Exactly
            Should -Invoke Get-RetentionPolicyTag -Times 1 -Exactly
        }
    }
}
