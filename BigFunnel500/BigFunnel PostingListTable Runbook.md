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

Two explanations fit that result, and the lab could not separate them: the build may account for posting list data elsewhere regardless of content volume, or the counter may materialize only above an allocation threshold that 5.699 MB of content does not reach. Both carry the same consequence for monitoring, so read a zero against the corroborating counters rather than on its own:

| Reading | Interpretation | Action |
|---|---|---|
| `BigFunnelPostingListTableTotalSize` above `0 B` | The metric is populated on this build | Apply the thresholds in the next section |
| `0 B`, with `BigFunnelIndexedCount` at `0` | The mailbox has no index yet | Investigate indexing; this is not a table-growth question |
| `0 B`, with `BigFunnelIndexedCount` above `0` | The mailbox is indexed but the size is not accounted for in this counter | Do not read this as healthy. Check `BigFunnelTotalPOISize`, `BigFunnelLargePOITableTotalSize`, and `BigFunnelFilterTableTotalSize` for where the index size actually is |

> [!IMPORTANT]
> If every mailbox on a database reports `0 B` while reporting a non-zero `BigFunnelIndexedCount`, threshold alerting on this metric cannot fire there. A clean monitoring run then says nothing about posting list growth - it says only that nothing could have been found. Validate the counter against at least one mailbox known to exhibit the problem before treating an absence of alerts as evidence of health. The monitoring script in the next section reports this case as a distinct `NotPopulated` status rather than as `Normal`, precisely so that it cannot be mistaken for a pass.

When you judge how widespread the condition is, count it against the mailboxes that have an index, not against every row `Get-MailboxStatistics` returns. Health, arbitration, system and archive mailboxes hold no BigFunnel index at all and cannot exhibit the condition; on the lab server above they were 44 of 66 rows. A ratio taken over all rows therefore understates the problem badly and can never reach 100%, even when every mailbox capable of exhibiting it does.

#### When every indexed mailbox reads 0 B

One mailbox reading `0 B` is a gap in one row. Every indexed mailbox on the server reading `0 B` is a gap in the entire run, and the two need separate alerting. In the second case nothing collected could have crossed a threshold, so a clean result carries no information whatsoever.

`Monitor-BigFunnelPostingList.ps1` in this folder reports that state explicitly rather than leaving it to be inferred from a count:

| Where | Value | Meaning |
|---|---|---|
| `latest-summary.json` | `Status` = `MetricUnavailable` | Every indexed mailbox in scope reported `0 B`. Written on every run, whether or not alert exit codes were requested |
| Process exit code | `5` | The same condition, surfaced to the scheduler. Only under `-ExitNonZeroOnAlert` |
| Run log | Two `[ERROR]` lines | Gives the count, and states that the thresholds in that run were untested rather than passed |

> [!IMPORTANT]
> `Completed = false` does **not** cover this case, and a monitoring integration that alerts only on that field will miss it entirely. A run in this state completes and collects everything it was asked to collect. It simply cannot read the one counter it exists to read, so every threshold in it was applied to a constant zero. Alert on `Status = MetricUnavailable` as a separate condition, and treat it as a monitoring gap to raise rather than as a pass.

Exit code `5` is kept distinct from `1` deliberately. `1` means a mailbox crossed a line; `5` means there was no line to cross. Collapsing the two lets a metric outage be triaged as a threshold breach that turned out to be nothing, which is the same false negative in a different place.

The comparison is made against the indexed population rather than against every row collected, for the reason given above. Health, arbitration, system and archive mailboxes can never reach this state, so counting them in the denominator means the run-level escalation never fires on a real server.

Verified on the lab server described above, Exchange Server SE `15.2.2562.17`. With no intervention it reports 15 of 15 indexed mailboxes at `0 B`, exits `5`, and reports `Status = MetricUnavailable`. With a single controlled non-zero value present on one mailbox, the same server minutes later reports 14 of 15, exits `1`, and reports `Status = OK`. That pair is what separates "the metric is blind" from "the metric works and nothing crossed a line," and reproducing it is the check to run before trusting an absence of alerts on your own build.

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

