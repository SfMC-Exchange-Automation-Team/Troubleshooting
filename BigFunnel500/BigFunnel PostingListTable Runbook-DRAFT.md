# Troubleshoot Exchange Search Issues Related to BigFunnel Mailbox Search Metadata Growth

**Applies to:** Exchange Server Subscription Edition, Exchange Server 2019

## Summary

In on-premises Exchange Server environments, search operations on mailboxes with oversized BigFunnel search metadata can cause prolonged mailbox unavailability, mail delivery delays, and shared mailbox access failures.

The primary indicator is the `BigFunnelPostingListTableTotalSize` property exposed through `Get-MailboxStatistics`. When this value grows significantly, generic or broad search queries may hold mailbox-level resources for extended periods, blocking other operations until the search completes or the database is switched over to another server.

The core operational model separates two remediation patterns:

| Situation | Primary action | Rationale |
|---|---|---|
| Users actively blocked; mail delivery queuing with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy` | Database switchover using `Move-ActiveMailboxDatabase` | Restores user access by moving the active database copy to another server, but does not reduce `BigFunnelPostingListTableTotalSize` |
| `BigFunnelPostingListTableTotalSize` at an elevated threshold with no active user impact | Collect diagnostics, reduce mailbox content, then schedule a mailbox move | A mailbox move may rebuild search metadata structures on the destination, potentially reducing the table size |
| Many mailboxes above threshold | Monitor, prioritize, and batch moves under change control | Exchange Server 2019 workload management (WLM) throttling defaults to 10 simultaneous mailbox moves from the same source or to the same target; batching and automation are required at scale |

> [!IMPORTANT]
> Database switchover is a **database-scoped** operation. Exchange Server does not support failing over an individual mailbox; all failover actions occur at the database level.

## Table of contents

- [Symptoms](#symptoms)
- [Cause](#cause)
- [Detection and monitoring](#detection-and-monitoring)
- [Monitoring automation](#monitoring-automation)
- [Resolution](#resolution)
- [Database failover vs. mailbox move](#database-failover-vs-mailbox-move)
- [Database isolation strategy](#database-isolation-strategy)
- [Concurrency and WLM throttling](#concurrency-and-wlm-throttling)
- [Automated remediation strategy](#automated-remediation-strategy)
- [Operator decision flow](#operator-decision-flow)
- [Operational guardrails and best practices](#operational-guardrails-and-best-practices)
- [Related articles](#related-articles)

## Symptoms

Users may report one or more of the following symptoms, especially on shared mailboxes:

- Search-driven mailbox unavailability: users cannot open on-premises shared mailboxes, or the mailbox becomes unresponsive during or immediately after a search operation.
- "This server is too busy and cannot respond" error in Outlook or Outlook on the web (OWA).
- HTTP 500 errors during search on shared mailboxes in OWA.
- Mail delivery delays or queuing, with transport logs showing `432 4.3.2 STOREDRV.Storage; mailbox server is too busy`.
- Search hangs or long delays in Outlook online mode or OWA when using broad or generic search terms.

These symptoms can persist for hours until either the search operation completes or the database is switched over to another server.

## Cause

Exchange Server 2019 and Exchange Server SE use BigFunnel as the native full-text indexing subsystem integrated into the Exchange Information Store. BigFunnel maintains several per-mailbox data structures to support search, including a Posting List Table that provides full-text search capability for larger mailboxes.

When the Posting List Table grows significantly beyond its intended operating range, broad search queries can trigger long-running decode and evaluation operations that hold mailbox-level resources. During this time, other operations against the mailbox, including mail delivery and client access, may be blocked.

Key characteristics of this issue:

- Mailbox size alone is not the determining factor. A relatively small mailbox can have a large `BigFunnelPostingListTableTotalSize` depending on the mailbox's content shape, folder structure, and search behavior.
- Shared mailboxes are disproportionately affected because multiple concurrent users searching broadly amplify the likelihood of triggering the condition.
- Database failover restores access but does not reduce the table size. Observed behavior showed that a database availability group (DAG) switchover preserved the table at approximately the same size, such as 12 GB before switchover and approximately 11.5 GB after switchover. This confirms that switchover releases the lock but does not rebuild the search metadata.
- Mailbox moves may rebuild the search structures, but the degree of reduction varies. In one observed case, a mailbox move caused the BigFunnel table to fully reduce and begin rebuilding. In another case, the move reduced `BigFunnelPostingListTableTotalSize` from 6.607 GB to 5.32 GB.

## Detection and monitoring

### Primary metric

The primary metric is `BigFunnelPostingListTableTotalSize`, collected through the `Get-MailboxStatistics` cmdlet, which returns information about a mailbox including size, message count, and last access time.

```powershell
Get-MailboxStatistics -Identity "<MailboxIdentity>" |
    Format-List DisplayName, Database, TotalItemSize, ItemCount, BigFunnel*
```

For database-wide assessment:

```powershell
Get-MailboxStatistics -Database "<DatabaseName>" |
    Where-Object { $_.BigFunnelPostingListTableTotalSize -ne $null } |
    Sort-Object BigFunnelPostingListTableTotalSize -Descending |
    Select-Object DisplayName, MailboxGuid, ItemCount, TotalItemSize,
        BigFunnelPostingListTableTotalSize |
    Format-Table -AutoSize
```

`Get-MailboxStatistics` requires at least one of the following parameters: `Server`, `Database`, or `Identity`.

### Confirm the metric is populated before you trust it

A `0 B` reading of `BigFunnelPostingListTableTotalSize` is ambiguous, and the ambiguity matters more than the value. It can mean the mailbox is genuinely small, or it can mean the counter is not being populated on that build - and those two look identical in the output. Confirm which one you are looking at before concluding that a mailbox, or a database, is healthy.

On a lab running Exchange Server SE RTM (`15.2.2562.17`), a mailbox seeded with 200 messages drawn from a 40,000-term vocabulary reported:

| Property | Value |
|---|---|
| `BigFunnelIsEnabled` | `True` |
| `BigFunnelIndexedCount` | `200` |
| `BigFunnelIndexedSize` | `5.7 MB (5,976,557 bytes)` |
| `BigFunnelPostingListTableTotalSize` | `0 B (0 bytes)` |
| `BigFunnelPostingListTableAvailableSize` | `0 B (0 bytes)` |
| `BigFunnelTotalPOISize` | `1.427 MB` |
| `BigFunnelLargePOITableTotalSize` | `2.156 MB` |
| `BigFunnelFilterTableTotalSize` | `544 KB` |

The index was live: `Search-Mailbox -EstimateResultOnly` for a term appearing only in the seeded message bodies returned a hit. The zero was genuine rather than a formatting or parsing artifact - the returned object reported `IsUnlimited` as `False` and its `ToBytes()` method returned integer `0` - and it did not change over a four-minute observation window. `BigFunnelPostingListTableChunkCount` and `BigFunnelLargePostingListTableTotalSize` were not present on the statistics object at all. Roughly 4.1 MB of index payload existed and was accounted for in the POI and filter tables. Note that `BigFunnelPostingListTableAvailableSize` also read `0 B`, where the corresponding large-POI counter reported 736 KB of free space: the table is not an allocated structure that happens to be empty.

Two explanations fit that result, and the lab could not separate them: the build may account for posting list data elsewhere regardless of content volume, or the counter may materialize only above an allocation threshold that 5.75 MB of content does not reach. Both carry the same consequence for monitoring, so read a zero against the corroborating counters rather than on its own:

| Reading | Interpretation | Action |
|---|---|---|
| `BigFunnelPostingListTableTotalSize` above `0 B` | The metric is populated on this build | Apply the thresholds in the next section |
| `0 B`, with `BigFunnelIndexedCount` at `0` | The mailbox has no index yet | Investigate indexing; this is not a table-growth question |
| `0 B`, with `BigFunnelIndexedCount` above `0` | The mailbox is indexed but the size is not accounted for in this counter | Do not read this as healthy. Check `BigFunnelTotalPOISize`, `BigFunnelLargePOITableTotalSize`, and `BigFunnelFilterTableTotalSize` for where the index size actually is |

> [!IMPORTANT]
> If every mailbox on a database reports `0 B` while reporting a non-zero `BigFunnelIndexedCount`, threshold alerting on this metric cannot fire there. A clean monitoring run then says nothing about posting list growth - it says only that nothing could have been found. Validate the counter against at least one mailbox known to exhibit the problem before treating an absence of alerts as evidence of health. The monitoring script in the next section reports this case as a distinct `NotPopulated` status rather than as `Normal`, precisely so that it cannot be mistaken for a pass.

When you judge how widespread the condition is, count it against the mailboxes that have an index, not against every row `Get-MailboxStatistics` returns. Health, arbitration, system and archive mailboxes hold no BigFunnel index at all and cannot exhibit the condition; on the lab server above they were 44 of 66 rows. A ratio taken over all rows therefore understates the problem badly and can never reach 100%, even when every mailbox capable of exhibiting it does.

### Detection signals

| Detection area | Signal | Collection method |
|---|---|---|
| User experience | Outlook / OWA search hangs; "server too busy" or 500 errors; shared mailbox cannot be opened | Incident reports, client-side reproduction, OWA HTTP Archive (HAR) capture |
| Transport / Store | Mail delivery queues with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy` | Transport queue monitoring, Store event logs |
| Search test | `Test-ExchangeSearch` shows timeout or failure | Run `Test-ExchangeSearch -Identity "<MailboxIdentity>" -Verbose`; the cmdlet creates a hidden test message, waits for indexing, then searches for it |
| BigFunnel metric | `BigFunnelPostingListTableTotalSize` elevated or growing | `Get-MailboxStatistics -Identity "<MailboxIdentity>" \| Format-List BigFunnel*` |
| Scale assessment | Multiple mailboxes with elevated values on the same database or DAG | Aggregate `Get-MailboxStatistics -Database "<DatabaseName>"` filtered by threshold |

### Monitoring thresholds

The following thresholds are operational examples derived from observed environments. They are not official Exchange Server product limits. Adjust them based on the growth rate and impact patterns observed in your environment.

| Level | Example threshold | Operator action |
|---|---:|---|
| Normal | Below approximately 1.7 GB and not growing measurably | Continue periodic monitoring |
| Emerging | Below approximately 1.7 GB, but growing fast enough to reach approximately 2.0 GB within 3 days | Treat as a warning. A mailbox climbing 0.3 GB per day crosses both thresholds between two daily samples, so size alone would never raise it in time |
| Warning | At or above approximately 1.7 GB | Start proactive review; confirm growth rate; identify mailbox owner; plan content cleanup or move. This example warning value was chosen to provide approximately three days of lead time before potential user impact in the observed environment |
| Critical | At or above approximately 2.0 GB | Treat as high risk for search-related user impact; collect diagnostics; prepare remediation |
| Not populated | Exactly `0 B`, with `BigFunnelIndexedCount` above 0 | The rows above cannot be evaluated for this mailbox. Do not record it as Normal. Read the index size from `BigFunnelTotalPOISize`, `BigFunnelLargePOITableTotalSize`, and `BigFunnelFilterTableTotalSize`, and rely on the symptom-side signals until the counter is confirmed to populate on your build |

