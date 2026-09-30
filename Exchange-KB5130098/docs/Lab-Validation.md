# Exchange Korean Rules: validation and operational limits

## Repository archive cleanup

Superseded material is indexed in the [archive](../archive/README.md).
The cleanup moved **22 historical download/checksum files** and **11 older media
files** without changing any of their SHA256 identities. Four forwarding
compatibility entry points moved to `archive\compatibility`; their relative-root
resolution was updated so they remain usable from that location.

The active root now has exactly the three recommended operator scripts, active
downloads contains only the latest 2.1.0 ZIP and sidecar, and active docs retains
the latest available 2.0.0 video and current written guidance.
The **326-test repository suite passed**, including native compatibility
execution, current runtime packaging and five layout/checksum regressions.
Local Markdown links were checked after the moves.

This is repository housekeeping, not a new code/payload release or lab deployment.
Published ZIPs were not rebuilt; the 2.1.0 source ZIP keeps its existing internal
layout and checksum. No files were removed from an operator or lab working folder.

- **Original workload pilot:** September 25, 2026.
- **Historical console/reporting verification:** through September 28, 2026.
- **Historical builder/CSV/confirmation verification:** September 29, 2026.
- **2.0.0 offline worktree validation:** September 29, 2026.
- **2.0.0 source-archive verification/runtime smoke check:** September 29, 2026.
- **2.0.0 lab working-folder staging/read-only check:** September 29, 2026.
- **2.0.0 walkthrough/narration validation:** September 29, 2026.
- **2.1.0 final offline worktree validation:** September 30, 2026; **321 of 321 tests passed**.
- **2.1.0 independent source-archive validation:** September 30, 2026; **321 of 321 tests passed**.
- **2.1.0 stable-folder/native lab verification:** September 30, 2026; **7 cases passed**.
- **Current operator interface:** 2.1.0; see the [written guide](../README.md).

This separates release-specific offline worktree and independent source-archive results,
no-contact runtime checks and sanitized historical evidence.
The 2.1.0 live checks include packaging already-verified rules and read-only
inspection, not SQL download/extraction, Exchange Apply, service restart or
customer rollout. Updating a stable working folder and checking inputs/state,
described below, is not remediation.
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

## 2.1.0 input contract and evidence boundary

This release documents installer/input and routine-skip guidance changes, not
a new Exchange remediation or workload-recovery result:

- Install without arguments prints usage/examples and exits `0` with no prompt,
  download, elevation or file writes. Preparation still needs elevation.
- Position 0 is an existing EXE/source folder (`SqlPackagePath`, alias `Path`);
  position 1 is an optional **new** output directory, defaulting to a unique
  child of `C:\Temp\KoreanRules-Ready`. The compatibility builder shares this
  contract and propagates the installer exit.
- Folder selection is nonrecursive. An expected EXE plus either rule BIN is
  ambiguous; select the exact EXE or `-RuleSourceDirectory`. A partial rules
  folder reports the missing filename. Paired pasted quotes are stripped;
  paths remain literal, without command evaluation.
- Download remains explicit. Invalid existing inputs are rejected before
  work/output creation or execution. Bytes, version, SHA256 and Microsoft
  signature remain required; partial downloads are not renamed to the canonical
  EXE until identity and signature pass. Failures retain available diagnostics,
  report once and exit `1` by default; `-ErrorAction Stop` is catchable.
- Get/Set and legacy Invoke accept position-0 `ComputerName`; CSV still needs
  `-CsvPath`. Other paths and switches remain named.
- Expected skips retain `ApplicabilityReason`, including found/required values,
  and the yellow continue-to-next-target behavior from 2.0.1. Leave unchanged
  and review actual build, prior receipt or partial pair instead of escalating
  routinely. Partial modifying failures, abandoned operations, unstable
  service/ContentEngine and exceptional rollback still warrant Support.

A smaller-than-required EXE with an invalid signature is consistent with
incomplete or corrupt media, not proof that a download was interrupted or of
the underlying cause. Obtain a fresh complete Microsoft copy, not relaxed
verification. This is input guidance, not a live extraction result.

