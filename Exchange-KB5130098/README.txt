Exchange KB5130098 workaround automation | 1.2.3
Guidance reviewed: September 25, 2026

PURPOSE AND SUPPORT BOUNDARY

This is custom, reviewable PowerShell automation of Microsoft's published
workaround. It is NOT a Microsoft-signed installer, hotfix, security update or
permanent product fix. Review it through your change-control and code-signing
process and pilot on one affected server before wider use. Version 1.0.0 was
piloted on one lab server; that initial run did not prove workload recovery.
Version 1.0.1 corrects native invocation paths and deployment-agent exit handling;
it does not change applicability, payload, or the automated restart scope.
Version 1.0.2 adds interactive UAC relaunch and human-readable before/action/current
summaries. Machine callers must now specify -AsJson explicitly.
Version 1.1.0 integrates serial remote orchestration and strict CSV targeting into
the primary entry point. RestartSearch is explicit for both local and remote
primary Apply; the old fleet wrapper retains its historical Apply/restart behavior.
Version 1.1.1 shows a single STATUS column unless Mode is Apply, and colors
Present file-state values green without changing eligibility or recovery gates.
Version 1.1.2 makes ReportDirectory optional everywhere. Omitted remote report
paths use C:\Temp\KB5130098-Reports on the calling computer.
Version 1.2.0 retains structured session-level $report objects and $reportFiles,
prints their summary, and exports CSV, detailed JSON and final JSON Lines by
default for local and remote runs. Previews produce no persistent report exports.
Version 1.2.1 colors a pinned-identity mismatch red, a confirmed match green,
and Missing rule files green only for a matching identity; Missing on an
ineligible installation is yellow, while unobserved state stays neutral.
Version 1.2.2 permits package builds on Exchange with an advisory warning and
no required ManagementWorkstationConfirmed switch. CSV imports accept native
Get-ExchangeServer Fqdn/Name columns as well as existing ComputerName lists.
Version 1.2.3 makes standard PowerShell confirmation opt-in at the default
ConfirmPreference. WhatIf and operation-specific approval/recovery gates remain.

Sources:
https://support.microsoft.com/en-us/servicing/exchange/server/update/2026/5130098
https://learn.microsoft.com/en-us/exchange/new-features/build-numbers-and-release-dates
https://support.microsoft.com/en-us/servicing/exchange/server/update/2026/5121608

SECURITY UPDATE VS SE

The affected build 15.02.2562.049 is Exchange Server SE RTM Sep26SU, released
September 8, 2026 (KB5121608). SU means Security Update. SE means Subscription
Edition, the product edition. This is a security update to SE, not a feature/CU
upgrade to SE. KB5130098 documents a regression and its workaround; it is not
the security-update installer. This kit only adds the two rule-data files.
It does not install or uninstall the SU and does not replace korwbrkr.dll.
Do not remove a security update as an automated workaround.

IMPACT AND OPEN QUESTIONS

Confirmed by KB5130098: environments processing Korean-language email after
the September 2026 SU may have missing search results, delayed email delivery,
and MAPI/Outlook clients that stall, disconnect or become unresponsive. The
updated Korean WordBreaker is missing required external rule-data files.

The KB does not establish that every Korean email triggers a deadlock, describe
the full trigger conditions, or state a precise user/message blast radius.
Do not claim either "only the Korean message/user" or "everyone always".
Because ContentEngine is shared server-side processing, broader workload
disruption is a reasonable operational risk, not a documented guarantee that
every mailbox or transport queue is blocked. Other messages may be affected;
use message tracking, queues, server health and the support case to establish
the actual scope. This kit does not diagnose deadlock or inspect message bodies.

Survey the explicit target list. Apply only to affected installations matching
EVERY KB criterion. Do not deploy indiscriminately to all Exchange versions,
roles, servers or machines based solely on symptoms or user language.
Passive copies or absence of current Korean senders do not prove future safety;
review affected-server scope with Microsoft Support.