`Monitor-BigFunnelPostingList.ps1`, in this folder, collects `BigFunnelPostingListTableTotalSize` for every mailbox on the databases in scope, evaluates configurable thresholds, and exports the result to CSV.

From its second run onwards it also compares each mailbox against an earlier collection, derives a growth rate, and ranks the mailboxes that are not yet over the threshold by how soon they are projected to cross it. On builds where the posting list table reads `0 B` it still ranks them, by growth rate, without projecting a date. See [Ranking mailboxes by how soon they cross](#ranking-mailboxes-by-how-soon-they-cross) for how to read that output.

Run it in Exchange Management Shell, or in any PowerShell session where the Exchange cmdlets are available. It targets Windows PowerShell 5.1 and takes no dependency on anything outside the Exchange management tools.

> [!IMPORTANT]
> Run the file, not a copy assembled out of this article. Earlier revisions of this runbook carried the whole script inline, and a copy taken from one of those has no `-Scope`, `-ThresholdMode`, `-MaxRunMinutes` or `-ExitNonZeroOnAlert`, writes neither `latest.csv` nor `latest-summary.json`, and has neither the `MetricUnavailable` status nor exit code `5`. Every exit code, contract and lab result described in this article refers to the file in this folder. The excerpts below are quoted from it for reading, and are not a substitute for it.

> [!NOTE]
> The script exports to CSV rather than sending mail. The `Send-MailMessage` cmdlet is obsolete and Microsoft recommends against using it because it does not guarantee a secure connection to the SMTP server. Integrate the CSV output with your organization's approved monitoring or alerting platform.

### What a run leaves behind

Everything lands under `-OutputPath`, which defaults to `%ProgramData%\ExchangeBigFunnelPostingListMonitor`.

| File | Written | Contents |
|---|---|---|
| `BigFunnelPostingListMonitor-<timestamp>.csv` | On any run that collected at least one mailbox | One row per mailbox: the size, the supporting counters, the status, and the trend fields once a baseline exists |
| `BigFunnelPostingListMonitor-<timestamp>.log` | On every run | The run transcript, including the two `[ERROR]` lines a `MetricUnavailable` run emits |
| `latest.csv` | Refreshed only when a run produced detail | A copy of the newest per-run CSV at a stable path, for a monitoring agent that reads files |
| `latest-summary.json` | On every run that gets far enough to have an output directory | The run verdict: `Completed`, `Status`, `ExitCode`, the status counts, and `TrendMetric` |

Per-run files older than `-RetentionDays` are pruned at the end of each run. The retention sweep matches on the `BigFunnelPostingListMonitor-*` prefix only, so the two stable files are never candidates for it and an integration reading just those keeps working at any retention setting.

### Parameters

```powershell
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
```

The defaults are the values this runbook recommends, so a run with no arguments at all is the intended configuration on a DAG member. Four parameters exist mainly because a monitoring integration needs them:

| Parameter | Effect |
|---|---|
| `-Scope` | `Local`, the default, collects only the databases whose active copy is mounted on this node. That is what makes one scheduled task correct on every DAG member and correct again after a switchover. `All` collects every database in the organization, which is right on exactly one member and wrong on all the others |
| `-ThresholdMode` | `Fixed` applies `-WarningGB` and `-CriticalGB` as given. `Adaptive` raises them to the collected population's 95th and 99th percentile where those sit higher, never lowers them, and falls back to the fixed values when fewer than `-AdaptiveMinimumSample` mailboxes were collected or when the two percentiles fail to separate |
| `-MaxRunMinutes` | A collection budget. Reaching it ends the run early and reports exit code `2`, so a collection cut short is never reported as a clean one |
| `-ExitNonZeroOnAlert` | Turns findings into the non-zero exit codes `1` and `5`. Without it the script exits `0` for anything short of a breakage and reports its findings through `latest-summary.json` only |

### How a mailbox is classified

Every threshold decision is made in one function, and the `0 B` finding is the last thing it tests before it is willing to call a mailbox healthy:

```powershell
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
```

`Critical` and `Warning` are findings about a size. `NotPopulated` is not: it says the mailbox reported a live index and a posting list table of exactly zero bytes, which is a statement about the counter rather than about the mailbox. On a build that never populates the table every indexed mailbox lands there, and that run-wide case is escalated separately as `MetricUnavailable`. See [When every indexed mailbox reads 0 B](#when-every-indexed-mailbox-reads-0-b).

### Verifying a copy before you rely on it

`Tests\run-tests.ps1` in this folder exercises the monitor against a mock Exchange module. It needs no Exchange installation, touches no mailbox, and runs on a workstation. Each case launches the monitor in its own `powershell.exe` with `-File`, the way a scheduled task invokes it, so the exit codes it asserts on are real process exit codes rather than inferred ones.

```powershell
# From this folder. No Exchange, no elevation, no network.
.\Tests\run-tests.ps1
```

It ends with a `RESULT: <n> passed, <n> failed` line and exits non-zero if anything failed. Run it after any local edit to the monitor, and run it before trusting a copy that reached you by some route other than this repository.

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
- **Interpret the exit code.** See [Exit codes and the run summary](#exit-codes-and-the-run-summary) below. A run that is missing entirely leaves a log file with no `Monitor run complete` line; that is how a killed run is identified, since it has no exit code to report.
- **Register the task with `-File`, never `-Command`.** `powershell.exe -Command` collapses every non-zero exit code to `1`. Exit codes `2`, `3`, `4`, `5` and `6` then all reach the scheduler looking like "at-risk mailboxes found", and a metric outage, an uncollected database or a projection days out cannot be told apart from a threshold breach. This is measured rather than assumed: a script whose only statement is `exit 5` returns `5` under `-File` and `1` under `-Command`, with no errors involved. The registration above already uses `-File`. Keep it that way in any wrapper script or monitoring agent that invokes the monitor on your behalf, and check the wrapper specifically, because a wrapper is where `-Command` usually creeps back in.

#### Exit codes and the run summary

The monitor reports through two independent channels: the process exit code, for a scheduler, and `latest-summary.json`, for a monitoring platform that reads files. They agree on every run, which makes each a check on the other.

| Code | Meaning | Alert |
|---:|---|---|
| `0` | Completed. All in-scope databases collected, nothing over threshold | No |
| `1` | Completed, at-risk mailboxes found. `-ExitNonZeroOnAlert` only | Yes, as a mailbox finding |
| `2` | Completed with partial failure. At least one database was not collected, or collection was cut short by `-MaxRunMinutes` | Yes, as a monitor fault |
| `3` | Fatal. Pre-flight failed, or no database was in scope | Yes, as a monitor fault, but see the DAG note below |
| `4` | Another instance is already running | Yes, as a monitor fault |
| `5` | Completed, but every indexed mailbox in scope reported the posting list table as `0 B`. `-ExitNonZeroOnAlert` only | Yes, as a monitoring gap |
| `6` | Completed, nothing over threshold, but at least one mailbox is projected to cross the critical threshold within 3 days. `-ExitNonZeroOnAlert` only | Yes, as a mailbox finding, but not as urgent as `1` |

Codes `2`, `3`, `4` and `5` all mean the monitor is not reporting on something, which is more urgent than a large posting list table because it is the state in which a large posting list table goes unseen. Route them differently from `1`.

Exit code `6` is the opposite case: the monitor is working and has found something that has not happened yet. `1` is work today; `6` is work before the weekend. They are separated rather than collapsed because a queue that treats them alike either drags the projections forward into the breach queue or lets the breaches sink into the projection one. If your scheduler cannot route two codes, treat `6` as non-zero and read `latest-summary.json` for which of the two it was.

Exit codes `1`, `5` and `6` require `-ExitNonZeroOnAlert`. Without it the script returns `0` for anything short of a breakage and reports its findings through `latest-summary.json` only, so that "found problems" is never confused with "the monitor broke". Add the switch when a scheduler is the thing consuming the result.

A run cannot return both `1` and `6`. Where a breach and a projection coexist, `1` wins, because the mailbox already over the line is the more urgent of the two and its meaning must not change. Read `Emerging` in the summary to see whether an exit-`1` run also carried projections.

`latest-summary.json` is written on every run that gets far enough to have an output directory, including runs that abort, and always carries the same field set. Its `Status` field on a run that completed is one of:

| `Status` | Meaning |
|---|---|
| `OK` | The run collected its scope and the counter was readable |
| `Partial` | At least one database was not collected. Pairs with exit code `2` |
| `MetricUnavailable` | Every indexed mailbox in scope reported the posting list table as `0 B`. Pairs with exit code `5`, but is reported whether or not `-ExitNonZeroOnAlert` was passed |

Alert on `Completed = false` to catch every abort reason, and read `Status` for the reason itself. `Completed = false` does not cover `MetricUnavailable`, which is a completed run: see [When every indexed mailbox reads 0 B](#when-every-indexed-mailbox-reads-0-b). `latest.csv` is refreshed only when a run produced detail, so it can legitimately be older than the summary sitting beside it.

`TrendMetric` in the summary names the counter growth was measured on. On a mixed estate it reads `Mixed`, meaning both counters were in use in the one run: the mailboxes whose posting list table is readable were trended on it and carry projected dates, and the mailboxes still reading `0 B` were trended on `IndexPayloadBytes` and carry a ranking instead. `TrendedOnPayload` gives the size of that second group.

Read `Emerging` as the answer only when `TrendedOnPayload` is `0`. Above zero, `Emerging` is keyed on a projected date and no date is produced on the fallback path, so it can only ever name mailboxes from the group the thresholds can see - a short list there is not evidence that the rest of the estate is quiet. Alert on `Growing` alongside it, and on `GrowingRanked` for the part of the estate that has an order but no dates. See [When the posting list table reads 0 B](#when-the-posting-list-table-reads-0-b).

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
[INFO] No previous run found. Growth trending begins from the next run.
```

Read that literally. On a first run the projection list is empty because there is no history, **not** because nothing is trending towards the threshold. Those two states look identical in a CSV and call for completely different responses, which is why the script distinguishes them in the log rather than leaving you to infer it from an absent section.

A run that has found a baseline names the file and the window it measured over, so the rates below it can be checked rather than taken on trust:

```output
[INFO] Comparing against [BigFunnelPostingListMonitor-20250114-060012-8244.csv], 24.02 hour(s) earlier, 1712 mailbox(es) baselined.
[INFO] Growth rate computed for 1698 mailbox(es) on PostingListBytes.
[INFO] 14 of 1712 mailbox(es) evaluated were not in the baseline and so have no projection yet. A mailbox created since the baseline was written, or one on a database that failed to collect on that run, has no earlier reading to difference against. A large count here means the ranking covers materially less of the estate than the row count suggests.
```

That last line matters on an estate that changes shape, and it is emitted only when the count is above zero. Before it existed those mailboxes were skipped in silence, so a run that could not see part of the estate and a run that found nothing to report produced an identical CSV.

#### Columns added by the trend join

These columns are written to the CSV for every mailbox that could be matched to a baseline. They are blank on a first run, and blank on any mailbox with no earlier reading.

| Column | Meaning |
|---|---|
| `PreviousBytes` | The same mailbox's size in the baseline run, in bytes |
| `DeltaBytes` | Change since the baseline. Negative after successful remediation |
| `GrowthGBPerDay` | `DeltaBytes` normalized to a 24-hour rate. This is the number to compare between mailboxes; raw deltas are not comparable unless both were measured over the same window |
| `MeasuredGB` | The current size of whichever counter `TrendMetric` names. Read this rather than `PostingListGB` alongside a growth rate: on a build where the posting list table reads `0 B` the two columns describe different things, and `PostingListGB` would report `0` next to a non-zero rate |
| `DaysToCritical` | Days until this mailbox reaches the critical threshold at its current rate. `0` means it is already at or past it. Blank means one of three things: the mailbox is flat or shrinking, it had no baseline to compare against, or growth was measured on a counter the thresholds do not describe. See [When the posting list table reads 0 B](#when-the-posting-list-table-reads-0-b) |
| `Trend` | `Growing`, `Flat`, or `Shrinking`. A 1 MB tolerance either side of zero keeps ordinary churn out of the growing and shrinking counts |
| `TrendWindowHours` | How far apart the two readings actually were. A short window magnifies noise, so this qualifies every rate on the row |
| `TrendMetric` | Which counter the rate was measured on, `PostingListBytes` or `IndexPayloadBytes`. See [When the posting list table reads 0 B](#when-the-posting-list-table-reads-0-b) |

#### The emerging list

Mailboxes below the warning threshold but projected to reach the **critical** threshold within 3 days are listed in the log, soonest first. The full set is in the CSV, in the `DaysToCritical` column:

```output
[WARN] Emerging: [a1f3...] Contoso Dispatch on [DB04] is 1.61 GB but projected critical in 1.15 day(s).
[WARN] Emerging: [7c02...] Shared AP Inbox on [DB01] is 1.44 GB but projected critical in 2.78 day(s).
```

The three-day window is fixed and is not a parameter. It is the lead time the thresholds exist to buy: a mailbox climbing 0.3 GB per day crosses both lines between two daily samples, so a window shorter than the gap between one sample and the next would let it appear and cross unseen.

The ordering is the point, and it is an ordering by time rather than by size. The top of the list is the work to do before the weekend rather than the work to explain afterwards, and a mailbox projected to cross in 1.15 days needs attention ahead of a larger one 2.78 days out. This matters most when `-MaxAlertDetail` truncates the list: what survives the cap is the head of it, and the remainder is reported as a count.

```output
[WARN] ...and 5 further emerging mailbox(es) not listed, all of them further out than the ones above.
```

Mailboxes already at or past a threshold are deliberately **excluded** from this list. They appear in the at-risk lines above it, and they need remediating rather than predicting; including them would put a block of zeroes at the top and bury the mailboxes that can still be reached in time.

Under `-ExitNonZeroOnAlert`, a run whose only finding is an emerging mailbox exits `6`. A run that also has a mailbox over a threshold exits `1`, and the emerging entries are still in the log and the CSV.

#### When the posting list table reads 0 B

On builds where `BigFunnelPostingListTableTotalSize` reads exactly `0 B` across an indexed population (see [Confirm the metric is populated before you trust it](#confirm-the-metric-is-populated-before-you-trust-it)), ranking on that column would sort the whole estate by a value that is zero for every row, producing an arbitrary order that still looks authoritative. The script detects this from the collected data and measures growth on the combined POI and filter sizes instead, announcing the substitution:

```output
[WARN] BigFunnelPostingListTableTotalSize is 0 B for all 1712 mailbox(es) in scope, so growth is being measured on IndexPayloadBytes instead. The ordering below is still meaningful - the mailbox at the top is genuinely the one growing fastest. No date is given: ...
```

On this path the output is a **ranking without dates**. `DaysToCritical` stays blank and the list is headed differently:

```output
[WARN] 47 mailbox(es) grew over the 24.02-hour window, measured on IndexPayloadBytes. They are ranked fastest first below. No projected date is given, for the reason logged above; treat this as the order to work through, not a countdown.
[WARN] Fastest growing #1: [a1f3...] Contoso Dispatch on [DB04] at 0.412 GB, growing 0.0386 GB/day on IndexPayloadBytes.
[WARN] Fastest growing #2: [7c02...] Shared AP Inbox on [DB01] at 0.298 GB, growing 0.0329 GB/day on IndexPayloadBytes.
```

The ordering is genuine and is what you act on: the mailbox at the top is the one whose index is growing fastest, and that is still the answer to "which one is next". The dates are withheld rather than estimated, because `-WarningGB` and `-CriticalGB` are sizes of the posting list table and have never been validated against this counter. Extrapolating one to the other compares unrelated quantities. The index payload here is typically single-digit megabytes against a two-gigabyte threshold, so every projection would land months out and the three-day window would discard the entire list. A monitor that returns nothing while reporting no problem is worse than one that declines to guess.

To get dates back on such a build, establish what a problematic `IndexPayloadBytes` looks like on your own estate first. Collect for a few weeks, find the sizes at which search actually degrades, and set `-WarningGB` and `-CriticalGB` from that. Until then, work the ranking top-down.

##### When only part of the estate reads 0 B

The choice of counter is made per mailbox, not per run. An estate part-way through the transition holds both kinds at once, and both reports appear in the same run:

```output
[WARN] Growth on this run is split across two counters. 9 of 15 mailbox(es) in scope carry no posting list table reading and are trended on IndexPayloadBytes; the remaining 6 are trended on BigFunnelPostingListTableTotalSize. ...
```

`TrendMetric` in the summary reads `Mixed` on such a run, and `TrendedOnPayload` gives the size of the fallback group. Both reports are real: the posting list rows carry projected dates and appear in the emerging list, and the payload rows carry a ranking and no dates.

Read the emerging list on a mixed run as a partial answer. It can only name mailboxes the thresholds can see, so a short list there says nothing about the `TrendedOnPayload` group - work the ranking for those.

This is worth stating because the alternative is not hypothetical. When the counter was chosen once per run, a single mailbox crossing the allocation threshold moved the whole scope onto the posting list table, including the mailboxes still reading `0 B`, whose growth then measured as a constant zero. Measured in the lab on Exchange Server SE 15.2.2562.17: at 17:16 the run trended 18 mailboxes on `IndexPayloadBytes` and ranked them; at 17:43, two *other* mailboxes having crossed the allocation threshold in the interval, the same 18 - unchanged in every other respect - were trended on a counter that reads zero for them, and the ranking that exists to name the next mailbox went blind for most of the population.

#### Parameters that control the projection

| Parameter | Default | What to consider when changing it |
|---|---:|---|
| `-TrendBaselineHours` | `24` | How far back to reach for the comparison run. Short windows magnify noise: at a 15-minute cadence a delta is multiplied by 96 to reach a daily rate, so a few megabytes of ordinary churn reads as a trend and the projection swings between runs. If the history is not yet this deep the widest window available is used and the run is marked provisional. Accepts `1`–`8760` |
| `-MaxAlertDetail` | `25` | Caps per-mailbox detail in the log, so a large estate does not make the monitor its own disk-space problem. Every capped list is sorted worst-first - by status and size for the at-risk lines, by how soon it crosses for the emerging list - so what survives the cap is the part worth reading, and the remainder is reported as a count rather than dropped silently. The full set is always in the CSV. Accepts `1`–`10000` |

There is no parameter for how far ahead the emerging list looks. The three-day window is fixed in the script, for the reason given in [The emerging list](#the-emerging-list).

> [!IMPORTANT]
> The projection is a linear extrapolation of one interval. It is a work queue, not a forecast: mailbox growth is driven by user behavior and rarely stays linear for three days. Use the ordering to decide what to look at first, and re-read it each run rather than planning against a specific date. A mailbox whose rate came from a window shorter than `-TrendBaselineHours` is flagged provisional in the log for exactly this reason.

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
