#Requires -Version 5.1

<#
Result construction and CSV flattening.

v0.10's New-MFAReportResult took 60+ discrete parameters, which is why most call
sites silently omitted RunId and CorrelationId and a post-hoc fixup loop had to
patch them in afterwards (generating a DIFFERENT correlation id than the one the
mailbox loop had already created).

Here the identity fields are mandatory and everything optional arrives in a
single Evidence hashtable, so adding a signal never means touching a signature.

Structured values are preserved on the result object and flattened ONLY at
export. v0.10 joined everything with ';' immediately and then re-split on ';'
later to recover the pieces -- unreliable, because several values legitimately
contain a semicolon.
#>

function New-MFAReportResult {
    <#
    .SYNOPSIS
    Builds one per-mailbox result record.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Evidence is read by the nested Get-Evidence helper, which the analyzer does not follow into.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result record; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            # Get-MailboxMFAReadiness
            'Ready', 'Blocked', 'Skipped',
            # Start-MailboxMFAProcessing
            'TriggeredAwaitingAssistant', 'NotTriggered'
        )]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$CorrelationId,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SkipReason,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [AllowNull()]
        [object]$Mailbox,

        [Parameter()]
        [hashtable]$Evidence = @{}
    )

    function Get-Evidence {
        param([string]$Key, $Default = $null)
        if ($Evidence.ContainsKey($Key) -and $null -ne $Evidence[$Key]) { return $Evidence[$Key] }
        return $Default
    }

    $healthWarnings = @(Get-Evidence 'HealthWarnings' @())
    $context = @(Get-Evidence 'Context' @())

    $result = [PSCustomObject]@{
        User                          = $User
        RunId                         = $RunId
        CorrelationId                 = $CorrelationId
        Status                        = $Status
        SkipReason                    = $SkipReason
        Message                       = $Message

        RecipientTypeDetails          = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'RecipientTypeDetails'
        ArchiveState                  = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'ArchiveState'
        AutoExpandingArchiveEnabled   = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'AutoExpandingArchiveEnabled'
        RetentionPolicy               = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'RetentionPolicy'
        RetentionHoldEnabled          = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'RetentionHoldEnabled'
        LitigationHoldEnabled         = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'LitigationHoldEnabled'
        ElcProcessingDisabled         = Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'ElcProcessingDisabled'

        LicenseSkus                   = @(Get-Evidence 'LicenseSkus' @())
        UsageLocation                 = Get-Evidence 'UsageLocation'
        AccountEnabled                = Get-Evidence 'AccountEnabled'
        AutoExpandingArchiveEffective = Get-Evidence 'AutoExpandingArchiveEffective'
        EdgeCase                      = Get-Evidence 'EdgeCase'

        HoldRequirement               = Get-Evidence 'HoldRequirement'
        HoldSources                   = @(Get-Evidence 'HoldSources' @())
        ExcludedHolds                 = @(Get-Evidence 'ExcludedHolds' @())

        RetentionPolicyValidation     = Get-Evidence 'RetentionPolicyValidation'
        TriggeringRetentionTags       = @(Get-Evidence 'TriggeringRetentionTags' @())
        RetentionTagApplicability     = Get-Evidence 'RetentionTagApplicability'

        DiagnosticClassification      = Get-Evidence 'DiagnosticClassification'
        RecommendedNextAction         = Get-Evidence 'RecommendedNextAction'
        DiagnosticParseConfidence     = Get-Evidence 'DiagnosticParseConfidence' 'NotCollected'
        AssistantDiagnosticsStatus    = Get-Evidence 'AssistantDiagnosticsStatus' 'NotCollected'

        # Retained so Start-MailboxMFAProcessing can reclassify after monitoring
        # without re-evaluating the mailbox.
        AssistantClassification       = Get-Evidence 'AssistantClassification'
        AssistantRanSuccessfully      = [bool](Get-Evidence 'AssistantRanSuccessfully' $false)
        PolicyIsValid                 = [bool](Get-Evidence 'PolicyIsValid' $false)
        RepairSuggestions             = @(Get-Evidence 'RepairSuggestions' @())

        ELCLastSuccessTimestamp       = Get-Evidence 'ELCLastSuccessTimestamp'
        ELCItemCount                  = Get-Evidence 'ELCItemCount'
        ELCDeletedItemCount           = Get-Evidence 'ELCDeletedItemCount'
        ELCArchivedItemCount          = Get-Evidence 'ELCArchivedItemCount'
        ELCLastRunTotalProcessingTime = Get-Evidence 'ELCLastRunTotalProcessingTime'
        MRMResourceUnhealthy          = Get-Evidence 'MRMResourceUnhealthy'
        WorkCycleLag                  = Get-Evidence 'WorkCycleLag'
        StoreMaintenanceBacklog       = Get-Evidence 'StoreMaintenanceBacklog'
        DelayHoldApplied              = Get-Evidence 'DelayHoldApplied'
        DelayReleaseHoldApplied       = Get-Evidence 'DelayReleaseHoldApplied'
        ComplianceTagHoldApplied      = Get-Evidence 'ComplianceTagHoldApplied'
        MRMConfigStatus               = Get-Evidence 'MRMConfigStatus'
        HoldTrackingSummary           = Get-Evidence 'HoldTrackingSummary'
        SubstrateHoldTrackingSummary  = Get-Evidence 'SubstrateHoldTrackingSummary'

        PurviewPolicySummary          = Get-Evidence 'PurviewPolicySummary'
        PurviewOverrideSignal         = Get-Evidence 'PurviewOverrideSignal'
        MatchedPurviewPolicies        = @(Get-Evidence 'MatchedPurviewPolicies' @())
        NotEvaluatedPurviewPolicies   = @(Get-Evidence 'NotEvaluatedPurviewPolicies' @())

        FolderEvidenceSummary         = Get-Evidence 'FolderEvidenceSummary'
        FolderTagDetails              = @(Get-Evidence 'FolderTagDetails' @())
        RecoverableItemsSummary       = Get-Evidence 'RecoverableItemsSummary'
        RecoverableItemsPressure      = Get-Evidence 'RecoverableItemsPressure'

        MailboxHealthWarnings         = $healthWarnings
        MailboxContext                = $context

        NormalMailboxItems            = Get-Evidence 'NormalMailboxItems'
        ArchiveMailboxItems           = Get-Evidence 'ArchiveMailboxItems'
        NormalMailboxSize             = Get-Evidence 'NormalMailboxSize'
        ArchiveMailboxSize            = Get-Evidence 'ArchiveMailboxSize'

        MovementMeasured              = [bool](Get-Evidence 'MovementMeasured' $false)
        MonitoringSamples             = [int](Get-Evidence 'MonitoringSamples' 0)
        MovedNormalItems              = [int](Get-Evidence 'MovedNormalItems' 0)
        MovedArchiveItems             = [int](Get-Evidence 'MovedArchiveItems' 0)
        MovedNormalBytes              = [long](Get-Evidence 'MovedNormalBytes' 0)
        MovedArchiveBytes             = [long](Get-Evidence 'MovedArchiveBytes' 0)

        Actions                       = @(Get-Evidence 'Actions' @())
    }

    return $result
}