Microsoft says it is investigating and will update KB5130098. The article does
not announce a separate permanent hotfix, release date, future KB number or
fleet installer. This custom automation is not a commitment from Microsoft.
Re-read the article before use. Future build/hash changes require new Microsoft
guidance; do not relax the pinned identities to make the script accept them.

CONTENTS

KB5130098.psd1                Exact build/file identities from the KB
KB5130098.psm1                Local implementation and guarded service restart
Invoke-KB5130098.ps1          Local / explicit-target / CSV inventory and rollout
Invoke-KB5130098Fleet.ps1     Compatibility wrapper (legacy Apply includes restart)
Build-KB5130098Package.ps1    Verified extract-only media and ZIP builder
tests\                       Isolated development tests (source kit only)
examples\servers.csv          Fictional target-list template; edit before use
docs\Reporting-and-Splunk.md   Report variables, CSV/JSON formats and Splunk examples

The source kit contains NO Microsoft binaries. The builder produces a small
deployment ZIP containing only the automation and two verified BIN files, not
SQL media, SQL binaries, a DLL, runtime libraries or SQL Setup. SQL Server is
never installed. Keep the source kit for rebuilding; the deployment ZIP does
not include the builder. Review applicable licensing before redistribution
outside your organization. Checksums detect changes; they are not code signing.

PREREQUISITES

64-bit Windows PowerShell 5.1. The local CLI can request normal Windows UAC
elevation for an interactive human run and reopen itself in the correct host.
The elevated window displays the results and waits for Enter before closing;
the original process then receives its exit code and report data. A private,
locked, data-only handoff is removed after the parent receives it. No credential
or executable content is written to that result handoff. It never changes execution
policy or supplies approval for an Exchange operation. Parameters, including
explicit false switches and WhatIf, are preserved. Declined elevation is an error,
not a successful no-op.
Inherited WhatIf and confirmation preferences are preserved too; elevation must
not turn a session-level preview into a modifying operation.

For local operations, JSON capture (-AsJson), pipelines, remoting and unattended
runs must already be elevated. -NoAutoElevate suppresses local relaunch explicitly;
it does not bypass the administrator requirement. Remote orchestration instead
uses existing Kerberos rights and administrative 64-bit sessions on each target,
without local UAC or changed credentials. The builder retains its elevation
requirement. SYSTEM remains supported for local
staging through an approved deployment agent. A package intended for interactive
UAC launch must be readable from the initial unelevated account; keep write access
restricted to administrators and follow your code-signing policy. Use C: for
build/staging/reports. The script discovers the actual Exchange install path
from the local registry; it does not assume the default path. Write paths
through junctions/reparse points or F: are intentionally refused. Detection
can report an F: installation, but this package will not change one.

Use an approved secure local directory and your organization's script-signing
policy. No execution-policy bypass or policy changes are included.
WinRM rollout requires existing administrative Kerberos access to the normal
Microsoft.PowerShell endpoint, NOT the constrained Exchange shell endpoint.
It never enables remoting, changes TrustedHosts or persists credentials.
No cloud/tenant connection, Exchange cmdlet module or third-party module is needed.

1. BUILD THE PAYLOAD (MANAGEMENT WORKSTATION RECOMMENDED)

Open elevated Windows PowerShell and change to the extracted SOURCE kit:

  Set-Location 'C:\Temp\Exchange-KB5130098'

Exchange hosts are no longer blocked. The builder emits a warning about local
disk/CPU usage and continues; it never applies the workaround or restarts Exchange.
The KB still recommends extracting on a management workstation. This custom
tool's relaxed restriction is not a change to that recommendation; plan resource
impact through normal change control. ManagementWorkstationConfirmed is optional
and accepted only for backward-compatible commands, not as an execution gate.

