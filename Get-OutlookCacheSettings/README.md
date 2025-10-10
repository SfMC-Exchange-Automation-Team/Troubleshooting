# Get-OutlookCacheSettings: Technical Guide
Written by Copilot - Please report any concerns to the author listed below.

> **Version:** 1.2.0 (2025-10-10)  
> **Author:** Cullen Haafke  
> **Compatibility:** Windows PowerShell 5.1  
> **Scope:** Registry audit (policy and user), per-profile flags, optional Outlook COM (per-store cache state)  
> **Support:** Provided **AS IS**; **not** a Microsoft-supported tool unless explicitly stated  

---

## Summary

`Get-OutlookCacheSettings` audits Outlook Cached Exchange Mode configuration by enumerating policy and user registry values (e.g., `Enable`, `CacheOthersMail`, `SyncWindowSetting`, `NoOST`) and the per-profile flag `00036601`. Optionally, it queries live Outlook via **COM** to report per-store `IsCachedExchange` state. It supports output to the terminal (default **TABLE**) or file export (**CSV/XML**), with optional **PassThru** and a **Value Explanation** column for quick interpretation.

Exports are written to:  
`C:\temp\OutlookCacheSettingsResults\<dd-MMM-yyyy>\OutlookCacheSettings - <dd-MMM-yyyy--HHmm>.<csv|xml>`

> The script file can be dot-sourced to load the function globally. When invoked with `-RunFunction`, it executes the function immediately (suitable for automation and scale-out).

---

## Key Scenarios & Outcomes

- **Baseline audit**: Confirm if Cached Exchange Mode is enforced via policy and/or enabled at the profile level (`00036601`).
- **Pre‑migration validation**: Validate Cached Mode and sync window before moving mailboxes to EXO; identify Online Mode stores.
- **Shared mailbox posture**: Assess `CacheOthersMail` policy and per-store cache state for shared stores.
- **Compliance reporting**: Export CSV/XML for enterprise dashboards and compliance baselines (SCCM/Intune).
- **Troubleshooting**: Rapidly detect misaligned policy keys, profile flags, or Outlook COM session readiness issues.

---

## Prerequisites

- **OS & PowerShell**: Windows + **Windows PowerShell 5.1**
- **Rights**: Runs under the current user; requires read access to HKCU; HKLM policy reads require read permissions
- **Outlook dependency (if COM is used)**:
  - Outlook (classic) installed and profile present
  - User session context (HKCU hive loaded); Outlook MAPI session initialized (script includes readiness wait)
- **Network & remote execution (for scale)**:
  - WinRM enabled for PowerShell remoting
  - SMB share access if centralizing exports
  - For ConfigMgr/Intune deployment, ensure client is healthy and can run user-context scripts when enforcing HKCU policy

---

## Parameters

> **Script wrapper parameters**  
> `param([switch]$RunFunction, [ValidateSet('TABLE','CSV','XML')][string]$Output='TABLE', [string]$OutputRoot, [switch]$PassThru, [switch]$IncludeMeaning, [switch]$UseOutlookCom, [switch]$StoresFlat)`

> **Function parameters**  
> `function global:Get-OutlookCacheSettings([switch]$UseOutlookCom, [switch]$IncludeMeaning, [switch]$StoresFlat, [ValidateSet('TABLE','CSV','XML')][string]$Output='TABLE', [string]$OutputRoot, [switch]$PassThru)`

| Name           | Type    | Default                                                | Description (Value Explanation)                                                                 | Notes |
|----------------|---------|--------------------------------------------------------|--------------------------------------------------------------------------------------------------|-------|
| RunFunction    | switch  | (none)                                                 | Execute `Get-OutlookCacheSettings` immediately when calling the script file.                    | Script wrapper only. Useful for automation and scale-out. |
| Output         | string  | `TABLE`                                                | `TABLE`, `CSV`, or `XML`. `TABLE` writes formatted table to terminal; `CSV/XML` write to file.  | In `TABLE` mode, output is formatted; use `CSV/XML + -PassThru` to get objects back. |
| OutputRoot     | string  | `$env:SystemDrive\temp\OutlookCacheSettingsResults`    | Root folder for exports; a dated subfolder is created per run.                                  | Ensure the user has permissions to create subdirectories. |
| PassThru       | switch  | (none)                                                 | When exporting, also **return objects** to the pipeline.                                         | Applies to `CSV/XML` modes; `TABLE` mode is formatted output only. |
| IncludeMeaning | switch  | (none)                                                 | Adds a **Value Explanation** column summarizing what each value means.                          | Populated when an interpretable value exists; empty otherwise. |
| UseOutlookCom  | switch  | (none)                                                 | Uses Outlook **COM** to report `IsCachedExchange` per store.                                     | Requires Outlook installed and profile; handles readiness with a timeout. |
| StoresFlat     | switch  | (none)                                                 | Returns a flat two-column view (`StoreName`,`Cached`) for COM store results.                    | Skips the main registry table when used in combination with COM view. |

