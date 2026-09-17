# **Get-ExoQueue**

## **Overview**

`Get-ExoQueue` approximates the Exchange Online message queue using **Message Trace data**. It
retrieves messages for a time range and reports how deep the queue is, how old it is, and which
destinations it is going to.

> **This is an approximation, not the transport queue.** Exchange Online exposes no queue object, so
> there is nothing to read directly. Every run prints a disclaimer saying so. Please repeat that to
> customers — a message trace row is not a queue entry.

**Current version: 1.6.6.** It supersedes 1.4.2, which has moved to [`archive/`](archive/) — that
version under-reports on any tenant where the queue exceeds one page, and reports the run as
complete while doing so.

---

## **Quick start**

```powershell
. .\Get-ExoQueue.ps1                       # dot-source it; running it does nothing useful

Get-ExoQueue -AgeHours 6 -Status Pending,Failed -Output None -PassThru -Force
```

Two habits worth forming immediately, both explained below: **pass `-Status` explicitly**, and
**check `Truncated` before quoting any number.**

---

## **The two things that catch people out**

### **1. `-Status` defaults to `Pending` only**

A tenant full of `Failed` or `Delivered` mail will report **zero**, correctly, and that looks like an
empty queue when it is not. Since 1.6.5 the tool says so:

```
Number of messages in the queue: 0
  Nothing matched Status=Pending in this window. That is a filter result, not necessarily an empty tenant.
  -Status defaults to Pending only. Add -Status Pending,Failed or -IncludeDelivered to widen it.
```

### **2. A truncated run reports a floor, not the queue depth**

```powershell
$r = Get-ExoQueue -AgeHours 6 -Status Pending,Failed -PassThru -Force
$r.Truncated          # did the run finish?
$r.TruncationReason   # if not, why not
```

Reasons include reaching `-MaxQueryPages`, a failed page, or a cursor that could not make progress.
The run also warns on screen. **Do not quote a queue number to a customer without checking this
first.**

---

## **Reading the output**

```
Number of messages in the queue: 52  (154 recipient deliveries)
Queue age: oldest 1.8 hr, median 64.8 min, newest 14.1 min
Retrieved in 8.2 s over 3 pages.

Queued by destination domain (4):

Domain                 Deliveries  AgeMinutes
------                 ----------  ----------
contoso-partner.com           131       106.5
fabrikam.com                   12        42.1
northwind-traders.com           8        31.7
adventure-works.com             3        14.1
```

- **Two counts, not one.** Messages and recipient deliveries differ whenever one message fans out to
  many recipients. Conflating them makes a queue look far worse than it is. The bracketed delivery
  count is shown only when it differs from the message count — when they match, it would be
  restating the number beside it.
- **Age matters as much as depth.** A hundred thousand messages thirty seconds old is a burst; the
  same hundred thousand six hours old is an outage. The count alone cannot tell them apart. The unit
  scales — seconds, minutes, hours, days — so the outage case does not arrive as `404.0 min`.
- **Destination.** There is no real `NextHopDomain` in Exchange Online, so the recipient domain
  stands in for it. When one destination defers, its domain rises to the top of this list — the shape
  above, where 131 of 154 deliveries are waiting on one partner, is what a single deferring
  destination looks like. The heading names the domain total, so `(4)` means you are seeing all of
  them and `top 10 of 37` means a tail is hidden.
- **Paging is quiet.** Per-page detail goes to a progress bar rather than scrollback. Add `-Verbose`
  for the page-by-page trail when you are diagnosing paging itself.

---

## **Journal mail**

In a regulated tenant this is usually the largest single distortion: journaling copies every message
to an archive address, which doubles the delivery count.

```powershell
Get-ExoQueue -AgeHours 6 -JournalOnly      # size the journal backlog on its own
Get-ExoQueue -AgeHours 6 -JournalExclude   # everything else
```

The journal address is discovered from the tenant's own journal rules (`Get-JournalRule`), so you do
not need to know it. It falls back to a prompt and a saved value, which is now stored **per tenant** —
before 1.6.1 one shared value meant working across tenants could silently filter on the wrong
address.

`-JournalOnly` filters inside the service and is much cheaper. `-JournalExclude` cannot: message
trace has no "everything except this recipient" filter, so journal rows are retrieved and then
discarded, and the page budget is spent either way. `$result.JournalExcluded` reports how many.

---

## **At incident scale**

Measured, not estimated: roughly **24 seconds and 1.3 GB of managed memory for 100,000 recipient
rows.**