Download the exact Microsoft SQL Express media, verify Microsoft Authenticode,
version, byte count and SHA256, extract without installation, and package:

  .\Build-KB5130098Package.ps1 -Download -OutputDirectory 'C:\Temp\KB5130098-Ready'

The download is about 749 MB; allow several GB of free working space.
Alternatively use an existing, exact copy of the Microsoft media:

  .\Build-KB5130098Package.ps1 -SqlPackagePath 'C:\Temp\SQLEXPR_x64_ENU.exe' -OutputDirectory 'C:\Temp\KB5130098-Ready'

Or package the two files you have already extracted using the KB:

  .\Build-KB5130098Package.ps1 -RuleSourceDirectory 'C:\Temp\VerifiedKoreanRules' -OutputDirectory 'C:\Temp\KB5130098-Ready'

All input paths still undergo exact rule size/hash checks. Output must be a new
directory. Existing output is never overwritten. Extraction uses a unique
subfolder of C:\Temp\KB5130098-Build. A failed download/extraction stops the
build and preserves logs. Delete that unique work folder after troubleshooting
or successful packaging when it is no longer needed.

The result is Exchange-KB5130098-1.2.3-deploy.zip plus a SHA256 sidecar. If code
signing is required, sign the scripts/module BEFORE building; sign the builder
too before execution as required by policy. The builder hashes the resulting
files. Protect the package as administrative code.

Use the GENERATED runtime, for example:
  C:\Temp\KB5130098-Ready\Exchange-KB5130098
It contains payload\ko.token.rule.bin and payload\ko.complex.rule.bin. The source
folder is not populated by the build. Stage the reviewed generated runtime in
your stable operator folder, or specify -PayloadDirectory for the verified rules
on the caller. Remote Apply validates its caller-side payload before connecting.
For repeated manual use, keep a stable working folder such as
C:\Scripts\Exchange-KB5130098. Update verified contents in place while no run is
active, preserving user edits and reports. Versions belong in metadata/archive
names, not a new working directory for every release.

2. INVENTORY BEFORE CHANGES

Copy/extract the deployment ZIP to an affected server's staging location.
In Windows PowerShell, in the extracted package (approve UAC if prompted):

  powershell.exe -NoProfile -File .\Invoke-KB5130098.ps1 -Mode Detect

Human output is the default: STATUS, ACTION TAKEN, and NEXT STEP. A no-argument
run is Detect only: it never copies rules or restarts services and shows each
observed value once. Only -Mode Apply uses BEFORE / CURRENT comparisons, including
an explicitly labelled Apply -WhatIf preview. Those observations refer to this
invocation, not earlier history. Rollback shows resulting STATUS and describes
removals in ACTION TAKEN. Errors retain observed state and partial-operation receipts.
Present values are green in human output. Green means a file exists, not that
its contents are verified or the workload has recovered; stop warnings remain.
Existing -AsJson status/exit meanings and operational checks remain; the remote
JSON envelope additionally includes ReportData rows and ExportFiles paths.

STANDARD CONFIRMATION IS OPT-IN

With the default $ConfirmPreference = 'High', normal local changes and remote
runs do not prompt for standard PowerShell confirmation. -Confirm:$false is no
longer required. Apply proceeds after its checks; use -WhatIf to preview first,
or add -Confirm to explicitly request the standard confirmation prompt.

Stricter session confirmation preferences (Medium or Low) are still honored.
-Confirm:$false remains an explicit override. Report persistence does not add
its own confirmation prompts. WhatIf remains non-modifying, including exports.
This does not remove UAC consent, RestartSearch, MaintenanceWindowApproved,
MicrosoftSupportApprovedRollback, or per-server recovery attestation.

RESULT OBJECTS AND DEFAULT EXPORTS

After a normal script call in the same PowerShell session:

  $report
  $report | Format-Table ComputerName, Mode, Status, TokenRule, ComplexRule
  $report | Where-Object Status -eq 'FailedStop'
  $reportFiles

