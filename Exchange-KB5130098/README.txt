Exchange Korean Rules | 2.0.0
Operator quick reference

PURPOSE AND SUPPORT BOUNDARY

This is custom PowerShell automation, not a Microsoft-signed hotfix, security
update or permanent product fix. Source guidance:
https://support.microsoft.com/en-us/servicing/exchange/server/update/2026/5130098
Re-read that article, review signing/change control and pilot one affected
server. The article number is not the tool identity. The tool does not install
or uninstall an Exchange SU, replace korwbrkr.dll or diagnose a deadlock.

Current full guide: README.md
Reports/Splunk: docs\Reporting-and-Splunk.md
Historical evidence and limits: docs\Lab-Validation.md

THREE RECOMMENDED COMMANDS

Install-KoreanRules.ps1    Prepare verified payload and a deployable runtime.
                          NOT SQL installation; NOT applying rules to Exchange.
Get-KoreanRulesState.ps1   Detect only: local, -ComputerName, or -CsvPath.
Set-KoreanRulesState.ps1   Apply by default; -Rollback is receipt-bound/local.

Safe order: prepare, verify, Get, Set -WhatIf, approved pilot, actual workload
checks, then the next server. Get does not require payload files. Set never
infers restart: select -RestartSearch and assert -MaintenanceWindowApproved.

PREREQUISITES AND EXACT IDENTITY

Use 64-bit Windows PowerShell 5.1. The installer requires elevation. Local
interactive state commands can request normal UAC and preserve switches,
WhatIf and confirmation preferences. Their private data-only handoff returns
exit/report data to the invoking session and is removed afterward.
Declined elevation is an error. For local JSON, pipelines, remoting and
unattended operation, start elevated. Set's -NoAutoElevate disables relaunch;
it does not bypass administrator checks. No execution-policy bypass is used.
Keep administrative code readable by its initial caller but not world-writable.

Remote operations require existing administrative Kerberos/WinRM access to a
64-bit Microsoft.PowerShell endpoint, not the constrained Exchange shell.
They do not change credentials, enable remoting or alter TrustedHosts.
Review Exchange/DAG health, maintenance and workload scope separately.
Use approved C: build/staging/report locations; writes through reparse points
or junctions and writes to F: are refused. Detect may observe an installation
that this tool cannot modify.

Apply requires all of:
  Exchange version: 15.2.2562.49 (published as 15.02.2562.049)
  korwbrkr.dll: version 16.0.5194.1000, 326544 bytes
  DLL SHA256:
    1C6BD8E144BA677EBCC83323AE59DB3881918170F9B3A5189B44611558B92C61
  Neither rule already present in the destination.

The destination is registry-discovered:
  <ExchangeInstallPath>\Bin\Search\Ceres\Native

Use the authoritative DLL hash in KoreanRules.psd1 and the full guide when
checking identity. Never loosen build/hash checks to accept a future update.
Either existing rule blocks Apply, even a partial pair; no overwrite or
repair-by-reapply is supported. Eligibility alone does not establish symptoms.

1. PREPARE THE VERIFIED PAYLOAD

From the source folder, choose ONE input in elevated Windows PowerShell.
Download requires explicit -Download (approximately 749 MB of Microsoft media):

  $build = .\Install-KoreanRules.ps1 -Download

Instead, use existing exact Microsoft media:

  $build = .\Install-KoreanRules.ps1 -SqlPackagePath 'C:\Temp\SQLEXPR_x64_ENU.exe'

Or use both already-extracted rule files:

  $build = .\Install-KoreanRules.ps1 -RuleSourceDirectory 'C:\Temp\VerifiedKoreanRules'

OutputDirectory is optional. Its default is a UNIQUE child of
C:\Temp\KoreanRules-Ready. An explicit directory must be new; existing output
is not overwritten. WorkRoot defaults to C:\Temp\KoreanRules-Build, with a
unique extraction subfolder. Allow several GB of space.

A management workstation is recommended. An Exchange host is allowed with
a disk/CPU warning, not an additional approval switch. That allowance does
not change Microsoft's workstation recommendation.
Media version, size, SHA256 and Microsoft Authenticode signature are checked
before extraction. The installer extracts without installing SQL and verifies
the exact two rule files. It neither copies them into Exchange nor restarts
services. Failed extraction preserves diagnostics for review.

  $build | Select-Object Package, SHA256, ExpandedPackage, PayloadDirectory, ExtractionArtifacts

