#Requires -Version 5.1

<#
Run-level concerns shared by every public cmdlet: preflight validation,
once-per-run context, the mailbox loop, and export.

Factored out so Get-MailboxMFAReadiness, Start-MailboxMFAProcessing, and
Repair-MailboxMFAPrerequisite do not each carry their own copy of the transcript,
connection-check, dedupe, and artifact-writing plumbing.
#>

function Test-MFAReportPrerequisite {
    <#
    .SYNOPSIS
    Verifies that the required cmdlets are present and the sessions are live.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [switch]$SkipGraphChecks,
        [Parameter()] [switch]$RequireMfaStart,
        [Parameter()] [switch]$RequireArchiveRepair,
        [Parameter()] [switch]$RequireRetentionRepair,
        [Parameter()] [switch]$SkipRetentionPolicyTriggerValidation,
        [Parameter()] [switch]$IncludeAssistantDiagnostics,
        [Parameter()] [switch]$IncludeFolderEvidence
    )

    $required = [System.Collections.Generic.List[string]]::new()
    @('Get-Mailbox', 'Get-MailboxStatistics', 'Get-OrganizationConfig') | ForEach-Object { $required.Add($_) }

    if (-not $SkipGraphChecks) { @('Get-MgUser', 'Get-MgUserLicenseDetail') | ForEach-Object { $required.Add($_) } }
    if ($RequireMfaStart) { $required.Add('Start-ManagedFolderAssistant') }
    if (-not $SkipRetentionPolicyTriggerValidation) {
        @('Get-RetentionPolicy', 'Get-RetentionPolicyTag') | ForEach-Object { $required.Add($_) }
    }
    if ($IncludeAssistantDiagnostics) { $required.Add('Export-MailboxDiagnosticLogs') }
    if ($IncludeFolderEvidence) { $required.Add('Get-MailboxFolderStatistics') }
    if ($RequireArchiveRepair) { @('Enable-Mailbox', 'Set-Mailbox') | ForEach-Object { $required.Add($_) } }
    if ($RequireRetentionRepair) {
        @('Get-RetentionPolicy', 'Get-RetentionPolicyTag', 'New-RetentionPolicy',
          'Set-RetentionPolicy', 'New-RetentionPolicyTag', 'Set-Mailbox') | ForEach-Object { $required.Add($_) }
    }

    $missing = @($required | Sort-Object -Unique | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -gt 0) {
        return [PSCustomObject]@{
            IsSatisfied = $false
            Message     = "Missing required commands: $($missing -join ', '). Connect or import the required modules before running, or use -SkipGraphChecks when only Graph commands are unavailable."
        }
    }

    try {
        # Cheaper than v0.10's Get-Mailbox -ResultSize 1, which enumerated the
        # tenant purely to prove the session was alive.
        Get-OrganizationConfig -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    }
    catch {
        return [PSCustomObject]@{
            IsSatisfied = $false
            Message     = "Failed to reach Exchange Online. Connect Exchange Online PowerShell before running. $($_.Exception.Message)"
        }
    }

    if (-not $SkipGraphChecks) {
        try {
            Get-MgUser -Top 1 -ErrorAction Stop | Out-Null
        }
        catch {
            return [PSCustomObject]@{
                IsSatisfied = $false
                Message     = "Failed to reach Microsoft Graph. Connect with permissions for Get-MgUser and Get-MgUserLicenseDetail, or re-run with -SkipGraphChecks. $($_.Exception.Message)"
            }
        }
    }

    return [PSCustomObject]@{ IsSatisfied = $true; Message = $null }
}