$report contains one flat, typed object per target, not a JSON string or formatted
screen output. It is refreshed at session scope for each invocation. For explicit
assignment or use inside a function, use:

  $report = .\Invoke-KB5130098.ps1 -ComputerName EX02.contoso.com -PassThru

-AsJson and -PassThru are alternatives. An external powershell.exe process cannot
set a variable in an unrelated parent shell; read the exports or capture its JSON.
The script's own UAC relaunch returns the data to the original invoking session.

Local and remote runs save these files in a unique caller-side report directory:
  rollout.json    Full nested detail; rewritten checkpoints during remote rollout.
  results.csv     Default one-row-per-target summary, suitable for spreadsheets.
  results.jsonl   Final one-object-per-line JSON events with RunId/TimestampUtc.

CSV is convenient for Excel. JSON preserves structure and types for automation.
For Splunk monitoring use the finalized results.jsonl, not the rewritten checkpoint
or both formats together. Review docs\Reporting-and-Splunk.md with the customer's
Splunk administrator; the script does not send to or configure Splunk.

-NoCsv omits CSV only. -ReportDirectory optionally overrides the shared
C:\Temp\KB5130098-Reports default for local or remote runs. -WhatIf retains objects
in memory but writes no persistent report exports. No report-directory prompt
is required. Write failures are explicit errors, not silent fallbacks.

Final JSONL is written once per run, not updated for every checkpoint. A gracefully
stopped fleet retains FailedStop/NotRun rows; a hard termination may leave only
the detailed checkpoint. CSV neutralizes formula-leading text, while JSON and
objects retain the original values. Review hostnames/paths/errors before sharing.

For the original JSON interface, start in an elevated shell and opt in explicitly:

  powershell.exe -NoProfile -NonInteractive -File .\Invoke-KB5130098.ps1 -Mode Detect -AsJson

Or from the management workstation, inventory an explicit list:

  .\Invoke-KB5130098.ps1 -ComputerName EX02.contoso.com

ReportDirectory is optional. The shared default is C:\Temp\KB5130098-Reports on
the calling computer, with a unique subfolder per run. JSON, CSV and JSON Lines
paths are printed and retained in $reportFiles. Custom paths remain supported:

  .\Invoke-KB5130098.ps1 -Mode Detect -ComputerName EX01.contoso.com,EX02.contoso.com -ReportDirectory 'C:\Temp\KB5130098-Reports'

Remote Detect writes only staged automation and reports, not the Exchange
installation, rule files or service state. Errors stop the run. Nonapplicable
builds/existing rules are reported and never silently treated as remediated.
An invalid or unwritable report location stops before target connections; no
silent fallback or lost reporting. Choose another approved ReportDirectory if
the default is not usable. Standard confirmation is opt-in; maintenance and
recovery approval gates are unchanged.

CSV TARGETS FOR LARGER ENVIRONMENTS

Use a reviewed comma-separated file with ComputerName, Fqdn or Name, for example:

  Name,Fqdn,Site
  EX01,EX01.contoso.com,SiteA
  EX02,EX02.contoso.com,SiteB

  .\Invoke-KB5130098.ps1 -Mode Detect -CsvPath 'C:\Temp\servers.csv'

Export native Exchange properties without renaming:

  Get-ExchangeServer | Select-Object Name,Fqdn | Export-Csv -LiteralPath 'C:\Temp\servers.csv' -NoTypeInformation -Encoding UTF8

Review and narrow the roster before use. A full Get-ExchangeServer export also
works, including an optional leading #TYPE line. Select the target column once
per file, in this precedence order: ComputerName, Fqdn, Name. Header case and
surrounding whitespace are ignored. Blank/invalid selected values stop the run;
there is no per-row fallback to a different column.

