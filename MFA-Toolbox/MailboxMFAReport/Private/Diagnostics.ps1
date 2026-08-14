#Requires -Version 5.1

<#
Assistant and folder evidence collection.

The v0.10 design collected signals and then re-scanned the RAW LOG TEXT to
classify them. That is what produced the dominant false positive: the regex
'ResourceUnhealthy|throttl|WorkCycleLag|StoreMaintenanceBacklog' matches the
literal element NAME, so a mailbox reporting
<ResourceUnhealthy>False</ResourceUnhealthy> was classified as throttled.

Here, extraction and interpretation are separated. Text is parsed once into
typed values; classification reads only the typed values and never the raw text.
#>

function Get-MFAReportAssistantClassification {
    <#
    .SYNOPSIS
    Classifies assistant health from parsed signal values.

    .DESCRIPTION
    Pure function over already-parsed values. Accepts $null for any signal to
    mean "undetermined", which is treated as "not a problem" for classification
    but is reflected in ParseConfidence by the caller.

    WorkCycleLag is deliberately NOT a classifier by default. The healthy
    baseline for that value is not documented, so treating any non-zero lag as a
    fault would recreate the false-positive problem in a new form. Supply
    -WorkCycleLagThreshold to opt in once a baseline is known for the tenant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$IsResourceUnhealthy,

        [Parameter()]
        [AllowNull()]
        [object]$StoreMaintenanceBacklogCount,

        [Parameter()]
        [AllowNull()]
        [object]$WorkCycleLag,

        [Parameter()]
        [AllowNull()]
        [object]$WorkCycleLagThreshold,

        [Parameter()]
        [AllowNull()]
        [object]$IsDelayHoldApplied,

        [Parameter()]
        [AllowNull()]
        [object]$IsDelayReleaseHoldApplied,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ElcLastSuccessTimestamp
    )

    if ($IsResourceUnhealthy -eq $true) {
        return 'MFA running but throttled or resource unhealthy'
    }

    if ($null -ne $StoreMaintenanceBacklogCount -and $StoreMaintenanceBacklogCount -gt 0) {
        return 'MFA running but throttled or resource unhealthy'
    }

    if ($null -ne $WorkCycleLagThreshold -and
        $null -ne $WorkCycleLag -and
        $WorkCycleLag -gt $WorkCycleLagThreshold) {
        return 'MFA running but throttled or resource unhealthy'
    }

    if ($IsDelayHoldApplied -eq $true -or $IsDelayReleaseHoldApplied -eq $true) {
        return 'Delay hold / hold cleanup issue'
    }

    if ([string]::IsNullOrWhiteSpace($ElcLastSuccessTimestamp)) {
        return 'MFA execution status unknown'
    }

    return 'Assistant diagnostics collected'
}

function Get-MFAReportParseConfidence {
    <#
    .SYNOPSIS
    Reports how much of the expected diagnostic signal set was actually parsed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Values
    )

    if ($null -eq $Values) { return 'Low' }

    $parsed = @($Values | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })

    if ($parsed.Count -ge 4) { return 'High' }
    if ($parsed.Count -ge 1) { return 'Medium' }
    return 'Low'
}

