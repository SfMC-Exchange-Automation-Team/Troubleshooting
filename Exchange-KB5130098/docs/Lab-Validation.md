# Exchange Korean Rules: historical validation and operational limits

- **Original workload pilot:** September 25, 2026.
- **Historical console/reporting verification:** through September 28, 2026.
- **Historical builder/CSV/confirmation verification:** September 29, 2026.
- **2.0.0 offline worktree validation:** September 29, 2026.
- **2.0.0 source-archive verification/runtime smoke check:** September 29, 2026.
- **2.0.0 lab working-folder staging/read-only check:** September 29, 2026.
- **Current operator interface:** 2.0.0; see the [written guide](../README.md).

This separates current offline worktree and independent source-archive results,
no-contact runtime checks and sanitized historical evidence.
No new 2.0.0 live Exchange payload build, Apply, service restart or customer
rollout is claimed. Copying the tool into a lab working folder and running
read-only detection, described below, is not remediation.
Private hostnames, identities, operation IDs, raw logs, credential helpers,
provisioning and session scaffolding are not published. Operator examples use
fictional names.

## Current interface does not change the evidence boundary

Use these names for current operations:

| Command | Scope |
|---|---|
| `Install-KoreanRules.ps1` | Build verified payload/runtime; no SQL installation or Exchange Apply |
| `Get-KoreanRulesState.ps1` | Detect-only local, explicit-name or CSV inventory; no payload required |
| `Set-KoreanRulesState.ps1` | Apply by default; `-Rollback` is local and receipt-bound |

One to three targets retain detailed per-server state/action blocks.
Four or more automatically end with aggregated **`Status` + `Count`** and report
paths, not a table enumerating every server. Detailed blocks, per-target progress
and target-list dumps are suppressed. Errors still name the failed target, and
mandatory recovery prompts still appear per server; **neither is suppressed**.
Full `$report`, CSV, JSON/JSONL and explicit `-AsJson`/`-PassThru` streams retain
every target. Operators can explicitly inspect those rows with
`$report | Format-Table ComputerName, Mode, Status, TokenRule, ComplexRule`,
or use `$report | Format-List *` for all fields.

These interface checks are not proof that a large modifying
rollout or its workload recovery has been exercised. Standard confirmation is
still opt-in at the default preference; exact identity, no-overwrite, explicit
restart, maintenance approval and per-server recovery gates remain separate.

The repository folder, `C:\Temp\KB5130098-Reports`, receipts beneath
`%ProgramData%\Exchange-KB5130098` and established stable lab folders retain their
existing names. The archive-root change to `Exchange-KoreanRules` is not evidence
that any lab folder was moved. The in-place tool update below retained the
existing unversioned working folder.

## 2.0.0 worktree validation

The complete worktree suite passed **281 of 281 tests** on September 29, 2026.
The independently rebuilt source archive passed the same suite. Coverage included:

- Native invocation of the three public entry points: `Install-KoreanRules.ps1`,
  `Get-KoreanRulesState.ps1` and `Set-KoreanRulesState.ps1`.
- The exact **three-target vs four-target** display boundary for explicit names
  and CSV rosters, in both Detect and Apply.
- Aggregated `Status` + `Count` output for compact runs rather than automatic
  enumeration of every server.
- Preservation of all per-target machine data despite compact human output.
- Missing and partial payload diagnostics: expected directory, missing filenames
  and the Install/returned `PayloadDirectory` recovery guidance.
- Visibility of target-identifying errors and required per-server recovery prompts.
- Three added native cases for `Get-KoreanRulesState.ps1`,
  `Set-KoreanRulesState.ps1` and the legacy `Invoke-KB5130098.ps1` state wrapper.
  A wrapper-only/incomplete package now fails explicitly with guidance to extract
  the complete package, including the `private` folder and module, rather than
  potentially returning a stale successful exit.

No new live Exchange operation or media rebuild accompanied it. These
offline/native checks do not establish production recovery, a large live rollout,
or additional workload evidence beyond the historical pilot below.

## 2.0.0 archive and generated-runtime checks

After the incomplete-package guards were added,
[`Exchange-KoreanRules-2.0.0-source.zip`](../downloads/Exchange-KoreanRules-2.0.0-source.zip)
independently passed **281 of 281 tests** when tested from the final archive.
All **21 manifest-covered files** were hash-verified, and the source archive
contains **no vendor binaries**. No payload-bearing deployment archive is
distributed publicly.

The actual generated runtime's `Get-KoreanRulesState.ps1` was
also smoke-tested in **no-contact `-WhatIf` mode**. That check exercised the
generated entry point, not live target inventory or an Exchange modifying
operation.

No live Exchange build, Apply or service restart was performed for these checks,
and no instructional media was rebuilt. Archive tests and a no-contact preview
do not add new workload-recovery evidence or change the historical lab limits.

