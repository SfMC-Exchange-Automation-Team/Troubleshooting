#Requires -Version 5.1

function Get-MailboxMFAReadiness {
    <#
    .SYNOPSIS
    Reports Managed Folder Assistant readiness for one or more Exchange Online mailboxes. Read-only.

    .DESCRIPTION
    Evaluates licensing, mailbox type, archive provisioning, ELC processing, hold state, retention
    policy configuration, and optional assistant, folder, and Purview evidence. Makes NO tenant
    changes of any kind.

    This replaces the read path of Start-MFAReport_v0.10.ps1, which interleaved reporting with
    tenant remediation. Prerequisites that are missing are now reported as Blocked results carrying
    a reason and a RepairSuggestions list; acting on them is an explicit, separate decision made
    through Repair-MailboxMFAPrerequisite.

    Status values:
      Ready   - every prerequisite checked is satisfied; MFA is expected to process the mailbox.
      Blocked - evaluated successfully, and the reason MFA will not process it is known.
      Skipped - could not be evaluated (lookup, licensing, or statistics access failure).

    v0.10 reported the last two identically, so "this mailbox has no archive" and "I could not read
    this mailbox" were indistinguishable in the output.

    .PARAMETER Users
    Mailbox identities or user principal names to evaluate. Supports pipeline input.

    .PARAMETER RequiredHold
    Which hold requirement must be satisfied. Defaults to None because a hold is not a general
    prerequisite for MFA. Holds that explicitly EXCLUDE the mailbox (a leading '-' or a ':2' suffix)
    do not count toward satisfying this.

    .PARAMETER RequiredRetentionActions
    Retention actions that count as MFA-triggering when validating the assigned policy.

    .PARAMETER SkipRetentionPolicyTriggerValidation
    Skips inspection of the assigned retention policy's tags.

    .PARAMETER RecipientTypeDetails
    Recipient types supported by the run. Defaults to UserMailbox and SharedMailbox.

    .PARAMETER IncludeAssistantDiagnostics
    Collects Export-MailboxDiagnosticLogs evidence. High-cost; prefer exception-only collection.

    .PARAMETER IncludeFolderEvidence
    Collects folder-level policy and age evidence via Get-MailboxFolderStatistics. High-cost.

    .PARAMETER IncludePurviewDetails
    Collects Purview retention policy context. Policies are fetched once per run, not per mailbox.

    .PARAMETER WorkCycleLagThreshold
    Optional TimeSpan above which a reported work cycle lag is treated as a throttling signal. Left
    unset, lag is reported but never classified, because the healthy baseline is not documented.

    .PARAMETER SkipGraphChecks
    Skips Microsoft Graph license, usage location, and account-enabled checks.

    .PARAMETER Region
    Optional UsageLocation value to compare against Microsoft Graph user data.

    .PARAMETER OutputPath
    Directory for CSV artifacts. Omit to return results without writing any files.

    .PARAMETER IncludeJsonOutput
    Also writes the full result set as JSON, serialised from the structured (unflattened) results.

    .PARAMETER CritSitMode
    Adds an escalation-focused CSV keeping only the fields most useful for CritSit or PG handoff.

    .PARAMETER LogPath
    Optional transcript path for troubleshooting and audit logging.

    .EXAMPLE
    Get-MailboxMFAReadiness -Users user@contoso.com

    Evaluates one mailbox and returns the result. Writes nothing and changes nothing.

    .EXAMPLE
    Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt) -OutputPath C:\temp -CritSitMode

    .EXAMPLE
    (Get-MailboxMFAReadiness -Users user@contoso.com).Results |
        Where-Object Status -eq 'Blocked' |
        Repair-MailboxMFAPrerequisite -EnableArchive -WhatIf

    Feeds blocked mailboxes into remediation, previewing the changes first. This cmdlet returns one
    run object per run (RunId/Summary/Results/Artifacts), so the per-mailbox records come from
    .Results -- piping the run object itself matches nothing.

    .OUTPUTS
    PSCustomObject with RunId, Summary, Results, and Artifacts. Results holds one record per mailbox.

    .NOTES
    Requires Exchange Online PowerShell. Microsoft Graph PowerShell is recommended for license,
    usage location, and account-enabled checks; use -SkipGraphChecks without it.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('UserPrincipalName', 'Identity', 'PrimarySmtpAddress', 'User')]
        [string[]]$Users,

        [Parameter()]
        [ValidateSet('None', 'Any', 'LitigationHold', 'MailboxOrOrgWideHold', 'LitigationHoldOrOrgWideHold')]
        [string]$RequiredHold = 'None',

        [Parameter()]
        [ValidateSet('MoveToArchive', 'DeleteAndAllowRecovery', 'PermanentlyDelete', 'MarkAsPastRetentionLimit')]
        [string[]]$RequiredRetentionActions = @('MoveToArchive', 'DeleteAndAllowRecovery', 'PermanentlyDelete', 'MarkAsPastRetentionLimit'),

        [Parameter()]
        [switch]$SkipRetentionPolicyTriggerValidation,

        [Parameter()]
        [ValidateSet('UserMailbox', 'SharedMailbox')]
        [string[]]$RecipientTypeDetails = @('UserMailbox', 'SharedMailbox'),

        [Parameter()]
        [switch]$IncludeAssistantDiagnostics,

        [Parameter()]
        [switch]$IncludeFolderEvidence,

        [Parameter()]
        [switch]$IncludePurviewDetails,

        [Parameter()]
        [Nullable[TimeSpan]]$WorkCycleLagThreshold,

        [Parameter()]
        [switch]$SkipGraphChecks,

        [Parameter()]
        [string]$Region,

        [Parameter()]
        [string]$OutputPath,

        [Parameter()]
        [switch]$IncludeJsonOutput,

        [Parameter()]
        [switch]$CritSitMode,

        [Parameter()]
        [string]$LogPath
    )

    begin {
        $inputUsers = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($user in $Users) {
            if (-not [string]::IsNullOrWhiteSpace($user)) { $inputUsers.Add($user.Trim()) }
        }
    }

    end {
        $session = Start-MFAReportSession `
            -Users $inputUsers `
            -LogPath $LogPath `
            -SkipGraphChecks:$SkipGraphChecks `
            -SkipRetentionPolicyTriggerValidation:$SkipRetentionPolicyTriggerValidation `
            -IncludeAssistantDiagnostics:$IncludeAssistantDiagnostics `
            -IncludeFolderEvidence:$IncludeFolderEvidence `
            -IncludePurviewDetails:$IncludePurviewDetails

        if (-not $session.IsReady) { return }

        try {
            $config = @{
                RequiredHold                         = $RequiredHold
                RequiredRetentionActions             = $RequiredRetentionActions
                SkipRetentionPolicyTriggerValidation = [bool]$SkipRetentionPolicyTriggerValidation
                RecipientTypeDetails                 = $RecipientTypeDetails
                IncludeAssistantDiagnostics          = [bool]$IncludeAssistantDiagnostics
                IncludeFolderEvidence                = [bool]$IncludeFolderEvidence
                IncludePurviewDetails                = [bool]$IncludePurviewDetails
                WorkCycleLagThreshold                = $(if ($PSBoundParameters.ContainsKey('WorkCycleLagThreshold')) { $WorkCycleLagThreshold } else { $null })
                SkipGraphChecks                      = [bool]$SkipGraphChecks
                Region                               = $Region
            }

            $results = Invoke-MFAReportPopulation `
                -Users $session.Users `
                -Config $config `
                -Cache $session.Cache `
                -RunContext $session.RunContext `
                -Activity 'Evaluating Managed Folder Assistant readiness' `
                -CheckpointPath (Initialize-MFAReportCheckpoint -Session $session -OutputPath $OutputPath)

            $session.Results = $results

            return Complete-MFAReportSession -Session $session -OutputPath $OutputPath `
                -IncludeJsonOutput:$IncludeJsonOutput -CritSitMode:$CritSitMode
        }
        finally {
            Stop-MFAReportSession -Session $session
        }
    }
}
