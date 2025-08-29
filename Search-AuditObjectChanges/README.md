# Search-UnifiedAuditEvent

**Find object-related changes in the Microsoft 365 Unified Audit Log** with smart `RecordType` inference, stable output columns, and mailbox-focused defaults.

- **Fast path**: targeted, high-signal filters with multi-pass server-side queries  
- **Minimal-call option**: one broad call across all RecordTypes  
- **Stable schema**: consistent columns for easy export/automation  
- **Mailbox-first defaults**: item deletes + lean admin ops (expandable)

> **Compatibility**: Windows PowerShell **5.1** compatible (no PowerShell 7-only syntax)

---

## Why this function?

Admins often need to answer: **“Who changed WHAT, and WHEN?”** across mailboxes, distribution lists, and Entra ID (M365) groups. `Search-UnifiedAuditEvent` wraps `Search-UnifiedAuditLog` with sensible defaults and sharp filters to dramatically reduce noise, guess the right `RecordType(s)`, and standardize the output so it’s **predictable for humans and scripts**.

---

## Key Features

- **Smart record-type inference**  
  Infers the correct `RecordType` from your selector (e.g., `-Mailbox`, `-DistributionGroup`, `-GroupId`) and/or supplied `-Operations`.

- **Stable output schema**  
  Always returns:  
  `LocalTimeZoneId, WhenLocal, WhenUtc, Workload, RecordType, Operation, Actor, Object, Subjects, ClientIP, [Member], [Modified]`.

- **Mailbox-focused defaults**  
  When you pass `-Mailbox` (without explicit ops), it returns **item-level mailbox operations** (deletes/moves) **and** a **lean** set of mailbox **admin** operations. Widen coverage via `-AdminOpsMode Broad|All` and/or `-ExtraOperations`.

- **Flexible time inputs**  
  Accepts **UTC** (`-StartDate/-EndDate`) or **local window** (`-StartDateLocalTz/-EndDateLocalTz`) and converts with `-LocalTimeZoneId` (shows friendly “ID (abbrev)” like `Central Standard Time (CDT)`).

- **Server-side actor filters**  
  Use `-UserIds` for scalable “what did X do?” queries. Optional `-ActorLike` is a client-side contains filter when server-side isn’t feasible.

- **Two strategies**  
  - `InferMultiPass` *(default)*: faster, focused server-side passes  
  - `AllTypesSingleCall`: one broad call (fewest API calls)

- **Graceful retry**  
  `-ExpandIfEmpty` optionally re-runs the query extending the window back 3 more days if nothing is found.

---

## Prerequisites

- **Exchange Online PowerShell** (for `Search-UnifiedAuditLog`, `Get-Mailbox`, `Get-DistributionGroup`)
- Appropriate **audit licensing/retention** and **permissions**

> Typical setup in a session:
```powershell
# Install/Update EXO V3 if needed
Install-Module ExchangeOnlineManagement -Scope CurrentUser

# Connect to EXO
Connect-ExchangeOnline

# Dot-source the function or import your module
. .\Search-UnifiedAuditEvent.ps1
# or
Import-Module .\YourModule.psd1
```

---

## Quick Start

### 1) Past 24 hours of distribution group changes
```powershell
Search-UnifiedAuditEvent -DistributionGroup 'notgolfers@contoso.com'
```

### 2) Mailbox deletes + common mailbox admin ops (fast defaults)
```powershell
Search-UnifiedAuditEvent -Mailbox 'wsobchak' `
  -StartDateLocalTz (Get-Date).AddHours(-12) `
  -EndDateLocalTz (Get-Date)
```

### 3) Broaden mailbox admin coverage (no manual ops list)
```powershell
Search-UnifiedAuditEvent -Mailbox 'wsobchak' -AdminOpsMode Broad
```

### 4) Max admin coverage for a specific actor
```powershell
Search-UnifiedAuditEvent -Mailbox 'wsobchak' `
  -AdminOpsMode All `
  -UserIds 'ch.adm@contoso.com' `
  -StartDate (Get-Date).AddHours(-6).ToUniversalTime() `
  -EndDate (Get-Date).ToUniversalTime()
```

