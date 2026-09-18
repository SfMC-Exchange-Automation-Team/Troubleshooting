# **BigFunnel500**

## **Overview**

Oversized BigFunnel search metadata makes mailboxes unavailable. A broad search against a
mailbox with a large `BigFunnelPostingListTableTotalSize` can hold mailbox-level resources for
hours, blocking mail delivery and client access until the search finishes or the database is
switched over. Shared mailboxes are hit hardest.

This folder holds the runbook for diagnosing and remediating it, and a monitor that finds the
mailboxes heading that way **before** anyone is blocked.

> **Database switchover restores access but does not fix the problem.** A DAG switchover
> preserved a 12 GB table at roughly 11.5 GB. It releases the lock; it does not rebuild the
> metadata. The runbook separates the two remediation patterns and says which applies when.

**Current version: 1.14.0.**

---

## **Quick start**

```powershell
# Read-only. From an ordinary shell - it elevates itself and relays the child's
# output back into the window you are already looking at.
.\Monitor-BigFunnelPostingList.ps1 -Scope Local

# Query a run instead of reading it
$r = .\Monitor-BigFunnelPostingList.ps1 -Scope All -PassThru
$r | Where-Object Status -eq 'Critical'
```

> **New here?** There is a narrated walkthrough in [`docs/`](docs/) - verifying the copy,
> reading the report, watching it find something, and scheduling it. A
> [transcript](docs/BigFunnel-Monitor-Walkthrough.transcript.md) is there too if you would
> rather read it.

---

## **Verify the copy before you run it**

The script is **not code-signed**, so the hash is the only thing that says the file you have is
the file that was tested. Check the line and byte counts too - they catch a copy truncated in
transit, which a hash only tells you about after you already have a known-good one to compare
against.

```powershell
Get-FileHash .\Monitor-BigFunnelPostingList.ps1 -Algorithm SHA256
```

| | |
|---|---|
| SHA256 | `511CE5AC251D93D6033C7AB900A6553BB9328BB8DF1F9E0B6288D423AECF9CFF` |
| Size | 244,931 bytes, 4,399 lines |
| Version | 1.14.0 |

It calls three Exchange cmdlets and all three are read-only: `Get-ExchangeServer`,
`Get-MailboxDatabase`, `Get-MailboxStatistics`. It does not move a mailbox, fail over a
database, or change an Exchange setting. By default the only thing it writes is files under
`-OutputPath`. Two switches add a destination outside it - `-EmitTo` writes to the Application
event log, `-RegisterScheduledTask` creates a task - and neither happens unless you ask.

`View-Only Organization Management` is enough.

---

## **The three things that catch people out**

### **1. `-Password` is not optional, and a task that says `Ready` is not a task that runs**

This is the single most expensive mistake available here, because it fails **silently**:

| Registration | Result |
|---|---|
| `-User` without `-Password` | `LogonType Interactive`. Status `Ready`, `LastTaskResult 0x41303`, **no log, no output directory, nothing**. It has never run. |
| `-LogonType S4U` | Runs, but cannot open the Exchange runspace. Exit `3`. |
| `-User` with `-Password` | `LogonType Password`. Runspace opens. Exit `0`. This is the only one that is a monitor. |

Let the script register its own task and it enforces this, then reads the task back and proves
it:

```powershell
# From an elevated shell, on each DAG member. Write the run you want, then add
# the switch - the task is built from the run you typed.
.\Monitor-BigFunnelPostingList.ps1 `
    -Scope Local -WarningGB 1.7 -CriticalGB 2.0 -RetentionDays 30 `
    -EmitTo EventLog,RunJson `
    -RegisterScheduledTask -TaskIntervalHours 4 -TaskStartTime 00:05
```

```text
  Registered and verified: Exchange BigFunnel PostingListTable Monitor
    LogonType Password, RunLevel Highest, -File action.
