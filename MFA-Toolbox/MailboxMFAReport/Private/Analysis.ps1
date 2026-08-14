#Requires -Version 5.1

<#
Interpretation layer: turns collected evidence into a classification and a
recommended next action.

Two v0.10 defects are addressed structurally here.

1. Informational context was appended to $mailboxHealthWarnings, so
   .Count -gt 0 was ALWAYS true. That made every mailbox classify as
   'Mailbox health or policy context warnings' and every recommendation read
   'Review mailbox health warnings before remediation.' Context and warnings
   are now separate inputs.

2. 'NoEligibleItems' was concluded from movement counters that are only
   populated during single-mailbox monitoring. In a multi-mailbox run they were
   always zero, so the tool asserted "no movement was detected" about a
   quantity it never measured. MovementMeasured is now an explicit input and
   the conclusion requires it.
#>

function Get-MFAReportRecoverableItemsPressure {
    <#
    .SYNOPSIS
    Compares Recoverable Items consumption against quota.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$RecoverableItemsBytes,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecoverableItemsQuota,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecoverableItemsWarningQuota
    )

    $result = [ordered]@{
        State                = 'NotCalculated'
        PercentOfQuota       = $null
        PercentOfWarning     = $null
        UsedBytes            = $RecoverableItemsBytes
        Quota                = $RecoverableItemsQuota
        WarningQuota         = $RecoverableItemsWarningQuota
    }

    if ($null -eq $RecoverableItemsBytes) {
        return [PSCustomObject]$result
    }

    $quotaBytes = Convert-MFAReportSizeToBytes -SizeString $RecoverableItemsQuota
    $warningBytes = Convert-MFAReportSizeToBytes -SizeString $RecoverableItemsWarningQuota

    # An unlimited or unparseable quota yields $null, which must NOT be treated
    # as a zero-byte quota. v0.10 collapsed both to 0 and reported 'Unknown'.
    if ($null -eq $quotaBytes -or $quotaBytes -le 0) {
        $result.State = 'NoQuotaLimitDetected'
        return [PSCustomObject]$result
    }

    $result.PercentOfQuota = [Math]::Round(($RecoverableItemsBytes / $quotaBytes) * 100, 2)
    if ($null -ne $warningBytes -and $warningBytes -gt 0) {
        $result.PercentOfWarning = [Math]::Round(($RecoverableItemsBytes / $warningBytes) * 100, 2)
    }

    $result.State = if ($result.PercentOfQuota -ge 95) {
        'Critical'
    }
    elseif ($null -ne $warningBytes -and $warningBytes -gt 0 -and $RecoverableItemsBytes -ge $warningBytes) {
        'Warning'
    }
    elseif ($result.PercentOfQuota -ge 80) {
        'Elevated'
    }
    else {
        'Healthy'
    }

    return [PSCustomObject]$result
}

function Get-MFAReportDiagnosticClassification {
    <#
    .SYNOPSIS
    Produces the overall per-mailbox classification.

    .PARAMETER MovementMeasured
    Whether a monitoring window actually sampled mailbox statistics more than
    once. Without this, "no movement" is an unmeasured quantity and must not be
    reported as a finding.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [switch]$AssistantRanSuccessfully,

        [Parameter()]
        [switch]$MovementMeasured,

        [Parameter()]
        [switch]$NoMovementDetected,

        [Parameter()]
        [switch]$PolicyIsValid,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AssistantClassification,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$HealthWarnings = @()
    )

    if ($AssistantRanSuccessfully -and $PolicyIsValid -and $MovementMeasured -and $NoMovementDetected) {
        return 'NoEligibleItems: MFA ran successfully, policy is valid, and no movement was detected over the monitored window.'
    }

    if ($AssistantRanSuccessfully -and $PolicyIsValid -and -not $MovementMeasured) {
        return 'Assistant ran and policy is valid, but item movement was not measured in this run. Re-run against a single mailbox to sample movement.'
    }

    if (-not [string]::IsNullOrWhiteSpace($AssistantClassification)) {
        return $AssistantClassification
    }

    if ($null -ne $HealthWarnings -and $HealthWarnings.Count -gt 0) {
        return 'Mailbox health or policy context warnings'
    }

    return 'No diagnostic blocker identified by collected checks'
}