### 5) Reduce API calls: single broad pass
```powershell
Search-UnifiedAuditEvent -Mailbox 'shared@contoso.com' `
  -RecordTypeStrategy AllTypesSingleCall `
  -ResultSize 5000
```

### 6) CSV export with predictable columns
```powershell
Search-UnifiedAuditEvent -Mailbox 'wsobchak' |
  Select LocalTimeZoneId,WhenLocal,WhenUtc,Workload,RecordType,Operation,Actor,Object,Subjects,ClientIP,Member,Modified |
  Export-Csv .\audit.csv -NoTypeInformation
```

---

## Output Schema

Each row is a `[PSCustomObject]` with the following columns:

- **LocalTimeZoneId**: Windows time zone ID + current abbreviation (e.g., `Central Standard Time (CDT)`)  
- **WhenLocal**: Time converted to your `-LocalTimeZoneId`  
- **WhenUtc**: Original event UTC timestamp  
- **Workload**: Source workload (e.g., Exchange, AzureActiveDirectory)  
- **RecordType**: UAL record type (e.g., `ExchangeAdmin`, `ExchangeItem`)  
- **Operation**: The specific operation name from the log  
- **Actor**: Primary actor UPN (best-effort across multiple fields)  
- **Object**: The target object label (best-effort from Identity/TargetResources/ObjectId/Owner)  
- **Subjects**: For mailbox item ops, concatenated item subjects (if present)  
- **ClientIP**: Client IP address when present (best-effort from `ClientIP`/`IPAddress`)  
- **Member** *(optional)*: Member principal for DL membership operations  
- **Modified** *(optional)*: Concise “Name: old → new” trail for admin/config operations

---

## Parameters (Reference)

- **`-Mailbox <String>`**  
  Mailbox identity. Without `-Operations`/`-RecordType`, searches `ExchangeItem` **and** a **lean** set of `ExchangeAdmin` mailbox ops (tunable via `-AdminOpsMode`).

- **`-SubjectLike <String>`**  
  Client-side contains filter for item-level results (when `-Mailbox` set).

- **`-DistributionGroup <String>`**  
  Distribution Group identity (SMTP/Name/Alias/DisplayName/LegacyDN). Searches `ExchangeAdmin`.

- **`-GroupId <String>`**  
  Entra ID (M365) Group **GUID**. Searches `AzureActiveDirectory`.

- **`-Operations <String[]>`**  
  Explicit operations (e.g., `'Set-Mailbox','SoftDelete'`). If you mix ops across record types, the function automatically splits into focused passes.

- **`-RecordType <String>`**  
  Force a specific record type (e.g., `ExchangeAdmin`, `ExchangeItem`, `AzureActiveDirectory`). Skips inference.

- **`-UserIds <String[]>`**  
  Server-side **actor filter** (UPN list). Strongly recommended for “what did X do?” scenarios.

- **`-ResultSize <Int>`**  
  Page size for `Search-UnifiedAuditLog` (e.g., `5000`).

- **`-StartDate/-EndDate <DateTime>`**  
  **UTC** window. Defaults to `now−1 day .. now (UTC)` if not provided.

- **`-StartDateLocalTz/-EndDateLocalTz <DateTime>`**  
  **Local** window inputs (converted to UTC using `-LocalTimeZoneId`). **Do not** combine with the UTC variants.

- **`-LocalTimeZoneId <String>`**  
  Windows TZ ID for conversion/presentation (default: current host). Output shows `"<Id> (<abbrev>)"`.

- **`-LocalTimeAbbrev <String>`**  
  Optional override for the abbreviation displayed with `-LocalTimeZoneId`.

- **`-ActorLike <String>`**  
  Client-side contains filter on actor UPN. Prefer `-UserIds` when possible.

- **`-AdminOpsMode <Lean|Broad|All>`** *(Mailbox set & no `-Operations`)*  
  - **Lean** *(default)*: `Set-Mailbox` + common mailbox/recipient permission ops (fast).  
  - **Broad**: adds CAS, autoreply, calendar, regional config, folder-perm ops.  
  - **All**: **no** `ExchangeAdmin` ops filter (heaviest; pair with `-UserIds` and tight time windows).

