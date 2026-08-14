#Requires -Version 5.1

<#
Read-only readiness evaluation.

This function performs NO tenant writes. Every prerequisite that v0.10 would
have silently repaired mid-report (enabling archives, creating retention tags,
assigning policies) is now reported as a Blocked result carrying the reason, and
remediation is the caller's explicit decision via Repair-MailboxMFAPrerequisite.

Status semantics -- a distinction v0.10 did not draw:
  Ready   - every prerequisite checked is satisfied; MFA is expected to process.
  Blocked - evaluated successfully, and we know why MFA will not process.
  Skipped - could not be evaluated at all (lookup or access failure).

v0.10 reported both of the latter as 'Skipped', so "this mailbox has no archive"
and "I could not read this mailbox" were indistinguishable in the report.
#>

function Invoke-MFAReportReadinessEvaluation {
    <#
    .SYNOPSIS
    Evaluates one mailbox's Managed Folder Assistant readiness without writing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache,

        [Parameter(Mandatory = $true)]
        [hashtable]$RunContext
    )

    $correlationId = [guid]::NewGuid().Guid
    $runId = [string]$RunContext.RunId

    # Every key is initialised because the module runs under Set-StrictMode
    # -Version 3.0, which throws on reading a missing hashtable key just as it
    # does for a missing object property.
    $evidence = @{
        Actions                       = [System.Collections.Generic.List[string]]::new()
        HealthWarnings                = [System.Collections.Generic.List[string]]::new()
        Context                       = [System.Collections.Generic.List[string]]::new()
        LicenseSkus                   = @()
        UsageLocation                 = $null
        AccountEnabled                = $null
        AutoExpandingArchiveEffective = $null
        EdgeCase                      = $null
        HoldRequirement               = $null
        HoldSources                   = @()
        ExcludedHolds                 = @()
        RetentionPolicyValidation     = $null
        TriggeringRetentionTags       = @()
        RetentionTagApplicability     = $null
        AssistantClassification       = $null
        DiagnosticClassification      = $null
        RecommendedNextAction         = $null
        DiagnosticParseConfidence     = 'NotCollected'
        AssistantDiagnosticsStatus    = 'NotCollected'
        AssistantRanSuccessfully      = $false
        PolicyIsValid                 = $false
        ELCLastSuccessTimestamp       = $null
        ELCItemCount                  = $null
        ELCDeletedItemCount           = $null
        ELCArchivedItemCount          = $null
        ELCLastRunTotalProcessingTime = $null
        MRMResourceUnhealthy          = $null
        WorkCycleLag                  = $null
        StoreMaintenanceBacklog       = $null
        DelayHoldApplied              = $null
        DelayReleaseHoldApplied       = $null
        ComplianceTagHoldApplied      = $null
        MRMConfigStatus               = $null
        HoldTrackingSummary           = $null
        SubstrateHoldTrackingSummary  = $null
        PurviewPolicySummary          = $null
        PurviewOverrideSignal         = $null
        MatchedPurviewPolicies        = @()
        NotEvaluatedPurviewPolicies   = @()
        FolderEvidenceSummary         = $null
        FolderTagDetails              = @()
        RecoverableItemsSummary       = $null
        RecoverableItemsPressure      = $null
        NormalMailboxItems            = $null
        ArchiveMailboxItems           = $null
        NormalMailboxSize             = $null
        ArchiveMailboxSize            = $null
        MovementMeasured              = $false
        MonitoringSamples             = 0
        MovedNormalItems              = 0
        MovedArchiveItems             = 0
        MovedNormalBytes              = [long]0
        MovedArchiveBytes             = [long]0
        RepairSuggestions             = @()
    }

    # Local helper so every early exit produces a fully-formed record.
    $newResult = {
        param([string]$User, [string]$Status, [string]$SkipReason, [string]$Message, $Mailbox)
        $evidence.RecommendedNextAction = Get-MFAReportRecommendedAction -SkipReason $SkipReason -Status $Status
        New-MFAReportResult -User $User -Status $Status -SkipReason $SkipReason -Message $Message `
            -RunId $runId -CorrelationId $correlationId -Mailbox $Mailbox -Evidence $evidence
    }

    # ---- Mailbox lookup -----------------------------------------------------
    $mailbox = $null
    try {
        $mailbox = Get-MFAReportMailbox -Identity $Identity
    }
    catch {
        $lookupError = $_.Exception.Message
        try {
            $softDeleted = Get-MFAReportMailbox -Identity $Identity -SoftDeletedMailbox
            $evidence.Actions.Add('DetectedSoftDeletedMailbox')
            $evidence.EdgeCase = 'SoftDeletedMailbox'
            $evidence.DiagnosticClassification = 'Soft-deleted mailbox edge case'
            return & $newResult $Identity 'Skipped' 'SoftDeletedMailbox' `
                'Mailbox is soft-deleted; use soft-deleted mailbox recovery before MFA remediation.' $softDeleted
        }
        catch {
            return & $newResult $Identity 'Skipped' 'MailboxLookupFailed' $lookupError $null
        }
    }

    $userIdentity = [string](Get-MFAReportPropertyValue -InputObject $mailbox -Name 'UserPrincipalName')
    if ([string]::IsNullOrWhiteSpace($userIdentity)) { $userIdentity = $Identity }
    Write-Verbose "Evaluating readiness: $userIdentity"

    $recipientType = [string](Get-MFAReportPropertyValue -InputObject $mailbox -Name 'RecipientTypeDetails')

    # ---- Licensing and directory state --------------------------------------
    if ($Config.SkipGraphChecks) {
        $skuAssigned = Get-MFAReportPropertyValue -InputObject $mailbox -Name 'SKUAssigned'
        if ($null -ne $skuAssigned) {
            $evidence.LicenseSkus = @("ExchangeSKUAssigned=$skuAssigned")
            if ($skuAssigned -eq $false) {
                $evidence.HealthWarnings.Add('Exchange reports SKUAssigned=False; Graph checks were skipped, so archive capability is not fully verified.')
            }
        }
        else {
            $evidence.LicenseSkus = @('GraphChecksSkipped')
        }
        $evidence.Actions.Add('GraphChecksSkipped')
    }
    else {
        try {
            $licenseDetail = @(Get-MgUserLicenseDetail -UserId $userIdentity -ErrorAction Stop)
            $evidence.LicenseSkus = @($licenseDetail | ForEach-Object { $_.SkuPartNumber })
        }
        catch {
            return & $newResult $userIdentity 'Skipped' 'LicenseLookupFailed' $_.Exception.Message $mailbox
        }

        if (@($evidence.LicenseSkus).Count -eq 0) {
            return & $newResult $userIdentity 'Blocked' 'NoLicense' `
                'User does not have a license required for archive processing.' $mailbox
        }

        try {
            $graphUser = Get-MgUser -UserId $userIdentity -ErrorAction Stop
            $evidence.UsageLocation = Get-MFAReportPropertyValue -InputObject $graphUser -Name 'UsageLocation'
            $accountEnabled = Get-MFAReportPropertyValue -InputObject $graphUser -Name 'AccountEnabled'
            if ($null -ne $accountEnabled) { $evidence.AccountEnabled = [string]$accountEnabled }
        }
        catch {
            $evidence.Actions.Add("GraphUserLookupWarning:$($_.Exception.Message)")
        }
    }

    # ---- Edge cases ---------------------------------------------------------
    if ((Get-MFAReportPropertyValue -InputObject $mailbox -Name 'IsInactiveMailbox') -eq $true) {
        $evidence.EdgeCase = 'InactiveMailbox'
        $evidence.HealthWarnings.Add('Inactive mailbox detected. Items are not moved from inactive mailboxes to archive; use -MfaMode InactiveMailbox only when appropriate.')
    }

    $remoteRecipientType = [string](Get-MFAReportPropertyValue -InputObject $mailbox -Name 'RemoteRecipientType')
    if ($recipientType -match 'Remote|MailUser' -or ($remoteRecipientType -and $remoteRecipientType -ne 'None')) {
        if (-not $evidence.EdgeCase) { $evidence.EdgeCase = 'HybridOrRemoteMailbox' }
        $evidence.HealthWarnings.Add('Hybrid/remote mailbox indicators detected; if the primary mailbox is on-premises, use the on-premises Exchange Management Shell path.')
    }

    if ($evidence.AccountEnabled -eq 'False' -and $recipientType -eq 'UserMailbox') {
        if (-not $evidence.EdgeCase) { $evidence.EdgeCase = 'DisabledRegularMailboxAccount' }
        $evidence.HealthWarnings.Add('Regular mailbox account is disabled; MRM may not process regular disabled-account mailboxes.')
    }

    $mailboxAutoExpanding = Get-MFAReportPropertyValue -InputObject $mailbox -Name 'AutoExpandingArchiveEnabled'
    $evidence.AutoExpandingArchiveEffective = if ($RunContext.OrganizationAutoExpandingArchive -eq $true) { 'EnabledByOrganization' }
        elseif ($mailboxAutoExpanding -eq $true) { 'EnabledByMailbox' }
        elseif ($RunContext.OrganizationAutoExpandingArchive -eq $false -or $mailboxAutoExpanding -eq $false) { 'Disabled' }
        else { 'Unknown' }

    if ($mailboxAutoExpanding -eq $false -and $evidence.AutoExpandingArchiveEffective -eq 'Disabled') {
        $evidence.RepairSuggestions += 'EnableAutoExpandingArchive'
    }

    if ($Config.Region -and $evidence.UsageLocation -and $evidence.UsageLocation -ne $Config.Region) {
        $evidence.Actions.Add("UsageLocationMismatch:$($evidence.UsageLocation)")
        Write-Warning "$userIdentity usage location is $($evidence.UsageLocation), expected $($Config.Region)."
    }

    if ($Config.RecipientTypeDetails -notcontains $recipientType) {
        return & $newResult $userIdentity 'Skipped' 'UnsupportedRecipientType' `
            "Mailbox recipient type '$recipientType' is not enabled for this run." $mailbox
    }

    # ---- Hold requirement ---------------------------------------------------
    # Evaluated before the optional deep evidence because the policy GUIDs
    # recovered from InPlaceHolds are the strongest input the Purview matcher
    # has: Exchange stating a policy is applied beats inferring it from a
    # location string.
    $holdStatus = Test-MFAReportHoldRequirement -Mailbox $mailbox -RequiredHold $Config.RequiredHold `
        -OrganizationWideHoldIds $RunContext.OrganizationWideHoldIds
    $evidence.HoldRequirement = $holdStatus.RequiredHold

    # Only holds that actually apply may vouch for a policy, so exclusions are
    # not part of this set.
    $activeHoldGuids = @(
        @($holdStatus.MailboxInPlaceHolds) + @($holdStatus.OrganizationWideHolds) |
        Where-Object { $_ -and $_.PolicyGuid } |
        ForEach-Object { $_.PolicyGuid }
    ) | Sort-Object -Unique

    if (-not $holdStatus.IsSatisfied) {
        $evidence.HoldSources   = $holdStatus.HoldSources
        $evidence.ExcludedHolds = @($holdStatus.ExcludedHolds | ForEach-Object { $_.Description })
        return & $newResult $userIdentity 'Blocked' 'HoldRequirementNotMet' `
            "Required hold state '$($Config.RequiredHold)' was not satisfied." $mailbox
    }

    $evidence.Actions.Add($(if ($Config.RequiredHold -eq 'None') { 'HoldRequirementNotEnforced' }
                            else { "HoldRequirementSatisfied:$($holdStatus.HoldSources -join ',')" }))

    # ---- Optional deep evidence ---------------------------------------------
    $assistant = $null
    if ($Config.IncludeAssistantDiagnostics) {
        $assistant = Get-MFAReportDiagnosticSignals -Identity $userIdentity -WorkCycleLagThreshold $Config.WorkCycleLagThreshold

        $evidence.AssistantDiagnosticsStatus    = $assistant.Status
        $evidence.DiagnosticParseConfidence     = $assistant.ParseConfidence
        $evidence.AssistantClassification       = $assistant.Classification
        $evidence.ELCLastSuccessTimestamp       = $assistant.ELCLastSuccessTimestamp
        $evidence.ELCItemCount                  = $assistant.ELCItemCount
        $evidence.ELCDeletedItemCount           = $assistant.ELCDeletedItemCount
        $evidence.ELCArchivedItemCount          = $assistant.ELCArchivedItemCount
        $evidence.ELCLastRunTotalProcessingTime = $assistant.ELCLastRunTotalProcessingTime
        $evidence.MRMResourceUnhealthy          = $assistant.MRMResourceUnhealthy
        $evidence.WorkCycleLag                  = $assistant.WorkCycleLag
        $evidence.StoreMaintenanceBacklog       = $assistant.StoreMaintenanceBacklog
        $evidence.DelayHoldApplied              = $assistant.DelayHoldApplied
        $evidence.DelayReleaseHoldApplied       = $assistant.DelayReleaseHoldApplied
        $evidence.ComplianceTagHoldApplied      = $assistant.ComplianceTagHoldApplied
        $evidence.MRMConfigStatus               = $assistant.MRMConfigStatus
        $evidence.HoldTrackingSummary           = $assistant.HoldTrackingSummary
        $evidence.SubstrateHoldTrackingSummary  = $assistant.SubstrateHoldTrackingSummary
        $evidence.AssistantRanSuccessfully      = -not [string]::IsNullOrWhiteSpace($assistant.ELCLastSuccessTimestamp)

        # Driven by the PARSED booleans, not by the presence of a token in the log.
        if ($assistant.IsDelayHoldApplied -eq $true -or $assistant.IsDelayReleaseHoldApplied -eq $true) {
            $evidence.HealthWarnings.Add('Delay hold evidence detected; purge behaviour may remain blocked until MFA hold cleanup completes.')
        }
        if ($assistant.IsResourceUnhealthy -eq $true) {
            $evidence.HealthWarnings.Add('MRM resource unhealthy evidence detected.')
        }
    }

    $folderEvidence = $null
    if ($Config.IncludeFolderEvidence) {
        $folderEvidence = Get-MFAReportFolderEvidence -Identity $userIdentity
        $evidence.FolderEvidenceSummary   = $folderEvidence.Summary
        $evidence.FolderTagDetails        = $folderEvidence.TaggedFolderDetails
        $evidence.RecoverableItemsSummary = $folderEvidence.RecoverableItemsSummary
        foreach ($warning in @($folderEvidence.Warnings)) { $evidence.HealthWarnings.Add($warning) }
    }

    $purview = $null
    $preservationLockOverride = $false
    if ($Config.IncludePurviewDetails) {
        $purview = Get-MFAReportPurviewSignals -Identity $userIdentity -Mailbox $mailbox `
            -Policies $RunContext.PurviewPolicies -AppPolicies $RunContext.PurviewAppPolicies `
            -MailboxHoldGuids $activeHoldGuids `
            -CollectionError $RunContext.PurviewCollectionError

        $evidence.PurviewPolicySummary        = $purview.Summary
        $evidence.MatchedPurviewPolicies      = $purview.MatchedPolicies
        $evidence.NotEvaluatedPurviewPolicies = $purview.NotEvaluatedPolicies
        $preservationLockOverride = [bool]$purview.HasPreservationLockOverride

        if ($preservationLockOverride) {
            $evidence.HealthWarnings.Add("Preservation-locked Purview policy detected; mailbox ElcProcessingDisabled may be ignored. Policies=$($purview.PreservationLockedPolicies -join ',')")
        }
    }

    # Name the holds from the policies already fetched, so the report shows a
    # policy name instead of an identifier the operator has to chase manually.
    if ($RunContext.PurviewPolicies) {
        $named = @(Resolve-MFAReportHoldPolicyName `
            -Holds @(@($holdStatus.MailboxInPlaceHolds) + @($holdStatus.OrganizationWideHolds)) `
            -Policies $RunContext.PurviewPolicies)
        $resolved = @($named | Where-Object { $_.PolicyName })
        if ($resolved.Count -gt 0) {
            $evidence.Context.Add("ResolvedHoldPolicies=$(($resolved | ForEach-Object { "$($_.HoldId)=$($_.PolicyName)" }) -join ',')")
        }
    }

    $evidence.HoldSources   = $holdStatus.HoldSources
    $evidence.ExcludedHolds = @($holdStatus.ExcludedHolds | ForEach-Object { $_.Description })

    # ---- ELC processing -----------------------------------------------------
    if ($RunContext.OrganizationElcProcessingDisabled -eq $true) {
        return & $newResult $userIdentity 'Blocked' 'OrgElcDisabled' `
            'Organization-level ELC processing is disabled, so MFA will not process mailboxes in this run.' $mailbox
    }

    if ((Get-MFAReportPropertyValue -InputObject $mailbox -Name 'ElcProcessingDisabled') -eq $true) {
        if (-not $preservationLockOverride -and -not $Config.IncludePurviewDetails -and $RunContext.PurviewAvailable) {
            # Targeted lookup: a preservation lock can legitimately override
            # mailbox-level ElcProcessingDisabled, so it is worth the cost here.
            Get-MFAReportPurviewPolicySet -RunContext $RunContext
            $purview = Get-MFAReportPurviewSignals -Identity $userIdentity -Mailbox $mailbox `
                -Policies $RunContext.PurviewPolicies -MailboxHoldGuids $activeHoldGuids `
                -CollectionError $RunContext.PurviewCollectionError
            $evidence.PurviewPolicySummary        = $purview.Summary
            $evidence.MatchedPurviewPolicies      = $purview.MatchedPolicies
            $evidence.NotEvaluatedPurviewPolicies = $purview.NotEvaluatedPolicies
            $preservationLockOverride = [bool]$purview.HasPreservationLockOverride
        }

        if ($preservationLockOverride) {
            $evidence.Actions.Add('MailboxElcProcessingDisabledIgnoredByPreservationLock')
            $evidence.HealthWarnings.Add('Mailbox ElcProcessingDisabled=True, but a preservation-locked compliance policy appears to override that setting.')
        }
        else {
            return & $newResult $userIdentity 'Blocked' 'MailboxElcDisabled' `
                'Mailbox-level ELC processing is disabled, so MFA will not process this mailbox.' $mailbox
        }
    }

    if ((Get-MFAReportPropertyValue -InputObject $mailbox -Name 'RetentionHoldEnabled') -eq $true) {
        $evidence.Actions.Add('RetentionHoldDetected')
        $evidence.HealthWarnings.Add('RetentionHoldEnabled=True; expiration from user-visible folders is blocked, but MFA may still process Recoverable Items.')
    }

    # ---- Archive readiness (reported, never repaired here) -------------------
    $archiveState = [string](Get-MFAReportPropertyValue -InputObject $mailbox -Name 'ArchiveState')
    if ($archiveState -notin @('HostedProvisioned', 'Local')) {
        $evidence.RepairSuggestions += 'EnableArchive'
        return & $newResult $userIdentity 'Blocked' 'NoArchive' `
            'Archive is missing. Use Repair-MailboxMFAPrerequisite -EnableArchive to provision it.' $mailbox
    }

    # ---- Retention configuration (reported, never repaired here) -------------
    $assignedPolicy = [string](Get-MFAReportPropertyValue -InputObject $mailbox -Name 'RetentionPolicy')
    if ([string]::IsNullOrWhiteSpace($assignedPolicy)) {
        $evidence.RepairSuggestions += 'AssignRetentionPolicy'
        return & $newResult $userIdentity 'Blocked' 'NoRetentionPolicy' `
            'Mailbox has no retention policy assigned. Use Repair-MailboxMFAPrerequisite -RetentionPolicyName to assign one.' $mailbox
    }

    $triggeringTags = @()
    if ($Config.SkipRetentionPolicyTriggerValidation) {
        $evidence.RetentionPolicyValidation = 'Skipped by parameter.'
        $evidence.Actions.Add('RetentionPolicyTriggerValidationSkipped')
        $evidence.PolicyIsValid = $true
    }
    else {
        $policyTrigger = Test-MFAReportRetentionPolicyTrigger -PolicyName $assignedPolicy `
            -RequiredRetentionActions $Config.RequiredRetentionActions -Cache $Cache

        $evidence.RetentionPolicyValidation = $policyTrigger.Message
        $triggeringTags = @($policyTrigger.TriggeringTags)
        $evidence.TriggeringRetentionTags = $triggeringTags
        $evidence.PolicyIsValid = [bool]$policyTrigger.IsValid

        if (-not $policyTrigger.IsValid) {
            $evidence.RepairSuggestions += 'ReviewRetentionPolicyTags'
            return & $newResult $userIdentity 'Blocked' 'RetentionPolicyDoesNotTriggerMFA' $policyTrigger.Message $mailbox
        }

        $evidence.Actions.Add('RetentionPolicyTriggersMFA')
    }
    $evidence.TriggeringRetentionTags = $triggeringTags

    # ---- Statistics (single sample; monitoring belongs to processing) -------
    $statistics = Measure-MFAReportMailboxMovement -Identity $userIdentity
    foreach ($action in @($statistics.Actions)) { $evidence.Actions.Add($action) }

    if (-not $statistics.StatisticsAvailable) {
        return & $newResult $userIdentity 'Skipped' 'MailboxStatisticsFailed' $statistics.ErrorMessage $mailbox
    }

    $evidence.NormalMailboxItems  = $statistics.NormalItems
    $evidence.ArchiveMailboxItems = $statistics.ArchiveItems
    $evidence.NormalMailboxSize   = $statistics.NormalSize
    $evidence.ArchiveMailboxSize  = $statistics.ArchiveSize

    if ($recipientType -eq 'UserMailbox' -and $null -ne $statistics.NormalBytes -and $statistics.NormalBytes -lt 10MB) {
        if (-not $evidence.EdgeCase) { $evidence.EdgeCase = 'SmallRegularMailbox' }
        $evidence.HealthWarnings.Add('Regular mailbox is smaller than 10 MB; MRM may not process it.')
    }

    # ---- Derived signals ----------------------------------------------------
    # Quota values are CONTEXT, not warnings. v0.10 appended them to the warning
    # list, which made every mailbox look like it had a problem.
    $quota = Get-MFAReportPropertyValue -InputObject $mailbox -Name 'RecoverableItemsQuota'
    $warningQuota = Get-MFAReportPropertyValue -InputObject $mailbox -Name 'RecoverableItemsWarningQuota'
    if ($null -ne $quota) { $evidence.Context.Add("RecoverableItemsQuota=$quota") }
    if ($null -ne $warningQuota) { $evidence.Context.Add("RecoverableItemsWarningQuota=$warningQuota") }

    $pressure = Get-MFAReportRecoverableItemsPressure `
        -RecoverableItemsBytes $(if ($folderEvidence) { $folderEvidence.RecoverableItemsBytes } else { $null }) `
        -RecoverableItemsQuota ([string]$quota) `
        -RecoverableItemsWarningQuota ([string]$warningQuota)
    $evidence.RecoverableItemsPressure = $pressure

    if ($pressure.State -in @('Critical', 'Warning')) {
        $evidence.HealthWarnings.Add("Recoverable Items pressure is $($pressure.State) at $($pressure.PercentOfQuota)% of quota.")
    }

    $taggedFolderCount = $null
    if ($folderEvidence -and $folderEvidence.Summary -match 'TaggedFolders=(\d+)') {
        $taggedFolderCount = [int]$Matches[1]
    }

    $evidence.RetentionTagApplicability = Get-MFAReportRetentionTagApplicability `
        -TriggeringTags $triggeringTags -TaggedFolderCount $taggedFolderCount

    $evidence.PurviewOverrideSignal = Get-MFAReportPurviewOverrideSignal `
        -IsComplianceTagHoldApplied $(if ($assistant) { $assistant.IsComplianceTagHoldApplied } else { $null }) `
        -MatchedPolicyCount $(if ($purview) { @($purview.MatchedPolicies).Count } else { 0 }) `
        -ConfirmedPolicyCount $(if ($purview) { @($purview.MatchedPolicies | Where-Object { $_.MatchConfidence -eq 'Confirmed' }).Count } else { 0 }) `
        -NotEvaluatedPolicyCount $(if ($purview) { @($purview.NotEvaluatedPolicies).Count } else { 0 }) `
        -HasPreservationLock:$preservationLockOverride `
        -RetentionTagApplicability $evidence.RetentionTagApplicability

    # Anchored: an unanchored 'PurviewOverride' also matches the NEGATIVE signal
    # value, which would file "no override found" as a warning -- the same
    # substring-match failure this rewrite exists to remove.
    if ($evidence.PurviewOverrideSignal -match '^(Possible)?PurviewOverride:') {
        $evidence.HealthWarnings.Add($evidence.PurviewOverrideSignal)
    }

    $evidence.DiagnosticClassification = Get-MFAReportDiagnosticClassification `
        -AssistantRanSuccessfully:$evidence.AssistantRanSuccessfully `
        -PolicyIsValid:$evidence.PolicyIsValid `
        -AssistantClassification $evidence.AssistantClassification `
        -HealthWarnings @($evidence.HealthWarnings)

    $evidence.RecommendedNextAction = Get-MFAReportRecommendedAction `
        -Status 'Ready' `
        -DiagnosticClassification $evidence.DiagnosticClassification `
        -HealthWarnings @($evidence.HealthWarnings) `
        -EdgeCase $evidence.EdgeCase

    return New-MFAReportResult -User $userIdentity -Status 'Ready' `
        -Message 'All checked prerequisites are satisfied.' `
        -RunId $runId -CorrelationId $correlationId -Mailbox $mailbox -Evidence $evidence
}
