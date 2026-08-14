# MailboxMFAReport

Diagnoses why the Managed Folder Assistant (MFA) is or is not processing Exchange Online mailboxes.

Successor to `Start-MFAReport_v0.10.ps1`, which is deliberately not published here: it is superseded
and carries the defects listed in `ReleaseNotes`. See `ReleaseNotes` in `MailboxMFAReport.psd1` for
the full list of behavioural fixes.

For task-oriented documentation aimed at operators, see [the MFA-Toolbox README](../README.md). This
file documents the module's internals and is aimed at anyone changing it.

## Design rules

Three rules hold the module together. Breaking any of them reintroduces the class of defect this
rewrite exists to remove -- a report that is confidently wrong.

1. **Parsing never guesses.** Every parser returns `$null` for "undetermined". Callers must
   distinguish *known false* from *not measured*.
2. **Interpretation reads typed values, never raw text.** Classification never re-scans a diagnostic
   log; it reads values already parsed into booleans, counts, and timespans.
3. **Diagnosis never writes.** `Get-MailboxMFAReadiness` issues no write cmdlet, and an integration
   test enforces this by logging every write-capable stub call and asserting the log is empty.

## Commands

| Command | Writes to tenant | Use when |
|---|---|---|
| `Get-MailboxMFAReadiness` | **No** | Investigating. Always safe to run. |
| `Start-MailboxMFAProcessing` | Starts the assistant only | You want MFA to run now. |
| `Repair-MailboxMFAPrerequisite` | **Yes** | Fixing what readiness reported as blocked. |

`Start-MailboxMFAReport` is a stub that throws a migration message.

## Before you trust it: check the assumptions

The test suite runs entirely against stubs, and **those stubs are assumptions about what Exchange
Online returns** -- property names, object shapes, identifier formats, parameter types. If an
assumption is wrong, every test still passes and the module still misbehaves.

`Tools\Test-MFAReportAssumption.ps1` tests those assumptions directly against one mailbox. It is
read-only: only `Get-*` calls and cmdlet metadata. See [Tools\README.md](Tools/README.md) for what
each check covers and what to do when one fails.

```powershell
.\MailboxMFAReport\Tools\Test-MFAReportAssumption.ps1 -Identity user@contoso.com -IncludePurview
```

Pick a mailbox that exercises as much as possible -- one with an archive, a retention policy, and at
least one hold. Anything it reports as `UNKNOWN` was not exercised by that mailbox and is still
unverified.

The assumptions most likely to be wrong, in rough order of risk:

1. **`RetentionPolicyTagLinks` normalisation.** These are `ADObjectId` objects; the module takes the
   trailing `/` segment as the tag name. Wrong here means retention trigger validation misreports.
2. **`Get-RetentionCompliancePolicy` exposes a usable `Guid`.** This drives the `Confirmed` match
   tier and hold-to-policy naming. Wrong here fails *silently* -- the features simply never fire.
3. **Hold identifier format.** If real identifiers do not decode to a 32-hex GUID, hold naming and
   confirmed matching degrade to nothing (safely, but uselessly).
4. **`Set-Mailbox -AutoExpandingArchive` is a switch.** Wrong here breaks that one repair action.
5. **Diagnostic log property and signal names.** Wrong here shows up as `DiagnosticParseConfidence`
   of `Low` rather than as a wrong answer.

## Quick start

```powershell
Connect-ExchangeOnline
Import-Module .\MailboxMFAReport\MailboxMFAReport.psd1

# Safe first contact: read-only, one mailbox.
Get-MailboxMFAReadiness -Users user@contoso.com

# Population sweep with artifacts and an escalation handoff file.
Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt) -OutputPath C:\temp -CritSitMode

# Deep evidence for a specific problem mailbox.
Get-MailboxMFAReadiness -Users user@contoso.com -IncludeAssistantDiagnostics -IncludeFolderEvidence -IncludePurviewDetails

# Trigger, then measure whether anything actually moved.
Start-MailboxMFAProcessing -Users user@contoso.com -Monitor -IncludeAssistantDiagnostics

# Remediate only what the report proved was broken. Preview first.
# Note the .Results -- the cmdlet returns a run object (RunId/Summary/Results/Artifacts),
# and it is the records inside Results that pipe into the repair cmdlet.
(Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt)).Results |
    Where-Object SkipReason -eq 'NoArchive' |
    Repair-MailboxMFAPrerequisite -EnableArchive -WhatIf
```

## What the cmdlets return

`Get-MailboxMFAReadiness` and `Start-MailboxMFAProcessing` return one run object per run, not a
stream of per-mailbox records:

| Property | Contents |
|---|---|
| `RunId` | Correlates the run with its artifacts and log lines. |
| `Summary` | Counts by status, plus the top blocking reasons. |
| `Results` | One record per mailbox. **This is what you filter and pipe.** |
| `Artifacts` | Paths of any CSV/JSON files written, when `-OutputPath` was supplied. |

```powershell
$run = Get-MailboxMFAReadiness -Users (Get-Content .\mailboxes.txt)
$run.Summary
$run.Results | Where-Object Status -eq 'Blocked' | Format-Table User, SkipReason, RecommendedNextAction
```

