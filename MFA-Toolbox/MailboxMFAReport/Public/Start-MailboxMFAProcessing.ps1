#Requires -Version 5.1

function Start-MailboxMFAProcessing {
    <#
    .SYNOPSIS
    Starts the Managed Folder Assistant for mailboxes that pass readiness checks.

    .DESCRIPTION
    Runs the same read-only readiness evaluation as Get-MailboxMFAReadiness, then triggers the
    Managed Folder Assistant for every mailbox that came back Ready. Mailboxes that are Blocked or
    Skipped are reported and left alone.

    This cmdlet performs exactly one kind of tenant action: starting the assistant. It will not
    provision archives or touch retention configuration -- that is Repair-MailboxMFAPrerequisite's
    job. v0.10 combined all three behind a single command whose documented purpose was reporting.

    Starting the assistant is asynchronous and does not prove completion. For a single mailbox,
    -Monitor samples mailbox and archive statistics over the monitoring window so the report can
    distinguish "MFA ran and there was nothing eligible" from "movement was never measured".

    .PARAMETER Users
    Mailbox identities or user principal names. Supports pipeline input, including piping the
    output of Get-MailboxMFAReadiness.

    .PARAMETER MfaMode
    Which assistant path to use. FullCrawl, HoldCleanup, and InactiveMailbox are scenario-specific
    remediation paths and all honour -WhatIf and -Confirm.

    .PARAMETER Monitor
    Samples statistics over the monitoring window after triggering. Only meaningful for a
    single-mailbox run; ignored otherwise, since deltas cannot be attributed across a population.

    .PARAMETER DurationInMinutes
    Total monitoring duration when -Monitor is supplied.

    .PARAMETER CheckIntervalSeconds
    How often statistics are sampled during monitoring.

    .PARAMETER RequiredHold
    Which hold requirement must be satisfied before MFA is started. Defaults to None.

    .PARAMETER RequiredRetentionActions
    Retention actions that count as MFA-triggering when validating the assigned policy.

    .PARAMETER SkipRetentionPolicyTriggerValidation
    Skips inspection of the assigned retention policy's tags.

    .PARAMETER RecipientTypeDetails
    Recipient types supported by the run.

    .PARAMETER IncludeAssistantDiagnostics
    Collects Export-MailboxDiagnosticLogs evidence. High-cost.

    .PARAMETER IncludeFolderEvidence
    Collects folder-level evidence via Get-MailboxFolderStatistics. High-cost.

    .PARAMETER IncludePurviewDetails
    Collects Purview retention policy context, fetched once per run.

    .PARAMETER WorkCycleLagThreshold
    Optional TimeSpan above which a reported work cycle lag counts as a throttling signal.

    .PARAMETER SkipGraphChecks
    Skips Microsoft Graph license, usage location, and account-enabled checks.

    .PARAMETER Region
    Optional UsageLocation value to compare against Microsoft Graph user data.

    .PARAMETER OutputPath
    Directory for CSV artifacts. Omit to return results without writing files.

    .PARAMETER IncludeJsonOutput
    Also writes the full result set as JSON.

    .PARAMETER CritSitMode
    Adds an escalation-focused CSV for CritSit or PG handoff.

    .PARAMETER LogPath
    Optional transcript path.

    .EXAMPLE
    Start-MailboxMFAProcessing -Users user@contoso.com -WhatIf

    Shows which mailboxes would have the assistant started, without starting it.

    .EXAMPLE
    Start-MailboxMFAProcessing -Users user@contoso.com -Monitor -IncludeAssistantDiagnostics -CritSitMode

    Triggers MFA and then samples movement for 15 minutes so the classification is based on
    measured data rather than an assumption.

    .NOTES
    Requires Exchange Online PowerShell with permission to run Start-ManagedFolderAssistant.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is invoked by Invoke-MFAReportAssistantStart against this cmdlet''s $PSCmdlet, passed through AssistantOptions, so prompts and -WhatIf are attributed here.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('UserPrincipalName', 'Identity', 'PrimarySmtpAddress', 'User')]
        [string[]]$Users,

        [Parameter()]
        [ValidateSet('Standard', 'FullCrawl', 'HoldCleanup', 'InactiveMailbox')]
        [string]$MfaMode = 'Standard',

        [Parameter()]
        [switch]$Monitor,

        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$DurationInMinutes = 15,

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$CheckIntervalSeconds = 300,

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
            -RequireMfaStart `
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

            # Monitoring deltas cannot be attributed to a specific mailbox across
            # a population, so it is only offered for a single-mailbox run.
            $canMonitor = $Monitor -and $session.RunContext.SingleUser
            if ($Monitor -and -not $session.RunContext.SingleUser) {
                Write-Warning '-Monitor was requested for a multi-mailbox run and will be ignored; movement deltas are only attributable for a single mailbox.'
            }

            $assistantOptions = @{
                MfaMode              = $MfaMode
                Monitor              = $canMonitor
                DurationInMinutes    = $DurationInMinutes
                CheckIntervalSeconds = $CheckIntervalSeconds
                Cmdlet               = $PSCmdlet
            }

            $session.Results = Invoke-MFAReportPopulation `
                -Users $session.Users `
                -Config $config `
                -Cache $session.Cache `
                -RunContext $session.RunContext `
                -Activity 'Starting Managed Folder Assistant' `
                -AssistantOptions $assistantOptions `
                -CheckpointPath (Initialize-MFAReportCheckpoint -Session $session -OutputPath $OutputPath)

            return Complete-MFAReportSession -Session $session -OutputPath $OutputPath `
                -IncludeJsonOutput:$IncludeJsonOutput -CritSitMode:$CritSitMode
        }
        finally {
            Stop-MFAReportSession -Session $session
        }
    }
}
