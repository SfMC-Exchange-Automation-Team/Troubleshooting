#Requires -Version 5.1

<#
.SYNOPSIS
Monitors BigFunnelPostingListTableTotalSize for Exchange mailboxes, with
growth-rate trending and time-to-threshold projection.

.DESCRIPTION
Collects Get-MailboxStatistics output by database, converts
BigFunnelPostingListTableTotalSize to bytes, evaluates thresholds, compares
against an earlier run to derive growth rate and projected days to the
critical threshold, and exports CSV results.

On builds where the posting list table reads 0 B for every mailbox in scope,
growth is measured on IndexPayloadBytes instead and the at-risk mailboxes are
ranked by rate rather than projected to a date. The thresholds are sizes of the
posting list table and have never been validated against the payload counter,
so extrapolating one to the other would be arithmetic on unrelated quantities.
The ordering is still the answer to "which mailbox is next"; only the deadline
is withheld.

Designed to run unattended on a schedule. Every failure mode is contained at
the smallest possible scope: a single unparseable mailbox does not abort its
database, and a single failed database does not abort the run.

.PARAMETER Databases
Explicit database names. When omitted, databases are discovered according to
-Scope.

.PARAMETER Scope
Local  - databases whose active copy is currently mounted on this server
         (default; correct for a per-server scheduled task in a DAG).
All    - every mounted database in the organization.
Ignored when -Databases is supplied.

.PARAMETER ThresholdMode
Fixed     - use -WarningGB and -CriticalGB as given (default).
Adaptive  - raise the thresholds to the population's 95th and 99th percentile
            when those sit above the fixed values. Adaptive only ever raises,
            never lowers: the fixed values remain a floor, so an organization
            whose tables all sit high alerts on genuine outliers instead of on
            everyone, while a healthy organization is unaffected. Falls back to
            Fixed when the sample is smaller than -AdaptiveMinimumSample or
            when the two percentiles do not separate.

.PARAMETER AdaptiveMinimumSample
Smallest mailbox population for which -ThresholdMode Adaptive will compute
percentiles. Below this the percentiles are dominated by a handful of values
and the fixed thresholds are used instead.

.PARAMETER TrendBaselineHours
Minimum age of the run used as the growth baseline. A short window magnifies
noise: at a 4-hour cadence, a 4-hour delta is multiplied by six to reach a
per-day rate, and the projection swings with it. The newest run at least this
old is preferred; if the history is not that deep, the oldest available run is
used instead and the actual window is reported.

Accepts 1 to 8760. Zero is rejected rather than treated as "no minimum":
it would make every baseline old enough by definition, silencing the warning
that the window was too narrow while the rates were still computed and
reported from it.

.PARAMETER MaxRunMinutes
Wall-clock budget for collection. Remaining databases are skipped and reported
as not collected once it is spent, so a slow run cannot overrun its own
schedule interval. 0 disables the budget.

This bounds the work the script does; it cannot interrupt a single store call
that never returns. Set -ExecutionTimeLimit on the scheduled task as the
backstop for that case.

.PARAMETER MaxAlertDetail
Maximum number of per-mailbox alert lines written to the log per category.
A server in a bad state can hold thousands of at-risk mailboxes, and one log
line each turns the run into its own disk-space problem.

.PARAMETER ExitNonZeroOnAlert
Return a non-zero exit code when the run has something to say: 1 when at-risk
mailboxes are found, 5 when the metric could not be read on any indexed
mailbox. Off by default so that "found problems" is not confused with "the
monitor broke".

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1

Collects every database whose active copy is mounted on this server, using the
default 1.7 GB / 2.0 GB thresholds, and writes to %ProgramData%.

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1 -Databases DB01, DB02 -Verbose

Collects two named databases and echoes the log to the console.

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1 -ThresholdMode Adaptive -ThrottleDelaySeconds 30

Raises the thresholds to the population's 95th/99th percentile where those sit
above the fixed values, and pauses 30 seconds between databases to spread the
load on a busy store.

.EXAMPLE
Register-ScheduledTask -TaskName 'BigFunnel PostingList Monitor' -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        '"C:\Scripts\Monitor-BigFunnelPostingList.ps1"')) `
    -Trigger (New-ScheduledTaskTrigger -Once -At 00:05 `
        -RepetitionInterval (New-TimeSpan -Hours 4)) `
    -User 'CONTOSO\svc-exmon' -RunLevel Highest `
    -Settings (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable)

Schedules the monitor every 4 hours. -ExecutionTimeLimit is the backstop for a
store call that never returns; -MultipleInstances IgnoreNew is belt and braces
alongside the script's own concurrency lock.

.NOTES
Windows PowerShell 5.1 compatible. Read-only against Exchange.

Exit codes:
  0  Completed. All in-scope databases collected.
  1  Completed, at-risk mailboxes found (-ExitNonZeroOnAlert only).
  2  Completed with partial failure. At least one database was not collected,
     or collection was cut short by -MaxRunMinutes.
  3  Fatal. Pre-flight failed, or no databases were in scope.
  4  Another instance is already running.
  5  Completed, but every indexed mailbox in scope reported the posting list
     table as 0 B, so no threshold in this run could have fired
     (-ExitNonZeroOnAlert only). Kept distinct from 1 on purpose: 1 means a
     mailbox crossed a line, 5 means there was no line to cross. Returning 0
     here would report "nothing found" from a run that could not have found
     anything.

Invoke with powershell.exe -File, not -Command. -Command collapses every
non-zero exit to 1, so 2, 3, 4 and 5 all arrive as "at-risk mailboxes found"
and a caller cannot tell a metric outage or a failed database from a threshold
breach. Measured, not assumed: a script whose only statement is "exit 5"
returns 5 under -File and 1 under -Command, with no errors involved. The
scheduled-task example above already uses -File.

Status values in the detail CSV:
  Critical      at or above the critical threshold
  Warning       at or above the warning threshold
  NotPopulated  BigFunnelPostingListTableTotalSize is 0 B on a mailbox
                BigFunnel reports as indexed (BigFunnelIndexedCount above
                zero). The metric this monitor is built on is not being
                populated for that mailbox, so its size cannot be read as
                healthy - it cannot be read at all. Confirmed on Exchange
                Server SE 15.2.2562.17, where a fully indexed mailbox kept
                its index in BigFunnelTotalPOISize,
                BigFunnelLargePOITableTotalSize and
                BigFunnelFilterTableTotalSize while the posting list table
                stayed at exactly 0 B. Check IndexPayloadBytes for the size
                that is actually there.
  Normal        below the warning threshold, with no contradicting counter

If NotPopulated covers every mailbox that has an index, this build does not
surface the metric and a clean run proves nothing about posting list growth.
Treat that as a monitoring gap to raise, not as a pass. The run says so itself
rather than leaving it to be noticed: Status in latest-summary.json becomes
MetricUnavailable, and the exit code becomes 5 under -ExitNonZeroOnAlert. The
comparison is against indexed mailboxes rather than all collected rows on
purpose: health, arbitration, system and archive mailboxes hold no index, so
they can never reach this state and would otherwise mask a total outage.

On that build the run still answers which mailbox is next. Growth is measured
on IndexPayloadBytes, DaysToCritical is left empty on every row, and the log
carries a "Fastest growing #n" ranking in place of the emerging-risk list,
which is keyed on a projection that cannot be made there. latest-summary.json
reports TrendMetric = IndexPayloadBytes and a Growing count; alert on Growing
rather than Emerging when TrendMetric is not PostingListBytes, because Emerging
is empty by construction on that path.

Requires Exchange RBAC permission to run:
- Get-ExchangeServer
- Get-MailboxDatabase
- Get-MailboxStatistics

Outputs, written to -OutputPath:
  BigFunnelPostingListMonitor-<runId>.csv   per-run detail, retained
  BigFunnelPostingListMonitor-<runId>.log   per-run log, retained
  latest.csv                                stable copy of the newest detail
  latest-summary.json                       stable run summary for monitoring

The two stable files are deliberately named outside the
BigFunnelPostingListMonitor-* pattern so that neither the baseline scan nor
the retention sweep can pick them up.

latest-summary.json is written on every run that gets far enough to have an
output directory, including runs that abort. It always carries the same field
set. Alert on Completed = false, which covers every abort reason, and read
Status for the reason itself. latest.csv is only refreshed when a run produced
detail, so it can legitimately be older than the summary beside it.

Status on a run that completed is one of:
  OK                 the run collected its scope and the counter was readable
  Partial            at least one database was not collected (exit code 2)
  MetricUnavailable  every indexed mailbox in scope reported the posting list
                     table as 0 B

Completed = false does not cover MetricUnavailable. Such a run completes and
collects everything asked of it; it just cannot read the one counter it exists
to read, so every threshold in it was applied to a constant zero and a clean
result means only that nothing could have been found. Alert on it separately,
as a monitoring gap rather than a pass. Unlike the exit code, this value is not
gated on -ExitNonZeroOnAlert.
#>