function Get-MFAReportRunContext {
    <#
    .SYNOPSIS
    Fetches organization and Purview state once for the whole run.

    .DESCRIPTION
    v0.10 called Get-RetentionCompliancePolicy -DistributionDetail once per
    MAILBOX. It is among the most expensive calls in the compliance shell, and
    its result is identical for every mailbox in the run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()] [switch]$IncludePurviewDetails
    )

    $context = @{
        RunId                             = $null
        SingleUser                        = $false
        OrganizationWideHoldIds           = @()
        OrganizationAutoExpandingArchive  = $null
        OrganizationElcProcessingDisabled = $null
        OrganizationConfigError           = $null
        PurviewPolicies                   = $null
        PurviewAppPolicies                = $null
        PurviewCollectionError            = $null
        PurviewAvailable                  = $false
    }

    try {
        $organizationConfig = Get-OrganizationConfig -ErrorAction Stop
        $context.OrganizationWideHoldIds = @(
            Get-MFAReportPropertyValue -InputObject $organizationConfig -Name 'InPlaceHolds' |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

        $autoExpanding = Get-MFAReportPropertyValue -InputObject $organizationConfig -Name 'AutoExpandingArchiveEnabled'
        if ($null -ne $autoExpanding) { $context.OrganizationAutoExpandingArchive = [bool]$autoExpanding }

        $elcDisabled = Get-MFAReportPropertyValue -InputObject $organizationConfig -Name 'ElcProcessingDisabled'
        if ($null -ne $elcDisabled) { $context.OrganizationElcProcessingDisabled = [bool]$elcDisabled }
    }
    catch {
        $context.OrganizationConfigError = $_.Exception.Message
    }

    if (Get-Command Get-RetentionCompliancePolicy -ErrorAction SilentlyContinue) {
        $context.PurviewAvailable = $true
        if ($IncludePurviewDetails) {
            try {
                $context.PurviewPolicies = @(Get-RetentionCompliancePolicy -DistributionDetail -ErrorAction Stop)
            }
            catch {
                $context.PurviewCollectionError = $_.Exception.Message
            }
        }
    }

    if ($IncludePurviewDetails -and (Get-Command Get-AppRetentionCompliancePolicy -ErrorAction SilentlyContinue)) {
        try {
            $context.PurviewAppPolicies = @(Get-AppRetentionCompliancePolicy -ErrorAction Stop)
        }
        catch {
            Write-Verbose "App retention compliance policy lookup failed: $($_.Exception.Message)"
        }
    }

    return $context
}

function Get-MFAReportPurviewPolicySet {
    <#
    .SYNOPSIS
    Lazily fetches Purview policies into the run context on first use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RunContext
    )

    if ($null -ne $RunContext.PurviewPolicies -or $RunContext.PurviewCollectionError) { return }
    if (-not $RunContext.PurviewAvailable) { return }

    try {
        $RunContext.PurviewPolicies = @(Get-RetentionCompliancePolicy -DistributionDetail -ErrorAction Stop)
    }
    catch {
        $RunContext.PurviewCollectionError = $_.Exception.Message
    }
}

