# Technical Guide: Get-OutlookCacheSettings
**Version:** `v1.0.0`  

---

## Overview  
`Get-OutlookCacheSettings` is a PowerShell function designed for Exchange and Outlook administrators who need to audit or verify **Cached Exchange Mode** configurations. It inspects registry-based policy and user settings, evaluates per-profile flags, and optionally queries live Outlook COM objects for real-time cache state.  

This guide explains the script’s capabilities, parameters, and usage scenarios in detail.

---

## Why Use This Script?  
Cached Exchange Mode impacts performance, offline access, and troubleshooting scenarios in enterprise environments. Understanding its configuration across profiles and stores is critical for:  

- Diagnosing sync issues  
- Validating policy enforcement  
- Auditing compliance with organizational standards  

---

## Key Features  
### **Registry Enumeration**  
Scans policy and user registry paths for Cached Mode settings, including `Enable`, `CacheOthersMail`, `SyncWindow`, and OST restrictions (`NoOST`).  

### **Optional COM Integration**  
Interacts with Outlook COM objects to retrieve live per-store cache state (`IsCachedExchange`). Useful when registry values alone don’t reflect runtime behavior.  

### **Value Explanation**  
Adds a `ValueMeaning` column to interpret raw values into clear, actionable descriptions.  

### **Flexible Output**  
Choose between a detailed table for full context or a simplified flat view (`StoreName`, `Cached`) for quick checks.  

---

## Parameter Deep Dive  

### **`-UseOutlookCom`**  
**Purpose:**  
Enables querying of live Outlook COM objects to determine whether each mailbox store is operating in Cached Exchange Mode.  

**When to Use:**  
- You need runtime verification beyond registry values.  
- Troubleshooting discrepancies between policy and actual behavior.  

**Technical Notes:**  
- Requires Outlook to be installed and running.  
- Handles COM initialization and readiness checks gracefully.  

---

### **`-IncludeMeaning`**  
**Purpose:**  
Adds a `ValueMeaning` column to the output, providing **Value Explanation** for each setting.  

**Why It Matters:**  
Registry values like `Enable=1` or `NoOST=2` are cryptic. This parameter translates them into clear interpretations such as:  
- *“Policy: Use Cached Exchange Mode for new and existing profiles”*  
- *“Disallow OST creation; Cached/Offline disabled”*  

**Recommended For:**  
Audits, reporting, and scenarios where clarity is essential.  

---

### **`-StoresFlat`**  
**Purpose:**  
Outputs a simplified two-column table (`StoreName`, `Cached`) when querying Outlook COM.  

**Ideal Use Case:**  
- Quick checks across multiple stores.  
- When detailed registry context is unnecessary.  

**Behavior:**  
- Overrides the default detailed output when combined with `-UseOutlookCom`.  

---

## Output Formats  
- **Detailed Table:**  
  Includes `Scope`, `Path`, `Key`, `Value`, and optionally `ValueMeaning`.  
- **Flat View:**  
  Displays `StoreName` and `Cached` for rapid assessment.  

---

## Examples  

# Show all discovered settings with an explanation of the Value :
Get-OutlookCacheSettings -IncludeMeaning

# Include live per-store cache state (requires Outlook):
Get-OutlookCacheSettings -UseOutlookCom -IncludeMeaning

# Just the live per-store cached state (flat view):
Get-OutlookCacheSettings -UseOutlookCom -StoresFlat
