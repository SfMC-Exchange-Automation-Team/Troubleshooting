#Requires -Version 5.1

<#
    DISCLAIMER:
    This script is provided "as is" with no warranties or guarantees, and confers no rights.
    This script is not officially supported by Microsoft. Use of the script is at your own risk.
    Microsoft and the author disclaim any liability for any damages or loss resulting from the use of this script.
    The script is intended for informational purposes only and has been provided as a courtesy.
    Users should exercise caution and test it thoroughly before use in any non-testing environment.
#>


$script:ExoQueueVersion = '1.6.5'

# Documented service limit: 100 query requests per rolling 5 minutes. Tracked at script scope so
# two runs in the same session share one budget rather than each believing it has the whole of it.
$script:ExoQueueRequestLog = [System.Collections.Generic.List[datetime]]::new()

# A page shorter than the requested ResultSize normally means the data is exhausted. It can also
# mean the service capped ResultSize below what was asked - the documented default is 1000 - in
# which case every page looks short and the run would stop at page 1 reporting the cap as the queue
# depth. Pages at or above this size are therefore not trusted to be the last one.
#
# 100, not the documented 1000. At 1000 the probe only ever caught a cap AT the documented default:
# a role capped at 100, 250 or 500 returned a short page on the first query, was trusted as an
# exhausted queue, and the cap was reported as the queue depth with Truncated=False - the exact
# 1.4.x failure this probe exists to prevent, surviving inside the fix for it. Measured against a
# service capped at 10 while 5000 was requested, the run returned 10 of 35 messages and called
# itself complete.
#
# The cost of lowering it is one extra query on a run whose queue is between this threshold and
# -ResultSize, and nothing at all on the two common shapes: a quiet queue stays at one query, and a
# real backlog fills a page and proves the service honours the request. What remains below the
# threshold is not a plausible service limit.
$script:ExoQueueCapProbeThreshold = 100

# The names Get-MessageTraceV2 might use for the received timestamp, most likely first. Learn shows
# the display name "Received Time"; Get-MessageTrace v1 used "Received".
$script:ExoQueueReceivedNames = @('Received', 'ReceivedTime', 'Received Time', 'ReceivedUtc')

# How many rows to sample before giving up on finding the received-timestamp property. Sampling only
# the first row meant one row with an unreadable value blanked ReceivedUtc for every message in the
# run, which degrades the oldest-first ordering into arrival order without saying so.
$script:ExoQueueReceivedSampleLimit = 25

# Leading characters a spreadsheet evaluates as a formula. A [char[]] membership test rather than a
# regex: this runs against every string property of every exported row.
$script:ExoQueueFormulaLeadChars = [char[]]@('=', '+', '-', '@')

$script:ExoQueueTransientPattern = @(
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

function Get-ExoQueueProperty {
    <#
    .SYNOPSIS
    Reads a property that may not exist, without throwing under StrictMode.

    .DESCRIPTION
    Get-MessageTraceV2 is generated inside the REST session rather than shipped in the module, so
    its output shape is not pinned by anything on disk. Dot access on an absent property is fatal
    under Set-StrictMode -Version 3.0, which is why every read goes through here.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }

    return $property.Value
}

function ConvertTo-ExoQueueUtcValue {
    <#
    .SYNOPSIS
    Normalises one raw received value to Kind=Utc, or returns $null if it is not a time.

    .DESCRIPTION
    Split out of Get-ExoQueueReceivedUtc so the hot paths can handle the overwhelmingly common
    [datetime] case inline and call in here only for the string fallback.

    Treating a Kind=Unspecified value as local is precisely the 1.4.3 paging defect, so an
    unspecified kind is stamped as UTC rather than converted.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [datetime]) {
        $parsed = $Value
    }
    else {
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                  [System.Globalization.DateTimeStyles]::AssumeUniversal
        $ok = [datetime]::TryParse([string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)
        if (-not $ok) { return $null }
    }

    if ($parsed.Kind -eq [System.DateTimeKind]::Utc)   { return $parsed }
    if ($parsed.Kind -eq [System.DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
    return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
}

function Resolve-ExoQueueReceivedName {
    <#
    .SYNOPSIS
    Picks the property name this tenant's trace rows actually use for the received timestamp.

    .DESCRIPTION
    Resolving once per run and then reading that one name directly is what keeps grouping off the
    candidate-scan path: Get-ExoQueueReceivedUtc costs about 0.6 ms per row because it makes up to
    four nested advanced-function calls, which is roughly a minute per 100,000 rows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$SampleRow
    )

    if ($null -eq $SampleRow) { return $null }

    $properties = $SampleRow.PSObject.Properties
    foreach ($name in $script:ExoQueueReceivedNames) {
        $property = $properties[$name]
        if ($null -ne $property -and $null -ne (ConvertTo-ExoQueueUtcValue -Value $property.Value)) {
            return $name
        }
    }

    return $null
}

function Get-ExoQueueReceivedUtc {
    <#
    .SYNOPSIS
    Returns a trace row's received time, normalised to Kind=Utc.

    .DESCRIPTION
    Learn documents the output timestamps as UTC and shows the display name as "Received Time";
    Get-MessageTrace v1 used "Received". Several candidate names are tried so a service-side rename
    degrades into a reported truncation rather than a wrong window.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return $null }

    $properties = $InputObject.PSObject.Properties
    foreach ($name in $script:ExoQueueReceivedNames) {
        $property = $properties[$name]
        if ($null -eq $property) { continue }

        $value = ConvertTo-ExoQueueUtcValue -Value $property.Value
        if ($null -ne $value) { return $value }
    }

    return $null
}

function ConvertTo-ExoQueueRequestTime {
    <#
    .SYNOPSIS
    Converts a UTC instant into the clock the query parameters are expressed in.

    .DESCRIPTION
    The single place where the two clocks meet. 1.4.3 had no such place: it seeded EndDate from
    Get-Date (local) and then re-seeded it from a UTC output value, so the window silently shifted
    by the machine's UTC offset on every page after the first.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Utc,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Utc', 'Local')]
        [string]$Basis
    )

    if ($Basis -eq 'Local') { return $Utc.ToLocalTime() }
    return [datetime]::SpecifyKind($Utc, [System.DateTimeKind]::Utc)
}

function ConvertTo-ExoQueueSecondBoundary {
    <#
    .SYNOPSIS
    Rounds a cursor instant UP to the next whole second, so the service does not exclude its own row.

    .DESCRIPTION
    Get-MessageTraceV2 honours EndDate only to whole-second precision. Measured against a live
    tenant: a timestamp T of 18:51:09.4450000Z carrying three rows returned NOTHING at T for
    EndDate = T, nothing for T plus one tick, and all three for T plus one second. The service is
    flooring EndDate to the second and comparing Received against that.

    The consequence is severe, because the paging cursor is seeded from a row's own Received. Seeding
    the next page with 18:51:09.445 asks for rows at or before 18:51:09.000, which excludes every row
    in that second - including ones never returned. They become unreachable, and no
    StartingRecipientAddress can rescue them, because EndDate has already discarded them before the
    recipient filter is considered. Measured cost: 42 of 78 rows retrieved at -ResultSize 5, 57 at 10,
    70 at 25, every run reporting Truncated=False.

    Rounding up to the next whole second makes the boundary second INCLUDED rather than excluded. The
    overlap that re-fetches is discarded by the existing deduplication.

    This never moves the cursor forward, so the monotonicity guard is unaffected: a row's Received is
    always at or before the floor of the EndDate that returned it, and rounding up to a whole second
    therefore lands at or before that same EndDate.

    A value already exactly on a second is returned unchanged, or the cursor could never progress.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Utc
    )

    $remainder = $Utc.Ticks % [TimeSpan]::TicksPerSecond
    if ($remainder -eq 0) { return $Utc }
    return $Utc.AddTicks([TimeSpan]::TicksPerSecond - $remainder)
}

function Test-ExoQueueAmbiguousRequestTime {
    <#
    .SYNOPSIS
    Is this request time one the service cannot resolve to a single instant?

    .DESCRIPTION
    Get-MessageTraceV2 is OFFSET-AWARE. Measured against a live tenant: a Kind=Utc value arrives as
    "...Z", a Kind=Local value arrives carrying its per-instant offset, and both are read correctly.
    Only Kind=Unspecified has no offset to read, and is treated as local.

    That matters for the one hour a year that happens twice. A local wall clock inside it is
    ambiguous on its own - 01:30 Central on 1 Nov 2026 is both 06:30Z and 07:30Z - but a value
    carrying an offset is not ambiguous at all. .NET keeps the daylight side of such a value in a
    hidden flag when it came from ToLocalTime(), which is exactly how the paging cursor is built, so
    the two readings serialise as "01:30:00-05:00" and "01:30:00-06:00" despite having identical
    ticks, and each round-trips to the instant it came from.

    So the cursor is safe, and so is any window this script computes for itself. What is NOT safe is
    a bare date supplied by the caller - "2026-11-01 01:30" has Kind=Unspecified, carries no offset,
    and genuinely cannot say which of the two instants was meant. That is the only case this
    reports, and it is a warning rather than a stop, because one reading has to be chosen and .NET's
    choice (standard time) is as defensible as any.

    An earlier version stopped the run whenever the CURSOR landed in the repeated hour. That was
    wrong: it rested on a test double that discarded the offset, and it would have truncated healthy
    runs for an hour every year. See the 1.6.3 note.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$RequestTime
    )

    # A value carrying an offset is never ambiguous on the wire, whatever the wall clock says.
    if ($RequestTime.Kind -ne [System.DateTimeKind]::Unspecified) { return $false }

    try {
        return [bool][System.TimeZoneInfo]::Local.IsAmbiguousTime($RequestTime)
    }
    catch {
        Write-Verbose "Could not test '$RequestTime' for daylight-saving ambiguity: $($_.Exception.Message)"
        return $false
    }
}

function Resolve-ExoQueueWindow {
    <#
    .SYNOPSIS
    Turns the age or explicit-date parameters into one start/end pair.

    .DESCRIPTION
    Takes a single reading of the clock for the whole run. 1.4.3 called Get-Date six separate
    times, so a run that crossed a minute boundary produced files whose names disagreed, and a run
    that crossed midnight filed its results under the wrong day.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$NowUtc,

        [Parameter()]
        [int]$AgeMinutes = 0,

        [Parameter()]
        [int]$AgeHours = 0,

        [Parameter()]
        [int]$AgeDays = 0,

        [Parameter()]
        [AllowNull()]
        [object]$StartDate,

        [Parameter()]
        [AllowNull()]
        [object]$EndDate
    )

    $endUtc = $NowUtc

    # Deliberately [object] rather than [Nullable[datetime]]: PowerShell collapses a bound
    # Nullable[datetime] to a plain DateTime, which has no .Value property, so reading .Value is
    # fatal under StrictMode.
    if ($null -ne $StartDate) {
        $start = [datetime]$StartDate
        $startUtc = if ($start.Kind -eq [System.DateTimeKind]::Utc) { $start } else { $start.ToUniversalTime() }

        if ($null -ne $EndDate) {
            $end = [datetime]$EndDate
            $endUtc = if ($end.Kind -eq [System.DateTimeKind]::Utc) { $end } else { $end.ToUniversalTime() }
        }
    }
    elseif ($AgeDays -gt 0)    { $startUtc = $NowUtc.AddDays(-$AgeDays) }
    elseif ($AgeHours -gt 0)   { $startUtc = $NowUtc.AddHours(-$AgeHours) }
    else                       { $startUtc = $NowUtc.AddMinutes(-$AgeMinutes) }

    if ($startUtc -ge $endUtc) {
        throw "The start of the search window ($startUtc) is not earlier than the end ($endUtc)."
    }

    # Documented Get-MessageTraceV2 limits: 90 days retained, at most 10 days returned per query.
    $span = $endUtc - $startUtc
    if ($span.TotalDays -gt 10) {
        throw ('The search window is {0:N1} days. Get-MessageTraceV2 returns at most 10 days per query.' -f $span.TotalDays)
    }
    if (($NowUtc - $startUtc).TotalDays -gt 90) {
        throw ('The search window starts {0:N1} days ago. Get-MessageTraceV2 retains 90 days.' -f ($NowUtc - $startUtc).TotalDays)
    }

    [pscustomobject]@{
        StartUtc = $startUtc
        EndUtc   = $endUtc
        Span     = $span
    }
}

function Test-ExoQueueTransientError {
    <#
    .SYNOPSIS
    Decides whether a failure is worth retrying.

    .DESCRIPTION
    Returns $false for anything that does not match a known transient shape, so terminal errors
    fail immediately rather than being retried. Ported from MailboxMFAReport\Private\Resilience.ps1.
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

    # Anchored on word boundaries so an address or subject containing '429' as part of a larger
    # token does not read as an HTTP status.
    if ($Message -match '\b(429|503)\b') { return $true }

    return [bool]($Message -match $script:ExoQueueTransientPattern)
}