function Start-MFAReportSession {
    <#
    .SYNOPSIS
    Performs preflight, opens the transcript, and builds the shared run state.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds in-memory run state and optionally opens a transcript; performs no tenant writes.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Users,

        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$LogPath,
        [Parameter()] [switch]$SkipGraphChecks,
        [Parameter()] [switch]$RequireMfaStart,
        [Parameter()] [switch]$RequireArchiveRepair,
        [Parameter()] [switch]$RequireRetentionRepair,
        [Parameter()] [switch]$SkipRetentionPolicyTriggerValidation,
        [Parameter()] [switch]$IncludeAssistantDiagnostics,
        [Parameter()] [switch]$IncludeFolderEvidence,
        [Parameter()] [switch]$IncludePurviewDetails
    )

    $session = @{
        IsReady           = $false
        RunId             = [guid]::NewGuid().Guid
        Users             = @()
        Cache             = $null
        RunContext        = $null
        Results           = @()
        TranscriptStarted = $false
        ExportCompleted   = $false
        OutputPath        = $null
        CheckpointPath    = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $logDirectory = Split-Path -Path $LogPath -Parent
        if ($logDirectory) { Initialize-MFAReportOutputDirectory -Path $logDirectory -Confirm:$false }
        Start-Transcript -Path $LogPath -Append | Out-Null
        $session.TranscriptStarted = $true
    }

    $preflight = Test-MFAReportPrerequisite `
        -SkipGraphChecks:$SkipGraphChecks `
        -RequireMfaStart:$RequireMfaStart `
        -RequireArchiveRepair:$RequireArchiveRepair `
        -RequireRetentionRepair:$RequireRetentionRepair `
        -SkipRetentionPolicyTriggerValidation:$SkipRetentionPolicyTriggerValidation `
        -IncludeAssistantDiagnostics:$IncludeAssistantDiagnostics `
        -IncludeFolderEvidence:$IncludeFolderEvidence

    if (-not $preflight.IsSatisfied) {
        Write-Error $preflight.Message
        return $session
    }

    $unique = @($Users | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
    if ($unique.Count -eq 0) {
        Write-Error 'No mailboxes provided. Please specify at least one mailbox.'
        return $session
    }

    if ($unique.Count -gt 1 -and ($IncludeAssistantDiagnostics -or $IncludeFolderEvidence -or $IncludePurviewDetails)) {
        Write-Warning 'Deep diagnostics were requested for a multi-mailbox run. Export-MailboxDiagnosticLogs, folder statistics, and Purview lookups are high-cost; prefer exception-only collection for large tenants.'
    }

    $runContext = Get-MFAReportRunContext -IncludePurviewDetails:$IncludePurviewDetails
    $runContext.RunId = $session.RunId
    $runContext.SingleUser = ($unique.Count -eq 1)

    if ($runContext.OrganizationConfigError) {
        Write-Warning "Unable to read organization configuration. Organization-wide hold and ELC state are unknown. $($runContext.OrganizationConfigError)"
    }

    $session.Users = $unique
    $session.RunContext = $runContext
    $session.Cache = New-MFAReportRunCache
    $session.IsReady = $true

    return $session
}

function Invoke-MFAReportPopulation {
    <#
    .SYNOPSIS
    Runs readiness evaluation across the population with progress reporting.

    .PARAMETER AssistantOptions
    When supplied, each Ready mailbox is passed to Invoke-MFAReportAssistantStart
    with these options (MfaMode, Monitor, DurationInMinutes, CheckIntervalSeconds,
    Cmdlet). Omit for a purely read-only run.

    .PARAMETER CheckpointPath
    When supplied, each result is appended to this CSV as soon as it completes.
    v0.10 held every result in memory and wrote nothing until the loop finished,
    so a throttle, token expiry, or Ctrl-C partway through discarded the entire
    run. The file is removed on successful completion, when the full artifacts
    supersede it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)] [string[]]$Users,
        [Parameter(Mandatory = $true)] [hashtable]$Config,
        [Parameter(Mandatory = $true)] [hashtable]$Cache,
        [Parameter(Mandatory = $true)] [hashtable]$RunContext,
        [Parameter(Mandatory = $true)] [string]$Activity,
        [Parameter()] [AllowNull()] [hashtable]$AssistantOptions,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$CheckpointPath
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($user in $Users) {
        $index++
        Write-Progress -Activity $Activity -Status "$index of $($Users.Count): $user" `
            -PercentComplete (($index / $Users.Count) * 100)

        # Per-mailbox containment. Evaluation handles the failures it anticipates
        # (lookup, licensing, statistics) and returns Skipped for them, but an
        # UNANTICIPATED error -- a property Exchange stopped returning, an
        # unexpected object shape -- used to escape all the way out of the run.
        # That defeated the checkpoint, because Complete-MFAReportSession never
        # ran and no artifacts were written: a 500-mailbox sweep could die on
        # mailbox 1 and produce nothing but an exception.
        $result = $null
        try {
            $result = Invoke-MFAReportReadinessEvaluation -Identity $user -Config $Config `
                -Cache $Cache -RunContext $RunContext

            if ($AssistantOptions -and $result) {
                $result = Invoke-MFAReportAssistantStart -Result $result -Options $AssistantOptions
            }
        }
        catch {
            Write-Warning "Evaluation failed for ${user}: $($_.Exception.Message)"
            $result = New-MFAReportResult -User $user -Status 'Skipped' -SkipReason 'EvaluationError' `
                -Message "Unhandled evaluation error: $($_.Exception.Message)" `
                -RunId ([string]$RunContext.RunId) -CorrelationId ([guid]::NewGuid().Guid)
        }

        if ($result) {
            $results.Add($result)

            if (-not [string]::IsNullOrWhiteSpace($CheckpointPath)) {
                try {
                    $result | ConvertTo-MFAReportFlatRecord |
                        Export-Csv -Path $CheckpointPath -NoTypeInformation -Encoding UTF8 -Append
                }
                catch {
                    # A checkpoint failure must never abort the run it exists to protect.
                    Write-Verbose "Checkpoint write failed for ${user}: $($_.Exception.Message)"
                }
            }
        }
    }

    Write-Progress -Activity $Activity -Completed
    return @($results)
}

function Initialize-MFAReportCheckpoint {
    <#
    .SYNOPSIS
    Prepares the in-progress checkpoint file for a run and returns its path.

    .DESCRIPTION
    Returns $null when no output directory was requested, in which case the run
    keeps results in memory only and there is nothing to salvage.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Prepares a local output path; performs no tenant writes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Session,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$OutputPath
    )

    if ([string]::IsNullOrWhiteSpace($OutputPath)) { return $null }

    Initialize-MFAReportOutputDirectory -Path $OutputPath -Confirm:$false
    $Session.OutputPath = $OutputPath
    $Session.CheckpointPath = Join-Path $OutputPath "MFAReport_INPROGRESS_$($Session.RunId).csv"
    return $Session.CheckpointPath
}

function Complete-MFAReportSession {
    <#
    .SYNOPSIS
    Summarises the run, writes artifacts, and returns the caller's output object.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Session,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string]$OutputPath,
        [Parameter()] [switch]$IncludeJsonOutput,
        [Parameter()] [switch]$CritSitMode
    )

    $results = @($Session.Results)
    $summary = New-MFAReportSummary -Results $results -RunId $Session.RunId
    $artifacts = [ordered]@{}

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $Session.OutputPath = $OutputPath
        $artifacts = Export-MFAReportResultSet -Results $results -Summary $summary `
            -OutputPath $OutputPath -IncludeJsonOutput:$IncludeJsonOutput -CritSitMode:$CritSitMode

        foreach ($artifact in $artifacts.GetEnumerator()) {
            if ($artifact.Value) {
                Write-Information "$($artifact.Key) report saved to $($artifact.Value)" -InformationAction Continue
            }
        }
    }

    $Session.ExportCompleted = $true

    # The full artifacts supersede the checkpoint, so it stops being useful the
    # moment the run finishes.
    if (-not [string]::IsNullOrWhiteSpace($Session.CheckpointPath)) {
        Remove-Item -LiteralPath $Session.CheckpointPath -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        RunId     = $Session.RunId
        Summary   = $summary
        Results   = $results
        Artifacts = $artifacts
    }
}