function Get-MFAReportDiagnosticSignals {
    <#
    .SYNOPSIS
    Collects and parses Export-MailboxDiagnosticLogs evidence for one mailbox.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter()]
        [AllowNull()]
        [object]$WorkCycleLagThreshold
    )

    $signals = [ordered]@{
        Status                        = 'NotCollected'
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
        # Typed interpretations. Classification reads only these.
        IsResourceUnhealthy           = $null
        IsDelayHoldApplied            = $null
        IsDelayReleaseHoldApplied     = $null
        IsComplianceTagHoldApplied    = $null
        WorkCycleLagValue             = $null
        StoreMaintenanceBacklogCount  = $null
        Classification                = $null
        ParseConfidence               = 'NotCollected'
        Errors                        = @()
    }

    if (-not (Get-Command Export-MailboxDiagnosticLogs -ErrorAction SilentlyContinue)) {
        $signals.Status = 'Export-MailboxDiagnosticLogsNotAvailable'
        $signals.Classification = 'Needs escalation: assistant diagnostics unavailable'
        return [PSCustomObject]$signals
    }

    try {
        $extendedText = ConvertTo-MFAReportText -InputObject (
            Export-MailboxDiagnosticLogs -Identity $Identity -ExtendedProperties -ErrorAction Stop)
        $mrmText = ConvertTo-MFAReportText -InputObject (
            Export-MailboxDiagnosticLogs -Identity $Identity -ComponentName MRM -ErrorAction Stop)

        $signals.ELCLastSuccessTimestamp       = Select-MFAReportRegexFlag -Text $extendedText -Name 'ELCLastSuccessTimestamp'
        $signals.ELCItemCount                  = Select-MFAReportRegexFlag -Text $mrmText -Name 'ELCItemCount'
        $signals.ELCDeletedItemCount           = Select-MFAReportRegexFlag -Text $mrmText -Name 'ELCDeletedItemCount'
        $signals.ELCArchivedItemCount          = Select-MFAReportRegexFlag -Text $mrmText -Name 'ELCArchivedItemCount'
        $signals.ELCLastRunTotalProcessingTime = Select-MFAReportRegexFlag -Text $mrmText -Name 'ELCLastRunTotalProcessingTime'
        $signals.MRMResourceUnhealthy          = Select-MFAReportRegexFlag -Text $mrmText -Name 'ResourceUnhealthy'
        $signals.WorkCycleLag                  = Select-MFAReportRegexFlag -Text $mrmText -Name 'WorkCycleLag'
        $signals.StoreMaintenanceBacklog       = Select-MFAReportRegexFlag -Text $mrmText -Name 'StoreMaintenanceBacklog'
        $signals.ComplianceTagHoldApplied      = Select-MFAReportRegexFlag -Text $extendedText -Name 'ComplianceTagHoldApplied'
        $signals.DelayHoldApplied              = Select-MFAReportRegexFlag -Text $extendedText -Name 'DelayHoldApplied'
        $signals.DelayReleaseHoldApplied       = Select-MFAReportRegexFlag -Text $extendedText -Name 'DelayReleaseHoldApplied'

        $signals.IsResourceUnhealthy          = ConvertTo-MFAReportBoolean -Value $signals.MRMResourceUnhealthy
        $signals.IsDelayHoldApplied           = ConvertTo-MFAReportBoolean -Value $signals.DelayHoldApplied
        $signals.IsDelayReleaseHoldApplied    = ConvertTo-MFAReportBoolean -Value $signals.DelayReleaseHoldApplied
        $signals.IsComplianceTagHoldApplied   = ConvertTo-MFAReportBoolean -Value $signals.ComplianceTagHoldApplied
        $signals.WorkCycleLagValue            = ConvertTo-MFAReportTimeSpan -Value $signals.WorkCycleLag
        $signals.StoreMaintenanceBacklogCount = ConvertTo-MFAReportCount -Value $signals.StoreMaintenanceBacklog

        $signals.MRMConfigStatus = if ($extendedText -match 'PR_ROAMING_XMLSTREAM|IPM\.Configuration\.MRM') {
            'MRM configuration evidence present'
        }
        else {
            'MRM configuration evidence not found in diagnostic output'
        }

        $signals.ParseConfidence = Get-MFAReportParseConfidence -Values @(
            $signals.ELCLastSuccessTimestamp
            $signals.ELCItemCount
            $signals.ELCDeletedItemCount
            $signals.ELCArchivedItemCount
            $signals.ELCLastRunTotalProcessingTime
            $signals.WorkCycleLag
            $signals.StoreMaintenanceBacklog
            $signals.DelayHoldApplied
            $signals.DelayReleaseHoldApplied
            $signals.ComplianceTagHoldApplied
        )

        $signals.Classification = Get-MFAReportAssistantClassification `
            -IsResourceUnhealthy $signals.IsResourceUnhealthy `
            -StoreMaintenanceBacklogCount $signals.StoreMaintenanceBacklogCount `
            -WorkCycleLag $signals.WorkCycleLagValue `
            -WorkCycleLagThreshold $WorkCycleLagThreshold `
            -IsDelayHoldApplied $signals.IsDelayHoldApplied `
            -IsDelayReleaseHoldApplied $signals.IsDelayReleaseHoldApplied `
            -ElcLastSuccessTimestamp $signals.ELCLastSuccessTimestamp

        $signals.Status = 'Collected'
    }
    catch {
        $signals.Status = 'CollectionFailed'
        $signals.Errors += $_.Exception.Message
        $signals.Classification = 'Needs escalation: assistant diagnostics collection failed'
    }

    # When the primary collection failed for a TERMINAL reason -- RBAC, an
    # unsupported mailbox type, the cmdlet refusing this identity -- these two
    # components will fail the same way. Issuing them anyway doubled the failed
    # round-trips per mailbox and spent throttling budget to learn nothing. A
    # transient failure is still worth following up on, so only terminal ones
    # short-circuit.
    $skipComponents = $signals.Status -eq 'CollectionFailed' -and
        @($signals.Errors | Where-Object { Test-MFAReportTransientError -Message $_ }).Count -eq 0

    foreach ($component in @('HoldTracking', 'SubstrateHoldTracking')) {
        $summaryProperty = "${component}Summary"

        if ($skipComponents) {
            $signals[$summaryProperty] = 'NotCollected:PrimaryDiagnosticCollectionFailed'
            continue
        }

        try {
            $componentText = ConvertTo-MFAReportText -InputObject (
                Export-MailboxDiagnosticLogs -Identity $Identity -ComponentName $component -ErrorAction Stop)
            $signals[$summaryProperty] = if ($componentText.Length -gt 500) {
                $componentText.Substring(0, 500)
            }
            else {
                $componentText
            }
        }
        catch {
            $signals[$summaryProperty] = "CollectionFailed:$($_.Exception.Message)"
        }
    }

    return [PSCustomObject]$signals
}

function Get-MFAReportRecoverableItemsSize {
    <#
    .SYNOPSIS
    Computes total Recoverable Items bytes without double counting.

    .DESCRIPTION
    FolderAndSubfolderSize is CUMULATIVE: the '/Recoverable Items' root already
    includes Deletions, Purges, Versions and so on. v0.10 concatenated that
    property across every folder and summed all byte values it found, inflating
    the total by roughly the depth of the hierarchy and overstating quota
    pressure.

    This takes the root folder's cumulative size when the root can be
    identified, and otherwise sums the NON-cumulative per-folder FolderSize.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Folders
    )

    if ($null -eq $Folders -or $Folders.Count -eq 0) { return $null }

    $withDepth = $Folders | ForEach-Object {
        $path = [string](Get-MFAReportPropertyValue -InputObject $_ -Name 'FolderPath')
        [PSCustomObject]@{
            Folder = $_
            Depth  = ($path -split '/' | Where-Object { $_ }).Count
        }
    }

    $root = @($withDepth | Sort-Object Depth | Select-Object -First 1).Folder
    $rootSize = Convert-MFAReportSizeToBytes -SizeString ([string](
        Get-MFAReportPropertyValue -InputObject $root -Name 'FolderAndSubfolderSize'))

    if ($null -ne $rootSize) { return $rootSize }

    $total = [long]0
    $sawAny = $false
    foreach ($folder in $Folders) {
        $size = Convert-MFAReportSizeToBytes -SizeString ([string](
            Get-MFAReportPropertyValue -InputObject $folder -Name 'FolderSize'))
        if ($null -ne $size) {
            $total += $size
            $sawAny = $true
        }
    }

    if (-not $sawAny) { return $null }
    return $total
}

function Get-MFAReportFolderEvidence {
    <#
    .SYNOPSIS
    Collects folder-level policy, age, and Recoverable Items evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity
    )

    $evidence = [ordered]@{
        Summary                 = 'NotCollected'
        RecoverableItemsSummary = $null
        RecoverableItemsBytes   = $null
        RecoverableItemsCount   = $null
        TaggedFolderDetails     = $null
        Warnings                = @()
    }

    if (-not (Get-Command Get-MailboxFolderStatistics -ErrorAction SilentlyContinue)) {
        $evidence.Summary = 'Get-MailboxFolderStatisticsNotAvailable'
        return [PSCustomObject]$evidence
    }

    try {
        $folders = @(Get-MailboxFolderStatistics -Identity $Identity -IncludeOldestAndNewestItems -ErrorAction Stop)
        $taggedFolders = @($folders | Where-Object {
            (Get-MFAReportPropertyValue -InputObject $_ -Name 'ArchivePolicy') -or
            (Get-MFAReportPropertyValue -InputObject $_ -Name 'DeletePolicy') -or
            (Get-MFAReportPropertyValue -InputObject $_ -Name 'CompliancePolicy') -or
            (Get-MFAReportPropertyValue -InputObject $_ -Name 'RetentionFlags')
        })

        $oldestReceived = @($folders |
            Where-Object { Get-MFAReportPropertyValue -InputObject $_ -Name 'OldestItemReceivedDate' } |
            Sort-Object OldestItemReceivedDate |
            Select-Object -First 1)
        $oldestModified = @($folders |
            Where-Object { Get-MFAReportPropertyValue -InputObject $_ -Name 'OldestItemLastModifiedDate' } |
            Sort-Object OldestItemLastModifiedDate |
            Select-Object -First 1)

        # Read off the filtered collection BEFORE interpolating. Under
        # Set-StrictMode -Version 3.0, $empty.SomeProperty is a missing-property
        # error, so a mailbox where no folder carries an oldest-item date used to
        # throw here -- and the catch below then blamed Exchange for it while
        # silently discarding TaggedFolderDetails, the point of the whole switch.
        $oldestReceivedValue = if ($oldestReceived.Count -gt 0) {
            Get-MFAReportPropertyValue -InputObject $oldestReceived[0] -Name 'OldestItemReceivedDate'
        } else { $null }
        $oldestModifiedValue = if ($oldestModified.Count -gt 0) {
            Get-MFAReportPropertyValue -InputObject $oldestModified[0] -Name 'OldestItemLastModifiedDate'
        } else { $null }

        $evidence.Summary = "Folders=$($folders.Count)|TaggedFolders=$($taggedFolders.Count)|OldestReceived=$oldestReceivedValue|OldestModified=$oldestModifiedValue"
        $evidence.TaggedFolderDetails = @($taggedFolders | Select-Object -First 25 | ForEach-Object {
            [PSCustomObject]@{
                Name             = Get-MFAReportPropertyValue -InputObject $_ -Name 'Name'
                ArchivePolicy    = Get-MFAReportPropertyValue -InputObject $_ -Name 'ArchivePolicy'
                DeletePolicy     = Get-MFAReportPropertyValue -InputObject $_ -Name 'DeletePolicy'
                CompliancePolicy = Get-MFAReportPropertyValue -InputObject $_ -Name 'CompliancePolicy'
                RetentionFlags   = Get-MFAReportPropertyValue -InputObject $_ -Name 'RetentionFlags'
                OldestReceived   = Get-MFAReportPropertyValue -InputObject $_ -Name 'OldestItemReceivedDate'
                OldestModified   = Get-MFAReportPropertyValue -InputObject $_ -Name 'OldestItemLastModifiedDate'
            }
        })
    }
    catch {
        $evidence.Summary = "PrimaryFolderStatsFailed:$($_.Exception.Message)"
        $evidence.Warnings += 'FolderEvidenceCollectionFailed'
    }

    try {
        $recoverableFolders = @(Get-MailboxFolderStatistics -Identity $Identity -FolderScope RecoverableItems -IncludeOldestAndNewestItems -ErrorAction Stop)
        $evidence.RecoverableItemsBytes = Get-MFAReportRecoverableItemsSize -Folders $recoverableFolders
        $evidence.RecoverableItemsCount = ($recoverableFolders | Measure-Object -Property ItemsInFolder -Sum).Sum
        $evidence.RecoverableItemsSummary = "Folders=$($recoverableFolders.Count)|Items=$($evidence.RecoverableItemsCount)|Bytes=$($evidence.RecoverableItemsBytes)"
    }
    catch {
        $evidence.RecoverableItemsSummary = "RecoverableItemsStatsFailed:$($_.Exception.Message)"
        $evidence.Warnings += 'RecoverableItemsEvidenceCollectionFailed'
    }

    return [PSCustomObject]$evidence
}