function Get-ExoQueueRetryDelay {
    <#
    .SYNOPSIS
    Computes the backoff delay for a given attempt.

    .DESCRIPTION
    Exponential with full jitter, so two consoles throttled at the same moment do not retry in
    lockstep and recreate the burst.
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

function Invoke-ExoQueueRetry {
    <#
    .SYNOPSIS
    Runs a scriptblock, retrying only transient failures.

    .DESCRIPTION
    Pass -InitialDelaySeconds 0 to disable waiting, which is what the tests do so they can exercise
    the retry logic without sleeping.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [Parameter()]
        [ValidateRange(1, 11)]
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

            if ($attempt -ge $MaxAttempt -or -not (Test-ExoQueueTransientError -Message $message)) {
                throw
            }

            $delay = Get-ExoQueueRetryDelay -Attempt $attempt `
                -InitialDelaySeconds $InitialDelaySeconds -MaxDelaySeconds $MaxDelaySeconds

            Write-Verbose "$Operation failed with a transient error (attempt $attempt of $MaxAttempt); retrying in ${delay}s. $message"
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
        }
    }
}

function Wait-ExoQueueThrottleBudget {
    <#
    .SYNOPSIS
    Holds the run inside the documented request budget.

    .DESCRIPTION
    Get-MessageTraceV2 accepts 100 query requests per rolling 5 minute window. 1.4.3 defaulted to
    95 pages with no pacing, so one run consumed almost the entire allowance and a second run in
    the same window was throttled immediately.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$MaxRequests = 90,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$WindowSeconds = 300
    )

    $now    = [datetime]::UtcNow
    $cutoff = $now.AddSeconds(-$WindowSeconds)

    while ($script:ExoQueueRequestLog.Count -gt 0 -and $script:ExoQueueRequestLog[0] -lt $cutoff) {
        $script:ExoQueueRequestLog.RemoveAt(0)
    }

    if ($script:ExoQueueRequestLog.Count -ge $MaxRequests) {
        $oldest = $script:ExoQueueRequestLog[0]
        $wait   = [int][Math]::Ceiling(($oldest.AddSeconds($WindowSeconds) - $now).TotalSeconds) + 1
        if ($wait -gt 0) {
            Write-Warning ('Approaching the Get-MessageTraceV2 request limit ({0} requests per {1}s). Pausing {2}s.' -f $MaxRequests, $WindowSeconds, $wait)
            Start-Sleep -Seconds $wait
        }
        $script:ExoQueueRequestLog.RemoveAt(0)
    }

    $script:ExoQueueRequestLog.Add([datetime]::UtcNow)
}

function Get-ExoQueueTraceResult {
    <#
    .SYNOPSIS
    Pages through Get-MessageTraceV2 and returns every recipient row it retrieved.

    .DESCRIPTION
    Get-MessageTraceV2 has no pagination. The documented technique is to reissue the query with
    StartingRecipientAddress and EndDate taken from the last row of the previous page.

    Three things went wrong with that in 1.4.3 and are fixed here:
      - EndDate was seeded locally and then re-seeded from a UTC value, so west of UTC the window
        widened instead of narrowing. There is now one conversion point and a guard that refuses
        to let EndDate advance, which makes termination independent of the time basis.
      - A failure on any page returned from the whole function, discarding every page already
        retrieved along with the request quota spent on it. Partial results are now kept.
      - Runs that stopped early still reported and logged their count as though it were complete.
        Every exit path now sets Truncated and TruncationReason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$RequestStart,

        [Parameter(Mandatory = $true)]
        [datetime]$RequestEnd,

        [Parameter(Mandatory = $true)]
        [string[]]$Status,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 5000)]
        [int]$ResultSize,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 500)]
        [int]$MaxQueryPages,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Utc', 'Local')]
        [string]$TimeBasis,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$RecipientAddress,

        [Parameter()]
        [ValidateRange(0, 60000)]
        [int]$ThrottleDelayMilliseconds = 3000,

        [Parameter()]
        [ValidateRange(1, 11)]
        [int]$MaxRetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 2,

        [Parameter()]
        [scriptblock]$ProgressAction
    )

    $rows     = [System.Collections.Generic.List[object]]::new()
    $seen     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $warnings = [System.Collections.Generic.List[string]]::new()

    $pageEnd         = $RequestEnd
    # The same boundary as an instant. The monotonicity and stall checks compare on this, because
    # request-clock values are not monotonic across a daylight-saving fall-back.
    $pageEndUtc      = if ($RequestEnd.Kind -eq [System.DateTimeKind]::Utc) { $RequestEnd }
                       elseif ($RequestEnd.Kind -eq [System.DateTimeKind]::Local) { $RequestEnd.ToUniversalTime() }
                       else { [datetime]::SpecifyKind($RequestEnd, [System.DateTimeKind]::Local).ToUniversalTime() }
    $startingAddress = $null
    $page            = 0
    $duplicateRows   = 0
    $truncated       = $false
    $reason          = $null
    $receivedName    = $null
    $maxPageRows     = 0
    $capSuspected    = $false
    $fullPageSeen    = $false
    $probeShortCount = 0
    $exhausted       = $false

    while ($page -lt $MaxQueryPages) {
        $page++

        $traceParams = @{
            StartDate   = $RequestStart
            EndDate     = $pageEnd
            Status      = $Status
            ResultSize  = $ResultSize
            ErrorAction = 'Stop'
        }

        # Journal mail is addressed TO the journal address. 1.4.3 filtered SenderAddress here,
        # which is why -JournalOnly returned almost nothing.
        if ($null -ne $RecipientAddress -and $RecipientAddress.Count -gt 0) {
            $traceParams.RecipientAddress = $RecipientAddress
        }
        if (-not [string]::IsNullOrWhiteSpace($startingAddress)) {
            $traceParams.StartingRecipientAddress = $startingAddress
        }

        Write-Verbose ("Page {0}: StartDate={1:o} EndDate={2:o} StartingRecipientAddress='{3}'" -f `
            $page, $RequestStart, $pageEnd, $startingAddress)

        $pageRows = @()
        try {
            # The budget is charged INSIDE the retried block. Charging it once per page instead
            # undercounted by the retry factor: a stub that always failed transiently issued four
            # requests and had one charged, so -MaxRetryCount 3 over 20 pages could spend 60
            # requests against the documented 100-per-5-minutes limit while believing it spent 20.
            $pageRows = @(Invoke-ExoQueueRetry `
                -Operation ('Get-MessageTraceV2 page {0}' -f $page) `
                -MaxAttempt $MaxRetryCount `
                -InitialDelaySeconds $RetryDelaySeconds `
                -ScriptBlock {
                    Wait-ExoQueueThrottleBudget
                    Get-MessageTraceV2 @traceParams
                })
        }
        catch {
            # 1.4.3 returned from the whole function here, discarding every page already fetched.
            $truncated = $true
            $reason    = 'QueryFailed'
            $message   = ('Page {0} failed after {1} attempt(s): {2}' -f $page, $MaxRetryCount, $_.Exception.Message)
            $warnings.Add($message)
            Write-Warning $message
            $page--
            break
        }

        if ($pageRows.Count -gt $maxPageRows) { $maxPageRows = $pageRows.Count }
        if ($pageRows.Count -eq $ResultSize) { $fullPageSeen = $true }

        if ($null -eq $receivedName -and $pageRows.Count -gt 0) {
            # Sampled across rows, not just the first. One row with an unreadable received value
            # blanked ReceivedUtc for the whole run and silently turned the oldest-first ordering
            # into arrival order.
            $sampleLimit = [Math]::Min($pageRows.Count, $script:ExoQueueReceivedSampleLimit)
            for ($sample = 0; $sample -lt $sampleLimit -and $null -eq $receivedName; $sample++) {
                $receivedName = Resolve-ExoQueueReceivedName -SampleRow $pageRows[$sample]
            }
        }

        $newOnPage = 0
        foreach ($row in $pageRows) {
            # Composite key, not MessageId. Keeping every recipient row means any duplicate the
            # cursor produces becomes visible instead of being absorbed by a MessageId collapse.
            # Property reads inlined: this runs once per retrieved row.
            $properties = $row.PSObject.Properties

            $property = $properties['MessageId']
            $idPart   = if ($null -eq $property) { '' } else { [string]$property.Value }

            $property   = $properties['RecipientAddress']
            $rcptPart   = if ($null -eq $property) { '' } else { [string]$property.Value }

            $timePart = ''
            if ($null -ne $receivedName) {
                $property = $properties[$receivedName]
                if ($null -ne $property) {
                    $value = $property.Value
                    if ($value -is [datetime]) { $timePart = $value.ToString('o') }
                    else {
                        $converted = ConvertTo-ExoQueueUtcValue -Value $value
                        if ($null -ne $converted) { $timePart = $converted.ToString('o') }
                    }
                }
            }

            $key = '{0}|{1}|{2}' -f $idPart, $rcptPart, $timePart

            if ($seen.Add($key)) { $rows.Add($row); $newOnPage++ }
            else { $duplicateRows++ }
        }

        # The previous page came back short but large enough that a cap could explain it, so this
        # query was issued to settle which it was. NEW rows here prove the short page was not the end
        # of the data, which is the entire signature of a server-side cap. An empty page proves the
        # opposite and is the ordinary way a run ends, so nothing is flagged for it.
        #
        # Read after the dedup loop, not before it, and counted in new rows rather than returned
        # rows: a service that replays part of the previous page returns plenty of rows and no new
        # information, and judging the probe on the raw count reported a cap on that. A false
        # ResultSizeCapped is worse than none, because it is the value .NOTES sends the operator to
        # read when asking whether their role is capped.
        if ($probeShortCount -gt 0) {
            if ($newOnPage -gt 0 -and -not $capSuspected) {
                $capSuspected = $true
                $message = ('Page {0} returned {1} rows for a requested ResultSize of {2}, and page {3} then returned more data. The service is capping ResultSize for this role, so a short page here does not mean the queue is exhausted. Paging continues; the counts are still complete.' -f `
                    ($page - 1), $probeShortCount, $ResultSize, $page)
                $warnings.Add($message)
                Write-Warning $message
            }
            $probeShortCount = 0
        }

        if ($null -ne $ProgressAction) {
            & $ProgressAction $page $pageRows.Count $newOnPage $rows.Count
        }

        # A page shorter than requested normally means the data is exhausted. It can also mean the
        # service capped ResultSize below what was asked - the documented default is 1000 - and
        # then EVERY page looks short, so the run would stop here at page 1 and report the cap as
        # the queue depth. Deciding between the two costs one extra query, and this is where the
        # run works out whether it has to spend it.
        if ($pageRows.Count -lt $ResultSize) {
            # A page that came back at exactly ResultSize, anywhere in this run, proves the service
            # honours the request. A short page after that is the documented end of the data, and
            # probing it would spend a request on nearly every ordinary run for no information.
            if ($fullPageSeen) { $exhausted = $true; break }

            # Too small for any plausible cap to explain, so trust it. This is the blind spot, and it
            # is now narrow: a service limit below ExoQueueCapProbeThreshold rows is not a shape
            # Exchange Online produces. It was 1000, which left every cap under the documented
            # default invisible.
            if ($pageRows.Count -lt $script:ExoQueueCapProbeThreshold) { $exhausted = $true; break }

            # Neither. Nothing is flagged yet - a short page that really was the last one is
            # indistinguishable from a capped one until the next query answers it.
            $probeShortCount = $pageRows.Count
        }

        if ($newOnPage -eq 0) {
            $truncated = $true
            $reason    = 'NoNewRows'
            $message   = ('Page {0} returned only rows already seen. Stopping before repeating the same query.' -f $page)
            $warnings.Add($message)
            Write-Warning $message
            break
        }

        $lastRow   = $pageRows[$pageRows.Count - 1]
        $cursorUtc = Get-ExoQueueReceivedUtc -InputObject $lastRow
        if ($null -eq $cursorUtc) {
            $truncated = $true
            $reason    = 'CursorUnavailable'
            $message   = ('The last row on page {0} has no readable received time. Stopping before repeating the same query.' -f $page)
            $warnings.Add($message)
            Write-Warning $message
            break
        }

        $nextAddress = [string](Get-ExoQueueProperty -InputObject $lastRow -Name 'RecipientAddress')

        # The service floors EndDate to whole seconds, so a cursor seeded with a row's own sub-second
        # Received asks for rows strictly before that second and silently drops every row inside it,
        # including ones never returned. Rounding up to the next whole second includes the boundary
        # second instead; the overlap is removed by the deduplication above. See
        # ConvertTo-ExoQueueSecondBoundary for the measurements.
        $cursorBoundaryUtc = ConvertTo-ExoQueueSecondBoundary -Utc $cursorUtc
        $nextEnd = ConvertTo-ExoQueueRequestTime -Utc $cursorBoundaryUtc -Basis $TimeBasis

        # EndDate must never move FORWARD. That is what makes termination independent of whether
        # the time basis is right, and it is the 1.4.3 defect: a local page-1 EndDate re-seeded
        # from a UTC output value widened the window by the machine's offset on every page.
        #
        # Compared as INSTANTS, not as request-clock values. DateTime comparison is on ticks alone,
        # and local wall clocks are not monotonic across a daylight-saving fall-back: paging from
        # 07:02Z to 06:43Z - correctly backwards - reads as 01:02 to 01:43 and looks like a jump
        # forward. That misfired as CursorAdvanced, truncated a healthy run, and advised switching
        # -TimeBasis, which would not have helped because nothing was wrong with it.
        # Compared as the boundary actually sent, not the raw cursor: $pageEndUtc tracks what went on
        # the wire as EndDate, and since 1.6.4 that is the cursor rounded up to a whole second.
        # Rounding up can never move the boundary forward - a row's Received is always at or before
        # the floor of the EndDate that returned it - so this guard is unaffected by it.
        if ($cursorBoundaryUtc -gt $pageEndUtc) {
            $truncated = $true
            $reason    = 'CursorAdvanced'
            $message   = ('The paging cursor moved forward on page {0} (EndDate {1:o} to {2:o}), which means -TimeBasis {3} is wrong for this tenant. Stopping. Try -TimeBasis {4}.' -f `
                $page, $pageEndUtc, $cursorBoundaryUtc, $TimeBasis, $(if ($TimeBasis -eq 'Utc') { 'Local' } else { 'Utc' }))
            $warnings.Add($message)
            Write-Warning $message
            break
        }

        # An EndDate that stays put is NOT a stall on its own: a burst of messages sharing one
        # timestamp is exactly what StartingRecipientAddress exists to page through, and refusing
        # equality here dropped 15 of 20 retrievable rows in that shape. The real stall is when
        # neither half of the cursor moves, because that reissues the identical query.
        #
        # Also compared as instants: two different instants inside the repeated hour share a wall
        # clock, and treating them as equal would call a healthy page a stall.
        #
        # This is now the exit that catches a single second holding more rows than -ResultSize. That
        # case is genuinely unpageable - the boundary second can never be cleared - and stopping here
        # reports it honestly as INCOMPLETE rather than losing the rest in silence.
        if ($cursorBoundaryUtc -eq $pageEndUtc -and $nextAddress -eq $startingAddress) {
            $truncated = $true
            $reason    = 'CursorStalled'
            $message   = ('The paging cursor did not advance on page {0} (EndDate {1:o}, recipient ''{2}'' unchanged). Results are INCOMPLETE. This usually means one second holds more rows than -ResultSize; raise -ResultSize or narrow the time range.' -f $page, $pageEndUtc, $nextAddress)
            $warnings.Add($message)
            Write-Warning $message
            break
        }

        $pageEnd         = $nextEnd
        $pageEndUtc      = $cursorBoundaryUtc
        $startingAddress = [string](Get-ExoQueueProperty -InputObject $lastRow -Name 'RecipientAddress')

        if ($ThrottleDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $ThrottleDelayMilliseconds }
    }

    # $exhausted, not just the page number. Reaching the page limit and finishing ON the page limit
    # are different runs with the same $page, and testing only the number reported a complete run as
    # INCOMPLETE - to the console, to $result.Truncated, and permanently into the trend log, which
    # is the one artefact nobody goes back and corrects. -MaxQueryPages 1 mislabelled every run.
    if (-not $truncated -and -not $exhausted -and $page -ge $MaxQueryPages) {
        $truncated = $true
        $reason    = 'MaxQueryPages'
        $message   = ('Reached -MaxQueryPages ({0}). Results are INCOMPLETE. Narrow the time range, add filters, or raise -MaxQueryPages.' -f $MaxQueryPages)
        $warnings.Add($message)
        Write-Warning $message
    }

    [pscustomobject]@{
        Rows             = $rows
        PagesQueried     = $page
        DuplicateRows    = $duplicateRows
        Truncated        = $truncated
        TruncationReason = $reason

        # The largest page the service actually returned, and whether it ever came back short of
        # the requested ResultSize by an amount a server-side cap could explain. On the first run
        # against a real tenant these two are the direct answer to "is my role capped at 1000".
        EffectivePageSize = $maxPageRows
        ResultSizeCapped  = $capSuspected

        Warnings         = @($warnings)
    }
}

function Test-ExoQueueConnection {
    <#
    .SYNOPSIS
    Reports whether the session can actually run Get-MessageTraceV2.

    .DESCRIPTION
    1.4.3 probed with Get-Mailbox -ResultSize 1, which needs a recipient-management role that a
    message-tracking operator may not hold, and then checked only that a module named
    ExchangeOnlineManagement was loaded. That check cannot tell 3.4.0 - which has no
    Get-MessageTraceV2 at all - from 3.9.2, so the wrong module version surfaced as a generic
    red error in the middle of the query loop.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $result = [pscustomobject]@{
        Connected     = $false
        Reason        = $null
        Organization  = $null
        ModuleVersion = $null
    }

    $module = Get-Module -Name ExchangeOnlineManagement |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($null -ne $module) { $result.ModuleVersion = $module.Version }

    if (-not (Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue)) {
        $result.Reason = 'The ExchangeOnlineManagement module is not loaded.'
        return $result
    }

    $connection = $null
    try {
        $connection = @(Get-ConnectionInformation -ErrorAction Stop) |
            Where-Object { $_.State -eq 'Connected' } |
            Select-Object -First 1
    }
    catch {
        $result.Reason = "Get-ConnectionInformation failed: $($_.Exception.Message)"
        return $result
    }

    if ($null -eq $connection) {
        $result.Reason = 'No active Exchange Online connection.'
        return $result
    }

    $result.Organization = Get-ExoQueueProperty -InputObject $connection -Name 'Organization'

    if (-not (Get-Command -Name Get-MessageTraceV2 -ErrorAction SilentlyContinue)) {
        $result.Reason = "Connected to Exchange Online, but Get-MessageTraceV2 is not available. It requires ExchangeOnlineManagement 3.7.0 or later; this session has $($result.ModuleVersion)."
        return $result
    }

    $result.Connected = $true
    return $result
}

