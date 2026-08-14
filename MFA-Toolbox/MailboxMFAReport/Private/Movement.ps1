#Requires -Version 5.1

<#
Mailbox statistics sampling and movement measurement.

Split out of the evaluation path because measuring movement is only meaningful
after MFA has actually been started, which is Start-MailboxMFAProcessing's job.
The read-only readiness path takes a single sample and never sleeps.
#>

function Get-MFAReportByteDelta {
    <#
    .SYNOPSIS
    Subtracts two possibly-unknown byte counts, yielding 0 when either is unknown.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter()] [AllowNull()] [object]$Current,
        [Parameter()] [AllowNull()] [object]$Baseline
    )

    if ($null -eq $Current -or $null -eq $Baseline) { return [long]0 }
    return [long]$Current - [long]$Baseline
}

function Measure-MFAReportMailboxMovement {
    <#
    .SYNOPSIS
    Samples mailbox and archive statistics, optionally over a monitoring window.

    .DESCRIPTION
    Monitoring only runs when -Monitor is supplied. v0.10 entered the monitoring
    loop for ANY single-mailbox run, so its documented -ReportOnly example
    blocked for the full 15 minutes after deliberately triggering nothing.

    MovementMeasured is true only when at least two samples were taken, so
    downstream classification can tell "no movement" from "never looked".

    Deltas are cumulative across the window (last sample minus first). v0.10
    reported only the final interval's delta despite the report describing the
    whole monitored period.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter()] [switch]$Monitor,
        [Parameter()] [int]$DurationInMinutes = 15,
        [Parameter()] [int]$CheckIntervalSeconds = 300
    )

    $actions = [System.Collections.Generic.List[string]]::new()
    $result = @{
        StatisticsAvailable = $false
        ErrorMessage        = $null
        Samples             = 0
        MovementMeasured    = $false
        NormalItems         = $null
        ArchiveItems        = $null
        NormalSize          = $null
        ArchiveSize         = $null
        NormalBytes         = $null
        MovedNormalItems    = 0
        MovedArchiveItems   = 0
        MovedNormalBytes    = [long]0
        MovedArchiveBytes   = [long]0
        Actions             = $actions
    }

    $baseline = $null
    $endTime = (Get-Date).AddMinutes($DurationInMinutes)

    do {
        $normalResult = Get-MFAReportMailboxStatistics -Identity $Identity
        $archiveResult = Get-MFAReportMailboxStatistics -Identity $Identity -Archive

        if (-not $normalResult.Success) {
            if ($result.Samples -eq 0) {
                $result.ErrorMessage = $normalResult.ErrorMessage
                return [PSCustomObject]$result
            }
            $actions.Add("MailboxStatisticsWarning:$($normalResult.ErrorMessage)")
            break
        }

        $result.StatisticsAvailable = $true
        $result.Samples++

        $normalStats = $normalResult.Statistics
        $archiveStats = if ($archiveResult.Success) { $archiveResult.Statistics } else { $null }
        if (-not $archiveResult.Success -and $result.Samples -eq 1) {
            $actions.Add("ArchiveStatisticsWarning:$($archiveResult.ErrorMessage)")
        }

        $sample = @{
            NormalItems  = [int](Get-MFAReportPropertyValue -InputObject $normalStats -Name 'ItemCount')
            ArchiveItems = if ($archiveStats) { [int](Get-MFAReportPropertyValue -InputObject $archiveStats -Name 'ItemCount') } else { 0 }
            NormalBytes  = Get-MFAReportTotalItemSizeBytes -Statistics $normalStats
            ArchiveBytes = if ($archiveStats) { Get-MFAReportTotalItemSizeBytes -Statistics $archiveStats } else { $null }
        }

        if ($null -eq $baseline) { $baseline = $sample }

        $result.NormalItems  = $sample.NormalItems
        $result.ArchiveItems = if ($archiveStats) { $sample.ArchiveItems } else { $null }
        $result.NormalSize   = Get-MFAReportPropertyValue -InputObject $normalStats -Name 'TotalItemSize'
        $result.ArchiveSize  = if ($archiveStats) { Get-MFAReportPropertyValue -InputObject $archiveStats -Name 'TotalItemSize' } else { $null }
        $result.NormalBytes  = $sample.NormalBytes

        $result.MovedNormalItems  = $sample.NormalItems - $baseline.NormalItems
        $result.MovedArchiveItems = $sample.ArchiveItems - $baseline.ArchiveItems
        $result.MovedNormalBytes  = Get-MFAReportByteDelta -Current $sample.NormalBytes -Baseline $baseline.NormalBytes
        $result.MovedArchiveBytes = Get-MFAReportByteDelta -Current $sample.ArchiveBytes -Baseline $baseline.ArchiveBytes

        if (-not $Monitor) { break }

        $remaining = [int](($endTime - (Get-Date)).TotalSeconds)
        if ($remaining -le 0) { break }

        Write-Progress -Activity "Monitoring $Identity" `
            -Status "Sample $($result.Samples); $remaining second(s) remaining" `
            -SecondsRemaining $remaining

        Start-Sleep -Seconds ([Math]::Min($CheckIntervalSeconds, [Math]::Max($remaining, 1)))
    } while ((Get-Date) -lt $endTime)

    if ($Monitor) { Write-Progress -Activity "Monitoring $Identity" -Completed }

    $result.MovementMeasured = ($result.Samples -ge 2)
    return [PSCustomObject]$result
}