## 2.0.0 working-folder delivery correction

The manual-run lab copy had remained at 1.2.1 while 2.0.0 was available only on
the GitHub topic branch. The stable working folder was subsequently updated in
place with the current scripts, shared module/private runtime, documentation,
source downloads and instructional media. Previous files were backed up in a
protected directory; unrelated files and the existing verified payload were
preserved.

The working kit's manifest-tracked files and preserved payload were hash-verified. The actual
`Get-KoreanRulesState.ps1` entry point then ran in native 64-bit PowerShell in
read-only mode, returning `RuleFilesPresentStop` and exit 20 with both installed
rules present. It retained typed results and produced the expected JSON, CSV
and JSON Lines reports.

Before/after fingerprints confirmed unchanged installed Exchange file hashes,
Native-directory/file ACLs, monitored service states/PIDs and NodeRunner
identities. All 38 preexisting report/receipt files were preserved unchanged.
No Set/Apply, SQL extraction or service restart was performed. This delivery
check does not extend the historical workload-recovery evidence below.

## Original workload pilot observations

| Area | Recorded observation |
|---|---|
| Source/payload identity | Source checksums matched; both rules matched pinned sizes/SHA256. |
| Native Detect | Eligible/missing returned 0; existing rules and an older ineligible build returned 20. |
| Fleet preview | Three-target WhatIf returned 0 without connections or report creation. |
| Actual inventory | Serial Kerberos inventory observed the expected three states without Apply. |
| Guarded Apply | One eligible pilot received only the two verified BINs and a graceful Host Controller restart. |
| Existing-file guard | A subsequent Apply was refused; no overwrite or repeat restart occurred. |
| Controls | Other eligible/older-build controls were not patched or restarted. |
| Final new-message workload | Two ordinary/English and two Korean messages delivered, preserved bodies and passed EWS subject/body queries. |
| Negative controls | Four nonexistent-term queries returned no test item. |
| Final diagnostic window | 275 CTS lines; no matched feeder/Korean-init/timeout failures or relevant application warnings/errors. |
| Final health | Empty transport queues, Mounted/Healthy database copies with zero copy/replay queues, monitored services running. |

These final observations followed investigation of earlier failed windows.
A restart or a green service/process state did not, by itself, establish recovery.

## Historical interface and offline coverage

The pre-2.0.0 source suites used fixtures/mocks and native Windows PowerShell 5.1
children. This summary retains the coverage boundaries without substituting an
old suite count for current-release validation.

| Historical area | What was exercised; what it did not prove |
|---|---|
| Native invocation and exits | Path defaults, deployment-agent exit forwarding, exact custom exits; not production compliance. |
| UAC boundary | Launch selection, 32/64-bit host selection, cancellation/no-loop guards and preserved arguments/preferences. Consent was mocked, not approved by tests. |
| Data handoff | Native harmless child processes, private data-only report handoff, ACL/exit validation and cleanup; no Exchange Apply. |
| Human output | Status vs Before/Current columns, actions, receipts and contextual colors; green presence was not recovery. |
| Target parsing | Whole-roster validation, metadata/quoting, ordered large lists, duplicates and DNS rules; parser scale was not a live fleet deployment. |
| Remote orchestration | File-only/restarted behavior, fail-stop, `NotRun`, duplicate-machine aliases and required recovery attestation in fixtures. |
| Reporting | Typed rows, stale-data clearing, CSV protection/round trips, detailed JSON, finalized JSONL, NoCsv and preview/export failures. |
| Builder compatibility | Simulated Exchange hosts, retained elevation/identity/signature checks, extract-only/fresh-output behavior; no live SQL extraction on Exchange. |
| Native Exchange CSV | `ComputerName` > `Fqdn` > `Name`, optional `#TYPE`, no row fallback and no `PSComputerName` selection. |
| Confirmation | Default High preference, explicit Confirm/Confirm false, inherited stricter policy and file-free previews; operation-specific gates were retained. |

Historical package/manifest checks verified the artifacts of those releases.
They are not verification of the differently named 2.0.0 archives. The current
worktree and earlier 2.0.0 source archive have separately scoped results above;
neither inherits historical test totals or earlier archive hashes. Final archive
status is tracked separately. Current source retains the tests and legacy
compatibility wrappers.

## Later read-only lab observations

Actual CSV Detect observed three explicit targets over Kerberos/WinRM in human
and JSON modes. Two already had rule files; an older build was ineligible. Exit
20 and the ordered observations were expected review results, not failed Apply.
Independent before/after fingerprints showed unchanged Exchange file identities,
directory ACLs, service states/PIDs and NodeRunner identities.

Read-only reporting checks subsequently exercised local output, a remote target,
a two-target CSV with JSON, NoCsv and preview in the same PowerShell session.
Typed rows and report paths were retained. CSV rows matched the objects, detailed
JSON parsed, and finalized UTF-8 JSONL had one complete object per row. NoCsv
omitted only CSV; preview exported no files. Caller/target fingerprints stayed
unchanged. These were inventory/reporting checks, not new Apply or restart tests.

