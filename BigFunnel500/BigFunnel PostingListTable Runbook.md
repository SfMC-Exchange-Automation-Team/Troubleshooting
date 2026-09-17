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
| Many mailboxes above threshold | Monitor, prioritize, and batch moves under change control | Exchange Server 2019 and Exchange Server SE workload management (WLM) throttling defaults to 10 simultaneous mailbox moves from the same source or to the same target; batching and automation are required at scale |

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

Two explanations fit that result: the build may account for posting list data elsewhere regardless of content volume, or the counter may materialize only above an allocation threshold that 5.699 MB of content does not reach. A later pass on the same lab separated them, and it is the second.

Three mailboxes were seeded on `15.2.2562.17` and measured together:

| Mailbox | Items | Content | `BigFunnelPostingListTableTotalSize` |
|---|---|---|---|
| `bfseed03` | 142 | 3.447 MB | `0 B` |
| `bfseed02` | 272 | 6.87 MB | `0 B` |
| `bfseed01` | 740 | 16.33 MB | **`3.344 MB (3,506,176 bytes)`** |

`bfseed01` had itself read `0 B` at 380 items after three weeks of sitting, and moved off zero the same afternoon it was topped up to 740. Elapsed time is therefore not the variable; content volume is. **The table is allocated somewhere between roughly 6.9 MB and 16.3 MB of mailbox content.**

This changes how a `0 B` reading must be read. Below the allocation point, `0 B` is the *correct* value and not a symptom of anything - the table has not been created yet because there is not enough in the mailbox to warrant one. Above it, `0 B` on an indexed mailbox is a real monitoring gap. The same three corroborating counters still apply, but the mailbox's own size is now the first thing to check:

| Reading | Interpretation | Action |
|---|---|---|
| `BigFunnelPostingListTableTotalSize` above `0 B` | The metric is populated on this build | Apply the thresholds in the next section |
| `0 B`, with `BigFunnelIndexedCount` at `0` | The mailbox has no index yet | Investigate indexing; this is not a table-growth question |
| `0 B`, indexed, and holding less than ~16 MB | Expected. The table has not been allocated at that size | None. Do not read it as a fault |
| `0 B`, indexed, and holding well above ~16 MB | The mailbox is indexed but the size is not accounted for in this counter | Do not read this as healthy. Check `BigFunnelTotalPOISize`, `BigFunnelLargePOITableTotalSize`, and `BigFunnelFilterTableTotalSize` for where the index size actually is |

> [!IMPORTANT]
> If every mailbox on a database reports `0 B` while reporting a non-zero `BigFunnelIndexedCount`, **and those mailboxes are large enough to have allocated a table**, threshold alerting on this metric cannot fire there. A clean monitoring run then says nothing about posting list growth - it says only that nothing could have been found. Validate the counter against at least one mailbox known to exhibit the problem before treating an absence of alerts as evidence of health. The monitoring script in the next section refuses to record this as a pass at either level: each affected mailbox is classified `NotPopulated` rather than `Normal`, and the run as a whole reports `Status = MetricUnavailable` rather than `OK`. The size qualifier is load-bearing: without it, an estate of small mailboxes - a lab, a new deployment, a small tenant - reports a total metric outage on every run, and an alert that always fires is an alert that gets muted.

When you judge how widespread the condition is, count it against the mailboxes that could actually exhibit it: indexed, and above the allocation point. Two separate populations have to come out of the denominator. Health, arbitration, system and archive mailboxes hold no BigFunnel index at all; on the lab server above they were 44 of 66 rows. Mailboxes below roughly 16 MB read `0 B` correctly and are not evidence of anything. A ratio taken over all rows understates the problem badly and can never reach 100%; a ratio that counts small mailboxes as witnesses overstates it and reaches 100% on a perfectly healthy small estate.

#### When every indexed mailbox reads 0 B

One mailbox reading `0 B` is a gap in one row. Every eligible mailbox on the server reading `0 B` is a gap in the entire run, and the two need separate alerting. In the second case nothing collected could have crossed a threshold, so a clean result carries no information whatsoever.

`Monitor-BigFunnelPostingList.ps1` in this folder reports that state explicitly rather than leaving it to be inferred from a count:

| Where | Value | Meaning |
|---|---|---|
| `latest-summary.json` | `Status` = `MetricUnavailable` | Every eligible mailbox in scope reported `0 B`. Written on every run, whether or not alert exit codes were requested |
| `latest-summary.json` | `MetricValidation` = `Blind` | The same fact stated as a verdict on the instrument rather than on the estate |
| Process exit code | `5` | The same condition, surfaced to the scheduler. Only under `-ExitNonZeroOnAlert` |
| Run log | Two `[ERROR]` lines | Gives the count, and states that the thresholds in that run were untested rather than passed |

> [!IMPORTANT]
> `Completed = false` does **not** cover this case, and a monitoring integration that alerts only on that field will miss it entirely. A run in this state completes and collects everything it was asked to collect. It simply cannot read the one counter it exists to read, so every threshold in it was applied to a constant zero. Alert on `Status = MetricUnavailable` as a separate condition, and treat it as a monitoring gap to raise rather than as a pass.

Exit code `5` is kept distinct from `1` deliberately. `1` means a mailbox crossed a line; `5` means there was no line to cross. Collapsing the two lets a metric outage be triaged as a threshold breach that turned out to be nothing, which is the same false negative in a different place.

The comparison is made against the eligible population rather than against every row collected, for the reasons given above - indexed, because health, arbitration, system and archive mailboxes can never reach this state and counting them means the escalation never fires on a real server; and above the allocation point, because counting mailboxes that read `0 B` correctly means it fires on every small server.

#### When nothing in scope is large enough to say

There is a third case, and it is the common one on a small or newly built estate: no mailbox in scope has a populated posting list table, **and** no mailbox is large enough to have been expected to. The run cannot tell whether the counter works. That is not a fault, and alerting on it would fire forever.

`Monitor-BigFunnelPostingList.ps1` reports it as `Status = MetricInconclusive` and `MetricValidation = Inconclusive`, logs a single `WARN` naming the largest mailbox it saw and the bar it fell short of, and **leaves the exit code alone**. Mailboxes in this state are `NotAllocated` in the detail CSV, not `NotPopulated`.

Read it as "this run proved nothing", not as "this run passed". To convert it into a real answer, put one mailbox above the bar - seed it, or wait for one to get there - and the next run will return `Confirmed` or `Blind`.

#### Where the bar comes from

The script does not carry a fixed size. It calibrates against the estate in front of it, the same way `-ThresholdMode Adaptive` derives thresholds from the population:

| Situation | Bar | `AllocationEvidenceBasis` |
|---|---|---|
| Some mailbox in scope has a populated table | The smallest such mailbox's `TotalItemSize`, clamped up to a 16 MB floor | `Observed` |
| No mailbox in scope has one | `-AllocationEvidenceMB`, default `64` | `Configured` |

An observed bar is a direct measurement of the allocation point on the build actually in front of you, which beats any constant chosen in advance. The 16 MB floor exists because the smallest populated mailbox is only an *upper* bound: a mailbox that was large when its table was allocated and has since been emptied would otherwise drag the bar down and reclassify a healthy estate as `NotPopulated`. The clamp can only move the bar up, which errs toward "expected" - the safe direction, because a missed outage costs one quiet run and a false outage costs a muted monitor.

The 64 MB fallback is roughly four times the upper bound of the measured range, so a `Blind` verdict reached under it is close to unarguable. Both the bar in force and its basis are published in `latest-summary.json` on every run.

Verified on the lab server described above, Exchange Server SE `15.2.2562.17`. With no intervention it reports 15 of 15 eligible mailboxes at `0 B`, exits `5`, and reports `Status = MetricUnavailable`. With a single controlled non-zero value present on one mailbox, the same server minutes later reports 14 of 15, exits `1`, and reports `Status = Alert` - a threshold crossed on a counter that demonstrably reads. That pair is what separates "the metric is blind" from "the metric works and has something to say," and reproducing it is the check to run before trusting an absence of alerts on your own build.

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

Run it from any Windows PowerShell 5.1 session. It does not need to be an Exchange Management Shell: the script opens its own remote Exchange runspace against the local server's PowerShell vdir, and reuses an existing import when it finds one, so running it from EMS costs nothing extra. It takes no dependency on anything outside the Exchange management tools.

> [!IMPORTANT]
> **The in-process Exchange snap-in is never used, and that is deliberate.** A store cmdlet loaded by `Add-PSSnapin` binds the store from the calling process, and an in-process bind reaches only a store on the same server - so a `-Scope All` run under it drops every database mounted on another DAG member and still writes a complete-looking summary. Measured on a three-node DAG, same server and minute: the snap-in collected 50 mailboxes across 2 of 4 databases and reported `Partial`; the runspace collected 97 across all 4 and reported `OK`. A run that cannot open a runspace exits `3` rather than collecting a subset. `-ConnectionUri` points at another Exchange server in the organisation where the local vdir is not the one to use; it does not have to be the node holding the database. `latest-summary.json` records which binding was used in `Binding`, and where, in `ConnectionUri`.

