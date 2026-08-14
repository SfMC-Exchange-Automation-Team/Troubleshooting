#Requires -Version 5.1

<#
Resilience for long multi-mailbox runs.

v0.10 issued every Exchange Online call exactly once. A tenant large enough to
need this tool is also large enough to throttle it, and a throttled call surfaced
as a per-mailbox failure indistinguishable from a real finding -- so a run against
500 mailboxes could report dozens of mailboxes as unreadable purely because the
service asked it to slow down.

Retries are deliberately narrow: only errors that look transient are retried.
Retrying a terminal error (a mailbox that genuinely does not exist) would
multiply the runtime of a run with a stale identity list and change nothing.
#>

$script:MFAReportTransientPattern = @(
    'throttl'
    'micro ?delay'
    'request limit'
    'too many requests'
    'server is busy'
    'serverbusy'
    'temporarily unavailable'
    'service unavailable'
    'operation has timed out'
    'timed out'
    'connection.*(closed|reset|aborted|forcibly)'
    'the remote server returned an error'
) -join '|'

function Test-MFAReportTransientError {
    <#
    .SYNOPSIS
    Decides whether a failure is worth retrying.

    .DESCRIPTION
    Returns $false for anything that does not match a known transient shape, so
    terminal errors fail immediately rather than being retried.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    # Anchored on word boundaries so an identity or message containing '429'
    # as part of a larger token does not read as an HTTP status.
    if ($Message -match '\b(429|503)\b') { return $true }

    return [bool]($Message -match $script:MFAReportTransientPattern)
}

function Get-MFAReportRetryDelay {
    <#
    .SYNOPSIS
    Computes the backoff delay for a given attempt.

    .DESCRIPTION
    Exponential with full jitter. Jitter matters: without it, a population of
    mailboxes failing at the same moment retries in lockstep and re-creates the
    burst that caused the throttling.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 64)]
        [int]$Attempt,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$InitialDelaySeconds = 2,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$MaxDelaySeconds = 60
    )

    if ($InitialDelaySeconds -le 0) { return 0 }

    $exponential = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $Attempt - 1), $MaxDelaySeconds)
    return [int](Get-Random -Minimum 0 -Maximum ([int]$exponential + 1))
}

function Invoke-MFAReportRetry {
    <#
    .SYNOPSIS
    Runs a scriptblock, retrying only transient failures.

    .DESCRIPTION
    Pass -InitialDelaySeconds 0 to disable waiting, which is what the tests do so
    they can exercise the retry logic without sleeping.

    The scriptblock must be self-contained with respect to module-private
    functions: it is invoked with the call operator from this scope, so it should
    only call cmdlets available in the module session state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxAttempt = 4,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$InitialDelaySeconds = 2,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$MaxDelaySeconds = 60
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $message = $_.Exception.Message

            if ($attempt -ge $MaxAttempt -or -not (Test-MFAReportTransientError -Message $message)) {
                throw
            }

            $delay = Get-MFAReportRetryDelay -Attempt $attempt `
                -InitialDelaySeconds $InitialDelaySeconds -MaxDelaySeconds $MaxDelaySeconds

            Write-Verbose "$Operation failed with a transient error (attempt $attempt of $MaxAttempt); retrying in ${delay}s. $message"
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
}
