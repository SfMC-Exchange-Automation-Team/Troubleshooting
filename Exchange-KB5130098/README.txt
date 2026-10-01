Exchange Korean Rules | 2.3.1

Console identity differences show only mismatched Exchange build and
Korean DLL version, one per line, without byte counts or hashes. Size/hash
checks remain mandatory; detailed identity differences remain in reports.

2.3.1: The public repository and Exchange-KoreanRules-2.3.1.zip include both
exact, pinned Microsoft BINs under payload. The user explicitly approved
including both files publicly. The ZIP contains the complete runtime, docs,
tests and archived compatibility wrappers; no SQL EXE, MSI or DLL is included.
No SQL media preparation or Install run is needed. Get needs no payload; Set
automatically uses adjacent payload and still checks for itself.
Optional bare Install verifies the bundled files read-only, with no download,
admin requirement, writes, directories or prompts. Only explicit OutputDirectory
requests a separate portable expanded kit and ZIP; it must name a NEW directory.
There are no implicit downloads.

CURRENT VIDEOS: 2.3.1 walkthroughs are available in English, Hindi and Tamil.
They cover the bundled payload, optional Install, adjacent-only preparation,
explicit portable export, remote two-file transfer and scoped Internet-zone
handling. MaintenanceWindowApproved is an optional compatibility no-op.
RestartSearch remains explicit; operational planning, Support-approved rollback
and recovery checks remain.

2.0.1: Existing rules and incompatible identities are yellow skips, not fatal
Apply errors. Fleet Set records them and continues to inspect the remaining
targets without overwriting or restarting a skipped target. Genuine failures
and failed recovery attestations still stop the modifying rollout.
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

Install-KoreanRules.ps1    Verify/prepare adjacent payload; portable output only
                          when explicitly requested with OutputDirectory.
                          NOT SQL installation; NOT applying rules to Exchange.
Get-KoreanRulesState.ps1   Detect only: local, -ComputerName, or -CsvPath.
Set-KoreanRulesState.ps1   Apply by default; -Rollback is receipt-bound/local.

Safe order: verify trusted kit, prepare only if needed, Get, Set -WhatIf,
approved pilot, actual workload checks, then the next server.
Get does not require payload files. Set never infers restart: select
-RestartSearch. Plan an operational window and obtain actual change approval.
-MaintenanceWindowApproved is an optional compatibility no-op, not approval.

PREREQUISITES AND EXACT IDENTITY

Use 64-bit Windows PowerShell 5.1. Use an elevated session for media/file-writing
preparation; bare Install's bundled verification or historical/custom
source-only help needs no administrator rights and creates no directories. Local
interactive state commands can request normal UAC and preserve switches,
WhatIf and confirmation preferences. Their private data-only handoff returns
exit/report data to the invoking session and is removed afterward.
Declined elevation is an error. For local JSON, pipelines, remoting and
unattended operation, start elevated. Set's -NoAutoElevate disables relaunch;
it does not bypass administrator checks. State-command UAC is unchanged.
No execution-policy bypass or automatic self-unblocking is used.
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

1. USE BUNDLED PAYLOAD; PREPARE ONLY IF NEEDED

From the reviewed complete public kit, optionally verify bundled payload:

  .\Install-KoreanRules.ps1

This verifies both adjacent BINs read-only and exits 0 without prompting,
downloading, elevating, writing files or creating work/output directories.
Get and Set need no prior Install
when the bundled payload is complete and verified. Set performs its own checks:

  .\Get-KoreanRulesState.ps1
  .\Set-KoreanRulesState.ps1 -WhatIf

Only in a historical/custom source-only kit with no payload does bare Install
show help and exit 0; help does not mean the payload is ready. An invalid or
partial adjacent payload fails verification, without fallback to help,
download or another source.

Only if fresh media extraction or payload preparation is needed, choose ONE
input in elevated Windows PowerShell. Keep the complete kit writable for
preparation. Explicit -Download is a fallback, not a public-kit prerequisite:
download approximately 749 MB of Microsoft media and extract once locally,
never install SQL. Capturing $build is optional:

  $build = .\Install-KoreanRules.ps1 -Download