ComputerName and CsvPath are mutually exclusive. ReportDirectory uses the same
optional default for CSV input. All records are validated before any connection or report:
blank target cells, duplicate names (ignoring case), invalid DNS/NetBIOS names,
IPs/wildcards/URLs, duplicate/empty headers, malformed quotes and inconsistent
field counts stop the run. Input order is preserved; whitespace around names is
trimmed. Blank physical lines are ignored. UTF-8 CSV, standard quoting and
multiline metadata are supported. Unselected columns, including PSComputerName,
are metadata only. PSComputerName can identify the remoting origin and is never
used as a target column. Enabled does not filter servers or grant approval.

The bundled examples\servers.csv uses fictional names and must be edited.
Parsing is tested with 2,500 targets; this is not a live fleet-scale claim.
Use -AsJson for machine-readable inventory or file-only staging, with native
exit-code forwarding where appropriate. Confirm false is optional, not required.

EligibleMissingBothRules means exactly:
  ExSetup.exe numeric file version: 15.2.2562.49 (15.02.2562.049 in the KB)
  korwbrkr.dll version: 16.0.5194.1000; 326544 bytes; pinned SHA256 matches
  Neither ko.token.rule.bin nor ko.complex.rule.bin exists in Native

Eligibility is not proof that the server has experienced a deadlock.
RuleFilesPresentStop means either rule exists. Even if both hashes match,
the KB says stop and contact Microsoft Support before changing the installation.
A repeated Apply intentionally refuses to overwrite or restart. It does not
silently return "success/already fixed". NotApplicableStop means build/DLL
criteria differ. Missing files, registry, access or hash errors are failures.

3. PILOT AND ROLL OUT ONE SERVER AT A TIME

Use your normal Exchange/DAG maintenance and health runbook first. This tool
does not move active databases, drain transport, suspend activation, put a
server into maintenance mode or restart IIS/Store/Transport. Confirm the
affected-server scope and maintenance window before approving a change.

Local read-only preflight:

  .\Invoke-KB5130098.ps1 -Mode Apply -WhatIf

Apply AND gracefully restart Search in the approved maintenance window:

  .\Invoke-KB5130098.ps1 -Mode Apply -RestartSearch -MaintenanceWindowApproved

Only HostControllerService is stopped/started. No Force or process termination
is used. Running dependent services cause refusal. A stop/start timeout,
missing ContentEngineNode1, process exit/restart, or hash/permission error
stops the procedure. Do not force-terminate Exchange processes; contact Support.

The tool verifies the exact ContentEngineNode1 command-line noderoot and
executable path, then observes the SAME PID for 30 seconds by default. This is
only a startup observation; it cannot prove long-term stability or recovery.

If the process is stable but the calling workload remains blocked, stop rollout
and preserve its diagnostics. Adding rules and restarting ContentEngine does
not necessarily recover a caller's existing connection, wait, or queued work.
A separately approved, evidence-led recovery may involve Mailbox Assistants for
background indexing or Mailbox Transport Delivery for delivery/on-delivery
indexing. Such a restart affects that workload and is NOT performed automatically
by this kit. Revalidate the original workload after any approved recovery; do not
restart unrelated services, mass-retry mailboxes, or rerun Apply to bypass the
existing-rule stop. Monitor new Korean initialization failures and CTS submission
timeouts as well as delivery/search. A successful Test-Mailflow is insufficient.
Attribute a remaining error to the originating PID and CTS caller, not just its
event provider name. For example, MSExchangeFastSearch event 1006 can be emitted
by a Transport or EWS process; restarting MSExchangeFastSearch on that evidence
alone can miss the actual caller. Recover only the specifically identified
workload under its own maintenance/runbook gates, then repeat the postchecks.

After the first server is confirmed recovered, an interactive serial fleet run:

  .\Invoke-KB5130098.ps1 -Mode Apply -ComputerName EX02.contoso.com,EX03.contoso.com -ReportDirectory 'C:\Temp\KB5130098-Reports' -RestartSearch -MaintenanceWindowApproved