[CmdletBinding()]
param(
    [string[]]$Databases,

    [ValidateSet('Local', 'All')]
    [string]$Scope = 'Local',

    [ValidateRange(0.001, 1024)]
    [double]$WarningGB = 1.7,

    [ValidateRange(0.001, 1024)]
    [double]$CriticalGB = 2.0,

    [ValidateSet('Fixed', 'Adaptive')]
    [string]$ThresholdMode = 'Fixed',

    [ValidateRange(10, 1000000)]
    [int]$AdaptiveMinimumSample = 100,

    [string]$OutputPath = (Join-Path $env:ProgramData 'ExchangeBigFunnelPostingListMonitor'),

    [ValidateRange(0, 3650)]
    [int]$RetentionDays = 30,

    [ValidateRange(0, 300)]
    [int]$ThrottleDelaySeconds = 0,

    # The floor is 1, not 0, and the difference is not cosmetic. Zero makes every
    # baseline on disk old enough by definition, so the newest run always wins,
    # MetMinimum is true by construction, and the warning below about a narrow
    # window magnifying noise can never fire. The rate is still computed and
    # still printed - from whatever gap happened to exist, with nothing on the
    # run saying the sample was too thin to divide by.
    [ValidateRange(1, 8760)]
    [int]$TrendBaselineHours = 24,

    [ValidateRange(0, 1440)]
    [double]$MaxRunMinutes = 60,

    [ValidateRange(1, 10000)]
    [int]$MaxAlertDetail = 25,

    [switch]$ExitNonZeroOnAlert
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptVersion   = '1.4.0'
$script:OutputPath      = $OutputPath
$script:LogFile         = $null
$script:LogFailed       = $false
$script:FailedDbs       = New-Object System.Collections.Generic.List[string]

# PowerShell 5.1's -Encoding UTF8 writes a byte-order mark. Harmless in a log,
# but the same encoder is reused for the summary JSON, where a leading BOM
# breaks strict parsers. One BOM-free encoder for both.
$script:Utf8NoBom       = New-Object System.Text.UTF8Encoding($false)

# Incremented from inside a ForEach-Object script block, which runs in a child
# scope: a bare $x++ there would read the parent value and write a local copy,
# silently counting nothing. Script scope makes the write land.
$script:PropertyMissing = 0
$script:ParseFailures   = 0
$script:NoSizeValue     = 0
$script:MailboxesSeen   = 0
$script:DeadlineHit     = $false

# Run-level, unlike $script:DeadlineHit, which is reset per database.
$script:BudgetExceeded  = $false

$script:ThisServer = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($script:ThisServer)) { $script:ThisServer = [System.Net.Dns]::GetHostName() }

#region helpers ---------------------------------------------------------------

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line

    # Logging must never be the reason a monitoring run dies. If the log file
    # is locked, the volume is full, or AV holds a handle, degrade to the
    # console and keep collecting.
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, ($line + [Environment]::NewLine), $script:Utf8NoBom)
        }
        catch {
            if (-not $script:LogFailed) {
                $script:LogFailed = $true
                Write-Warning ('Log file unavailable, continuing without it: {0}' -f $_.Exception.Message)
            }
        }
    }

    if ($Level -eq 'ERROR' -or $Level -eq 'FATAL') { Write-Warning $line }
}

function Get-SafeProperty {
    # StrictMode 2.0 turns any access to an absent property into a terminating
    # error. Get-MailboxStatistics does not return a uniform shape across
    # mailbox states (disconnected, soft-deleted, never-logged-on), so every
    # property read goes through here.
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-NullableInt64 {
    # Counters arrive as integers from the live cmdlet and as strings from a
    # CSV baseline, and may be absent or empty on either path. Everything that
    # is not a whole number becomes $null so callers can test one way.
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $n = New-Object 'System.Int64'
    if ([int64]::TryParse($text, [ref]$n)) { return $n }
    return $null
}

function Convert-ExchangeSizeToBytes {
    [CmdletBinding()]
    param($SizeValue)

    if ($null -eq $SizeValue) { return $null }

    # Get-MailboxStatistics returns Unlimited<ByteQuantifiedSize>, which is a
    # wrapper. ToBytes() lives on the inner ByteQuantifiedSize, not on the
    # wrapper, so unwrap before testing for it.
    if ($SizeValue.PSObject.Properties.Name -contains 'IsUnlimited') {
        if ($SizeValue.IsUnlimited) { return $null }
        $SizeValue = $SizeValue.Value
        if ($null -eq $SizeValue) { return $null }
    }

    if ($SizeValue.PSObject.Methods.Name -contains 'ToBytes') {
        try { return [int64]$SizeValue.ToBytes() } catch { }
    }

    $text = [string]$SizeValue

    # Catches both a literal string and any wrapper whose ToString() is
    # "Unlimited", regardless of how it was reached.
    if ($text -match 'Unlimited') { return $null }

    # Exchange renders sizes with an invariant thousands separator, e.g.
    # "1.158 GB (1,243,054,080 bytes)". Verified identical under en-US, de-DE
    # and fr-FR, so this regex is culture-safe.
    if ($text -match '\(([0-9,]+)\s+bytes\)') {
        return [int64](($matches[1]) -replace ',', '')
    }

    if ($text -match '^\s*([0-9.]+)\s*(B|KB|MB|GB|TB)\s*$') {
        $number = [double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture)
        switch ($matches[2].ToUpperInvariant()) {
            'B'  { return [int64]$number }
            'KB' { return [int64]($number * 1KB) }
            'MB' { return [int64]($number * 1MB) }
            'GB' { return [int64]($number * 1GB) }
            'TB' { return [int64]($number * 1TB) }
        }
    }

    throw ('Unable to parse size value: {0}' -f $text)
}

function Test-ExchangeBuild {
    # BigFunnelPostingListTableTotalSize is exposed by Exchange 2019 and
    # Exchange Server SE, both of which report 15.2. On 2013 (15.0) and 2016
    # (15.1) the property is simply absent, and without this check the run
    # reports it one skipped mailbox at a time - which reads like a data
    # problem rather than an unsupported platform.
    #
    # Never fatal on its own uncertainty: if the build cannot be established,
    # the run continues and says so.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Server)

    $unknown = {
        param($Reason, $Text)
        [pscustomobject]@{ Known = $false; Supported = $true; Version = [string]$Text; Reason = [string]$Reason }
    }

    if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
        return (& $unknown 'Get-ExchangeServer is not available' '')
    }

    try { $srv = Get-ExchangeServer -Identity $Server -ErrorAction Stop }
    catch { return (& $unknown $_.Exception.Message '') }

    $version = Get-SafeProperty $srv 'AdminDisplayVersion'
    if ($null -eq $version) { return (& $unknown 'AdminDisplayVersion was not returned' '') }

    $major = Get-SafeProperty $version 'Major'
    $minor = Get-SafeProperty $version 'Minor'

    # Falls back to parsing the rendered string, which is the shape that comes
    # back over an implicit remoting session where the typed object is lost.
    if ($null -eq $major -or $null -eq $minor) {
        if ([string]$version -match '(\d+)\.(\d+)') {
            $major = [int]$matches[1]
            $minor = [int]$matches[2]
        }
    }
    if ($null -eq $major -or $null -eq $minor) {
        return (& $unknown 'the build number could not be parsed' $version)
    }

    $supported = ([int]$major -gt 15) -or ([int]$major -eq 15 -and [int]$minor -ge 2)
    return [pscustomobject]@{
        Known     = $true
        Supported = $supported
        Version   = [string]$version
        Reason    = ''
    }
}

function Get-Percentile {
    # Nearest-rank on an already-sorted ascending array. No interpolation:
    # these are byte counts feeding a threshold, and an interpolated value that
    # matches no observed mailbox would be harder to explain than one that does.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int64[]]$SortedValues,
        [Parameter(Mandatory = $true)][double]$Percentile
    )

    if ($SortedValues.Count -eq 0) { return [int64]0 }

    $rank = [int][math]::Ceiling(($Percentile / 100.0) * $SortedValues.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $SortedValues.Count) { $rank = $SortedValues.Count }
    return [int64]$SortedValues[$rank - 1]
}