Instead, extract from existing exact Microsoft media:

  $build = .\Install-KoreanRules.ps1 'C:\Temp\SQLEXPR_x64_ENU.exe'

Or a folder directly containing the expected EXE or rule BIN files:

  $build = .\Install-KoreanRules.ps1 'C:\Temp\VerifiedKoreanRules'

Or use both already-extracted rule files:

  $build = .\Install-KoreanRules.ps1 -RuleSourceDirectory 'C:\Temp\VerifiedKoreanRules'

The first positional argument is SqlPackagePath (alias Path), an INPUT, not
a download destination. Named -SqlPackagePath and -Path remain valid.
Folders are checked only for SQLEXPR_x64_ENU.exe, ko.token.rule.bin and
ko.complex.rule.bin directly inside them; subfolders are NOT searched.
No match: select the child folder/full EXE or explicitly use -Download.
EXE plus either rule BIN is ambiguous: select the exact EXE or use
-RuleSourceDirectory. A rules-only partial pair names the missing file;
it does not trigger an automatic download.

Quote paths containing spaces once when typing. Paired double/single quotes
remaining inside a pasted path string are stripped, for example:

  $copiedPath = '"C:\Temp\Microsoft Media\SQLEXPR_x64_ENU.exe"'
  $build = .\Install-KoreanRules.ps1 -Path $copiedPath

Paths are literal, not wildcard patterns or evaluated commands. Relative
paths resolve from the current PowerShell location. Paste only a path, not
a command line; unmatched quotes are input errors.

The optional second positional argument is a NEW output directory:

  $build = .\Install-KoreanRules.ps1 '.\Microsoft Media\SQLEXPR_x64_ENU.exe' 'C:\Temp\PreparedRules'

For portable output while downloading, name the output parameter:

  $build = .\Install-KoreanRules.ps1 -Download -OutputDirectory 'C:\Temp\PreparedDownload'

With bundled payload, explicit output needs no source/download argument:

  $build = .\Install-KoreanRules.ps1 -OutputDirectory 'C:\Temp\PreparedBundledRules'

If bundled payload is absent, this explicit output request is an error, not
silent help or an automatic download. Supply a verified source or explicitly
choose -Download when requesting portable output from a historical/custom
source-only kit.

Without OutputDirectory, preparation writes only the adjacent payload.
There is NO second kit, ZIP or default C:\Temp\KoreanRules-Ready directory;
BIN input creates no empty work directory. OutputDirectory (second positional
argument) explicitly requests a portable expanded kit PLUS ZIP. Existing output
folders are refused, not reused or overwritten.

Only media download/extraction uses unique WorkRoot directories for
collision-safe extraction/logs. The root defaults to C:\Temp\KoreanRules-Build;
allow several GB of space. Media work directories are intentionally retained
even after success, not second deployment kits. Old user directories are never
automatically deleted.

A management workstation is recommended. An Exchange host is allowed with
a disk/CPU warning, not an additional approval switch. That allowance does
not change Microsoft's workstation recommendation.
Media version, size, SHA256 and Microsoft Authenticode signature are checked
before extraction. The installer extracts without installing SQL and verifies
the exact two rule files. It neither copies them into Exchange nor restarts
services. Failed extraction preserves diagnostics for review.

Invalid existing sources are rejected before creating work/output directories
or executing media. Required EXE: 748772024 bytes, version 17.0.1000.7,
SHA256 74AA90C11202A5524E769B9BC22531BAEF22D91E9B2D2E8C3CB99E89A65C5297.
Mismatches show actual versus required bytes/hash/version. Obtain a fresh
complete copy from the approved Microsoft source. A smaller file is consistent
with an incomplete download, not proof of the cause. A matching filename or
version alone is insufficient. Hashes and Microsoft signature remain strict.
If a complete matching file fails signature verification, check certificate
trust, system time and network access; never bypass verification.

