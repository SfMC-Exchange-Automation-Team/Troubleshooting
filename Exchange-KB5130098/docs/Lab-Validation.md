# KB5130098: validation and operational lessons

- **Observed:** September 25, 2026
- **Scope:** Original lab pilot, console/elevation coverage, unified CSV inventory and structured reporting; not a customer rollout

This is a sanitized summary. Private hostnames, identities, operation IDs, raw logs,
credential helpers, test-mailbox provisioning, and session scaffolding are not
published. The [usage guide](../README.md) describes the supported operator flow.

## What was tested

| Area | Observation |
|---|---|
| Source and payload identities | Source checksums matched. Both rule files matched the pinned sizes and SHA256 values. |
| Original 1.0.1 regression suite | 55 passed, zero failed or skipped; includes 16 native Windows PowerShell 5.1 entry-point tests. |
| Native Detect | Verified eligible/missing rules with exit 0, existing rules with exit 20, and an older ineligible build with exit 20. |
| Native fleet WhatIf | Exit 0 on all three lab targets, no remote connections or report creation. |
| Actual fleet inventory | The original serial Kerberos inventory reported the expected three server states without applying the rules. |
| Original guarded Apply | One eligible pilot received only the two verified BINs and a graceful Host Controller restart. |
| Existing-file guard | The pilot subsequently refused Apply rather than overwriting rules or restarting again. |
| Unchanged controls | The other eligible control and older-build control were not patched or restarted. |
| Final workload | Two ordinary/English and two Korean messages delivered, preserved their bodies, and passed EWS subject/body queries. |
| Negative controls | Four nonexistent-term queries correctly returned no test item. |
| Final diagnostic window | 275 CTS lines observed; no matched feeder/Korean-init/timeout failures and no relevant application warnings/errors. |
| Final health | Transport queues empty; database copies Mounted/Healthy with zero copy/replay queues; monitored services running. |

The recorded video's visual commands are illustrative. Its final test results
summarize the original 1.0.1 observations; it does not show a new live deployment.

## 1.0.2 console and elevation coverage

The 1.0.2 suite had 87 tests. Its added coverage includes standard RunAs launch selection,
32-bit-to-64-bit host selection, cancellation, unknown child exits, no-loop and
unattended/remoting/JSON/pipeline guards, and preserved arguments with spaces,
apostrophes, literal PowerShell syntax, trailing separators and false switches.
Inherited WhatIf and confirmation preferences also cross the boundary, so a
session-level preview cannot become a modifying run merely because it elevated.

The launch/consent boundary is mocked. A real native Windows PowerShell child
executes the generated bootstrap against a harmless fixture to verify values,
working directory, loop prevention and exact exit codes 0, 1, 10 and 20. These
tests do not approve a real UAC prompt or execute Exchange Apply.

Native human-output tests use the actual console formatter with a fixture backend.
They cover default Detect, WhatIf, staging, completed startup observation, rollback,
wrong-build/existing-file stops, and a partial failure with current file state and
its receipt. `-AsJson` separately retains the original machine result/exit behavior.
Before/current refer to observations from the current invocation, not invented
historical state.

## 1.1.0 unified targeting and CSV coverage

The 1.1.0 suite passed **130 tests**. It covers strict CSV headers, quoted commas
and multiline metadata, blank/malformed rows, exact field counts, DNS/NetBIOS
validation, case-insensitive duplicates, deterministic ordering and a 2,500-name
roster without truncation. Extra metadata, including an `Enabled` column, is not
interpreted as a hidden filter or permission to change a server.

Native tests verify that the primary script dispatches `-ComputerName` or
`-CsvPath` without running the local engine or local UAC path; ambiguous targeting
and remote rollback are refused. Real no-connection CSV WhatIf produces valid
machine JSON. Module tests verify file-only Apply, explicit restarted rollout,
mandatory recovery attestation, duplicate-machine aliases, fail-stop behavior,
`NotRun` report entries, and pre-connection rejection of unattended restarts.
The legacy fleet wrapper preserves its earlier Apply/restart contract.

Actual CSV Detect ran against three explicit lab targets in both human and JSON
modes over Kerberos/WinRM. Two targets already had rule files; the third had an
older ineligible build. The primary returned exit 20 with all three observed
records, in CSV order. Human output used the requested server name in each
before/current/action summary rather than the management computer's name.

Independent before/after fingerprints confirmed unchanged Exchange file
identities, directory ACLs, service states/PIDs and NodeRunner identities across
all three servers. No live Apply, rollback, service restart, parallel deployment,
credential setting or trust-policy change was performed for this feature test.
This validates three-target inventory, not a claim that a large modifying rollout
has been exercised.

## 1.1.1 display refinement

The 1.1.1 suite passed **136 tests**. Non-Apply output shows one Status column; only
Apply and its explicitly labelled previews retain Before/Current. Rollback
continues to describe the removals and required follow-up but shows resulting
status rather than an Apply comparison.

Formatter tests inspect actual `Write-Host` calls to verify that each Present
file-state value is green for local and remote target labels, in either Apply
column, and alongside unchanged existing-file stop warnings. Missing and
unobserved values are not colored green. Native output tests verify the exact
column shapes, unchanged action/error messages, and machine JSON/exit behavior.
Green indicates presence only, not verified remediation or workload recovery.

## 1.1.2 report-directory default

The 1.1.2 suite passed **149 tests**, including minimal native direct, CSV and legacy commands that
omit ReportDirectory, along with explicit override and empty-input checks.
Module tests verify the one shared default, unique per-run reports, no report
creation during WhatIf, and failure before any target connection when the report
directory is invalid or cannot be created. A default is not a silent fallback:
an explicitly bad path or write failure is still an error.

