# TLC Toolbox - Teams Log Collection

**Version 0.1.58 | Controlled, unsigned beta | Windows**

Collect scenario-specific Teams evidence after a problem, or sample the affected computer
while the problem is reproduced. The toolbox adds a scoped timeline, explicit collection
warnings, consent/privacy checks, and a verifiable handover archive.

This is a community troubleshooting tool, not a replacement for Microsoft Support, Teams
admin-center telemetry, or your organization's collection and sharing policy.

## Download and run

- **[Download the beta ZIP](https://github.com/SfMC-Exchange-Automation-Team/Troubleshooting/raw/refs/heads/add-tlc-toolbox-beta-0.1.58/TLC-Toolbox/releases/TLC-Toolbox-0.1.58-beta.zip)**
- [SHA256 file](releases/TLC-Toolbox-0.1.58-beta.sha256)
- [Key evidence to inspect and how to troubleshoot](docs/TROUBLESHOOTING.md)
- [Team's full Teams log collection guidelines](../Log%20Collection%20Guidelines%20-%20Microsoft%20Teams%20Troubleshooting.md)

1. Download the ZIP from the link above, not the whole development checkout.
2. Check its SHA256 against the accompanying file:

   ```powershell
   Get-FileHash -LiteralPath '.\TLC-Toolbox-0.1.58-beta.zip' -Algorithm SHA256
   ```

3. If your organization permits this unsigned beta, open the ZIP's **Properties**, select
   **Unblock**, and extract the **whole ZIP**. Do not run a launcher from inside the archive.
4. Keep the extracted folder intact. Double-click **Start-TlcToolbox.cmd**.

Windows PowerShell 5.1 is the recipient runtime; PowerShell 7 is not required. Ordinary
collection does not require administrator rights. Optional packet capture does require
elevation and is off by default. If application control or corporate policy blocks the tool,
ask IT for an approved route; do not change or bypass organizational security policy.

The ZIP contains program files and a recipient README only: **no collected logs, account
allowlists, local operator configuration, test output, or private validation report**.
The hash checks byte integrity; it is not a publisher signature or a malware attestation.
The source and verified beta ZIP in this contribution have the same product-file bytes.

## Pick a scenario explicitly

The dropdown starts blank. The common-scenario shortlist is:

1. **Meetings and Calls: Poor Meeting or Call Quality**
2. **Teams Desktop: Client Launch, Crash, or Performance Issue**
3. **Teams Desktop: Sign-in or Authentication Failure**

This order is a practical triage shortlist, **not a measured frequency ranking**. A divider
separates it from other local-live scenarios. Mobile, Rooms, tenant/service, Android Rooms,
and CVI room-segment scenarios have their own section because a local trace of this PC cannot
diagnose the remote device or service.

Selection controls the closing collectors and manual follow-up plan. It does not make
synthetic relay probes into actual meeting media measurements.

## Workflow A - the problem already happened

1. Choose the matching scenario, case number, affected user, and real collection consent.
2. Choose **Package existing logs**. Despite the name, this is the retrospective gathering
   path; the footer's **Package** action later seals the collected evidence.
3. Enter the **local impact time** and the before/after window. Check the dashboard's
   coverage: files existing on disk does not mean they cover the selected time.
4. Choose an output folder you can write to. **Validate** plans/checks readiness but collects
   nothing. Then choose **Collect**.
5. Complete or skip prompted steps explicitly. Retrospective support-file generation remains
   prompted by default; a fresh support bundle may describe today, not an old incident.
6. Open the completed run folder and follow the review/privacy workflow below.

Collect promptly. Teams rotates logs; there is no guaranteed retention period that makes an
old incident recoverable.

## Workflow B - reproduce the problem now

1. Choose the scenario and enter the case, affected user, consent, and writable output folder.
2. Choose **Run a live trace**, then **Start trace**.
3. Wait for **Reproduce**: loading/warm-up is not recording. Reproduce the issue and note the
   exact symptom time, time zone, meeting/call ID if applicable, and affected media.
4. Click **Stop run** once. **Stopping** is not a hang or an undo: samples are kept while the
   closing collectors run.
5. Watch the pinned checklist: **Stop sampling -> Collect logs -> Support files -> Finish run**.
   File counts, write age, quiet-period checks, and copy failures explain the longer waits.
6. Local live captures normally attempt Teams support generation automatically. Teams may
   come to the foreground. Guarded keyboard automation can be refused or ignored; wait for
   **files collected**, not merely **shortcut sent**.
7. If asked, use **Generate support files** or press **Ctrl+Alt+Shift+1 in Teams**. Wait for
   Teams' **Downloading web logs** banner to disappear.
8. **Skip support files** ends that wait; it does not pretend the support evidence was collected.
   **Skip steps that need the user** opts out up front.

The default cadence is five seconds and the safety cap is 60 minutes. Shorter events can fall
between samples. Raw samples are persisted; chart smoothing and hiding **Show live graphs**
do not change sampling or evidence. The initial RAM preview is not a saved capture sample.
The actual session times in **Capture.json**, not the button-click time, define the live window.

## Review, consent, and packaging

1. Inspect **Run.json**, **Blockers.csv**, and the evidence described in the
   [troubleshooting guide](docs/TROUBLESHOOTING.md). `Complete` alone is not proof that every
   prompted lane succeeded.
2. Use **Open run folder** to review the files. Record gaps, skipped lanes and failed copies.
3. Use the **Signed in** tile's account details/Declare controls only to identify accounts
   legitimately in scope. Obtain the required consent; do not approve unknown identities
   just to make packaging pass.
4. Select footer **Package**. If several runs exist, choose the run(s) that actually cover the
   incident. A new beta installation does not inherit the developer's account allowlist.
5. Resolve any refusal with the displayed guidance, without disabling privacy rules.
6. Verify the sealed archive:

   ```powershell
   Import-Module '.\Tlc.psd1'
   Test-TlcBundleIntegrity -BundlePath 'C:\Evidence\TLC-<correlation-id>.zip'
   ```

   Require **Valid = True**. The `.bundle.json` file next to the ZIP records its SHA256.
   Transfer only through your approved support channel. **Never upload customer captures to
   this public GitHub repository or its issues.**

Teams support logs may include **every signed-in account**. The gate blocks unapproved
accounts, missing required consent, unreadable scanned files, and detected credentials.
HAR credentials and third-party plaintext addresses are redacted before the gate scans.

**Important limits:** some client evidence is opaque or encrypted. The toolbox reads
client ZIP entry names for identity clues and flags archive presence, but does not recursively
scan/redact archive bodies or every binary format. A passing gate is not a blanket
certification that all collected content is shareable. Follow Microsoft and customer guidance.
Retain or dispose of originals and generated Downloads according to that policy.

## CLI examples

Run from the extracted toolbox folder. Substitute real incident details; the examples use
reserved sample identities, not pre-approved accounts.

```powershell
# Plan only: no sampling, support trigger, or evidence collection.
.\TLC-Toolbox.ps1 -Stage Capture -Scenario CallQuality -ValidationOnly `
    -OutputRoot 'C:\Evidence\Teams'

# Record locally, then stop via the wizard or the printed stop-signal instruction.
.\TLC-Toolbox.ps1 -Stage Capture -Scenario CallQuality -CaseNumber 'CASE-123' `
    -AffectedUser 'user@example.test' -ConsentGrantedBy 'Authorized operator' `
    -OutputRoot 'C:\Evidence\Teams'

# Gather an earlier local time window; replace the example timestamp.
.\TLC-Toolbox.ps1 -Stage Collect -Scenario DesktopLaunchCrash -CaseNumber 'CASE-123' `
    -ImpactTime '2026-10-01 14:30' -WindowBeforeMinutes 15 -WindowAfterMinutes 15 `
    -AffectedUser 'user@example.test' -ConsentGrantedBy 'Authorized operator' `
    -OutputRoot 'C:\Evidence\Teams' -SkipPrompted

# Seal an already collected run. Keep its original scenario, case and correlation ID.
.\TLC-Toolbox.ps1 -Stage Package -Scenario CallQuality -CaseNumber 'CASE-123' `
    -CorrelationId '<correlation-id>' -ConsentGrantedBy 'Authorized operator' `
    -OutputRoot 'C:\Evidence\Teams'
```

By default evidence is under `%SystemDrive%\TLC-Toolbox\Runs`; preferences and approved account
declarations are per-user under `%LOCALAPPDATA%\TLC-Toolbox`. The GUI can change the output root.
Windows/macOS Teams shortcut documentation does **not** mean this Windows/WPF toolbox runs on Mac.

## Beta status and feedback

The development release gate for 0.1.58 passed **1,772 tests, zero failures, 19 explicit skips**.
That is development evidence, not a claim that every customer device, policy or scenario works.
The second-PC acceptance covered a standard-user Windows launch and validation; the two
one-hour captured sessions provide earlier-build endurance/current-reader evidence. They do
not certify a new current-build hour-long media workload. All signable files remain unsigned.

This repository includes a **portable subset** of the original regression suite: privacy,
packaging/integrity, logging, and native theme tests. It excludes private lab/capture harnesses
and internal notes. It is not the entire 1,772-test development suite.

For beta feedback provide version, Windows/PowerShell version, scenario, gathering/live path,
approximate local/UTC timing, displayed warning, and reproduction steps. Keep diagnostic files,
UPNs, account IDs, tokens, meeting links and private screenshots out of public issues.

## Test or rebuild from source

Maintainer-only dependencies: Pester 5 or later and PSScriptAnalyzer. Recipients need neither.
Use an **STA** PowerShell host for native WPF tests:

```powershell
powershell.exe -NoProfile -STA -File .\Invoke-TlcBuild.ps1

# Runs the copied public suite first, then builds from Tlc.psd1's FileList.
.\Tools\New-TlcPackage.ps1 -OutputPath 'C:\Temp\TLC-Toolbox-local-build.zip'
```

Build outside the source folder. Do not ZIP/copy the whole working folder, use `-IncludeDocs`
on this minimal public copy, or use `-SkipGate` for a handover build. The archive's generated
README covers recipient setup; this GitHub README and the troubleshooting guide are not
silently added to the program ZIP. File attributes preserve verified script/BOM bytes in Git.