function ConvertTo-MFAReportFlatRecord {
    <#
    .SYNOPSIS
    Flattens a result object for CSV export.

    .DESCRIPTION
    Nothing in the pipeline re-parses these strings, so flattening is a one-way
    presentation concern rather than a data structure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$Result
    )

    process {
        $flat = [ordered]@{}

        foreach ($property in $Result.PSObject.Properties) {
            $value = $property.Value

            if ($null -eq $value) {
                $flat[$property.Name] = $null
                continue
            }

            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                $items = @($value | ForEach-Object {
                    if ($null -eq $_) { return }
                    if ($_ -is [string]) { return $_ }
                    if ($_ -is [System.Management.Automation.PSCustomObject]) {
                        return (($_.PSObject.Properties |
                            Where-Object { $null -ne $_.Value -and "$($_.Value)" -ne '' } |
                            ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',')
                    }
                    return [string]$_
                })
                $flat[$property.Name] = ($items -join '; ')
                continue
            }

            if ($value -is [System.Management.Automation.PSCustomObject]) {
                $flat[$property.Name] = (($value.PSObject.Properties |
                    Where-Object { $null -ne $_.Value -and "$($_.Value)" -ne '' } |
                    ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',')
                continue
            }

            $flat[$property.Name] = $value
        }

        return [PSCustomObject]$flat
    }
}

function New-MFAReportSummary {
    <#
    .SYNOPSIS
    Aggregates the run into a single summary record.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Aggregates in-memory results; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        [string]$RunId
    )

    $all = @($Results | Where-Object { $null -ne $_ })

    return [PSCustomObject]@{
        RunId                      = $RunId
        TotalMailboxes             = $all.Count
        Ready                      = @($all | Where-Object { $_.Status -eq 'Ready' }).Count
        Blocked                    = @($all | Where-Object { $_.Status -eq 'Blocked' }).Count
        Skipped                    = @($all | Where-Object { $_.Status -eq 'Skipped' }).Count
        TriggeredAwaitingAssistant = @($all | Where-Object { $_.Status -eq 'TriggeredAwaitingAssistant' }).Count
        NotTriggered               = @($all | Where-Object { $_.Status -eq 'NotTriggered' }).Count
        MovementMeasured           = @($all | Where-Object { $_.MovementMeasured }).Count
        NoEligibleItems            = @($all | Where-Object { $_.DiagnosticClassification -match 'NoEligibleItems' }).Count
        MovementNotMeasured        = @($all | Where-Object { $_.DiagnosticClassification -match 'movement was not measured' }).Count
        ThrottledOrResourceIssues  = @($all | Where-Object { $_.DiagnosticClassification -match 'throttled|resource unhealthy' }).Count
        DelayHoldIssues            = @($all | Where-Object { $_.DiagnosticClassification -match 'Delay hold' }).Count
        PossiblePurviewOverrides   = @($all | Where-Object { $_.PurviewOverrideSignal -match '^(Possible)?PurviewOverride:' }).Count
        InconclusivePurview        = @($all | Where-Object { $_.PurviewOverrideSignal -match '^Inconclusive:' }).Count
        RecoverableItemsPressure   = @($all | Where-Object { $_.RecoverableItemsPressure -match 'Critical|Warning' }).Count
        LowParseConfidence         = @($all | Where-Object { $_.DiagnosticParseConfidence -eq 'Low' }).Count
        SoftDeletedMailboxes       = @($all | Where-Object { $_.SkipReason -eq 'SoftDeletedMailbox' }).Count
        NeedsEscalation            = @($all | Where-Object { $_.DiagnosticClassification -match 'Needs escalation|status unknown|collection failed' }).Count
        Repairable                 = @($all | Where-Object { @($_.RepairSuggestions).Count -gt 0 }).Count
        BlockedByReason            = ((@($all | Where-Object { $_.SkipReason } | Group-Object SkipReason |
                                        ForEach-Object { "$($_.Name)=$($_.Count)" })) -join '; ')
    }
}