### Parameter Deep Dives (Purpose • When to Use • Behavior/Edge Cases • EXO/On‑Prem Notes)

- **RunFunction**  
  *Purpose*: Switch between load-only (dot-source) and immediate execution.  
  *When*: Automation or deployment tools calling the script directly.  
  *Behavior*: Executes the function with the provided wrapper switches and values.  
  *EXO/On‑Prem*: Neutral.

- **Output**  
  *Purpose*: Control destination/format.  
  *When*: `TABLE` for interactive terminals; `CSV/XML` for reporting.  
  *Behavior*: **Important**—in `TABLE` mode the function formats with `Format-Table` and returns no objects. Use `CSV/XML` with **`-PassThru`** to receive objects.  
  *EXO/On‑Prem*: Neutral.

- **OutputRoot**  
  *Purpose*: Export location root.  
  *When*: Centralized collection or per-user exports.  
  *Behavior*: Creates `\<dd-MMM-yyyy\>` subfolder; fails with a clear error if creation is denied.  
  *EXO/On‑Prem*: Neutral.

- **PassThru**  
  *Purpose*: Return objects even when exporting.  
  *When*: Need both files and in-session objects (e.g., additional pipeline processing).  
  *Behavior*: Applies to `CSV/XML`. Not used in `TABLE` mode.  
  *EXO/On‑Prem*: Neutral.

- **IncludeMeaning**  
  *Purpose*: Add **Value Explanation** interpretations (e.g., for `NoOST`, `SyncWindow`, `00036601`, COM store states).  
  *When*: Readability for audits and compliance reviews.  
  *Behavior*: Adds `ValueMeaning` where an interpretation exists; blank when unknown/unset.  
  *EXO/On‑Prem*: Strongly recommended for EXO readiness reviews.

- **UseOutlookCom**  
  *Purpose*: Live per-store posture (`IsCachedExchange`).  
  *When*: Confirm client reality (vs. policy intent).  
  *Behavior*: Initializes Outlook via COM; waits briefly for MAPI readiness; skips data-file stores and OneDrive/SharePoint. Adds “OutlookCOM” scope rows.  
  *EXO/On‑Prem*: Highly recommended for EXO; optional for on‑premises.

- **StoresFlat**  
  *Purpose*: A concise listing of COM stores and cached state.  
  *When*: Dashboards, large-scale aggregation, or simple compliance checks.  
  *Behavior*: Emits `[pscustomobject]` list of `StoreName`,`Cached` (formatted in `TABLE` mode unless exporting).  
  *EXO/On‑Prem*: Useful for shared mailbox posture validation in EXO.

---

## Outputs

- **Default (TABLE)**: Formatted table to terminal: `ComputerName, CurrentUser, Scope, Path (short), Key, Value[, ValueMeaning]`  
  - Note: `TABLE` is terminal formatting; to get objects, use `-Output CSV -PassThru` or `-Output XML -PassThru`.
