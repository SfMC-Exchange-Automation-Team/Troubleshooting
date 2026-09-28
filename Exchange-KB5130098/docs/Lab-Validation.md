# KB5130098: validation and operational lessons

- **Observed:** September 25, 2026
- **Scope:** Original 1.0.1 lab pilot, console/elevation coverage, unified CSV inventory, and 1.1.1 display refinement; not a customer rollout

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

The suite now has **136 tests**. Non-Apply output shows one Status column; only
Apply and its explicitly labelled previews retain Before/Current. Rollback
continues to describe the removals and required follow-up but shows resulting
status rather than an Apply comparison.

Formatter tests inspect actual `Write-Host` calls to verify that each Present
file-state value is green for local and remote target labels, in either Apply
column, and alongside unchanged existing-file stop warnings. Missing and
unobserved values are not colored green. Native output tests verify the exact
column shapes, unchanged action/error messages, and machine JSON/exit behavior.
Green indicates presence only, not verified remediation or workload recovery.

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