- **`-ExtraOperations <String[]>`**  
  Extra **admin** ops to include for mailbox scenarios (except when `AdminOpsMode=All`).

- **`-RecordTypeStrategy <InferMultiPass|AllTypesSingleCall>`**  
  - **InferMultiPass** *(default)*: focused calls per inferred `RecordType` (faster).  
  - **AllTypesSingleCall**: single broad call with no `RecordType` filter (fewest calls, might be slower).

- **`-ExpandIfEmpty`**  
  If no results, automatically re-run with `StartDate` extended **back 3 days**.

- **`-ReturnRaw`**  
  Return raw `Search-UnifiedAuditLog` records (skip shaping).

---

## Behavior & Design Notes

- **Default time window**: `now − 1 day → now (UTC)`  
- **Local time decoration**: `LocalTimeZoneId` shows the Windows ID **and** an abbreviation—e.g., `Central Standard Time (CDT)`  
- **Performance** (large tenants): strongly prefer **`-UserIds`** and **tight windows**  
- **Op catalogs** (built-in filters):  
  - `ExchangeItem`: `MoveToDeletedItems`, `SoftDelete`, `HardDelete`, `RecordDelete`, `UpdateInboxRules`, `SendOnBehalf`  
  - `ExchangeAdmin`: Common mailbox/DL ops (see code for catalog; widen via `-AdminOpsMode Broad|All` and `-ExtraOperations`)  
  - `AzureActiveDirectory`: typical group/user update and membership ops
- **Inference**: When you pass `-Mailbox`, the function will search both item operations and mailbox admin ops (unless you explicitly constrain with `-Operations` or a forced `-RecordType`).

---

## Examples (Expanded)

### DL membership deltas by a known actor in the last 6 hours
```powershell
$utcStart = (Get-Date).AddHours(-6).ToUniversalTime()
$utcEnd   = (Get-Date).ToUniversalTime()

Search-UnifiedAuditEvent -DistributionGroup 'notgolfers@contoso.com' `
  -UserIds 'helpdesk@contoso.com' `
  -StartDate $utcStart -EndDate $utcEnd
```

### Mailbox item deletes filtered by subject contains
```powershell
Search-UnifiedAuditEvent -Mailbox 'jane.doe@contoso.com' -SubjectLike 'Quarterly Results'
```

### Entra ID group configuration changes for a specific GroupId
```powershell
Search-UnifiedAuditEvent -GroupId '00000000-0000-0000-0000-000000000000'
```

### Broad admin scan with a safe time window (All admin ops)
```powershell
Search-UnifiedAuditEvent -Mailbox 'shared@contoso.com' `
  -AdminOpsMode All `
  -StartDate (Get-Date).AddHours(-2).ToUniversalTime() `
  -EndDate (Get-Date).ToUniversalTime()
```

### Return raw records for custom parsing
```powershell
Search-UnifiedAuditEvent -Mailbox 'wsobchak' -ReturnRaw
```

---

## Known Limitations & Tips

- **Unified Audit Log latency**: Some events appear with a delay. Use `-ExpandIfEmpty` or widen your window if you expect activity that isn’t yet visible.
- **Hybrid/On-Prem**: Only actions recorded by the **Microsoft 365 Unified Audit Log** will appear.
- **Noise control**: Prefer `-UserIds` and the default `InferMultiPass` strategy for larger tenants.
- **Subject capture**: `Subjects` is best-effort from mailbox item events (`AffectedItems.Subject`) and may be blank depending on event type.

---

## Disclaimer

This function is a **community convenience script** and is **not** an official Microsoft-supported tool.  
It is provided **“as is”** with **no warranties**. Test in **non-production** first and review outputs before acting.

---

## Version History
Author: cuhaafke
- 29 Sep 2025 | v_0.9 - Initial release (Alpha).

---

## Contributing / Feedback

- Open issues/PRs in your repo.  
- Share real-world scenarios where additional op catalogs or shaping would help.  
- If a future enhancement requires PowerShell 7+, the function will call it out explicitly.

---

## Appendix: Installing & Updating (Suggested)

```powershell
# One-time (current user):
Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force

# Per session:
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline

# Load the function
. .\Search-UnifiedAuditEvent.ps1
```

---

#