Or use the approved CSV roster:

  .\Invoke-KB5130098.ps1 -Mode Apply -CsvPath 'C:\Temp\approved-servers.csv' -ReportDirectory 'C:\Temp\KB5130098-Reports' -RestartSearch -MaintenanceWindowApproved

The fleet runner processes exactly one server at a time, including its restart.
It stops for a manual workload-recovery attestation after EVERY server. It
cannot continue until the operator types RECOVERED followed by that target's
exact name. A failed or unavailable check means stop, not attestation.
There is no unattended/parallel restart switch, even with -Confirm:$false.
Fleet -WhatIf lists intent only and makes no remote connection; use Detect for
actual eligibility checks.

Without -RestartSearch, primary remote Apply stages files only and returns 10.
It does not request recovery attestation or imply recovery. Restarted remote
Apply requires a local interactive console and refuses -AsJson or unattended
operation before the first connection; read rollout.json for structured results.
A JSON WhatIf plan is allowed because it does not connect or restart anything.
Any failure stops subsequent targets; unvisited roster entries remain NotRun.

Invoke-KB5130098Fleet.ps1 is now only a compatibility wrapper. Its Apply still
includes a restart, preserving the legacy maintenance/recovery gates. New callers
should use the primary entry point. Rollback remains local and receipt-bound.

Required recovery evidence:
  - In OWA, use a mailbox whose ACTIVE database is on the changed server.
  - Verify delivery AND server-side search of new ordinary messages.
  - Verify delivery AND server-side search of new Korean-language messages.
  - Verify the ORIGINAL affected workload, including Outlook connectivity or
    delivery delays where applicable, has recovered.
  - Monitor old indexing backlog separately; new-message success does not
    establish that all older items have been processed.
  - A service/process being Running alone is not sufficient evidence.

4. CONFIGMGR / OTHER APPROVED DEPLOYMENT AGENTS

Distribute the generated deployment ZIP, not the SQL package. Run elevated
64-bit Windows PowerShell on individually approved, inventoried targets.
The unattended staging command below ADDS FILES but NEVER restarts services:

  powershell.exe -NoProfile -NonInteractive -Command "& '.\Invoke-KB5130098.ps1' -Mode Apply -AsJson; exit $LASTEXITCODE"

Use that command line in your deployment-agent configuration. When invoking
from an existing PowerShell session, call the script directly with
-Mode Apply -AsJson instead. These examples use the default confirmation
preference. If an agent sets a stricter preference, -Confirm:$false remains an
optional override; Windows PowerShell 5.1 -File cannot express that false switch,
so use -Command when explicitly passing it. When using -Command, the final exit
forwards the script's custom code to the deployment agent; without
it, Windows PowerShell can turn codes 10 and 20 into process exit 1. This example
is a literal deployment-agent/cmd.exe command line. If constructing it inside
PowerShell, use a single-quoted argument or escape $LASTEXITCODE so the parent
does not expand it before the child runs.

Custom exit codes for the LOCAL entry point:
  0  Detection eligible, WhatIf/no change, or requested operation completed.
     Read the human action/current-state summary or -AsJson Status:
     0 does NOT mean workload recovery is proven.
  1  Error/verification failure. Stop and retain logs; do not blindly retry.
  10 Two files staged/removed; Search restart is still required.
     This is NOT a request to reboot Windows. Map to a custom non-reboot status.
  20 NotApplicableStop or RuleFilesPresentStop; review before further action.
     For remote Detect, at least one target has a stopped eligibility result.

Detection exit 0 means ELIGIBLE/MISSING, not compliance/remediated. Do not use
the Detect command as a ConfigMgr "installed" detection rule. Author deployment
compliance separately against your successful receipt, exact destination
identities and completed recovery evidence. Do not configure automatic retry
on existing-rule results. Detection does not inspect the state of prior receipts.