Downloads land as SQLEXPR_x64_ENU.partial.exe and are renamed to the canonical
EXE only after identity AND signature checks pass. Failures retain available
diagnostics; a .partial.exe is not verified media. By default the installer
reports a concise failure once on stderr and exits 1. -ErrorAction Stop gives
automation a catchable PowerShell exception. Correct source/download errors;
they are not Exchange failures or default reasons to contact Support.

  $build | Select-Object Package, SHA256, ExpandedPackage, PayloadDirectory, DefaultPayloadDirectory, ExtractionArtifacts

Default result (no OutputDirectory):
  Package and SHA256 are null because no ZIP is created.
  ExpandedPackage is the current invoked kit.
  PayloadDirectory = DefaultPayloadDirectory = the adjacent verified payload.
Explicit OutputDirectory preserves the portable result:
  Package is the generated ZIP; SHA256 is its hash.
  ExpandedPackage is the generated portable runtime.
  PayloadDirectory is that portable runtime's payload.
  DefaultPayloadDirectory still identifies the original kit's adjacent payload.
ExtractionArtifacts identifies retained media extraction/log artifacts when
media was used; BIN-only preparation creates no empty work directory.

Install prepares/verifies the original script folder's adjacent payload;
portable output is NOT a prerequisite. Both exact BINs are required. Matching existing files
are reused without rewriting; a missing sibling is added only after existing
files verify. Mismatching files, refused paths or write failures are hard
errors, never overwritten or hidden by fallback. Preparation needs a writable
complete kit; bare verification is read-only. Install NEVER writes Exchange
Native. The same folder can be reused.

Set in the SAME folder/computer automatically uses that adjacent payload.
There are no latest-folder scans, guessed paths or persisted global paths.
An explicit alternate PayloadDirectory still takes precedence; its failures
are not hidden. For example, after optionally capturing $build:

  .\Set-KoreanRulesState.ps1 -PayloadDirectory $build.PayloadDirectory -WhatIf

After explicitly requesting portable output, you can work from that runtime:

  Set-Location -LiteralPath $build.ExpandedPackage
  .\Get-KoreanRulesState.ps1

Missing-payload errors name the expected directory and both files:
  <entrypoint-folder>\payload\ko.token.rule.bin
  <entrypoint-folder>\payload\ko.complex.rule.bin

Run Install with -Download or existing inputs from this kit, then retry Set;
or use -PayloadDirectory for an existing verified pair on the caller.
The complete generated package includes its own payload when moved to another
computer. Scripts copied individually into another folder need the complete
kit plus payload, or the complete kit with an explicit payload override.
Detection needs no payload. Remote Apply validates caller-side payload before
connecting; bundled files do not bypass verification.

Required payload:
  ko.token.rule.bin, 56132 bytes
    8F2BD853593913EB8F73DCD4FCAC4216F216A0FF76A4569DF071BE3C36773010
  ko.complex.rule.bin, 717792 bytes
    0390D1E9A76EF33283025CF8F164430E311584B9535949C4EA1A74B6BB107B87

2. VERIFY AND STAGE

Public complete kit: downloads\Exchange-KoreanRules-2.3.1.zip
Checksum: downloads\Exchange-KoreanRules-2.3.1.zip.sha256
It includes the complete runtime, docs, tests, archived compatibility wrappers,
verified 56,132-byte token BIN and 717,792-byte complex BIN.
Explicit OutputDirectory can export a separate portable runtime and deployment
ZIP; default verification/preparation does not duplicate the kit.
Archive root: Exchange-KoreanRules
Exactly three root .ps1 entry points: Install-KoreanRules.ps1,
Get-KoreanRulesState.ps1 and Set-KoreanRulesState.ps1.
It also contains KoreanRules.psm1, KoreanRules.psd1,
private\Invoke-KoreanRulesOperation.ps1, docs, examples, tests,
archive\compatibility and payload.
The private script is not a fourth operator command.

