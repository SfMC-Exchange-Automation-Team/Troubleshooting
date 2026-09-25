Exchange KB5130098 workaround automation | 1.0.1
Guidance reviewed: September 25, 2026

PURPOSE AND SUPPORT BOUNDARY

This is custom, reviewable PowerShell automation of Microsoft's published
workaround. It is NOT a Microsoft-signed installer, hotfix, security update or
permanent product fix. Review it through your change-control and code-signing
process and pilot on one affected server before wider use. Version 1.0.0 was
piloted on one lab server; that initial run did not prove workload recovery.
Version 1.0.1 corrects native invocation paths and deployment-agent exit handling;
it does not change applicability, payload, or the automated restart scope.

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
Invoke-KB5130098.ps1          Detect / Apply / support-approved Rollback CLI
Invoke-KB5130098Fleet.ps1     Explicit-target, serial WinRM inventory/rollout
Build-KB5130098Package.ps1    Workstation-only media extraction and ZIP builder
tests\                       Isolated development tests (source kit only)

The source kit contains NO Microsoft binaries. The builder produces a small
deployment ZIP containing only the automation and two verified BIN files, not
SQL media, SQL binaries, a DLL, runtime libraries or SQL Setup. SQL Server is
never installed. Keep the source kit for rebuilding; the deployment ZIP does
not include the builder. Review applicable licensing before redistribution
outside your organization. Checksums detect changes; they are not code signing.

PREREQUISITES

64-bit Windows PowerShell 5.1, elevated as local administrator (SYSTEM is
supported for local staging through an approved deployment agent). Use C: for
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

1. BUILD THE PAYLOAD ON A MANAGEMENT WORKSTATION

Open elevated Windows PowerShell and change to the extracted SOURCE kit:

  Set-Location 'C:\Temp\Exchange-KB5130098'

Download the exact Microsoft SQL Express media, verify Microsoft Authenticode,
version, byte count and SHA256, extract without installation, and package:

  .\Build-KB5130098Package.ps1 -Download -ManagementWorkstationConfirmed -OutputDirectory 'C:\Temp\KB5130098-Ready'

The download is about 749 MB; allow several GB of free working space.
Alternatively use an existing, exact copy of the Microsoft media:

  .\Build-KB5130098Package.ps1 -SqlPackagePath 'C:\Temp\SQLEXPR_x64_ENU.exe' -ManagementWorkstationConfirmed -OutputDirectory 'C:\Temp\KB5130098-Ready'

Or package the two files you have already extracted using the KB:

  .\Build-KB5130098Package.ps1 -RuleSourceDirectory 'C:\Temp\VerifiedKoreanRules' -ManagementWorkstationConfirmed -OutputDirectory 'C:\Temp\KB5130098-Ready'

All input paths still undergo exact rule size/hash checks. Output must be a new
directory. Existing output is never overwritten. Extraction uses a unique
subfolder of C:\Temp\KB5130098-Build. A failed download/extraction stops the
build and preserves logs. Delete that unique work folder after troubleshooting
or successful packaging when it is no longer needed.

The result is Exchange-KB5130098-1.0.1-deploy.zip plus a SHA256 sidecar. If code
signing is required, sign the scripts/module BEFORE building; sign the builder
too before execution as required by policy. The builder hashes the resulting
files. Protect the package as administrative code.

2. INVENTORY BEFORE CHANGES

Copy/extract the deployment ZIP to an affected server's staging location.
In elevated Windows PowerShell, in the extracted package:

  powershell.exe -NoProfile -File .\Invoke-KB5130098.ps1 -Mode Detect

Or from the management workstation, inventory an explicit list:

  .\Invoke-KB5130098Fleet.ps1 -Mode Detect -ComputerName EX01.contoso.com,EX02.contoso.com -ReportDirectory 'C:\Temp\KB5130098-Reports'

Fleet Detect writes only staged automation and reports, not the Exchange
installation, rule files or service state. Errors stop the run. Nonapplicable
builds/existing rules are reported and never silently treated as remediated.

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

  .\Invoke-KB5130098Fleet.ps1 -Mode Apply -ComputerName EX02.contoso.com,EX03.contoso.com -ReportDirectory 'C:\Temp\KB5130098-Reports' -MaintenanceWindowApproved

The fleet runner processes exactly one server at a time, including its restart.
It stops for a manual workload-recovery attestation after EVERY server. It
cannot continue until the operator types RECOVERED followed by that target's
exact name. A failed or unavailable check means stop, not attestation.
There is no unattended/parallel restart switch, even with -Confirm:$false.
Fleet -WhatIf lists intent only and makes no remote connection; use Detect for
actual eligibility checks.

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

  powershell.exe -NoProfile -NonInteractive -Command "& '.\Invoke-KB5130098.ps1' -Mode Apply -Confirm:$false; exit $LASTEXITCODE"

Use that command line in your deployment-agent configuration. When invoking
from an existing PowerShell session, call the script directly with
-Mode Apply -Confirm:$false instead. Windows PowerShell 5.1 -File cannot pass
an explicit false value to a switch, which is why the agent example uses -Command.
The final exit forwards the script's custom code to the deployment agent; without
it, Windows PowerShell can turn codes 10 and 20 into process exit 1. This example
is a literal deployment-agent/cmd.exe command line. If constructing it inside
PowerShell, use a single-quoted argument or escape $LASTEXITCODE so the parent
does not expand it before the child runs.

Custom exit codes for the LOCAL entry point:
  0  Detection eligible, WhatIf/no change, or requested operation completed.
     Read JSON Status: 0 does NOT mean workload recovery is proven.
  1  Error/verification failure. Stop and retain logs; do not blindly retry.
  10 Two files staged/removed; Search restart is still required.
     This is NOT a request to reboot Windows. Map to a custom non-reboot status.
  20 NotApplicableStop or RuleFilesPresentStop; review before further action.

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
SYSTEM receive access to that operation directory. The returned JSON identifies
the exact receipt path. It records original absence, successfully copied/removed
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

1.0.1 CHANGES

- Resolve omitted payload/package defaults inside the script body so native
  powershell.exe -File works; explicitly supplied paths remain unchanged.
- Forward custom exit codes in the unattended deployment-agent example.
- Cover real child-process invocation, error/JSON output, explicit overrides,
  custom exit codes, the README command, and nonconnecting fleet WhatIf.
- Describe separately approved caller recovery without broadening the kit's
  automatic service changes or treating process stability as workload success.