> [!NOTE]
> **Every run reports on the console, whether or not you ask it to.** A header, a line per database as it is collected, any warning or error inline, and then a verdict block: the status, the counts behind it, which mailboxes carry a posting list table, the worst affected, the paths to the CSV and the log, and the exit code. Status and counts are coloured. `-Verbose` adds the timestamped `[INFO]`/`[WARN]`/`[ERROR]` stream underneath, which is the troubleshooting layer rather than the only way to learn what happened - before v1.7.6 it was the only way, and a default run printed nothing at all. Long explanations are written to the log in full and abbreviated on screen, so the verdict is not pushed off the top of the window by the reasoning behind it. `-Quiet` removes the report for a wrapper that parses instead of reads; it suppresses decoration, never evidence, so the log, both stable files and the exit code are unaffected. See [Reading a run on screen](#reading-a-run-on-screen).

> [!NOTE]
> **The script elevates itself, and the report survives the window that opens to do it.** Started from an ordinary console it relaunches under UAC with the same parameters, waits, and exits with that run's code, so the stable files cannot end up owned by an administrator and then be unwritable to the next non-elevated run. What that costs is a console: an elevated process cannot attach to the console of the non-elevated one that asked for it, so the relaunch gets a window of its own and Windows closes it the moment the run ends. Before v1.11.0 that left the operator approving a consent prompt, watching a console flash past, and holding two lines and a path to a log file. The child now writes each console line to a relay file in the parent's `TEMP` as it prints it, and the parent replays the file - colours included - into the window the operator is actually looking at. Line by line rather than buffered, so a child that dies mid-run still relays what it managed to say; where `TEMP` is not set the relay is skipped and the run falls back to reporting the exit code and the log path. `-NoElevate` opts out of the whole arrangement, which is right wherever the output directory is already owned by the account running the script, and `-Quiet` relays nothing because there is nothing to relay.

> [!IMPORTANT]
> Run the file, not a copy assembled out of this article. Earlier revisions of this runbook carried the whole script inline, and a copy taken from one of those has no `-Scope`, `-ThresholdMode`, `-MaxRunMinutes` or `-ExitNonZeroOnAlert`, writes neither `latest.csv` nor `latest-summary.json`, and has neither the `MetricUnavailable` status nor exit code `5`. Every exit code, contract and lab result described in this article refers to the file in this folder. The excerpts below are quoted from it for reading, and are not a substitute for it.

> [!NOTE]
> The script exports to CSV rather than sending mail. The `Send-MailMessage` cmdlet is obsolete and Microsoft recommends against using it because it does not guarantee a secure connection to the SMTP server. Where a log aggregator is the consumer rather than a person, `-EmitTo` writes the run to the Windows event log, to a per-run JSON file, or to both, in a shape a forwarder reads with no configuration. See [Feeding a log aggregator](#feeding-a-log-aggregator).

### Reading a run on screen

A run started by hand looks like this. Nothing was passed but `-Scope Local`:

```text
BigFunnel PostingListTable monitor v1.13.0
run 20260915-121458-317452 on EXCH-01

Scope Local - 3 database(s) in scope
  MDB01............................. 7 mailbox(es)
  MDB02............................. 7 mailbox(es)
  MDB03............................. 7 mailbox(es)
  - 3 mailbox(es) were skipped because their size value could not be parsed.
  - 3 mailbox(es) were skipped because BigFunnelPostingListTableTotalSize held no readable value - Unlimited, or present but empty. They are absent from the detail below; do not read that as a size of zero.

  RESULT  Alert
  15 mailbox(es) evaluated in 1.1s  (bind 0.4s, discover 0.1s, collect 0.5s)

    Critical             3
    Warning              3
    Emerging             0
    Databases failed     0
    Counter              Confirmed
    Posting list table   15 of 15 mailbox(es) - see the report

  Growth
    No baseline old enough to measure against. The next run is the first that can.

  Worst affected
    Critical  Ana Ilic on MDB02  2.4 GB  no rate yet
    Critical  Ana Ilic on MDB03  2.4 GB  no rate yet
    Critical  Ana Ilic on MDB01  2.4 GB  no rate yet
    ...and 3 more in the report below

  Report  C:\ProgramData\ExchangeBigFunnelPostingListMonitor\BigFunnelPostingListMonitor-20260914-224627-1556648.csv
  Log     C:\ProgramData\ExchangeBigFunnelPostingListMonitor\BigFunnelPostingListMonitor-20260914-224627-1556648.log

  Exit code 0
  0 because -ExitNonZeroOnAlert was not passed. The finding above is still real.
```

That is a first run, which is why every finding reads `no rate yet` rather than
carrying a rate: there is no earlier run to difference against. From the second
run onward those tails carry the measured growth instead.

On an estate where only a handful of mailboxes have allocated a posting list
table, that same block names them instead of counting them:

```text
    Critical             1
    Warning              1
    Emerging             1
    Databases failed     0
    Counter              Confirmed

  Posting list table present on 3 of 97 mailbox(es)
    Critical  bfseed03 on clab-daga-db02  0.704 GB  not growing
    Warning   bfseed01 on clab-daga-db02  0.566 GB  not growing
    Emerging  bfseed02 on clab-daga-db02  0.453 GB  +0.0787 GB/day, critical in 2.5 day(s)

  Growth  measured over 48h, against run 20260913-095608-000000
    Two counters in use: 3 dated on BigFunnelPostingListTableTotalSize, 37 ranked only on IndexPayloadBytes.
    Nothing else grew measurably over that window.
```

When those same three mailboxes are healthy, the block does not list them. It
says how many there are and how many it held back:

```text
  Posting list table present on 3 of 97 mailbox(es)
    3 reading Normal, not listed. -Verbose lists them.

  Growth  measured over 36.88h, against run 20260913-214541-18364
    Two counters in use: 3 dated on BigFunnelPostingListTableTotalSize, 37 ranked only on IndexPayloadBytes.
    Nothing grew measurably over that window.
```

Eight things in those blocks are easy to misread:

**`RESULT Alert` above `Exit code 0` is not a contradiction.** Exit codes `1`, `5` and `6` are gated behind `-ExitNonZeroOnAlert` so that adding this monitor to an existing scheduler cannot start failing tasks on the day it is deployed. The finding is real either way and `latest-summary.json` records it as `Status: Alert`. The line under the exit code says so rather than leaving you to work it out.

**A count of zero is still printed.** A row missing because the number was zero reads identically to a row missing because the run never looked, so every category is listed on every run.

**`Counter` is the metric-validation verdict, not a count.** `Confirmed` means at least one mailbox in scope has a populated posting list table, so the thresholds above were applied to real numbers. `Blind` means nothing was populated and something in scope was large enough that it should have been - that is a monitoring gap and it is red. `Inconclusive` means nothing was populated and nothing was large enough to prove it either way, which is the expected steady state of a small estate. See [Confirm the metric is populated before you trust it](#confirm-the-metric-is-populated-before-you-trust-it).

**`Worst affected` is a sample, capped at three.** It is there so you know whether to open the CSV, not instead of opening it. A bad estate can hold hundreds of at-risk mailboxes; printing them all would push the verdict off the top of the window on exactly the run that most needs reading. The full list is in the CSV and in the log. It is skipped altogether when the `Posting list table` block above it has already named every at-risk mailbox, which is the normal case on an estate where only a few mailboxes have allocated the table at all - the two lists were identical, printed one under the other, under different headings.

**`Posting list table` switches between a roll call and a count.** Ten or fewer, and the ones that are a finding are named with their database and size, because that is the question a bare count raises and the only other way to answer it was the 32-column CSV. Above ten it collapses to a single line: a hundred names would be the whole report. A row that is driving the `Emerging` count is labelled `Emerging` there rather than `Normal`, with its projected date - `Emerging` is not a status in the CSV, it is `Normal` plus a projection inside three days, so the count above would otherwise have nothing on screen to attach itself to.

**Every finding carries its own growth rate; a size on its own is half the picture.** `Critical ... 0.704 GB  not growing` and `Critical ... 0.704 GB  +0.4 GB/day` are the same size and different problems, and the second is the one to act on this week. Both blocks that name a mailbox annotate it - the roll call on a small estate, `Worst affected` on a large one - so the amount the report says about growth does not fall away as the estate grows. The tail on each row is the rate, then the projected date where the thresholds can produce one. Three tails mean three different things: `+N GB/day, critical in N day(s)` is a mailbox with a measured rate and a crossing point; `+N GB/day` alone is a mailbox already past Critical, where a projection to Critical would be meaningless; `+N GB/day on index payload, no projected date` is trended on a counter the thresholds do not describe, so the rate is real and no crossing point exists. `not growing` means the script measured it and it did not move. `no rate yet` means there was no baseline to measure against - not the same claim, and the difference matters when you are deciding whether to wait a day.

**`Growth` is the only block that is not about current size.** Everything above it - the counts, the roll call, `Worst affected` - is a size measured against a threshold. This block is the provenance for every rate on screen: the window it was measured over and the run it was measured against, and both matter, because `0.02 GB/day` off a 40-hour window and off a 40-minute one are not the same claim. Under that it lists what the roll call did not already name, fastest first and capped at three - mailboxes that are growing but are not yet a finding, which nothing else in the report can show. `Nothing else grew` and `Nothing grew` are deliberately different sentences: the first is what a run says when it has already printed rates above. On a first run the block says it has no baseline rather than reporting zero growth. The two-counter caveat prints here, directly above the rates it qualifies; before v1.9.0 it printed at collection time, roughly ten lines above any growth number and immediately below nine lines of sizes.

**The roll call names findings, not mailboxes that are fine.** A `Normal` row is the absence of a finding, and a verdict block that spends a line each saying mailboxes are healthy is the wall of text this block exists to avoid - on a clean estate every line in it would be one. They are counted, and the line below says how many were held back and how to see them; `-Verbose` lists them in the same shape as the rest. The count and the CSV are unaffected either way.

A run that aborts before it collects anything prints the same shape with `RESULT` naming the abort reason and a pointer to the log, rather than returning you to a bare prompt.

### What a run leaves behind

Everything lands under `-OutputPath`, which defaults to `%ProgramData%\ExchangeBigFunnelPostingListMonitor`.

| File | Written | Contents |
|---|---|---|
| `BigFunnelPostingListMonitor-<timestamp>.csv` | On any run that collected at least one mailbox | One row per mailbox: the size, the supporting counters, the status, and the trend fields once a baseline exists |
| `BigFunnelPostingListMonitor-<timestamp>.log` | On every run | The run transcript, including the two `[ERROR]` lines a `MetricUnavailable` run emits |
| `BigFunnelPostingListMonitor-<runid>.json` | Only when `-EmitTo` includes `RunJson` | The same summary object as `latest-summary.json`, kept per run instead of overwritten. See [Feeding a log aggregator](#feeding-a-log-aggregator) |
| `latest.csv` | Refreshed only when a run produced detail | A copy of the newest per-run CSV at a stable path, for a monitoring agent that reads files |
| `latest-summary.json` | On every run that gets far enough to have an output directory | The run verdict: `Completed`, `Status`, `ExitCode`, the status counts, and `TrendMetric`, plus what the run cost - see [How long a run takes, and where the time goes](#how-long-a-run-takes-and-where-the-time-goes) |

Those last two are the stable pair, and they are the only files a scheduled consumer reads. A run that cannot refresh either one exits `3` and names the reason in `PublishErrors`, rather than returning success over a pair that still describes an earlier run. A `latest.csv` deliberately skipped because the run produced no detail is not that case and does not affect the exit code.

Per-run files older than `-RetentionDays` are pruned at the end of each run. The retention sweep matches on the `BigFunnelPostingListMonitor-*` prefix only, so the two stable files are never candidates for it and an integration reading just those keeps working at any retention setting. The per-run JSON is named **inside** that prefix deliberately, so it is swept by the same pass with no second rotation mechanism to configure or forget — the exact mirror of why the stable pair is named outside it.

### Querying a run instead of reading it

The console report is a summary, and the CSV is the full picture, but neither answers an arbitrary question without either scrolling or opening a 32-column file in something. `-PassThru` emits the collected rows on the success stream as well, so the run becomes a variable:

```powershell
$r = .\Monitor-BigFunnelPostingList.ps1 -Scope All -PassThru

$r | Where-Object Status -eq 'Critical' | Select-Object DisplayName, Database, PostingListGB
$r | Sort-Object GrowthGBPerDay -Descending | Select-Object -First 5 DisplayName, GrowthGBPerDay, DaysToCritical
$r | Where-Object { $_.DaysToCritical -gt 0 -and $_.DaysToCritical -le 14 } | Measure-Object
$r | Group-Object Database | Sort-Object Count -Descending
```

These are the same `[pscustomobject]` rows the report and the CSV are both built from, not a re-read of the file. They are typed `BigFunnel.PostingListRow`, so a downstream script can test the type rather than duck-typing on column names.

**The types survive, which is the point.** `Import-Csv` hands back strings, and a string sort puts `0.9` above `0.0787` - correct lexically and wrong for a growth rate. Off the objects, `PostingListGB`, `GrowthGBPerDay` and `DaysToCritical` are doubles and sort and compare as numbers.

Two things to know before wiring it into anything:

- **Pair it with `-Quiet` when the caller wants data rather than a report.** Without `-Quiet` the report still prints - it goes out through `Write-Host`, so it will not contaminate `$r`, but it will still be on screen.
- **It returns nothing across an elevation relaunch.** The rows are built in the elevated child process, and what crosses back to the parent is its exit code and a replay of its console report - not its pipeline. So a `-PassThru` run that elevates hands back an empty pipeline, which is indistinguishable from a run that found no mailboxes, even though the report on screen plainly says otherwise. The script warns before the consent prompt when both apply. Run it from an already-elevated session, or read the CSV the child writes.

### Feeding a log aggregator

The two stable files answer *what is true now*. A log aggregator asks *what happened over time*, and `latest-summary.json` structurally cannot answer that: every run destroys the previous answer. `-EmitTo` adds the channels that can.

```powershell
# Both channels. Add them to whatever the run already was.
.\Monitor-BigFunnelPostingList.ps1 -Scope Local -EmitTo EventLog,RunJson
```

| Parameter | Effect |
|---|---|
| `-EmitTo` | `EventLog`, `RunJson`, or both. **Empty by default**, so a run that does not ask for them behaves exactly as it did before they existed |
| `-EventLogSource` | The event source to write under. Defaults to `BigFunnelPostingListMonitor` |

Neither channel replaces the stable pair, and neither is on unless asked for. Pick by what your forwarder can reach: an estate that cannot get a file path allowlisted takes `EventLog`; one that can, and would rather not touch the event log, takes `RunJson`. Taking both is the reason this is a list rather than a switch.

> [!IMPORTANT]
> **An emit failure never changes the exit code, and that is a deliberate contract.** These are additional channels, not the reporting contract, and adding this monitor to an existing scheduler must not start failing tasks on the day a channel is switched on. A channel that fails records its reason in the summary's `EmitErrors` field and `WARN`s it in the log - visible, never fatal. That cuts the other way too, and it is why the field exists: an estate whose *only* channel is the event log must not have it fail silently. A non-empty `EmitErrors` beside `Status OK` and `ExitCode 0` is the correct reading of a healthy run whose forwarder feed is broken. `EmitErrors` and `PublishErrors` are kept separate for the same reason - one collection would lose the distinction in the direction that breaks a customer's scheduler.

#### `EventLog`

One event for the run, then one per at-risk or emerging mailbox, written to the **Application** log. The run's `Status` selects the event ID and the entry type. Findings are Warnings and monitor faults are Errors, which is the exit-code philosophy applied to a second channel: a full posting list table is the estate's problem, and a monitor that could not measure one is this script's.

| Event ID | Raised when | Entry type |
|---:|---|---|
| `1000` | `Status OK` | Information |
| `1001` | `Status Emerging` | Warning |
| `1002` | `Status Alert` | Warning |
| `1003` | `Status Partial` | Error |
| `1004` | `Status MetricUnavailable` | Error |
| `1005` | `Status MetricInconclusive` | Information |
| `1006` | `Status PublishFailed` | Error |
| `1007` | **The run aborted before it finished.** `Status` carries the free-form reason | Error |
| `1099` | A completed run whose `Status` this table does not cover | Warning |
| `1010` | A mailbox at or above the critical threshold | Warning |
| `1011` | A mailbox at or above the warning threshold | Warning |
| `1012` | A mailbox projected to cross critical inside the lead-time window | Warning |

Three of those need explaining before you build a search on them.

**`1007` is the one to alert on hardest.** An aborted run leaves `latest.csv` untouched, so a consumer reading that file's timestamp sees only that nothing changed - which is exactly what a healthy estate looks like. A monitor that stopped reporting and an estate with nothing wrong are indistinguishable from the file side, and this event is the difference.

**`1099` means this article is out of date, not that your estate is.** It fires when the script's status chain has grown a value the event table does not cover. It is emitted rather than dropped because a missing event and a run that never happened look identical to a forwarder. Treat it as a monitoring defect and report it.

**`1006` can only be raised here.** `latest-summary.json` is built before it is written, so it can never report its own failure to be written - the file cannot describe its own absence. The emit runs after that attempt and after the exit code is final, so a run whose summary could not be published still emits `PublishFailed` with the reason in `PublishErrors`. For an estate collecting by forwarder that is not a detail; it is the reason to run this channel at all, because it is the only one that stays up when the file a poller reads goes stale.

The payload is `key=value`, one field per line. Event Viewer renders it with no parser, which matters because the person triaging at 3am is reading the event, not the index:

```text
RunId=20260916-120000-4242
ScriptVersion=1.13.0
Timestamp=2026-09-16T12:00:00.0000000+02:00
Server=EXCH-01
Scope=Local
Status=Alert
Completed=true
ExitCode=0
MetricValidation=Confirmed
Critical=3
Warning=3
Emerging=0
FailedDatabases=""
PublishErrors=""
```

> [!WARNING]
> **Splunk does not parse this payload without configuration, and an earlier revision of this article said it did.** Measured on Splunk Enterprise 10.4.3 against this monitor's own events: the Windows event *header* is extracted as usual - `EventCode`, `SourceName`, `ComputerName`, `Type` and six more - and the entire `key=value` body arrives intact inside the `Message` field and is **not** broken out. `Status`, `MailboxesEvaluated`, `BindSeconds` and the other 47 do not exist as fields, so every search in this section returns nothing until a `props.conf` is in place. Setting `KV_MODE = auto` on the sourcetype does **not** fix it; the stanzas that do are in [A worked Splunk configuration](#a-worked-splunk-configuration) below, and they were applied to a live indexer and re-measured rather than proposed. The `RunJson` channel needs none of this - Splunk parses JSON at index time on its own.

Four encoding rules, each of which exists because the alternative breaks a search silently:

- A value with no whitespace is left **unquoted**, which is the form field extraction prefers.
- A value containing a space is **quoted**, because an unquoted space is where extraction stops - silently, taking every later field on the line with it.
- A newline inside a value is **folded to a space**. A line break splits one record into two at the forwarder, and the second half arrives with no timestamp and no context.
- An embedded `"` becomes `'`. Backslash-escaping is what a JSON reader expects and not what Event Viewer renders, and here both read the same string.

The quoting rule survives the extraction intact, which is worth knowing because it is not obvious from either side: with the configuration below, `ExchangeVersion="Version 15.2 (Build 2562.17)"` extracts as `Version 15.2 (Build 2562.17)` - the quotes are consumed by the extraction, not carried into the value - so a search matches the bare string and `Binding="EMS (Kerberos)"` finds the events it should. Quote the value in the payload; do not quote it in the search.

A boolean is rendered lower case, a null is an empty value rather than the word `null` or a missing key, and a payload approaching the event log's 32,766-character ceiling is clipped at 31,000 with a `[truncated]` marker - an event that silently stops mid-field is worse than one that says it was cut, because the missing fields read as absent rather than as elided.

Per-mailbox events are bounded by `-MaxAlertDetail` (default `25`), the same cap that bounds the log and the console. The lists are already sorted worst-first, so the detail that survives the cap is the detail worth having, and the number held back is `WARN`ed in the log rather than dropped quietly. If the run event itself could not be written, the mailbox events are skipped entirely: several hundred mailbox events with no run event to correlate them against have no value, and every one of them would fail the same way.

> [!IMPORTANT]
> **Creating the event source needs administrator once; writing to it does not.** Measured on PowerShell 5.1.26100: `New-EventLog` and `CreateEventSource` both fail without an elevated token, while `WriteEntry` to a source that already exists succeeds whatever token the caller holds. The script self-elevates and the scheduled task runs elevated, so an ordinary deployment never meets the limit - but the first run on a new server has to be one of those two, not a `-NoElevate` run. There is a second measured trap behind that: for a non-administrator, `[System.Diagnostics.EventLog]::SourceExists()` **throws** for a source that does not exist (*"the source was not found, but some or all event logs could not be searched. Inaccessible logs: Security, State"*), and that is the same exception it throws when it simply cannot look. The script therefore treats a throw as *indeterminate* and lets the write be the test, rather than reading it as "absent" and calling `New-EventLog` - which would fail with a rights error describing a problem the caller does not have. The elevated half was measured separately, on `w25-ex01` (Server 2025 Datacenter, PowerShell 5.1.26100.33438) on 2026-09-16: `SourceExists()` returned a clean `false` for an absent source and for a not-yet-created one, without throwing. So the indeterminate reading is scoped to the non-administrator case, and the first run on a new server - which is elevated by definition, per the paragraph above - gets a straight answer rather than an exception.

#### `RunJson`

`BigFunnelPostingListMonitor-<runid>.json`, in the output directory, carrying the same summary object as `latest-summary.json` - the same 50 fields, plus the run's real `ExitCode` - kept per run instead of overwritten. It is written **after** the event log channel on purpose, so that it records whatever the event log channel just failed with; written the other way round it would report an empty `EmitErrors` on precisely the runs where that channel broke.

At a 4-hour cadence that is about 2,200 files a year, and they are swept by the existing `-RetentionDays` pass because the name sits inside the `BigFunnelPostingListMonitor-*` pattern. There is no second rotation setting to configure, and none to forget.

#### A worked Splunk configuration

Both channels, on a DAG member with the default output path:

```ini
# inputs.conf - the event log channel.
# Filtering on the source rather than on the ID range: the source writes
# nothing else, and an ID list is one more place for 1007 to be forgotten.
[WinEventLog://Application]
disabled = 0
renderXml = 0
index = exchange_bigfunnel
whitelist1 = SourceName="^BigFunnelPostingListMonitor$"

# inputs.conf - the per-run JSON channel.
# The glob is deliberately the per-run prefix and NOT *.json. latest-summary.json
# is rewritten in place on every run, and a monitored file that is overwritten
# rather than appended to is the classic way to index the same event twice and
# miss the next one. The per-run files are write-once, which is what a file
# monitor is built for.
[monitor://C:\ProgramData\ExchangeBigFunnelPostingListMonitor\BigFunnelPostingListMonitor-*.json]
disabled = 0
index = exchange_bigfunnel
sourcetype = _json
```

That glob was the thing most worth checking, because getting it wrong is silent in both directions, and it holds: on a live indexer, each of the four per-run files present on disk was indexed exactly once, and `source="*latest-summary.json"` matched **zero** events. The `_json` channel also needs no extraction configuration at all - all 50 summary fields came out by name, Splunk having parsed the JSON at index time.

The `index` both stanzas name has to exist before either input will land anything, which is a separate `indexes.conf` change and is easy to forget because nothing complains loudly:

```ini
# indexes.conf
[exchange_bigfunnel]
homePath   = $SPLUNK_DB\exchange_bigfunnel\db
coldPath   = $SPLUNK_DB\exchange_bigfunnel\colddb
thawedPath = $SPLUNK_DB\exchange_bigfunnel\thaweddb
```

The event log channel needs one more file, and this is the part that is easy to get wrong because nothing fails - the events arrive, the searches run, and they return nothing:

```ini
# props.conf - without this, the key=value body is not parsed at all. Splunk
# extracts the Windows event header and leaves the whole payload sitting
# inside the Message field. KV_MODE = auto does NOT do it; measured.
[WinEventLog:Application]
REPORT-bigfunnel_kv    = bigfunnel_kv
REPORT-bigfunnel_runid = bigfunnel_runid

# transforms.conf
[bigfunnel_kv]
# The config-file equivalent of: | extract pairdelim="\r\n" kvdelim="="
DELIMS = "\r\n", "="

[bigfunnel_runid]
# Splunk renders the event body as Message=<body>, so the payload's first line
# arrives as Message=RunId=... and the pair split above consumes RunId into
# Message. RunId is the only field this happens to, because it is always
# emitted first - and it is the one that joins a run event to its per-mailbox
# events and to its per-run JSON file, so it is worth recovering by name.
SOURCE_KEY = Message
REGEX = ^RunId=([^\r\n]+)
FORMAT = RunId::$1
```

> [!NOTE]
> **What that was measured on, and what it cost.** Splunk Enterprise 10.4.3 on Windows Server 2025, both channels fed by a real scheduled-task run of this script against a 50-mailbox lab. Before the `props.conf`, the payload contributed **nothing**: the ten fields Splunk names from the Windows event header - `LogName`, `EventCode`, `ComputerName`, `SourceName`, `Type`, `RecordNumber`, `Keywords`, `TaskCategory`, `OpCode` and `Message` - and not one field of the script's own. After it, **47 of the summary's 50 published fields** extract, with `Status`, `MailboxesEvaluated`, `BindSeconds`, `ExchangeVersion` and the rest correct, and `stats avg(BindSeconds) by ...` working as you would expect. 46 of those come from the `DELIMS` transform and `RunId` is the 47th, from the second one. A per-mailbox event carries 17 payload fields the same way.
>
> The remaining three - `EmitErrors`, `FailedDatabases`, `PublishErrors` - are empty on a clean run, and Splunk creates no field for an empty value. That is the correct behaviour rather than a gap: it is exactly what makes `EmitErrors!=""` below a search that stays silent until something is wrong.
>
> Count those yourself with `| fieldsummary` and you will get a larger number, and it is worth knowing why before you quote it. `fieldsummary` lists a field **name** whenever the sourcetype knows of one, whether or not the event in front of it has a value - a field absent from the event still appears, with `count = 0`. It also counts Splunk's own internals. `| fieldsummary | search count>0` is the form that answers "what did this event actually yield", and it is the form every number above came from.
>
> The cost to declare: `props.conf` is scoped by **sourcetype**, so `[WinEventLog:Application]` applies that extraction to every Application-channel event reaching the same sourcetype, not only this monitor's. On an indexer already collecting the Application log for other purposes, that is a search-time cost on those events too, and a `DELIMS` split will manufacture fields from any other `key=value` text it finds there. Scoping it to a dedicated sourcetype on the input avoids that, at the price of losing Splunk's built-in handling of the Windows event header - which is a trade for the Splunk team to make, not this article.

Set `-RetentionDays` with the forwarder in mind. The sweep deletes per-run files on a schedule that knows nothing about whether they were collected, so a retention window shorter than the forwarder's worst-case backlog loses runs silently. The default of `30` is not close to that for any healthy forwarder.

Searches worth having on day one, in that order:

| Search | Catches |
|---|---|
| `EventCode IN (1003,1004,1006,1007)` | The monitor is not reporting on something. More urgent than a large posting list table, because it is the state in which one goes unseen |
| No `EventCode=10*` from a server in 3× the task interval | The task stopped running altogether - the failure no event can report |
| `EventCode=1002` grouped by `Database` | Where the estate is actually getting worse |
| `EmitErrors!=""` | The feed you are reading this with is itself broken |
| `stats values(EventCode) by RunId` | The run event and its per-mailbox events, as one run. This is what the second transform above exists for |

That second one is the reason to alert on absence as well as on content: every other row here depends on an event arriving.

The first of those was run against the live indexer during the validation described above, and returned `EventCode=1007 Status="No network credential to open an Exchange runspace"` for three aborted runs - a monitor that could not reach Exchange, surfaced by the search meant to surface exactly that. The last one grouped a run event with its three per-mailbox events under one `RunId`, and joined that same run across both channels.

> [!IMPORTANT]
> **State plainly which fields leave the server.** Run events carry no mailbox identity at all - they are counts, thresholds, verdicts and paths. Per-mailbox events (`1010`, `1011`, `1012`) carry `DisplayName` and `MailboxGuid` alongside the measurements, because an alert that cannot name a mailbox is an alert somebody has to open a CSV to act on. That is ordinarily unremarkable for a customer's own estate and their own index, but it is a decision to make knowingly rather than to discover in a search result: those two fields, and no others, identify a person's mailbox. The same two fields are already in `latest.csv`. If they must not leave the box, use `RunJson` only, or leave `-EmitTo` unset and keep reading the files.

### Parameters

```powershell
[CmdletBinding()]
param(
    [string[]]$Databases,

    # All, not Local, since v1.7.7. A run started by hand is expected to answer
    # for the estate, not for whichever node the operator happened to be sitting
    # on - and the remote runspace reaches every database regardless of which
    # node holds it. Scheduled tasks on more than one DAG member want -Scope
    # Local explicitly.
    [ValidateSet('Local', 'All')]
    [string]$Scope = 'All',

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

    # Fallback only. A run that can see the allocation point in its own
    # population calibrates against that instead and ignores this.
    [ValidateRange(1, 1048576)]
    [int]$AllocationEvidenceMB = 64,

    # Empty means this server, built from its own FQDN at run time.
    [string]$ConnectionUri = '',

    [System.Management.Automation.PSCredential]$Credential,

    # Do not relaunch elevated. Correct wherever the output directory is already
    # owned by the account running the script.
    [switch]$NoElevate,

    # Silence the console report. The log, both stable files and the exit code
    # are unaffected: this suppresses decoration, never evidence.
    [switch]$Quiet,

    # Emit the collected rows on the success stream as well as writing them to
    # the CSV, so the run can be queried rather than only read.
    [switch]$PassThru,

    # Internal. The parent passes this to the elevated child so the child can
    # mirror every console line into a file the parent replays. Not a parameter
    # an operator sets: empty on a run nobody relaunched.
    [string]$ConsoleRelayPath = '',

    [switch]$ExitNonZeroOnAlert,

    # Additional channels for a log aggregator: EventLog, RunJson, or both.
    # Empty by default, so a run that does not ask for them behaves exactly as it
    # did before they existed. Deliberately NOT a [ValidateSet] - see below.
    [string[]]$EmitTo = @(),

    [ValidateNotNullOrEmpty()]
    [string]$EventLogSource = 'BigFunnelPostingListMonitor',

    # Register the scheduled task, verify it, and exit without collecting.
    [switch]$RegisterScheduledTask,

    # Remove it again, and confirm it is gone rather than assuming success.
    [switch]$UnregisterScheduledTask,

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'Exchange BigFunnel PostingListTable Monitor',

    [ValidateRange(1, 168)]
    [int]$TaskIntervalHours = 4,

    # 24-hour clock. Stagger it across DAG members.
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$TaskStartTime = '00:05',

    # The account the task runs as. Deliberately NOT -Credential, which means
    # the Exchange runspace. Prompted for when omitted.
    [System.Management.Automation.PSCredential]$TaskCredential
)
```

> [!NOTE]
> **`-EmitTo` has no `[ValidateSet]` and that is not an oversight.** A set attribute fires at parameter-binding time, before any code in the script can run. `powershell.exe -File` cannot carry a multi-element array, so the value arriving from the scheduled task the script registers is the single string `EventLog,RunJson` and has to be re-split - which a set attribute would reject first. Measured, and the error message is worth seeing once: *the argument "EventLog,RunJson" does not belong to the set "EventLog,RunJson"*. The values are checked below the param block instead, and a bad one exits `3`. The cost is tab completion; the alternative was a registered task that failed every run. `-Databases` is re-split for the same reason - see [Register the task with `-File`](#other-points-that-matter-in-production).

The defaults are the values this runbook recommends, so a run with no arguments at all is the intended configuration on a DAG member. Ten parameters exist mainly because a monitoring integration needs them:

| Parameter | Effect |
|---|---|
| `-Scope` | `All`, the default, collects every database in the organization from any invocation including a scheduled task, because the script binds through an Exchange runspace rather than the in-process snap-in. `Local` collects only the databases whose active copy is mounted on this node, and that is what makes one scheduled task correct on every DAG member and correct again after a switchover - **pass it explicitly when registering a task per node**, or each node sweeps the whole organization and writes a full set of files describing the same estate. See [`-Scope All`, and what a Partial means now](#-scope-all-and-what-a-partial-means-now) |
| `-ThresholdMode` | `Fixed` applies `-WarningGB` and `-CriticalGB` as given. `Adaptive` raises them to the collected population's 95th and 99th percentile where those sit higher, never lowers them, and falls back to the fixed values when fewer than `-AdaptiveMinimumSample` mailboxes were collected or when the two percentiles fail to separate |
| `-MaxRunMinutes` | A collection budget. Reaching it ends the run early and reports exit code `2`, so a collection cut short is never reported as a clean one |
| `-ExitNonZeroOnAlert` | Turns findings into the non-zero exit codes `1`, `5` and `6`. Without it the script exits `0` for anything short of a breakage and reports its findings through the console report and `latest-summary.json` only - the report says so on the line below the exit code rather than leaving the contradiction on screen |
| `-PassThru` | Emits the collected rows on the success stream as well as writing them to the CSV, so a run can be assigned and queried: `$r = .\Monitor-BigFunnelPostingList.ps1 -Scope All -PassThru`, then `$r \| Where-Object Status -eq 'Critical'`. These are the same `[pscustomobject]` rows the report and the CSV are both built from - typed `BigFunnel.PostingListRow`, not a re-read of the file - so the growth fields come back as numbers rather than as text that sorts lexically. Off by default, because a bare run would follow the report with a hundred objects through the default formatter. Returns nothing across an elevation relaunch, since the rows are built in the elevated child; the run warns when both apply. See [Querying a run instead of reading it](#querying-a-run-instead-of-reading-it) |
| `-AllocationEvidenceMB` | The mailbox size, in MB, above which a `0 B` posting list table counts as evidence that the counter is not being populated. **A fallback only**: where any mailbox in scope has a populated table, the script measures the bar off the estate instead and ignores this value. Default `64`, roughly four times the upper bound of the measured allocation range, so a `Blind` verdict reached under it is close to unarguable. Lower it only if you have measured a lower allocation point on your own build; raising it makes the script slower to call a real outage |
| `-ConnectionUri` | The Exchange runspace to bind through. Empty by default, which means this server's own PowerShell vdir, built from its FQDN at run time. Any Exchange server in the organization is a valid target - it does not have to be the node holding the databases being collected |
| `-Credential` | Only needed where the account running the script cannot authenticate to that runspace on its own. Whether it can is decided by the task's `LogonType`, not by the account: measured on a lab DAG, a task registered with a stored password opened the runspace with Kerberos and no credential, and the same task registered `S4U` could not open it at all. Use this where a stored password is not permitted, and supply it from your own secret store. See [The logon type is load-bearing](#the-logon-type-is-load-bearing) |
| `-EmitTo` | Additional channels for a log aggregator: `EventLog`, `RunJson`, or both. Empty by default, so this is fully backward compatible. Neither channel replaces `latest.csv` and `latest-summary.json`, and a failure in either one never changes the exit code - it lands in `EmitErrors` instead. See [Feeding a log aggregator](#feeding-a-log-aggregator) |
| `-EventLogSource` | The event source `-EmitTo EventLog` writes under. Defaults to `BigFunnelPostingListMonitor`. Configurable because event source names are one of the things large estates standardise on |

Six more exist only to register the scheduled task, and are described in [Scheduling](#scheduling):

| Parameter | Effect |
|---|---|
| `-RegisterScheduledTask` | Register the task from whatever else is on the same command line, verify it, and exit. Does not collect, so it works on a node where Exchange is not reachable yet |
| `-UnregisterScheduledTask` | Remove the task and confirm it is gone. Exits `0` when there was nothing to remove |
| `-TaskName` | Defaults to `Exchange BigFunnel PostingListTable Monitor`. Configurable for estates with task naming standards |
| `-TaskIntervalHours` | Repetition interval, `1` to `168`. Default `4` |
| `-TaskStartTime` | First run, on a 24-hour clock. Default `00:05`. **Stagger this across DAG members** |
| `-TaskCredential` | The account the task runs as. **Not** `-Credential`, which is the Exchange runspace - the two are not interchangeable. Prompted for when omitted, so it reaches neither source control nor shell history |

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
        $IndexedCount = $null,
        # Untyped for the same reason: TotalItemSize is absent or Unlimited on
        # some mailboxes, and the evidence point is absent when the caller has
        # not computed one.
        $MailboxBytes = $null,
        $EvidenceBytes = $null
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
    #
    # But only above the size at which this build allocates the table. Below it,
    # 0 B is the correct reading and flagging it is the mirror-image error: a
    # small estate reports a total metric outage on every run, and an alert that
    # always fires is an alert that gets muted.
    $indexed = ConvertTo-NullableInt64 $IndexedCount
    if ($Bytes -eq 0 -and $null -ne $indexed -and $indexed -gt 0) {
        $size     = ConvertTo-NullableInt64 $MailboxBytes
        $evidence = ConvertTo-NullableInt64 $EvidenceBytes

        # Unparseable or Unlimited TotalItemSize lands here as $null. The mailbox
        # cannot be judged either way, so it is reported as the benign state
        # rather than the alarming one: a wrong "nothing is wrong" on one row is
        # recoverable, a wrong "your monitoring is blind" trains people to
        # ignore the message.
        if ($null -eq $evidence -or $null -eq $size -or $size -lt $evidence) {
            return 'NotAllocated'
        }
        return 'NotPopulated'
    }

    return 'Normal'
}
```

`Critical` and `Warning` are findings about a size. `NotPopulated` is not: it says the mailbox reported a live index, a posting list table of exactly zero bytes, and enough content that the table should have existed. That is a statement about the counter rather than about the mailbox. On a build that never populates the table every eligible mailbox lands there, and that run-wide case is escalated separately as `MetricUnavailable`. See [When every indexed mailbox reads 0 B](#when-every-indexed-mailbox-reads-0-b).

`NotAllocated` is the same zero reading below that size, where it is expected rather than wrong. It is reported instead of `Normal` because the size still cannot be read - but it is not evidence of a fault, it does not escalate, and it does not move the exit code. Mailboxes whose `TotalItemSize` cannot be parsed, or that report `Unlimited`, land here too: they cannot be judged either way, and the classifier fails toward the benign verdict on purpose.

### Verifying a copy before you rely on it

`Tests\run-tests.ps1` in this folder exercises the monitor against a mock Exchange module. It needs no Exchange installation, touches no mailbox, and runs on a workstation. Each case launches the monitor in its own `powershell.exe` with `-File`, the way a scheduled task invokes it, so the exit codes it asserts on are real process exit codes rather than inferred ones.

```powershell
# From this folder. No Exchange, no elevation, no network.
.\Tests\run-tests.ps1
```

It ends with a `RESULT: <n> passed, <n> failed` line and exits non-zero if anything failed. Run it after any local edit to the monitor, and run it before trusting a copy that reached you by some route other than this repository.

### Verifying this article against the script

`run-tests.ps1` proves the monitor works. It does not prove this article still describes it, and those are different failures. The second is the quieter one: a parameter default, an exit code or an event ID can change in the script without anything here looking wrong, because drift of that kind reads perfectly well as prose and is only ever found by comparison. `Tests\runbook-checks.py` does that comparison mechanically.

```powershell
# From this folder. Python 3, no Exchange, no elevation, no network.
python Tests\runbook-checks.py
```

It checks, in both directions: the parameter block reproduced above against the script's own, as `(name, type, default)` triples and in declaration order; every status in the precedence chain against the Status table and against the ordering of the worst-first sentence; every exit code the script can return against the Code table; every in-page link against every heading slug; every event ID and entry type against the two maps in the script; and every parameter excluded from the scheduled task's argument string against the sentence that names them, including the spelled-out count in it, which has already been wrong once. It prints a PASS or FAIL line per assertion, ends with `CHECKS: <n> failed`, and exits non-zero if anything failed. **Run it after editing this article, and after any change to the monitor's parameters, exit codes or event IDs.**

`Tests\runbook-checks-selftest.py` is the test for that checker, and it is worth knowing it exists before reading a `0 failed` line as an assurance. It builds a throwaway copy of this article and the script in a temp directory, breaks exactly one thing, and asserts on what the checker prints: a renamed table header, a count drifted by one, a link pointing into a code fence, a parameter whose type changed, an exit code carrying a trailing comment. Every case the checker is meant to tolerate is paired with its inverse, so "this link now resolves" can be told apart from "the link check stopped checking". It ends with `PROOFS: <n> failed`, writes only to a temp directory, and changes nothing in this folder.

### Rehearsing the alerting on a non-production estate

`run-tests.ps1` proves the monitor behaves against a mock. It does not prove your alerting does. The route from an exit code to a ticket runs through a scheduled task, an account, a network path and whatever consumes the summary file, and the only state most estates ever produce naturally is the clean one. `Invoke-BigFunnelScenario.ps1` closes that gap by driving the monitor into each of its states against real mailboxes on a dev or lab estate.

It is read-only against Exchange: no mailbox, database or index is modified. It runs the monitor once as a probe with the thresholds parked far above anything the estate holds, reads the sizes actually present, then solves for the parameters that put those same real mailboxes into the state you asked for. Every scenario declares the exit code and summary fields it expects, and the run fails loudly if it produced the state next door.

```powershell
# Which states can this estate show, and why not the rest?
.\Invoke-BigFunnelScenario.ps1

# Produce one: solve thresholds, run monitor, check result.
.\Invoke-BigFunnelScenario.ps1 -Scenario Critical
```

The eight states are `Healthy`, `Warning`, `Critical`, `Emerging`, `Shrinking`, `Inconclusive`, `Blind` and `Partial`, covering exit codes 0, 1, 2, 5 and 6. `Inconclusive` and `Blind` are the pair worth running back to back: the same mailboxes and the same zero-byte readings produce opposite verdicts and opposite exit codes, and the only thing that changes between them is where the allocation evidence bar sits. That is the distinction in [When every indexed mailbox reads 0 B](#when-every-indexed-mailbox-reads-0-b), run as an experiment you can repeat.

Two cautions. **The thresholds it computes are demonstration values, not production values** - they are scaled to whatever your dev estate holds, so a lab with a 30 MB posting list table produces thresholds three orders of magnitude below the shipped defaults. Use it to exercise the alerting path, never to choose thresholds. And `Emerging` and `Shrinking` are statements about change over time, so they need an earlier reading to difference against; the script writes a clearly marked synthetic baseline CSV into its own run directory, with a `SYNTHETIC-BASELINE.txt` beside it. **Never copy one into a real monitor output directory** - the monitor cannot tell it from a genuine earlier run, which is exactly why it works here.

#### Standing up a demonstration that already has findings

`Invoke-BigFunnelScenario.ps1` drives the estate into one state at a time and reports on it. A demonstration usually wants the opposite - a directory that shows Critical, Warning and Emerging together, from an ordinary monitor run with no special arguments, every time it is run in front of an audience. `Set-BigFunnelDemoState.ps1` prepares that once, and then prints the single command to demonstrate with.

```powershell
# Prepares the state and prints the command to run in front of an audience.
# -OutputPath defaults to ...-demo, NOT the production directory. See below.
.\Set-BigFunnelDemoState.ps1
```

**Two of those three findings are real and the third is a fixture, and that distinction is why this is documented rather than left as a convenience.** Critical and Warning are the live sizes of two real mailboxes, measured during the preparation run, compared against a threshold pair scaled to a lab estate instead of the production 1.7 / 2.0 GB: genuine rows, scaled thresholds, nothing invented. Emerging cannot be produced that way at all. It is `Normal` plus a projection inside three days, so it needs two observations that differ, and an estate whose posting list tables have not moved has only one. The script writes the earlier observation itself - it collects the real population, back-dates that CSV, and lowers exactly one cell in it, the Emerging mailbox's `PostingListBytes`, by the amount that makes today's real size project across critical inside the window. One cell, in one file. What was fabricated is written to `DEMO-FIXTURE.txt` beside the data as well as printed, because a demo directory looks exactly like a production one and that is how a fixture ends up being quoted as a measurement.

**Never point `-OutputPath` at a directory you care about.** It defaults to `C:\ProgramData\ExchangeBigFunnelPostingListMonitor-demo` - deliberately not the production path - and the script empties it twice: once before collecting, and again afterwards so the back-dated baseline is the only history left. That is not tidiness. `Get-PreviousRunBaseline` takes the newest run at least `-TrendBaselineHours` old, so one leftover real run wins over the fixture and the Emerging row quietly goes flat, which reads like the script did nothing rather than like a stale directory. The same mechanism is why the state expires: **re-run the script before each demonstration**, because once a demo run itself ages past 24 hours it becomes a baseline candidate and Emerging goes flat again.

Two details worth knowing before changing a parameter. Back-dating is a rename, not a timestamp change - the monitor reads the trend window from the run-id stamp in the file name, which a copy cannot clobber the way it clobbers a file time - so `-BaselineAgeHours` must stay above the monitor's `-TrendBaselineHours` or the join rejects the baseline as too recent to divide by. And the script refuses rather than improvising: ten named failures, among them a nominated mailbox that was not collected, one that does not sit between the thresholds it was nominated for, and an Emerging target so far below critical that the implied earlier reading would have to be negative. Each names the parameter to change. No mailbox, database or index is modified at any point, and nothing needs undoing beyond deleting the directory.

### Scheduling

The script registers its own task. It is already running as administrator at that point - it self-elevates - which makes it the right place to do this, and it builds the task out of the run you typed rather than out of a second set of parameters that can disagree with it.

```powershell
# From an elevated shell, on each DAG member. Write the run you want, then add
# the switch. -Scope Local and no -Databases: the script then discovers the
# databases whose active copy is mounted on this node, which is what makes one
# registration correct on every member and correct again after a switchover.
.\Monitor-BigFunnelPostingList.ps1 `
    -Scope Local -WarningGB 1.7 -CriticalGB 2.0 -RetentionDays 30 `
    -EmitTo EventLog,RunJson `
    -RegisterScheduledTask -TaskIntervalHours 4 -TaskStartTime 00:05
```

That prompts once for the account the task will run as, registers it, reads it back from the scheduler, and reports:

```text
  Registered and verified: Exchange BigFunnel PostingListTable Monitor
    LogonType Password, RunLevel Highest, -File action.

  Exit code 0
```

Everything on that command line becomes the task's own argument string, so the task runs the invocation you just described, minus the eight parameters that cannot mean anything inside it: `-RegisterScheduledTask`, `-UnregisterScheduledTask`, `-TaskName`, `-TaskIntervalHours`, `-TaskStartTime` and `-TaskCredential`, which describe how to build the task rather than how to run it; `-Credential`, because a `PSCredential` does not survive being written to a command line; and the internal `-ConsoleRelayPath`, which names a parent process that will not exist. The argument string is built from the same `PSBoundParameters` machinery the elevation relaunch uses, so a parameter added to the script later cannot be silently dropped from either one.

Removing it again is the same shape, and confirms the removal rather than assuming it:

```powershell
.\Monitor-BigFunnelPostingList.ps1 -UnregisterScheduledTask
```

A registration run does not collect. It opens no Exchange runspace and runs no pre-flight, which makes it fast and means it works on a node where Exchange is not reachable yet.

**Stagger `-TaskStartTime` across DAG members.** Every node registering the same task at the same minute puts the whole estate's collection into one window, which on `-Scope Local` is the one thing a per-node registration exists to avoid.

#### What the script refuses to do

Three registrations are refused rather than completed, each because the resulting task fails in a way nothing announces. All three exit `7` and register nothing.

| Refusal | Why |
|---|---|
| No `-TaskCredential`, and no way to prompt | A task registered without a password gets `LogonType Interactive` and never runs. Refusing is the only honest answer; see below |
| The run is not elevated | Creating a task needs an elevated token. `-NoElevate`, `-Credential` and `-TaskCredential` each suppress the automatic relaunch, so a registration run that passes one of the last two must already be elevated |
| The generated command line is not `-File` based | Should be impossible, since the script builds it. Asserted anyway, because it is cheaper than the failure it prevents |

One case is a loud warning rather than a refusal: **`-Scope` not passed explicitly**. The default is `All`, so leaving it off registers a task on every DAG member that sweeps the whole organization, writing several full sets of files describing the same estate. A deliberate `-Scope All` task on exactly one node is a legitimate thing to want, so this does not block - but pass `-Scope All` explicitly to say you meant it.

**Where policy blocks registration**, the script says so rather than passing the exception through. A local administrator refused by a management policy gets `Access is denied` and no indication that the denial is an estate setting rather than a bug, so the script names it as a policy refusal, points at the manual registration below, and still records the underlying error. That is the common case in a locked-down estate, and the equivalent command exists precisely so it can be handed to whoever does hold the right.

#### Registering it by hand

Use this where policy reserves task creation to a management layer, or where the task is built by configuration management rather than on the box. It is the same registration the script performs, written out.

```powershell
# -Scope Local, and no -Databases, for the reason given above. Name databases
# explicitly only when you deliberately want a fixed subset, and expect that
# task to start collecting nothing the first time the copy moves.
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-File "C:\Scripts\Monitor-BigFunnelPostingList.ps1" ' +
    '-OutputPath "C:\ProgramData\ExchangeBigFunnelPostingListMonitor" ' +
    '-Scope Local -WarningGB 1.7 -CriticalGB 2.0 -RetentionDays 30 ' +
    '-EmitTo "EventLog,RunJson"')

$trigger = New-ScheduledTaskTrigger -Once -At 00:05 `
    -RepetitionInterval (New-TimeSpan -Hours 4)

# ExecutionTimeLimit is the backstop for a store call that never returns. The
# script's own mutex prevents a slow run from being overlapped by the next
# scheduled one, but it cannot interrupt a call already in progress, so the task
# needs a hard ceiling of its own. MultipleInstances IgnoreNew is the same
# protection at the scheduler level. Set it ABOVE -MaxRunMinutes rather than
# equal to it: -MaxRunMinutes is when the script gives up and writes its summary,
# and a scheduler limit landing on the same minute can kill the process in the
# middle of doing that, turning an orderly Partial into a run that published
# nothing. The script's own registration uses -MaxRunMinutes plus 15.
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable

# -Password is not optional, and -User on its own is not equivalent. See
# "The logon type is load-bearing" below before changing this line. Prompted
# for rather than written into the script, so it reaches neither source
# control nor shell history.
$cred = Get-Credential -Message 'Service account for the monitor task'

Register-ScheduledTask -TaskName "Exchange BigFunnel PostingListTable Monitor" `
    -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
    -RunLevel Highest -Force
```

Note `-EmitTo "EventLog,RunJson"` as **one quoted token**. That is the honest spelling of what crosses `powershell.exe -File`, which cannot carry a multi-element array at all; the script re-splits it on arrival. The same applies to `-Databases`. See [Register the task with `-File`](#other-points-that-matter-in-production).

#### The logon type is load-bearing

**`-User` with no `-Password` registers a task that never runs.** It is not a syntax error and nothing warns you: PowerShell defaults that principal to `LogonType Interactive`, which means "run only when this user is logged on", and a service account never is. The task registers, sits at `Ready`, and reports `LastTaskResult 267011` (`0x41303`, `SCHED_S_TASK_HAS_NOT_RUN`) indefinitely. No log file is written, and the output directory is never created, so the usual places you would look for a fault are all empty.

The other way to get this wrong is the Task Scheduler UI's **Do not store password**, or `-LogonType S4U`. That task does run, and then cannot open the Exchange runspace: an S4U logon has no outbound network credential, and the runspace is a network logon even when the target is the same server. Every run fails identically at the binding step with `0x8009030e`, `A specified logon session does not exist`.

Measured on a lab DAG member, same account and same argument string, three registrations minutes apart:

| Registration | Resulting `LogonType` | What happens |
|---|---|---|
| `-User` alone | `Interactive` | Never runs. `LastTaskResult 0x41303`, no log, no output directory |
| `-LogonType S4U` | `S4U` | Runs, cannot bind Exchange. Exit `3` every run |
| `-User` + `-Password` | `Password` | Runs. Runspace opens with Kerberos, exit `0` |

Only the third is a working monitor. This is a consequence of binding through a runspace rather than the snap-in, so it is specific to `1.7.0` and later; the same registration under an older build ran, and quietly collected only the local node. **A gMSA cannot be used for this task**, for the same reason S4U cannot.

##### `0x8009030e` has a second cause, and the remedies do not overlap

The table above is about scheduled tasks, and for years that was the only place this error turned up. It is not. **Running the monitor inside a WinRM remote session produces the identical error for an unrelated reason**, and every instruction in this section is useless against it.

A `New-PSSession`/`Invoke-Command` connection authenticates you to the target. Opening the Exchange runspace from inside it is a *second* hop - a fresh network logon - and the credential that got you there cannot be delegated onward. **This is true even when the runspace target is the same server you are already connected to**, which is the part that makes it look like something else. Measured on `w25-ex01`, 2026-09-17: the monitor exited `3` at the binding step with `A specified logon session does not exist`, from a session where the account had every right it needed.

Tell the two apart before changing anything:

| | Scheduled task / service | WinRM session |
|---|---|---|
| Session ID | `0` | `0` - **identical, so this is not the discriminator** |
| `Test-Path variable:PSSenderInfo` | `False` | `True` |
| Host | `ConsoleHost` | `ServerRemoteHost` |
| Remedy | Re-register with `-User` **and** `-Password` | Re-registering changes nothing |

The monitor now makes this distinction itself and says which one it is, rather than assuming session 0 means a task. If you see the WinRM wording, there are three ways out: run the monitor directly on the server, pass `-Credential` so it authenticates the runspace itself rather than relying on delegation, or enable CredSSP on both ends so the first hop can delegate. The first is almost always the right answer for a monitor.

`-RegisterScheduledTask` enforces all of this rather than asking you to remember it: it refuses to register without a password, it registers `-RunLevel Highest`, and it reads the task back and fails the registration if the resulting `LogonType` is anything but `Password` - naming which of the two failures you are looking at, because `Interactive` and `S4U` break in completely different ways. Registering by hand, you are the one checking; see below.

Where a stored password is not permitted, pass `-Credential` to the script instead and supply it from whatever secret store your estate uses. That moves the credential out of the task definition without giving up the runspace.

#### Verify the registration before trusting it

`-RegisterScheduledTask` performs the first of these three checks itself and refuses the registration if it fails. The other two need the task to have actually run, so they are yours either way - and all three are yours if the task was registered by hand.

```powershell
$name = 'Exchange BigFunnel PostingListTable Monitor'

# 1. Password, or the task will not run unattended.
#    -RegisterScheduledTask already checked this one, along with RunLevel
#    Highest and the -File action, and refused to leave a task that failed it.
(Get-ScheduledTask -TaskName $name).Principal.LogonType

# 2. Run it once on demand and read the code the scheduler recorded.
Start-ScheduledTask -TaskName $name
while ((Get-ScheduledTask -TaskName $name).State -eq 'Running') { Start-Sleep 5 }
(Get-ScheduledTaskInfo -TaskName $name).LastTaskResult

# 3. The exit code and the summary have to agree. If the file says 3 and the
#    scheduler says 1, the action is using -Command somewhere.
Get-Content 'C:\ProgramData\ExchangeBigFunnelPostingListMonitor\latest-summary.json' |
    ConvertFrom-Json | Select-Object ScriptVersion, Completed, Status, ExitCode,
        DatabasesInScope, MailboxesEvaluated, MetricValidation
```

| What you see | What it means |
|---|---|
| `LogonType` is not `Password` | Re-register. See above |
| `LastTaskResult 267011` and `LastRunTime` in 1999 | The task never ran. `LogonType Interactive` |
| `LastTaskResult 3`, summary `Status` names a credential | S4U, or the account has no Exchange RBAC |
| Exit `3`, `A specified logon session does not exist`, **and you are in a PSSession** | Not a task fault at all. See [`0x8009030e` has a second cause](#0x8009030e-has-a-second-cause-and-the-remedies-do-not-overlap) |
| `LastTaskResult 3`, `DatabasesInScope 0` | Expected on a passive-only member |
| `LastTaskResult` and summary `ExitCode` disagree | The action is using `-Command`. Re-register with `-File` |
| `LastTaskResult 0`, summary `Status OK` | Working, and it found nothing |
| `LastTaskResult 0`, summary `Status Alert` | Working. The task is fine; the estate is not. Read the counts |

Do this on every member you register, not just the first. A passive-only member is the one node where a genuine fault and the expected exit `3` look alike, and the summary's `DatabasesInScope` is what tells them apart.

#### Other points that matter in production

- **Store the script outside its own output directory.** The script prunes files matching `BigFunnelPostingListMonitor-*` under `-OutputPath` on a retention schedule. Keeping the script somewhere else, such as `C:\Scripts`, removes any possibility of the housekeeping and the tooling sharing a folder.
- **Use a literal path, not an environment variable.** `%ProgramData%` expands differently depending on which shell creates the task and whether the service account's profile is loaded. A hardcoded path fails visibly at registration rather than silently at 02:05.
- **The account needs Exchange RBAC, not just local administrator.** It must be able to run `Get-ExchangeServer`, `Get-MailboxDatabase`, and `Get-MailboxStatistics`. View-Only Organization Management is sufficient and is the least-privileged role that covers all three.
- **It elevates itself.** If the script is not already running as administrator it relaunches itself with the same parameters under `-Verb RunAs`, waits for that run, and exits with its exit code. Start it from an elevated shell and no prompt appears — which includes every task registered with `-RunLevel Highest`. Two departures from the usual four-line version of this pattern are deliberate: it **waits** and propagates the child's exit code, because returning `0` the moment the child starts would report every run as clean; and it rebuilds the child's command line from `PSBoundParameters` rather than a hand-kept list, so a relaunch cannot quietly drop `-CriticalGB` and judge against the wrong threshold. Three cases do not prompt. A non-interactive session has no desktop to show consent on, so it warns that the task wants `-RunLevel Highest` rather than hanging on a prompt nobody can answer. A run with `-Credential` cannot relaunch, because a `PSCredential` does not cross a process boundary and dropping it would change how the runspace authenticates. And `-NoElevate` suppresses it outright — pass that when the output directory is somewhere the current account already owns, such as a scratch path under `%TEMP%`, and a prompt would be pure friction. In all three the run continues and, if it genuinely cannot publish, fails with exit `3` rather than silently. Refusing the prompt is also exit `3`, because a monitor that was not allowed to run has not run.
- **Interpret the exit code.** See [Exit codes and the run summary](#exit-codes-and-the-run-summary) below. A run that is missing entirely leaves a log file with no `Monitor run complete` line; that is how a killed run is identified, since it has no exit code to report.
- **Register the task with `-File`, never `-Command`.** `powershell.exe -Command` collapses every non-zero exit code to `1`. Exit codes `2`, `3`, `4`, `5` and `6` then all reach the scheduler looking like "at-risk mailboxes found", and a metric outage, an uncollected database or a projection days out cannot be told apart from a threshold breach. This is measured rather than assumed, and measured at the scheduler rather than in a shell: the same failing run, registered twice minutes apart with only the launcher changed, wrote `"ExitCode": 3` to `latest-summary.json` both times, and the scheduler recorded `LastTaskResult 3` under `-File` and `1` under `-Command`. That disagreement between the file and the scheduler is the signature, and step 3 of the verification above is how to catch it. `-RegisterScheduledTask` builds a `-File` action and then reads the registration back and asserts it, which also catches a management layer rewriting the action after the fact. Keep it that way in any wrapper script or monitoring agent that invokes the monitor on your behalf, and check the wrapper specifically, because a wrapper is where `-Command` usually creeps back in.
- **`-File` cannot carry a multi-element array, and every way it fails is silent.** This is the other half of the same launcher problem and it is worth knowing before you hand-write a task or a wrapper. Measured against a stub script that printed what it bound:

  | Written as | What the script received | Exit |
  |---|---|---:|
  | `-Databases "DB01","DB02"` | **one** element, the string `DB01,DB02` | `0` |
  | `-Databases DB01,DB02` | **one** element, the string `DB01,DB02` | `0` |
  | `-Databases "DB01" "DB02"` | `DB01` to `-Databases`, and **`DB02` bound positionally to whatever parameter came next** | `0` |
  | `-Databases "DB01" -Databases "DB02"` | hard error, and the error text recommends the comma form above | `1` |

  Three of the four exit `0`, and the third is the dangerous one: a value lands on a different parameter than the one it was written beside. There is no command-line form that survives, so the fix is at the receiving end - the script re-splits `-Databases` and `-EmitTo` on arrival, and `ConvertTo-RelaunchArguments` emits one quoted token (`-Databases "DB one,DB two"`), which is the honest spelling of what actually crosses. Typing a genuine array interactively is unaffected. The limit that remains is that **a value containing a comma cannot round-trip**; Exchange database names do not contain commas and neither do the `-EmitTo` keywords. This affected the elevation relaunch too, and had done since v1.7.x: a `-Databases DB01,DB02` run from a non-elevated session collapsed to one database name that did not exist, matched nothing, and fell through to discovering every database instead - a silently wrong scope on a run that looked entirely normal.

#### Exit codes and the run summary

The monitor reports through two independent channels: the process exit code, for a scheduler, and `latest-summary.json`, for a monitoring platform that reads files. They agree on every run, which makes each a check on the other.

| Code | Meaning | Alert |
|---:|---|---|
| `0` | Completed. All in-scope databases collected, nothing over threshold | No |
| `1` | Completed, at-risk mailboxes found. `-ExitNonZeroOnAlert` only | Yes, as a mailbox finding |
| `2` | Completed with partial failure. At least one database was not collected, or collection was cut short by `-MaxRunMinutes` | Yes, as a monitor fault |
| `3` | Fatal. Pre-flight failed, no database was in scope, or one of the two stable files could not be refreshed | Yes, as a monitor fault, but see the DAG note below |
| `4` | Another instance is already running | Yes, as a monitor fault |
| `5` | Completed, but every mailbox large enough to have allocated a posting list table reported it as `0 B`. `-ExitNonZeroOnAlert` only | Yes, as a monitoring gap |
| `6` | Completed, nothing over threshold, but at least one mailbox is projected to cross the critical threshold within 3 days. `-ExitNonZeroOnAlert` only | Yes, as a mailbox finding, but not as urgent as `1` |
| `7` | A scheduled task operation failed. **Only ever returned by a run that passed `-RegisterScheduledTask` or `-UnregisterScheduledTask`** | Not from a collecting run - it cannot occur on one |

Exit code `7` is safe to add to an existing integration precisely because of that restriction: a collecting run has no path to it, so no consumer watching a scheduled monitor can ever observe it. It means the registration was refused, the registration could not be verified, or the removal could not be confirmed - never that anything is wrong with the estate. The run that returns it collected nothing and wrote no CSV.

Codes `2`, `3`, `4` and `5` all mean the monitor is not reporting on something, which is more urgent than a large posting list table because it is the state in which a large posting list table goes unseen. Route them differently from `1`.

Exit code `6` is the opposite case: the monitor is working and has found something that has not happened yet. `1` is work today; `6` is work before the weekend. They are separated rather than collapsed because a queue that treats them alike either drags the projections forward into the breach queue or lets the breaches sink into the projection one. If your scheduler cannot route two codes, treat `6` as non-zero and read `latest-summary.json` for which of the two it was.

Exit codes `1`, `5` and `6` require `-ExitNonZeroOnAlert`. Without it the script returns `0` for anything short of a breakage and reports its findings through `latest-summary.json` only, so that "found problems" is never confused with "the monitor broke". Add the switch when a scheduler is the thing consuming the result.

A run cannot return both `1` and `6`. Where a breach and a projection coexist, `1` wins, because the mailbox already over the line is the more urgent of the two and its meaning must not change. Read `Emerging` in the summary to see whether an exit-`1` run also carried projections.

`latest-summary.json` is written on every run that gets far enough to have an output directory, including runs that abort, and always carries the same field set. Its `Status` field on a run that completed is one of:

| `Status` | Meaning |
|---|---|
| `OK` | The run collected its scope, the counter was readable, and nothing is at or approaching a threshold |
| `PublishFailed` | `latest.csv` could not be refreshed, so the stable files no longer describe the newest run. Pairs with exit code `3`. `PublishErrors` names the reason |
| `Partial` | At least one database was not collected. Pairs with exit code `2` |
| `Alert` | At least one mailbox is at or above the warning or critical threshold now. Pairs with exit code `1`, but is reported whether or not `-ExitNonZeroOnAlert` was passed |
| `MetricUnavailable` | Every eligible mailbox in scope reported the posting list table as `0 B`. Pairs with exit code `5`, but is reported whether or not `-ExitNonZeroOnAlert` was passed |
| `Emerging` | Nothing has crossed yet, but at least one mailbox is projected to cross critical inside the lead-time window. Pairs with exit code `6`, and is likewise ungated |
| `MetricInconclusive` | Nothing in scope has a populated posting list table and nothing is large enough to have allocated one, so the run cannot say whether the counter works. **Not a fault.** Does not change the exit code |

Reported worst-first where more than one applies: `PublishFailed`, then `Partial`, then `Alert`, then `MetricUnavailable`, then `Emerging`, then `MetricInconclusive`, then `OK`. That is the exit-code order, so `Status` and `ExitCode` never name different findings about the same run.

`PublishFailed` outranks everything because a consumer that cannot read this run's verdict learns nothing from the rest of the field. It carries one asymmetry worth knowing before you build an integration on it: it can only ever be *read* when `latest.csv` was the file that failed. If `latest-summary.json` itself could not be written, the value never reaches disk - the file cannot report its own absence - and the condition surfaces only as exit code `3`. That is precisely why the exit code carries it too, and why an integration that polls the summary file alone needs a staleness check of its own: a summary whose `RunId` has not moved since the last poll is the signature, and the scheduler's `3` is the corroboration. Measured on `w25-ex01`: a non-elevated session could create its timestamped CSV and log but not overwrite a `latest.csv` and `latest-summary.json` owned by `BUILTIN\Administrators`. Before this existed the run warned twice and exited `0`, leaving a summary 19 hours stale beside a CSV it had just written. Self-elevation is the other half of that fix; see [Reading a run on screen](#reading-a-run-on-screen).

> [!IMPORTANT]
> **Before v1.7.2, `Status` had no value for a finding at all.** It described only whether the run mechanism worked, so a run could publish `Critical 1`, `Warning 1`, `ExitCode 1` and `Status OK` side by side - and the integration recommended here, alert when `Status` is not `OK`, went silent on the one condition the script exists to detect. If you are reading a summary written by v1.7.1 or earlier, `OK` there means "the run worked", not "nothing was found"; read the counts.

Three further fields describe the run's confidence in its own instrument, independent of any threshold:

| Field | Values | Meaning |
|---|---|---|
| `MetricValidation` | `Confirmed` / `Blind` / `Inconclusive` | Whether the counter demonstrably works in this scope, demonstrably does not, or could not be tested |
| `AllocationEvidenceMB` | number | The mailbox size above which a `0 B` table counts as evidence of an outage, in force for this run |
| `AllocationEvidenceBasis` | `Observed` / `Configured` | Whether that bar was measured off this estate or taken from `-AllocationEvidenceMB` |

Alert on `Status` not in `OK, MetricInconclusive`, and read the counts beside it for what was found. `Completed = false` catches the abort reasons and nothing else, so it is a useful second condition but not a substitute: `PublishFailed`, `Alert`, `MetricUnavailable` and `Emerging` are all completed runs. `MetricInconclusive` is excluded deliberately - on a permanently small estate it fires on every run, and an alert that always fires gets muted; read it when triaging a clean result instead. If your alerting cannot express a set, `Status -ne 'OK'` is the safe simplification in the noisy direction. `latest.csv` is refreshed only when a run produced detail, so it can legitimately be older than the summary sitting beside it - that deliberate skip is not a publish failure and does not affect the exit code.

`Elevated` records whether the process that wrote the summary held an elevated token. It is there because it is the usual reason `PublishErrors` is not empty, and because it cannot be recovered from the files after the fact.

`EmitErrors` names whatever went wrong on the `-EmitTo` channels, and is empty on every run that did not ask for them. It is deliberately **not** folded into `PublishErrors`: those two describe failures of different severity, and one field would lose the distinction in the direction that breaks a customer's scheduler. `PublishErrors` means the stable files no longer describe the newest run, and it exits `3`. `EmitErrors` means an additional channel is broken, and it changes nothing. Alert on it separately, and read a non-empty `EmitErrors` beside `Status OK` as what it is - a healthy estate whose forwarder feed needs fixing. One ordering consequence is worth knowing: the emit channels run *after* the summary is written, so `EmitErrors` is filled in by a second, best-effort rewrite of the same file. A summary that could not be written at all is therefore reported by `PublishErrors` and the exit code, never by this field.

`TrendMetric` in the summary names the counter growth was measured on. On a mixed estate it reads `Mixed`, meaning both counters were in use in the one run: the mailboxes whose posting list table is readable were trended on it and carry projected dates, and the mailboxes still reading `0 B` were trended on `IndexPayloadBytes` and carry a ranking instead. `TrendedOnPayload` gives the size of that second group.

Read `Emerging` as the answer only when `TrendedOnPayload` is `0`. Above zero, `Emerging` is keyed on a projected date and no date is produced on the fallback path, so it can only ever name mailboxes from the group the thresholds can see - a short list there is not evidence that the rest of the estate is quiet. Alert on `Growing` alongside it, and on `GrowingRanked` for the part of the estate that has an order but no dates. See [When the posting list table reads 0 B](#when-the-posting-list-table-reads-0-b).

#### How long a run takes, and where the time goes

Every run measures itself. Five fields in `latest-summary.json` say how much work it did and how long each part of it took:

| Field | Meaning |
|---|---|
| `MailboxesEvaluated` | How many mailboxes the run collected statistics for, after skips. The denominator for everything below. `0` on a run that aborted before it collected |
| `DurationSeconds` | Wall clock for the whole run, from the moment it took the lock to the moment it wrote this file |
| `BindSeconds` | Opening the Exchange runspace and confirming `Get-MailboxStatistics` came back with it |
| `DiscoverSeconds` | Selecting the databases in scope |
| `CollectSeconds` | The per-mailbox statistics loop, across every database in scope |

The same breakdown prints on the console under `RESULT`, and each phase boundary is logged as it is crossed, so a run that is still going can be read from its log rather than waited out.

**Three phases rather than one number, because they scale on different things.** `BindSeconds` is very nearly a fixed cost whatever the estate - a runspace to one Exchange server costs what it costs, and ten times the mailboxes do not make it slower. `DiscoverSeconds` tracks the database count. `CollectSeconds` tracks the mailbox population, and on any estate large enough for the question to be worth asking it is the whole of the answer. A single total averages a fixed cost across a variable population, which flatters a small estate and understates a large one - so a total cannot be extrapolated from one estate to another, and these three can. Measure a scope you already have, and the term that is going to grow is named rather than buried.

The three do not sum to `DurationSeconds`. The difference is the setup before the bind and the reporting, publishing and retention sweep after the collection. That remainder is deliberately not broken out: it is small, and it does not scale with anything anyone is asking about.

**A run that aborted still reports them, and that is when they are worth most.** A phase the run never reached reports `0`. A phase it died *inside* reports how long it had been in it when it failed, rather than `0` - so an abort carrying `BindSeconds 180` and `DiscoverSeconds 0` names the runspace as the thing that hung, which is otherwise a log-reading exercise. The two zeroes are told apart by the phase after: a `0` with a non-zero phase behind it means that phase was fast, and a `0` with nothing after it means the run never got there.

> [!NOTE]
> **The instrument is here; measurements from a large estate are not.** Every timing in this article was taken on a lab DAG of under 100 mailboxes, and a per-mailbox cost measured there does not transfer to an estate two orders of magnitude larger - different storage, different RBAC evaluation, different database layout. These fields exist so that the estate running the monitor can answer the scale question from its own runs instead of from ours: collect a week of summaries, and `CollectSeconds` over `MailboxesEvaluated` is the per-mailbox cost on your hardware. Size the `-MaxRunMinutes` budget and the schedule interval from that, not from any figure in this document.

#### Which DAG node to schedule on

In a DAG, `Get-MailboxStatistics -Database` returns data only from the server currently hosting the active copy. Register the task on **every** member of the DAG and pass no `-Databases`, which is the case the script's discovery is built for: it selects only the databases whose active copy is mounted on the local server.

That arrangement survives a switchover: whichever node holds the active copy after a failover is the node that collects it, with no reconfiguration. The nodes that do not hold an active copy exit 3 with an explanatory log line, so a node reporting exit 3 continuously is expected on a passive-only member and is not by itself a fault.

A passive member still writes a log file on every run, so it is also the node where housekeeping matters most: at a 15-minute interval that is roughly 35,000 files a year in one directory, on a node that never produces a report anyone reads. The retention sweep runs on every exit that held the lock, including exit 3, so a passive member prunes its own logs without ever collecting anything.

Do not try to cover the DAG from one node by naming every database in `-Databases`. It works while that node is up, and stops silently when it is not.

#### `-Scope All`, and what a Partial means now

`-Scope All` works from any invocation, including a scheduled task, because the monitor opens its own Exchange runspace rather than loading the snap-in. Measured from a real scheduled task on a three-node lab DAG: `4 database(s) in scope`, 97 mailboxes evaluated, `FailedDatabases` empty, exit `0`. The same task under `-Scope Local` on the same node collected 2 databases and 50 mailboxes, which is the whole of what that node holds. So a `Partial` from a `-Scope All` run is a real finding about the estate: a database that is dismounted, outside this account's RBAC, or genuinely unreachable. Read `FailedDatabases` in `latest-summary.json` and the per-database reason in the log, and treat it as a collection failure rather than an artefact of how the run was started.

This depends on the task carrying a network credential, which means the stored-password logon described in [The logon type is load-bearing](#the-logon-type-is-load-bearing). Under `S4U` the run does not reach a reduced scope, it reaches no scope at all and exits `3`.

That was not always true, and an older build or an older log will show the difference. Under the in-process snap-in the same run reported `Partial` on **every** execution, naming every database whose active copy was mounted on another node:

```text
Exchange Information Store on server 'ex01.contoso.com' is inaccessible.
  MapiExceptionNetworkError: Unable to make admin interface connection to
  server. (hr=0x80040115, ec=-2147221227)
  Lid: 12514 Win32Error: 0x5
```

`Win32Error: 0x5` is `ACCESS_DENIED`, and the call failed in under a second rather than timing out - the tell that nothing was attempted on the wire. If you see that signature, you are looking at output from a build before `1.7.0`, or at another script that still loads the snap-in. It is not a fault on the server named in the message.

Two things follow that are easy to get wrong while triaging any in-process store binding, and they still apply to other scripts:

- **Not every cross-node Exchange call fails, so a working call proves nothing.** `Get-MailboxDatabaseCopyStatus` and `Get-ServerHealth` against the same peer succeed from the same failing session, because neither touches the store. Only store admin calls fail: `Get-MailboxStatistics -Database`, `Get-MailboxStatistics -Identity`, and `Get-LogonStatistics -Database`.
- **`Test-MAPIConnectivity -Server <peer>` is not a valid second opinion.** Run from the same session it fails the same way, which reads like a store outage on the peer and sends the investigation to the wrong host. It is measuring the invocation, not the peer.

For scheduled monitoring, pass `-Scope Local` explicitly on every node. It is **not** the default - the default is `All` - and this is the one place in this article where the default is the wrong choice. `Local` on every node covers the DAG, survives a switchover with no reconfiguration, and spreads the collection across the members that own the data instead of funnelling every store call through one runspace. Leaving it off registers a task on each member that sweeps the whole organization, so every node writes a full set of files describing the same estate; `-RegisterScheduledTask` warns when `-Scope` was not passed explicitly for exactly this reason, and that warning is described in [What the script refuses to do](#what-the-script-refuses-to-do). Reserve `-Scope All` for an ad-hoc estate-wide sweep from one place:

```powershell
& 'C:\Scripts\Monitor-BigFunnelPostingList.ps1' -Scope All -OutputPath 'C:\Temp\Sweep'
```

One consequence for reading the logs: a passive member running at `-Scope Local` logs a `WARN` saying no active copies are mounted there and pointing at the two ways round it. Both now work. Neither is needed if the task is registered on every member as this section describes, which remains the recommendation.

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

The `Start-MailboxAssistant` cmdlet is available in Exchange Server 2019 Cumulative Update 11 (CU11) or later, and in every build of Exchange Server SE, which continues that servicing line. It starts the `BigFunnelRetryFeederTimeBasedAssistant` assistant, which indexes mailbox items that were not indexed previously.

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

Exchange Server 2019 and Exchange Server SE implement workload management (WLM) throttling. By default, WLM applies a limit of 10 simultaneous mailbox moves from the same source or to the same target. WLM throttling overrides Mailbox Replication Service (MRS) throttling.

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
2. Consider invoking `Start-MailboxAssistant` with `BigFunnelRetryFeederTimeBasedAssistant` if running Exchange Server 2019 CU11 or later, or any build of Exchange Server SE, and the required setting override is in place.

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