function Stop-MFAReportSession {
    <#
    .SYNOPSIS
    Closes the transcript and salvages partial results when a run did not finish.

    .DESCRIPTION
    v0.10 wrote every CSV only after the loop completed, so a token expiry,
    throttle, or Ctrl-C at mailbox 400 of 500 discarded the entire run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Closes a transcript and salvages already-collected results to disk; performs no tenant writes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Session
    )

    if (-not $Session.ExportCompleted -and @($Session.Results).Count -gt 0) {
        $count = @($Session.Results).Count

        if (-not [string]::IsNullOrWhiteSpace($Session.CheckpointPath) -and (Test-Path -LiteralPath $Session.CheckpointPath)) {
            # The checkpoint was written incrementally, so it already holds
            # everything collected before the run stopped.
            Write-Warning "Run did not complete. Results for $count mailbox(es) were checkpointed to $($Session.CheckpointPath)"
        }
        elseif ($Session.OutputPath) {
            try {
                Initialize-MFAReportOutputDirectory -Path $Session.OutputPath -Confirm:$false
                $partialPath = Join-Path $Session.OutputPath "MFAReport_PARTIAL_$($Session.RunId).csv"
                @($Session.Results) | ConvertTo-MFAReportFlatRecord |
                    Export-Csv -Path $partialPath -NoTypeInformation -Encoding UTF8
                Write-Warning "Run did not complete. Partial results for $count mailbox(es) saved to $partialPath"
            }
            catch {
                Write-Warning "Run did not complete and partial results could not be saved: $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "Run did not complete. $count mailbox(es) were evaluated but no -OutputPath was supplied, so nothing was written to disk."
        }
    }

    if ($Session.TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}

function Export-MFAReportResultSet {
    <#
    .SYNOPSIS
    Writes the CSV, JSON, and CritSit artifacts for a run.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        [object]$Summary,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter()] [switch]$IncludeJsonOutput,
        [Parameter()] [switch]$CritSitMode
    )

    Initialize-MFAReportOutputDirectory -Path $OutputPath -Confirm:$false

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $all = @($Results | Where-Object { $null -ne $_ })
    $flat = @($all | ConvertTo-MFAReportFlatRecord)

    $artifacts = [ordered]@{}

    $artifacts['Full'] = Export-MFAReportArtifact -InputObject $flat `
        -Path (Join-Path $OutputPath "MFAReport_$timestamp.csv")

    # A mailbox appears in exactly one of these. v0.10 wrote any ReportOnly
    # result carrying a SkipReason to BOTH the processed and skipped files.
    $actionable = @($flat | Where-Object { $_.Status -in @('Ready', 'TriggeredAwaitingAssistant', 'NotTriggered') })
    $needsAttention = @($flat | Where-Object { $_.Status -in @('Blocked', 'Skipped') })

    $artifacts['Actionable'] = Export-MFAReportArtifact -InputObject $actionable `
        -Path (Join-Path $OutputPath "ReadyMailboxes_$timestamp.csv")
    $artifacts['NeedsAttention'] = Export-MFAReportArtifact -InputObject $needsAttention `
        -Path (Join-Path $OutputPath "BlockedMailboxes_$timestamp.csv")
    $artifacts['Summary'] = Export-MFAReportArtifact -InputObject @($Summary) `
        -Path (Join-Path $OutputPath "MFAReportSummary_$timestamp.csv")

    if ($IncludeJsonOutput) {
        $jsonPath = Join-Path $OutputPath "MFAReport_$timestamp.json"
        # Serialised from the STRUCTURED results, not the flattened ones, so the
        # JSON keeps nested tag and policy objects.
        $all | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
        if (-not $WhatIfPreference -and (Test-Path -LiteralPath $jsonPath)) {
            $artifacts['Json'] = $jsonPath
        }
    }

    if ($CritSitMode) {
        $critSit = @($flat | Select-Object User, Status, SkipReason, DiagnosticClassification,
            RecommendedNextAction, RepairSuggestions, DiagnosticParseConfidence, MovementMeasured,
            MonitoringSamples, ELCLastSuccessTimestamp, ELCItemCount, ELCDeletedItemCount,
            ELCArchivedItemCount, ELCLastRunTotalProcessingTime, MRMResourceUnhealthy, WorkCycleLag,
            StoreMaintenanceBacklog, DelayHoldApplied, DelayReleaseHoldApplied, ComplianceTagHoldApplied,
            PurviewOverrideSignal, MatchedPurviewPolicies, NotEvaluatedPurviewPolicies, PurviewPolicySummary,
            RetentionPolicyValidation, RetentionTagApplicability, TriggeringRetentionTags,
            FolderTagDetails, FolderEvidenceSummary, RecoverableItemsPressure, RecoverableItemsSummary,
            MailboxHealthWarnings, MailboxContext, EdgeCase, Actions)

        $artifacts['CritSit'] = Export-MFAReportArtifact -InputObject $critSit `
            -Path (Join-Path $OutputPath "MFAReport_CritSit_$timestamp.csv")
    }

    # Artifacts is the run's record of what reached disk, so a key whose file was
    # never written does not belong in it. Export-MFAReportArtifact returns $null
    # both for an empty record set and for a write -WhatIf suppressed; keeping
    # the key regardless made .Artifacts.Count report files the operator could
    # not open.
    $written = [ordered]@{}
    foreach ($entry in $artifacts.GetEnumerator()) {
        if ($entry.Value) { $written[$entry.Key] = $entry.Value }
    }

    return $written
}