Package is the generated ZIP; SHA256 is its hash; ExpandedPackage is the
generated runtime folder; PayloadDirectory contains verified rules;
ExtractionArtifacts identifies retained extraction artifacts.

IMPORTANT: the original source folder is NOT populated with payload.
Use the generated runtime or explicitly pass the returned directory:

  .\Set-KoreanRulesState.ps1 -PayloadDirectory $build.PayloadDirectory -WhatIf

Alternatively:

  Set-Location -LiteralPath $build.ExpandedPackage
  .\Get-KoreanRulesState.ps1

Missing-payload errors name the expected directory and both files:
  <entrypoint-folder>\payload\ko.token.rule.bin
  <entrypoint-folder>\payload\ko.complex.rule.bin

Run Install with -Download or existing inputs, then select its PayloadDirectory;
or use -PayloadDirectory for an existing verified pair on the caller.
Detection needs no payload. Remote Apply validates caller-side payload before
connecting, rather than assuming a source checkout contains the vendor files.

Required payload:
  ko.token.rule.bin, 56132 bytes
    8F2BD853593913EB8F73DCD4FCAC4216F216A0FF76A4569DF071BE3C36773010
  ko.complex.rule.bin, 717792 bytes
    0390D1E9A76EF33283025CF8F164430E311584B9535949C4EA1A74B6BB107B87

2. VERIFY AND STAGE

Local build: Exchange-KoreanRules-2.0.0-deploy.zip
Archive root: Exchange-KoreanRules
Exactly three root .ps1 entry points: Install-KoreanRules.ps1,
Get-KoreanRulesState.ps1 and Set-KoreanRulesState.ps1.
It also contains KoreanRules.psm1, KoreanRules.psd1,
private\Invoke-KoreanRulesOperation.ps1, docs, examples and payload.
The private script is not a fourth operator command.

Extract/copy the WHOLE code package, not just a .ps1 wrapper. Get, Set and
the legacy Invoke-KB5130098.ps1 wrapper require the private folder and shared
module. Missing components cause an explicit "package is incomplete" failure;
restore the complete package, including private and the module, before retrying.
Get needs no vendor payload but still requires the complete code package.

Public source: downloads\Exchange-KoreanRules-2.0.0-source.zip
Source also includes tests and legacy compatibility wrappers. No vendor rules,
SQL media or payload-bearing deployment ZIP is published in this repository.
Review licensing before redistribution of your generated runtime.

Verify the ZIP hash and sidecar against the approved build record before
extracting to a NEW directory; README.md has the complete checksum example.
A checksum is not signing or authentication of an untrusted download. Sign
scripts/module before building when policy requires; rebuilding changes hashes.

Retain an established stable folder, such as C:\Scripts\Exchange-KB5130098.
Update reviewed contents only while no run is active; preserve user edits and
reports. The new archive name does not move stable lab/operator directories,
the repository directory Exchange-KB5130098, existing reports or receipts.

3. DETECT FIRST

These are alternative inventory examples:

  .\Get-KoreanRulesState.ps1
  .\Get-KoreanRulesState.ps1 -ComputerName EX01.contoso.com,EX02.contoso.com
  .\Get-KoreanRulesState.ps1 -CsvPath 'C:\Temp\servers.csv'

Get exposes no Mode selector and cannot Apply or Rollback. Remote Detect
stages code and writes caller-side reports, but changes no Exchange rules or
services. Remote WhatIf only validates roster/plan; it does not connect,
stage code or inventory remote state.

CSV accepts ComputerName, Fqdn or Name, in that order of precedence, selected
once per file. An invalid/blank selected value never falls back to another
column. Get-ExchangeServer exports need no calculated ComputerName property.
The full roster is validated before any connection/report: malformed rows,
duplicates, IPs, URLs, wildcards and invalid host labels stop the run.
Quoted/multiline metadata and leading #TYPE export metadata are supported.
CSV order is retained; PSComputerName is never a target selector. Enabled,
approval/action and other columns do not filter targets or authorize changes.
ComputerName and CsvPath are mutually exclusive. Review every target first.

EligibleMissingBothRules means eligible/missing, NOT installed or recovered.
NotApplicableStop means identity mismatch. RuleFilesPresentStop means one or
both rules already exist; do not overwrite or reapply.
Human colors are contextual: match green, mismatch red; Missing green only
with matching identity, yellow for mismatch, neutral if unobserved. Present
is green for presence only, not a recovery sign-off.