> [!IMPORTANT]
> The three days of lead time in the warning row is a claim about a *rate*, not about a size. It holds only for the growth rate observed in the environment the threshold was derived from. A single reading of `BigFunnelPostingListTableTotalSize` cannot tell you how much time you have; it takes two readings separated by a known interval. Compare each collection against an earlier one and derive gigabytes per day before relying on the lead time. The monitoring script below does this and reports both the rate and the projected days to the critical threshold.

> [!NOTE]
> Mailbox size alone is not the deciding factor. A mailbox can be relatively small and still have `BigFunnelPostingListTableTotalSize` well above these thresholds depending on its content shape, item count, folder structure, and search patterns.

### Recommended monitoring cadence

| Population | Cadence | Notes |
|---|---|---|
| Known impacted or high-risk databases | Every 4 hours | Aligns with the BigFunnel internal time-based assistant (TBA) retry cycle |
| Business-critical shared mailboxes | Every 4 hours | Use the warning threshold to create lead time before user impact |
| General shared mailboxes | Daily | Escalate to 4-hour cadence if growth accelerates |
| Post-remediation mailboxes | Daily for 7 days | Confirm the table does not rebound quickly after remediation |

### BigFunnel health signals beyond PostingListTable size

When evaluating mailbox search health, review additional BigFunnel properties. Two of the three are only meaningful as a change between two collections, so record them alongside the size on every run rather than reading them once:

| Signal | Expected condition | How to evaluate |
|---|---|---|
| `BigFunnelNotIndexedCount` | Should trend low or decreasing | Compare against the previous collection for the same mailbox. A rising count means indexing is falling behind ingestion. A single high reading on a newly migrated mailbox is normal and should fall on its own |
| `BigFunnelCorruptedCount` | Should be 0; moving the mailbox to another database has been observed to reset this value to 0 | Meaningful on its own, with no baseline. Any non-zero value warrants investigation |
| `BigFunnelStaleCount` | Should not be growing | Compare against the previous collection. Growth here indicates items whose index entries no longer match the item |

> [!NOTE]
> These counters describe index *health*; `BigFunnelPostingListTableTotalSize` describes index *size*. They are separate problems with separate remediations, and a mailbox can be bad on one and fine on the other. Keep them separate in alerting rather than folding them into one health score.

## Monitoring automation

The following script collects `BigFunnelPostingListTableTotalSize` for all mailboxes on specified databases, evaluates configurable thresholds, and exports results to CSV.