The final 2.1.0 worktree suite passed **321 of 321 tests** on September 30, 2026.
The independent archive and limited native lab results are scoped separately
below. Historical results belong to their named releases, not automatically to
2.1.0. Public distribution remains source-only, without vendor binaries. The
retained 2.0.0 media predates these installer/input and skip-guidance changes;
use the current written guide rather than treating the recording as current
validation.

## 2.1.0 independent archive and native lab verification

On September 30, 2026, the final
[`Exchange-KoreanRules-2.1.0-source.zip`](../downloads/Exchange-KoreanRules-2.1.0-source.zip)
independently passed **321 of 321 tests**. All **22 manifest-covered files**
were verified across **23 archive entries**. The source archive contains
**no vendor binaries**.

Archive SHA256:
`57BD79F7B609BFCBB5CF12E224D0B24DFA8FC41454D2F5AE09CB51CB1F6F24D9`

The lab tool was updated to 2.1.0 in its existing stable working folder. Native
PowerShell verification then passed these **seven cases**:

1. Bare Install displayed help without prompting.
2. An empty source folder produced one concise corrective diagnostic.
3. A real **9,018,790-byte** EXE supplied with embedded pasted quotes resolved
   as a path and was rejected by identity verification.
4. A real **584,994,603-byte** EXE selected through its containing folder was
   rejected by identity verification.
5. A positional verified-BIN source plus a new positional output directory
   actually built the runtime package; the generated deployment ZIP hash was
   verified.
6. Local Get inspected the existing-rule state without routine Support
   boilerplate.
7. Positional remote Get with `-WhatIf` planned the target without contacting it.

The two rejected EXEs were below the required **748,772,024 bytes** and had
invalid signatures. Those observations are consistent with incomplete or
corrupt media, not proof of an interrupted download or its underlying cause.
The original files were preserved; verification requirements were not relaxed.

No SQL download or extraction, Set Apply, or service restart was performed.
Installed Exchange hashes/ACLs, services and NodeRunner identities remained
unchanged. The test-owned build directory was cleaned up. These checks establish
input handling, packaging from already-verified rules and bounded inspection;
they do not establish new workload recovery, a modifying rollout or live SQL
extraction.

## 2.0.1 expected skips, identity explanations and missing media

Saved lab reports established why a later target was unvisited: an Apply roster
hit an existing-rule target first, converted its `RuleFilesPresentStop` detection
to `FailedStop`, and left the following older-build server `NotRun`. A separate
Detect had already reached that server successfully. This was a fail-fast
classification problem, not evidence of a connection failure.

The corrected full suite passed **292 tests** from both the worktree and the
source archive. Tests cover names/CSV, skip-only and mixed lists, the recheck
race, explicit restart intent without restart/attestation on a skip, true-failure
halting, compact yellow skip output, detailed identity mismatches, and separate
missing BIN-payload versus missing SQL-media guidance. All 21 archive manifest
files were verified; no vendor binaries are included in the source ZIP.

The stable lab kit was updated in place with hash checks, protected backup and
preservation of existing payload, reports and receipts. Live three-target CSV
Detect observed two existing-rule installations and one incompatible build/DLL.
The shared Set orchestrator was then exercised against the original two-target
sequence: existing rules first, incompatible identity second. Both were contacted,
recorded as skipped, and exported with exit20/ReviewRequired instead of failure
or NotRun. Real host color metadata showed yellow skip/reason text, with no red
expected-state messages.

This Set-path test had an additional test-only guard that would refuse any remote
Apply invocation if a target unexpectedly became eligible. It was not triggered:
neither target reached Apply, restart, or recovery attestation. Before/after
installed Exchange hashes/ACLs, monitored service/PIDs and NodeRunner identities
were unchanged across all three servers. The test-owned scheduled task and
remote code staging were removed; operational reports were retained.

This is skip/inventory validation, not a new modifying deployment or workload
recovery certification. The 2.0.0 video predates this patch; the current written
guide documents the corrected yellow eligibility and continued-inspection behavior.

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

No new live Exchange operation accompanied that code verification. These
offline/native checks do not establish production recovery, a large live rollout,
or additional workload evidence beyond the historical pilot below.

## 2.0.0 archive and generated-runtime checks