```

**Stagger `-TaskStartTime` across DAG members**, or every node collects in the same minute -
the one thing a per-node registration exists to avoid. `-UnregisterScheduledTask` removes it
and confirms the removal rather than assuming it.

Where policy blocks local admins from creating tasks, the run says so in those words and exits
`7`, rather than letting a raw `Access is denied` out. The runbook keeps the manual
`Register-ScheduledTask` block for handing to whoever does have the rights.

### **2. Alert on `Status` and the exit code together, not on either alone**

A run can find a Critical mailbox and still exit `0`. That is deliberate: codes `1`, `5` and
`6` are gated behind `-ExitNonZeroOnAlert` so that adding this monitor to an existing scheduler
cannot start failing tasks on day one. The report says so on screen rather than leaving the
contradiction there.

Codes `2`, `3`, `4` and `5` mean **the monitor is not reporting on something**, which is more
urgent than a large posting list table, because it is the state in which a large posting list
table goes unseen. Route them differently from `1`. Full table in the
[runbook](BigFunnel-PostingListTable-Runbook.md).

### **3. `-Scope` defaults to `All`**

A task on each DAG member wants `-Scope Local` - the databases whose active copy is mounted on
this node, which stays correct after a switchover. Registering with the default sweeps the
whole organisation from every node, writing several full sets of files describing the same
estate. The script warns at registration time when `-Scope` was not passed explicitly.

---

## **Feeding a log aggregator**

```powershell
.\Monitor-BigFunnelPostingList.ps1 -Scope Local -EmitTo EventLog,RunJson
```

`EventLog` writes one event per run keyed to `Status`, plus one per Critical, Warning or
Emerging mailbox, bounded by `-MaxAlertDetail`. Findings are Warnings; monitor faults are
Errors. The payload is `key=value` lines - Splunk's native extraction format, and readable in
Event Viewer without a parser. `RunJson` writes the run summary as a per-run file, named so the
existing retention sweep prunes it.

Both are **additional channels, never the contract**: an emit failure is recorded in
`EmitErrors` and warned about, and cannot change the exit code.

Per-mailbox events carry `DisplayName` and `MailboxGuid`. The runbook states plainly which
fields leave the box, so that is a decision rather than a discovery.

---

## **What is in this folder**

| | |
|---|---|
| [`BigFunnel-PostingListTable-Runbook.md`](BigFunnel-PostingListTable-Runbook.md) | **The runbook.** Symptoms, cause, detection, remediation, failover vs. move, WLM throttling, operator decision flow. |
| [`Monitor-BigFunnelPostingList.ps1`](Monitor-BigFunnelPostingList.ps1) | **The monitor.** Read-only, self-elevating, schedulable. 28 parameters; exit codes `0`-`7`. |
| [`Invoke-BigFunnelScenario.ps1`](Invoke-BigFunnelScenario.ps1) | Drives the monitor into each alert state on a **non-production** estate, so the alerting can be tested before the day it fires for real. |
| [`Set-BigFunnelDemoState.ps1`](Set-BigFunnelDemoState.ps1) | Puts three lab mailboxes into a standing Critical / Warning / Emerging state for a demo. |
| [`docs/`](docs/) | Narrated walkthrough, transcript, subtitles, chapters. |
| [`Tests/`](Tests/) | Verification of the script and the runbook against each other. Not for customer work. |

### **Seeing the alert states before they happen for real**

The monitor's states are easy to describe and hard to see: a healthy dev estate never crosses
2 GB, so the Critical, Warning and Emerging paths go untested until the day they fire on
production, when nobody has seen one before.

```powershell
.\Invoke-BigFunnelScenario.ps1          # what this estate can demonstrate, and why not the rest
```

It touches no mailbox. It runs the monitor as a read-only probe, reads the sizes actually
present, and solves for the parameters that put those same real mailboxes into the state you
asked for. Emerging and Shrinking are statements about change over time, so those need a
synthetic baseline - which it writes clearly marked, with a `SYNTHETIC-BASELINE.txt` beside it.
**Never copy one into a real output directory**; the monitor cannot tell it from a genuine
earlier run, which is exactly why it works.

---

## **Prerequisites**

- Windows PowerShell 5.1 on an Exchange Server SE or 2019 member.
- `View-Only Organization Management`, or any role that can run the three read-only cmdlets.
- Administrator, for the Exchange runspace. The script self-elevates if you are not; use
  `-NoElevate` to suppress that.
- Nothing to install. No module, no agent, no network dependency beyond the Exchange server it
  connects to.

---

## **Disclaimer**

Provided **"as is"** without warranties or guarantees. Use at your own risk, and test before
relying on it in production.