After unattended file staging, re-running Apply is intentionally blocked by
the KB's existing-file rule. Verify receipt, both destination identities and
inherited permissions, then follow the KB's manual restart/recovery procedure
in the maintenance window on that same server. Do not run the fleet Apply
command against already-staged machines. Prefer the interactive Apply/restart
path when coordinating the whole workflow.

LOGS AND FAILURE HANDLING

Each modifying operation creates a protected, unique receipt.json and
events.jsonl under %ProgramData%\Exchange-KB5130098. Only Administrators and
SYSTEM receive access to that operation directory. The human summary or -AsJson
result identifies the exact receipt path. It records original absence, successfully copied/removed
files and lifecycle state. Code-only fleet staging is retained under
C:\ProgramData\Exchange-KB5130098-Staging\<unique ID>; the report records it.
Keep remote receipts and local rollout.json as your change evidence.

No automatic deletion/rollback is attempted after a partial failure. A partial
file, one copied rule, a logging error or a stopped service can require manual
recovery. Stop, preserve logs and contact Microsoft Support. The unchanged
source files remain available. The DLL and preexisting files are never touched.

Normal inherited read permissions are checked for both created files. The tool
does not grant permissive ACEs, change the Native directory ACL, or override a
customized DACL. Its inheritance check is not a complete effective-access audit;
validate access for your actual service identities and workload during the pilot.

ROLLBACK (SUPPORT-APPROVED ONLY)

The KB does not prescribe rollback. Removing these files can reintroduce the
original issue. This optional custom action requires explicit Microsoft Support
approval, a maintenance window and a receipt from a completed Apply on the same
computer/path/build. It refuses changed files, changed builds or partial/failed
deployments and never removes arbitrary paths from a receipt.

  .\Invoke-KB5130098.ps1 -Mode Rollback -ReceiptPath 'C:\ProgramData\Exchange-KB5130098\<operation-id>\receipt.json' -MicrosoftSupportApprovedRollback -MaintenanceWindowApproved -RestartSearch

Only the exact two files added by a recorded Apply are backed up into the new
operation directory and removed. No SU uninstall or DLL replacement occurs.
Service restart and workload recovery must still be controlled. Retain all
receipts. If a future Microsoft fix changes file identity/build, this rollback
will refuse it; follow the later Microsoft guidance instead.

DEVELOPMENT / RELEASE LIMITS

The source tests use fixtures/mocks with the existing Pester runner and native
Windows PowerShell 5.1 child processes. Native tests exercise the real entry-point
scripts against isolated module fixtures and use nonconnecting fleet WhatIf.
They do not install Exchange/SQL, download executables or change real services.
This package must still be piloted on an affected installation with the exact
Microsoft payload and actual workload before a production rollout.

1.2.3 CHANGES

- Standard PowerShell confirmation is opt-in at the default High preference.
  Normal local, remote, CSV and legacy runs no longer need -Confirm:$false.
- Explicit Confirm, Confirm false, inherited policies, WhatIf and UAC preference
  forwarding remain supported. Report persistence adds no confirmation prompts.
- Maintenance/restart/rollback approval and recovery-attestation gates remain.

1.2.2 CHANGES (PREVIOUS RELEASE)

- Allow builds on Exchange with a disk/CPU advisory warning instead of refusal.
- Remove the mandatory workstation assertion; accept the old switch for
  compatibility. Administrator, media identity/signature, extraction and
  no-overwrite output-directory checks are unchanged.
- Accept CSV target columns in order ComputerName, Fqdn, Name, plus an optional
  leading #TYPE line from Export-Csv. Native Exchange properties need no rename.
- Validate the selected column for every row without silent fallback, target
  skipping or guessed hosts. Existing whole-roster safety checks remain.

1.2.0 CHANGES (PREVIOUS RELEASE)

- Keep actual typed per-target results in session-level $report, with paths in
  $reportFiles, and print a terminal summary. -PassThru supports object pipelines.