Extract/copy the WHOLE code package, not just a .ps1 wrapper. Get, Set and
the legacy Invoke-KB5130098.ps1 wrapper require the private folder and shared
module. Missing components cause an explicit "package is incomplete" failure;
restore the complete package, including private and the module, before retrying.
Get needs no vendor payload but still requires the complete code package.

The public kit includes tests and legacy compatibility wrappers under
archive\compatibility, not at the release root. Only the repository-only
ArchiveLayout.Tests.ps1 is excluded because it requires historical assets.
The previous source-only archive and checksum are preserved unchanged:
  archive\downloads\Exchange-KoreanRules-2.3.0-source.zip
  archive\downloads\Exchange-KoreanRules-2.3.0-source.zip.sha256
Public inclusion of the two pinned Microsoft BINs was explicitly approved.
The payload allowlist tracks only payload\ko.token.rule.bin and
payload\ko.complex.rule.bin; unrelated payload files remain ignored.
No SQL EXE, MSI or DLL is included in the public kit.

Verify the ZIP hash and sidecar against the approved build record before
extracting to a NEW directory; README.md has the complete checksum example.
A checksum is not signing or authentication of an untrusted download. Sign
scripts/module before building when policy requires; rebuilding changes hashes.

MARK OF THE WEB (MOTW)

Obtain the ZIP and expected checksum from an approved source, verify trust and
checksum, then Unblock-File the EXACT ZIP BEFORE extracting. Use a fresh unique
extraction directory. Only after that trust/checksum verification:

  $zip = 'C:\Temp\Exchange-KoreanRules-2.3.1.zip'
  Unblock-File -LiteralPath $zip
  $destination = 'C:\Temp\KoreanRules-Extract-' + [Guid]::NewGuid().ToString('N')
  if (Test-Path -LiteralPath $destination) { throw 'Choose a new extraction directory.' }
  Expand-Archive -LiteralPath $zip -DestinationPath $destination

For an explicitly exported portable ZIP, use its own filename and trusted checksum.
Unblocking a ZIP AFTER extraction does not clear Zone.Identifier alternate
data streams (ADS) already on extracted files. Prefer a fresh extraction from
the verified, unblocked ZIP. If keeping an extracted kit, first review the
WHOLE package including private and verify trusted identities. Only then, if
policy permits, manually unblock its .ps1, .psm1 and .psd1 files.
This example assumes the exact dedicated kit C:\Tools\Exchange-KoreanRules
contains NO unrelated files:

  $kit = 'C:\Tools\Exchange-KoreanRules'
  Set-Location -LiteralPath $kit
  Get-ChildItem -LiteralPath $kit -Recurse -File |
      Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
      Unblock-File

This includes private but only inside that reviewed kit. Never unblock all
of C:\Temp or another shared tree. The tool does not self-unblock.
Microsoft Unblock-File documentation:
https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/unblock-file?view=powershell-5.1

MOTW is distinct from UAC consent, publisher trust/signature prompts,
AllSigned, Group Policy (GPO) and Windows Defender Application Control (WDAC).
Unblocking does not sign code, elevate, override those controls or guarantee
that every prompt disappears. Get-ExecutionPolicy -List is a read-only
diagnostic. Do not disable policies or use an execution-policy bypass.
Follow organizational signing and approval requirements.

Retain an established stable folder, such as C:\Scripts\Exchange-KB5130098.
Update reviewed contents only while no run is active; preserve user edits and
reports. The new archive name does not move stable lab/operator directories,
the repository directory Exchange-KB5130098, existing reports or receipts.

3. DETECT FIRST

These are alternative inventory examples:

  .\Get-KoreanRulesState.ps1
  .\Get-KoreanRulesState.ps1 EX01,EX02
  .\Get-KoreanRulesState.ps1 -ComputerName EX01.contoso.com,EX02.contoso.com
  .\Get-KoreanRulesState.ps1 -CsvPath 'C:\Temp\servers.csv'