function Get-ExoQueueJournalRuleAddress {
    <#
    .SYNOPSIS
    Reads the journal recipient out of the tenant's own journal rules.

    .DESCRIPTION
    The tenant already knows this. Journaling in Exchange Online is configured with a journal rule,
    and that rule names the address journal reports are sent to - which is exactly the address
    -JournalOnly and -JournalExclude need. Until 1.6.1 the script asked a human to type it and then
    cached the answer in the registry, which is slower, gets typed wrongly, and goes stale silently
    when journaling is repointed.

    Only enabled rules are returned. A disabled rule is not producing journal traffic, so filtering
    on its address would remove nothing and, worse, would look like it had worked.

    Degrades quietly: a message-tracking operator may not hold the role that can read journal rules,
    and that is a reason to fall back to the saved value, not a reason to fail the run.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    if (-not (Get-Command -Name Get-JournalRule -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Get-JournalRule is not available to this session; cannot discover the journal address.'
        return @()
    }

    try {
        $rules = @(Get-JournalRule -ErrorAction Stop)
    }
    catch {
        # Almost always a permissions answer rather than a real failure.
        Write-Verbose "Get-JournalRule failed: $($_.Exception.Message)"
        return @()
    }

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in $rules) {
        $enabled = Get-ExoQueueProperty -InputObject $rule -Name 'Enabled'
        # $null means the property is absent, which is not the same as disabled, so an absent value
        # is treated as enabled. Everything else is read through its string form: this object is not
        # pinned by anything on disk, and a rule reporting 'False' or 'Disabled' as text rather than
        # a [bool] would otherwise be read as enabled - the exact mistake this check exists to stop.
        if ($null -ne $enabled) {
            $state = ([string]$enabled).Trim()
            if ($state -in @('False', 'Disabled', '0')) { continue }
        }

        # The documented property is JournalEmailAddress. The others are tried for the same reason
        # the received timestamp has a candidate list: this object is not pinned by anything on disk.
        foreach ($name in @('JournalEmailAddress', 'JournalRecipient', 'Recipient')) {
            $value = Get-ExoQueueProperty -InputObject $rule -Name $name
            if ($null -eq $value) { continue }
            $address = ([string]$value).Trim()
            if ([string]::IsNullOrWhiteSpace($address)) { continue }

            # Rules can carry an address as "Display Name <smtp@domain>" or as a bare address.
            $m = [regex]::Match($address, '<([^>]+)>')
            if ($m.Success) { $address = $m.Groups[1].Value.Trim() }

            if ($address -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' -and -not $found.Contains($address)) {
                $found.Add($address)
            }
            break
        }
    }

    @($found)
}

function Resolve-ExoQueueJournalSmtp {
    <#
    .SYNOPSIS
    Determines the journal address, in the order parameter, registry, prompt.

    .DESCRIPTION
    1.4.3 had no way to change a saved address except deleting the registry key, and applied its
    email validation only to freshly typed input, so an empty or malformed saved value went
    straight into the query.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$JournalSmtp,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Organization,

        [Parameter()]
        [switch]$SkipDiscovery,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$Quiet
    )

    # Scoped per organisation. One shared value silently applied whichever journal address happened
    # to be saved last, which is wrong the moment anyone works across two tenants - and consultants
    # do that daily. The unscoped value is still read as a fallback so existing installs keep
    # working, but anything saved from here on is written under the tenant it belongs to.
    $registryRoot = 'HKCU:\Software\Microsoft\Exchange\ExoQueue'
    $registryPath = if ([string]::IsNullOrWhiteSpace($Organization)) { $registryRoot }
                    else { Join-Path $registryRoot ('Tenants\' + ($Organization -replace '[^\w.-]', '_')) }

    # Two shapes are accepted: a literal address, and a wildcard pattern for tenants that journal
    # to a whole domain (for example *@journal.contoso.com). A wildcard is only ever matched
    # client-side by -JournalExclude; -JournalOnly passes its value to the service, which does not
    # accept wildcards, so that combination is rejected by the caller's own validation below.
    $literalPattern  = "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    $wildcardPattern = "^[a-zA-Z0-9._%+*?-]+@[a-zA-Z0-9.*?-]+\.[a-zA-Z*?]{2,}$"

    function Test-Address {
        param([string]$Address)
        if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
        if ($Address -match '[\*\?]') { return [bool]($Address -match $wildcardPattern) }
        return [bool]($Address -match $literalPattern)
    }

    if ($null -ne $JournalSmtp -and $JournalSmtp.Count -gt 0) {
        foreach ($address in $JournalSmtp) {
            if (-not (Test-Address -Address $address)) {
                throw "Invalid journal address '$address'. Expected an address such as journal@contoso.com, or a pattern such as *@journal.contoso.com."
            }
        }

        # -Force is used by scheduled runs; persisting a value from one is a side effect the
        # operator did not ask for, so the save is skipped there.
        if (-not $Force -and $PSCmdlet.ShouldProcess($registryPath, 'Save the journal address')) {
            try {
                if (-not (Test-Path -Path $registryPath)) {
                    New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
                }
                Set-ItemProperty -Path $registryPath -Name 'JournalSmtp' -Value ($JournalSmtp -join ';') -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "JournalSmtp value set to $($JournalSmtp -join ', ') in the registry. This will be saved for future use of this cmdlet." -ForegroundColor Cyan
                }
            }
            catch {
                # A policy-blocked write is not a reason to abandon the query.
                Write-Warning "Unable to save the journal address to the registry: $($_.Exception.Message)"
            }
        }

        return $JournalSmtp
    }

    # Ask the tenant before asking the human. A journal rule names the address journal reports go
    # to, which is precisely what is wanted here, and it cannot go stale the way a cached answer can.
    if (-not $SkipDiscovery) {
        $discovered = @(Get-ExoQueueJournalRuleAddress)
        if ($discovered.Count -gt 0) {
            if (-not $Quiet) {
                Write-Host "NOTE: " -ForegroundColor Cyan -NoNewline
                Write-Host "Journal address read from this tenant's journal rules: " -NoNewline
                Write-Host ($discovered -join ', ') -ForegroundColor Cyan
                Write-Host "      Pass -JournalSmtp to override it, or -SkipJournalDiscovery to use the saved value."
            }
            return $discovered
        }
        Write-Verbose 'No enabled journal rule found; falling back to the saved or prompted address.'
    }

    $saved = $null
    foreach ($path in @($registryPath, 'HKCU:\Software\Microsoft\Exchange\ExoQueue')) {
        if (-not (Test-Path -Path $path)) { continue }
        $item = Get-ItemProperty -Path $path -Name 'JournalSmtp' -ErrorAction SilentlyContinue
        $value = Get-ExoQueueProperty -InputObject $item -Name 'JournalSmtp'
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $saved = $value
            # An unscoped value predates tenant scoping and may belong to a different tenant
            # entirely. Usable, but the operator should be told which one they are getting - and
            # this warning is NOT suppressed by -Quiet, because an unattended cross-tenant run is
            # exactly the case that most needs it.
            if ($path -ne $registryPath) {
                $tenantLabel = if ([string]::IsNullOrWhiteSpace($Organization)) { 'the connected tenant' } else { $Organization }
                Write-Warning "Using a journal address saved without a tenant ('$value') against $tenantLabel. If you work across tenants, pass -JournalSmtp to confirm it belongs to this one."
            }
            break
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($saved)) {
        $addresses = @([string]$saved -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $invalid   = @($addresses | Where-Object { -not (Test-Address -Address $_) })

        if ($addresses.Count -gt 0 -and $invalid.Count -eq 0) {
            if (-not $Quiet) {
                Write-Host "NOTE: " -ForegroundColor Cyan -NoNewline
                Write-Host "The Journal SMTP address is already set to " -NoNewline
                Write-Host "$($addresses -join ', ')" -ForegroundColor Cyan -NoNewline
                Write-Host " in the registry. To change it, pass -JournalSmtp."
            }
            return $addresses
        }

        Write-Warning "The journal address saved in the registry ('$saved') is not a valid email address and is being ignored. Pass -JournalSmtp to replace it."
    }

    if ($Force) {
        throw "No journal address is available. Pass -JournalSmtp when using -Force, because the prompt is suppressed."
    }

    Write-Host "Enter the Journal address to search for. Example: Journal@contoso.com" -ForegroundColor Yellow
    $entered = Read-Host "Journal Address"
    if (-not (Test-Address -Address $entered)) {
        throw "Invalid email address '$entered'. Please try again."
    }

    if ($PSCmdlet.ShouldProcess($registryPath, 'Save the journal address')) {
        try {
            if (-not (Test-Path -Path $registryPath)) {
                # Without -Force the registry provider will not create missing parent keys, which
                # made -JournalOnly fail outright on a machine with no Exchange client profile.
                New-Item -Path $registryPath -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $registryPath -Name 'JournalSmtp' -Value $entered -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "JournalSmtp value set to $entered in the registry. This will be saved for future use of this cmdlet." -ForegroundColor Cyan
            }
        }
        catch {
            Write-Warning "Unable to save the journal address to the registry: $($_.Exception.Message)"
        }
    }

    return @($entered)
}

function Group-ExoQueueMessage {
    <#
    .SYNOPSIS
    Collapses recipient rows into message rows without discarding the recipients.

    .DESCRIPTION
    1.4.3 used Sort-Object MessageId -Unique, which kept one arbitrary row per message and threw
    the rest away before anything was exported or counted. It also reordered the results by an
    opaque token and silently merged every row that had no MessageId at all.

    Here the extra recipients are preserved as RecipientCount and Recipients, rows keep
    chronological order, and rows without a MessageId stay distinct.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$MaxRecipientsListed = 25
    )

    if ($Row.Count -eq 0) { return @() }

    # Resolved once for the whole set. Calling Get-ExoQueueReceivedUtc per row instead costs about
    # 59 s per 100,000 rows, because each call scans up to four candidate names through a nested
    # advanced function. Sampled across rows rather than just Row[0]: one row with an unreadable
    # received value used to blank ReceivedUtc for every message here, and the oldest-first sort
    # then quietly became arrival order.
    $receivedName = $null
    $sampleLimit  = [Math]::Min($Row.Count, $script:ExoQueueReceivedSampleLimit)
    for ($sample = 0; $sample -lt $sampleLimit -and $null -eq $receivedName; $sample++) {
        $receivedName = Resolve-ExoQueueReceivedName -SampleRow $Row[$sample]
    }

    $order  = [System.Collections.Generic.List[string]]::new()
    $groups = @{}
    $blank  = 0

    # Property reads are inlined from Get-ExoQueueProperty throughout this function. That helper is
    # still the tested surface and the cold paths call it, but an advanced-function call per row
    # measures 37 s per 100,000 reads against 1.3 s inlined - and this loop runs once per recipient
    # row, twice.
    foreach ($item in $Row) {
        $property  = $item.PSObject.Properties['MessageId']
        $messageId = if ($null -eq $property) { '' } else { [string]$property.Value }

        if ([string]::IsNullOrWhiteSpace($messageId)) {
            # A missing MessageId is not evidence that two rows are the same message.
            $blank++
            $key = "`0blank-$blank"
        }
        else {
            $key = $messageId
        }

        $bucket = $groups[$key]
        if ($null -eq $bucket) {
            $bucket = [System.Collections.Generic.List[object]]::new()
            $groups[$key] = $bucket
            $order.Add($key)
        }
        $bucket.Add($item)
    }

    $messages = [System.Collections.Generic.List[object]]::new()

    foreach ($key in $order) {
        $members = $groups[$key]
        $first   = $members[0]

        $recipients = [System.Collections.Generic.List[string]]::new()
        foreach ($member in $members) {
            $property = $member.PSObject.Properties['RecipientAddress']
            if ($null -eq $property) { continue }
            $address = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($address)) { $recipients.Add($address) }
        }

        $listed = if ($recipients.Count -le $MaxRecipientsListed) {
            $recipients -join '; '
        }
        else {
            '{0}; (+{1} more)' -f `
                (($recipients | Select-Object -First $MaxRecipientsListed) -join '; '),
                ($recipients.Count - $MaxRecipientsListed)
        }

        $received = $null
        if ($null -ne $receivedName) {
            $property = $first.PSObject.Properties[$receivedName]
            if ($null -ne $property) {
                $value = $property.Value
                # The overwhelmingly common case, handled without a function call. Anything else
                # goes through the shared converter.
                if ($value -is [datetime]) {
                    $received = if ($value.Kind -eq [System.DateTimeKind]::Utc) { $value }
                                elseif ($value.Kind -eq [System.DateTimeKind]::Local) { $value.ToUniversalTime() }
                                else { [datetime]::SpecifyKind($value, [System.DateTimeKind]::Utc) }
                }
                else {
                    $received = ConvertTo-ExoQueueUtcValue -Value $value
                }
            }
        }

        # Flattened into a fresh object rather than copied. PSObject.Copy() does NOT isolate a typed
        # .NET object - verified - so Add-Member on the "copy" writes the message-level properties
        # straight back onto the caller's recipient rows. The stubs in the test suite emit
        # pscustomobject, which IS isolated, so that defect was invisible offline.
        # This is also the faster path: 3.6 s per 20,000 against 22.4 s for Copy plus three
        # Add-Member calls.
        $message    = [pscustomobject]@{}
        $properties = $message.PSObject.Properties
        foreach ($sourceProperty in $first.PSObject.Properties) {
            $properties.Add([System.Management.Automation.PSNoteProperty]::new(
                $sourceProperty.Name, $sourceProperty.Value))
        }

        # Properties.Add does not replace the way Add-Member -Force did, so a source row that
        # already carries these names has to be cleared first.
        foreach ($name in @('RecipientCount', 'Recipients', 'ReceivedUtc')) {
            if ($null -ne $properties[$name]) { $properties.Remove($name) }
        }
        $properties.Add([System.Management.Automation.PSNoteProperty]::new('RecipientCount', $recipients.Count))
        $properties.Add([System.Management.Automation.PSNoteProperty]::new('Recipients',     $listed))
        $properties.Add([System.Management.Automation.PSNoteProperty]::new('ReceivedUtc',    $received))

        $messages.Add($message)
    }

    # Oldest first: for queue triage the head of the queue is the interesting end.
    #
    # Sorted here rather than with Sort-Object, which is not a stable sort on 5.1 and has no -Stable
    # switch. Fed 40 messages sharing one timestamp in arrival order it returned them 27,26,28,30,29,
    # 22,21,... - so a burst arriving inside one second, which is exactly the shape the paging cursor
    # was fixed for, came out of "oldest first" in an arbitrary order. Get-ExoQueueTopN already
    # carries a secondary sort key for this same reason.
    #
    # The key packs the arrival index into the low digits of the tick count, so ties resolve to the
    # order the service returned them in and Array.Sort needs no comparer. decimal arithmetic, not
    # long: ticks already occupy 62 bits, and decimal carries the product exactly with room to spare
    # (the largest possible key is 3.2e26 against a decimal ceiling of 7.9e28). The multiplier bounds
    # a run at 100,000,000 messages; MaxQueryPages x ResultSize caps it at 2,500,000.
    #
    # The keys are held as object, NOT as decimal, and that is load-bearing. Array.Sort(keys, items)
    # with arrays of DIFFERENT element types binds to the generic overload, which converts the items
    # array to a copy, sorts the copy and discards it: [decimal[]] keys against [object[]] items came
    # back with the keys sorted, the items untouched and no error raised anywhere. Two object[] need
    # no conversion, so both are sorted in place. Casting both arguments to [Array] also works, by
    # forcing the non-generic overload, but measured 25% slower.
    #
    # Built in the same pass that partitions out the undated messages, so this costs one multiply-add
    # per message and no extra traversal. Per 85,715 messages sharing timestamps in bursts: 1,604 ms
    # against 1,957 ms for the partition plus Sort-Object it replaces, and at parity with it when
    # every timestamp is distinct.
    #
    # Messages with no readable received time are held out and appended, because Sort-Object put
    # nulls FIRST ascending - so an unreadable timestamp presented as the most stuck mail in the
    # tenant, at the top of the console grid and the top of the CSV.
    $sortKeys = [System.Collections.Generic.List[object]]::new()
    $dated    = [System.Collections.Generic.List[object]]::new()
    $undated  = [System.Collections.Generic.List[object]]::new()

    $arrival = 0
    foreach ($message in $messages) {
        $received = $message.ReceivedUtc
        if ($null -eq $received) {
            $undated.Add($message)
        }
        else {
            $dated.Add($message)
            $sortKeys.Add(([decimal]$received.Ticks * 100000000) + $arrival)
        }
        $arrival++
    }

    $keyArray   = $sortKeys.ToArray()
    $datedArray = $dated.ToArray()
    [Array]::Sort($keyArray, $datedArray)

    # No leading comma: every call site already wraps with @(), and doing both would return an
    # array containing one array rather than the messages themselves.
    if ($undated.Count -eq 0) { return $datedArray }

    # The caller counts these off the tail, so they must stay contiguous at the end.
    $datedArray + $undated.ToArray()
}

function Get-ExoQueueTopN {
    <#
    .SYNOPSIS
    Counts the most frequent value of a property, tagged with the population it was counted over.

    .DESCRIPTION
    The single implementation replacing six near-identical copies in 1.4.3, whose drift is what
    produced the malformed XML filenames and the GridView/XML feature gap.

    Population matters: senders are counted over unique messages, recipients over recipient
    deliveries. 1.4.3 counted both over the deduplicated set, so a message queued to 200 recipients
    contributed one recipient.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Property,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 1000)]
        [int]$First,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Messages', 'RecipientDeliveries')]
        [string]$Population
    )

    if ($Source.Count -eq 0) { return @() }

    # Inlined property read, as in Group-ExoQueueMessage: this loop runs once per recipient
    # delivery, and the helper call costs 37 s per 100,000 rows against 1.3 s inlined.
    #
    # $propertyInfo, NOT $property: variable names are case-insensitive, so $property IS the
    # $Property parameter. Assigning it replaced the name being counted with a PSNoteProperty on
    # the first iteration, and every row after that read a property that does not exist.
    $counts = @{}
    foreach ($row in $Source) {
        $propertyInfo = $row.PSObject.Properties[$Property]
        $value        = if ($null -eq $propertyInfo) { '' } else { [string]$propertyInfo.Value }
        if ([string]::IsNullOrWhiteSpace($value)) { $value = '(none)' }

        $current = $counts[$value]
        if ($null -eq $current) { $counts[$value] = 1 } else { $counts[$value] = $current + 1 }
    }

    # Secondary sort on Name so ties are stable and two runs over the same data produce identical
    # output instead of looking as though the data moved. Call sites wrap with @().
    $ranked = @($counts.GetEnumerator() |
        Sort-Object -Property @{ Expression = 'Value'; Descending = $true },
                              @{ Expression = 'Name';  Descending = $false } |
        Select-Object -First $First)

    # Built explicitly rather than with Select-Object calculated properties: a scriptblock that
    # closes over $Population reads to PSScriptAnalyzer as an unused parameter.
    $output = foreach ($entry in $ranked) {
        [pscustomobject]@{
            Name       = $entry.Key
            Count      = $entry.Value
            Population = $Population
        }
    }

    @($output)
}

function Get-ExoQueueExcelPath {
    <#
    .SYNOPSIS
    Locates excel.exe, returning $null rather than throwing when it is absent.

    .DESCRIPTION
    1.4.3 printed a message when Excel was missing but left the variable unset and carried on to
    Test-Path -Path $null, which is a terminating parameter-binding error. It also looked only in
    a hardcoded Office16 directory on C:.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $appPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\excel.exe'
    try {
        $item = Get-ItemProperty -Path $appPath -ErrorAction Stop
        $candidate = Get-ExoQueueProperty -InputObject $item -Name '(default)'
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return [string]$candidate
        }
    }
    catch {
        Write-Verbose "Excel was not found in App Paths: $($_.Exception.Message)"
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($version in @('Office16', 'Office15', 'Office14')) {
            foreach ($relative in @("Microsoft Office\root\$version\EXCEL.EXE", "Microsoft Office\$version\EXCEL.EXE")) {
                $candidate = Join-Path -Path $root -ChildPath $relative
                if (Test-Path -LiteralPath $candidate) { return $candidate }
            }
        }
    }

    return $null
}

function Get-ExoQueueUnusedSuffix {
    <#
    .SYNOPSIS
    Returns '', ' (2)', ' (3)' ... - the first decoration for which none of Path already exists.

    .DESCRIPTION
    The file stamp has minute resolution, so two runs started inside the same minute produced
    identical names and Export-Csv silently overwrote the first. Re-running immediately with a
    narrower window or a different -Status is a normal triage move, which makes the export most
    likely to be destroyed the one taken seconds earlier.

    One decoration for the whole file set, not one per file. Resolving each file on its own let a
    run write "ExoQueue - <stamp> (2).csv" beside "ExoQueue - <stamp>-TopSenders.csv", and whoever
    picked the folder up afterwards had no way to tell which breakdown belonged to which results.

    Only the exports go through this. The trend log is deliberately appended and must keep its
    single per-day name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Path
    )

    if ($Path.Count -eq 0) { return '' }

    for ($attempt = 1; $attempt -le 999; $attempt++) {
        $suffix = if ($attempt -eq 1) { '' } else { ' ({0})' -f $attempt }

        $taken = $false
        foreach ($candidate in $Path) {
            $decorated = Join-Path -Path (Split-Path -Path $candidate -Parent) -ChildPath ('{0}{1}{2}' -f `
                [System.IO.Path]::GetFileNameWithoutExtension($candidate),
                $suffix,
                [System.IO.Path]::GetExtension($candidate))
            if (Test-Path -LiteralPath $decorated) { $taken = $true; break }
        }

        if (-not $taken) { return $suffix }
    }

    throw "Unable to find an unused file name for $($Path[0]) after 999 attempts."
}