4. PREVIEW AND APPLY

From the verified runtime, or add your caller-side -PayloadDirectory:

  .\Set-KoreanRulesState.ps1 -WhatIf

Only after real pilot/maintenance approval:

  .\Set-KoreanRulesState.ps1 -RestartSearch -MaintenanceWindowApproved

Set defaults to Apply. Without RestartSearch it only stages the rules,
returns 10 and requires a separately controlled manual restart/recovery.
MaintenanceWindowApproved alone does not request restart.
WhatIf is file-free: no Exchange writes, operation receipts or report exports;
remote previews also avoid connections/staging. Local preflight can still
fail on an ineligible or already-staged installation.

Standard confirmation remains opt-in as in 1.2.3. At ConfirmPreference High
no Confirm false is required. Use -Confirm to request a prompt; inherited
stricter preferences remain effective. Confirm false does not remove UAC,
restart selection, maintenance approval, rollback approval or recovery gates.
Report persistence adds no separate confirmation prompt.

Apply rechecks identity, uses no-overwrite creation, verifies destination
hashes/sizes and inherited read access, and writes incremental protected
receipts. It does not loosen directory ACLs or override custom permissions.
RestartSearch gracefully restarts ONLY HostControllerService and observes
the exact ContentEngine process/PID for a default 30-second stability window.
Dependencies, timeouts, permission failures or instability stop the run.
No force-kill, automatic rollback or blanket caller restart is performed.

5. REPORTS AND HUMAN OUTPUT

1-3 targets retain detailed state/action/next-step blocks for each server.
Only Apply and its previews show Before/Current; Detect/rollback show Status.
4+ targets automatically omit these blocks, per-target progress and roster
dumps. The final human summary contains aggregated Status + Count and report
paths, NOT a table enumerating every server.
ERRORS NAME THE FAILED TARGET. REQUIRED RECOVERY PROMPTS STILL APPEAR PER SERVER.
Neither is suppressed by compact mode.
This threshold changes display only, not $report, CSV, JSON/JSONL, or explicit
AsJson/PassThru streams; all target data remains available.

Inspect the full per-target rows explicitly when needed:

  $report
  $report | Format-Table ComputerName, Mode, Status, TokenRule, ComplexRule
  $reportFiles

Use $report | Format-List * to inspect every retained field. Compact mode
does not automatically dump the per-target rows; these commands request them.

For explicit pipeline capture:
  $report = .\Get-KoreanRulesState.ps1 -CsvPath 'C:\Temp\servers.csv' -PassThru

Both state commands support AsJson, PassThru, NoCsv and ReportDirectory.
AsJson text and PassThru typed objects are alternatives, not a combination.
Direct invocation retains report variables in the current shell; an external
process cannot set them in its parent. Each invocation refreshes the variables.

Default: C:\Temp\KB5130098-Reports\<unique-run-id> ON THE CALLER
  rollout.json   Detailed checkpoint, rewritten during remote progress
  results.csv    Final flat rows; CSV formula-text protection is applied
  results.jsonl  Final UTF-8 one-object-per-line events

ReportDirectory overrides the root; NoCsv omits only CSV. Invalid paths and
export failures are explicit errors, not silent fallback or discarded data.
WhatIf creates no exports. Use final JSONL, not checkpoint rewrites, for
Splunk. Do not ingest both CSV and JSONL as duplicate events. See the reporting
guide for customer-admin configuration; no live Splunk ingestion is claimed.

Operation evidence is separate and unchanged:
  %ProgramData%\Exchange-KB5130098\<operation-id>\receipt.json
  %ProgramData%\Exchange-KB5130098\<operation-id>\events.jsonl
Only Administrators and SYSTEM have access. Retain the actual returned paths.
Remote code staging retains its existing Exchange-KB5130098-Staging path.
Partial failures do not trigger cleanup or automatic rollback. Preserve
diagnostics; a partial copy or stopped service needs reviewed manual recovery.

6. WORKLOAD RECOVERY AND SERIAL EXPANSION

RestartedWorkloadValidationRequired is NOT proof of recovery.
Use a test mailbox whose active database is on the changed server. Check
ordinary/Korean delivery, preserved bodies, server-side subject/body search,
nonexistent-term negative controls, OWA and the actual Outlook/delivery
symptoms. Review new CTS/FAST/Korean errors, queues and database health.
Observe new-message indexing and historical backlog separately.

