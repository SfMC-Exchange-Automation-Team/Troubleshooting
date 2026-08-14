#Requires -Version 5.1

<#
Assistant start.

Kept out of Evaluation.ps1 so that file remains provably write-free, and
implemented as a normal module function rather than a closure passed into the
population loop: a scriptblock built with GetNewClosure() loses its binding to
module session state, so module-private helpers stop resolving when it is
invoked from another function.
#>

function Invoke-MFAReportAssistantStart {
    <#
    .SYNOPSIS
    Starts the Managed Folder Assistant for a mailbox that evaluated as Ready.

    .DESCRIPTION
    Mailboxes that are not Ready are returned untouched. The returned record's
    Status becomes TriggeredAwaitingAssistant or NotTriggered, and monitoring is
    applied when requested and attributable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to the calling cmdlet via Options.Cmdlet so every prompt is attributed to Start-MailboxMFAProcessing.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [hashtable]$Options
    )

    if ($Result.Status -ne 'Ready') { return $Result }

    $identity = [string]$Result.User
    $mode = [string]$Options.MfaMode
    $cmdlet = $Options.Cmdlet
    $started = $false

    if ($mode -eq 'InactiveMailbox' -and $Result.EdgeCase -ne 'InactiveMailbox') {
        $Result.Actions = @($Result.Actions + 'InactiveMailboxModeSkippedForActiveMailbox')
        $Result.MailboxHealthWarnings = @($Result.MailboxHealthWarnings +
            '-MfaMode InactiveMailbox was requested, but this mailbox was not detected as inactive.')
    }
    elseif ($cmdlet.ShouldProcess($identity, "Start Managed Folder Assistant ($mode)")) {
        try {
            # v0.10 omitted -ErrorAction Stop here, so a non-terminating failure
            # still recorded 'StartedMFA' and reported success.
            switch ($mode) {
                'FullCrawl'       { Start-ManagedFolderAssistant -Identity $identity -FullCrawl -ErrorAction Stop }
                'HoldCleanup'     { Start-ManagedFolderAssistant -Identity $identity -HoldCleanup -ErrorAction Stop }
                'InactiveMailbox' { Start-ManagedFolderAssistant -Identity $identity -InactiveMailbox -ErrorAction Stop }
                default           { Start-ManagedFolderAssistant -Identity $identity -ErrorAction Stop }
            }
            $Result.Actions = @($Result.Actions + "StartedMFA:$mode")
            $started = $true
        }
        catch {
            $Result.Actions = @($Result.Actions + "MFAStartFailed:$($_.Exception.Message)")
            $Result.MailboxHealthWarnings = @($Result.MailboxHealthWarnings +
                "Start-ManagedFolderAssistant failed: $($_.Exception.Message)")
        }
    }
    else {
        $Result.Actions = @($Result.Actions + 'MFAStartNotConfirmed')
    }

    $status = if ($started) { 'TriggeredAwaitingAssistant' } else { 'NotTriggered' }

    if ($started -and $Options.Monitor) {
        $movement = Measure-MFAReportMailboxMovement -Identity $identity -Monitor `
            -DurationInMinutes ([int]$Options.DurationInMinutes) `
            -CheckIntervalSeconds ([int]$Options.CheckIntervalSeconds)
        return Update-MFAReportResultMovement -Result $Result -Movement $movement -Status $status
    }

    $Result.Status = $status
    $Result.RecommendedNextAction = Get-MFAReportRecommendedAction `
        -Status $status `
        -DiagnosticClassification $Result.DiagnosticClassification `
        -HealthWarnings @($Result.MailboxHealthWarnings) `
        -EdgeCase $Result.EdgeCase

    return $Result
}