function Test-ExoQueueFormulaRisk {
    <#
    .SYNOPSIS
    Reports whether any exported string value would be read as a formula by a spreadsheet.

    .DESCRIPTION
    Subjects and display names are chosen by external senders and the person opening the file is a
    tenant administrator. The values are deliberately NOT rewritten - altering a subject line would
    damage the artefact being investigated - so this only drives a warning.

    Only the first character matters, so this tests membership in a [char[]] rather than running a
    regex against every string property of every exported row.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Row
    )

    $leadChars = $script:ExoQueueFormulaLeadChars

    foreach ($item in $Row) {
        foreach ($property in $item.PSObject.Properties) {
            $value = $property.Value
            if ($value -isnot [string]) { continue }
            if ($value.Length -eq 0) { continue }
            if ($leadChars -contains $value[0]) { return $true }
        }
    }

    return $false
}

function Get-ExoQueueDestination {
    <#
    .SYNOPSIS
    Counts queued deliveries by recipient domain - the nearest thing Exchange Online offers to
    on-premises NextHopDomain.

    .DESCRIPTION
    On-premises, the first question of any transport incident is answered by Get-Queue in one line:
    which next hop is backing up, and how deep is it. Exchange Online exposes no queue object at all,
    so that question has no direct answer here.

    The recipient domain is the closest available proxy. It is NOT the next hop - a connector can
    route several domains to one host, and one domain can resolve to several - but when a single
    destination is deferring, its domain is what rises to the top of this list, which is the
    operational question being asked.

    Counted over recipient deliveries rather than messages, because a queue backing up on one
    destination is a count of deliveries waiting, not of distinct messages.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$First = 10
    )

    if ($Row.Count -eq 0) { return @() }

    $counts = @{}
    $oldest  = @{}
    foreach ($item in $Row) {
        $properties = $item.PSObject.Properties

        $property = $properties['RecipientAddress']
        $address  = if ($null -eq $property) { '' } else { [string]$property.Value }
        $at       = $address.LastIndexOf('@')
        # A recipient with no @ is not a domain; bucket it visibly rather than silently dropping it.
        $domain   = if ($at -lt 0 -or $at -eq $address.Length - 1) { '(no domain)' } else { $address.Substring($at + 1).ToLowerInvariant() }

        if ($counts.ContainsKey($domain)) { $counts[$domain] = $counts[$domain] + 1 }
        else { $counts[$domain] = 1 }

        $received = Get-ExoQueueReceivedUtc -InputObject $item
        if ($null -ne $received) {
            if (-not $oldest.ContainsKey($domain) -or $received -lt $oldest[$domain]) { $oldest[$domain] = $received }
        }
    }

    $ranked = @($counts.GetEnumerator() |
        Sort-Object -Property @{ Expression = 'Value'; Descending = $true },
                              @{ Expression = 'Name';  Descending = $false } |
        Select-Object -First $First)

    $output = foreach ($entry in $ranked) {
        $old = if ($oldest.ContainsKey($entry.Key)) { $oldest[$entry.Key] } else { $null }
        [pscustomobject]@{
            Domain     = $entry.Key
            Deliveries = $entry.Value
            OldestUtc  = $old
            AgeMinutes = if ($null -eq $old) { $null } else { [math]::Round(([datetime]::UtcNow - $old).TotalMinutes, 1) }
        }
    }

    @($output)
}

function Get-ExoQueueAge {
    <#
    .SYNOPSIS
    Describes how long the queue has been waiting.

    .DESCRIPTION
    On-premises this is Get-Message's DateReceived against now, and it is asked before anything else:
    a queue of 100,000 messages all thirty seconds old is a burst, and the same queue all six hours
    old is an outage. The count alone cannot tell those apart, and until now neither could this tool.

    Messages with no readable received time are counted separately rather than skipped, because a run
    where that number is large has no working ordering either.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Message,

        [Parameter()]
        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $ages = [System.Collections.Generic.List[double]]::new()
    $undated = 0
    $oldestUtc = $null
    $newestUtc = $null

    foreach ($item in $Message) {
        $received = Get-ExoQueueReceivedUtc -InputObject $item
        if ($null -eq $received) { $undated++; continue }
        $ages.Add(($NowUtc - $received).TotalMinutes)
        if ($null -eq $oldestUtc -or $received -lt $oldestUtc) { $oldestUtc = $received }
        if ($null -eq $newestUtc -or $received -gt $newestUtc) { $newestUtc = $received }
    }

    if ($ages.Count -eq 0) {
        return [pscustomobject]@{
            Counted = 0; Undated = $undated
            OldestUtc = $null; NewestUtc = $null
            OldestMinutes = $null; MedianMinutes = $null; NewestMinutes = $null
        }
    }

    $sorted = $ages.ToArray()
    [Array]::Sort($sorted)
    # Floor, not [int]. PowerShell's [int] cast rounds half to even, so [int](3/2) is 2 rather than
    # 1 - which picked the largest of three ages and reported the oldest message as the median.
    $mid = [int][Math]::Floor($sorted.Length / 2)
    $median = if ($sorted.Length % 2 -eq 1) { $sorted[$mid] } else { ($sorted[$mid - 1] + $sorted[$mid]) / 2 }

    [pscustomobject]@{
        Counted       = $ages.Count
        Undated       = $undated
        OldestUtc     = $oldestUtc
        NewestUtc     = $newestUtc
        OldestMinutes = [math]::Round($sorted[$sorted.Length - 1], 1)
        MedianMinutes = [math]::Round($median, 1)
        NewestMinutes = [math]::Round($sorted[0], 1)
    }
}