- **StoresFlat**: Two columns—`StoreName`, `Cached`—representing COM per-store cached state.
- **Value Explanation semantics** (selected):
  - **Enable (Policy)**: `1` → Cached Mode enforced; `0` → Cached Mode disabled.
  - **CacheOthersMail (Policy)**:
    - `null` → Not configured
    - `0` → Shared **mail** folders **not** cached (non‑mail folders only)
    - `1` → Shared **mail** folders cached (typical when enabled)
  - **SyncWindow**:
    - Months: `0=All mail`, `1`, `3`, `6`, `12`, `24`, `36 (3yrs)`, `60 (5yrs)`
    - Days (overrides months when present): `3d`, `7d`, `14d`, or custom days → “Sync window (days): N”
  - **NoOST** (policy/user):
    - `null` → Not configured
    - `0` → OST allowed; users can enable Cached Mode
    - `1` → Legacy semantics (OST set up by default; users cannot enable offline store)
    - `2` → **Disallow OST** creation; Cached/Offline disabled
    - `3` → No OST in Online Mode; Cached Mode may still create OST
  - **00036601 (per‑profile)**: High bit in first byte indicates **Cached Mode Enabled (per-profile)** vs **Disabled**.
  - **Outlook COM `IsCachedExchange`**: `True` = Cached, `False` = Online/not cached, `Unknown` = unavailable.

---

## Examples (Windows PowerShell 5.1)

> All examples assume the function is already available (dot-sourced or executed via `-RunFunction`).

**1) Baseline audit with Value Explanation (terminal):**
```powershell
. .\Get-OutlookCacheSettings.ps1
Get-OutlookCacheSettings -IncludeMeaning
```

**2) Live COM check (per-store), with Value Explanation:**
```powershell
Get-OutlookCacheSettings -UseOutlookCom -IncludeMeaning
```

**3) Flat per-store listing (StoreName, Cached):**
```powershell
Get-OutlookCacheSettings -UseOutlookCom -StoresFlat
```

**4) Export to CSV and also return objects to pipeline for further filtering:**
```powershell
Get-OutlookCacheSettings -Output CSV -PassThru -IncludeMeaning |
    Where-Object { $_.Key -eq 'IsCachedExchange' -and $_.Value -eq 'False' } |
    Select-Object Path, Key, Value, ValueMeaning
```

**5) Non-terminating, at-scale collection with remoting (mass runs):**
```powershell
$computers = Get-Content .\targets.txt
Invoke-Command -ComputerName $computers -ErrorAction Continue -ScriptBlock {
    param($share)
    # Ensure function is resident; load from share
    . "$share\Get-OutlookCacheSettings.ps1"
    # Export locally and return objects for aggregation
    Get-OutlookCacheSettings -Output CSV -PassThru -IncludeMeaning
} -ArgumentList '\\fileserver\ops\OutlookAudit' |
    Export-Csv .\Aggregated-OutlookCacheSettings.csv -NoTypeInformation
```

---

## Enterprise Deployment Guidance

### SCCM (ConfigMgr) Compliance Baseline

**Detection Script Pattern (Boolean):**
- **Goal**: “Compliant” if Cached Mode is enabled by policy **or** per-profile flag indicates enabled; **and** (optionally) COM shows Cached for primary store.

```powershell
# Detection (True = Compliant)
try {
    . "$PSScriptRoot\Get-OutlookCacheSettings.ps1"
    $r = Get-OutlookCacheSettings -IncludeMeaning -PassThru -Output CSV  # get objects
    $policyEnable = $r | Where-Object { $_.Key -eq 'Enable' -and $_.Value -eq 1 }
    $profileFlag  = $r | Where-Object { $_.Key -eq '00036601' -and $_.ValueMeaning -like 'Cached Mode: Enabled*' }

    if ($policyEnable -or $profileFlag) { $true } else { $false }
}
catch { $false }
```

**Optional Remediation Strategy (prefer GPO first):**
- Set policy keys under `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\Enable = 1`
- Configure `SyncWindowSetting` and `CacheOthersMail` as needed
- Stage rollout (pilot → broad), require user logoff/restart Outlook

**Collection Targeting & Aggregation:**
- Start with IT pilot ring; expand to business pilots; then broad rollout
- Aggregate `CSV` outputs from endpoints to a share; report via SCCM

### Intune (Proactive Remediations)

**Detection Script (exit 0 = compliant; exit 1 = remediation required):**
```powershell
try {
    . "$PSScriptRoot\Get-OutlookCacheSettings.ps1"
    $r = Get-OutlookCacheSettings -IncludeMeaning -PassThru -Output CSV
    $policyEnable = $r | Where-Object { $_.Key -eq 'Enable' -and $_.Value -eq 1 }
    $profileFlag  = $r | Where-Object { $_.Key -eq '00036601' -and $_.ValueMeaning -like 'Cached Mode: Enabled*' }

    if ($policyEnable -or $profileFlag) { exit 0 } else { exit 1 }
}
catch { exit 1 }
```