Only a safe output location is inferred. No target, modifying operation, restart,
maintenance approval, credentials or recovery attestation is selected implicitly.

Read-only live direct and CSV runs from the calling lab server also omitted
ReportDirectory. Each created a different report under the documented default
on the caller and returned the expected existing-rules review result. No
parameter prompt occurred; existing operational confirmation behavior was not
changed. Independent fingerprints confirmed unchanged Exchange files, ACLs,
service states/PIDs and NodeRunner identities on caller and target.

## 1.2.0 report objects and exports

The suite passes **175 tests**. Reporting coverage verifies that session-level
`$report` contains typed rows rather than formatted strings, `$reportFiles` names
the files, and terminal output remains usable. Native cases exercise explicit
`-PassThru`, machine JSON, stale-result clearing, errors, preview/no-file behavior,
and `-NoCsv`.

CSV tests round-trip commas, quotes, multiline errors and Korean text. Formula-like
spreadsheet strings are neutralized only in CSV, while objects and JSON preserve
the original value. Detailed JSON keeps nested data; finalized UTF-8 JSONL has
one complete object per physical line, a run ID, UTC timestamp, scalar fields
and typed booleans. Final JSONL is not rewritten as a fleet checkpoint.

Tests preserve failed and unvisited targets, prevent missing observations from
looking successful, and surface export failures while retaining available rows.
Elevation tests use the real native child bootstrap and a private reserved-file
handoff to return report data, validate the child's exit code, enforce ACLs and
cleanup, and reject missing/mismatched handoffs. Actual UAC consent is not clicked
or bypassed by these tests.

The Splunk guidance was checked against published configuration specifications.
Neither a customer Splunk connection nor live Splunk ingestion was performed;
field extraction, timestamp mapping, duplicate handling and customer index policy
must still be validated by that environment's Splunk administrator.

Read-only live checks subsequently exercised local human output, one remote
target, a two-target CSV with machine JSON, NoCsv, and a preview in the same
PowerShell session. The report variable retained typed rows in every case;
terminal summaries/paths were present, CSV identities matched the objects,
detailed JSON parsed, and JSONL contained exactly one UTF-8 object per row.
NoCsv omitted only CSV; the preview exported no files. Installed Exchange file,
ACL, service/PID and NodeRunner fingerprints stayed unchanged across caller
and targets. No Apply or service restart was performed for the reporting update.

## Why the first workload observation was not enough

The initial ordinary message passed before applying the rules. After the
ContentEngine restart, new ordinary mail delivered but did not appear in the
tested subject/body query during two separate five-minute windows.

Those remain genuine failed observation windows. A running process and healthy
monitor status did not justify declaring recovery.

Subsequent investigation found long-running callers retaining failed FAST/CTS
feeder objects. The logs distinguished an old feeder reporting blocked delivery,
its shutdown, and a new feeder opening a session. Several callers recovered
without a service restart.

New-message searches began passing while a residual feeder warning still occurred.
That is why the investigation continued instead of treating a positive query as
the entire recovery criterion.

## Attribute the failure to its caller

`MSExchangeFastSearch` event 1006 was emitted by multiple processes in the lab:
EWS, Mailbox Transport Delivery, and EdgeTransport.

The **event provider name is not the originating service**. Use:

1. The event XML's `System/Execution/@ProcessID`.
2. The matching live executable and parent/service identity.
3. Correlated CTS feeder/session identifiers and timestamps.
4. The workload's own health and maintenance requirements.

The last residual warning was attributed to a preexisting EdgeTransport worker.
A separately scoped, graceful `MSExchangeTransport` restart on the pilot was
performed only after verifying empty queues, healthy database copies, the exact
caller identity, and no running dependent services. Stop/start waits were bounded;
no process was force-terminated. The new worker was observed stable, while the
other monitored service and NodeRunner identities remained unchanged.

This was an **evidence-led lab recovery**, not a new automatic action added to the
deployment package. Do not turn it into a blanket restart recommendation.

## Final workload and limits

After the targeted caller recovery, all four new-message tests and all four
negative controls passed. The diagnostic window remained clear through the final
snapshot, roughly eight minutes after that validation run began.

The temporary mailbox reported four indexed items. Its aggregate not-indexed
counter did not drain during the two-minute sample. No claim is made that every
older or retained item was processed.

Not established by this test:

- Complete historical backlog recovery.
- Sustained production-load behavior.
- Reproduction of every Korean initialization/deadlock trigger.
- The original customer's symptoms or impact boundary.
- OWA or Outlook UI/connectivity recovery; the automated checks used EWS.
- Live rollback, which was not attempted without actual Support approval.

Temporary recipients, scheduled tasks, and staging were removed. Normal
disconnected-mailbox retention applied. The original Apply receipt and installed
workaround files were retained on the pilot; they were not deleted merely to
exercise another Apply.

## Why retain the guarded kit

A smaller pilot script offered useful payload confirmation and caller-recovery
guidance. It did have basic error handling: terminating errors, input hashes,
existing-file refusal, no-overwrite copying, copied-file hashes, and snapshots.

The guarded kit adds explicit applicability, protected incremental receipts,
inherited-read checks, operation serialization, bounded restart observation, and
serial fleet recovery gates. Service snapshots alone do not enforce these checks
or prove workload recovery.

Version 1.0.1 fixes omitted path defaults under native `-File` invocation and
documents explicit forwarding of custom exit codes through `-Command`. The guarded
deployment engine and builder were not broadened or weakened by those corrections.

## Public distribution boundary

This repository publishes source, offline tests, the article, and finished
instructional media. It intentionally does not redistribute Microsoft's rule
binaries or SQL media. Obtain those through the reviewed local build process and
the current Microsoft guidance, and review licensing before redistributing the
generated deployment package.