function Get-ExoQueue {
<#

.SYNOPSIS
    Get the Exchange Online message queue for the past X minutes, hours, or days.
.DESCRIPTION
    Get the Exchange Online message queue for the past X minutes, hours, or days. The function uses
    the Get-MessageTraceV2 cmdlet to search for messages in the queue.
    The function can output the results to a CSV, XML, or GridView.

    Two counts are reported, because they answer different questions:
      - Messages           : unique messages queued (deduplicated by MessageId).
      - Recipient deliveries: individual queued deliveries. A message addressed to 200 recipients
                              is 1 message and 200 deliveries.
    Top Senders is counted over messages. Top Recipients is counted over recipient deliveries.
.PARAMETER JournalOnly
    Search only for messages sent TO the journal address.
    The journal address is saved in the registry for future use of the cmdlet.
.PARAMETER JournalExclude
    Exclude messages sent TO the journal address.
    The journal address is saved in the registry for future use of the cmdlet.
.PARAMETER JournalSmtp
    The journal address to use, overriding and updating any value saved in the registry.
    Accepts more than one address for tenants that journal to several destinations.
.PARAMETER SkipJournalDiscovery
    Do not read the address from the tenant's journal rules; use the saved or prompted value
    instead. Discovery is the default because the tenant is authoritative and a cached answer goes
    stale silently when journaling is repointed.
.PARAMETER AgeMinutes
    The number of minutes to search for messages in the queue.
.PARAMETER AgeHours
    The number of hours to search for messages in the queue.
.PARAMETER AgeDays
    The number of days to search for messages in the queue. Get-MessageTraceV2 returns at most
    10 days per query.
.PARAMETER StartDate
    Explicit start of the search window, as an alternative to the Age parameters.
.PARAMETER EndDate
    Explicit end of the search window. Defaults to now when -StartDate is used.
.PARAMETER TimeBasis
    Which clock StartDate and EndDate are expressed in, and the clock the paging cursor is
    converted back to. Local (the default) or Utc. See the note about time zones in .NOTES.
.PARAMETER Status
    Delivery statuses to search for. Defaults to Pending. Valid values are the ones accepted by
    Get-MessageTraceV2: Delivered, Expanded, Failed, FilteredAsSpam, GettingStatus, Pending,
    Quarantined.
.PARAMETER IncludeDelivered
    Retained for compatibility. Equivalent to -Status Pending,Delivered. Ignored with a warning
    if -Status is supplied explicitly. Intended for demos and testing, not for measuring a queue.
.PARAMETER TopSenders
    The number of top senders to display in the output, counted over unique messages.
.PARAMETER TopRecipients
    The number of top recipients to display in the output, counted over recipient deliveries.
.PARAMETER TopDestinations
    How many recipient domains to show in the queued-by-destination breakdown. This is the nearest
    available equivalent to the on-premises NextHopDomain: it is the recipient domain rather than the
    actual next hop, but when one destination is deferring, its domain is what rises to the top.
    Always shown; defaults to 10.
.PARAMETER Output
    The output format(s) for the results: CSV, XML, GridView, or None. More than one may be given,
    so a single query can populate a grid and a file without paying for a second query. None cannot
    be combined with any other value.

    None means no RESULT files. The dated folder is still created and the run is still appended to
    the trend log in it, because the trend log is the point of running this repeatedly and the most
    useful entry in it - the return to zero - is the one an empty or file-less run would drop. Use
    -WhatIf for a run that touches nothing at all.
.PARAMETER OutputPath
    Directory to write results and the log into. Defaults to <SystemDrive>\temp\ExoQueueResults.
    A dated subfolder is created inside it.
.PARAMETER ResultSize
    Rows requested per query. Get-MessageTraceV2 accepts 1-5000 and defaults to 1000. If the service
    caps this below what is asked, see ResultSizeCapped in the notes.
.PARAMETER MaxQueryPages
    Maximum number of queries issued for one run. Get-MessageTraceV2 permits 100 requests per
    5 minute window, so the default of 20 deliberately leaves headroom for a second run.
.PARAMETER ThrottleDelayMilliseconds
    Pause between pages. Set to 0 to disable pacing.
.PARAMETER MaxRetryCount
    Attempts per page when a query fails with a transient error.
.PARAMETER RetryDelaySeconds
    Initial backoff before the first retry. Doubles per attempt with full jitter. Set to 0 to
    retry without waiting.
.PARAMETER GridViewRowLimit
    Maximum rows handed to Out-GridView. The grid materialises every row in-process, so a very
    large queue is truncated for display only, with a warning. Files are never truncated.
.PARAMETER Force
    Answer every prompt automatically: connect to Exchange Online, accept the -AgeDays warning,
    and decline opening the CSV. Required for unattended and scheduled runs.
.PARAMETER PassThru
    Emit the result object to the pipeline.
.PARAMETER Quiet
    Suppress the progress and summary output. Warnings and errors are still written. GridView is
    skipped under -Quiet, with a warning saying so: an unattended run has no one to look at it.
    Use -Output CSV or -PassThru to get at the results.
.EXAMPLE
    Get-ExoQueue

    Queues the last 30 minutes and shows the result in a GridView.
.EXAMPLE
    Get-ExoQueue -AgeHours 4 -Output CSV,GridView -TopSenders 10 -TopRecipients 10

    Queues the last 4 hours, shows the grid, and writes CSV files for the results and both Top-N
    breakdowns.
.EXAMPLE
    Get-ExoQueue -AgeMinutes 15 -JournalExclude -Output CSV

    Queues the last 15 minutes with journal traffic removed, so a journaling backlog does not mask
    the rest of the queue.
.EXAMPLE
    $queue = Get-ExoQueue -AgeMinutes 30 -Force -Quiet -Output None -PassThru
    $queue.Messages | Where-Object RecipientCount -gt 50

    Unattended run that emits the result object instead of printing, then finds the fan-out
    messages inside it.
.NOTES
    File Name      : Get-ExoQueue.ps1
    Author         : cuhaafke
    Compatibility  : Windows PowerShell 5.1, ExchangeOnlineManagement 3.7.0 or later

    Time zones: Get-MessageTraceV2 documents its output timestamps as UTC, while StartDate and
    EndDate are documented as the machine's regional short date format. Paging feeds an output
    timestamp back in as EndDate, so the two have to be reconciled explicitly. -TimeBasis Local is
    the default, and that is now a measurement rather than a guess: against a live tenant
    (a live lab tenant, 14 Sep 2026) an anchor message returned at 03:13:07Z was findable only by
    querying 22:11:07..22:15:07 - the request window had to be shifted by the machine's UTC offset,
    which is exactly what "the parameters are read in local time" looks like. It also matches the
    documentation. The default was Utc until 1.5.3, and was wrong. Re-measured independently on
    15 Sep 2026 against a different anchor (05:23:21Z, found at 00:21:21..00:25:21): same verdict.

    The consequence of expressing a request in local time is that one hour a year repeats. That
    turns out NOT to be a problem on the wire: the service is offset-aware, and a cursor built by
    ToLocalTime() carries the correct per-instant offset, so the two readings of the repeated hour
    are distinguishable. The cursor monotonicity checks compare instants rather than wall clocks for
    the same reason - see 1.6.3. Only a bare date typed by the caller is genuinely ambiguous, and
    that warns.

    The paging loop refuses to let EndDate move forward regardless, so a wrong basis costs
    completeness (which is reported as CursorAdvanced) rather than terminating the loop. If a tenant
    ever disagrees, Test-ExoQueueTenantAssumption.ps1 answers the question in seven read-only
    queries and names the setting to use.

    Result types: elements of $result.Messages are built fresh as pscustomobject rather than copied
    from the trace rows, because copying a typed .NET object shares its member set and stamped the
    grouped properties back onto the caller's rows. Elements of $result.RecipientRows are the trace
    rows themselves, untouched. The visible consequence is that -Output XML followed by
    Import-Clixml reports the messages as Deserialized.System.Management.Automation.PSCustomObject
    instead of the trace type name; every property, including the added RecipientCount, Recipients
    and ReceivedUtc, reads exactly as before.

    Page size: EffectivePageSize on the result is the largest page the service actually returned.
    ResultSizeCapped says the service is honouring something smaller than the requested -ResultSize,
    and it is only ever set when that has been demonstrated: a page came back short, no page in the
    run had reached -ResultSize exactly, and one more query then returned rows the run had NOT
    already seen - proving the short page was not the end. Rows alone are not enough, because a
    service that replays part of the previous page returns plenty of them and no new information. A
    run that ever returned a full page never sets it, and never spends the extra query either. On a
    first run in a new tenant this answers "is my role capped below what I asked for", which is
    otherwise invisible, because a capped run looks complete.

    The probe has one blind spot, and it is narrow. A page below ExoQueueCapProbeThreshold (100) is
    trusted as the end of the data without a probe, so a role capped below 100 rows would still
    report the cap as the queue depth. Trusting small pages is what keeps a quiet queue at one
    query; the threshold is where that trade sits, and nothing Exchange Online is known to do caps
    below it. It was 1000 until 1.5.2, which left every cap under the documented default - 100, 250,
    500 - invisible, reported as a complete queue. If a run's EffectivePageSize is a suspiciously
    round number well under -ResultSize, that is still the tell.

    Ordering: messages come back oldest first, and messages sharing one received timestamp keep the
    order the service returned them in. Sort-Object is not a stable sort on Windows PowerShell 5.1
    and has no -Stable switch, so the sort key packs the arrival index into the tick count instead.
    Messages with no readable received time are appended last rather than sorted, and counted in a
    warning; that warning naming every message in the run means the received property was not
    recognised at all and the ordering is not real.

    Truncated: set only when the run stopped for a reason that leaves data behind - MaxQueryPages,
    QueryFailed, NoNewRows, CursorStalled, CursorUnavailable, CursorAdvanced. A run that pages until
    the service returns a short page has exhausted the queue and is not truncated, including when
    that happens on the last page -MaxQueryPages permits.

    Version history
    3/8/24   | 1.0  -  Initial release - pending feedback and some features
    3/12/24  | 1.1  -  Finished CSV Output
                       Modifications to Gridview. To include, increased the output to include all properties, and removed terminal output by removing -Passthru
                       Removed Journal results from default search
                       Made more efficient by combining searches using commas for the StatusTypes and removing an redundant search set.
                       Prevented user from combining the Age parameters
                       Minor updates to formatting and comments.
    3/13/24  | 1.1.1 - Added cmdlet binding
    4/1/24   | 1.1.4 - Added Parameters Used to Log output to help understand why numbers may jump around while troubleshooting. Ex: Parameters Used: AgeMinutes=30, JournalOnly=False, Output=GridView
                       Changed the smarsh param to JournalOnly
    4/4/24   | 1.1.5 - Adding Registry logic for JournalOnly
                       Removing plan to implement the following params due to search filter options in output
                         - #[switch]$RecipientDomain
                         - #[switch]$ToIP
    4/24/24  | 1.2   - Completed implementation of JournalOnly and JournalExclude
                        Added JournalExclude parameter
                        Added logic to check if the JournalSmtp value already exists in the registry
                        Added logic to check if the JournalSmtp value is a valid email address
                        Corrected the JournalSmtp value to be a global variable, breaking the SenderAddress filter
             | 1.2.1 - Removed xml import prompt
     5/31/24 | 1.3   - Removed GettingStatus from search after speaking with PG - Produced too many false positives
    11/14/24 | 1.3.1 - Changed the results logic to only show unique results. This will remove the multiple recipient messages from the results.
     4/14/25 | 1.4 -   Major update:
                        - Replaced Get-MessageTrace with Get-MessageTraceV2 for improved performance and accuracy.
                        - Removed pagination logic; simplified query execution.
                        - Changed output directory from Desktop to C:\Temp\ExoQueueResults\<Date>.
                        - Added confirmation prompts for AgeDays and AgeHours to prevent timeouts in large environments.
                        - Enhanced connection handling with Yes/No prompt for Exchange Online connection.
                        - Improved logging and output handling; log files now stored in C:\Temp\ExoQueueResults\<Date>.
                        - Added auto-import of XML results into global variables for easier analysis.
                        - General code cleanup and improved error handling.
    8/14/25 | 1.4.1 - Update changelog for 1.4, cleaned up syntax, and corrected some entries for $allresults to use $uniqueresults.
    8/21/25 | 1.4.2 - Added IncludeDelivered parameter to allow testing/demos without having to modify the Delivery Status. Cirrected a few more issues with $allresults to use $uniqueresults.
    6/17/26 | 1.4.3 - Updated Get-MessageTraceV2 query handling for current ResultSize and cursor behavior.
                         Added ResultSize and MaxQueryPages controls.
                         Fixed saved JournalSmtp reuse, no-result handling, and grouped Top Senders/Recipients exports.
    7/29/26 | 1.5.0 - BEHAVIOR CHANGE: -JournalOnly and -JournalExclude now filter on the RECIPIENT
                       address, not the sender. Journal mail is addressed TO the journal address, so
                       since 1.2 -JournalOnly has matched only mail the journal mailbox itself sent
                       (in practice, almost nothing) and -JournalExclude has excluded almost nothing.
                       Expect counts to move. Get-ExoQueue.Baseline.Tests.ps1 demonstrates the old
                       behavior against the 1.4.2 file, which is retained for comparison.
                      Fixed the paging cursor mixing two clocks: page 1 used a local EndDate while
                       page 2 onwards used the UTC Received value, so west of UTC the window moved
                       forward by the offset instead of backward. Added -TimeBasis, a single
                       conversion point, and a guard that refuses to let EndDate advance.
                      Fixed Top Recipients counting from the MessageId-deduplicated set, which
                       counted a message queued to 200 recipients as one recipient.
                      Fixed multi-recipient messages losing every recipient but one on export.
                       Added RecipientCount and Recipients; results now sort oldest first.
                      Fixed a failed page discarding every page already retrieved. Partial results
                       are kept and flagged with Truncated and TruncationReason.
                      Fixed truncated runs being written to the log as though they were complete.
                      Fixed empty queues writing no log entry, which erased the single most useful
                       point in a queue trend.
                      Fixed Excel launch throwing when Excel is not found, and broadened detection
                       beyond the hardcoded Office16 path.
                      Fixed CSV and log files being written as ASCII/ANSI, which mangled non-ASCII
                       addresses and subjects. Both are UTF-8 now.
                      Fixed output paths using a culture-sensitive date format, which produced a
                       Hijri date under ar-SA.
                      Added throttle pacing, retry with backoff, and a request budget against the
                       documented 100-requests-per-5-minutes limit. -MaxQueryPages now defaults
                       to 20 rather than 95.
                      Added -Force, -PassThru, -Quiet, -Status, -StartDate/-EndDate, -OutputPath,
                       -JournalSmtp, -TimeBasis. -Output now accepts more than one format.
                      Added a connection check that uses Get-ConnectionInformation and verifies the
                       ExchangeOnlineManagement version actually provides Get-MessageTraceV2.
                      Removed the $global: function definition and the four $global: result
                       variables; use -PassThru.
                      Renamed the file to Get-ExoQueue.ps1 so the name cannot drift from the version
                       again, and added Get-ExoQueue.Tests.ps1.
    8/13/26 | 1.5.1 - Made the post-query work usable at incident scale. Measured over 100,000
                       recipient rows resolving to 53,769 messages, both versions in one process
                       over identical data: total 202,914 ms to 22,444 ms (9.0x). Grouping
                       158,917 to 17,495 ms, Top Senders 16,043 to 435 ms, Top Recipients 24,928
                       to 1,264 ms. Formula-risk scanning was 3,026 to 3,250 ms - a wash, kept
                       because it no longer starts a regex engine per value. Message count,
                       ordering, RecipientCount, Recipients, ReceivedUtc and the full property
                       set are identical between the two.
                      Fixed grouping stamping RecipientCount, Recipients and ReceivedUtc onto the
                       caller's own rows. PSObject.Copy() does not isolate a typed .NET object, so
                       adding a member to the copy landed on the source - which is what
                       -PassThru and Top Recipients then read. Messages are now built fresh, so
                       $result.Messages elements are pscustomobject: -Output XML then
                       Import-Clixml reports Deserialized.System.Management.Automation.PSCustomObject
                       rather than the trace type name. Property access is unchanged.
                      Fixed retries not being charged to the request budget. Pacing ran once per
                       page, outside the retry, so a page that failed three times cost four
                       requests and recorded one - enough for a 20-page run to spend 60 requests
                       against the documented 100-per-5-minutes limit believing it spent 20.
                      Fixed a server-side ResultSize cap ending the run at page 1 and reporting
                       the cap as the queue depth. A short page is now trusted only when the run
                       has already seen a page at exactly -ResultSize, or when it is too small for
                       any documented cap to explain; otherwise one more query settles it. Added
                       EffectivePageSize and ResultSizeCapped to the result and to the log line, so
                       a capped run stays identifiable afterwards. ResultSizeCapped is set only
                       once the probe has actually returned further data - suspicion alone does not
                       set it, and a run that ever filled a page cannot set it at all.
                      Fixed the paging cursor stopping on a timestamp it could still page through.
                       A burst of messages sharing one instant is exactly what
                       StartingRecipientAddress exists for; refusing equality dropped 15 of 20
                       retrievable rows. The stop condition is now that neither half of the cursor
                       moved, and a cursor that moves FORWARD stops separately as CursorAdvanced
                       with the -TimeBasis diagnosis.
                      Fixed the output folder and file stamp being read after the query, which
                       filed a run beginning at 23:58 under the following day and stamped the log
                       with a time outside the run's own window.
                      Fixed post-query warnings - grid truncation, formula risk, a missing Excel -
                       reaching the console only. $result.Warnings now carries them.
                      Fixed -Output None binding happily alongside a real format and then writing
                       the file. It is rejected.
                      Fixed -WhatIf creating the dated folder and appending a row to the trend log.
                       Every export was guarded and those two were not, so the one file that is
                       accumulated rather than replaced was being permanently added to by a run
                       that promised to write nothing.
                      Fixed "CSV file with All Results saved to" and the XML equivalent printing a
                       path for a file that had just been declined, under -WhatIf or an answered-no
                       -Confirm. Both now sit inside the guard, where the Top-N lines already were.
                      Fixed -Quiet without -Force stopping on an invisible prompt. The connect and
                       -AgeDays questions are printed through Write-Ui, which -Quiet suppresses, so
                       an unattended run stopped at a bare colon with nothing on screen. Those two
                       now throw, naming the question and both ways past it. The optional "open in
                       Excel" prompt is skipped instead of refused, because stopping a finished run
                       over it would throw the work away.
                      Fixed two runs in the same minute overwriting each other's exports. The file
                       stamp has minute resolution, and re-running immediately with a narrower
                       window is a normal triage move, which made the file most likely to be
                       destroyed the one taken seconds earlier. Names now fall back to
                       "ExoQueue - <stamp> (2).csv", and the suffix is resolved once for the whole
                       file set so the results and both Top-N breakdowns from one run always share
                       a name. The trend log is still appended, by design.
                      Fixed one unreadable row disabling timestamps for a whole run. The received
                       property name was resolved from the first row alone, so a single bad value
                       emptied ReceivedUtc everywhere and quietly turned the oldest-first ordering
                       into arrival order. Up to 25 rows are sampled, and any message left without a
                       received time is reported rather than assumed.
                      Fixed messages with no received time sorting to the TOP of an oldest-first
                       list, where they read as the most stuck mail in the tenant. Sort-Object puts
                       nulls first; they are now held out and appended, and counted in a warning.
                      Fixed a complete run being reported INCOMPLETE when it finished on its last
                       permitted page. Reaching -MaxQueryPages and ending ON it produce the same
                       page number, and only the number was tested, so -MaxQueryPages 1 mislabelled
                       every run - to the console, to $result.Truncated, and permanently into the
                       trend log, which is the one artefact nobody goes back and corrects. The exit
                       reason is now recorded, not inferred.
                      Fixed a cap probe treating replayed rows as evidence of a cap. The probe read
                       the raw page count before deduplication, so a service returning part of the
                       previous page again set ResultSizeCapped and warned that the role was capped.
                       It now counts only rows the run had not already seen.
                      Fixed oldest-first ordering scrambling messages that share a timestamp.
                       Sort-Object is not a stable sort on 5.1 and has no -Stable; fed 40 messages
                       sharing one instant it returned them 27,26,28,30,29,22,21,... - and a burst
                       inside one second is exactly the shape the paging cursor was fixed for.
                       Ties now keep the order the service returned them in, via a sort key that
                       packs the arrival index into the tick count. Faster than what it replaces on
                       that shape - 1,604 ms per 85,715 messages against 1,957 ms - and at parity
                       when every timestamp is distinct.
                      Fixed -Quiet opening a GridView. -Output defaults to GridView and -Quiet is
                       what an unattended run passes, so the combination the help points a scheduled
                       task at put a window on a desktop nobody was watching - and suppressed the
                       one line that said where it came from. The grid is skipped under -Quiet and
                       a warning says so, because warnings survive -Quiet.
                      Fixed $result.LogPath naming a file that was never written when -WhatIf or an
                       answered-no -Confirm declined the trend-log append, or when the append failed.
                       It is null in those cases, as OutputFiles already was.
                      Fixed the "open in Excel" prompt offering to open the All Results CSV when
                       that export specifically had been declined under -Confirm while a Top-N
                       export was accepted.
                      Added a hint when the file is run instead of dot-sourced. 1.4.2 declared its
                       function at global scope, so "& .\Get-ExoQueue.ps1" worked; here that same
                       habit was a silent no-op.
    9/14/26 | 1.5.2 - Fixed the ResultSize cap probe missing every cap below the documented default,
                       which is the same silent under-report 1.5.1 introduced the probe to end. A
                       short page was trusted without a probe whenever it held fewer than 1000 rows,
                       so a role capped at 100, 250 or 500 returned one short page on the first
                       query, was read as an exhausted queue, and had its cap written to the console
                       and permanently into the trend log as the queue depth with Truncated=False
                       and ResultSizeCapped=False. Against a simulated service capping at 10 while
                       5000 was requested, the run reported 10 of 35 messages and called itself
                       complete - the 1.4.x failure mode surviving inside its own fix.
                       ExoQueueCapProbeThreshold is now 100. The cost is one extra query on a run
                       whose queue lands between the threshold and -ResultSize; a quiet queue still
                       costs one query, and a real backlog fills a page and never probes at all.
                       Test-ExoQueueTenantAssumption.ps1 already treated 100, 250 and 500 as the
                       round numbers a configured limit looks like, so the tool that asks whether a
                       role is capped and the tool that has to cope with one now agree.
                      Paging was verified end to end against a simulated Get-MessageTraceV2 built to
                       the documented cursor contract, under both readings of the
                       StartingRecipientAddress resume rule (the cursor row returned again, and not).
                       Single-recipient, multi-recipient fan-out, bursts sharing one timestamp, and
                       50 messages on a single instant all retrieve the corpus exactly, in order,
                       with no losses and no duplicates. See _probe-exoqueue3.ps1.
    9/14/26 | 1.5.3 - BEHAVIOR CHANGE: -TimeBasis now defaults to Local, not Utc. This was the one
                       default the offline work could not settle, and it was wrong. Measured against
                       a live lab tenant: an anchor message returned at
                       2026-09-12T03:13:07.178Z was findable only by querying 22:11:07..22:15:07 -
                       the request window had to be shifted by the machine's UTC offset to reach it,
                       which is what "the service reads its parameters in local time" looks like.
                       Querying the window as returned found nothing. It also matches the
                       documentation, which describes output as UTC and the input parameters as the
                       machine's regional format.
                      With Utc, every page after the first queried the wrong window - the 1.4.3
                       defect this parameter was introduced to prevent, reintroduced by guessing its
                       default. The guard that refuses a forward-moving EndDate limited it to lost
                       completeness rather than a wrong answer, and would have reported it as
                       CursorAdvanced on a queue deep enough to page.
                      Verified in the same tenant run: the received property IS named 'Received';
                       -RecipientAddress and -StartingRecipientAddress DO compose, so journal-
                       filtered runs page correctly; and paging against the real service returned
                       identical totals at -ResultSize 1 and 5000, over three pages, with no
                       duplicates and no losses.
    9/15/26 | 1.6.0 - Answered the two questions on-premises triage asks before any other, and which
                       a bare count cannot answer at all.
                      Added a queued-by-destination-domain breakdown. Exchange Online exposes no
                       queue object, so there is no NextHopDomain to read; the recipient domain is
                       the closest available proxy, and when one destination defers it is what rises
                       to the top of the list. Counted over recipient deliveries, carrying the oldest
                       delivery per domain. Shown on every run - it is what an incident opens with
                       and nobody thinks to ask for it by parameter. -TopDestinations sets the depth.
                      Added queue age: oldest, median and newest, on the result as QueueAge and on
                       the console under the count. A hundred thousand messages thirty seconds old is
                       a burst; the same hundred thousand six hours old is an outage. The count is
                       identical in both cases, which is why reporting it alone was never enough.
                       Messages with no readable received time are counted separately rather than
                       skipped, because a run with many of those has no working ordering either.
                      Measured the cost of all of this at incident scale rather than assuming it:
                       Measure-ExoQueueScaleCost.ps1 reports 22 s and 1.45 GB of managed heap for
                       100,000 recipient rows, scaling linearly from 1.9 s and 157 MB at 10,000.
                       The binding constraints at that size turn out to be arithmetic rather than
                       performance - -ResultSize 5000 x -MaxQueryPages 20 is exactly 100,000 rows,
                       and a role capped at the documented 1000 default retrieves a fifth of that
                       before the page ceiling stops it. Both are in the project plan.
    9/15/26 | 1.6.1 - Stopped asking the operator for something the tenant already knows. Since 1.1.5
                       the journal address has come from a prompt and a saved HKCU value, so the
                       first -JournalExclude on any new machine stopped an unattended run dead, and
                       -Force turned that into a hard failure. Get-JournalRule is available in
                       Exchange Online and carries the address in JournalEmailAddress; it is now read
                       from the connected session, with the prompt and the saved value kept as
                       fallbacks for roles that cannot see journal rules. Disabled rules are skipped -
                       filtering on a rule that is journaling nothing removes nothing while looking
                       like it worked, and the disabled state is read through its string form because
                       'False' as text is truthy in PowerShell and a [bool]-only test would have read
                       exactly the rule it was meant to skip as enabled. Every enabled rule is
                       collected, because a tenant may journal to more than one destination and the
                       old single-value store could only ever hold one of them. -JournalSmtp still
                       wins over discovery, and -SkipJournalDiscovery turns it off.
                      Fixed journal resolution running BEFORE the connection check, which is what
                       made discovery impossible rather than merely absent: the one question the
                       tenant could answer was asked while there was no session to ask.
                      Fixed the saved address being stored tenant-blind. One registry value served
                       every tenant, so an operator moving between organizations silently filtered
                       one tenant's queue on another tenant's journal address and got a plausible,
                       wrong number. The value is now written per organization; a pre-1.6.1 unscoped
                       value is still honoured, with a warning naming the tenant it is being applied
                       to.
                      Fixed -JournalExclude reporting only what survived. Message trace has no
                       "everything except this recipient" filter, so exclusion happens after
                       retrieval - the page budget is spent on rows that are then discarded. A run
                       that threw away 90% of what it fetched printed the remaining 10% as though
                       that were the whole cost. JournalExcluded is now on the result and in the
                       trend log. When such a run is ALSO truncated and half or more of what it
                       retrieved was journal mail, it says so: the printed count is not a floor for
                       the non-journal queue, because the pages spent on journal traffic could have
                       held anything.
    9/15/26 | 1.6.2 - Fixed a silent under-report during the daylight-saving fall-back hour, found
                       while re-confirming -TimeBasis against the CDX tenant. Because the service
                       reads StartDate and EndDate in LOCAL time (measured, 1.5.3), and because the
                       paging cursor is an output timestamp fed back in as EndDate, the one hour a
                       year that occurs twice cannot be expressed: 01:30 Central on 1 Nov 2026 is
                       both 06:30Z and 07:30Z, and a DateTime carrying no offset cannot say which.
                       A cursor in the second pass serialises to a wall clock the service may resolve
                       to the first, and the hour between them is skipped.
                      Measured against a corpus of 150 messages spanning the repeat: the run returned
                       91 and reported Truncated=False - a silent loss of 59 messages presented as a
                       complete answer, which is the exact failure class this script exists to
                       eliminate, reappearing through the clock rather than through paging.
                      The information is genuinely not expressible in the parameter's own units, so
                       there is no in-band fix. The run now stops on CursorAmbiguous and says why,
                       turning a wrong number into an honest floor. A requested window that merely
                       ENDS inside the repeated hour is a lesser case - one query, resolved one way
                       or the other, so the run stays internally consistent - and warns instead of
                       stopping. Both name the two ways past it, and both were verified: a window
                       avoiding the hour retrieves its corpus completely over multiple pages.
                      Costs nothing outside that hour. The check is TimeZoneInfo.IsAmbiguousTime,
                       which is false for every instant in a zone without daylight saving, including
                       a machine set to UTC - which is also the standing recommendation for anything
                       scheduled.
                      Also verified in the same pass that the conversion tracks DST properly rather
                       than capturing a fixed offset: ToLocalTime applies the zone's rules per
                       instant, measured across the Oct/Nov and Mar transitions, with every instant
                       round-tripping exactly.
    9/15/26 | 1.6.3 - CORRECTS 1.6.2, which fixed the wrong thing. Get-MessageTraceV2 is
                       OFFSET-AWARE - measured against a live tenant by bracketing a known message
                       four ways: Kind=Utc found it, Kind=Local found it, Kind=Unspecified holding
                       local digits found it, and only Kind=Unspecified holding UTC digits missed.
                       The service reads the offset when there is one, and treats a bare value as
                       local. The script always sends an offset (-TimeBasis Utc emits
                       "...T05:23:21.1050000Z", Local emits "...T00:23:21.1050000-05:00").
                      So the repeated hour is not ambiguous on the wire after all. .NET keeps the
                       daylight side of an ambiguous local time in a hidden flag when the value came
                       from ToLocalTime(), which is exactly how the cursor is built, so 06:30Z and
                       07:30Z serialise as "01:30:00-05:00" and "01:30:00-06:00" - identical ticks,
                       different offsets, each round-tripping to the instant it came from.
                       CursorAmbiguous was a false positive that would have truncated healthy runs
                       for an hour every year, and it is removed. The 91-of-150 measurement behind
                       it came from a test double that discarded the offset: the stub was wrong, not
                       the script.
                      What WAS broken, and is fixed here, is the script's own cursor monotonicity
                       guard. It compared request-clock values, and DateTime comparison is on ticks
                       alone, so paging correctly backwards from 07:02Z to 06:43Z read as 01:02 to
                       01:43 and looked like a jump forward. A run spanning the repeat stopped at 77
                       of 150 as CursorAdvanced and advised switching -TimeBasis, which would not
                       have helped. The advance and stall checks now compare INSTANTS. The same
                       corpus now returns 150 of 150, untruncated, with no warnings. This defect
                       predates 1.6.2 - it has been present since -TimeBasis was introduced in 1.5.0.
                      Test-ExoQueueAmbiguousRequestTime is kept but retargeted to the one genuinely
                       lossy case: a bare caller-supplied -StartDate/-EndDate inside the repeated
                       hour, which carries no offset and cannot say which instant was meant. That
                       warns, and does not stop, because a reading has to be chosen and .NET's
                       (standard time) is as defensible as any.
                      Consequence for -TimeBasis: both settings send an unambiguous value and both
                       were verified live to page identically (3 messages at ResultSize 1 and 5000,
                       under both bases). The 1.5.3 switch of the default from Utc to Local was
                       driven by Test-ExoQueueTenantAssumption.ps1, which probes with
                       Kind=Unspecified - a shape Get-ExoQueue never sends. Local remains the
                       default because it is what the documentation describes and what the gate
                       measures, but Utc is not broken and never was.
    9/15/26 | 1.6.4 - Fixed the paging cursor silently losing rows against the real service, found
                       the moment there was real multi-page traffic to page through. The same
                       78-delivery corpus returned 53, 71 and 78 deliveries at -ResultSize 5, 25 and
                       5000 - three answers for one unchanging corpus - and every run reported
                       Truncated=False. Same failure class as the 1.4.x defect this project began
                       with: an under-report presented as complete, invisible from inside the script
                       because no exit condition fires and nothing is retrieved twice.
                      ROOT CAUSE, measured directly rather than inferred. Get-MessageTraceV2 honours
                       EndDate only to WHOLE-SECOND precision. Against a timestamp T of
                       18:51:09.4450000Z carrying three rows: EndDate = T returned 0 rows at T,
                       EndDate = T plus one tick returned 0, and EndDate = T plus one SECOND returned
                       all three. The service floors EndDate and compares Received against that.
                      So seeding the next page with a row's own sub-second Received asks for rows at
                       or before the start of that second, silently excluding every row inside it -
                       including ones never returned. They are unreachable, and
                       StartingRecipientAddress cannot rescue them because EndDate discards them
                       before the recipient filter is considered. That also explains why resuming
                       from a recipient at the boundary timestamp returned nothing at all. Every one
                       of the 13 timestamps among the lost rows was shared by more than one row.
                      The cursor is now rounded UP to the next whole second, so the boundary second
                       is included rather than excluded; the overlap this re-fetches is removed by
                       the deduplication that was already there. Rounding up can never move the
                       cursor forward - a row's Received is always at or before the floor of the
                       EndDate that returned it - so the monotonicity guard is unaffected.
                      Verified against the live tenant, same corpus, A/B against the old rule:
                       -ResultSize 10 went from 57 of 78 to 78 of 78, and 25 from 70 of 78 to 78 of
                       78. At -ResultSize 5 the corpus holds one second with more rows than a page,
                       which is genuinely unpageable; that now STOPS as CursorStalled and reports
                       INCOMPLETE rather than losing 36 rows in silence. Wrong-and-quiet became
                       either right, or honestly truncated.
                      Four offline tests had encoded the old contract - that the cursor equals the
                       row's Received exactly - and were updated to the measured one. Two others
                       placed their burst in the CURRENT second, a shape the service cannot return
                       at all once flooring is understood, and were moved a few seconds back.
                       Test-ExoQueuePagingLive.ps1 reproduces the whole thing against a tenant.
    9/15/26 | 1.6.5 - An empty result now says WHY it is empty. Reported from a live window: a lab
                       holding 40 Failed deliveries answered a bare Get-ExoQueue with
                       "Number of messages in the queue: 0" and nothing else. That was correct -
                       -Status defaults to Pending alone - but a bare zero reads as "nothing is
                       queued" when it often means "nothing matched the filter", and there was
                       nothing on screen to tell the two apart.
                      A zero result now names the status filter it actually used, and adds a second
                       line pointing at the Pending-only default when -Status was not supplied. The
                       second line is suppressed when the caller named the statuses explicitly,
                       because repeating a default back to someone who overrode it is noise. Both go
                       through Write-Ui, so -Quiet still silences them.
                      Worth stating plainly for lab work: nothing in a lab is ever Pending. Exchange
                       treats every unroutable smart host as a PERMANENT failure, so synthetic
                       traffic lands as Failed and a bare Get-ExoQueue will correctly report 0. Pass
                       -Status Pending,Failed.
#>
    [CmdletBinding(DefaultParameterSetName = 'AgeMinutes', SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(ParameterSetName = 'AgeMinutes')]
        [ValidateRange(1, 1440)]
        [Alias('Minutes')]
        [int]$AgeMinutes = 30,

        [Parameter(Mandatory = $true, ParameterSetName = 'AgeHours')]
        [ValidateRange(1, 240)]
        [Alias('Hours')]
        [int]$AgeHours,

        [Parameter(Mandatory = $true, ParameterSetName = 'AgeDays')]
        [ValidateRange(1, 10)]
        [Alias('Days')]
        [int]$AgeDays,

        [Parameter(Mandatory = $true, ParameterSetName = 'DateRange')]
        [ValidateNotNull()]
        [datetime]$StartDate,

        [Parameter(ParameterSetName = 'DateRange')]
        [ValidateNotNull()]
        [datetime]$EndDate,

        [Parameter()]
        [ValidateSet('Utc', 'Local')]
        [string]$TimeBasis = 'Local',

        [Parameter()]
        [switch]$JournalOnly,

        [Parameter()]
        [switch]$JournalExclude,

        [Parameter()]
        [Alias('JournalAddress')]
        [string[]]$JournalSmtp,

        [Parameter()]
        [switch]$SkipJournalDiscovery,

        [Parameter()]
        [ValidateSet('Delivered', 'Expanded', 'Failed', 'FilteredAsSpam', 'GettingStatus', 'Pending', 'Quarantined')]
        [string[]]$Status = @('Pending'),

        [Parameter()]
        [switch]$IncludeDelivered,

        [Parameter()]
        [ValidateRange(1, 25)]
        [int]$TopSenders,

        [Parameter()]
        [ValidateRange(1, 25)]
        [int]$TopRecipients,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$TopDestinations = 10,

        [Parameter()]
        [ValidateSet('CSV', 'XML', 'GridView', 'None')]
        [string[]]$Output,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Alias('OutputDirectory')]
        [string]$OutputPath = (Join-Path -Path $env:SystemDrive -ChildPath 'temp\ExoQueueResults'),

        [Parameter()]
        [ValidateRange(1, 5000)]
        [int]$ResultSize = 5000,

        [Parameter()]
        [ValidateRange(1, 500)]
        [int]$MaxQueryPages = 20,

        [Parameter()]
        [ValidateRange(0, 60000)]
        [int]$ThrottleDelayMilliseconds = 3000,

        [Parameter()]
        [ValidateRange(1, 11)]
        [int]$MaxRetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 2,

        [Parameter()]
        [ValidateRange(1, 500000)]
        [int]$GridViewRowLimit = 20000,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$PassThru,

        [Parameter()]
        [switch]$Quiet
    )

    begin {
        # Scoped to the function so dot-sourcing this file does not leave the caller in StrictMode.
        Set-StrictMode -Version 3.0

        function Write-Ui {
            param([string]$Message = '', [string]$ForegroundColor, [switch]$NoNewline)
            if ($Quiet) { return }
            $splat = @{ Object = $Message }
            if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $splat.ForegroundColor = $ForegroundColor }
            if ($NoNewline) { $splat.NoNewline = $true }
            Write-Host @splat
        }

        function Confirm-Ui {
            # Preprinted means the caller already wrote the question through Write-Ui, so Read-Host
            # is left bare and the line keeps its colour. It also means -Quiet has hidden the
            # question - see below.
            param([string]$Prompt, [switch]$DefaultYes, [switch]$Preprinted)
            if ($Force) { return $true }

            # -Quiet suppresses Write-Ui, so a preprinted question is invisible and Read-Host would
            # stop an unattended run on a bare colon with nothing on screen to say what it wants.
            # Refuse instead, naming the question and both ways past it. Prompts that print
            # themselves are still answerable, so they are left alone.
            if ($Quiet -and $Preprinted) {
                throw "This run needs an answer to a question -Quiet cannot show: $Prompt Re-run with -Force to answer yes, or without -Quiet to answer it yourself."
            }

            $answer = if ($Preprinted) { Read-Host } else { Read-Host $Prompt }
            if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
            return $answer -match '^\s*y(es)?\s*$'
        }
    }

    process {
        if ($JournalOnly -and $JournalExclude) {
            throw "Only one of the following parameters can be used: JournalOnly, JournalExclude."
        }

        # 'None' means "produce no files"; combining it with a format is self-contradictory, and
        # -Output None,CSV bound happily and then wrote the CSV, so whichever reading the caller
        # intended, one of them was silently wrong.
        if ($Output -contains 'None' -and $Output.Count -gt 1) {
            throw "-Output None cannot be combined with another format. Received: $($Output -join ', ')."
        }

        $effectiveStatus = $Status
        if ($IncludeDelivered) {
            if ($PSBoundParameters.ContainsKey('Status')) {
                Write-Warning "-IncludeDelivered was ignored because -Status was supplied explicitly."
            }
            else {
                $effectiveStatus = @('Pending', 'Delivered')
            }
        }

        if (-not $PSBoundParameters.ContainsKey('Output')) {
            Write-Ui "NOTE: " -ForegroundColor Cyan -NoNewline
            Write-Ui "-Output parameter using default: 'GridView' - CSV and XML are also available."
            Write-Ui ""
            $Output = @('GridView')
        }

        if ($PSCmdlet.ParameterSetName -eq 'AgeMinutes' -and -not $PSBoundParameters.ContainsKey('AgeMinutes')) {
            Write-Ui "NOTE: " -ForegroundColor Cyan -NoNewline
            Write-Ui "-AgeMinutes or -AgeHours not set. Defaulting to 30 minutes."
        }

        $journalAddresses = @()

        $connection = Test-ExoQueueConnection
        if (-not $connection.Connected) {
            Write-Verbose "Connection check: $($connection.Reason)"

            if ($Force) {
                throw "Not connected to Exchange Online ($($connection.Reason)). Connect with Connect-ExchangeOnline before using -Force."
            }

            Write-Ui "You are not connected to Exchange Online. Do you want to connect now? (Y/N) - Default is Yes." -ForegroundColor Yellow
            if (-not (Confirm-Ui -Prompt 'You are not connected to Exchange Online. Do you want to connect now?' -DefaultYes -Preprinted)) {
                Write-Ui "Search cancelled.."
                return
            }

            Write-Ui "Connecting to Exchange Online.." -ForegroundColor Yellow
            Write-Ui "If the cmdlet stalls, there may be a MFA prompt in the background."
            try {
                Connect-ExchangeOnline -ShowProgress $false -ErrorAction Stop
            }
            catch {
                throw "Unable to connect to Exchange Online: $($_.Exception.Message)"
            }

            $connection = Test-ExoQueueConnection
            if (-not $connection.Connected) {
                throw "Unable to query Exchange Online: $($connection.Reason)"
            }
        }

        Write-Ui "DISCLAIMER: " -ForegroundColor Yellow -NoNewline
        Write-Ui "THIS IS AN APPROXIMATION OF THE QUEUE USING MESSAGE TRACE DATA. IT IS NOT AN EXACT REPRESENTATION OF THE QUEUE."
        Write-Ui ""

        # Resolved AFTER the connection, not before it. Discovery reads the tenant's own journal
        # rules and the saved value is scoped per tenant, and neither is possible without knowing
        # which tenant this is.
        if ($JournalOnly -or $JournalExclude) {
            $journalAddresses = @(Resolve-ExoQueueJournalSmtp -JournalSmtp $JournalSmtp `
                -Organization ([string]$connection.Organization) `
                -SkipDiscovery:$SkipJournalDiscovery -Force:$Force -Quiet:$Quiet)

            if ($JournalOnly) {
                # -JournalOnly is a server-side RecipientAddress filter and Get-MessageTraceV2 does
                # not accept wildcards there. Failing here beats silently returning nothing.
                $patterns = @($journalAddresses | Where-Object { $_ -match '[\*\?]' })
                if ($patterns.Count -gt 0) {
                    throw ("-JournalOnly cannot use a wildcard address ({0}) because the filter is applied by the service. Use an exact address, or use -JournalExclude, which filters locally." -f ($patterns -join ', '))
                }
            }
        }

        if ($PSCmdlet.ParameterSetName -eq 'AgeDays') {
            Write-Warning "Using the -AgeDays parameter WILL timeout in large environments and should only be used in a low-volume, or test environments. Try using -AgeMinutes instead."
            Write-Ui "Are you sure you want to continue? (Y/N) - Default is No." -ForegroundColor Yellow
            if (-not (Confirm-Ui -Prompt '-AgeDays will time out in a large tenant. Are you sure you want to continue?' -Preprinted)) {
                Write-Ui "Search cancelled.."
                return
            }
        }

        $runStartUtc = [datetime]::UtcNow

        # One reading of the clock for every path and file name in this run, taken from the run
        # start rather than from whenever the query happened to finish. Reading it afterwards filed
        # a run that began at 23:58 and paged for four minutes under the following day's folder,
        # and stamped the log with a time outside the run's own window.
        $stamp     = $runStartUtc.ToLocalTime()
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture

        # A bare date such as "2026-11-01 01:30" carries no offset, and on the one night a year the
        # clocks go back that wall clock happens twice. Everything this script computes for itself
        # carries an offset and is therefore unambiguous; only what the caller typed can be
        # ambiguous. One reading has to be chosen - .NET picks standard time - so this is said out
        # loud rather than guessed at silently. Held here and folded into $runWarnings below, which
        # does not exist until the trace returns.
        $ambiguousInputWarnings = [System.Collections.Generic.List[string]]::new()
        foreach ($supplied in @(
            @{ Name = 'StartDate'; Value = $StartDate }
            @{ Name = 'EndDate';   Value = $EndDate }
        )) {
            if (-not $PSBoundParameters.ContainsKey($supplied.Name)) { continue }
            if (Test-ExoQueueAmbiguousRequestTime -RequestTime $supplied.Value) {
                $ambiguousWarning = ("-{0} '{1:yyyy-MM-dd HH:mm:ss}' is a local time that occurs twice, because the clocks go back that night. It carries no offset, so it has been read as standard time. Pass a value with an offset, or in UTC, to say which you meant." -f `
                    $supplied.Name, $supplied.Value)
                $ambiguousInputWarnings.Add($ambiguousWarning)
                Write-Warning $ambiguousWarning
            }
        }

        $window = Resolve-ExoQueueWindow -NowUtc $runStartUtc `
            -AgeMinutes $(if ($PSCmdlet.ParameterSetName -eq 'AgeMinutes') { $AgeMinutes } else { 0 }) `
            -AgeHours   $(if ($PSCmdlet.ParameterSetName -eq 'AgeHours')   { $AgeHours }   else { 0 }) `
            -AgeDays    $(if ($PSCmdlet.ParameterSetName -eq 'AgeDays')    { $AgeDays }    else { 0 }) `
            -StartDate  $(if ($PSCmdlet.ParameterSetName -eq 'DateRange')  { $StartDate }  else { $null }) `
            -EndDate    $(if ($PSCmdlet.ParameterSetName -eq 'DateRange' -and $PSBoundParameters.ContainsKey('EndDate')) { $EndDate } else { $null })

        switch ($PSCmdlet.ParameterSetName) {
            'AgeDays' {
                $unit = if ($AgeDays -eq 1) { 'day' } else { 'days' }
                Write-Ui "Getting the message queue for the past $AgeDays $unit. Please wait.." -ForegroundColor Cyan
            }
            'AgeHours' {
                $unit = if ($AgeHours -eq 1) { 'hour' } else { 'hours' }
                $tail = if ($AgeHours -eq 1) { '' } else { ' If the queue is large and there is a timeout, attempt to reduce the -AgeHours setting.' }
                Write-Ui "Getting the message queue for the past $AgeHours $unit.$tail Please wait.." -ForegroundColor Cyan
            }
            'AgeMinutes' {
                $unit = if ($AgeMinutes -eq 1) { 'minute' } else { 'minutes' }
                $tail = if ($AgeMinutes -eq 1) { '' } else { ' If the queue is large and there is a timeout, attempt to reduce the -AgeMinutes setting.' }
                Write-Ui "Getting the message queue for the past $AgeMinutes $unit.$tail Please wait.." -ForegroundColor Cyan
            }
            default {
                Write-Ui ("Getting the message queue from {0:yyyy-MM-dd HH:mm:ss}Z to {1:yyyy-MM-dd HH:mm:ss}Z. Please wait.." -f $window.StartUtc, $window.EndUtc) -ForegroundColor Cyan
            }
        }

        $progress = {
            param($Page, $Returned, $New, $Total)
            if ($Page -gt 1 -or $Returned -ge $ResultSize) {
                Write-Ui ("Retrieved {0} message trace rows on page {1} ({2} new, {3} total). Querying next page.." -f $Returned, $Page, $New, $Total) -ForegroundColor Cyan
            }
        }

        $trace = Get-ExoQueueTraceResult `
            -RequestStart (ConvertTo-ExoQueueRequestTime -Utc $window.StartUtc -Basis $TimeBasis) `
            -RequestEnd   (ConvertTo-ExoQueueRequestTime -Utc $window.EndUtc   -Basis $TimeBasis) `
            -Status $effectiveStatus `
            -ResultSize $ResultSize `
            -MaxQueryPages $MaxQueryPages `
            -TimeBasis $TimeBasis `
            -RecipientAddress $(if ($JournalOnly) { $journalAddresses } else { @() }) `
            -ThrottleDelayMilliseconds $ThrottleDelayMilliseconds `
            -MaxRetryCount $MaxRetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -ProgressAction $progress

        $recipientRows = @($trace.Rows)

        # Seeded from the trace warnings and appended to for the rest of the run. $result.Warnings
        # holds this same List by reference, so a warning raised after the object is built still
        # reaches a caller using -PassThru. Before this, everything the export and display stages
        # warned about - grid truncation, formula risk, a missing Excel - went to the console only,
        # which is exactly the audience that is not watching during an escalation.
        $runWarnings = [System.Collections.Generic.List[string]]::new()
        foreach ($inputWarning in $ambiguousInputWarnings) { $runWarnings.Add($inputWarning) }
        foreach ($traceWarning in @($trace.Warnings)) { $runWarnings.Add([string]$traceWarning) }

        $journalExcluded = 0
        if ($JournalExclude -and $journalAddresses.Count -gt 0) {
            # Applied after the page count is taken, so filtering never disturbs paging.
            $beforeExclude = $recipientRows.Count
            $recipientRows = @($recipientRows | Where-Object {
                $recipient = [string](Get-ExoQueueProperty -InputObject $_ -Name 'RecipientAddress')
                $match = $false
                foreach ($address in $journalAddresses) {
                    if ($address -match '[\*\?]') {
                        if ($recipient -like $address) { $match = $true; break }
                    }
                    elseif ($recipient -eq $address) { $match = $true; break }
                }
                -not $match
            })
            $journalExcluded = $beforeExclude - $recipientRows.Count

            # Message trace has no "everything except this recipient" filter, so exclusion can only
            # happen here - which means the page budget was spent retrieving rows that were then
            # discarded. Silent until now: a run that threw away 90% of what it fetched reported the
            # 10% as though that were the whole cost.
            if ($journalExcluded -gt 0) {
                $share = [math]::Round(100 * $journalExcluded / [double]$beforeExclude, 1)
                Write-Verbose ("Excluded {0:N0} journal deliveries ({1}% of what was retrieved)." -f $journalExcluded, $share)

                # The combination that cannot be reasoned about: the run stopped early AND most of
                # what it did retrieve was thrown away, so the non-journal depth is unknown and the
                # number about to be printed is not a floor for it either.
                if ($trace.Truncated -and $share -ge 50) {
                    $warningText = ("This run is INCOMPLETE ({0}) and {1}% of what it retrieved was journal mail that -JournalExclude then discarded. The non-journal count below is not a floor for the real one - the pages spent on journal traffic could have held anything. Use -JournalOnly to size the journal backlog separately, or narrow the window." -f `
                        $trace.TruncationReason, $share)
                    $runWarnings.Add($warningText)
                    Write-Warning $warningText
                }
            }
        }

        $messages = @(Group-ExoQueueMessage -Row $recipientRows)

        # Group-ExoQueueMessage parks messages with no readable received time at the end, contiguous,
        # so counting backwards stops at the first dated one instead of walking the whole set. Worth
        # saying out loud: it means the received property was not found, which also disables the
        # oldest-first ordering that the whole grid is read for.
        $undatedMessages = 0
        for ($i = $messages.Count - 1; $i -ge 0 -and $null -eq $messages[$i].ReceivedUtc; $i--) {
            $undatedMessages++
        }
        if ($undatedMessages -gt 0) {
            $warningText = ("{0:N0} of {1:N0} messages have no readable received time, so they are listed last rather than sorted. If that is all of them, this build does not recognise the received property name on these rows and the oldest-first ordering is not real." -f `
                $undatedMessages, $messages.Count)
            $runWarnings.Add($warningText)
            Write-Warning $warningText
        }

        $topSenderResults    = @()
        $topRecipientResults = @()
        if ($PSBoundParameters.ContainsKey('TopSenders')) {
            $topSenderResults = @(Get-ExoQueueTopN -Source $messages -Property 'SenderAddress' `
                -First $TopSenders -Population 'Messages')
        }
        if ($PSBoundParameters.ContainsKey('TopRecipients')) {
            # Recipient deliveries, not the deduplicated message set.
            $topRecipientResults = @(Get-ExoQueueTopN -Source $recipientRows -Property 'RecipientAddress' `
                -First $TopRecipients -Population 'RecipientDeliveries')
        }

        # The two questions on-premises triage asks first, and which a bare count cannot answer:
        # which destination is backing up, and how long has it been waiting. Neither is free at
        # 100,000 rows, so both are skipped when there is nothing to describe.
        $destinations = @()
        $queueAge     = $null
        if ($recipientRows.Count -gt 0) {
            $destinations = @(Get-ExoQueueDestination -Row $recipientRows -First $TopDestinations)
            $queueAge     = Get-ExoQueueAge -Message $messages -NowUtc $runStartUtc
        }

        # $stamp and $invariant are set at run start, above the query.
        $dateFolder  = $stamp.ToString('dd-MMM-yyyy', $invariant)
        $fileStamp   = $stamp.ToString('dd-MMM-yyyy--HHmm', $invariant)
        $runFolder   = Join-Path -Path $OutputPath -ChildPath $dateFolder
        $logPath     = $null

        if (-not (Test-Path -Path $runFolder)) {
            # Guarded like the exports are. Without this, -WhatIf created the date folder and then
            # reported that it would have written files into it.
            if ($PSCmdlet.ShouldProcess($runFolder, 'Create the output folder')) {
                try {
                    New-Item -Path $runFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                catch {
                    throw "Unable to create the folder $runFolder. Please ensure you have the necessary permissions. $($_.Exception.Message)"
                }
            }
        }

        $ageParam = switch ($PSCmdlet.ParameterSetName) {
            'AgeMinutes' { "AgeMinutes=$AgeMinutes" }
            'AgeHours'   { "AgeHours=$AgeHours" }
            'AgeDays'    { "AgeDays=$AgeDays" }
            default      { 'DateRange' }
        }

        $journalMode = if ($JournalOnly) { "Only($($journalAddresses -join ','))" }
                       elseif ($JournalExclude) { "Exclude($($journalAddresses -join ','),-$journalExcluded)" }
                       else { 'None' }

        # Written on every run, including the empty one. 1.4.3 returned before this point when the
        # queue was empty, so the single most useful point in a trend - the return to zero - was
        # indistinguishable from the tool never having run.
        $logPath  = Join-Path -Path $runFolder -ChildPath ("ExoQueueLog--{0}.txt" -f $dateFolder)
        $logEntry = '{0} - {1} messages in the queue ({2} recipient deliveries) | Parameters Used: {3}, Journal={4}, Status={5}, Output={6} | Window={7:yyyy-MM-ddTHH:mm:ssZ}..{8:yyyy-MM-ddTHH:mm:ssZ} Basis={9} | Pages={10}/{11} Truncated={12}{13} Duplicates={14} ResultSize={15} EffectivePageSize={16}{17} | v{18}' -f `
            $stamp.ToString('yyyy-MM-dd HH:mm:ss', $invariant),
            $messages.Count,
            $recipientRows.Count,
            $ageParam,
            $journalMode,
            ($effectiveStatus -join '+'),
            ($Output -join '+'),
            $window.StartUtc,
            $window.EndUtc,
            $TimeBasis,
            $trace.PagesQueried,
            $MaxQueryPages,
            $trace.Truncated,
            $(if ($trace.Truncated) { "($($trace.TruncationReason))" } else { '' }),
            $trace.DuplicateRows,
            $ResultSize,
            $trace.EffectivePageSize,
            $(if ($trace.ResultSizeCapped) { '(CAPPED)' } else { '' }),
            $script:ExoQueueVersion

        # The trend log is the one file that is appended rather than replaced, so -WhatIf writing it
        # was not merely a stray file - it permanently added a row to the history being trended.
        if ($PSCmdlet.ShouldProcess($logPath, 'Append the queue count to the trend log')) {
            try {
                Add-Content -Path $logPath -Value $logEntry -Encoding UTF8 -ErrorAction Stop
                Write-Ui "Log File:" -ForegroundColor Cyan
                Write-Ui "A log file with the number of messages in queue has saved/updated to: " -NoNewline
                Write-Ui "$logPath" -ForegroundColor Cyan
                Write-Ui ""
            }
            catch {
                Write-Warning "Unable to write the log entry to ${logPath}: $($_.Exception.Message)"
                # Cleared for the same reason OutputFiles only lists what was written: a caller that
                # trusts $result.LogPath and reads it gets a file-not-found instead of a log.
                $logPath = $null
            }
        }
        else {
            # -WhatIf declined the write, so there is no log file to point anyone at.
            $logPath = $null
        }

        Write-Ui "Number of messages in the queue: " -NoNewline
        Write-Ui ("{0:N0}" -f $messages.Count) -ForegroundColor Cyan -NoNewline
        Write-Ui ("  ({0:N0} recipient deliveries)" -f $recipientRows.Count)

        # A bare zero is ambiguous: it looks like "nothing is queued" when it can equally mean
        # "nothing matched the filter". -Status defaults to Pending alone, so a tenant full of Failed
        # or Delivered mail reports 0 and gives no hint why. Say what was actually asked for.
        if ($messages.Count -eq 0) {
            Write-Ui ("  Nothing matched Status={0} in this window. That is a filter result, not necessarily an empty tenant." -f ($effectiveStatus -join ', '))
            if (-not $PSBoundParameters.ContainsKey('Status') -and -not $IncludeDelivered) {
                Write-Ui "  -Status defaults to Pending only. Add -Status Pending,Failed or -IncludeDelivered to widen it."
            }
        }

        # Age before anything else. A hundred thousand messages thirty seconds old is a burst; the
        # same hundred thousand six hours old is an outage, and the count alone cannot tell them
        # apart. On-premises this is the first thing Get-Message is asked for.
        if ($null -ne $queueAge -and $queueAge.Counted -gt 0) {
            Write-Ui ("Queue age: oldest {0:N1} min, median {1:N1} min, newest {2:N1} min" -f `
                $queueAge.OldestMinutes, $queueAge.MedianMinutes, $queueAge.NewestMinutes) -ForegroundColor Cyan
            if ($queueAge.Undated -gt 0) {
                Write-Ui ("           {0:N0} message(s) had no readable received time and are not counted above." -f $queueAge.Undated)
            }
        }
        if ($trace.Truncated) {
            Write-Warning ("These results are INCOMPLETE ({0}). The count above is a floor, not the queue depth." -f $trace.TruncationReason)
        }
        Write-Ui ""

        $result = [pscustomobject]@{
            Messages             = $messages
            RecipientRows        = $recipientRows
            MessageCount         = $messages.Count
            RecipientRowCount    = $recipientRows.Count
            TopSenders           = $topSenderResults
            TopRecipients        = $topRecipientResults
            TopDestinations      = $destinations
            QueueAge             = $queueAge
            StartUtc             = $window.StartUtc
            EndUtc               = $window.EndUtc
            TimeBasis            = $TimeBasis
            Status               = $effectiveStatus
            JournalMode          = $journalMode
            JournalExcluded      = $journalExcluded
            PagesQueried         = $trace.PagesQueried
            DuplicateRows        = $trace.DuplicateRows
            Truncated            = $trace.Truncated
            TruncationReason     = $trace.TruncationReason
            EffectivePageSize    = $trace.EffectivePageSize
            ResultSizeCapped     = $trace.ResultSizeCapped
            Warnings             = $runWarnings
            LogPath              = $logPath
            OutputFiles          = @()
            Organization         = $connection.Organization
            Version              = $script:ExoQueueVersion
        }

        $displaySet = New-Object System.Management.Automation.PSPropertySet(
            'DefaultDisplayPropertySet',
            [string[]]@('MessageCount', 'RecipientRowCount', 'Truncated', 'StartUtc', 'EndUtc', 'Status'))
        $standard = New-Object System.Management.Automation.PSMemberInfo[] 1
        $standard[0] = $displaySet
        Add-Member -InputObject $result -MemberType MemberSet -Name PSStandardMembers -Value $standard -Force

        if ($messages.Count -eq 0) {
            Write-Ui "No messages found in the queue."
            if ($PassThru) { return $result }
            return
        }

        if ($topSenderResults.Count -gt 0) {
            Write-Ui ("Top {0} senders (by unique message, {1:N0} messages):" -f $TopSenders, $messages.Count) -ForegroundColor Cyan
            if (-not $Quiet) { $topSenderResults | Format-Table -AutoSize -Property Name, Count | Out-Host }
        }        if ($topRecipientResults.Count -gt 0) {
            Write-Ui ("Top {0} recipients (by recipient delivery, {1:N0} deliveries):" -f $TopRecipients, $recipientRows.Count) -ForegroundColor Cyan
            if (-not $Quiet) { $topRecipientResults | Format-Table -AutoSize -Property Name, Count | Out-Host }
        }

        # The nearest available answer to "which next hop is backing up". Always shown, because it
        # is the question an incident opens with and nobody thinks to ask for it by parameter.
        if ($destinations.Count -gt 0) {
            Write-Ui ("Queued by destination domain (top {0}):" -f $TopDestinations) -ForegroundColor Cyan
            if (-not $Quiet) { $destinations | Format-Table -AutoSize -Property Domain, Deliveries, AgeMinutes | Out-Host }
            Write-Ui "  Recipient domain, not the actual next hop - a connector can route several domains to one host."
            Write-Ui ""
        }

        $outputFiles = [System.Collections.Generic.List[string]]::new()

        # One suffix for every file this run writes, resolved from the whole set before anything is
        # written. Resolving each file on its own produced "ExoQueue - <stamp> (2).csv" next to an
        # undecorated "ExoQueue - <stamp>-TopSenders.csv" whenever the earlier run in the same minute
        # had written only some of the set, which breaks the one thing the names are for.
        $exportExtensions = @()
        if ($Output -contains 'CSV') { $exportExtensions += 'csv' }
        if ($Output -contains 'XML') { $exportExtensions += 'xml' }

        $exportCandidates = [System.Collections.Generic.List[string]]::new()
        foreach ($extension in $exportExtensions) {
            $exportCandidates.Add((Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}.{1}" -f $fileStamp, $extension)))
            if ($topSenderResults.Count -gt 0) {
                $exportCandidates.Add((Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}-TopSenders.{1}" -f $fileStamp, $extension)))
            }
            if ($topRecipientResults.Count -gt 0) {
                $exportCandidates.Add((Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}-TopRecipients.{1}" -f $fileStamp, $extension)))
            }
        }
        $exportSuffix = Get-ExoQueueUnusedSuffix -Path $exportCandidates

        if ($Output -contains 'CSV') {
            $csvPath = Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}{1}.csv" -f $fileStamp, $exportSuffix)
            # Evaluated once and remembered: calling ShouldProcess again for the message below would
            # prompt a second time under -Confirm.
            $csvWritten = $PSCmdlet.ShouldProcess($csvPath, 'Export queue results')
            if ($csvWritten) {
                $messages | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                $outputFiles.Add($csvPath)
            }

            if ($topSenderResults.Count -gt 0) {
                $tsPath = Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}-TopSenders{1}.csv" -f $fileStamp, $exportSuffix)
                if ($PSCmdlet.ShouldProcess($tsPath, 'Export top senders')) {
                    $topSenderResults | Export-Csv -Path $tsPath -NoTypeInformation -Encoding UTF8
                    $outputFiles.Add($tsPath)
                    Write-Ui "CSV file for Top Senders saved to     :  " -NoNewline
                    Write-Ui "$tsPath" -ForegroundColor Cyan
                }
            }
            if ($topRecipientResults.Count -gt 0) {
                $trPath = Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}-TopRecipients{1}.csv" -f $fileStamp, $exportSuffix)
                if ($PSCmdlet.ShouldProcess($trPath, 'Export top recipients')) {
                    $topRecipientResults | Export-Csv -Path $trPath -NoTypeInformation -Encoding UTF8
                    $outputFiles.Add($trPath)
                    Write-Ui "CSV file for Top Recipients saved to  :  " -NoNewline
                    Write-Ui "$trPath" -ForegroundColor Cyan
                }
            }
            # Inside the guard, unlike the Top-N lines it sits beside: -WhatIf used to print a path
            # and a "saved to" for a file it had just declined to write.
            if ($csvWritten) {
                Write-Ui "CSV file with All Results saved to    :  " -NoNewline
                Write-Ui "$csvPath" -ForegroundColor Cyan
            }
        }

        if ($Output -contains 'XML') {
            $xmlPath = Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}{1}.xml" -f $fileStamp, $exportSuffix)
            $xmlWritten = $PSCmdlet.ShouldProcess($xmlPath, 'Export queue results')
            if ($xmlWritten) {
                $messages | Export-Clixml -Path $xmlPath
                $outputFiles.Add($xmlPath)
            }
            if ($xmlWritten) {
                Write-Ui "XML File(s):" -ForegroundColor Cyan
                Write-Ui "XML file saved to: " -NoNewline
                Write-Ui "$xmlPath" -ForegroundColor Cyan
            }

            if ($topSenderResults.Count -gt 0) {
                # 1.4.3 built this as "$filePath-TopSenders.xml", producing ...--1432.xml-TopSenders.xml.
                $tsPath = Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}-TopSenders{1}.xml" -f $fileStamp, $exportSuffix)
                if ($PSCmdlet.ShouldProcess($tsPath, 'Export top senders')) {
                    $topSenderResults | Export-Clixml -Path $tsPath
                    $outputFiles.Add($tsPath)
                    Write-Ui "Top senders saved to: " -NoNewline
                    Write-Ui "$tsPath" -ForegroundColor Cyan
                }
            }
            if ($topRecipientResults.Count -gt 0) {
                $trPath = Join-Path -Path $runFolder -ChildPath ("ExoQueue - {0}-TopRecipients{1}.xml" -f $fileStamp, $exportSuffix)
                if ($PSCmdlet.ShouldProcess($trPath, 'Export top recipients')) {
                    $topRecipientResults | Export-Clixml -Path $trPath
                    $outputFiles.Add($trPath)
                    Write-Ui "Top recipients saved to: " -NoNewline
                    Write-Ui "$trPath" -ForegroundColor Cyan
                }
            }
            Write-Ui ""
        }

        $result.OutputFiles = @($outputFiles)

        if ($Output -contains 'GridView') {
            # -Quiet is what an unattended run passes, and -Output defaults to GridView, so the
            # combination the help points a scheduled task at opened a window on a desktop nobody
            # was watching - and the NOTE that would have explained where it came from goes through
            # Write-Ui, which -Quiet had already suppressed. Warnings survive -Quiet, so the run now
            # says what it declined to show instead of showing it.
            if ($Quiet) {
                $warningText = "-Quiet suppresses the GridView. $($messages.Count) messages were retrieved; use -Output CSV or -PassThru to get at them."
                $runWarnings.Add($warningText)
                Write-Warning $warningText
            }
            else {
                $grid = $messages
                if ($messages.Count -gt $GridViewRowLimit) {
                    $warningText = ("Showing the {0:N0} oldest of {1:N0} messages in the grid. Use -Output CSV for the full set or raise -GridViewRowLimit." -f $GridViewRowLimit, $messages.Count)
                    $runWarnings.Add($warningText)
                    Write-Warning $warningText
                    $grid = @($messages | Select-Object -First $GridViewRowLimit)
                }
                Write-Ui "Current Queue: (If Gridview window doesn't appear, check for a hidden PowerShell pop-up window)." -ForegroundColor Cyan
                $grid | Select-Object -Property * | Out-GridView -Title "Exchange Online Message Queue"
            }
        }

        if ($Output -contains 'CSV' -and $outputFiles.Count -gt 0) {
            if (Test-ExoQueueFormulaRisk -Row $messages) {
                $warningText = "Some exported values begin with =, +, - or @ and will be evaluated as formulas if opened in Excel. The values are exported unaltered; treat the file as untrusted content."
                $runWarnings.Add($warningText)
                Write-Warning $warningText
            }

            # Skipped rather than refused under -Quiet: opening Excel is optional decoration, and
            # stopping a finished run over it would throw away the work. $csvWritten as well,
            # because under -Confirm the All Results export can be declined while a Top-N export is
            # accepted, and the prompt offers to open the file that was not written.
            if ($csvWritten -and -not $Force -and -not $Quiet -and (Confirm-Ui -Prompt 'Do you want to open the queue csv file for All Results? (Y/N)')) {

                $excelPath = Get-ExoQueueExcelPath
                if ($null -eq $excelPath) {
                    # 1.4.3 fell through to Test-Path -Path $null here, which is a terminating
                    # parameter-binding error rather than the intended message.
                    $warningText = "Excel executable not found. Please ensure Excel is installed."
                    $runWarnings.Add($warningText)
                    Write-Warning $warningText
                }
                else {
                    Start-Process -FilePath $excelPath -ArgumentList "`"$csvPath`""
                }
            }
        }

        if ($PassThru) { return $result }
    }
}

# This file defines a function; it does not run one. 1.4.2 declared that function at global scope,
# so "& .\Get-ExoQueue.ps1" left the command behind in the session and appeared to work. Here that
# same habit is a silent no-op - no function, no error, no output - so it gets one line of help
# instead. InvocationName is '.' only for a dot-source, including the test suite's, and is the
# call operator or the full path otherwise.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ""
    Write-Host "Get-ExoQueue.ps1 defines the Get-ExoQueue function; running the file does not run it." -ForegroundColor Yellow
    Write-Host "Dot-source it first, then call it:" -ForegroundColor Yellow
    Write-Host ("    . '{0}'" -f $PSCommandPath) -ForegroundColor Cyan
    Write-Host "    Get-ExoQueue -AgeMinutes 30" -ForegroundColor Cyan
    Write-Host ""
}