Get exposes no Mode selector and cannot Apply or Rollback. Remote Detect
stages code and writes caller-side reports, but changes no Exchange rules or
services. Remote WhatIf only validates roster/plan; it does not connect,
stage code or inventory remote state.

Get/Set and legacy Invoke wrappers accept ComputerName at position 0:
  .\Set-KoreanRulesState.ps1 EX01 -WhatIf

CSV ALWAYS needs -CsvPath; a positional filename is not guessed to be CSV.
Other paths and switches remain named; there is no other positional guessing.

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
Human colors are contextual: match green, not-applicable yellow; Missing green only
with matching identity, yellow for mismatch, neutral if unobserved. Present
is green for presence only, not a recovery sign-off.

The identity row says Not applicable and lists found versus required Exchange
build, DLL version, byte count and/or SHA256 for each mismatch. The same reason
is recorded in ApplicabilityReason in the objects, CSV and JSON.
Existing files are distinguished as both-present versus a partial pair.
Presence is not verification of a prior installation, restart or recovery.
Expected skips do not require Support escalation. Leave the target unchanged:
review the actual build for a mismatch, or the prior receipt, hashes and
restart/recovery record for existing rules. Investigate a partial pair without
overwriting or blindly reapplying. True partial modifying failures, abandoned
operations, unstable service/ContentEngine or exceptional rollback still
warrant Support involvement.

Missing payload is a caller-side preflight failure with a multiline heading,
expected folder and filenames, followed by exact Install and PayloadDirectory
commands. Get does not require payload; Set does. Missing -SqlPackagePath media
gets separate guidance to Download, select the real EXE, or use extracted rules.

4. PREVIEW AND APPLY

From a complete verified bundled kit (no Install prerequisite), the same kit
after needed preparation, an explicitly generated portable runtime, or
with an explicit alternate caller-side -PayloadDirectory:

  .\Set-KoreanRulesState.ps1 -WhatIf

Only after real pilot/maintenance approval:

  .\Set-KoreanRulesState.ps1 -RestartSearch

Set defaults to Apply. Without RestartSearch it only stages the rules,
returns 10 and requires a separately controlled manual restart/recovery.
MaintenanceWindowApproved is an optional compatibility no-op: it does not
request restart or record/obtain approval and is not required for any command.
WhatIf is file-free: no Exchange writes, operation receipts or report exports;
remote previews also avoid connections/staging. Local preflight can still
return a review-required skip (exit 20) for an ineligible/already-staged
installation; that is not a fatal Apply failure.

Standard confirmation remains opt-in as in 1.2.3. At ConfirmPreference High
no Confirm false is required. Use -Confirm to request a prompt; inherited
stricter preferences remain effective. Confirm false does not remove UAC,
restart selection, rollback approval or recovery gates, or operational
change/window responsibilities.
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

  .\Set-KoreanRulesState.ps1 -CsvPath 'C:\Temp\approved-servers.csv' -RestartSearch

The serial rollout waits after each restarted target for actual recovery
checks and the exact response RECOVERED <exact-target-name>. Any other
response stops it. This gate is retained for 4+ targets and is not waived
by compact output or Confirm false.
Restarted remote Apply refuses AsJson, noninteractive/remoting hosts or
unavailable input before contacting targets. JSON WhatIf is allowed.
Expected existing-rule/wrong-identity states skip that target's changes and
continue the list. No Apply, payload transfer, restart or attestation runs for
targets skipped at detection. Actual errors stop later targets; they remain NotRun in reports. Duplicate-machine
aliases are refused before a second Apply. File-only staging does not attest
recovery. Do not run Apply again on already-staged machines; verify receipt,
hashes and permissions, then follow the approved manual restart/recovery.

EXIT CODES AND UNATTENDED CALLERS

  0  Eligible detection, preview/no change or requested operation complete.
     Inspect status; this is not compliance or a recovery sign-off.
  1  Error/verification failure; stop and preserve diagnostics.
  10 Files staged/removed; Search restart required, NOT a Windows reboot.
  20 Not applicable or rules already present; review before further action.