After the incomplete-package guards were added,
[`Exchange-KoreanRules-2.0.0-source.zip`](../archive/downloads/Exchange-KoreanRules-2.0.0-source.zip)
independently passed **281 of 281 tests** when tested from the final archive.
All **21 manifest-covered files** were hash-verified, and the source archive
contains **no vendor binaries**. No payload-bearing deployment archive is
distributed publicly.

The actual generated runtime's `Get-KoreanRulesState.ps1` was
also smoke-tested in **no-contact `-WhatIf` mode**. That check exercised the
generated entry point, not live target inventory or an Exchange modifying
operation.

No live Exchange build, Apply or service restart was performed for those code checks.
Archive tests and a no-contact preview
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

Historical package/manifest checks verified the artifacts of those releases,
not a later release's archives. The 2.0.0 and 2.0.1 worktree/source-archive results
above are separately scoped; 2.1.0 inherits neither those test totals nor archive
hashes. Final archive status is tracked separately. Current source retains the tests and legacy
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

## Current 2.0.0 walkthrough validation

The [current video](Exchange-KoreanRules-2.0.0-Walkthrough.mp4) was rebuilt for
the three-command interface with new offline natural-sounding synthetic
narration, rather than relabeling the 1.2.1 recording. It lasts **8 minutes
57 seconds**, at **1920 x 1080 / 24 fps**, with **16 chapters** and **81 caption
cues**. A separate [audio track](Exchange-KoreanRules-2.0.0-Narration.m4a),
transcript, SRT/WebVTT captions and poster accompany it.

Full video and audio decoding completed without errors. Caption text matches
every narration-source sentence, cues stay within the timeline without overlap,
and the guide's chapter times match the media. The audio-only track is identical
to the video's narration stream. Integrated loudness measured **-16.54 LUFS**
and true peak **-4.23 dBTP**. Encoded screens were visually inspected, and local
speech recognition checked the key preparation, output, confirmation, restart
and recovery statements.

Documentation checks resolved **45 local links**, parsed **31 PowerShell
blocks/commands**, including **17 video examples**, and checked current parameter
names. Modifying examples were not executed. The actual four-target remote
WhatIf display was checked without contacting servers or creating reports.

These are media/documentation checks, not a new Exchange remediation or
workload pilot. The existing **281-test** code-release evidence remains
separately scoped above. No source ZIP, Microsoft payload or script behavior
was changed as part of this video refresh.

## Historical media and external integration limits

The [1.2.1 walkthrough](../archive/media/1.2.1/Exchange-KB5130098-1.2.1-Walkthrough.mp4) is historical
illustrative material with synthetic narration, captions and recorded-result
summaries. It is not a recording of a fresh deployment or a 2.0.0 demonstration.
It shows old names and detailed output, not the three-command interface or 4+
compact behavior. Former workstation-only, ComputerName-only and default-prompt
instructions are also superseded. Use the [current written guide](../README.md)
and [reporting contract](Reporting-and-Splunk.md). A separate current
[2.0.0 walkthrough](Exchange-KoreanRules-2.0.0-Walkthrough.mp4) now covers the
three-command interface and its operating boundaries.
The [1.0.1 recording](../archive/media/1.0.1/Exchange-KB5130098-1.0.1-Walkthrough.mp4) remains historical too.

Historical media decoding, caption/transcript and illustrative-command checks
were documentation checks, not additional Exchange or Splunk validation.
The [Splunk examples](Reporting-and-Splunk.md) were reviewed against published
configuration specifications, not tested end-to-end against a customer instance.
Its administrator must validate timestamps, extraction, duplicates and index policy.

## Public distribution and operational boundaries

The public repository contains source, offline tests, instructions and finished
current/historical media, not Microsoft rule binaries, SQL media or payload-bearing ZIPs.
Obtain verified payload using `Install-KoreanRules.ps1` and the
[Microsoft source guidance](https://support.microsoft.com/en-us/servicing/exchange/server/update/2026/5130098).
Review licensing before distributing a generated deployment package.

Keep exact applicability, no-overwrite creation, protected incremental receipts,
inherited-read checks, operation serialization, bounded restart observation and
serial workload gates. A smaller copy/restart script or a healthy service snapshot
does not replace them. The legacy fleet wrapper's Apply still implies restart;
current Set requires explicit `-RestartSearch`. Rollback remains local, owned,
completed-receipt-bound and Support-approved, never routine cleanup.
