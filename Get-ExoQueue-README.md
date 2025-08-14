Here’s a **README** you can include for your updated script:

---

# **Get-ExoQueue.ps1**

## **Overview**
`Get-ExoQueue.ps1` is a PowerShell script that approximates the Exchange Online message queue using **message trace data** from the `Get-MessageTraceV2` cmdlet. It helps administrators quickly identify messages in a **Pending**, **Delivered**, or **Failed** state over a specified time range. The script supports multiple output formats and includes options for filtering journal traffic.

---

## **Disclaimer**
This script is provided **“as is”** without warranties or guarantees and is **not officially supported by Microsoft**. Use at your own risk. Test thoroughly in non-production environments before deploying in production.

---

## **Features**
- Retrieve Exchange Online message queue data for the past **X minutes, hours, or days**.
- Filter results by:
  - **JournalOnly**: Include only messages sent to a specific journal address.
  - **JournalExclude**: Exclude messages sent to a specific journal address.
- Output options:
  - **GridView** (default)
  - **CSV**
  - **XML**
- Display **Top Senders** and **Top Recipients**.
- Logs execution details and parameters for troubleshooting.
- Auto-import XML results into global variables for quick analysis.

---

## **Prerequisites**
- PowerShell 5.1 or later.
- Exchange Online PowerShell module (`ExchangeOnlineManagement`).
- Appropriate permissions to run `Get-MessageTraceV2`.
- Ability to connect to Exchange Online (MFA supported).

---

## **Parameters**
| Parameter        | Description                                                                 |
|-------------------|-----------------------------------------------------------------------------|
| `-JournalOnly`    | Include only messages sent to a journal address (stored in registry).     |
| `-JournalExclude` | Exclude messages sent to a journal address (stored in registry).          |
| `-AgeMinutes`     | Time range in minutes (1–59).                                             |
| `-AgeHours`       | Time range in hours (1–24).                                               |
| `-AgeDays`        | Time range in days (1–10). **Warning:** May timeout in large environments.|
| `-TopSenders`     | Display top N senders (1–25).                                             |
| `-TopRecipients`  | Display top N recipients (1–25).                                          |
| `-Output`         | Output format: `CSV`, `XML`, or `GridView` (default).                    |

**Note:** Only one of `AgeMinutes`, `AgeHours`, or `AgeDays` can be used at a time.

---

## **Usage Examples**
```powershell
# Default: Last 30 minutes, GridView output
Get-ExoQueue

# Last 2 hours, CSV output
Get-ExoQueue -AgeHours 2 -Output CSV

# Last 10 minutes, show top 5 senders and recipients
Get-ExoQueue -AgeMinutes 10 -TopSenders 5 -TopRecipients 5

# Include only journal traffic
Get-ExoQueue -AgeMinutes 30 -JournalOnly

# Exclude journal traffic, export to XML
Get-ExoQueue -AgeHours 1 -JournalExclude -Output XML
```

---

## **Output**
- **GridView**: Interactive table view.
- **CSV/XML**: Saved under `C:\Temp\ExoQueueResults\<Date>\`.
- **Log File**: Tracks execution details and parameters for troubleshooting.

---

## **Version History**
- **1.0 (03/08/24)**: Initial release.
- **1.1 – 1.3.1**: Added CSV/XML output, registry logic for journal filters, parameter validation, and unique result filtering.
- **1.4 (04/14/25)**:  
  - Replaced `Get-MessageTrace` with `Get-MessageTraceV2` for improved performance and accuracy.  
  - Removed pagination logic; simplified query execution.  
  - Changed output directory from Desktop to `C:\Temp\ExoQueueResults\<Date>`.  
  - Added confirmation prompts for `-AgeDays` and `-AgeHours` to prevent timeouts in large environments.  
  - Enhanced connection handling with Yes/No prompt for Exchange Online connection.  
  - Improved logging and output handling; log files now stored in `C:\Temp\ExoQueueResults\<Date>`.  
  - Added auto-import of XML results into global variables for easier analysis.  
  - General code cleanup and improved error handling.  
- **1.4.1 (08/14/25)**:  
  - Updated changelog for 1.4.  
  - Cleaned up syntax and corrected some entries to use `$UniqueResults` instead of `$allResults`.  

---

## **Important Notes**
- This script **approximates** the queue using message trace data. It is **not an exact representation** of the live queue.
- Large time ranges (especially `-AgeDays`) can cause timeouts in high-volume environments.
- Ensure Exchange Online connectivity before running.

---