Exit 20 means at least one target needs review, including Set with only skips.
A mixed file-only Set that really stages files returns10 even with skips;
a restarted mixed run with skips returns20. Skipped-only runs never claim
restart pending. Inspect all report rows. Do not use Detect
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

  .\Set-KoreanRulesState.ps1 -Rollback -ReceiptPath 'C:\ProgramData\Exchange-KB5130098\<operation-id>\receipt.json' -MicrosoftSupportApprovedRollback -RestartSearch

Use the real completed receipt, not the placeholder. Only the exact two owned,
unchanged files are backed up and removed. No arbitrary file deletion, remote
rollback, DLL replacement or SU uninstall occurs. Retain evidence and repeat
workload checks. Follow later Microsoft guidance for changed future builds.

COMPATIBILITY AND HISTORICAL MATERIAL

In the repository, archive\compatibility retains Invoke-KB5130098.ps1,
Invoke-KB5130098Fleet.ps1, Build-KB5130098Package.ps1 and KB5130098.psm1.
The current public kit uses this archived-wrapper layout. The archived 2.1.0
source ZIP and sidecar are unchanged and retain their original internal layout.
See archive\README.md in the repository for the index.
Old fleet Apply STILL
IMPLIES RESTART and retains recovery gates. Operational window planning remains
advice, not a required maintenance flag. Prefer the new three
commands. Internal KB function/error keys and the mutex remain compatible.
Build-KB5130098Package accepts the same source-first/output-second arguments,
adjacent-only default preparation, opt-in portable output and explicit Download;
it propagates the installer
exit code. Legacy Invoke wrappers accept positional ComputerName; CSV remains
explicit -CsvPath.

Current 2.3.1 narrated walkthroughs:
  docs\en\Exchange-KoreanRules-2.3.1-English-Walkthrough.mp4
  docs\hi\Exchange-KoreanRules-2.3.1-Hindi-Walkthrough.mp4
  docs\ta\Exchange-KoreanRules-2.3.1-Tamil-Walkthrough.mp4
  docs\Walkthroughs.md
Each language has matching audio, captions, transcript and 20 chapters. Hindi
uses Devanagari captions; Tamil uses Tamil-script captions. Exact English
command cards remain consistent across languages.
The PowerShell scripts and their error messages are not localized.
Media is separate from the small public kit ZIP. That published ZIP and its
checksum remain immutable; its text documents are a release-time snapshot.
Use the live GitHub guide and media index for these refreshed recordings.
The old English/Hindi 2.1.0 media is preserved under archive\media\2.1.0.
The older 2.0.0 walkthrough is at archive\media\2.0.0; use the current written
guide for operating instructions.

The 1.2.1 media is HISTORICAL, not current instructions:
  archive\media\1.2.1\Exchange-KB5130098-1.2.1-Walkthrough.mp4
  archive\media\1.2.1\Exchange-KB5130098-1.2.1-Narration.m4a
  archive\media\1.2.1\Exchange-KB5130098-1.2.1-Transcript.txt
  archive\media\1.2.1\Exchange-KB5130098-1.2.1-Captions.vtt
  archive\media\1.2.1\Exchange-KB5130098-1.2.1-Captions.srt
It shows old names/detailed output, not the new commands or 4+ compact behavior.
Use README.md and docs\Reporting-and-Splunk.md instead. Earlier workstation,
CSV-column and default-confirmation instructions are superseded too.
Historical 1.0.1 media and 1.0.1/1.2.3 source downloads remain linked in README.md.
The active downloads folder contains only the latest public kit ZIP and checksum.
Older downloads and recordings are preserved under archive; existing operator
folders and previously downloaded packages have not been moved or removed.

For release-specific recorded results and limits, read docs\Lab-Validation.md.
Historical results do not establish a 2.3.1 test/archive pass or new lab rollout.
The historical pilot proved tested EWS new-message results, not OWA/Outlook
recovery, full backlog, sustained production load or live rollback.