- `-ResultSize` maxes at **5,000** per page; the service allows **100 requests per rolling 5 minutes**.
- `-ResultSize 5000 × -MaxQueryPages 20` is **exactly 100,000 rows**. If you expect more, raise
  `-MaxQueryPages` *before* you need it.
- Prefer `-Output CSV` over GridView at that size. GridView caps at 20,000 rows and warns.

---

## **What it cannot do**

Set this expectation before the customer does:

- No `Suspend`, `Resume`, `Retry`, `Remove` or `Export` — Exchange Online exposes **no queue control
  surface at all**.
- No true `NextHopDomain`, no per-message `LastError`, no `ExpirationTime`.
- Outbound-shaped: it sees what message trace sees.

It is a diagnostic, not a control plane.

---

## **Prerequisites**

- PowerShell 5.1 or later.
- `ExchangeOnlineManagement` 3.7.0 or later (`Install-Module ExchangeOnlineManagement`), which must
  provide `Get-MessageTraceV2`.
- Permission to run `Get-MessageTraceV2`. Journal discovery additionally needs `Get-JournalRule`; it
  degrades gracefully without it.

---

## **Output**

- `-Output` accepts `GridView`, `CSV`, `XML` or `None`, and more than one at a time.
- Files are written under `C:\Temp\ExoQueueResults\<Date>\` by default; `-OutputPath` overrides.
- A trend log, `ExoQueueLog--<Date>.txt`, is appended on every run, including empty ones — an empty
  queue is the single most useful point in a queue trend.
- `-PassThru` returns the result object. `-Quiet` suppresses console output for scheduled runs; use
  it with `-Force`, or the run will stop on a prompt you cannot see.

---

## **Tests**

```powershell
Import-Module Pester -MinimumVersion 6.0.0
Invoke-Pester -Path .\Get-ExoQueue.Tests.ps1 -Output Detailed
```

158 tests, offline — they stub `Get-MessageTraceV2` and connect to nothing.

`Test-ExoQueueTenantAssumption.ps1` is different: it runs **seven read-only queries against your own
connected tenant** and reports whether the service behaves the way this script assumes. Worth running
once in an unfamiliar tenant. `Test-ExoQueuePagingFidelity.ps1` proves the paging loop retrieves a
known corpus exactly, offline.

---

## **What changed since 1.4.2**

The headline is that **1.4.2 silently under-reports.** Highlights of the rebuild:

- **Paging.** 1.4.2 stops after one page, so a queue deeper than `-ResultSize` is reported at the cap
  and called complete. Paging now follows the documented cursor, and every exit path sets `Truncated`
  and `TruncationReason`. A separate defect — the service floors `EndDate` to whole seconds, so a
  cursor seeded with a sub-second timestamp silently skipped every row in that second — was found
  against a live tenant and fixed in 1.6.4.
- **Journal filtering was inverted.** `-JournalOnly` and `-JournalExclude` filtered on the *sender*,
  so `-JournalOnly` matched only mail the journal mailbox itself sent (in practice, almost nothing).
  They filter on the recipient now. **Expect counts to move.**
- **Time basis.** Page 1 used a local `EndDate` while later pages used the UTC value, so west of UTC
  the window moved the wrong way. Reconciled, and verified against a live tenant.
- **Multi-recipient messages** lost every recipient but one on export. `RecipientCount` and
  `Recipients` are now reported, and Top Recipients counts deliveries rather than deduplicated
  messages.
- **Added** queue age, the destination-domain breakdown, throttle pacing and retry against the
  documented request budget, UTF-8 output, and `-Force`, `-PassThru`, `-Quiet`, `-Status`,
  `-StartDate`/`-EndDate`, `-OutputPath`, `-JournalSmtp`, `-TimeBasis`.
- **The console lied about paging.** The per-page line ended `Querying next page..`, and it was
  printed from a callback that fires *before* the loop evaluates any stop condition — so the page
  that returned zero rows and ended the run still announced a next query. The last thing on screen
  at the end of every long run was a promise it did not keep, which reads exactly like a hang.
  Fixed in 1.6.6, along with a general tidy: the answer now comes before the housekeeping, file
  paths are collected into one block at the end, and durations scale to a readable unit.

Full version history is in the comment block at the end of `Get-ExoQueue.ps1`.

---

## **Disclaimer**

Provided **"as is"** without warranties or guarantees. Use at your own risk, and test before relying
on it in production.