function Get-PostingListStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int64]$Bytes,
        [Parameter(Mandatory = $true)][int64]$WarningBytes,
        [Parameter(Mandatory = $true)][int64]$CriticalBytes,
        # Deliberately untyped. PowerShell 5.1 cannot bind $null to [int64], and
        # this arrives as $null on any build that does not expose the counter.
        $IndexedCount = $null
    )

    if ($Bytes -ge $CriticalBytes) { return 'Critical' }
    if ($Bytes -ge $WarningBytes)  { return 'Warning' }

    # Verified on Exchange Server SE 15.2.2562.17: a mailbox with 200 fully
    # indexed messages reported BigFunnelIndexedCount 200, a live searchable
    # index, and roughly 4 MB spread across BigFunnelTotalPOISize,
    # BigFunnelLargePOITableTotalSize and BigFunnelFilterTableTotalSize - while
    # BigFunnelPostingListTableTotalSize stayed at exactly 0 B.
    #
    # Reporting that as Normal is a silent false negative: it is indistinguish-
    # able from a genuinely small mailbox, so on a build that never populates
    # the table every mailbox reads healthy and the monitor never alerts.
    # Zero bytes on a demonstrably indexed mailbox means the metric is
    # unavailable here, which is a different fact from "this mailbox is fine".
    $indexed = ConvertTo-NullableInt64 $IndexedCount
    if ($Bytes -eq 0 -and $null -ne $indexed -and $indexed -gt 0) { return 'NotPopulated' }

    return 'Normal'
}

function Get-PreviousRunBaseline {
    # The run ID embedded in each file name is yyyyMMdd-HHmmss followed by the
    # process id, so the timestamp parses without touching the current culture.
    # That is deliberately more robust than reading a datetime back out of the
    # CSV body.
    #
    # The trailing process id is optional in the pattern below rather than
    # required, and both halves of that matter. It has to be allowed, because
    # without it this function silently stops finding any baseline at all the
    # moment $runId gained a $PID suffix - and the failure is invisible, because
    # "no previous run found" is also what a genuine first run looks like. It
    # has to stay optional, because runs written before that change are still
    # on disk and are still perfectly good baselines.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExcludeFile,
        [int]$MinHours = 24
    )

    $now = Get-Date

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter 'BigFunnelPostingListMonitor-*.csv' -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -ne $ExcludeFile })) {

        if ($file.BaseName -notmatch '(\d{8}-\d{6})(?:-\d+)?$') { continue }
        $stamp = New-Object DateTime
        $parsed = [datetime]::TryParseExact(
            $matches[1], 'yyyyMMdd-HHmmss',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$stamp)
        if (-not $parsed) { continue }
        if ($stamp -ge $now) { continue }

        $candidates.Add([pscustomobject]@{
            File  = $file
            Stamp = $stamp
            Age   = ($now - $stamp).TotalHours
        })
    }
    if ($candidates.Count -eq 0) { return $null }

    # A short window magnifies noise. At a 4-hour cadence the delta is
    # multiplied by six to reach a per-day rate, so a few megabytes of ordinary
    # churn reads as a growth trend and the projection swings run to run.
    # Prefer the newest run that is at least MinHours old; when the history is
    # not yet that deep, fall back to the oldest run on disk, which is the
    # widest window available.
    $ordered   = @($candidates | Sort-Object Stamp -Descending)
    $preferred = @($ordered | Where-Object { $_.Age -ge $MinHours })

    $attempts = New-Object System.Collections.Generic.List[object]
    foreach ($c in $preferred) { $attempts.Add($c) }
    foreach ($c in @($ordered | Where-Object { $_.Age -lt $MinHours } | Sort-Object Stamp)) { $attempts.Add($c) }

    foreach ($candidate in $attempts) {
        try { $rows = @(Import-Csv -LiteralPath $candidate.File.FullName -ErrorAction Stop) }
        catch { continue }
        if ($rows.Count -eq 0) { continue }

        $map = @{}
        foreach ($r in $rows) {
            $guid = [string](Get-SafeProperty $r 'MailboxGuid')
            if ([string]::IsNullOrWhiteSpace($guid)) { continue }

            $bytes = ConvertTo-NullableInt64 (Get-SafeProperty $r 'PostingListBytes')
            if ($null -eq $bytes) { continue }

            # Carried so the search-health counters can be judged as
            # "increasing" rather than against a threshold this script has no
            # business inventing. Payload is here for the same reason the
            # collection gathers it: on a build that never populates the posting
            # list table it is the only counter with a growth signal in it, and
            # a rate needs two readings of the same counter, not one of each.
            #
            # Null on baselines written before that column existed. The join
            # treats that as "no reading" rather than as zero, because zero would
            # turn the whole of the current size into a single run's growth.
            $map[$guid] = [pscustomobject]@{
                Bytes      = $bytes
                Payload    = ConvertTo-NullableInt64 (Get-SafeProperty $r 'IndexPayloadBytes')
                NotIndexed = ConvertTo-NullableInt64 (Get-SafeProperty $r 'BigFunnelNotIndexedCount')
                Stale      = ConvertTo-NullableInt64 (Get-SafeProperty $r 'BigFunnelStaleCount')
            }
        }
        if ($map.Count -eq 0) { continue }

        return [pscustomobject]@{
            Timestamp   = $candidate.Stamp
            AgeHours    = [math]::Round($candidate.Age, 2)
            MetMinimum  = ($candidate.Age -ge $MinHours)
            Sizes       = $map
            Source      = $candidate.File.Name
        }
    }
    return $null
}

function Get-SearchHealth {
    # The runbook's index-health table states the expectations directly:
    # corrupted items should be 0, not-indexed should trend low or decreasing,
    # and stale should not be growing. Two of the three are only answerable
    # against a baseline, which is why this runs after the trend join. Nothing
    # here invents a threshold - it reports "non-zero" and "increased".
    [CmdletBinding()]
    param($Row, $Previous)

    $flags = New-Object System.Collections.Generic.List[string]

    $corrupt = ConvertTo-NullableInt64 $Row.BigFunnelCorruptedCount
    if ($null -ne $corrupt -and $corrupt -gt 0) { $flags.Add('Corrupted=' + $corrupt) }

    if ($null -ne $Previous) {
        $notIndexed = ConvertTo-NullableInt64 $Row.BigFunnelNotIndexedCount
        if ($null -ne $notIndexed -and $null -ne $Previous.NotIndexed -and $notIndexed -gt $Previous.NotIndexed) {
            $flags.Add('NotIndexedUp=+' + ($notIndexed - $Previous.NotIndexed))
        }

        $stale = ConvertTo-NullableInt64 $Row.BigFunnelStaleCount
        if ($null -ne $stale -and $null -ne $Previous.Stale -and $stale -gt $Previous.Stale) {
            $flags.Add('StaleUp=+' + ($stale - $Previous.Stale))
        }
    }

    if ($flags.Count -eq 0) { return 'OK' }
    return ($flags -join '; ')
}

function Remove-ExpiredOutput {
    # A 4-hour cadence writes ~4,400 files a year into ProgramData. Prune.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$Days)

    if ($Days -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    try {
        $old = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop |
                 Where-Object { $_.Name -like 'BigFunnelPostingListMonitor-*' -and $_.LastWriteTime -lt $cutoff })
        foreach ($f in $old) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            catch { Write-RunLog ('Could not remove [{0}]: {1}' -f $f.Name, $_.Exception.Message) 'WARN' }
        }
        if ($old.Count -gt 0) { Write-RunLog ('Removed {0} file(s) older than {1} day(s).' -f $old.Count, $Days) }
    }
    catch { Write-RunLog ('Retention sweep skipped: {0}' -f $_.Exception.Message) 'WARN' }
}

