# Diagnose Managed Folder Assistant processing with MFA-Toolbox

The Managed Folder Assistant (MFA) is the Exchange Online mailbox assistant that applies Messaging
Records Management (MRM) retention policies: moving items to the archive, deleting expired items, and
tagging items past their retention limit. When it appears not to run against a mailbox, the cause is
usually a prerequisite that is not met rather than a fault in the assistant itself.

MFA-Toolbox is a Windows PowerShell module that determines **why** the Managed Folder Assistant is or
is not processing a mailbox, and separates that diagnosis from any change to your tenant.

**Applies to:** Exchange Online

> [!IMPORTANT]
> The diagnostic command performs no tenant writes. Remediation lives in a separate command that you
> must invoke deliberately, with a switch per action. This separation is enforced by an automated
> test, not by convention. See [Command reference](#command-reference).

## In this article

- [Prerequisites](#prerequisites)
- [Install the module](#install-the-module)
- [Command reference](#command-reference)
- [Validate the module against your tenant](#validate-the-module-against-your-tenant)
- [Diagnose mailbox readiness](#diagnose-mailbox-readiness)
- [Interpret the results](#interpret-the-results)
- [Start the Managed Folder Assistant](#start-the-managed-folder-assistant)
- [Repair prerequisites](#repair-prerequisites)
- [Output files](#output-files)
- [How the toolbox reaches its conclusions](#how-the-toolbox-reaches-its-conclusions)
- [Troubleshoot the toolbox](#troubleshoot-the-toolbox)
- [Run the tests](#run-the-tests)
- [Known limitations](#known-limitations)
- [Disclaimer](#disclaimer)

## Prerequisites

Before you begin, confirm the following.

| Requirement | Detail |
|---|---|
| PowerShell | Windows PowerShell 5.1. The module is not tested on PowerShell 7. |
| Exchange Online | A connected session with `Get-Mailbox`, `Get-MailboxStatistics`, and `Get-OrganizationConfig`. |
| Retention validation | `Get-RetentionPolicy` and `Get-RetentionPolicyTag`, unless you use `-SkipRetentionPolicyTriggerValidation`. |
| Microsoft Graph | `Get-MgUser` and `Get-MgUserLicenseDetail`, unless you use `-SkipGraphChecks`. |
| Assistant diagnostics | `Export-MailboxDiagnosticLogs`, only when you use `-IncludeAssistantDiagnostics`. |
| Folder evidence | `Get-MailboxFolderStatistics`, only when you use `-IncludeFolderEvidence`. |
| Purview detail | `Get-RetentionCompliancePolicy`, only when you use `-IncludePurviewDetails`. |
| Permissions | Read access to the mailboxes you target. Remediation additionally requires `Enable-Mailbox`, `Set-Mailbox`, and the retention policy cmdlets. |

The module verifies these at startup and stops with a message naming the missing commands rather than
failing partway through a run.

## Install the module

1. Download the `MailboxMFAReport` folder from this directory.

2. Import it by path:

   ```powershell
   Import-Module .\MailboxMFAReport\MailboxMFAReport.psd1
   ```

3. Connect to the services you intend to use:

   ```powershell
   Connect-ExchangeOnline
   Connect-MgGraph -Scopes 'User.Read.All'          # omit if you use -SkipGraphChecks
   Connect-IPPSSession                              # only for -IncludePurviewDetails
   ```

4. Confirm the module loaded:

   ```powershell
   Get-Command -Module MailboxMFAReport
   ```

## Command reference

| Command | Writes to the tenant | Use it when |
|---|---|---|
| `Get-MailboxMFAReadiness` | **No** | You are investigating. Safe to run at any time. |
| `Start-MailboxMFAProcessing` | Starts the assistant only | You want the assistant to run now. |
| `Repair-MailboxMFAPrerequisite` | **Yes** | You are fixing what readiness reported as blocked. |

`Start-MailboxMFAReport` remains as a stub that throws a migration message. It was the single
combined command in the predecessor script and is retained so that existing calls fail loudly with
instructions instead of behaving differently than they used to.

### Parameters shared by the diagnostic commands

`Get-MailboxMFAReadiness` and `Start-MailboxMFAProcessing` accept the same evaluation parameters.

| Parameter | Description |
|---|---|
| `-Users` | One or more mailbox identities. Accepts pipeline input, including by property name. |
| `-RequiredHold` | Treats a mailbox as blocked unless it carries the specified hold. `None` (default), `Any`, `LitigationHold`, `MailboxOrOrgWideHold`, `LitigationHoldOrOrgWideHold`. |
| `-RequiredRetentionActions` | Retention actions that count as triggering the assistant. Defaults to all four. |
| `-SkipRetentionPolicyTriggerValidation` | Skips inspecting retention policy tags. Use when the retention cmdlets are unavailable. |
| `-RecipientTypeDetails` | Mailbox types to evaluate. `UserMailbox`, `SharedMailbox`, or both (default). |
| `-IncludeAssistantDiagnostics` | Collects and parses `Export-MailboxDiagnosticLogs` evidence. |
| `-IncludeFolderEvidence` | Collects per-folder tag, age, and Recoverable Items evidence. |
| `-IncludePurviewDetails` | Resolves Microsoft Purview retention policies that apply to the mailbox. |
| `-WorkCycleLagThreshold` | A `TimeSpan` above which work cycle lag is treated as a fault. See [Why lag is not a default signal](#why-lag-is-not-a-default-signal). |
| `-SkipGraphChecks` | Skips the license lookup and its Graph prerequisites. |
| `-OutputPath` | Directory for CSV artifacts. When omitted, nothing is written to disk. |
| `-IncludeJsonOutput` | Also writes structured JSON, preserving nested tag and policy objects. |
| `-CritSitMode` | Writes an additional wide CSV containing every diagnostic column, for escalation. |
| `-LogPath` | Transcript path. |
| `-Region` | Free-text label recorded on each result. |

## Validate the module against your tenant

> [!IMPORTANT]
> Do this before you rely on any output. The automated test suite runs entirely against stubs, and
> **those stubs encode assumptions** about what Exchange Online returns: property names, object
> shapes, identifier formats, and parameter types. If an assumption is wrong, every test still passes
> and the module still misreports.

`Tools\Test-MFAReportAssumption.ps1` tests those assumptions directly against a single mailbox. It is
read-only: it issues only `Get-*` calls and inspects cmdlet metadata.

1. Choose a mailbox that exercises as much as possible — one with an archive, a retention policy, and
   at least one hold.

2. Run the prober:

   ```powershell
   .\MailboxMFAReport\Tools\Test-MFAReportAssumption.ps1 -Identity user@contoso.com -IncludePurview
   ```

3. Review each result. Anything reported as `UNKNOWN` was not exercised by that mailbox and remains
   unverified — choose a different mailbox and run it again.

The assumptions most likely to be wrong, in rough order of risk:

1. **`RetentionPolicyTagLinks` normalization.** These are `ADObjectId` objects; the module takes the
   trailing `/` segment as the tag name. If that is wrong, retention trigger validation misreports.
2. **`Get-RetentionCompliancePolicy` exposes a usable `Guid`.** This drives confirmed Purview matching
   and hold-to-policy naming. If it is wrong, those features fail *silently* — they simply never fire.
3. **Hold identifier format.** If real identifiers do not decode to a 32-character hexadecimal GUID,
   hold naming and confirmed matching degrade to nothing. This degrades safely but uselessly.
4. **`Set-Mailbox -AutoExpandingArchive` is a switch.** If it is wrong, that one repair action breaks.
5. **Diagnostic log property and signal names.** If these are wrong, it shows up as a
   `DiagnosticParseConfidence` of `Low` rather than as a confidently wrong answer.

See `MailboxMFAReport\Tools\README.md` for what each check covers and what to do when one fails.

## Diagnose mailbox readiness

`Get-MailboxMFAReadiness` evaluates prerequisites and reports why the assistant will or will not
process each mailbox. It issues no write cmdlet.

### Check one mailbox

```powershell
Get-MailboxMFAReadiness -Users user@contoso.com
```

### Check a set of mailboxes and write reports

```powershell
Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt) -OutputPath C:\Temp\MFAReport
```

### Collect full evidence for an escalation

```powershell
Get-MailboxMFAReadiness -Users user@contoso.com `
    -IncludeAssistantDiagnostics -IncludeFolderEvidence -IncludePurviewDetails `
    -OutputPath C:\Temp\MFAReport -IncludeJsonOutput -CritSitMode
```

### Check mailboxes that must be on hold

```powershell
Get-MailboxMFAReadiness -Users user@contoso.com -RequiredHold LitigationHoldOrOrgWideHold
```

## Interpret the results

### The return shape

> [!NOTE]
> Each command returns **one run object**, not one object per mailbox. The per-mailbox records are in
> the `Results` property. Filtering the run object directly matches nothing.

```powershell
$run = Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt)

$run.RunId              # correlation ID for the whole run
$run.Summary            # counts by status and by blocked reason
$run.Results            # one record per mailbox   <-- filter here
$run.Artifacts          # paths of files actually written
```

```powershell
# Correct: filter the per-mailbox records.
$run.Results | Where-Object Status -eq 'Blocked' | Select-Object User, SkipReason, RecommendedNextAction
```

### Status values

| Status | Meaning |
|---|---|
| `Ready` | Evaluated successfully. Prerequisites are met. |
| `Blocked` | Evaluated successfully, **and we know why** the assistant will not process this mailbox. |
| `Skipped` | Could **not** be evaluated. The reason describes the lookup failure, not the mailbox. |
| `TriggeredAwaitingAssistant` | `Start-MailboxMFAProcessing` started the assistant for this mailbox. |
| `NotTriggered` | The assistant was not started, because the mailbox was blocked or you declined the prompt. |

> [!TIP]
> The distinction between `Blocked` and `Skipped` is deliberate. The predecessor script reported both
> identically, which made "this mailbox has no archive" indistinguishable from "we could not read this
> mailbox." Only `Blocked` results describe the mailbox; `Skipped` results describe the attempt.

### Blocked reasons

| `SkipReason` | What it means |
|---|---|
| `NoArchive` | No archive mailbox, so archive tags cannot move anything. |
| `NoRetentionPolicy` | The mailbox has no retention policy assigned. |
| `RetentionPolicyDoesNotTriggerMFA` | A policy is assigned, but none of its tags perform a retention action that would cause work. |
| `OrgElcDisabled` | ELC processing is disabled organization-wide. |
| `MailboxElcDisabled` | ELC processing is disabled on this mailbox. |
| `HoldRequirementNotMet` | You specified `-RequiredHold` and this mailbox does not carry it. |
| `NoLicense` | No license that entitles the mailbox to MRM processing. |

> [!NOTE]
> Retention hold is reported as a **health warning**, not as a blocked reason. Retention hold blocks
> expiration from user-visible folders, but the assistant may still process Recoverable Items, so
> treating it as a blocker would be wrong. Look for `RetentionHoldDetected` in the `Actions` column
> and validate the target workload before you change hold state.

### Skipped reasons

| `SkipReason` | What it means |
|---|---|
| `MailboxLookupFailed` | `Get-Mailbox` failed after retries. |
| `MailboxStatisticsFailed` | `Get-MailboxStatistics` failed after retries. |
| `LicenseLookupFailed` | The Graph license lookup failed. |
| `UnsupportedRecipientType` | The recipient type is outside `-RecipientTypeDetails`. |
| `SoftDeletedMailbox` | The mailbox is soft-deleted. |
| `EvaluationError` | An unanticipated error occurred. The run continued and the message is recorded. |

Every result also carries `RecommendedNextAction`, which names the specific command to run next.

## Start the Managed Folder Assistant

`Start-MailboxMFAProcessing` performs the same evaluation as `Get-MailboxMFAReadiness`, then starts
the assistant for mailboxes that are ready. It supports `-WhatIf` and `-Confirm`.

```powershell
# Preview first.
Start-MailboxMFAProcessing -Users user@contoso.com -WhatIf

# Then run it.
Start-MailboxMFAProcessing -Users user@contoso.com
```

| Parameter | Description |
|---|---|
| `-MfaMode` | `Standard` (default), `FullCrawl`, `HoldCleanup`, or `InactiveMailbox`. |
| `-Monitor` | Samples the mailbox after triggering to measure whether items actually moved. |
| `-DurationInMinutes` | Length of the monitoring window. Default `15`, range 1–1440. |
| `-CheckIntervalSeconds` | Interval between samples. Default `300`, range 1–86400. |

> [!NOTE]
> `-Monitor` applies to single-mailbox runs only. Movement is measured by sampling counters that
> cannot be attributed to an individual mailbox in a multi-mailbox run, so the command warns and
> declines rather than reporting a number it cannot substantiate. Results carry `MovementMeasured` so
> you can tell "no movement" apart from "not measured."

## Repair prerequisites

> [!WARNING]
> `Repair-MailboxMFAPrerequisite` writes to your tenant. Every action is opt-in through its own
> switch, and the command refuses to run when no action is selected. Preview with `-WhatIf` before
> every use.

```powershell
# Preview.
Repair-MailboxMFAPrerequisite -Users user@contoso.com -EnableArchive -WhatIf

# Apply.
Repair-MailboxMFAPrerequisite -Users user@contoso.com -EnableArchive
```

Feed blocked mailboxes from a diagnostic run into remediation:

```powershell
$run = Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt)

$run.Results |
    Where-Object { $_.Status -eq 'Blocked' -and $_.SkipReason -eq 'NoArchive' } |
    Repair-MailboxMFAPrerequisite -EnableArchive -WhatIf
```

| Parameter | Effect on the tenant |
|---|---|
| `-EnableArchive` | Enables the archive mailbox. |
| `-EnableAutoExpandingArchive` | Enables auto-expanding archiving. **Cannot be undone.** The confirmation prompt states this. |
| `-RetentionPolicyName` | Names the retention policy to create or modify. **No default.** |
| `-RetentionTag` | One or more hashtables, each requiring `Name`, `Type`, `RetentionAction`, and `AgeLimitForRetention`. |
| `-AssignPolicyToMailbox` | Assigns the named policy to each mailbox. |

```powershell
Repair-MailboxMFAPrerequisite -Users user@contoso.com `
    -RetentionPolicyName 'Contoso MRM Policy' `
    -RetentionTag @{
        Name                 = 'Contoso Archive 2 Years'
        Type                 = 'All'
        RetentionAction      = 'MoveToArchive'
        AgeLimitForRetention = 730
    } `
    -AssignPolicyToMailbox -WhatIf
```

> [!CAUTION]
> `-RetentionPolicyName` has no default value, deliberately. The predecessor script defaulted it to
> `Default MRM Policy`, which meant the default code path modified the tenant's built-in policy for
> every mailbox in the run. You must now name the policy you intend to change.

Retention tag and policy work runs **once per run**, not once per mailbox.

## Output files

When you supply `-OutputPath`, files are written with a `yyyyMMdd_HHmmss` stamp.

| File | Contents |
|---|---|
| `MFAReport_<timestamp>.csv` | Every mailbox evaluated. |
| `ReadyMailboxes_<timestamp>.csv` | `Ready`, `TriggeredAwaitingAssistant`, and `NotTriggered`. |
| `BlockedMailboxes_<timestamp>.csv` | `Blocked` and `Skipped`. |
| `MFAReportSummary_<timestamp>.csv` | Run-level counts. |
| `MFAReport_<timestamp>.json` | Structured results, with `-IncludeJsonOutput`. |
| `MFAReport_CritSit_<timestamp>.csv` | Every diagnostic column, with `-CritSitMode`. |
| `MFAReport_INPROGRESS_<runid>.csv` | Checkpoint, written as each mailbox completes and removed on success. |

Each mailbox appears in exactly one of the ready and blocked files. All CSVs are written as UTF-8;
Windows PowerShell 5.1 defaults `Export-Csv` to ASCII, which corrupts non-ASCII display names.

> [!TIP]
> If a run is interrupted, the checkpoint file survives and contains every mailbox completed up to
> that point. `$run.Artifacts` lists only files that were actually written, so a `-WhatIf` preview
> reports no artifacts.

## How the toolbox reaches its conclusions

Three rules govern the module. They exist to prevent the failure mode this toolbox was written to
remove: a report that is confidently wrong.

1. **Parsing never guesses.** Every parser returns `$null` for "undetermined." Callers must
   distinguish *known false* from *not measured*.
2. **Interpretation reads typed values, never raw text.** Classification never re-scans a diagnostic
   log; it reads values already parsed into booleans, counts, and time spans.
3. **Diagnosis never writes.** `Get-MailboxMFAReadiness` issues no write cmdlet, and an integration
   test enforces this by logging every write-capable call and asserting the log is empty.

### Parse confidence

Each result carries `DiagnosticParseConfidence` of `High`, `Medium`, or `Low`, reflecting how much of
the expected signal set was actually parsed. Treat a `Low` value as "this mailbox's diagnostics were
not readable," not as "this mailbox is healthy."

### Why lag is not a default signal

Work cycle lag is **not** a classifier unless you supply `-WorkCycleLagThreshold`. The healthy
baseline for that value is not documented, so treating any non-zero lag as a fault would manufacture
false positives. Supply a threshold once you know the baseline for your tenant.

### Holds and Purview

The mailbox's own `InPlaceHolds` value is authoritative about which compliance policies apply to it.
The toolbox decodes each hold identifier to the policy GUID it embeds and resolves that against the
retention compliance policies fetched for the run, so reports name a **policy** rather than an
identifier you have to chase manually. A GUID that matches no policy stays unnamed; nothing is
invented.

A policy whose GUID appears in the mailbox's active holds is reported as **confirmed** applied,
regardless of what `ExchangeLocation` says. Policies matched only by location remain **inferred** and
are reported as such. Policies that cannot be resolved either way are reported as *not evaluated*
rather than silently treated as non-applicable.

Holds that explicitly **exclude** the mailbox — those with a `-` prefix or a `:2` suffix — are
excluded from the GUID set, so a policy that excludes a mailbox can never confirm itself against it.

### Throttling and retries

Transient service failures — throttling, timeouts, connection resets — are retried with exponential
backoff and full jitter. Terminal errors are **not** retried, so a stale identity list does not
multiply the runtime of a large run.

## Troubleshoot the toolbox

| Symptom | Cause | Resolution |
|---|---|---|
| `Missing required commands: ...` | A required module is not imported or connected. | Connect the named service, or use `-SkipGraphChecks` / `-SkipRetentionPolicyTriggerValidation`. |
| A filter over the command output returns nothing | You filtered the run object instead of `.Results`. | Filter `$run.Results`. See [The return shape](#the-return-shape). |
| `DiagnosticParseConfidence` is `Low` everywhere | Diagnostic log signal names differ in your tenant. | Run the assumption prober. Do not treat the results as healthy. |
| Many mailboxes report `Skipped` | Lookups are failing, often permissions or throttling. | Read the `Message` column; it carries the underlying error. |
| `Inconclusive` Purview signal | Policies could not be resolved to the mailbox. | Add `-IncludePurviewDetails` and connect with `Connect-IPPSSession`. |
| Purview policy names never appear | `Get-RetentionCompliancePolicy` did not expose a usable `Guid`. | Run the assumption prober; this failure is otherwise silent. |
| A run was interrupted | Network drop or cancellation. | Use `MFAReport_INPROGRESS_<runid>.csv`; it holds everything completed so far. |

## Run the tests

The module ships with a Pester suite covering every behavioral fix.

```powershell
Invoke-Pester -Path .\MailboxMFAReport\Tests
```

```powershell
Invoke-ScriptAnalyzer -Path .\MailboxMFAReport -Recurse `
    -Settings .\MailboxMFAReport\PSScriptAnalyzerSettings.psd1
```

> [!NOTE]
> A green test suite proves the module is internally consistent. It does **not** prove the module's
> assumptions about Exchange Online are correct — that is what the assumption prober is for. See
> [Validate the module against your tenant](#validate-the-module-against-your-tenant).

## Known limitations

- **Windows PowerShell 5.1 only.** PowerShell 7 is untested.
- **No parallelism.** Parallel execution was deliberately not implemented: it requires one Exchange
  Online connection per runspace, which spends the same throttling budget it is meant to save, and it
  breaks confirmation prompting.
- **`-Monitor` is single-mailbox only**, for the attribution reason described above.
- **Purview resolution depends on a usable policy `Guid`.** Where that is unavailable, confirmed
  matching degrades to inferred matching.

## Disclaimer

The sample scripts in this directory are not supported under any Microsoft standard support program
or service. They are provided **as is** without warranty of any kind. Microsoft disclaims all implied
warranties including, without limitation, any implied warranties of merchantability or of fitness for
a particular purpose. The entire risk arising out of the use or performance of the sample scripts and
documentation remains with you. In no event shall Microsoft, its authors, or anyone else involved in
the creation, production, or delivery of the scripts be liable for any damages whatsoever (including,
without limitation, damages for loss of business profits, business interruption, loss of business
information, or other pecuniary loss) arising out of the use of or inability to use the sample
scripts or documentation, even if Microsoft has been advised of the possibility of such damages.

Test in a non-production environment before you use these scripts against production mailboxes.