If recovery fails, stop rollout, preserve evidence and do NOT reapply.
Correlate the event's process ID with caller/service and CTS feeder/session
identities. MSExchangeFastSearch event 1006 does not identify the originating
service by its provider name alone. Any targeted caller recovery requires
separate approval/runbook; the tool does not restart Transport for you.

After a successful pilot, in a local interactive console:

  .\Set-KoreanRulesState.ps1 -CsvPath 'C:\Temp\approved-servers.csv' -RestartSearch -MaintenanceWindowApproved

The serial rollout waits after each restarted target for actual recovery
checks and the exact response RECOVERED <exact-target-name>. Any other
response stops it. This gate is retained for 4+ targets and is not waived
by compact output or Confirm false.
Restarted remote Apply refuses AsJson, noninteractive/remoting hosts or
unavailable input before contacting targets. JSON WhatIf is allowed.
Errors stop later targets; they remain NotRun in reports. Duplicate-machine
aliases are refused before a second Apply. File-only staging does not attest
recovery. Do not run Apply again on already-staged machines; verify receipt,
hashes and permissions, then follow the approved manual restart/recovery.

EXIT CODES AND UNATTENDED CALLERS

  0  Eligible detection, preview/no change or requested operation complete.
     Inspect status; this is not compliance or a recovery sign-off.
  1  Error/verification failure; stop and preserve diagnostics.
  10 Files staged/removed; Search restart required, NOT a Windows reboot.
  20 Not applicable or rules already present; review before further action.

Remote Detect 20 means at least one target needs review. Do not use Detect
exit 0 as an installed-state rule or configure automatic Apply retry.
An approved elevated deployment agent may stage without restart. Literal
cmd.exe/agent command (explicitly preserves custom exit codes):

  powershell.exe -NoProfile -NonInteractive -Command "& '.\Set-KoreanRulesState.ps1' -AsJson -NoAutoElevate; exit $LASTEXITCODE"

From PowerShell, invoke the script directly and read $LASTEXITCODE. An outer
PowerShell double-quoted string can expand variables in the cmd example.

ROLLBACK: EXCEPTIONAL, LOCAL AND SUPPORT-APPROVED

The source article does not prescribe rollback; removal can reintroduce the
problem. Require actual Microsoft Support approval, a maintenance window and
the original completed Apply receipt for the same computer/install/build.
Changed files/builds and partial/failed deployments are refused.

  .\Set-KoreanRulesState.ps1 -Rollback -ReceiptPath 'C:\ProgramData\Exchange-KB5130098\<operation-id>\receipt.json' -MicrosoftSupportApprovedRollback -MaintenanceWindowApproved -RestartSearch

Use the real completed receipt, not the placeholder. Only the exact two owned,
unchanged files are backed up and removed. No arbitrary file deletion, remote
rollback, DLL replacement or SU uninstall occurs. Retain evidence and repeat
workload checks. Follow later Microsoft guidance for changed future builds.

COMPATIBILITY AND HISTORICAL MATERIAL

Source retains Invoke-KB5130098.ps1, Invoke-KB5130098Fleet.ps1 and
Build-KB5130098Package.ps1 as compatibility wrappers. Old fleet Apply STILL
IMPLIES RESTART and retains maintenance/recovery gates. Prefer the new three
commands. Internal KB function/error keys and the mutex remain compatible.

The 1.2.1 media is HISTORICAL, not current instructions:
  docs\Exchange-KB5130098-1.2.1-Walkthrough.mp4
  docs\Exchange-KB5130098-1.2.1-Narration.m4a
  docs\Exchange-KB5130098-1.2.1-Transcript.txt
  docs\Exchange-KB5130098-1.2.1-Captions.vtt
  docs\Exchange-KB5130098-1.2.1-Captions.srt
It shows old names/detailed output, not the new commands or 4+ compact behavior.
Use README.md and docs\Reporting-and-Splunk.md instead. Earlier workstation,
CSV-column and default-confirmation instructions are superseded too.
Historical 1.0.1 media and 1.0.1/1.2.3 source downloads remain linked in README.md.

For the bounded 2.0.0 worktree test result, read docs\Lab-Validation.md. That
result does not imply an independent source-archive pass or new lab rollout.
The historical pilot proved tested EWS new-message results, not OWA/Outlook
recovery, full backlog, sustained production load or live rollback.