function Write-RunSummary {
    # One writer for both the completed and the aborted paths.
    #
    # A monitoring agent polling latest-summary.json needs the same field set
    # every time. It also needs the file to change when a run fails: a
    # pre-flight failure that wrote nothing would leave the previous run's
    # summary in place, and the agent would go on reporting a healthy run
    # indefinitely while the monitor was in fact dead. Every field is declared
    # here with a default, and callers supply only what they measured.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $schema = [ordered]@{
        RunId                = ''
        ScriptVersion        = $script:ScriptVersion
        Timestamp            = (Get-Date).ToString('o')
        DurationSeconds      = 0
        Server               = $script:ThisServer
        Scope                = ''
        ExchangeVersion      = ''
        # False whenever the run stopped before completing collection, whatever
        # the reason. The single field an alert rule should key on.
        Completed            = $false
        Status               = ''
        ThresholdMode        = ''
        # What actually applied. Adaptive falls back to Fixed on a small or
        # tightly clustered population, and a consumer comparing runs needs to
        # know which happened rather than inferring it from the numbers.
        ThresholdBasis       = ''
        WarningGB            = 0
        CriticalGB           = 0
        ConfiguredWarningGB  = 0
        ConfiguredCriticalGB = 0
        DatabasesInScope     = 0
        DatabasesFailed      = 0
        # Joined rather than left as an array: PowerShell 5.1 serialises a
        # one-element array as a bare scalar, so a consumer would see a string
        # on one run and a list on the next.
        FailedDatabases      = ''
        RunBudgetExceeded    = $false
        MailboxesEvaluated   = 0
        Critical             = 0
        Warning              = 0
        Emerging             = 0
        Shrinking            = 0
        SearchHealthIssues   = 0
        # Mailboxes BigFunnel reports as indexed whose posting list table is
        # nonetheless 0 B. A non-zero count here means the metric this monitor
        # is built on is not populated on this build, and a clean run says
        # nothing about posting list growth.
        NotPopulated         = 0
        SkippedUnparseable   = 0
        # Present but unreadable - Unlimited, or an empty property. Separate
        # from SkippedUnparseable because the causes differ, and both are
        # separate from MailboxesEvaluated: the three have to add up against
        # the per-database counts or a row went missing unnoticed.
        SkippedNoSize        = 0
        MissingProperty      = 0
        TrendBaseline        = ''
        TrendWindowHours     = $null
        # Which counter GrowthGBPerDay was measured on. A consumer comparing
        # growth across runs needs it: the same column carries posting list
        # growth on one build and index payload growth on the next, and the two
        # are three orders of magnitude apart. Growing is the headline count for
        # the build where no projection is possible, and is the field to alert on
        # there, since Emerging is empty by construction on that path.
        TrendMetric          = ''
        Growing              = 0
        DetailCsv            = ''
        LogFile              = $script:LogFile
        ExitCode             = 0
    }

    foreach ($k in @($Values.Keys)) {
        # A mistyped key would otherwise vanish silently and the field would
        # report its default, which reads as a real measurement.
        if (-not $schema.Contains($k)) {
            Write-RunLog ('Run summary field [{0}] is not part of the schema and was ignored.' -f $k) 'WARN'
            continue
        }
        $schema[$k] = $Values[$k]
    }

    try {
        # Written without a BOM. PowerShell 5.1's -Encoding UTF8 emits one, and
        # a leading BOM breaks strict JSON parsers on the consuming side.
        $json = ([pscustomobject]$schema) | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
        # Recorded in script scope rather than returned, so a stray write to the
        # success stream from anything added above cannot be mistaken for the
        # result.
        $script:SummaryWritten = $true
    }
    catch {
        Write-RunLog ('Could not write the run summary to [{0}]: {1}' -f $Path, $_.Exception.Message) 'WARN'
    }
}

#endregion

#region pre-flight ------------------------------------------------------------

if ($WarningGB -ge $CriticalGB) {
    # Write-Warning, not Write-Error: $ErrorActionPreference is Stop, which
    # would make Write-Error terminating and skip the exit code below.
    Write-Warning ('WarningGB ({0}) must be below CriticalGB ({1}); otherwise the warning tier can never fire.' -f $WarningGB, $CriticalGB)
    exit 3
}

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
}
catch {
    Write-Warning ('Cannot create output path [{0}]: {1}' -f $OutputPath, $_.Exception.Message)
    exit 3
}

# The process id is part of the identity. Get-Date has one-second resolution, so
# two runs starting within the same second derive the same log path and append to
# one file. Logging here degrades rather than dies, so the run survives - but the
# line that gets dropped is the refused run's "another instance is already
# running", which is exactly the line that explains a missing run.
$runId          = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
$runStart       = Get-Date
$script:LogFile = Join-Path $OutputPath ('BigFunnelPostingListMonitor-{0}.log' -f $runId)
$csvPath        = Join-Path $OutputPath ('BigFunnelPostingListMonitor-{0}.csv' -f $runId)

# A timestamped file is right for history, but a monitoring agent wants one
# path it can read on a schedule without globbing for the newest name. Both of
# these sit outside the BigFunnelPostingListMonitor-* pattern, so neither the
# baseline scan nor the retention sweep can touch them. Resolved this early
# because the failure paths write the summary too.
$latestCsv      = Join-Path $OutputPath 'latest.csv'
$latestJson     = Join-Path $OutputPath 'latest-summary.json'