**Remediation Script (user context recommended; prefer GPO when possible):**
```powershell
$ver = '16.0'  # Office (Outlook) version
$cmPath = "HKCU:\Software\Policies\Microsoft\Office\$ver\Outlook\Cached Mode"
New-Item -Path $cmPath -Force | Out-Null
New-ItemProperty -Path $cmPath -Name Enable -PropertyType DWord -Value 1 -Force | Out-Null

# Example: 12-month sync window
New-ItemProperty -Path $cmPath -Name SyncWindowSetting -PropertyType DWord -Value 12 -Force | Out-Null

# Example: cache shared mail folders
New-ItemProperty -Path $cmPath -Name CacheOthersMail -PropertyType DWord -Value 1 -Force | Out-Null
```

**Reporting Strategy:**
- Use detection log output (custom) or export CSV to a secured OneDrive/Share share
- Consider Device/Log Analytics ingestion for dashboards

### Group Policy

**Registry policies to enforce Cached Mode and Sync Window:**
- `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\Enable`
- `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\CacheOthersMail`
- `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\SyncWindowSetting`
- `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\OST\NoOST`

**Recommendations:**
- **EXO**: Enforce Cached Mode (`Enable=1`), set appropriate `SyncWindowSetting` (e.g., 12 months), and enable `CacheOthersMail` as needed for shared mailboxes.
- **On‑Prem**: Cached Mode is generally fine; Online Mode may be tolerated where LAN latency is negligible. Document exceptions.

### At-Scale Alternatives

- **Pure registry audit (no COM)**: For speed and reliability at scale, omit `-UseOutlookCom`; rely on policy keys + `00036601`.
- **Remote collection / CSV aggregation**: Use `Invoke-Command` to gather and merge endpoint outputs centrally.
- **Why server-side logs are insufficient**: Exchange server logs do not reveal Outlook client Cached vs Online Mode per store; client-side inspection is required.

---

## EXO vs On‑Prem Considerations

- **EXO (Exchange Online)**:
  - Cached Mode provides resilience against WAN latency and intermittent connectivity.
  - Larger mailboxes: tune `SyncWindowSetting` (e.g., 6–12 months) to balance performance and user experience.
  - Shared mailboxes: consider enabling `CacheOthersMail` when users need reliable search/offline access; monitor OST growth.

- **On‑Prem**:
  - Online Mode has historically been viable on fast LANs; however, Cached Mode still improves perceived performance and resilience.
  - For migration gating, validate that target users (and shared mailboxes) have Cached Mode enabled prior to moving to EXO.

---

## Troubleshooting

- **Outlook not running / COM not accessible**: The function initializes Outlook via COM if needed and waits briefly via `Wait-OutlookReady`. If not ready, COM results may show `Not Found` or warning.
- **Profile hive not loaded**: HKCU policy/user keys require the user profile to be loaded. Scheduled tasks under system context won’t see user HKCU.
- **32/64‑bit registry view**: The script reads standard HKCU/HKLM paths; ensure Outlook and policies target the expected view.
- **Output path permission**: If `OutputRoot` cannot be created, the function emits an error and returns (pass-through objects only if `-PassThru` was used with `CSV/XML`).
- **Formatted output vs objects**: In `TABLE` mode, the function uses `Format-Table` and returns no objects; use `CSV/XML` with `-PassThru` for pipeline processing.
- **COM store filtering**: SharePoint/OneDrive and data-file stores are skipped by design.

---

## Security & Privacy

- **Data collected**: Computer name, current user, registry paths and values for Outlook Cached Mode settings; optional per‑store cache state (name only) via COM.
- **No credentials collected**.
- **Handling**: Treat CSV/XML exports as configuration data; store in secured locations and limit distribution.

---

## Versioning & Changelog