function Update-MFAReportResultMovement {
    <#
    .SYNOPSIS
    Applies monitoring results to a readiness record and reclassifies it.

    .DESCRIPTION
    Classification depends on whether movement was actually measured, so it must
    be recomputed once a monitoring window has run. The readiness pass stores the
    raw inputs (AssistantClassification, AssistantRanSuccessfully, PolicyIsValid)
    precisely so this can be done without re-evaluating the mailbox.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates an in-memory result record; performs no tenant writes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [object]$Movement,

        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $Result.Status            = $Status
    $Result.MovementMeasured  = [bool]$Movement.MovementMeasured
    $Result.MonitoringSamples = [int]$Movement.Samples
    $Result.MovedNormalItems  = [int]$Movement.MovedNormalItems
    $Result.MovedArchiveItems = [int]$Movement.MovedArchiveItems
    $Result.MovedNormalBytes  = [long]$Movement.MovedNormalBytes
    $Result.MovedArchiveBytes = [long]$Movement.MovedArchiveBytes

    if ($null -ne $Movement.NormalItems) { $Result.NormalMailboxItems = $Movement.NormalItems }
    if ($null -ne $Movement.ArchiveItems) { $Result.ArchiveMailboxItems = $Movement.ArchiveItems }
    if ($null -ne $Movement.NormalSize) { $Result.NormalMailboxSize = $Movement.NormalSize }
    if ($null -ne $Movement.ArchiveSize) { $Result.ArchiveMailboxSize = $Movement.ArchiveSize }

    $noMovement = ($Movement.MovedNormalItems -eq 0 -and $Movement.MovedArchiveItems -eq 0 -and
                   $Movement.MovedNormalBytes -eq 0 -and $Movement.MovedArchiveBytes -eq 0)

    $Result.DiagnosticClassification = Get-MFAReportDiagnosticClassification `
        -AssistantRanSuccessfully:([bool]$Result.AssistantRanSuccessfully) `
        -MovementMeasured:([bool]$Movement.MovementMeasured) `
        -NoMovementDetected:$noMovement `
        -PolicyIsValid:([bool]$Result.PolicyIsValid) `
        -AssistantClassification $Result.AssistantClassification `
        -HealthWarnings @($Result.MailboxHealthWarnings)

    $Result.RecommendedNextAction = Get-MFAReportRecommendedAction `
        -Status $Status `
        -DiagnosticClassification $Result.DiagnosticClassification `
        -HealthWarnings @($Result.MailboxHealthWarnings) `
        -EdgeCase $Result.EdgeCase

    return $Result
}