# A long collection against a busy store can overrun the schedule interval.
# Two concurrent runs would double the load on the very component this script
# exists to protect. Global\ needs SeCreateGlobalPrivilege, which the Exchange
# service account has and an interactive tester may not, so fall back rather
# than fail the run over a lock we could not take.
$mutex   = $null
$holding = $false
foreach ($scopePrefix in @('Global\', 'Local\')) {
    try {
        $mutex = New-Object System.Threading.Mutex($false, ($scopePrefix + 'ExchangeBigFunnelPostingListMonitor'))
        break
    }
    catch {
        Write-Warning ('Could not create a {0}scoped mutex: {1}' -f $scopePrefix, $_.Exception.Message)
    }
}

if ($null -ne $mutex) {
    try { $holding = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $holding = $true }

    if (-not $holding) {
        Write-RunLog 'Another instance is already running. Exiting without collecting.' 'WARN'
        exit 4
    }
}
else {
    Write-RunLog 'Proceeding without a concurrency lock; overlapping runs are possible.' 'WARN'
}

$exitCode = 0

# Set at each site that aborts the run, and reported as Status in the summary
# so a monitoring agent gets the reason rather than just a non-zero code.
$abortReason           = ''
$script:SummaryWritten = $false

# Declared out here because the finally block reads it, and StrictMode 2.0
# throws on a variable that was never assigned - which would replace the real
# abort reason with a misleading one.
$build                 = $null

try {
    Write-RunLog ('Starting BigFunnel PostingListTable monitor v{0}, run {1}, on {2}.' -f
        $script:ScriptVersion, $runId, $script:ThisServer)

    # Echoed in full because the first question asked of any unattended run is
    # "what was it actually configured with", and the answer should be in the
    # log rather than in whoever registered the task.
    Write-RunLog ('Settings: Scope={0}, ThresholdMode={1}, WarningGB={2}, CriticalGB={3}, TrendBaselineHours={4}, MaxRunMinutes={5}, ThrottleDelaySeconds={6}, RetentionDays={7}, MaxAlertDetail={8}, ExitNonZeroOnAlert={9}.' -f
        $Scope, $ThresholdMode, $WarningGB, $CriticalGB, $TrendBaselineHours,
        $MaxRunMinutes, $ThrottleDelaySeconds, $RetentionDays, $MaxAlertDetail, [bool]$ExitNonZeroOnAlert)

    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        try { Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop }
        catch { Write-RunLog ('Could not load the Exchange snap-in: {0}' -f $_.Exception.Message) 'WARN' }
    }
    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        Write-RunLog 'Get-MailboxStatistics is not available. Run from the Exchange Management Shell.' 'FATAL'
        $abortReason = 'Exchange cmdlets unavailable'
        $exitCode = 3
        exit $exitCode
    }

    # Confirm RBAC before collecting, so a permissions problem reports as a
    # fatal pre-flight rather than as every database failing individually.
    try {
        $null = Get-MailboxDatabase -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        Write-RunLog ('Cannot enumerate mailbox databases. Check Exchange RBAC for this account. {0}' -f $_.Exception.Message) 'FATAL'
        $abortReason = 'Cannot enumerate mailbox databases (RBAC)'
        $exitCode = 3
        exit $exitCode
    }

    # Fail fast on a build that cannot expose the property at all, rather than
    # producing an empty CSV and a warning per mailbox.
    $build = Test-ExchangeBuild -Server $script:ThisServer
    if ($build.Known) {
        if (-not $build.Supported) {
            Write-RunLog ('This server reports {0}. BigFunnelPostingListTableTotalSize is exposed by Exchange 2019 and Exchange Server SE (15.2) and later; on earlier builds it is absent for every mailbox. Nothing collected.' -f $build.Version) 'FATAL'
            $abortReason = ('Unsupported Exchange build {0}' -f $build.Version)
            $exitCode = 3
            exit $exitCode
        }
        Write-RunLog ('Exchange build: {0}.' -f $build.Version)
    }
    else {
        Write-RunLog ('Exchange build not determined ({0}); continuing, and any missing property will be reported per mailbox.' -f $build.Reason)
    }

    #region database scope ----------------------------------------------------

    # @($null).Count is 1, not 0, so an unbound [string[]] parameter cannot be
    # length-tested directly without falsely reporting one requested database.
    $requested = @()
    if ($null -ne $Databases) {
        $requested = @($Databases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($requested.Count -gt 0) {
        $valid = New-Object System.Collections.Generic.List[string]
        foreach ($name in $requested) {
            try {
                $db = Get-MailboxDatabase -Identity $name -ErrorAction Stop
                $valid.Add([string](Get-SafeProperty $db 'Name'))
            }
            catch {
                Write-RunLog ('Database [{0}] was requested but does not exist or is not visible.' -f $name) 'ERROR'
                $script:FailedDbs.Add([string]$name)
            }
        }
        $targets = @($valid)
    }
    else {
        Write-RunLog ('No databases specified. Discovering with scope [{0}].' -f $Scope)

        # Mounted is populated only on the server hosting the active copy, so
        # filtering on it silently yields nothing when the script runs on a
        # passive DAG node. MountedOnServer is populated from any node.
        $all = @(Get-MailboxDatabase -Status -ErrorAction SilentlyContinue |
                 Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-SafeProperty $_ 'MountedOnServer')) })

        if ($Scope -eq 'Local') {
            $me = $script:ThisServer
            $targets = @($all |
                Where-Object {
                    $host_ = [string](Get-SafeProperty $_ 'MountedOnServer')
                    ($host_ -split '\.')[0] -eq $me
                } |
                ForEach-Object { [string](Get-SafeProperty $_ 'Name') })

            if ($targets.Count -eq 0 -and $all.Count -gt 0) {
                Write-RunLog ('No active database copies are mounted on {0}. {1} database(s) are mounted elsewhere in the DAG; use -Scope All or schedule this on the active node.' -f $me, $all.Count) 'WARN'
            }
        }
        else {
            $targets = @($all | ForEach-Object { [string](Get-SafeProperty $_ 'Name') })
        }
    }

    if ($targets.Count -eq 0) {
        Write-RunLog 'No databases are in scope. Nothing to collect.' 'FATAL'
        $abortReason = 'No databases in scope'
        $exitCode = 3
        exit $exitCode
    }
    Write-RunLog ('{0} database(s) in scope: {1}' -f $targets.Count, ($targets -join ', '))

    #endregion

    #region collection --------------------------------------------------------

    $results = New-Object System.Collections.Generic.List[object]
    $first   = $true

    # A wall-clock budget, so a slow collection cannot overrun its own schedule
    # interval and collide with the next run. This bounds the work the script
    # does; it cannot interrupt a single store call that never returns, which
    # is what -ExecutionTimeLimit on the scheduled task is for.
    $deadline = $null
    if ($MaxRunMinutes -gt 0) { $deadline = (Get-Date).AddMinutes($MaxRunMinutes) }

    foreach ($db in $targets) {
        if ($null -ne $deadline -and (Get-Date) -gt $deadline) {
            Write-RunLog ('Run budget of {0} minute(s) is spent; database [{1}] was not collected.' -f $MaxRunMinutes, $db) 'ERROR'
            $script:BudgetExceeded = $true
            $script:FailedDbs.Add([string]$db)
            continue
        }

        if (-not $first -and $ThrottleDelaySeconds -gt 0) { Start-Sleep -Seconds $ThrottleDelaySeconds }
        $first = $false

        Write-RunLog ('Collecting mailbox statistics for database [{0}].' -f $db)

        $script:MailboxesSeen = 0
        $script:DeadlineHit   = $false
        $before = $results.Count

        # Streamed rather than collected with @(...). A production database can
        # hold tens of thousands of mailboxes, and materialising every
        # statistics object before the first one is examined puts the peak
        # memory of a scheduled monitoring task on the same server whose store
        # this script exists to protect.
        #
        # Two consequences of the child scope this introduces:
        #   - counters must be $script: scoped, or ++ writes a local copy
        #   - "continue" does not skip an item here; "return" exits the block
        try {
            Get-MailboxStatistics -Database $db -ErrorAction Stop | ForEach-Object {
                $script:MailboxesSeen++

                # Checked in batches: Get-Date on every mailbox would be its own
                # cost on a population this size.
                if ($null -ne $deadline -and -not $script:DeadlineHit -and
                    ($script:MailboxesSeen % 500) -eq 0 -and (Get-Date) -gt $deadline) {
                    $script:DeadlineHit = $true
                }
                if ($script:DeadlineHit) { return }

                $stat = $_

                # Assigned before the try so the catch cannot fault on an
                # unassigned variable and mask the original error.
                $displayName = '<unknown>'

                # Per-mailbox containment: one unparseable value must not
                # discard the other several thousand mailboxes on this database.
                try {
                    $displayName = [string](Get-SafeProperty $stat 'DisplayName')

                    if ($null -eq $stat.PSObject.Properties['BigFunnelPostingListTableTotalSize']) {
                        $script:PropertyMissing++
                        return
                    }
                    $raw = Get-SafeProperty $stat 'BigFunnelPostingListTableTotalSize'

                    $bytes = Convert-ExchangeSizeToBytes -SizeValue $raw
                    if ($null -eq $bytes) {
                        # Unlimited, or a property that is present but holds
                        # nothing. Dropped rather than recorded as zero, because
                        # a mailbox whose size cannot be read is not a mailbox of
                        # size zero and would otherwise land in the population
                        # the adaptive percentiles are computed from. Counted,
                        # though: without this the CSV is quietly shorter than
                        # the "database returned N mailbox(es)" line above it and
                        # nothing in the run accounts for the difference.
                        $script:NoSizeValue++
                        return
                    }

                    $lastLogon = Get-SafeProperty $stat 'LastLogonTime'

                    # Corroborating index counters. Without these, a 0 B posting
                    # list table cannot be told apart from a mailbox that simply
                    # has no index, and on a build that never populates the
                    # table the whole population reads as healthy.
                    $indexedCount = Get-SafeProperty $stat 'BigFunnelIndexedCount'
                    $poiBytes     = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'BigFunnelTotalPOISize')
                    $largePoi     = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'BigFunnelLargePOITableTotalSize')
                    $filterBytes  = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'BigFunnelFilterTableTotalSize')

                    # Where the index actually lives on builds that leave the
                    # posting list table empty. Summed only from the parts that
                    # parsed, so one absent property does not zero the total.
                    $payload = $null
                    foreach ($part in @($poiBytes, $largePoi, $filterBytes)) {
                        if ($null -ne $part) { $payload = [int64]$payload + [int64]$part }
                    }

                    $results.Add([pscustomobject]@{
                        # Round-trip format: unambiguous for any downstream
                        # parser regardless of the collecting server's locale.
                        Timestamp                          = (Get-Date).ToString('o')
                        Server                             = $script:ThisServer
                        Database                           = $db
                        DisplayName                        = $displayName
                        MailboxGuid                        = [string](Get-SafeProperty $stat 'MailboxGuid')
                        ItemCount                          = Get-SafeProperty $stat 'ItemCount'
                        TotalItemSize                      = [string](Get-SafeProperty $stat 'TotalItemSize')
                        BigFunnelPostingListTableTotalSize = [string]$raw
                        PostingListBytes                   = $bytes
                        PostingListGB                      = [math]::Round(($bytes / 1GB), 3)
                        # Assigned after collection: -ThresholdMode Adaptive
                        # needs the whole population before it can decide where
                        # the lines fall.
                        Status                             = $null
                        BigFunnelIsEnabled                 = Get-SafeProperty $stat 'BigFunnelIsEnabled'
                        BigFunnelIndexedCount              = $indexedCount
                        BigFunnelMessageCount              = Get-SafeProperty $stat 'BigFunnelMessageCount'
                        BigFunnelTotalPOISize              = [string](Get-SafeProperty $stat 'BigFunnelTotalPOISize')
                        BigFunnelLargePOITableTotalSize    = [string](Get-SafeProperty $stat 'BigFunnelLargePOITableTotalSize')
                        BigFunnelFilterTableTotalSize      = [string](Get-SafeProperty $stat 'BigFunnelFilterTableTotalSize')
                        IndexPayloadBytes                  = $payload
                        BigFunnelNotIndexedCount           = Get-SafeProperty $stat 'BigFunnelNotIndexedCount'
                        BigFunnelCorruptedCount            = Get-SafeProperty $stat 'BigFunnelCorruptedCount'
                        BigFunnelStaleCount                = Get-SafeProperty $stat 'BigFunnelStaleCount'
                        LastLogonTime                      = $(if ($lastLogon -is [datetime]) { $lastLogon.ToString('o') } else { [string]$lastLogon })
                        PreviousBytes                      = $null
                        DeltaBytes                         = $null
                        GrowthGBPerDay                     = $null
                        DaysToCritical                     = $null
                        Trend                              = $null
                        TrendWindowHours                   = $null

                        # Which counter the rate was taken from, and how large
                        # that counter reads on this mailbox. Both are needed
                        # together: a growth rate measured on the index payload
                        # printed beside PostingListGB produces lines reading
                        # "at 0 GB, growing 0.0161 GB/day", which is not a
                        # rounding artifact but two different counters set side
                        # by side as though they were one.
                        TrendMetric                        = $null
                        MeasuredGB                         = $null

                        SearchHealth                       = $null
                    })
                }
                catch {
                    $script:ParseFailures++
                    Write-RunLog ('Skipped mailbox [{0}] on [{1}]: {2}' -f $displayName, $db, $_.Exception.Message) 'WARN'
                }
            }

            if ($script:DeadlineHit) {
                Write-RunLog ('Run budget of {0} minute(s) is spent; [{1}] was cut short after {2} mailbox(es), {3} of which were recorded.' -f
                    $MaxRunMinutes, $db, $script:MailboxesSeen, ($results.Count - $before)) 'ERROR'
                $script:BudgetExceeded = $true
                $script:FailedDbs.Add([string]$db)
            }
            else {
                Write-RunLog ('Database [{0}] returned {1} mailbox(es).' -f $db, $script:MailboxesSeen)
            }
        }
        catch {
            Write-RunLog ('Failed to collect database [{0}] after {1} mailbox(es). {2}: {3}' -f
                $db, $script:MailboxesSeen, $_.Exception.GetType().Name, $_.Exception.Message) 'ERROR'
            $script:FailedDbs.Add([string]$db)

            # Streaming means a mid-enumeration failure leaves real rows already
            # collected. They are still valid observations, so keep them and
            # report the database as partial rather than discarding the work.
            if ($results.Count -gt $before) {
                Write-RunLog ('Keeping {0} row(s) collected from [{1}] before the failure.' -f ($results.Count - $before), $db) 'WARN'
            }
            continue
        }
    }

    if ($script:PropertyMissing -gt 0) {
        Write-RunLog ('{0} mailbox(es) did not expose BigFunnelPostingListTableTotalSize. Expected on Exchange 2019 and Exchange Server SE; absence across the whole population indicates an unsupported build.' -f $script:PropertyMissing) 'WARN'
    }
    if ($script:ParseFailures -gt 0) {
        Write-RunLog ('{0} mailbox(es) were skipped because their size value could not be parsed.' -f $script:ParseFailures) 'WARN'
    }
    if ($script:NoSizeValue -gt 0) {
        Write-RunLog ('{0} mailbox(es) were skipped because BigFunnelPostingListTableTotalSize held no readable value - Unlimited, or present but empty. They are absent from the detail below; do not read that as a size of zero.' -f $script:NoSizeValue) 'WARN'
    }

    #endregion

    #region thresholds --------------------------------------------------------

    $warningBytes   = [int64][math]::Floor($WarningGB * 1GB)
    $criticalBytes  = [int64][math]::Floor($CriticalGB * 1GB)
    $thresholdBasis = 'Fixed'

    if ($ThresholdMode -eq 'Adaptive') {
        if ($results.Count -lt $AdaptiveMinimumSample) {
            Write-RunLog ('Adaptive thresholds need at least {0} mailbox(es); {1} were collected, so the fixed values stand.' -f
                $AdaptiveMinimumSample, $results.Count) 'WARN'
        }
        else {
            $ascending = @($results | ForEach-Object { [int64]$_.PostingListBytes } | Sort-Object)
            $p95 = Get-Percentile -SortedValues $ascending -Percentile 95
            $p99 = Get-Percentile -SortedValues $ascending -Percentile 99

            # Adaptive only ever raises. The fixed values stay a floor, so a
            # healthy organization is unaffected and one whose tables all sit
            # high alerts on its outliers rather than on its whole population.
            $adaptiveWarning  = [int64][math]::Max([int64]$warningBytes,  [int64]$p95)
            $adaptiveCritical = [int64][math]::Max([int64]$criticalBytes, [int64]$p99)

            if ($adaptiveWarning -ge $adaptiveCritical) {
                # Happens when the population is tightly clustered and the two
                # percentiles land on the same value. A warning tier that can
                # never fire is worse than no adaptation.
                Write-RunLog ('Adaptive thresholds did not separate (P95 {0} GB, P99 {1} GB); the fixed values stand.' -f
                    [math]::Round($p95 / 1GB, 3), [math]::Round($p99 / 1GB, 3)) 'WARN'
            }
            else {
                $warningBytes   = $adaptiveWarning
                $criticalBytes  = $adaptiveCritical
                $thresholdBasis = 'Adaptive'
                Write-RunLog ('Adaptive thresholds from {0} mailbox(es): P95 {1} GB, P99 {2} GB.' -f
                    $results.Count, [math]::Round($p95 / 1GB, 3), [math]::Round($p99 / 1GB, 3))
            }
        }
    }

    Write-RunLog ('Thresholds in force ({0}): warning {1} GB, critical {2} GB.' -f
        $thresholdBasis, [math]::Round($warningBytes / 1GB, 3), [math]::Round($criticalBytes / 1GB, 3))

    foreach ($row in $results) {
        $row.Status = Get-PostingListStatus -Bytes ([int64]$row.PostingListBytes) `
            -WarningBytes $warningBytes -CriticalBytes $criticalBytes `
            -IndexedCount $row.BigFunnelIndexedCount
    }

    #endregion

    #region trend -------------------------------------------------------------

    # Which counter growth is measured on. PostingListBytes is the one the
    # thresholds describe, so it is preferred wherever it carries data.
    $trendMetric = 'PostingListBytes'

    # Whether a *date* can be put on that growth, as opposed to just an ordering.
    # The warning and critical thresholds are sizes of the posting list table and
    # nothing else. Measuring growth on a different counter and then
    # extrapolating it to those same thresholds compares two unrelated
    # quantities: on Exchange Server SE 15.2.2562.17 the index payload is
    # single-digit megabytes while the critical line is two gigabytes, so every
    # mailbox in the estate projects out to months and every lead-time window
    # discards all of them. The report that exists to say which mailbox is next
    # then produces nothing at all, on precisely the build the fallback was
    # written for. So on the fallback path this script ranks by rate and declines
    # to name a date, rather than extrapolating towards a line it has never
    # validated against this counter.
    $projectionApplies = $true

    $postingListPopulated = @($results | Where-Object { [int64]$_.PostingListBytes -gt 0 }).Count
    $payloadPopulated     = @($results | Where-Object {
        $null -ne $_.IndexPayloadBytes -and [int64]$_.IndexPayloadBytes -gt 0
    }).Count

    if ($postingListPopulated -eq 0 -and $payloadPopulated -gt 0) {
        $trendMetric       = 'IndexPayloadBytes'
        $projectionApplies = $false

        Write-RunLog ('BigFunnelPostingListTableTotalSize is 0 B for all {0} mailbox(es) in scope, so growth is being measured on IndexPayloadBytes instead. The ordering below is still meaningful - the mailbox at the top is genuinely the one growing fastest. No date is given: the warning and critical thresholds are sizes of the posting list table, they have never been validated against this counter, and a projection towards them would be arithmetic on two unrelated quantities. Use the ranking to decide what to look at first, and establish a threshold for this counter on your own estate before treating any of it as a deadline.' -f $results.Count) 'WARN'
    }

    # The warning threshold is only useful if it buys lead time, and lead time
    # requires two observations. Join against an earlier run to turn a point
    # reading into a growth rate.
    $baseline      = Get-PreviousRunBaseline -Path $OutputPath -ExcludeFile $csvPath -MinHours $TrendBaselineHours
    $baselineName  = ''
    $baselineHours = $null

    # Whether the join below actually ran. A baseline being found is not the same
    # thing: it can be found and then rejected for being too recent to divide by.
    # The reporting further down is gated on this rather than on $baseline, so
    # that a run which skipped trending entirely does not print an all-clear
    # about a measurement it never took.
    $trendComputed = $false

    if ($null -eq $baseline) {
        Write-RunLog 'No previous run found. Growth trending begins from the next run.'
    }
    else {
        $baselineName  = $baseline.Source
        $baselineHours = $baseline.AgeHours

        Write-RunLog ('Comparing against [{0}], {1} hour(s) earlier, {2} mailbox(es) baselined.' -f
            $baseline.Source, $baseline.AgeHours, $baseline.Sizes.Count)

        if (-not $baseline.MetMinimum) {
            Write-RunLog ('That window is short of the {0}-hour minimum, so the rates below are extrapolated from a narrow sample. Treat projections as provisional until the history is deeper.' -f $TrendBaselineHours) 'WARN'
        }

        if ($baseline.AgeHours -gt 0.01) {
            $trended   = 0
            $noReading = 0
            $tolerance = 1MB

            foreach ($row in $results) {
                $guid = [string]$row.MailboxGuid
                if ([string]::IsNullOrWhiteSpace($guid)) { continue }
                if (-not $baseline.Sizes.ContainsKey($guid)) { continue }

                if ($trendMetric -eq 'IndexPayloadBytes') {
                    $prev    = $baseline.Sizes[$guid].Payload
                    $current = $row.IndexPayloadBytes
                }
                else {
                    $prev    = $baseline.Sizes[$guid].Bytes
                    $current = $row.PostingListBytes
                }

                # Present in the baseline but with no reading for the chosen
                # counter - most often a baseline CSV written before this script
                # collected the payload at all. Skipped rather than treated as
                # zero, because a missing previous value coerced to 0 turns the
                # whole of the current size into one window's growth and parks
                # that mailbox at the top of the ranking for no reason.
                if ($null -eq $prev -or $null -eq $current) { $noReading++; continue }

                $delta  = [int64]$current - [int64]$prev
                $perDay = ($delta / $baseline.AgeHours) * 24.0

                $row.PreviousBytes    = [int64]$prev
                $row.DeltaBytes       = $delta
                $row.GrowthGBPerDay   = [math]::Round(($perDay / 1GB), 4)
                $row.TrendWindowHours = $baseline.AgeHours
                $row.TrendMetric      = $trendMetric
                $row.MeasuredGB       = [math]::Round(([int64]$current / 1GB), 3)

                # A direction, with tolerance so ordinary churn does not read as
                # a trend. Shrinking is the signal the runbook's post-
                # remediation cadence is actually asking for: confirmation that
                # the table came down and stayed down.
                if     ($delta -gt $tolerance)       { $row.Trend = 'Growing' }
                elseif ($delta -lt (0 - $tolerance)) { $row.Trend = 'Shrinking' }
                else                                 { $row.Trend = 'Flat' }

                # Skipped entirely when the rate came from a counter the
                # thresholds do not describe. Leaving DaysToCritical empty there
                # is the point: an empty column is read as "no projection", where
                # a number computed against the wrong threshold is read as a
                # deadline.
                if ($projectionApplies) {
                    if ($perDay -gt 0 -and [int64]$current -lt $criticalBytes) {
                        $row.DaysToCritical = [math]::Round((($criticalBytes - [int64]$current) / $perDay), 2)
                    }
                    elseif ([int64]$current -ge $criticalBytes) {
                        $row.DaysToCritical = 0
                    }
                }
                $trended++
            }
            $trendComputed = $true
            Write-RunLog ('Growth rate computed for {0} mailbox(es) on {1}.' -f $trended, $trendMetric)
            if ($noReading -gt 0) {
                Write-RunLog ('{0} mailbox(es) were in the baseline but carried no {1} reading there, so no rate could be derived for them. A baseline written by an earlier version of this script does not contain that column; the next run will not have this gap.' -f
                    $noReading, $trendMetric) 'WARN'
            }
        }
        else {
            Write-RunLog 'Previous run is too recent to derive a meaningful rate.' 'WARN'
        }
    }

    # Index health. Corrupted items are answerable from this run alone;
    # not-indexed and stale only as a direction of travel, so both cases go
    # through one call and the baseline is optional.
    foreach ($row in $results) {
        $previous = $null
        $guid     = [string]$row.MailboxGuid
        if ($null -ne $baseline -and -not [string]::IsNullOrWhiteSpace($guid) -and $baseline.Sizes.ContainsKey($guid)) {
            $previous = $baseline.Sizes[$guid]
        }
        $row.SearchHealth = Get-SearchHealth -Row $row -Previous $previous
    }

    #endregion

    #region output ------------------------------------------------------------

    # Critical must sort first. A single -Descending applied to both keys
    # orders Status reverse-alphabetically, which puts Critical last.
    # NotPopulated needs an explicit rank too: an unmapped status yields $null
    # from this hashtable, and $null sorts ahead of 0, which would float those
    # rows above Critical. It ranks below Warning because it is a statement
    # about the metric, not about the mailbox, but above Normal because it is
    # the one row type a reader must not skim past.
    $rank = @{ 'Critical' = 0; 'Warning' = 1; 'NotPopulated' = 2; 'Normal' = 3 }

    # The size key follows whichever counter is in use, for the same reason the
    # ranking below does. PostingListBytes is zero on every row of a 0 B build,
    # so sorting the export by it leaves each status group in collection order -
    # and this is the file the log points at for the detail it had to truncate.
    # Ordering it by the counter that actually varies is what makes that pointer
    # worth following.
    $sizeKey = if ($trendMetric -eq 'IndexPayloadBytes') { 'IndexPayloadBytes' } else { 'PostingListBytes' }

    $sorted = @($results | Sort-Object `
        @{ Expression = { $rank[[string]$_.Status] }; Descending = $false }, `
        @{ Expression = { [int64]$_.$sizeKey }; Descending = $true })

    try {
        $sorted | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-RunLog ('Exported {0} row(s) to [{1}].' -f $sorted.Count, $csvPath)
    }
    catch {
        # The CSV is the deliverable, so failing to write it is a real failure,
        # but the summary below is still worth emitting.
        Write-RunLog ('Failed to export CSV to [{0}]: {1}' -f $csvPath, $_.Exception.Message) 'ERROR'
        $exitCode = 2
    }

    $atRisk = @($sorted | Where-Object { $_.Status -in @('Warning', 'Critical') })
    $crit   = @($atRisk | Where-Object { $_.Status -eq 'Critical' })
    $notPop = @($sorted | Where-Object { $_.Status -eq 'NotPopulated' })

    Write-RunLog ('Summary: {0} mailbox(es) evaluated, {1} critical, {2} warning, {3} database(s) failed.' -f
        $sorted.Count, $crit.Count, ($atRisk.Count - $crit.Count), $script:FailedDbs.Count)

    # Denominator for the escalation below. Comparing against every collected
    # row looks right and is not: a real server carries health, arbitration,
    # system and archive mailboxes that hold no index at all, so they can never
    # be NotPopulated and they hold the ratio permanently below 1. Measured on
    # w25-ex01, 44 of 66 rows were in that category, which would have pinned a
    # total outage at WARN forever. Count only mailboxes that have an index,
    # because those are the only ones the posting list table could describe.
    $indexedPop = @($sorted | Where-Object {
        $c = ConvertTo-NullableInt64 $_.BigFunnelIndexedCount
        $null -ne $c -and $c -gt 0
    })

    # Loud on purpose. If the posting list table is empty across an indexed
    # population, every threshold in this script is being applied to a constant
    # zero, and a clean run means only that nothing could ever have been found.
    #
    # The flag is carried out of the block because it has to reach both the exit
    # code and the summary. Logging two ERROR lines and then reporting Status OK
    # with exit 0 is the same false negative NotPopulated was added to prevent,
    # moved one layer up: the CSV stops calling a blind mailbox healthy, and then
    # the run calls itself healthy anyway.
    $metricUnavailable = $false

    if ($notPop.Count -gt 0) {
        $total = $notPop.Count -ge $indexedPop.Count
        $metricUnavailable = $total
        $lvl   = if ($total) { 'ERROR' } else { 'WARN' }
        Write-RunLog ('{0} of {1} indexed mailbox(es) ({2} evaluated in total) report BigFunnelIndexedCount above zero while BigFunnelPostingListTableTotalSize reads 0 B. On those mailboxes the index is present but is not accounted for in the posting list table, so this run cannot speak to posting list growth. Verified on Exchange Server SE 15.2.2562.17, where the index sits in the POI and filter tables instead; see the IndexPayloadBytes column.' -f
            $notPop.Count, $indexedPop.Count, $sorted.Count) $lvl
        if ($total) {
            Write-RunLog 'Every indexed mailbox in scope is in this state, so no mailbox in this run could ever have crossed a threshold. Treat the thresholds here as untested, not as passed.' 'ERROR'
        }
    }

    if ($atRisk.Count -gt 0) {
        # Bounded. A badly affected server can hold thousands of at-risk
        # mailboxes, and one log line each would make the monitor its own
        # disk-space problem. The list is already sorted worst-first, so the
        # detail that survives the cap is the detail worth having.
        $shown = 0
        foreach ($r in $atRisk) {
            if ($shown -ge $MaxAlertDetail) { break }
            $shown++

            # Only project forward for mailboxes not already past the line;
            # "0 days to critical" reads as noise on something already critical.
            $trend = ''
            if ($null -ne $r.DaysToCritical -and $r.DaysToCritical -gt 0) {
                $trend = ', growing {0} GB/day, projected critical in {1} day(s)' -f $r.GrowthGBPerDay, $r.DaysToCritical
            }
            elseif ($null -ne $r.GrowthGBPerDay -and $r.GrowthGBPerDay -gt 0) {
                $trend = ', growing {0} GB/day' -f $r.GrowthGBPerDay
            }
            elseif ([string]$r.Trend -eq 'Shrinking') {
                $trend = ', shrinking since the baseline'
            }

            Write-RunLog ('{0}: [{1}] {2} on [{3}] at {4} GB{5}.' -f
                $r.Status, $r.MailboxGuid, $r.DisplayName, $r.Database, $r.PostingListGB, $trend) 'WARN'
        }
        if ($atRisk.Count -gt $shown) {
            Write-RunLog ('...and {0} further at-risk mailbox(es) not listed. Full detail is in [{1}].' -f
                ($atRisk.Count - $shown), $csvPath) 'WARN'
        }
        if ($ExitNonZeroOnAlert -and $exitCode -eq 0) { $exitCode = 1 }
    }

    # Emerging risk: still below the warning line, but trending into critical
    # inside the lead-time window the thresholds are meant to provide.
    $emerging = @($sorted | Where-Object {
        $_.Status -eq 'Normal' -and $null -ne $_.DaysToCritical -and $_.DaysToCritical -le 3
    })
    $shown = 0
    foreach ($r in $emerging) {
        if ($shown -ge $MaxAlertDetail) { break }
        $shown++
        Write-RunLog ('Emerging: [{0}] {1} on [{2}] is {3} GB but projected critical in {4} day(s).' -f
            $r.MailboxGuid, $r.DisplayName, $r.Database, $r.PostingListGB, $r.DaysToCritical) 'WARN'
    }
    if ($emerging.Count -gt $shown) {
        Write-RunLog ('...and {0} further emerging mailbox(es) not listed.' -f ($emerging.Count - $shown)) 'WARN'
    }

    # The same question the emerging report answers - of everything in scope,
    # which mailbox is next - asked where no date can be put on the answer.
    # Emerging is keyed on DaysToCritical, which is deliberately left empty when
    # the rate came from a counter the thresholds do not describe, so on a 0 B
    # build that report is silent no matter how fast the index is growing. This
    # ranks instead: fastest first, which is the order in which these mailboxes
    # become someone's problem even though the run cannot say when.
    #
    # Filtered on Trend rather than on the raw rate, so the same 1 MB tolerance
    # that keeps ordinary churn out of the trend column keeps it out of this list
    # too. Gated on $trendComputed as well as on the metric, so a run that never
    # derived a rate stays silent here rather than reporting that nothing grew.
    $growing = @()
    if (-not $projectionApplies -and $trendComputed) {
        $growing = @($sorted | Where-Object {
            [string]$_.Trend -eq 'Growing' -and
            $null -ne $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0
        } | Sort-Object @{ Expression = { [double]$_.GrowthGBPerDay } } -Descending)

        if ($growing.Count -gt 0) {
            Write-RunLog ('{0} mailbox(es) grew over the {1}-hour window, measured on {2}. They are ranked fastest first below. No projected date is given, for the reason logged above; treat this as the order to work through, not a countdown.' -f
                $growing.Count, $baselineHours, $trendMetric) 'WARN'

            $shown = 0
            foreach ($r in $growing) {
                if ($shown -ge $MaxAlertDetail) { break }
                $shown++
                Write-RunLog ('Fastest growing #{0}: [{1}] {2} on [{3}] at {4} GB, growing {5} GB/day on {6}.' -f
                    $shown, $r.MailboxGuid, $r.DisplayName, $r.Database, $r.MeasuredGB, $r.GrowthGBPerDay, $trendMetric) 'WARN'
            }
            if ($growing.Count -gt $shown) {
                Write-RunLog ('...and {0} further growing mailbox(es) not listed. Full detail is in [{1}].' -f
                    ($growing.Count - $shown), $csvPath) 'WARN'
            }
        }
        else {
            Write-RunLog ('No mailbox grew measurably on {0} over the {1}-hour window.' -f $trendMetric, $baselineHours)
        }
    }

    # The runbook's post-remediation cadence asks operators to confirm the
    # table does not rebound. That question needs a shrink signal, not just a
    # size reading.
    $shrinking = @($sorted | Where-Object { [string]$_.Trend -eq 'Shrinking' })
    if ($shrinking.Count -gt 0) {
        Write-RunLog ('{0} mailbox(es) shrank since the baseline, the expected signal after remediation.' -f $shrinking.Count)
    }

    $healthIssues = @($sorted | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.SearchHealth) -and [string]$_.SearchHealth -ne 'OK'
    })
    if ($healthIssues.Count -gt 0) {
        $shown = 0
        foreach ($r in $healthIssues) {
            if ($shown -ge $MaxAlertDetail) { break }
            $shown++
            Write-RunLog ('SearchHealth: [{0}] {1} on [{2}] - {3}.' -f
                $r.MailboxGuid, $r.DisplayName, $r.Database, $r.SearchHealth) 'WARN'
        }
        if ($healthIssues.Count -gt $shown) {
            Write-RunLog ('...and {0} further mailbox(es) with index-health flags.' -f ($healthIssues.Count - $shown)) 'WARN'
        }
        # Deliberately does not move the exit code: table size and index health
        # are separate problems with separate remediations, and quietly
        # redefining what a non-zero exit means would break existing alerting.
        Write-RunLog 'Index-health flags are reported for triage and do not change the exit code.'
    }

    if ($script:FailedDbs.Count -gt 0) {
        Write-RunLog ('Partial results. Not collected: {0}' -f ($script:FailedDbs -join ', ')) 'ERROR'
        $exitCode = 2
    }

    # After the partial-failure check so 2 wins: a run that could not collect a
    # database has a bigger problem than one that collected everything and found
    # the counter empty. Gated on -ExitNonZeroOnAlert for the same reason 1 is -
    # at defaults this script returns 0 for anything short of a breakage and
    # reports through latest-summary.json - but a caller that asked for alert
    # exit codes asked for this one too. "The metric is blind" is the alert.
    if ($metricUnavailable -and $ExitNonZeroOnAlert -and $exitCode -eq 0) {
        $exitCode = 5
    }

    if (Test-Path -LiteralPath $csvPath) {
        try { Copy-Item -LiteralPath $csvPath -Destination $latestCsv -Force -ErrorAction Stop }
        catch { Write-RunLog ('Could not refresh [{0}]: {1}' -f $latestCsv, $_.Exception.Message) 'WARN' }
    }

    Write-RunSummary -Path $latestJson -Values @{
        RunId                = $runId
        DurationSeconds      = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
        Scope                = $Scope
        ExchangeVersion      = $(if ($build.Known) { [string]$build.Version } else { '' })
        Completed            = $true
        # Ungated, unlike the exit code above. Status describes the run rather
        # than signalling it, and a caller reading this file is entitled to know
        # the metric was blind whether or not it asked for alert exit codes.
        # Ordered worst-first: a database that was never collected outranks a
        # counter that read zero, because the second is at least a complete run.
        Status               = $(if ($exitCode -eq 2) { 'Partial' } elseif ($metricUnavailable) { 'MetricUnavailable' } else { 'OK' })
        ThresholdMode        = $ThresholdMode
        ThresholdBasis       = $thresholdBasis
        WarningGB            = [math]::Round($warningBytes / 1GB, 3)
        CriticalGB           = [math]::Round($criticalBytes / 1GB, 3)
        ConfiguredWarningGB  = $WarningGB
        ConfiguredCriticalGB = $CriticalGB
        DatabasesInScope     = $targets.Count
        DatabasesFailed      = $script:FailedDbs.Count
        FailedDatabases      = ($script:FailedDbs -join ', ')
        RunBudgetExceeded    = $script:BudgetExceeded
        MailboxesEvaluated   = $sorted.Count
        Critical             = $crit.Count
        Warning              = ($atRisk.Count - $crit.Count)
        Emerging             = $emerging.Count
        Shrinking            = $shrinking.Count
        SearchHealthIssues   = $healthIssues.Count
        NotPopulated         = $notPop.Count
        SkippedUnparseable   = $script:ParseFailures
        SkippedNoSize        = $script:NoSizeValue
        MissingProperty      = $script:PropertyMissing
        TrendBaseline        = $baselineName
        TrendWindowHours     = $baselineHours
        TrendMetric          = $trendMetric
        Growing              = $growing.Count
        DetailCsv            = $csvPath
        ExitCode             = $exitCode
    }
    if ($script:SummaryWritten) { Write-RunLog ('Wrote run summary to [{0}].' -f $latestJson) }

    Remove-ExpiredOutput -Path $OutputPath -Days $RetentionDays
    Write-RunLog ('Monitor run complete. Exit code {0}.' -f $exitCode)

    #endregion
}
catch {
    # Anything unanticipated still produces a log line and a distinct exit
    # code rather than an opaque stack trace in the task history.
    Write-RunLog ('Unhandled failure: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message) 'FATAL'
    Write-RunLog ('At: {0}' -f $_.ScriptStackTrace) 'FATAL'
    $abortReason = ('{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message)
    $exitCode = 3
}
finally {
    # Reached on exit as well as on a fall-through, so every abort inside the
    # try lands here. Without this, a run that failed pre-flight would leave
    # the previous run's summary untouched and a monitoring agent would keep
    # reporting the last healthy result while the monitor was dead.
    if (-not $script:SummaryWritten) {
        Write-RunSummary -Path $latestJson -Values @{
            RunId                = $runId
            DurationSeconds      = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
            Scope                = $Scope
            Completed            = $false
            Status               = $(if ([string]::IsNullOrWhiteSpace($abortReason)) { 'Aborted' } else { $abortReason })
            # Carried onto the abort path too. Most aborts happen after the
            # build has been read, and dropping it here forces whoever triages
            # the alert back onto the log to answer the first question they will
            # ask. $build is $null only if the abort preceded the probe.
            ExchangeVersion      = $(if ($null -ne $build -and $build.Known) { [string]$build.Version } else { '' })
            ThresholdMode        = $ThresholdMode
            ConfiguredWarningGB  = $WarningGB
            ConfiguredCriticalGB = $CriticalGB
            DatabasesFailed      = $script:FailedDbs.Count
            FailedDatabases      = ($script:FailedDbs -join ', ')
            RunBudgetExceeded    = $script:BudgetExceeded
            SkippedUnparseable   = $script:ParseFailures
            MissingProperty      = $script:PropertyMissing
            ExitCode             = $exitCode
        }
    }

    if ($null -ne $mutex) {
        if ($holding) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

exit $exitCode
