# MailboxMFAReport Tools

Operator utilities that support the module but are not part of it. Nothing here is exported; these
are scripts you run by path.

| Script | Writes to tenant | Purpose |
|---|---|---|
| `Test-MFAReportAssumption.ps1` | **No** | Verifies the Exchange Online assumptions the module is built on. |

---

# Test-MFAReportAssumption.ps1

## Why this exists

The module ships with 212 Pester tests that all pass. They run entirely against **stubs** -- fake
Exchange Online objects defined in the test files.

Those stubs are assumptions. They encode what someone *believed* Exchange Online returns: which
properties exist, how identifiers are formatted, whether a parameter is a switch or a boolean. The
tests verify that the module's logic is correct **given those assumptions**.

If an assumption is wrong, every test still passes and the module still produces wrong output. The
test suite cannot catch this, because the test suite is built from the same assumptions.

This script checks the assumptions themselves, against a real tenant.

**Run it before trusting anything `Get-MailboxMFAReadiness` tells you.**

## Safety

Read-only. It issues only `Get-*` calls and reads cmdlet metadata via `Get-Command`. It never calls
`Set-`, `New-`, `Enable-`, or `Start-`, and it touches only the one mailbox you name.

The `Set-Mailbox -AutoExpandingArchive` check reads the parameter's *type* from cmdlet metadata. It
does not invoke `Set-Mailbox`.

## Prerequisites

```powershell
Connect-ExchangeOnline
Connect-IPPSSession      # only needed for -IncludePurview
```

Graph is not required. Checks for unavailable cmdlets report `SKIP`, not `FAIL`.

## Running it

```powershell
.\Test-MFAReportAssumption.ps1 -Identity user@contoso.com -IncludePurview
```

### Choose the mailbox carefully

The script can only verify what the mailbox exercises. A mailbox with no holds cannot tell you
whether hold decoding works -- that check reports `UNKNOWN`.

Pick one that has, ideally, all of:

- an archive (`ArchiveState` is `HostedProvisioned`)
- an assigned retention policy with linked tags
- **at least one entry in `InPlaceHolds`** -- this is the one people most often miss, and it gates
  two of the highest-risk checks

If no single mailbox has everything, run it two or three times against different mailboxes.

### Parameters

| Parameter | Required | Notes |
|---|---|---|
| `-Identity` | Yes | One mailbox to inspect. |
| `-RetentionPolicyName` | No | Policy whose tag links to inspect. Defaults to the one assigned to `-Identity`. |
| `-IncludePurview` | No | Adds Purview checks. Needs `Connect-IPPSSession`; `Get-RetentionCompliancePolicy` is slow on large tenants. |

## Reading the results

| Result | Meaning |
|---|---|
| `PASS` | The assumption holds. |
| `FAIL` | The assumption is wrong. The named module behaviour will not work correctly. |
| `WARN` | Holds partially, or holds with a caveat worth reading. |
| `UNKNOWN` | Could not be determined -- usually nothing in the tenant to test against. **Not the same as PASS.** |
| `SKIP` | The relevant cmdlet is not available in this session. |

Failures are reprinted at the end with their impact. The script also returns the full result set as
objects, so you can capture it:

```powershell
$r = .\Test-MFAReportAssumption.ps1 -Identity user@contoso.com -IncludePurview
$r | Export-Csv .\assumptions.csv -NoTypeInformation -Encoding UTF8
```

## What each check covers

Ordered by how much damage a wrong assumption does.

### 1. Retention policy tag links (highest risk)

`RetentionPolicyTagLinks` returns `ADObjectId` objects, not strings. The module normalises them by
taking the trailing `/` segment. This is the exact bug the rewrite fixed in the original script -- but
the fix was written against a *guess* at the string form.

The check takes real links, normalises them, and confirms each result resolves via
`Get-RetentionPolicyTag`.

**On FAIL:** retention trigger validation misreports, so mailboxes may be marked `Blocked` with
`RetentionPolicyDoesNotTriggerMFA` when their policy is fine. Fix `ConvertTo-MFAReportTagLinkName`
in `Private\Retention.ps1` -- the `Detail` column shows the raw and normalised forms.

### 2. Purview policy GUID -- *fails silently*

`Get-RetentionCompliancePolicy` must expose a usable `Guid`. It drives the `Confirmed` match tier and
hold-to-policy naming.

**On FAIL:** no error appears anywhere. Those features just never fire. Confirmed matches show as
`Inconclusive` and holds stay as opaque identifiers, with nothing explaining why. Fix the property
list in `Get-MFAReportPurviewPolicyMatch` and `Resolve-MFAReportHoldPolicyName`.

### 3. Hold identifier format -- *fails silently*

The module expects `InPlaceHolds` entries to decode to a 32-character hex GUID after stripping the
exclusion prefix (`-`), the include/exclude suffix (`:1` / `:2`), and the type prefix (`mbx`, `skp`,
`grp`, `cld`, `UniH`).

**On FAIL:** the `Detail` column shows what the decoder was left with. Hold naming and confirmed
Purview matching degrade to nothing -- safely, but uselessly. Fix `Get-MFAReportHoldPolicyGuid` in
`Private\Holds.ps1`.

**On UNKNOWN:** the mailbox has no holds. Re-run against one that does.

### 4. `Set-Mailbox -AutoExpandingArchive` parameter type

The module calls it as a bare switch.

**On FAIL:** `Repair-MailboxMFAPrerequisite -EnableAutoExpandingArchive` errors. Loud, not silent,
and limited to that one action. Fix `Repair-MFAReportAutoExpandingArchive` in
`Private\Remediation.ps1`.

### 5. Mailbox and organization properties

Required properties report `FAIL` if absent. Optional ones report `WARN` -- the module reads every
optional property through a safe accessor that returns `$null`, so absence degrades a specific check
rather than breaking the run.

### 6. Statistics shape

`TotalItemSize` should render as `1.5 GB (1,610,612,736 bytes)`. A `WARN` means the parenthesised
byte count was missing and the value fell back to unit parsing -- check the value was read correctly.

### 7. Diagnostic log shape

The lowest-stakes check, because the module already treats this evidence as advisory. A `WARN` or
`FAIL` shows up in normal output as `DiagnosticParseConfidence: Low`, which is the module correctly
telling you its classification rests on very little.

## What this does NOT check

Shapes, not behaviour. It cannot tell you:

- whether `Start-ManagedFolderAssistant` does what you expect
- how the tenant throttles under a several-hundred-mailbox sweep (exercises the retry and
  checkpoint paths)
- whether your RBAC covers the remediation cmdlets
- whether the diagnostic log *values* mean what the module assumes, only that the names appear

Those only surface in a real staged run. See the main [README](../README.md) for the suggested
sequence: read-only single mailbox, then depth, then small batch, then `-WhatIf`, then live.

## If something fails

The `Detail` column carries the actual observed value, which is usually enough to correct the
assumption directly. Capture the output and the fix is normally a few lines in one private function
plus a test fixture updated to match reality.