- Export CSV by default alongside detailed JSON and final JSON Lines. -NoCsv
  disables only CSV; previews remain in-memory with no persistent output files.
- Return local UAC report data through a private reserved result file, removed
  after use, without executable content or credentials.
- Preserve report state for failures/unvisited targets and expose export errors.
- Include a Splunk ingestion guide; no live customer connection/configuration
  is attempted and integration must be validated in the customer's environment.

1.2.1 CHANGES

- Color "No - stop" red and a confirmed pinned identity match green.
- Color Missing rules green only when the pinned identity matches; use yellow
  for Missing on an explicitly ineligible installation and neutral when unknown.
- Retain green Present styling. Console colors do not change machine results,
  status decisions, exit codes, operation scope or recovery gates.

1.1.2 CHANGES (PREVIOUS RELEASE)

- Default remote reports to C:\Temp\KB5130098-Reports on the calling computer.
- Primary direct/CSV and legacy entry points no longer prompt for an omitted
  ReportDirectory. Valid explicitly supplied paths remain unchanged.
- Unique per-run report folders, existing path protections, and explicit write
  errors are retained. No target selection or operation approval is inferred.
- Regression tests run minimal native commands without a report argument and
  exercise default/custom report output, CSV, legacy WhatIf and write failures.

1.1.1 CHANGES (PREVIOUS RELEASE)

- Single STATUS column for Detect/default and other non-Apply operations.
- BEFORE / CURRENT only for Apply, including previews labelled as no changes.
- Present file-state values use green console text locally and remotely.
- No change to machine JSON, reports, exit codes or modifying operations.

1.1.0 CHANGES (PREVIOUS RELEASE)

- Primary CLI accepts either -ComputerName or -CsvPath with -ReportDirectory.
- The full input roster is validated before connections; ordering is preserved.
- Remote execution shares one module orchestrator and the same local engine.
- Remote Apply does not restart unless -RestartSearch is explicit; restarted
  rollout remains serial and requires interactive workload attestation.
- Existing fleet entry point is a thin wrapper preserving legacy Apply/restart.
- Reports include original/current state and NotRun records after an early stop.
- The deployment ZIP includes examples\servers.csv; no credentials or target
  discovery are implied by importing a file.

1.0.2 CHANGES (PREVIOUS RELEASE)

- Human BEFORE/CURRENT, ACTION TAKEN and NEXT STEP output is now the local CLI
  default. No-argument execution remains Detect only, never an implicit Apply.
- -AsJson preserves the machine result shape and exit codes. Update automation
  explicitly; start it already elevated so it never depends on a UAC prompt.
- Local interactive human runs can relaunch through standard Windows UAC into
  64-bit Windows PowerShell 5.1. The child shows the result and waits for Enter;
  the parent waits and returns the child's exact exit code. JSON/pipeline,
  remoting, noninteractive and -NoAutoElevate invocations never prompt for UAC.
- Arguments are serialized as data, including explicit false switches, quotes,
  trailing separators and the working directory. No execution-policy changes,
  credential files, extra Exchange approvals or recursive elevation are added.
- Failure summaries show observed partial file state and the operation receipt
  when available. No automatic rollback, overwrite or retry is introduced.
- UAC protocol tests use mocked launch/context boundaries and a real native
  child fixture; they do not click a consent prompt or execute Exchange Apply.

1.0.1 CHANGES (PREVIOUS RELEASE)

- Resolve omitted payload/package defaults inside the script body so native
  powershell.exe -File works; explicitly supplied paths remain unchanged.
- Forward custom exit codes in the unattended deployment-agent example.
- Cover real child-process invocation, error/JSON output, explicit overrides,
  custom exit codes, the README command, and nonconnecting fleet WhatIf.
- Describe separately approved caller recovery without broadening the kit's
  automatic service changes or treating process stability as workload success.