function Get-MFAReportRecommendedAction {
    <#
    .SYNOPSIS
    Maps a result to the next troubleshooting step.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Status,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SkipReason,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DiagnosticClassification,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$HealthWarnings = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$EdgeCase
    )

    switch ($SkipReason) {
        'NoArchive'                        { return 'Enable the archive: Repair-MailboxMFAPrerequisite -Users <identity> -EnableArchive. Preview with -WhatIf first.' }
        'ArchiveEnableFailed'              { return 'Review archive enablement failure and licensing, then retry.' }
        'ArchiveEnableNotConfirmed'        { return 'Re-run and confirm the archive enablement prompt, or pre-enable the archive out of band.' }
        'NoRetentionPolicy'                { return 'Assign an appropriate retention policy before starting MFA.' }
        'RetentionPolicyDoesNotTriggerMFA' { return 'Review policy tags, scope, and folder applicability; do not create generic tags until an MRM design gap is proven.' }
        'RetentionTagError'                { return 'Retention tag creation or lookup failed. Verify Exchange Online RBAC covers retention tag management, then retry.' }
        'RetentionPolicyError'             { return 'Retention policy creation, update, or assignment failed. Verify RBAC and policy name, then retry.' }
        'OrgElcDisabled'                   { return 'Enable organization-level ELC processing before starting MFA.' }
        'MailboxElcDisabled'               { return 'Enable ELC processing on the mailbox before starting MFA, unless a preservation-locked compliance policy intentionally overrides it.' }
        'RetentionHold'                    { return 'Retention hold blocks expiration in user-visible folders, but MFA may still process Recoverable Items; validate the target workload before changing hold state.' }
        'HoldRequirementNotMet'            { return 'Review the -RequiredHold parameter; normal MFA troubleshooting usually does not require a hold.' }
        'UnsupportedRecipientType'         { return 'Add the recipient type with -RecipientTypeDetails only if this scenario is supported.' }
        'LicenseLookupFailed'              { return 'Retry with Graph access or use -SkipGraphChecks for Exchange-only diagnostics.' }
        'NoLicense'                        { return 'Assign a license that includes Exchange Online archiving before expecting MFA to process the mailbox.' }
        'MailboxLookupFailed'              { return 'Verify the identity resolves in Exchange Online and that the run has RBAC visibility of the mailbox.' }
        'MailboxStatisticsFailed'          { return 'Collect mailbox statistics manually and escalate if statistics access fails.' }
        'SoftDeletedMailbox'               { return 'Use soft-deleted mailbox recovery/restore workflow; do not run standard MFA remediation.' }
    }

    if ($EdgeCase -eq 'InactiveMailbox') {
        return 'Use inactive-mailbox-specific workflow; consider Start-ManagedFolderAssistant -InactiveMailbox only when appropriate.'
    }

    $joinedWarnings = ($HealthWarnings -join '; ')

    if ($joinedWarnings -match 'Delay hold') {
        return 'Run hold-cleanup workflow when approved; consider Start-ManagedFolderAssistant -HoldCleanup.'
    }

    if ($DiagnosticClassification -match 'movement was not measured') {
        return 'Re-run against this mailbox alone so the monitoring window can sample archive and folder movement.'
    }

    if ($DiagnosticClassification -match 'NoEligibleItems') {
        return 'No immediate remediation; validate folder/tag scope if the customer expected eligible items.'
    }

    if ($DiagnosticClassification -match 'throttled|resource unhealthy') {
        return 'Wait for backend processing; escalate with MRM diagnostics if SLA is exceeded.'
    }

    if ($DiagnosticClassification -match 'MFA execution status unknown|diagnostics unavailable|collection failed') {
        return 'Collect Export-MailboxDiagnosticLogs MRM/HoldTracking evidence or escalate with the available report.'
    }

    if ($null -ne $HealthWarnings -and $HealthWarnings.Count -gt 0) {
        return 'Review mailbox health warnings before remediation.'
    }

    if ($Status -eq 'TriggeredAwaitingAssistant') {
        return 'MFA was triggered asynchronously; monitor assistant completion within the expected service processing window and compare archive/folder deltas later.'
    }

    return 'No action identified by collected checks.'
}