| Version | Date       | Author         | Changes |
|---------|------------|----------------|---------|
| 0.8     | 2025-10-09 | Cullen Haafke  | Initial public header: synopsis, disclaimer, version history; function as provided. |
| 0.9     | 2025-10-09 | Cullen Haafke  | Added path normalization in output notes, clarified parameter docs. |
| 1.0.0   | 2025-10-09 | Cullen Haafke  | Tightened Outlook readiness and COM error handling notes in docs. |
| 1.1.0   | 2025-10-10 | Cullen Haafke  | Added Output (TABLE/CSV/XML), OutputRoot; CSV/XML export with dated folder; PassThru. |
| 1.2.0   | 2025-10-10 | Cullen Haafke  | Script wrapper: -RunFunction execution mode; default terminal output; corrected export path. |

> **Semantic Versioning**: Update the `# Version History / Changelog` block in the script header and mirror changes here.

---

## References

- Microsoft Learn — **Outlook Cached Exchange Mode** overview and guidance  
  - https://learn.microsoft.com/outlook/troubleshoot/performance/recommend-cached-exchange-mode
- Microsoft 365 Apps — **Policy Settings Reference (Outlook)**  
  - https://learn.microsoft.com/deployoffice/policy-settings-reference
- Outlook administrative templates (ADMX) — Policy key mappings for Cached Mode, Sync Window, and OST behavior  
  - https://learn.microsoft.com/deployoffice/administrative-templates

> **Policy Keys (for quick reference)**  
> `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\Enable`  
> `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\CacheOthersMail`  
> `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\Cached Mode\SyncWindowSetting`  
> `HKCU\Software\Policies\Microsoft\Office\<version>\Outlook\OST\NoOST`

---

## Appendix

### Example SCCM Detection Snippet (Boolean Script Setting)
```powershell
try {
    . "$PSScriptRoot\Get-OutlookCacheSettings.ps1"
    $r = Get-OutlookCacheSettings -IncludeMeaning -PassThru -Output CSV
    $policyEnable = $r | Where-Object { $_.Key -eq 'Enable' -and $_.Value -eq 1 }
    $profileFlag  = $r | Where-Object { $_.Key -eq '00036601' -and $_.ValueMeaning -like 'Cached Mode: Enabled*' }
    $policyEnable -or $profileFlag
}
catch { $false }
```

### Example Intune PR Detection & Remediation Stubs
**Detection (exit code semantics)**
```powershell
try {
    . "$PSScriptRoot\Get-OutlookCacheSettings.ps1"
    $r = Get-OutlookCacheSettings -IncludeMeaning -PassThru -Output CSV
    $policyEnable = $r | Where-Object { $_.Key -eq 'Enable' -and $_.Value -eq 1 }
    $profileFlag  = $r | Where-Object { $_.Key -eq '00036601' -and $_.ValueMeaning -like 'Cached Mode: Enabled*' }
    if ($policyEnable -or $profileFlag) { exit 0 } else { exit 1 }
}
catch { exit 1 }
```

**Remediation (user context)**
```powershell
$ver = '16.0'
$cmPath = "HKCU:\Software\Policies\Microsoft\Office\$ver\Outlook\Cached Mode"
New-Item -Path $cmPath -Force | Out-Null
New-ItemProperty -Path $cmPath -Name Enable -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $cmPath -Name SyncWindowSetting -PropertyType DWord -Value 12 -Force | Out-Null
New-ItemProperty -Path $cmPath -Name CacheOthersMail -PropertyType DWord -Value 1 -Force | Out-Null
```

### Example CSV Schema (Columns)

**Default (registry+COM table when `-IncludeMeaning` is used):**
```
ComputerName,CurrentUser,Scope,Path,Key,Value,ValueMeaning
```

**StoresFlat:**
```
StoreName,Cached
```

---

## Script Notes (Quality Checks)

- Parameter names and behaviors validated against provided code:
  - `Output` supports `TABLE|CSV|XML`; `TABLE` uses `Format-Table` → formatted output (no objects).
  - `PassThru` returns objects **only** for `CSV/XML`.
  - COM path skips OneDrive/SharePoint and data-file stores.
  - `00036601` interpretation uses first byte high bit.
  - `SyncWindowSettingDays` overrides `SyncWindowSetting` when present.
- COM/session dependency warnings included (readiness wait, profile presence).
- SCCM/Intune + GPO operationalization and data collection patterns provided.
- Versioning block and changelog mirrored from script header.
```
