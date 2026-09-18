# Tests

**Nothing in here is for troubleshooting a customer estate.** These verify the script and the
runbook against each other. If you came here to look at posting list tables, the script you
want is [`../Monitor-BigFunnelPostingList.ps1`](../Monitor-BigFunnelPostingList.ps1).

They live in a subfolder so the parent folder shows what an operator actually runs. They are in
the repo, rather than in a private workspace, because the script makes specific claims about
its own correctness and these are what back them up.

| File | What it does |
|---|---|
| `run-tests.ps1` | **529 assertions.** Runs non-elevated against a mocked Exchange and a mocked scheduler; connects to nothing and creates no task. |
| `runbook-checks.py` | 6 mechanical checks, 8 assertions, that the runbook still describes the script. Read-only, no PowerShell, no Exchange. |
| `runbook-checks-selftest.py` | **12 proofs** that `runbook-checks.py` still **fails** when it should. See below - this is the one that is easy to skip and worst to skip. |
| `Verify-LabGates.ps1` | Gates A-E: the things no offline test can reach, on a real elevated box. |
| `Verify-PolicyRefusal.ps1` | Gate F: produces the scheduled-task refusal with a **real** access control rather than an injected fault. |
| `Probe-EventLogRights.ps1` | The read-only half of Gate A. Every call is a read; it writes nothing anywhere. |
| `_mockmodules/` | `MockExchange` and `ScheduledTasks`. See below - the second one is named to shadow the real module deliberately. |

## Running them

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-tests.ps1
python .\runbook-checks.py
python .\runbook-checks-selftest.py
```

No Pester, no modules to install, no Exchange, no elevation, no network. All three should end
with a zero:

```text
RESULT: 529 passed, 0 failed
CHECKS: 0 failed
PROOFS: 0 failed
```

The lab gates are separate and need a real Exchange member - see below.

## Why there is a self-test for a test

An audit of the runbook found **six** defects by diffing it against the script: a wrong `$Scope`
default, a missing `ConsoleRelayPath`, an `-ExitNonZeroOnAlert` description that omitted exit
`6`, `PublishFailed` missing from the Status table and from the worst-first sentence, and two
undocumented summary fields.

**Every one of them read perfectly well as prose.** None would have been caught by reading the
document, however carefully, because nothing about a correct-sounding sentence announces that
the thing it describes has moved. That is what `runbook-checks.py` is for: it compares
parameter triples, the `$runStatus` chain, every `exit N`, every event ID and every in-page
anchor against the script, on both sides, so an addition on either side that is missing from
the other is a failure rather than an omission.

A checker like that has one failure mode, and it is silent: its patterns match what the script
is *allowed* to contain, not what it happens to contain today. An untyped parameter and an
`exit 7  # why` both existed nowhere when it was written, and both would have been read as
**absent** rather than reported - while the `PASS` line kept appearing. `runbook-checks-selftest.py`
mutates a copy of the pair and asserts the checker fails, so a check that has quietly stopped
seeing things gets caught.

Run the self-test whenever you touch `runbook-checks.py`, and after any change to the shape of
the script's parameter block or exit codes.

## The mock modules

`_mockmodules/MockExchange` reproduces `Unlimited<ByteQuantifiedSize>` as measured on Exchange
SE RTM 15.2.2562.17 - a wrapper carrying `IsUnlimited` and `Value`, where `ToBytes()` exists
only on the inner value and never on the wrapper. Packaged as a module so command auto-loading
resolves it in place of the real cmdlets, which lets the monitor run as the top-level `-File`
script the way a scheduled task invokes it, so its **exit codes are the process exit codes**.

`_mockmodules/ScheduledTasks` is **named to shadow the real module on purpose**, and two
independent mechanisms point the same way: the harness prepends `_mockmodules` to
`PSModulePath`, and these are *functions* where the real ones are *cmdlets*, which wins on
PowerShell's command precedence. That is deliberate belt and braces - a test that silently
reached the real scheduler would create a real task on the machine running the suite.

What it reproduces is the **measured** behaviour from `w25-ex01` and commit `54ebad7`, not the
documented behaviour. The difference is the whole point: `-User` without `-Password` registers
a task that reports `Ready` and has never run.

## The lab gates

Several things are unprovable from the suite, for the same reason every time: **the suite runs
non-elevated and against a mock, and these gates are about what the real, elevated machine
does.**

```powershell
.\Verify-LabGates.ps1        # A-E
.\Verify-PolicyRefusal.ps1   # F
```

- **Gate A - the Event Log rights split.** Measured non-elevated: creating a source needs
  administrator, writing to an existing source does not, and `SourceExists()` *throws* for a
  caller who cannot enumerate the log list. `Initialize-EmitEventSource` treats that throw as
  INDETERMINATE rather than as "absent", and that reading is only correct if an elevated caller
  gets a clean `$false`. [`Probe-EventLogRights.ps1`](Probe-EventLogRights.ps1) answers the
  read-only half without changing anything on the target.
- **Gate B** - a real registration, which the suite cannot reach.
- **Gate F - the policy refusal.** This is the gap that mattered most, because **the blocked
  path is the customer's primary environment** and it had only ever been proven against a mock.
  The suite covers it by setting `MOCK_TASK_DENY=1`, which makes the harness throw a synthetic
  `Access is denied`. That proves the handler works when handed a message it already expects;
  it does not prove Windows produces that message. `Verify-PolicyRefusal.ps1` applies a real
  access control and measures what the monitor actually says.

## If you change anything an operator sees

The walkthrough in [`../docs/`](../docs/) is a snapshot. When the console wording, parameters
or result fields move, the video keeps playing and keeps teaching the old behaviour - nothing
announces the divergence.

**There is no automated drift check for it yet.** Until there is, treat a change to the report,
the parameter set or the exit codes as a prompt to re-read
[`../docs/README.md`](../docs/README.md), which records exactly which version each chapter
shows and why.