From its second run onwards it also compares each mailbox against an earlier collection, derives a growth rate, and ranks the mailboxes that are not yet over the threshold by how soon they are projected to cross it. On builds where the posting list table reads `0 B` it still ranks them, by growth rate, without projecting a date. See [Ranking mailboxes by how soon they cross](#ranking-mailboxes-by-how-soon-they-cross) for how to read that output.

Run it in Exchange Management Shell or a PowerShell session where Exchange cmdlets are available. The script is compatible with Windows PowerShell 5.1.

> [!NOTE]
> This script uses CSV export for alerting output. The `Send-MailMessage` cmdlet is obsolete and Microsoft recommends not using it because it does not guarantee secure connections to SMTP servers. Integrate the CSV output with your organization's approved monitoring or alerting platform.

```powershell
<#
.SYNOPSIS
Monitors BigFunnelPostingListTableTotalSize for Exchange mailboxes.

.DESCRIPTION
Collects Get-MailboxStatistics output by database, converts
BigFunnelPostingListTableTotalSize to bytes, evaluates warning and critical
thresholds, and exports CSV results.

.NOTES
Windows PowerShell 5.1 compatible.

Run with an account that has Exchange RBAC permissions to run:
- Get-MailboxDatabase
- Get-MailboxStatistics
#>

[CmdletBinding()]
param(
    [string[]]$Databases,
    [double]$WarningGB = 1.7,
    [double]$CriticalGB = 2.0,
    [string]$OutputPath = (Join-Path $env:ProgramData "ExchangeBigFunnelPostingListMonitor"),

    # Long enough to cover a holiday weekend plus the time it takes anyone to
    # notice, so the run that first crossed a threshold is still on disk when
    # someone comes to look for it. Set to 0 to keep everything.
    [int]$RetentionDays = 30,

    # How far back to reach for the comparison run. A short window magnifies
    # noise: at a 15-minute cadence a delta is multiplied by 96 to reach a
    # per-day rate, so a few megabytes of ordinary churn reads as a growth trend
    # and the projection swings from run to run. A day of separation is enough
    # for the rate to mean something. If the history is not yet that deep the
    # widest available window is used instead, and the run says so.
    #
    # Validated rather than merely defaulted. A zero or negative window is not a
    # narrower version of this feature, it is a division by zero or a rate with
    # the sign flipped, and either produces a confident ranking that is simply
    # wrong. Failing at bind time is the honest response to a value the script
    # cannot act on.
    [ValidateRange(1, 8760)]
    [int]$TrendBaselineHours = 24,

    # How far ahead the "next to cross" list looks. Two weeks is chosen to be
    # longer than the gap between one working Friday and the next, so a mailbox
    # cannot appear and cross inside a single unattended weekend.
    [ValidateRange(1, 3650)]
    [int]$ProjectionHorizonDays = 14,

    # Caps the per-mailbox detail written to the log. An estate with thousands
    # of affected mailboxes would otherwise make the monitor its own disk-space
    # problem. Every list capped by this is sorted worst-first, so what survives
    # the cap is the part worth reading; the full set is always in the CSV.
    #
    # Zero is legal and means "counts only, no per-mailbox lines" - a reasonable
    # ask when the log is being shipped somewhere with a size budget. Negative
    # is not: Select-Object -First rejects it and the run dies at the point it
    # would otherwise have reported its findings.
    [ValidateRange(0, 100000)]
    [int]$MaxAlertDetail = 20
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} [{1}] {2}" -f $timestamp, $Level, $Message

    Write-Verbose $line

    if (-not (Test-Path -LiteralPath $script:OutputPath)) {
        New-Item -Path $script:OutputPath -ItemType Directory -Force | Out-Null
    }

    # UTF8 on both writers. Windows PowerShell 5.1 defaults Export-Csv to ASCII
    # and Add-Content to the ANSI code page, either of which mangles a display
    # name outside the local codepage - and a mailbox name is exactly the field
    # someone needs to be able to copy out of the report and search for.
    # Best effort, and deliberately so. $ErrorActionPreference is Stop, so an
    # unguarded Add-Content turns any transient lock on the log into an uncaught
    # terminating error: the run exits 1, which is not a code the scheduling
    # section tells anyone to alert on, and it never reaches Exit-MonitorRun, so
    # the lock is released as abandoned. A backup agent, an anti-virus scanner or
    # an operator with the file open in an editor is enough to trigger it. Losing
    # a log line is a much smaller problem than losing the run writing it.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -eq 3) {
                # stderr is the only channel left. A scheduled task discards it,
                # but a wrapper that redirects it will capture both the line that
                # could not be written and the reason.
                Write-Warning ("Could not write to the run log: {0}" -f $_.Exception.Message)
                Write-Warning $line
                return
            }
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
}

function Initialize-ExchangeShell {
    [CmdletBinding()]
    param()

    Write-Verbose "Checking whether Exchange cmdlets are available."

    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        Write-Verbose "Get-MailboxStatistics not found. Attempting to load Exchange snap-in."
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue
    }

    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        throw "Get-MailboxStatistics is not available. Run from Exchange Management Shell or load the Exchange tools."
    }

    Write-Verbose "Exchange cmdlets are available."
}

function Convert-ExchangeSizeToBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $SizeValue
    )

    Write-Verbose ("Converting size value [{0}] to bytes." -f $SizeValue)

    if ($null -eq $SizeValue) {
        return $null
    }

    # Get-MailboxStatistics returns Unlimited<ByteQuantifiedSize>, which is a
    # wrapper. Test the wrapper first, because ToBytes() lives on the inner
    # ByteQuantifiedSize and never on the wrapper itself.
    if ($SizeValue.PSObject.Properties.Name -contains "IsUnlimited") {
        if ($SizeValue.IsUnlimited) {
            return $null
        }

        $SizeValue = $SizeValue.Value

        if ($null -eq $SizeValue) {
            return $null
        }
    }

    # Exchange ByteQuantifiedSize objects usually expose ToBytes().
    if ($SizeValue.PSObject.Methods.Name -contains "ToBytes") {
        try {
            return [int64]$SizeValue.ToBytes()
        }
        catch {
            # Fall through to the text parsers below.
        }
    }

    $text = [string]$SizeValue

    # Catches both a literal string and any object whose ToString() is
    # "Unlimited", regardless of how it was reached.
    if ($text -match "Unlimited") {
        return $null
    }

    # Common Exchange string format: 1.7 GB (1,825,361,920 bytes)
    if ($text -match "\(([0-9,]+)\s+bytes\)") {
        return [int64](($matches[1]) -replace ",", "")
    }

    # Fallback parser for values such as "1.7 GB", "900 MB", "512 KB".
    # Parsed with the invariant culture: Exchange renders sizes with an
    # invariant separator, so a comma-decimal locale would otherwise misread
    # them.
    if ($text -match "^\s*([0-9.]+)\s*(B|KB|MB|GB|TB)\s*$") {
        $number = [double]::Parse($matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
        $unit = $matches[2].ToUpperInvariant()

        switch ($unit) {
            "B"  { return [int64]$number }
            "KB" { return [int64]($number * 1KB) }
            "MB" { return [int64]($number * 1MB) }
            "GB" { return [int64]($number * 1GB) }
            "TB" { return [int64]($number * 1TB) }
        }
    }

    # Returns $null rather than throwing. A throw here is caught by the
    # per-database handler in the collection loop, which abandons the rest of
    # that database - so one mailbox with an unreadable value would silently
    # drop every mailbox enumerated after it, and the run would still report as
    # having collected the database. The caller logs the skip instead.
    return $null
}

function Get-PostingListStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Bytes,

        [Parameter(Mandatory = $true)]
        [int64]$WarningBytes,

        [Parameter(Mandatory = $true)]
        [int64]$CriticalBytes,

        # Deliberately untyped. Windows PowerShell 5.1 cannot bind $null to an
        # [int64] parameter, and this arrives as $null on any build that does
        # not expose the counter.
        $IndexedCount = $null
    )

    if ($Bytes -ge $CriticalBytes) {
        return "Critical"
    }

    if ($Bytes -ge $WarningBytes) {
        return "Warning"
    }

    # A mailbox that reports indexed items while reporting 0 B here is not
    # small; the size is not being accounted for in this counter. Returning
    # "Normal" would make that indistinguishable from a healthy mailbox, and on
    # a build that never populates the table every mailbox would read healthy
    # and the monitor would never alert.
    $indexed = $null
    if ($null -ne $IndexedCount) {
        $parsed = New-Object System.Int64
        if ([int64]::TryParse([string]$IndexedCount, [ref]$parsed)) {
            $indexed = $parsed
        }
    }

    if ($Bytes -eq 0 -and $null -ne $indexed -and $indexed -gt 0) {
        return "NotPopulated"
    }

    return "Normal"
}

function Get-StatisticProperty {
    # Set-StrictMode 2.0 turns any access to an absent property into a
    # terminating error, and Get-MailboxStatistics does not return a uniform
    # shape across builds and mailbox states.
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-NullableInt64 {
    # CSV round-trips every value as text, and a blank or absent cell has to come
    # back as $null rather than 0. Zero is a real and different reading here: it
    # means "this mailbox has an empty posting list table", which is precisely
    # the state the NotPopulated status exists to flag. Coercing a missing value
    # to 0 would manufacture a growth spike out of an absent baseline.
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()

    if ($text.Length -eq 0) {
        return $null
    }

    $parsed = [int64]0

    if ([int64]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $null
}

function Get-PreviousRunBaseline {
    # A threshold is only worth having if it buys lead time, and lead time needs
    # two observations. This finds an earlier run of this same script and returns
    # its per-mailbox sizes, so this run's reading can become a rate of change.
    #
    # The run ID in each file name is yyyyMMdd-HHmmss followed by the process id,
    # so lexical order is chronological and the timestamp parses without
    # consulting the current culture. That is deliberately more robust than
    # reading a datetime back out of the CSV body, where it is subject to
    # whatever culture wrote it.
    #
    # The process id is optional in the pattern rather than required, and both
    # halves of that matter. It has to be allowed, or this silently finds no
    # baseline at all and the script reports "no earlier run found" forever,
    # which is indistinguishable from a genuine first run. It has to stay
    # optional, because runs written before the process id was introduced are
    # still on disk and are still perfectly good baselines.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExcludeFile,
        [int]$MinHours = 24
    )

    $now        = Get-Date
    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter "BigFunnelPostingListMonitor-*.csv" -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -ne $ExcludeFile })) {

        if ($file.BaseName -notmatch "(\d{8}-\d{6})(?:-\d+)?$") { continue }

        $stamp  = New-Object DateTime
        $parsed = [datetime]::TryParseExact(
            $matches[1], "yyyyMMdd-HHmmss",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$stamp)

        if (-not $parsed) { continue }

        # A file stamped in the future is a clock change or a copied file, not a
        # baseline. Using one would produce a negative window and invert every
        # projection derived from it.
        if ($stamp -ge $now) { continue }

        $candidates.Add([pscustomobject]@{
            File  = $file
            Stamp = $stamp
            Age   = ($now - $stamp).TotalHours
        })
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    # Prefer the newest run that is at least MinHours old. When the history is
    # not yet that deep, fall back to the oldest run on disk, which is the widest
    # window available - a narrow window is worse than a wide one but far better
    # than no trend at all, and the caller is told which it got.
    $ordered   = @($candidates | Sort-Object Stamp -Descending)
    $attempts  = New-Object System.Collections.Generic.List[object]

    foreach ($c in @($ordered | Where-Object { $_.Age -ge $MinHours })) { $attempts.Add($c) }
    foreach ($c in @($ordered | Where-Object { $_.Age -lt $MinHours } | Sort-Object Stamp)) { $attempts.Add($c) }

    foreach ($candidate in $attempts) {
        # A run that was killed mid-write leaves a truncated CSV behind. Skip to
        # the next candidate rather than failing: an older baseline is a worse
        # baseline, but no baseline at all is the outcome this exists to avoid.
        try {
            $rows = @(Import-Csv -LiteralPath $candidate.File.FullName -ErrorAction Stop)
        }
        catch {
            continue
        }

        if ($rows.Count -eq 0) { continue }

        $map = @{}

        foreach ($r in $rows) {
            $guid = [string](Get-StatisticProperty -InputObject $r -Name "MailboxGuid")

            if ([string]::IsNullOrWhiteSpace($guid)) { continue }

            # Both counters are carried. Which one the trend is measured on is
            # decided by the caller, once this run knows whether the posting list
            # table holds anything at all on this build.
            $map[$guid] = [pscustomobject]@{
                PostingList  = ConvertTo-NullableInt64 (Get-StatisticProperty -InputObject $r -Name "PostingListBytes")
                IndexPayload = ConvertTo-NullableInt64 (Get-StatisticProperty -InputObject $r -Name "IndexPayloadBytes")
            }
        }

        if ($map.Count -eq 0) { continue }

        return [pscustomobject]@{
            Timestamp  = $candidate.Stamp
            AgeHours   = [math]::Round($candidate.Age, 2)
            MetMinimum = ($candidate.Age -ge $MinHours)
            Sizes      = $map
            Source     = $candidate.File.Name
        }
    }

    return $null
}

$script:OutputPath = $OutputPath

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# The process id is part of the run's identity, not decoration. Get-Date has
# one-second resolution, so two runs starting within the same second derive the
# same file names and then append to the same log. Measured on Windows
# PowerShell 5.1, that collision makes one of the two die on a sharing violation
# and exit 1, and it is not reliably the run that was refused - an overlap can
# kill the run that was collecting.
$runId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID
$script:LogFile = Join-Path $OutputPath ("BigFunnelPostingListMonitor-{0}.log" -f $runId)
$script:CsvPath = Join-Path $OutputPath ("BigFunnelPostingListMonitor-{0}.csv" -f $runId)

# One run at a time. Collection can take longer than the interval it is
# scheduled on, and two concurrent runs would double the load on the store at
# exactly the moment it is already slow. Global\ so the lock holds across
# sessions rather than only within one desktop.
$mutex = New-Object System.Threading.Mutex($false, "Global\BigFunnelPostingListMonitor")
$holdingLock = $false

try {
    $holdingLock = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    # A guard, not a feature. If a previous run was killed while holding the
    # lock, the lock is ours and continuing is correct - the point is that the
    # run must not die here. Measured on Windows PowerShell 5.1: killing the
    # holding process does not raise this, WaitOne(0) simply returns $true, so
    # this branch does not fire on that runtime. Do not use its absence to infer
    # that the previous run exited cleanly; a killed run is identified by a log
    # file with no "Monitor run complete" line.
    $holdingLock = $true
}

if (-not $holdingLock) {
    Write-RunLog "Another instance is already running. Exiting without collecting." "WARN"
    $mutex.Dispose()
    exit 4
}

# Housekeeping. Without this the output directory grows without bound, and a
# monitor that fills a disk on an Exchange server has become a worse problem
# than the one it was watching for. Scoped to this script's own file pattern and
# to the current run's directory, and it never touches the run just written.
# The -gt 0 test is not decoration: AddDays(-0) is "now", so a retention of 0
# would delete every previous run rather than keeping them.
function Invoke-RetentionSweep {
    [CmdletBinding()]
    param()

    if ($RetentionDays -le 0) { return }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)

    $stale = @(Get-ChildItem -LiteralPath $script:OutputPath -Filter "BigFunnelPostingListMonitor-*" -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoff -and
            $_.FullName -ne $script:CsvPath -and
            $_.FullName -ne $script:LogFile
        })

    foreach ($old in $stale) {
        try {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
        }
        catch {
            # A file the monitor cannot delete is not a reason to fail the run,
            # but it is a reason to say so - this is how a full disk announces
            # itself weeks before it becomes an outage.
            Write-RunLog ("Could not remove [{0}]: {1}" -f $old.Name, $_.Exception.Message) "WARN"
        }
    }

    if ($stale.Count -gt 0) {
        Write-RunLog ("Retention: removed {0} file(s) older than {1} day(s)." -f $stale.Count, $RetentionDays)
    }
}

# Every exit below goes through this. A process exiting does release its mutex,
# but it releases it as abandoned, which makes the next run look like it
# recovered from a crash. Releasing explicitly keeps that signal meaningful.
#
# Housekeeping happens here rather than at the end of the script, because the end
# of the script is only reached on a successful collection. A passive DAG member
# exits 3 on every run by design - the scheduling section says to register the
# task on every node - so putting the sweep at the bottom meant the nodes that
# only ever write log files were the nodes that never pruned them. The refused
# run is deliberately not covered: it exits 4 without coming through here, which
# is right, because a run that never held the lock should not be deleting files
# underneath the run that does.
function Exit-MonitorRun {
    param([Parameter(Mandatory = $true)][int]$Code)

    try {
        Invoke-RetentionSweep
    }
    catch {
        # Housekeeping must never change the exit code. The code is what the
        # operator alerts on, and reporting a collection failure that did not
        # happen is worse than leaving a stale file on disk.
        Write-RunLog ("Retention sweep failed: {0}" -f $_.Exception.Message) "WARN"
    }

    if ($script:holdingLock) { $script:mutex.ReleaseMutex() }
    $script:mutex.Dispose()
    exit $Code
}

Write-RunLog "Starting BigFunnel PostingListTable monitor run."

# Caught rather than left to throw. An uncaught terminating error exits 1, which
# is not one of the codes the scheduling section tells the operator to alert on,
# and it skips Exit-MonitorRun so the lock is released as abandoned. Both make a
# missing Exchange shell harder to spot than it should be.
try {
    Initialize-ExchangeShell
}
catch {
    Write-RunLog ("Pre-flight failed: {0}" -f $_.Exception.Message) "ERROR"
    Exit-MonitorRun -Code 3
}

$warningBytes = [int64]($WarningGB * 1GB)
$criticalBytes = [int64]($CriticalGB * 1GB)

if (-not $Databases -or $Databases.Count -eq 0) {
    Write-RunLog "No databases specified. Discovering mounted mailbox databases."

    # Filter on MountedOnServer, not on Mounted. Mounted is populated only on
    # the server that holds the active copy and comes back blank from every
    # other DAG member, in both directions - so "Mounted -eq $true" discovers
    # nothing on a passive node and the run completes silently with an empty
    # CSV. MountedOnServer is populated from any node.
    $mounted = @(Get-MailboxDatabase -Status |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MountedOnServer) })

    $local = @($mounted |
        Where-Object { ([string]$_.MountedOnServer -split "\.")[0] -eq $env:COMPUTERNAME })

    if ($local.Count -eq 0 -and $mounted.Count -gt 0) {
        Write-RunLog ("No active database copies are mounted on {0}; {1} are mounted elsewhere in the DAG. Schedule this on the active node, or pass -Databases explicitly." -f $env:COMPUTERNAME, $mounted.Count) "WARN"
    }

    $Databases = @($local | Select-Object -ExpandProperty Name)
}

# An empty scope is a failed run, not a clean one. Without this the script
# exports a zero-row CSV, logs "Monitor run complete", and returns success -
# which is indistinguishable from a healthy estate.
if (-not $Databases -or @($Databases).Count -eq 0) {
    Write-RunLog "No databases are in scope. Nothing was collected; this run says nothing about posting list growth." "ERROR"
    Exit-MonitorRun -Code 3
}

$results = New-Object System.Collections.Generic.List[object]

# Databases that raised on collection. Tracked so the run can exit 2 rather than
# reporting success over a partial estate.
$failedDatabases = New-Object System.Collections.Generic.List[string]

foreach ($db in $Databases) {
    Write-RunLog ("Collecting mailbox statistics for database [{0}]." -f $db)

    try {
        $stats = Get-MailboxStatistics -Database $db -ErrorAction Stop

        foreach ($stat in $stats) {
            $property = $stat.PSObject.Properties["BigFunnelPostingListTableTotalSize"]

            if ($null -eq $property) {
                Write-RunLog ("Mailbox [{0}] does not expose BigFunnelPostingListTableTotalSize." -f $stat.DisplayName) "WARN"
                continue
            }

            $bytes = Convert-ExchangeSizeToBytes -SizeValue $property.Value

            if ($null -eq $bytes) {
                # Unlimited, or a value this parser does not recognize. Logged
                # per mailbox so a skipped mailbox is visible in the run rather
                # than quietly missing from the CSV.
                Write-RunLog ("Skipped mailbox [{0}] on [{1}]: could not read a size from [{2}]." -f $stat.DisplayName, $db, [string]$property.Value) "WARN"
                continue
            }

            # Corroborating counters. Without these, a 0 B posting list table
            # cannot be told apart from a mailbox that simply has no index.
            $indexedCount = Get-StatisticProperty -InputObject $stat -Name "BigFunnelIndexedCount"

            # Where the index size is accounted for on builds that leave the
            # posting list table empty. Summed only from the parts that parsed,
            # so one absent property does not zero the total.
            $payloadBytes = $null

            foreach ($name in @("BigFunnelTotalPOISize",
                                "BigFunnelLargePOITableTotalSize",
                                "BigFunnelFilterTableTotalSize")) {

                $part = Convert-ExchangeSizeToBytes -SizeValue (Get-StatisticProperty -InputObject $stat -Name $name)

                if ($null -ne $part) {
                    $payloadBytes = [int64]$payloadBytes + [int64]$part
                }
            }

            $status = Get-PostingListStatus `
                -Bytes $bytes `
                -WarningBytes $warningBytes `
                -CriticalBytes $criticalBytes `
                -IndexedCount $indexedCount

            $results.Add([pscustomobject]@{
                Timestamp                          = Get-Date
                Database                           = $db
                DisplayName                        = $stat.DisplayName
                MailboxGuid                        = $stat.MailboxGuid
                ItemCount                          = $stat.ItemCount
                TotalItemSize                      = [string]$stat.TotalItemSize
                BigFunnelPostingListTableTotalSize = [string]$property.Value
                PostingListBytes                   = $bytes
                PostingListGB                      = [math]::Round(($bytes / 1GB), 3)
                BigFunnelIndexedCount              = $indexedCount
                IndexPayloadBytes                  = $payloadBytes
                Status                             = $status
                LastLogonTime                      = $stat.LastLogonTime

                # Populated by the trend join below, once an earlier run has
                # been found to compare against. Declared here and not there,
                # because Set-StrictMode 2.0 makes assigning to a property that
                # was never defined a terminating error, and on a first run
                # there is nothing to compare so none of these are ever written.
                PreviousBytes                      = $null
                DeltaBytes                         = $null
                GrowthGBPerDay                     = $null
                DaysToCritical                     = $null
                Trend                              = $null
                TrendWindowHours                   = $null
                TrendMetric                        = $null

                # The size of whichever counter the rate was actually measured
                # on. Reporting PostingListGB next to a growth rate taken from
                # the index payload produces lines reading "at 0 GB, growing
                # 0.0161 GB/day", which is not a rounding artifact but two
                # different counters printed side by side as though they were
                # one.
                MeasuredGB                         = $null
            })
        }
    }
    catch {
        # Recorded rather than swallowed. A database that could not be read is
        # not a database with nothing wrong in it, and the run has to exit
        # non-zero so the scheduler notices.
        Write-RunLog ("Failed to collect database [{0}]. Error: {1}" -f $db, $_.Exception.Message) "ERROR"
        $failedDatabases.Add([string]$db)
    }
}

# A single run can say which mailboxes are over the line right now. It cannot say
# which one crosses next, and on an estate of any size that is the question that
# actually matters: the point of a threshold is to buy enough warning to act
# before a user notices. Turning a reading into a rate needs two observations, so
# everything below joins this run against an earlier one.

# Which counter to measure growth on is decided from the data rather than
# assumed. On Exchange SE 15.2.2562.17 BigFunnelPostingListTableTotalSize reads
# exactly 0 B on every fully indexed mailbox - the index mass sits in
# BigFunnelTotalPOISize and in the large POI and filter tables instead. Ranking
# an estate by a column that is zero for every row produces a list in arbitrary
# order that still looks authoritative, which is worse than producing no list at
# all. Where the posting list table does carry data it stays the metric, because
# that is the counter the thresholds were calibrated against.
$trendMetric = "PostingListBytes"

# Whether a *date* can be put on the growth, as opposed to just an ordering.
# The warning and critical thresholds are sizes of the posting list table and
# nothing else. Measuring growth on a different counter and then extrapolating
# it to those same thresholds compares two unrelated quantities: on this build
# the index payload is single-digit megabytes while the critical line is two
# gigabytes, so every mailbox in the estate returns a projection of months and
# the horizon filter below discards all of them. The feature that exists to say
# which mailbox is next then produces nothing at all, on precisely the build
# the fallback was written for, and prints a reassuring "none projected" while
# doing it. So on the fallback path the script ranks by rate and declines to
# name a date, rather than inventing a threshold it has never validated.
$projectionApplies = $true

$postingListPopulated = @($results | Where-Object { [int64]$_.PostingListBytes -gt 0 }).Count
$payloadPopulated     = @($results | Where-Object { $null -ne $_.IndexPayloadBytes -and [int64]$_.IndexPayloadBytes -gt 0 }).Count

if ($postingListPopulated -eq 0 -and $payloadPopulated -gt 0) {
    $trendMetric       = "IndexPayloadBytes"
    $projectionApplies = $false

    Write-RunLog ("BigFunnelPostingListTableTotalSize is 0 B for all {0} mailbox(es) in scope, so growth is being measured on IndexPayloadBytes instead. The ordering below is still meaningful - the mailbox at the top is genuinely the one growing fastest. No date is given: the warning and critical thresholds are sizes of the posting list table, they have never been validated against this counter, and a projection towards them would be arithmetic on two unrelated quantities. Use the ranking to decide what to look at first, and establish a threshold for this counter on your own estate before treating any of it as a deadline." -f $results.Count) "WARN"
}

$baseline = Get-PreviousRunBaseline -Path $script:OutputPath -ExcludeFile $script:CsvPath -MinHours $TrendBaselineHours

# Whether the join below actually ran. A baseline being found is not the same
# thing: it can be found and then rejected for being too recent to divide by.
# Without this the "nothing is projected to cross" line further down fires on
# the rejected case too, so a run that skipped the projection entirely reports
# an all-clear one line after saying it was skipping it.
$trendComputed = $false

if ($null -eq $baseline) {
    Write-RunLog "No earlier run was found on disk, so this run establishes the baseline. Growth rates and projections appear from the next run onwards. Until then nothing can be ranked by how soon it will cross, and an empty projection list below means only that there is no history yet."
}
elseif ($baseline.AgeHours -le 0.01) {
    Write-RunLog "The previous run is too recent to derive a meaningful rate from. Projections are skipped for this run." "WARN"
}
else {
    $trendComputed = $true

    Write-RunLog ("Comparing against [{0}], {1} hour(s) earlier, {2} mailbox(es) baselined." -f
        $baseline.Source, $baseline.AgeHours, $baseline.Sizes.Count)

    if (-not $baseline.MetMinimum) {
        Write-RunLog ("That window is shorter than the {0}-hour minimum, so these rates are extrapolated from a narrow sample and will move between runs. Treat the projections as provisional until the history is deeper." -f $TrendBaselineHours) "WARN"
    }

    # An absolute tolerance, so that ordinary churn does not read as a trend.
    # Without it every mailbox in the estate reports Growing or Shrinking on
    # every run and the column stops carrying information.
    $tolerance = 1MB
    $trended   = 0
    $unmatched = 0

    foreach ($row in $results) {
        $guid = [string]$row.MailboxGuid

        if ([string]::IsNullOrWhiteSpace($guid)) { continue }

        if (-not $baseline.Sizes.ContainsKey($guid)) {
            # A mailbox that did not exist at the baseline, or was in a database
            # that failed to collect that run. Not an error, but worth counting:
            # a large number here means the projection covers much less of the
            # estate than the row count suggests.
            $unmatched++
            continue
        }

        if ($trendMetric -eq "IndexPayloadBytes") {
            $previous = $baseline.Sizes[$guid].IndexPayload
            $current  = $row.IndexPayloadBytes
        }
        else {
            $previous = $baseline.Sizes[$guid].PostingList
            $current  = $row.PostingListBytes
        }

        # Present in the baseline but with no reading for the chosen counter.
        # Skipped rather than treated as zero: a missing previous value coerced
        # to 0 turns the whole of the current size into growth, and that single
        # mailbox then sits at the top of the projection for no reason.
        if ($null -eq $previous -or $null -eq $current) { continue }

        $delta  = [int64]$current - [int64]$previous
        $perDay = ($delta / $baseline.AgeHours) * 24.0

        $row.PreviousBytes    = [int64]$previous
        $row.DeltaBytes       = $delta
        $row.GrowthGBPerDay   = [math]::Round(($perDay / 1GB), 4)
        $row.TrendWindowHours = $baseline.AgeHours
        $row.TrendMetric      = $trendMetric
        $row.MeasuredGB       = [math]::Round(([int64]$current / 1GB), 3)

        if     ($delta -gt $tolerance)       { $row.Trend = "Growing" }
        elseif ($delta -lt (0 - $tolerance)) { $row.Trend = "Shrinking" }
        else                                 { $row.Trend = "Flat" }

        # Only project forward for mailboxes not already past the line. Zero days
        # on something already critical is noise in a list whose whole purpose is
        # to surface what has not happened yet.
        #
        # Skipped entirely when the rate came from a counter the thresholds do
        # not describe. Leaving DaysToCritical empty there is the point: an empty
        # column is read as "no projection", where a number computed against the
        # wrong threshold is read as a deadline.
        if ($projectionApplies) {
            if ([int64]$current -ge $criticalBytes) {
                $row.DaysToCritical = 0
            }
            elseif ($perDay -gt 0) {
                $row.DaysToCritical = [math]::Round((($criticalBytes - [int64]$current) / $perDay), 2)
            }
        }

        $trended++
    }

    Write-RunLog ("Growth rate computed for {0} of {1} mailbox(es), measured on {2}." -f $trended, $results.Count, $trendMetric)

    if ($unmatched -gt 0) {
        Write-RunLog ("{0} mailbox(es) were not in the baseline and so have no projection yet." -f $unmatched)
    }
}

# Critical must sort first, and "Sort-Object Status, PostingListBytes
# -Descending" does not do that: one -Descending applies to both keys, so Status
# comes back reverse-alphabetically as Warning, NotPopulated, Normal, Critical -
# putting the rows that matter most at the bottom of the file. Rank the statuses
# explicitly and set the direction per key. NotPopulated needs a rank of its own
# as well: an unmapped status returns $null from the hashtable, and $null sorts
# ahead of 0, which would float those rows above Critical.
$statusRank = @{ "Critical" = 0; "Warning" = 1; "NotPopulated" = 2; "Normal" = 3 }

# The size key follows whichever counter is in use, for the same reason the
# ranking does. PostingListBytes is zero on every row of a 0 B build, so sorting
# the export by it leaves each status group in arbitrary order - and this is the
# file the log points at for the detail it had to truncate. An ordered list in
# the log beside an unordered one in the CSV is the worse of both: the operator
# reads the ranking, opens the artifact to see the rest of it, and gets rows in
# collection order that look like a continuation of the list.
$sizeKey = if ($trendMetric -eq "IndexPayloadBytes") { "IndexPayloadBytes" } else { "PostingListBytes" }

$results |
    Sort-Object `
        @{ Expression = { $statusRank[[string]$_.Status] } }, `
        @{ Expression = { [int64]($_.$sizeKey) }; Descending = $true } |
    Export-Csv -NoTypeInformation -Path $script:CsvPath -Encoding UTF8

Write-RunLog ("Exported results to [{0}]." -f $script:CsvPath)

# Wrapped in @() throughout. A Where-Object that matches nothing returns
# $null, and under Set-StrictMode 2.0 reading .Count on $null is a terminating
# error - so on a completely healthy run the unwrapped form fails here.
$atRisk = @($results | Where-Object { $_.Status -in @("Warning", "Critical") })

if ($atRisk.Count -gt 0) {
    Write-RunLog ("Alert: {0} mailbox(es) at warning or critical threshold." -f $atRisk.Count)

    # Capped. On a large estate an unbounded table here scrolls the projection
    # below it off the screen, and the projection is the part that is actionable.
    $atRisk |
        Sort-Object @{ Expression = { [int64]$_.PostingListBytes }; Descending = $true } |
        Select-Object -First $MaxAlertDetail Database, DisplayName, PostingListGB, GrowthGBPerDay, Trend, Status |
        Format-Table -AutoSize

    if ($atRisk.Count -gt $MaxAlertDetail) {
        Write-RunLog ("...and {0} further mailbox(es) at or above the warning threshold, not shown. Full detail is in [{1}]." -f
            ($atRisk.Count - $MaxAlertDetail), $script:CsvPath) "WARN"
    }
}

# The list this script exists to produce, and the one a point-in-time reading
# cannot: of everything in scope, which mailbox is next. It takes one of two
# forms. Where the posting list table carries data, that question has a date
# attached and the list is sorted by time-to-threshold ascending. Where it reads
# 0 B the same question is answered by rate alone, because the thresholds do not
# describe the counter the rate came from. Both are orderings of the same thing;
# only one of them can honestly be given in days.
#
# Either way the list deliberately excludes anything already at or past the
# line. Those mailboxes are in the at-risk table above and need remediating, not
# predicting; leaving them here would put a row of zeroes at the top and bury
# the mailboxes that can still be got to in time.
if ($projectionApplies) {
    $nextToCross = @($results |
        Where-Object {
            $null -ne $_.DaysToCritical -and
            [double]$_.DaysToCritical -gt 0 -and
            [double]$_.DaysToCritical -le $ProjectionHorizonDays
        } |
        Sort-Object @{ Expression = { [double]$_.DaysToCritical } })

    if ($nextToCross.Count -gt 0) {
        Write-RunLog ("{0} mailbox(es) are below the critical threshold now but projected to cross it within {1} day(s), measured on {2} over a {3}-hour window." -f
            $nextToCross.Count, $ProjectionHorizonDays, $trendMetric, $baseline.AgeHours) "WARN"

        $shown = 0

        foreach ($r in $nextToCross) {
            if ($shown -ge $MaxAlertDetail) { break }
            $shown++

            Write-RunLog ("Next to cross: [{0}] {1} on [{2}] at {3} GB, growing {4} GB/day, projected critical in {5} day(s)." -f
                $r.MailboxGuid, $r.DisplayName, $r.Database, $r.MeasuredGB, $r.GrowthGBPerDay, $r.DaysToCritical) "WARN"
        }

        if ($nextToCross.Count -gt $shown) {
            Write-RunLog ("...and {0} further mailbox(es) inside the {1}-day horizon, not listed. Full detail is in [{2}]." -f
                ($nextToCross.Count - $shown), $ProjectionHorizonDays, $script:CsvPath) "WARN"
        }

        $nextToCross |
            Select-Object -First $MaxAlertDetail Database, DisplayName, MeasuredGB, GrowthGBPerDay, DaysToCritical, Status |
            Format-Table -AutoSize
    }
    elseif ($trendComputed) {
        # Said explicitly, and only when a rate was actually derived. A silent
        # absence here is ambiguous between "nothing is trending towards the
        # line" and "the projection did not run", and those call for very
        # different responses. Reporting the first when the truth is the second
        # is the worse of the two errors, so the condition is that the join ran,
        # not merely that a baseline file was found.
        Write-RunLog ("No mailbox below the critical threshold is projected to cross it within {0} day(s)." -f $ProjectionHorizonDays)
    }
}
elseif ($trendComputed) {
    # The fallback answer to the same question. No date can be put on this, for
    # the reasons given where $projectionApplies is set, so it ranks instead:
    # fastest first, which is the order in which these mailboxes will become
    # someone's problem even though the script cannot say when.
    # Filtered on Trend rather than on the raw rate, so the same 1 MB tolerance
    # that keeps ordinary churn out of the Growing count keeps it out of this
    # list too. A mailbox that moved by a few hundred kilobytes has a positive
    # rate and is not growing in any sense worth paging someone about; counting
    # it here would inflate the headline number with rows that the Trend column
    # on the very same line calls Flat.
    $fastestGrowing = @($results |
        Where-Object {
            $_.Trend -eq "Growing" -and
            $null -ne $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0
        } |
        Sort-Object @{ Expression = { [double]$_.GrowthGBPerDay } } -Descending)

    if ($fastestGrowing.Count -gt 0) {
        Write-RunLog ("{0} mailbox(es) grew over a {1}-hour window, measured on {2}. They are ranked fastest first below. No projected date is given for the reason logged above; treat this as the order to work through, not a countdown." -f
            $fastestGrowing.Count, $baseline.AgeHours, $trendMetric) "WARN"

        $shown = 0

        foreach ($r in $fastestGrowing) {
            if ($shown -ge $MaxAlertDetail) { break }
            $shown++

            Write-RunLog ("Fastest growing #{0}: [{1}] {2} on [{3}] at {4} GB, growing {5} GB/day on {6}." -f
                $shown, $r.MailboxGuid, $r.DisplayName, $r.Database, $r.MeasuredGB, $r.GrowthGBPerDay, $trendMetric) "WARN"
        }

        if ($fastestGrowing.Count -gt $shown) {
            Write-RunLog ("...and {0} further growing mailbox(es), not listed. Full detail is in [{1}]." -f
                ($fastestGrowing.Count - $shown), $script:CsvPath) "WARN"
        }

        $fastestGrowing |
            Select-Object -First $MaxAlertDetail Database, DisplayName, MeasuredGB, GrowthGBPerDay, Trend, Status |
            Format-Table -AutoSize
    }
    else {
        Write-RunLog ("No mailbox grew measurably on {0} over the {1}-hour window." -f $trendMetric, $baseline.AgeHours)
    }
}

# Loud on purpose. If the posting list table is empty across an indexed
# population, the thresholds above were applied to a constant zero, and a clean
# run means only that nothing could ever have been found.
$notPopulated = @($results | Where-Object { $_.Status -eq "NotPopulated" })

# The denominator is the indexed population, not every row collected. Health,
# arbitration, system and archive mailboxes hold no BigFunnel index at all, so
# they can never reach this state; on a lab server they were 44 of 66 rows.
# Comparing against $results.Count therefore never reaches equality on a real
# server, and the escalation below would never fire.
$indexedPop = @($results | Where-Object { [int64]$_.BigFunnelIndexedCount -gt 0 })

if ($notPopulated.Count -gt 0) {
    $totalOutage = $notPopulated.Count -ge $indexedPop.Count
    $level       = if ($totalOutage) { "ERROR" } else { "WARN" }

    Write-RunLog ("{0} of {1} indexed mailbox(es) ({2} evaluated in total) report indexed items while BigFunnelPostingListTableTotalSize reads 0 B. This run cannot speak to posting list growth for those mailboxes; see the IndexPayloadBytes column for the index size that does exist." -f $notPopulated.Count, $indexedPop.Count, $results.Count) $level

    if ($totalOutage) {
        Write-RunLog "Every indexed mailbox in scope is in this state, so no mailbox in this run could ever have crossed a threshold. Treat the thresholds here as untested, not as passed." "ERROR"
    }
}

Write-RunLog "Monitor run complete."

# Exit codes, matching what the scheduling section tells the operator to alert
# on. 0 is the only code that means "this run examined the estate and found
# nothing wrong"; every other code means the monitor is not reporting, which
# needs attention sooner than a large posting list table does. Housekeeping runs
# inside Exit-MonitorRun, so it happens on this path and on the early ones too.
if ($failedDatabases.Count -gt 0) {
    Write-RunLog ("{0} of {1} database(s) could not be collected: {2}. Results are partial." -f $failedDatabases.Count, @($Databases).Count, ($failedDatabases -join ", ")) "ERROR"
    Exit-MonitorRun -Code 2
}

Exit-MonitorRun -Code 0
```

### Scheduling example

Use this example to run every 4 hours. Run from an elevated Exchange Management Shell. Replace the script path, output path, and account with environment-specific values.

```powershell
# No -Databases. The script then discovers the databases whose active copy is
# mounted on this node, which is what makes the same registration correct on
# every DAG member and correct again after a switchover. Name databases
# explicitly only when you deliberately want a fixed subset, and expect that
# task to start collecting nothing the first time the copy moves.
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-File "C:\Scripts\Monitor-BigFunnelPostingList.ps1" ' +
    '-OutputPath "C:\ProgramData\ExchangeBigFunnelPostingListMonitor" ' +
    '-WarningGB 1.7 -CriticalGB 2.0 -RetentionDays 30')

$trigger = New-ScheduledTaskTrigger -Once -At 00:05 `
    -RepetitionInterval (New-TimeSpan -Hours 4)

# ExecutionTimeLimit is the backstop for a store call that never returns. The
# script's own mutex prevents a slow run from being overlapped by the next
# scheduled one, but it cannot interrupt a call already in progress, so the task
# needs a hard ceiling of its own. MultipleInstances IgnoreNew is the same
# protection at the scheduler level.
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable

Register-ScheduledTask -TaskName "Exchange BigFunnel PostingListTable Monitor" `
    -Action $action -Trigger $trigger -Settings $settings `
    -User "DOMAIN\ServiceAccount" -RunLevel Highest -Force
```

Points that matter in production:

- **Store the script outside its own output directory.** The script prunes files matching `BigFunnelPostingListMonitor-*` under `-OutputPath` on a retention schedule. Keeping the script somewhere else, such as `C:\Scripts`, removes any possibility of the housekeeping and the tooling sharing a folder.
- **Use a literal path, not an environment variable.** `%ProgramData%` expands differently depending on which shell creates the task and whether the service account's profile is loaded. A hardcoded path fails visibly at registration rather than silently at 02:05.
- **The account needs Exchange RBAC, not just local administrator.** It must be able to run `Get-ExchangeServer`, `Get-MailboxDatabase`, and `Get-MailboxStatistics`. View-Only Organization Management is sufficient and is the least-privileged role that covers all three.
- **Interpret the exit code.** The script exits 0 on a clean run, 2 when at least one database could not be collected, 3 when it could not collect anything at all (a failed pre-flight, or no database in scope), and 4 when a previous run is still going. Alert on 2, 3, and 4: those mean the monitor itself is not reporting, which is a different and more urgent problem than a large posting list table. A run that is missing entirely leaves a log file with no `Monitor run complete` line; that is how a killed run is identified, since it has no exit code to report.

#### Which DAG node to schedule on

In a DAG, `Get-MailboxStatistics -Database` returns data only from the server currently hosting the active copy. Register the task on **every** member of the DAG and pass no `-Databases`, which is the case the script's discovery is built for: it selects only the databases whose active copy is mounted on the local server.

That arrangement survives a switchover: whichever node holds the active copy after a failover is the node that collects it, with no reconfiguration. The nodes that do not hold an active copy exit 3 with an explanatory log line, so a node reporting exit 3 continuously is expected on a passive-only member and is not by itself a fault.

A passive member still writes a log file on every run, so it is also the node where housekeeping matters most: at a 15-minute interval that is roughly 35,000 files a year in one directory, on a node that never produces a report anyone reads. The retention sweep runs on every exit that held the lock, including exit 3, so a passive member prunes its own logs without ever collecting anything.

Do not try to cover the DAG from one node by naming every database in `-Databases`. It works while that node is up, and stops silently when it is not.

### Ranking mailboxes by how soon they cross

A single collection answers "which mailboxes are over the line now." On an estate of any size the more useful question is "which one goes over next," because that is the one still cheap to fix. A threshold is only worth setting if it buys enough warning to act before a user notices, and a size on its own cannot tell you how much warning is left.

The script answers that question by joining each run against an earlier one and turning the difference into a rate. Every run writes its results to a timestamped CSV in `-OutputPath`, and every subsequent run reads the most recent qualifying one back.

#### Trending needs two runs

The first run against an empty output directory has nothing to compare against, cannot produce a rate, and says so:

```output
[INFO] No earlier run was found on disk, so this run establishes the baseline. Growth rates and projections appear from the next run onwards.
```

Read that literally. On a first run the projection list is empty because there is no history, **not** because nothing is trending towards the threshold. Those two states look identical in a CSV and call for completely different responses, which is why the script distinguishes them in the log rather than leaving you to infer it from an absent section. Once history exists, an empty projection is stated positively instead:

```output
[INFO] No mailbox below the critical threshold is projected to cross it within 14 day(s).
```

A run that has found a baseline names the file and the window it measured over, so the rates below it can be checked rather than taken on trust:

```output
[INFO] Comparing against [BigFunnelPostingListMonitor-20250114-060012-8244.csv], 24.02 hour(s) earlier, 1712 mailbox(es) baselined.
[INFO] Growth rate computed for 1698 of 1712 mailbox(es), measured on PostingListBytes.
[INFO] 14 mailbox(es) were not in the baseline and so have no projection yet.
```

That last line matters on an estate that changes shape. A mailbox created since the baseline, or one on a database that failed to collect on the previous run, has no earlier reading to difference against and is therefore absent from the projection. A large count here means the ranking covers materially less of the estate than the row count suggests.

#### Columns added by the trend join

These columns are written to the CSV for every mailbox that could be matched to a baseline. They are blank on a first run, and blank on any mailbox with no earlier reading.

| Column | Meaning |
|---|---|
| `PreviousBytes` | The same mailbox's size in the baseline run, in bytes |
| `DeltaBytes` | Change since the baseline. Negative after successful remediation |
| `GrowthGBPerDay` | `DeltaBytes` normalized to a 24-hour rate. This is the number to compare between mailboxes; raw deltas are not comparable unless both were measured over the same window |
| `MeasuredGB` | The current size of whichever counter `TrendMetric` names. Read this rather than `PostingListGB` alongside a growth rate: on a build where the posting list table reads `0 B` the two columns describe different things, and `PostingListGB` would report `0` next to a non-zero rate |
| `DaysToCritical` | Days until this mailbox reaches the critical threshold at its current rate. `0` means it is already at or past it. Blank means one of three things: the mailbox is flat or shrinking, it had no baseline to compare against, or growth was measured on a counter the thresholds do not describe — see [When the posting list table reads 0 B](#when-the-posting-list-table-reads-0-b) |
| `Trend` | `Growing`, `Flat`, or `Shrinking`. A 1 MB tolerance either side of zero keeps ordinary churn out of the growing and shrinking counts |
| `TrendWindowHours` | How far apart the two readings actually were. A short window magnifies noise, so this qualifies every rate on the row |
| `TrendMetric` | Which counter the rate was measured on, `PostingListBytes` or `IndexPayloadBytes`. See [When the posting list table reads 0 B](#when-the-posting-list-table-reads-0-b) |

#### The next-to-cross list

Mailboxes below the critical threshold but projected to reach it inside the horizon are listed soonest-first, in the log and as a table:

```output
[WARN] 3 mailbox(es) are below the critical threshold now but projected to cross it within 14 day(s), measured on PostingListBytes over a 24.02-hour window.
[WARN] Next to cross: [a1f3...] Contoso Dispatch on [DB04] at 1.61 GB, growing 0.34 GB/day, projected critical in 1.15 day(s).
[WARN] Next to cross: [7c02...] Shared AP Inbox on [DB01] at 1.44 GB, growing 0.09 GB/day, projected critical in 6.22 day(s).
```

The ordering is the point. The top of the list is the work to do before the weekend rather than the work to explain afterwards, and a mailbox projected to cross in 1.15 days needs attention ahead of one already sitting at a higher size but not moving.

Mailboxes already at or past the threshold are deliberately **excluded** from this list. They appear in the at-risk table above it, and they need remediating rather than predicting; including them would put a block of zeroes at the top and bury the mailboxes that can still be reached in time.

#### When the posting list table reads 0 B

On builds where `BigFunnelPostingListTableTotalSize` reads exactly `0 B` across an indexed population (see [Confirm the metric is populated before you trust it](#confirm-the-metric-is-populated-before-you-trust-it)), ranking on that column would sort the whole estate by a value that is zero for every row, producing an arbitrary order that still looks authoritative. The script detects this from the collected data and measures growth on the combined POI and filter sizes instead, announcing the substitution:

```output
[WARN] BigFunnelPostingListTableTotalSize is 0 B for all 1712 mailbox(es) in scope, so growth is being measured on IndexPayloadBytes instead. The ordering below is still meaningful - the mailbox at the top is genuinely the one growing fastest. No date is given: ...
```

On this path the output is a **ranking without dates**. `DaysToCritical` stays blank and the list is headed differently:

```output
[WARN] 47 mailbox(es) grew over a 24.02-hour window, measured on IndexPayloadBytes. They are ranked fastest first below.
[WARN] Fastest growing #1: [a1f3...] Contoso Dispatch on [DB04] at 0.412 GB, growing 0.0386 GB/day on IndexPayloadBytes.
[WARN] Fastest growing #2: [7c02...] Shared AP Inbox on [DB01] at 0.298 GB, growing 0.0329 GB/day on IndexPayloadBytes.
```

The ordering is genuine and is what you act on: the mailbox at the top is the one whose index is growing fastest, and that is still the answer to "which one is next". The dates are withheld rather than estimated, because `-WarningGB` and `-CriticalGB` are sizes of the posting list table and have never been validated against this counter. Extrapolating one to the other compares unrelated quantities — the index payload here is typically single-digit megabytes against a two-gigabyte threshold, so every projection would land months out and the horizon filter would discard the entire list. A monitor that returns nothing while reporting no problem is worse than one that declines to guess.

To get dates back on such a build, establish what a problematic `IndexPayloadBytes` looks like on your own estate first — collect for a few weeks, find the sizes at which search actually degrades — and set `-WarningGB` and `-CriticalGB` from that. Until then, work the ranking top-down.

#### Parameters that control the projection

| Parameter | Default | What to consider when changing it |
|---|---:|---|
| `-TrendBaselineHours` | `24` | How far back to reach for the comparison run. Short windows magnify noise: at a 15-minute cadence a delta is multiplied by 96 to reach a daily rate, so a few megabytes of ordinary churn reads as a trend and the projection swings between runs. If the history is not yet this deep the widest window available is used and the run is marked provisional. Accepts `1`–`8760` |
| `-ProjectionHorizonDays` | `14` | How far ahead the list looks. The default is chosen to be longer than the gap between one working Friday and the next, so a mailbox cannot appear and cross inside a single unattended weekend. Raise it for a slow-moving estate; lower it if the list is too long to act on. Accepts `1`–`3650` |
| `-MaxAlertDetail` | `20` | Caps per-mailbox detail in the log, so a large estate does not make the monitor its own disk-space problem. Every capped list is sorted worst-first, so what survives the cap is the part worth reading, and the remainder is reported as a count rather than dropped silently. The full set is always in the CSV. Accepts `0`–`100000`; `0` means counts only, with no per-mailbox lines |

> [!IMPORTANT]
> The projection is a linear extrapolation of one interval. It is a work queue, not a forecast: mailbox growth is driven by user behavior and rarely stays linear for two weeks. Use the ordering to decide what to look at first, and re-read it each run rather than planning against a specific date. A mailbox whose rate came from a window shorter than `-TrendBaselineHours` is flagged provisional in the log for exactly this reason.

## Resolution

### Emergency: database switchover to restore access

Use this procedure when users are actively blocked, the mailbox is inaccessible, or mail delivery is queuing. Do not delay an emergency switchover solely to complete deep diagnostics.

#### Step 1: Capture minimum evidence

If time allows:

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName, Database, BigFunnel*
```

Record the affected mailbox identity, database name, and timestamp of impact.

#### Step 2: Verify target copy health

The database copy that will become the active mailbox database must be healthy and current.

```powershell
Get-MailboxDatabaseCopyStatus "<DatabaseName>"
```

The `Get-MailboxDatabaseCopyStatus` cmdlet returns health and status information about one or more mailbox database copies. Confirm the target copy shows a healthy status with minimal copy queue length.

#### Step 3: Execute the switchover

`Move-ActiveMailboxDatabase` is the on-premises cmdlet for performing a database or server switchover within a Database Availability Group (DAG). Activating a mailbox database copy designates a specific passive copy as the new active copy by dismounting the current active database and mounting the database copy on the specified server.

```powershell
Move-ActiveMailboxDatabase `
    -Identity "<DatabaseName>" `
    -ActivateOnServer "<TargetServer>" `
    -MountDialOverride None `
    -MoveComment "Search-related mailbox access mitigation"
```

Estimated time to complete: approximately 1 minute.

#### Step 4: Verify activation

```powershell
Get-MailboxDatabaseCopyStatus "<DatabaseName>" | Format-List
```

Confirm that the target server now hosts the active copy and that it is mounted.

#### Step 5: Validate recovery

Confirm:

- Mailbox access is restored.
- Mail delivery is restored.
- `BigFunnelPostingListTableTotalSize` remains materially unchanged. This confirms that switchover released the lock but did not reduce the table.

If access is not restored after switchover, escalate through Microsoft Support with timestamps, mailbox identity, database name, switchover details, and available search diagnostics. Failure to clear the lock may indicate a different constraint or incomplete switchover.

### Durable remediation: mailbox move

Use this procedure for planned, durable remediation. A mailbox move is a supported Exchange operation and may rebuild search metadata structures on the destination, potentially reducing `BigFunnelPostingListTableTotalSize`. However, the degree of reduction varies and is not guaranteed.

#### Pre-move: collect diagnostics

Before moving mailboxes affected by search issues, collect diagnostic data using the [Troubleshoot-ModernSearch script](https://microsoft.github.io/CSS-Exchange/Search/Troubleshoot-ModernSearch/) from the Microsoft CSS-Exchange repository. This script can quickly determine whether an item is indexed or not, and why it is not indexed.

```powershell
.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -ItemSubject "<ItemSubject>"

.\Troubleshoot-ModernSearch.ps1 -Server "<ServerName>"

.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -Category "NotIndexed"
```

The script supports parameters including `-MailboxIdentity`, `-ItemSubject`, `-MatchSubjectSubstring`, `-FolderName`, `-DocumentId`, `-Category`, `-Server`, and `-IsArchive`.

Collect all log files from the directory where the script was run and upload them to the Microsoft Support case before proceeding with the move.

#### Pre-move: content reduction

Before moving the mailbox, reduce its content where possible. Reducing items first produces the best metadata reduction after the move. Actions to consider, with business approval:

- Review and lower audit log retention settings on affected shared mailboxes.
- Apply messaging records management (MRM) retention policies to default folders.
- Archive older content to archive mailboxes or PST export.
- Hard-delete genuinely obsolete items.

#### Move execution

##### Pre-check

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName, Database, TotalItemSize, ItemCount, BigFunnel*
```

##### Create move request

`New-MoveRequest` begins the process of an asynchronous mailbox move. Use `-CompleteAfter` for scheduled completion, which Microsoft recommends over `-SuspendWhenReadyToComplete`.

```powershell
$CompleteAfter = (Get-Date).Date.AddDays(1).AddHours(22) # Next maintenance window

New-MoveRequest `
    -Identity "<MailboxIdentity>" `
    -TargetDatabase "<TargetDatabase>" `
    -BatchName "BF-PLT-Remediation-YYYYMMDD" `
    -CompleteAfter $CompleteAfter `
    -BadItemLimit 10
```

The `-BadItemLimit` parameter specifies the maximum number of corrupt items allowed before the request fails. The default value is 0. Microsoft recommends a value of 10 or lower. If you set this value to 51 or higher, you must also use the `-AcceptLargeDataLoss` switch.

Alternatively, use `-SuspendWhenReadyToComplete` to suspend the move before it reaches `CompletionInProgress`, then resume manually during a maintenance window:

```powershell
New-MoveRequest `
    -Identity "<MailboxIdentity>" `
    -TargetDatabase "<TargetDatabase>" `
    -BatchName "BF-PLT-Remediation-YYYYMMDD" `
    -SuspendWhenReadyToComplete `
    -BadItemLimit 10
```

##### Monitor progress

```powershell
Get-MoveRequest "<MailboxIdentity>" |
    Get-MoveRequestStatistics |
    Format-List DisplayName, Status, StatusDetail, PercentComplete, BadItemsEncountered
```

##### Complete during approved maintenance window

If using `-SuspendWhenReadyToComplete`:

```powershell
Resume-MoveRequest "<MailboxIdentity>"
```

##### Post-move verification

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName, Database, BigFunnel*
```

#### Move duration considerations

Large mailbox moves can take significant time. Plan capacity and maintenance windows accordingly.

#### Move effectiveness

Results vary. The degree of `BigFunnelPostingListTableTotalSize` reduction depends on how much content was cleaned before the move. Some moves produce a complete table rebuild, while others produce a partial reduction. If the table size did not materially decrease, evaluate whether additional content reduction is needed before a subsequent move.

### Search index retry for unindexed items

The `Start-MailboxAssistant` cmdlet is available only in Exchange Server 2019 Cumulative Update 11 (CU11) or later. It starts the `BigFunnelRetryFeederTimeBasedAssistant` assistant, which indexes mailbox items that were not indexed previously.

> [!CAUTION]
> Before using `Start-MailboxAssistant`, you must first create a setting override as described in [Incomplete search results after installing an Exchange Server 2019 update](https://support.microsoft.com/topic/incomplete-search-results-after-installing-an-exchange-server-2019-update-96ae2ef0-4569-4327-8d0c-8a3c1abdc1f6). Incorrect usage of the setting override cmdlets can cause serious damage to your Exchange organization. This damage could require you to reinstall Exchange. Only use these cmdlets as instructed by product documentation or under the direction of Microsoft Customer Service and Support.

```powershell
Start-MailboxAssistant -Identity "<MailboxIdentity>" -AssistantName BigFunnelRetryFeederTimeBasedAssistant
```

The `AssistantName` parameter value `BigFunnelRetryFeederTimeBasedAssistant` is case-sensitive.

The setting override must be removed after the re-indexing completes. It is not recommended to keep it enabled permanently, as it can increase CPU usage.

## Database failover vs. mailbox move

| Dimension | Database failover / switchover | Mailbox move |
|---|---|---|
| Immediate effect | Releases the mailbox lock and restores user access | Does not instantly release an active search lock; mailbox access transfers when the move completes |
| PostingListTable effect | Does not inherently reduce `BigFunnelPostingListTableTotalSize` | May rebuild BigFunnel structures on the destination; the degree of reduction varies |
| Speed | Seconds to minutes; estimated approximately 1 minute to complete switchover | Hours to days depending on mailbox size |
| When to use | Emergency: users are actively blocked, mail is queuing | Durable remediation: after diagnostics are collected and content cleanup is performed |
| Prerequisites | Target passive database copy must be healthy and current | Collect Troubleshoot-ModernSearch data before moving; open a Microsoft Support request if the issue is recurring |
| Caveats | Does not prevent recurrence; table size persists | Large mailboxes take significant time; may cause white space growth on the destination database |

> [!NOTE]
> Database failover and mailbox moves have different effects on `BigFunnelPostingListTableTotalSize`. Failover may restore mailbox accessibility by releasing locks but does not rebuild the BigFunnel posting list table. Mailbox moves can trigger a table rebuild and reduce the reported size, although the degree of reduction may vary and may not result in a complete index recreation in every case.

## Database isolation strategy

For environments with many affected shared mailboxes, consider creating a dedicated, low-density database within each affected DAG to house only the problematic shared mailboxes.

This strategy allows targeted switchovers that minimize impact on other users and streamlines remediation. Move the affected shared mailbox to the dedicated database first, then perform a switchover of that database if needed. This approach avoids affecting other users on the original database.

## Concurrency and WLM throttling

Exchange Server 2019 implements workload management (WLM) throttling. By default, WLM applies a limit of 10 simultaneous mailbox moves from the same source or to the same target. WLM throttling overrides Mailbox Replication Service (MRS) throttling.

A stalled status such as `StalledDueToTarget_MdbReplication`, `StalledDueToTarget_MdbAvailability`, or `StalledDueToTarget_DiskLatency` is typical during migration and does not mean the migration has a problem. The purpose of throttling is to maintain the performance of higher-priority Exchange Server workloads.

### Advanced: increasing the WLM limit

> [!CAUTION]
> Incorrect usage of the setting override cmdlets can cause serious damage to your Exchange organization. This damage could require you to reinstall Exchange. Only use these cmdlets as instructed by product documentation or under the direction of Microsoft Customer Service and Support.

Microsoft recommends:

- Do not set the WLM limit to a value greater than 100.
- Start by changing the WLM limit to 25.
- Monitor Exchange Server performance during the migration.
- To further increase, successively increase the WLM limit by 10 and monitor performance at each step.

To set a WLM limit of 25:

```powershell
$limit = 25

New-SettingOverride -Name "MdbReplication" -Component WorkloadManagement `
    -Section MdbReplication -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "CiAgeOfLastNotification" -Component WorkloadManagement `
    -Section CiAgeOfLastNotification -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "MdbAvailability" -Component WorkloadManagement `
    -Section MdbAvailability -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "DiskLatency" -Component WorkloadManagement `
    -Section DiskLatency -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "MdbDiskLatency" -Component WorkloadManagement `
    -Section MdbDiskWriteLatency -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"
```

To further update the limit, for example to 35:

```powershell
$limit = 35

Set-SettingOverride -Identity "MdbReplication" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "CiAgeOfLastNotification" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "MdbAvailability" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "DiskLatency" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "MdbDiskLatency" -Parameters @("MaxConcurrency=$limit")
```

Verify the configuration:

```powershell
Get-SettingOverride -Identity "MdbReplication" | Select-Object -ExpandProperty Parameters
```

The setting override cmdlets, such as `New-SettingOverride` and `Set-SettingOverride`, store Exchange customizations in Active Directory. The settings can be organization-wide or server-specific, and they persist across Exchange Cumulative Updates (CUs).

## Automated remediation strategy

Automation should identify, prepare, and stage remediation rather than silently execute disruptive actions.

| Automation layer | Criteria | Action |
|---|---|---|
| Detection | At or above warning threshold | Alert; create operational ticket; tag mailbox and database |
| Critical | At or above critical threshold | Require owner review; collect Troubleshoot-ModernSearch diagnostics; prepare move or switchover plan |
| Active impact | User blocked; mail queuing; search lock suspected | Initiate approved emergency database switchover |
| Durable remediation | Critical mailbox; diagnostics collected; content owner approves cleanup and move | Create move request with `-CompleteAfter` and descriptive `-BatchName` |
| Completion | Move completes during scheduled window | Validate search and BigFunnel metrics |

## Operator decision flow

### Step 1: Is there active user impact?

Active user impact includes:

- Users cannot open the mailbox.
- Searches cause "server too busy" or 500 errors.
- Mail delivery is queuing with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy`.

If yes:

1. Capture minimum evidence with `Get-MailboxStatistics`.
2. Perform an approved database switchover to release the lock.
3. Continue to durable remediation planning.

### Step 2: Has switchover restored access?

| Result | Action |
|---|---|
| Yes | Access is restored. Continue durable remediation because `BigFunnelPostingListTableTotalSize` persists |
| No | Escalate through Microsoft Support with timestamps, mailbox identity, database name, switchover details, and available search diagnostics |

### Step 3: Is `BigFunnelPostingListTableTotalSize` at or above the critical threshold?

If yes, treat as critical:

1. Collect `Troubleshoot-ModernSearch.ps1` diagnostics.
2. Open a Microsoft Support request and provide the collected data.
3. Plan content reduction followed by mailbox move.

If the value reads `0 B`, do not answer "no" and move on. Check `BigFunnelIndexedCount` first. A mailbox that reports items indexed while reporting `0 B` here is telling you the counter is not accounted for on this build, not that the mailbox is small - see [Confirm the metric is populated before you trust it](#confirm-the-metric-is-populated-before-you-trust-it). In that case this step cannot be answered from this metric, and the symptoms in Steps 1 and 2 are the evidence to work from.

### Step 4: Is the mailbox between the warning and critical thresholds?

If yes, treat as warning:

1. Alert.
2. Review growth rate.
3. Coordinate with the mailbox owner.
4. Schedule cleanup or move before user impact occurs.

### Step 5: Before mailbox move

Complete the following:

1. Run `Troubleshoot-ModernSearch.ps1` and export results.
2. Run `Get-MailboxStatistics` and record all `BigFunnel*` fields.
3. Document content reduction actions taken.
4. Create a change record.
5. Create the move request with `-CompleteAfter` or `-SuspendWhenReadyToComplete`.
6. Complete the move during the approved maintenance window.

### Step 6: After mailbox move

1. Re-run `Get-MailboxStatistics` and compare before/after `BigFunnelPostingListTableTotalSize`.
2. If the table size did not materially decrease, evaluate whether additional content reduction is needed before a subsequent move.
3. Add the mailbox to the monitoring cadence, daily for 7 days, to confirm the table does not rebound.

### Step 7: Validate search and user experience

#### Search validation

```powershell
Test-ExchangeSearch -Identity "<MailboxIdentity>" -Verbose
```

`Test-ExchangeSearch` creates a hidden message and an attachment in the specified mailbox that is visible only to Exchange Search, waits for the message to be indexed, then searches for the content. It reports success or failure depending on whether the message is found after the interval set by the `IndexingTimeoutInSeconds` parameter. The default is 120 seconds.

Confirm that there are no timeouts or failures and that search results are returned.

#### Client validation

Test the following client experiences:

- Outlook in cached mode.
- Outlook in online mode.
- OWA searches with common and broad keywords.

Confirm there are no hangs, long delays, or "server too busy" errors.

#### Mail flow validation

Confirm there is no transport queuing and that new mail delivery is timely.

### Step 8: Review BigFunnel health signals

```powershell
Get-MailboxStatistics "<MailboxIdentity>" | Format-List BigFunnel*
```

Focus on `BigFunnelNotIndexedCount`, `BigFunnelCorruptedCount`, and `BigFunnelStaleCount`.

If anomalies are found:

1. Re-run `Troubleshoot-ModernSearch.ps1`.
2. Consider invoking `Start-MailboxAssistant` with `BigFunnelRetryFeederTimeBasedAssistant` if running Exchange Server 2019 CU11 or later and the required setting override is in place.

### Step 9: Document outcome

Capture before/after metrics for operational tracking.

| Metric | Before move | After move |
|---|---:|---:|
| PostingListTable size | X GB | Y GB |
| Mailbox size | X GB | Y GB |
| Item count | X | Y |
| Search performance | Impacted / OK | OK |
| User impact | Yes / No | No |

Tag the mailbox with one of the following statuses:

| Status | Meaning |
|---|---|
| Remediated | Search, mail flow, and BigFunnel indicators are healthy |
| Partially improved | Metrics improved but additional monitoring or action is required |
| Requires further action | PostingListTable size, search behavior, or BigFunnel health remains problematic |

### Step 10: Decide if further action is required

If `BigFunnelPostingListTableTotalSize` is still at or above the critical threshold:

1. Perform additional content reduction.
2. Re-evaluate audit log volume, high-churn folders such as Inbox and Sent Items, and large conversation threads.
3. Plan a second mailbox move if justified.

If the size rebounded quickly within 7 days, investigate:

- Application behavior, including Exchange Web Services (EWS) and service accounts.
- Automated processes generating content.
- Search patterns, especially broad or generic queries.

### Step 11: Return to standard monitoring

Once stable:

1. Move the mailbox back to the normal monitoring cadence.
2. Keep alerts enabled at the warning and critical thresholds.
3. Remove any temporary tracking flags or incident status.

### Step 12: Continuous improvement

Use insights from the remediation to improve future handling:

- Refine thresholds based on observed growth patterns.
- Identify high-risk mailbox profiles: shared mailboxes, high item-churn mailboxes, and audit-heavy mailboxes.
- Identify databases with clustering of at-risk mailboxes.
- Adjust move batching strategy, monitoring frequency, and cleanup policies such as MRM and retention.

### Step 13: Optional preventive optimization

For frequently impacted environments:

- Isolate high-risk shared mailboxes into dedicated databases.
- Apply stricter retention policies and archive strategies.
- Review EWS usage patterns and third-party integrations.

## Operational guardrails and best practices

| Guardrail | Guidance |
|---|---|
| Do not treat failover as durable cleanup | Failover releases the lock but does not reduce `BigFunnelPostingListTableTotalSize` |
| Avoid unsafe data-loss flags in automation | Do not use `-AcceptLargeDataLoss` unless explicitly approved; it is required when `BadItemLimit` is 51 or higher |
| Start with conservative move concurrency | Begin at or below WLM defaults of 10; Microsoft recommends starting at 25 when increasing, maximum 100 |
| Align move finalization to maintenance windows | Use `-CompleteAfter` preferred, or `-SuspendWhenReadyToComplete` for controlled completion |
| Reduce mailbox content before move | Review audit settings, MRM/default folder policies, retention, archive, and item reduction for best results |
| Isolate affected shared mailboxes | Dedicated low-density databases reduce failover blast radius |
| Never assume mailbox size drives table size | A small mailbox can have a large `BigFunnelPostingListTableTotalSize`; growth depends on content shape and search behavior |
| Collect diagnostics before moving | Run `Troubleshoot-ModernSearch.ps1` and provide results to Microsoft Support |
| Do not use `Send-MailMessage` | The cmdlet is obsolete and does not guarantee secure SMTP connections; use CSV export and approved monitoring platforms |

## Related articles

- [Get-MailboxStatistics](https://learn.microsoft.com/powershell/module/exchangepowershell/get-mailboxstatistics)
- [Move-ActiveMailboxDatabase](https://learn.microsoft.com/powershell/module/exchangepowershell/move-activemailboxdatabase)
- [Activate mailbox database copies](https://learn.microsoft.com/exchange/high-availability/manage-ha/activate-db-copies)
- [New-MoveRequest](https://learn.microsoft.com/powershell/module/exchangepowershell/new-moverequest)
- [Test-ExchangeSearch](https://learn.microsoft.com/powershell/module/exchangepowershell/test-exchangesearch)
- [Start-MailboxAssistant](https://learn.microsoft.com/powershell/module/exchangepowershell/start-mailboxassistant)
- [Get-MailboxDatabaseCopyStatus](https://learn.microsoft.com/powershell/module/exchangepowershell/get-mailboxdatabasecopystatus)
- [Mailboxes are stalled during migration](https://learn.microsoft.com/troubleshoot/exchange/migration/mailboxes-stalled-during-migration)
- [New-SettingOverride](https://learn.microsoft.com/powershell/module/exchangepowershell/new-settingoverride)
- [Troubleshoot-ModernSearch](https://microsoft.github.io/CSS-Exchange/Search/Troubleshoot-ModernSearch/)