A historical display update refreshed a stable manual-run package in place,
preserving extra files and a protected backup of previous managed contents.
Detect then returned `RuleFilesPresentStop` with exit 20. This does not claim that
the same folder was moved or updated for 2.0.0.

The later builder/CSV and confirmation changes did not include a new live Apply,
restart, recovery attestation or customer rollout.

## Why the first workload observation was insufficient

The initial ordinary message passed before Apply. After the ContentEngine
restart, new ordinary mail delivered but did not appear in the tested subject/body
query during two separate five-minute windows. Those remain genuine failures.
Healthy monitors or a running process did not justify declaring recovery.

Investigation found long-running callers retaining failed FAST/CTS feeder objects.
Logs distinguished an old feeder reporting blocked delivery, its shutdown, and a
new feeder opening a session. Several callers recovered without a service restart.
New-message searches began passing while a residual feeder warning still occurred,
so investigation continued rather than treating one positive query as completion.

## Attribute failure to the actual caller

In the lab, `MSExchangeFastSearch` event 1006 originated from multiple processes:
EWS, Mailbox Transport Delivery and EdgeTransport. **The event provider name is
not the originating service.** Correlate:

1. Event XML `System/Execution/@ProcessID`.
2. The matching live executable, parent and service identity.
3. CTS feeder/session identifiers and timestamps.
4. The workload's own health, maintenance and recovery requirements.

The last residual warning was attributed to a preexisting EdgeTransport worker.
A separately approved, graceful `MSExchangeTransport` restart on the pilot
followed checks of empty queues, healthy database copies, exact caller identity
and no running dependent services. Waits were bounded; no process was force-killed.
The new worker was stable; other monitored service/NodeRunner identities were
unchanged.

This was **evidence-led lab recovery**, not an automatic action added to Exchange
Korean Rules and not a blanket recommendation to restart Transport or Search.
The tool's automatic approved restart scope remains `HostControllerService`.

## What the final workload did and did not establish

After targeted caller recovery, all four new-message tests and four negative
controls passed. The diagnostic window stayed clear through the final snapshot,
roughly eight minutes after that validation run began.
The test mailbox reported four indexed items; its aggregate not-indexed counter
did not drain during the two-minute sample.

Not established:

- Complete historical-backlog recovery or sustained production-load behavior.
- Every Korean initialization/deadlock trigger or the customer's impact boundary.
- OWA/Outlook UI or connectivity recovery; the automated checks used **EWS**.
- Live rollback, which was not attempted without actual Support approval.
- A large modifying fleet rollout or 2.0.0 live deployment.
- A customer's Splunk connection, ingestion, parsing or alerting.

Temporary recipients, scheduled tasks and pilot staging were removed after that
historical test; normal disconnected-mailbox retention applied. The original
Apply receipt and installed workaround files were retained, not removed merely
to force another Apply. This is not an instruction to clean up current state.

## Historical media and external integration limits

The [1.2.1 walkthrough](Exchange-KB5130098-1.2.1-Walkthrough.mp4) is historical
illustrative material with synthetic narration, captions and recorded-result
summaries. It is not a recording of a fresh deployment or a 2.0.0 demonstration.
It shows old names and detailed output, not the three-command interface or 4+
compact behavior. Former workstation-only, ComputerName-only and default-prompt
instructions are also superseded. Use the [current written guide](../README.md)
and [reporting contract](Reporting-and-Splunk.md). No video was regenerated.
The [1.0.1 recording](Exchange-KB5130098-1.0.1-Walkthrough.mp4) remains historical too.

Historical media decoding, caption/transcript and illustrative-command checks
were documentation checks, not additional Exchange or Splunk validation.
The [Splunk examples](Reporting-and-Splunk.md) were reviewed against published
configuration specifications, not tested end-to-end against a customer instance.
Its administrator must validate timestamps, extraction, duplicates and index policy.

## Public distribution and operational boundaries

The public repository contains source, offline tests, instructions and finished
historical media, not Microsoft rule binaries, SQL media or payload-bearing ZIPs.
Obtain verified payload using `Install-KoreanRules.ps1` and the
[Microsoft source guidance](https://support.microsoft.com/en-us/servicing/exchange/server/update/2026/5130098).
Review licensing before distributing a generated deployment package.

Keep exact applicability, no-overwrite creation, protected incremental receipts,
inherited-read checks, operation serialization, bounded restart observation and
serial workload gates. A smaller copy/restart script or a healthy service snapshot
does not replace them. The legacy fleet wrapper's Apply still implies restart;
current Set requires explicit `-RestartSearch`. Rollback remains local, owned,
completed-receipt-bound and Support-approved, never routine cleanup.
