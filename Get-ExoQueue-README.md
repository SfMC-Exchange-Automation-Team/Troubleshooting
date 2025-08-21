# **Get-ExoQueue.ps1 – Exchange Online Message Queue Viewer**

## **Overview**
`Get-ExoQueue` is a PowerShell function designed to approximate the Exchange Online message queue using **Message Trace data**. It retrieves messages for a specified time range and outputs results in **GridView**, **CSV**, or **XML** format.  
This tool is intended for **administrative and troubleshooting purposes** and is **not an exact representation of the transport queue**.

---

## **Features**
- Query Exchange Online message trace data for the past **minutes**, **hours**, or **days**.
- Filter results by:
  - **JournalOnly** – Include only messages sent to a journal address.
  - **JournalExclude** – Exclude messages sent to a journal address.
- Display **Top Senders** and **Top Recipients**.
- Output options:
  - **GridView** (interactive)
  - **CSV** (export to file)
  - **XML** (export and auto-import into variables)
- Logging of query parameters and message counts.
- Optional inclusion of **Delivered** messages for testing/demos.

---

## **Prerequisites**
- PowerShell 5.1 or later.
- Exchange Online Management Module installed:
  ```powershell
  Install-Module ExchangeOnlineManagement
  ```
- Permissions to run `Get-MessageTraceV2` in Exchange Online.
- Access to create folders under `C:\Temp` for output.

---

## **Installation**
1. Download `Get-ExoQueue.ps1` to a local folder (e.g., `C:\Scripts`).
2. Open **PowerShell** as Administrator (recommended for registry access if using Journal filters).

---

## **How to Load the Function**
To load the function into your **current PowerShell session** without permanently installing it:

```powershell
# Navigate to the folder where the script is saved
Set-Location C:\Scripts

# Dot-source the script
. .\Get-ExoQueue.ps1

# OR use the call operator (&)
& "C:\Scripts\Get-ExoQueue.ps1"
```

After loading, you can run the function directly:
```powershell
Get-ExoQueue -AgeMinutes 30 -Output GridView
```

---

## **Usage Examples**
### **1. Default (last 30 minutes, GridView)**
```powershell
Get-ExoQueue
```

### **2. Last 2 hours, CSV output**
```powershell
Get-ExoQueue -AgeHours 2 -Output CSV
```

### **3. Include Delivered messages for testing**
```powershell
Get-ExoQueue -AgeMinutes 15 -IncludeDelivered
```

### **4. Show Top 10 senders and recipients**
```powershell
Get-ExoQueue -AgeMinutes 60 -TopSenders 10 -TopRecipients 10
```

### **5. Journal filtering**
```powershell
Get-ExoQueue -AgeHours 1 -JournalOnly
```

---

## **Output Details**
- **GridView**: Interactive table in a separate window.
- **CSV/XML**: Files saved under:
  ```
  C:\Temp\ExoQueueResults\<Date>\
  ```
- **Log File**: `ExoQueueLog--<Date>.txt` in the same folder.

---

## **Important Notes**
- This script uses **Message Trace data**, which is **not real-time** and may lag by several minutes.
- Large queries (e.g., `-AgeDays`) can cause timeouts in large environments.
- Journal address is stored in the registry under:
  ```
  HKCU:\Software\Microsoft\Exchange\ExoQueue
  ```

---

## **Disclaimer**
This script is provided **“as is”** without warranties or guarantees. Use at your own risk. Test thoroughly before using in production.

---