## Status values

| Status | Meaning |
|---|---|
| `Ready` | Every prerequisite checked is satisfied. |
| `Blocked` | Evaluated, and the reason MFA will not process it is known. See `SkipReason` and `RepairSuggestions`. |
| `Skipped` | Could not be evaluated -- lookup, licensing, or statistics access failed. |
| `TriggeredAwaitingAssistant` | Assistant started. Asynchronous; this does not prove completion. |
| `NotTriggered` | Was `Ready`, but the start did not happen (declined, `-WhatIf`, or failed). |

`Blocked` vs `Skipped` is the distinction v0.10 lacked: it reported both as `Skipped`, so
"no archive" and "could not read this mailbox" looked identical in the output.

## Reading the output

`DiagnosticClassification` and `RecommendedNextAction` are the two fields to read first.

### Confidence, and where it comes from

Purview matches carry a `MatchConfidence`:

| Value | Meaning |
|---|---|
| `Confirmed` | The policy's GUID appears in the mailbox's own `InPlaceHolds`. Exchange is stating the policy is applied -- this is evidence, not inference. |
| `High` | The policy is organization-wide (`ExchangeLocation = All`) or names this mailbox explicitly. |
| `Unknown` | Scoped to recipients that could not be resolved from this run. Reported under `NotEvaluatedPurviewPolicies`. |

A non-zero `NotEvaluated` count means coverage is **incomplete**, not that those policies don't
apply -- absence of a match is not proof of absence. `PurviewOverrideSignal` reflects this: it says
`PurviewOverride:` for confirmed matches and `PossiblePurviewOverride:` for inferred ones, and never
hedges something it knows.

Hold identifiers are decoded into scope, state, and the embedded policy GUID. When Purview policies
have been fetched (`-IncludePurviewDetails`), holds are resolved to policy *names* and surfaced in
`MailboxContext` as `ResolvedHoldPolicies`. A hold whose GUID matches nothing stays unnamed rather
than being guessed at, and an identifier shape the decoder does not recognise reports as
`UnknownHoldType` rather than being forced into a category.

Still genuinely advisory -- treat as leads, not conclusions:

- Anything derived from `Export-MailboxDiagnosticLogs`. The log schema is undocumented and changes.
  Check `DiagnosticParseConfidence` (`High`/`Medium`/`Low`); `Low` means almost nothing parsed and
  the classification rests on very little.
- Preservation-lock detection beyond `RestrictiveRetention`, which is the only documented property;
  the other names checked are defensive fallbacks.

`MailboxHealthWarnings` holds genuine problems. Informational values live in `MailboxContext` -- v0.10
mixed the two, which made every mailbox report a warning.

## Safety

- `-RetentionPolicyName` has **no default**. v0.10 defaulted it to `Default MRM Policy`, so the
  default path modified the tenant's built-in policy.
- Retention tags require a full specification; there is no hardcoded tag shape.
- Enabling auto-expanding archiving is **irreversible** and the prompt says so.
- Every repair action is opt-in by its own switch; the cmdlet refuses to run with none selected.
- Run `Repair-MailboxMFAPrerequisite -WhatIf` first.

## Long runs

Tenant-wide lookups (retention policies, tags, Purview policies) are fetched **once per run**, not
once per mailbox. Transient service failures (throttling, timeouts) are retried with exponential
backoff and jitter; terminal errors are not retried. Results are checkpointed to
`MFAReport_INPROGRESS_<runid>.csv` as each mailbox completes and the file is removed on success, so
a run interrupted at mailbox 400 of 500 keeps its first 399 results.

### Why there is no `-Parallel`

v0.10 declared `-Parallel` and `-ThrottleLimit`, validated them, warned about them, and did nothing
with them. They are removed rather than reimplemented.

Real parallelism here needs a separate Exchange Online connection per runspace (sessions are not
thread-safe), which multiplies connection count against the same throttling budget that motivated
parallelism, and breaks `ShouldProcess` prompting from worker runspaces. It also cannot be verified
without a tenant. Per-run caching plus retry and checkpointing address the actual failure mode --
long runs dying partway -- more directly and with far less risk. If parallelism is genuinely needed
later, it should be built and measured against a real tenant, not inferred.

## Development

```powershell
Invoke-Pester -Path .\MailboxMFAReport\Tests
Invoke-ScriptAnalyzer -Path .\MailboxMFAReport -Recurse -Settings .\MailboxMFAReport\PSScriptAnalyzerSettings.psd1
```

Tests stub every Exchange and Graph call, so the suite runs with no tenant and no connection.

Layout: `Public/` holds the exported cmdlets, `Private/` the implementation.
`Private/Evaluation.ps1` is the read-only path and must stay write-free; every tenant write belongs
in `Private/Remediation.ps1`.

The module runs under `Set-StrictMode -Version 3.0`, which throws on missing hashtable keys as well
as missing object properties. Read optional Exchange properties through
`Get-MFAReportPropertyValue`, and initialise every hashtable key you intend to read.

## Status

Windows PowerShell 5.1. **Not yet run against a real tenant** -- all validation to date is against
stubs. Begin with `Get-MailboxMFAReadiness`, which cannot write.
