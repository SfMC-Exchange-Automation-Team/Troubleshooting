#Requires -Version 5.1

<#
End-to-end tests driving the public cmdlets against stubbed Exchange Online and
Graph commands. Module-internal calls resolve to these global stubs, so the whole
pipeline runs without a tenant.

Every write-capable stub appends to $global:MFAWriteLog, which lets the tests
assert that Get-MailboxMFAReadiness is read-only by construction rather than by
inspection.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\MailboxMFAReport.psd1'
    $script:OutRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'mfareport-tests'

    $global:MFAWriteLog = [System.Collections.Generic.List[string]]::new()
    $global:MFAArchiveState = @{}
    $global:MFAStatsAttempts = 0
    $global:MFACheckpointDir = $null
    $global:MFACheckpointRowsSeen = -1

    function global:New-StubMailbox {
        param(
            [string]$Upn,
            [string]$ArchiveState = 'HostedProvisioned',
            [string]$RetentionPolicy = 'Contoso MRM Policy',
            [string[]]$InPlaceHolds = @()
        )
        [PSCustomObject]@{
            UserPrincipalName            = $Upn
            PrimarySmtpAddress           = $Upn
            DisplayName                  = $Upn
            Alias                        = ($Upn -split '@')[0]
            ExternalDirectoryObjectId    = "dir-$Upn"
            ExchangeGuid                 = "guid-$Upn"
            RecipientTypeDetails         = 'UserMailbox'
            ArchiveState                 = $ArchiveState
            AutoExpandingArchiveEnabled  = $true
            RetentionPolicy              = $RetentionPolicy
            RetentionHoldEnabled         = $false
            LitigationHoldEnabled        = $false
            ElcProcessingDisabled        = $false
            InPlaceHolds                 = $InPlaceHolds
            IsInactiveMailbox            = $false
            RemoteRecipientType          = 'None'
            SKUAssigned                  = $true
            RecoverableItemsQuota        = '30 GB (32,212,254,720 bytes)'
            RecoverableItemsWarningQuota = '20 GB (21,474,836,480 bytes)'
        }
    }

    # A policy scoped to somebody else entirely, but which Exchange reports
    # against the 'held' mailbox via InPlaceHolds.
    $global:MFATestPolicyGuid = 'a1b2c3d4-e5f6-0718-293a-4b5c6d7e8f90'
    function global:Get-RetentionCompliancePolicy {
        param([switch]$DistributionDetail, $ErrorAction)
        @(
            [PSCustomObject]@{
                Name                      = 'Contoso Legal Retention'
                Guid                      = $global:MFATestPolicyGuid
                ExchangeLocation          = @('someone.else@contoso.com')
                ExchangeLocationException = @()
                Applications              = 'Exchange'
                Mode                      = 'Enforce'
                Enabled                   = $true
                DistributionStatus        = 'Success'
                RestrictiveRetention      = $false
            }
        )
    }

    function global:Get-Mailbox {
        param($Identity, $ResultSize, [switch]$SoftDeletedMailbox, $ErrorAction, $WarningAction)

        # Probe identity: records how many rows the in-progress checkpoint holds
        # at the moment this mailbox is reached, proving results reach disk
        # before the run ends rather than only at the end.
        if ($Identity -like '*probe*' -and $global:MFACheckpointDir) {
            $checkpoint = Get-ChildItem -Path $global:MFACheckpointDir -Filter 'MFAReport_INPROGRESS_*.csv' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $global:MFACheckpointRowsSeen = if ($checkpoint) { @(Import-Csv $checkpoint.FullName).Count } else { 0 }
        }

        if ($Identity -like '*missing*') { throw "The object '$Identity' couldn't be found." }

        # Visible only via -SoftDeletedMailbox, so this exercises switch
        # propagation through the retry wrapper's scriptblock.
        if ($Identity -like '*softdeleted*') {
            if (-not $SoftDeletedMailbox) { throw "The object '$Identity' couldn't be found." }
            return New-StubMailbox -Upn $Identity
        }
        if ($Identity -like '*noarchive*') {
            $state = if ($global:MFAArchiveState.ContainsKey($Identity)) { $global:MFAArchiveState[$Identity] } else { 'None' }
            return New-StubMailbox -Upn $Identity -ArchiveState $state
        }
        if ($Identity -like '*nopolicy*') { return New-StubMailbox -Upn $Identity -RetentionPolicy '' }

        # Exchange reports the Contoso Legal Retention policy against this
        # mailbox even though the policy's ExchangeLocation names someone else.
        if ($Identity -like '*held*') {
            return New-StubMailbox -Upn $Identity -InPlaceHolds @('mbxa1b2c3d4e5f60718293a4b5c6d7e8f90')
        }

        New-StubMailbox -Upn $Identity
    }

    function global:Get-OrganizationConfig {
        param($ErrorAction, $WarningAction)
        [PSCustomObject]@{ InPlaceHolds = @(); AutoExpandingArchiveEnabled = $true; ElcProcessingDisabled = $false }
    }

    function global:Get-MailboxStatistics {
        param($Identity, [switch]$Archive, $ErrorAction)

        # 'flaky' throttles once on the primary lookup, then succeeds.
        if ($Identity -like '*flaky*' -and -not $Archive) {
            $global:MFAStatsAttempts++
            if ($global:MFAStatsAttempts -lt 2) { throw 'The server is busy. Please try again.' }
        }

        [PSCustomObject]@{
            ItemCount     = if ($Archive) { 500 } else { 12000 }
            TotalItemSize = [PSCustomObject]@{ Value = '1.5 GB (1,610,612,736 bytes)' }
        }
    }

    function global:Get-RetentionPolicy {
        param($Identity, $ErrorAction)
        if ([string]::IsNullOrWhiteSpace([string]$Identity)) { return $null }
        [PSCustomObject]@{ Name = $Identity; RetentionPolicyTagLinks = @('Contoso 2 year archive') }
    }

    function global:Get-RetentionPolicyTag {
        param($Identity, $ErrorAction)
        [PSCustomObject]@{
            Name = 'Contoso 2 year archive'; Type = 'All'
            RetentionAction = 'MoveToArchive'; AgeLimitForRetention = '730'; RetentionEnabled = $true
        }
    }

    # A HEALTHY mailbox: every flag present but false, every counter zero.
    # This is the payload v0.10 classified as throttled.
    function global:Export-MailboxDiagnosticLogs {
        param($Identity, [switch]$ExtendedProperties, $ComponentName, $ErrorAction)
        if ($ExtendedProperties) {
            return [PSCustomObject]@{ MailboxLog = @'
<ELCLastSuccessTimestamp>2026-07-28T04:12:00Z</ELCLastSuccessTimestamp>
<DelayHoldApplied>False</DelayHoldApplied>
<DelayReleaseHoldApplied>False</DelayReleaseHoldApplied>
<ComplianceTagHoldApplied>False</ComplianceTagHoldApplied>
'@ }
        }
        return [PSCustomObject]@{ MailboxLog = @'
<ResourceUnhealthy>False</ResourceUnhealthy>
<WorkCycleLag>00:00:00</WorkCycleLag>
<StoreMaintenanceBacklog>0</StoreMaintenanceBacklog>
<ELCItemCount>12000</ELCItemCount>
'@ }
    }

    # ---- write-capable stubs: every call is recorded -------------------------
    function global:Start-ManagedFolderAssistant {
        param($Identity, [switch]$FullCrawl, [switch]$HoldCleanup, [switch]$InactiveMailbox, $ErrorAction)
        $global:MFAWriteLog.Add("Start-ManagedFolderAssistant:$Identity")
    }
    function global:Enable-Mailbox {
        param($Identity, [switch]$Archive, $ErrorAction)
        $global:MFAWriteLog.Add("Enable-Mailbox:$Identity")
        $global:MFAArchiveState[$Identity] = 'HostedProvisioned'
    }
    function global:Set-Mailbox {
        param($Identity, [switch]$AutoExpandingArchive, $RetentionPolicy, $ErrorAction)
        $global:MFAWriteLog.Add("Set-Mailbox:$Identity")
    }
    function global:New-RetentionPolicy {
        param($Name, $RetentionPolicyTagLinks, $ErrorAction)
        $global:MFAWriteLog.Add("New-RetentionPolicy:$Name")
    }
    function global:Set-RetentionPolicy {
        param($Identity, $RetentionPolicyTagLinks, $ErrorAction)
        $global:MFAWriteLog.Add("Set-RetentionPolicy:$Identity")
    }
    function global:New-RetentionPolicyTag {
        param($Name, $Type, $AgeLimitForRetention, $RetentionAction, $ErrorAction)
        $global:MFAWriteLog.Add("New-RetentionPolicyTag:$Name")
    }

    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module MailboxMFAReport -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $script:OutRoot -Recurse -Force -ErrorAction SilentlyContinue
    'Get-Mailbox', 'Get-OrganizationConfig', 'Get-MailboxStatistics', 'Get-RetentionPolicy',
    'Get-RetentionPolicyTag', 'Start-ManagedFolderAssistant', 'Export-MailboxDiagnosticLogs',
    'New-StubMailbox', 'Enable-Mailbox', 'Set-Mailbox', 'New-RetentionPolicy',
    'Set-RetentionPolicy', 'New-RetentionPolicyTag' | ForEach-Object {
        Remove-Item "function:global:$_" -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name MFAWriteLog, MFAArchiveState -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-MailboxMFAReadiness' {

    BeforeEach {
        $global:MFAWriteLog.Clear()
        $global:MFAArchiveState.Clear()
    }

    Context 'the diagnostic must never write to the tenant' {

        It 'issues no write cmdlet for a healthy mailbox' {
            Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks | Out-Null
            $global:MFAWriteLog | Should -BeNullOrEmpty
        }

        It 'issues no write cmdlet even when prerequisites are missing' {
            # v0.10 would have called Enable-Mailbox here under -FixPrerequisites,
            # from a command documented as a report.
            Get-MailboxMFAReadiness -Users @('noarchive@contoso.com', 'nopolicy@contoso.com') -SkipGraphChecks | Out-Null
            $global:MFAWriteLog | Should -BeNullOrEmpty
        }

        It 'returns promptly rather than entering a monitoring window' {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks | Out-Null
            $sw.Stop()
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
        }
    }

    Context 'Blocked and Skipped are distinct outcomes' {

        It 'reports a missing archive as Blocked, not Skipped' {
            $run = Get-MailboxMFAReadiness -Users 'noarchive@contoso.com' -SkipGraphChecks
            $run.Results[0].Status | Should -Be 'Blocked'
            $run.Results[0].SkipReason | Should -Be 'NoArchive'
        }

        It 'reports an unreadable mailbox as Skipped' {
            $run = Get-MailboxMFAReadiness -Users 'missing@contoso.com' -SkipGraphChecks
            $run.Results[0].Status | Should -Be 'Skipped'
            $run.Results[0].SkipReason | Should -Be 'MailboxLookupFailed'
        }

        It 'reports a healthy mailbox as Ready' {
            $run = Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks
            $run.Results[0].Status | Should -Be 'Ready'
        }

        It 'detects a soft-deleted mailbox via the fallback lookup' {
            $run = Get-MailboxMFAReadiness -Users 'softdeleted@contoso.com' -SkipGraphChecks
            $run.Results[0].Status | Should -Be 'Skipped'
            $run.Results[0].SkipReason | Should -Be 'SoftDeletedMailbox'
            $run.Results[0].EdgeCase | Should -Be 'SoftDeletedMailbox'
            $run.Results[0].RecommendedNextAction | Should -Match 'recovery'
        }

        It 'suggests the matching repair for a blocked mailbox' {
            $run = Get-MailboxMFAReadiness -Users 'noarchive@contoso.com' -SkipGraphChecks
            $run.Results[0].RepairSuggestions | Should -Contain 'EnableArchive'
            $run.Results[0].RecommendedNextAction | Should -Not -Be 'No action identified by collected checks.'
        }
    }

    Context 'regression: healthy mailboxes were classified as throttled' {

        It 'does not report throttling for all-False diagnostic flags' {
            $run = Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks -IncludeAssistantDiagnostics
            $run.Results[0].DiagnosticClassification | Should -Not -Match 'throttled|resource unhealthy'
        }

        It 'does not hand every mailbox the same generic recommendation' {
            $run = Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks -IncludeAssistantDiagnostics
            $run.Results[0].RecommendedNextAction | Should -Not -Be 'Review mailbox health warnings before remediation.'
            $run.Results[0].MailboxHealthWarnings | Should -BeNullOrEmpty
            $run.Results[0].MailboxContext | Should -Not -BeNullOrEmpty
        }
    }

    Context 'hold and Purview resolution' {

        It 'confirms a Purview policy from the mailbox InPlaceHolds rather than guessing at scope' {
            $run = Get-MailboxMFAReadiness -Users 'held@contoso.com' -SkipGraphChecks -IncludePurviewDetails
            $matched = @($run.Results[0].MatchedPurviewPolicies)

            $matched.Count | Should -Be 1
            $matched[0].Name | Should -Be 'Contoso Legal Retention'
            $matched[0].MatchConfidence | Should -Be 'Confirmed'
            # The policy names someone else in ExchangeLocation, so without the
            # hold reference it would have been reported as unresolvable.
            @($run.Results[0].NotEvaluatedPurviewPolicies).Count | Should -Be 0
        }

        It 'names the hold from the policy list instead of leaving an opaque id' {
            $run = Get-MailboxMFAReadiness -Users 'held@contoso.com' -SkipGraphChecks -IncludePurviewDetails
            ($run.Results[0].MailboxContext -join ' ') | Should -Match 'ResolvedHoldPolicies=.*Contoso Legal Retention'
        }

        It 'reports a definite rather than a speculative override signal' {
            $run = Get-MailboxMFAReadiness -Users 'held@contoso.com' -SkipGraphChecks -IncludePurviewDetails
            # Confirmed from InPlaceHolds, so it must not be hedged as "Possible".
            $run.Results[0].PurviewOverrideSignal | Should -Match '^PurviewOverride:1 .*confirmed'
            $run.Summary.InconclusivePurview | Should -Be 0
            $run.Summary.PossiblePurviewOverrides | Should -Be 1
        }

        It 'still reports an unheld mailbox as inconclusive against a scoped policy' {
            $run = Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks -IncludePurviewDetails
            @($run.Results[0].NotEvaluatedPurviewPolicies).Count | Should -Be 1
            $run.Results[0].PurviewOverrideSignal | Should -Match '^Inconclusive:1'
        }
    }

    Context 'resilience' {
        It 'retries a throttled statistics call instead of reporting the mailbox as failed' {
            $global:MFAStatsAttempts = 0
            $run = Get-MailboxMFAReadiness -Users 'flaky@contoso.com' -SkipGraphChecks

            # v0.10 issued this call once; a throttle response became
            # MailboxStatisticsFailed, indistinguishable from a real fault.
            $run.Results[0].Status | Should -Be 'Ready'
            $global:MFAStatsAttempts | Should -BeGreaterOrEqual 2
        }

        It 'checkpoints each result to disk as the run progresses' {
            $out = Join-Path $script:OutRoot 'checkpoint'
            $global:MFACheckpointDir = $out
            $global:MFACheckpointRowsSeen = -1

            try {
                Get-MailboxMFAReadiness -Users @('a@contoso.com', 'b@contoso.com', 'probe@contoso.com') `
                    -SkipGraphChecks -OutputPath $out | Out-Null
            }
            finally {
                $global:MFACheckpointDir = $null
            }

            # By the time the third mailbox was reached, the first two were
            # already durable. v0.10 held everything in memory until the end.
            $global:MFACheckpointRowsSeen | Should -BeGreaterOrEqual 2
        }

        It 'removes the checkpoint once the full artifacts supersede it' {
            $out = Join-Path $script:OutRoot 'checkpoint-clean'
            $run = Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks -OutputPath $out

            @(Get-ChildItem -Path $out -Filter 'MFAReport_INPROGRESS_*.csv').Count | Should -Be 0
            Test-Path $run.Artifacts['Full'] | Should -BeTrue
        }
    }

    Context 'run identity and artifacts' {

        It 'populates RunId and a distinct CorrelationId on every path' {
            $run = Get-MailboxMFAReadiness -Users @('missing@contoso.com', 'user@contoso.com') -SkipGraphChecks
            foreach ($result in $run.Results) {
                $result.RunId | Should -Be $run.RunId
                $result.CorrelationId | Should -Not -BeNullOrEmpty
            }
            @($run.Results.CorrelationId | Sort-Object -Unique).Count | Should -Be 2
        }

        It 'writes no files when OutputPath is omitted' {
            $run = Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks
            @($run.Artifacts.Keys).Count | Should -Be 0
        }

        It 'places each mailbox in exactly one artifact file' {
            $out = Join-Path $script:OutRoot 'artifacts'
            $run = Get-MailboxMFAReadiness -Users @('user@contoso.com', 'noarchive@contoso.com') `
                -SkipGraphChecks -OutputPath $out

            $ready = @(Import-Csv $run.Artifacts['Actionable'])
            $blocked = @(Import-Csv $run.Artifacts['NeedsAttention'])

            ($ready.Count + $blocked.Count) | Should -Be 2
            @($ready.User | Where-Object { $blocked.User -contains $_ }).Count | Should -Be 0
        }
    }
}

Describe 'Start-MailboxMFAProcessing' {

    BeforeEach {
        $global:MFAWriteLog.Clear()
        $global:MFAArchiveState.Clear()
    }

    It 'starts the assistant for a Ready mailbox' {
        $run = Start-MailboxMFAProcessing -Users 'user@contoso.com' -SkipGraphChecks -Confirm:$false
        $run.Results[0].Status | Should -Be 'TriggeredAwaitingAssistant'
        $global:MFAWriteLog | Should -Contain 'Start-ManagedFolderAssistant:user@contoso.com'
    }

    It 'does not start the assistant for a Blocked mailbox' {
        $run = Start-MailboxMFAProcessing -Users 'noarchive@contoso.com' -SkipGraphChecks -Confirm:$false
        $run.Results[0].Status | Should -Be 'Blocked'
        $global:MFAWriteLog | Should -BeNullOrEmpty
    }

    It 'honours -WhatIf' {
        Start-MailboxMFAProcessing -Users 'user@contoso.com' -SkipGraphChecks -WhatIf | Out-Null
        $global:MFAWriteLog | Should -BeNullOrEmpty
    }

    Context 'regression: NoEligibleItems asserted from unmeasured movement' {

        It 'reports movement as unmeasured when no monitoring window ran' {
            $run = Start-MailboxMFAProcessing -Users @('a@contoso.com', 'b@contoso.com') `
                -SkipGraphChecks -IncludeAssistantDiagnostics -Confirm:$false

            foreach ($result in $run.Results) {
                $result.MovementMeasured | Should -BeFalse
                $result.DiagnosticClassification | Should -Not -Match 'NoEligibleItems'
                $result.DiagnosticClassification | Should -Match 'movement was not measured'
            }
            $run.Summary.NoEligibleItems | Should -Be 0
            $run.Summary.MovementNotMeasured | Should -Be 2
        }

        It 'declines to monitor a multi-mailbox run and says so' {
            $warnings = @()
            Start-MailboxMFAProcessing -Users @('a@contoso.com', 'b@contoso.com') -Monitor `
                -SkipGraphChecks -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            ($warnings -join ' ') | Should -Match 'only attributable for a single mailbox'
        }
    }
}

Describe 'Repair-MailboxMFAPrerequisite' {

    BeforeEach {
        $global:MFAWriteLog.Clear()
        $global:MFAArchiveState.Clear()
    }

    Context 'refuses ambiguous or unsafe invocations' {

        It 'requires at least one remediation switch' {
            { Repair-MailboxMFAPrerequisite -Users 'user@contoso.com' -SkipGraphChecks -Confirm:$false -ErrorAction Stop } |
                Should -Throw -ExpectedMessage '*No remediation was requested*'
        }

        It 'requires -RetentionPolicyName before it will touch retention tags' {
            # v0.10 defaulted this to 'Default MRM Policy', so the default path
            # modified the tenant built-in policy.
            {
                Repair-MailboxMFAPrerequisite -Users 'user@contoso.com' -SkipGraphChecks -Confirm:$false `
                    -RetentionTag @{ Name = 'T'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = 365 } `
                    -ErrorAction Stop
            } | Should -Throw -ExpectedMessage '*require -RetentionPolicyName*'
        }

        It 'rejects an incomplete tag specification' {
            {
                Repair-MailboxMFAPrerequisite -Users 'user@contoso.com' -SkipGraphChecks -Confirm:$false `
                    -RetentionPolicyName 'Contoso MRM Policy' `
                    -RetentionTag @{ Name = 'T'; Type = 'All' } -ErrorAction Stop
            } | Should -Throw -ExpectedMessage '*missing required key*'
        }

        It 'rejects an invalid retention action' {
            {
                Repair-MailboxMFAPrerequisite -Users 'user@contoso.com' -SkipGraphChecks -Confirm:$false `
                    -RetentionPolicyName 'Contoso MRM Policy' `
                    -RetentionTag @{ Name = 'T'; Type = 'All'; RetentionAction = 'Delete'; AgeLimitForRetention = 365 } `
                    -ErrorAction Stop
            } | Should -Throw -ExpectedMessage '*invalid RetentionAction*'
        }

        It 'rejects a non-positive age limit' {
            {
                Repair-MailboxMFAPrerequisite -Users 'user@contoso.com' -SkipGraphChecks -Confirm:$false `
                    -RetentionPolicyName 'Contoso MRM Policy' `
                    -RetentionTag @{ Name = 'T'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = 0 } `
                    -ErrorAction Stop
            } | Should -Throw -ExpectedMessage '*invalid AgeLimitForRetention*'
        }
    }

    Context 'archive remediation' {

        It 'provisions a missing archive' {
            $run = Repair-MailboxMFAPrerequisite -Users 'noarchive@contoso.com' -EnableArchive `
                -SkipGraphChecks -Confirm:$false
            $global:MFAWriteLog | Should -Contain 'Enable-Mailbox:noarchive@contoso.com'
            $run.Results[0].Status | Should -Be 'Completed'
        }

        It 'leaves an existing archive alone' {
            $run = Repair-MailboxMFAPrerequisite -Users 'user@contoso.com' -EnableArchive `
                -SkipGraphChecks -Confirm:$false
            $global:MFAWriteLog | Should -BeNullOrEmpty
            $run.Results[0].Actions | Should -Match 'ArchiveAlreadyProvisioned'
        }

        It 'honours -WhatIf' {
            Repair-MailboxMFAPrerequisite -Users 'noarchive@contoso.com' -EnableArchive `
                -SkipGraphChecks -WhatIf | Out-Null
            $global:MFAWriteLog | Should -BeNullOrEmpty
        }
    }

    Context 'retention remediation' {

        It 'creates tags and policy once per run, not once per mailbox' {
            Repair-MailboxMFAPrerequisite -Users @('a@contoso.com', 'b@contoso.com', 'c@contoso.com') `
                -RetentionPolicyName 'Brand New Policy' `
                -RetentionTag @{ Name = 'Contoso 2 year archive'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = 730 } `
                -SkipGraphChecks -Confirm:$false | Out-Null

            # v0.10 ran the whole tag/policy block inside the per-mailbox loop.
            @($global:MFAWriteLog | Where-Object { $_ -like 'New-RetentionPolicyTag:*' }).Count | Should -BeLessOrEqual 1
            @($global:MFAWriteLog | Where-Object { $_ -like 'Set-Mailbox:*' }).Count | Should -Be 0
        }

        It 'only assigns the policy to mailboxes when explicitly asked' {
            # A policy name the stub mailbox is NOT already assigned, so a no-op
            # would be visible as a missing Set-Mailbox call.
            Repair-MailboxMFAPrerequisite -Users 'a@contoso.com' -RetentionPolicyName 'Different Policy' `
                -AssignPolicyToMailbox -SkipGraphChecks -Confirm:$false | Out-Null
            @($global:MFAWriteLog | Where-Object { $_ -like 'Set-Mailbox:*' }).Count | Should -Be 1
        }

        It 'does not reassign a policy the mailbox already has' {
            Repair-MailboxMFAPrerequisite -Users 'a@contoso.com' -RetentionPolicyName 'Contoso MRM Policy' `
                -AssignPolicyToMailbox -SkipGraphChecks -Confirm:$false | Out-Null
            @($global:MFAWriteLog | Where-Object { $_ -like 'Set-Mailbox:*' }).Count | Should -Be 0
        }
    }
}

Describe 'Start-MailboxMFAReport migration stub' {

    BeforeEach {
        $global:MFAWriteLog.Clear()
        $global:MFAArchiveState.Clear()
    }

    It 'throws a message naming all three replacements' {
        { Start-MailboxMFAReport -Users 'user@contoso.com' -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*Get-MailboxMFAReadiness*'
    }

    It 'explains where -AutoCreateTags went' {
        $message = try { Start-MailboxMFAReport 2>&1 | Out-String } catch { $_.Exception.Message }
        $message | Should -Match 'Repair-MailboxMFAPrerequisite'
    }
}

Describe 'Artifact reporting under -WhatIf' {

    # Export-Csv and Set-Content both honour -WhatIf, so a preview run writes
    # nothing. Export-MFAReportArtifact returned the path regardless, so the
    # cmdlets announced "report saved to <path>" and counted artifacts for files
    # that do not exist -- on exactly the preview step the README tells operators
    # to run before touching a tenant.

    BeforeEach {
        $global:MFAWriteLog.Clear()
        $global:MFAArchiveState.Clear()
    }

    It 'reports no repair artifact for a file it did not write' {
        $out = Join-Path $script:OutRoot 'whatif-repair'
        $messages = @()

        Repair-MailboxMFAPrerequisite -Users 'noarchive@contoso.com' -EnableArchive `
            -SkipGraphChecks -OutputPath $out -WhatIf `
            -InformationVariable messages -InformationAction SilentlyContinue | Out-Null

        ($messages -join ' ') | Should -Not -Match 'report saved to'
        Test-Path $out | Should -BeFalse
    }

    It 'reports no readiness artifacts for files it did not write' {
        $out = Join-Path $script:OutRoot 'whatif-processing'
        $run = Start-MailboxMFAProcessing -Users 'user@contoso.com' -SkipGraphChecks `
            -OutputPath $out -WhatIf

        @($run.Artifacts.Keys).Count | Should -Be 0
        Test-Path $out | Should -BeFalse
    }

    It 'still reports the artifacts it does write' {
        $out = Join-Path $script:OutRoot 'whatif-control'
        $run = Start-MailboxMFAProcessing -Users 'user@contoso.com' -SkipGraphChecks `
            -OutputPath $out -Confirm:$false

        @($run.Artifacts.Keys).Count | Should -BeGreaterThan 0
        foreach ($path in $run.Artifacts.Values) {
            Test-Path -LiteralPath $path | Should -BeTrue
        }
    }
}

Describe 'Run-level resilience' {


    BeforeEach {
        $global:MFAWriteLog.Clear()
        $global:MFAArchiveState.Clear()
    }

    Context 'regression: a preservation-locked policy aborted the whole run' {

        It 'completes a multi-mailbox Purview run when a locked policy matches nobody' {
            # The suite's standing stub sets RestrictiveRetention = $false, which
            # is precisely why 212 passing tests never caught this: the guard is
            # behind an -and short-circuit that only evaluates once a policy is
            # actually locked. With it locked, the run died on mailbox 1 and
            # wrote no artifacts at all.
            function global:Get-RetentionCompliancePolicy {
                param([switch]$DistributionDetail, $ErrorAction)
                @([PSCustomObject]@{
                    Name                      = 'Locked, scoped elsewhere'
                    Guid                      = '11111111-2222-3333-4444-555555555555'
                    ExchangeLocation          = @('someone.else@contoso.com')
                    ExchangeLocationException = @()
                    Applications              = 'Exchange'
                    Mode                      = 'Enforce'
                    Enabled                   = $true
                    DistributionStatus        = 'Success'
                    RestrictiveRetention      = $true
                })
            }
            try {
                $run = Get-MailboxMFAReadiness -Users @('a@contoso.com', 'b@contoso.com', 'c@contoso.com') `
                    -IncludePurviewDetails -SkipGraphChecks -WarningAction SilentlyContinue

                @($run.Results).Count | Should -Be 3
            }
            finally { Remove-Item function:global:Get-RetentionCompliancePolicy -ErrorAction SilentlyContinue }
        }
    }

    Context 'an unanticipated per-mailbox error must not discard the run' {

        It 'contains the failure, keeps the other results, and marks the one that failed' {
            # Evaluation handles the failures it anticipates. An unexpected one
            # used to escape the loop entirely, so Complete-MFAReportSession
            # never ran: a 500-mailbox sweep could die on mailbox 1 with nothing
            # to show for it.
            # A genuine result object, captured from a real evaluation, so the
            # surviving mailboxes flow through export exactly as they normally
            # would. The mock body runs in test scope, where the module's own
            # New-MFAReportResult is not visible.
            $template = (Get-MailboxMFAReadiness -Users 'user@contoso.com' -SkipGraphChecks).Results[0]

            # One mock, no ParameterFilter: this Pester does not fall through to
            # the original when a filter misses, so the body decides.
            Mock -ModuleName MailboxMFAReport Invoke-MFAReportReadinessEvaluation {
                if ($Identity -eq 'boom@contoso.com') { throw 'Simulated unexpected failure.' }
                $copy = $template.PSObject.Copy()
                $copy.User = $Identity
                $copy
            }

            $outputPath = Join-Path $script:OutRoot 'containment'
            $run = Get-MailboxMFAReadiness -Users @('user@contoso.com', 'boom@contoso.com', 'flaky@contoso.com') `
                -OutputPath $outputPath -SkipGraphChecks -WarningAction SilentlyContinue

            @($run.Results).Count | Should -Be 3

            $failed = @($run.Results | Where-Object { $_.User -eq 'boom@contoso.com' })
            $failed.Count | Should -Be 1
            $failed[0].Status | Should -Be 'Skipped'
            $failed[0].SkipReason | Should -Be 'EvaluationError'
            $failed[0].Message | Should -Match 'Simulated unexpected failure'

            # The surviving mailboxes are still evaluated normally.
            @($run.Results | Where-Object { $_.Status -eq 'Ready' }).Count | Should -Be 2

            # The real payoff: the run still reaches Complete-MFAReportSession,
            # so artifacts exist. Previously the exception escaped the loop and
            # the run produced nothing but a stack trace.
            @($run.Artifacts).Count | Should -BeGreaterThan 0
            Get-ChildItem -Path $outputPath -Filter 'MFAReport_*.csv' | Should -Not -BeNullOrEmpty
        }
    }
}
