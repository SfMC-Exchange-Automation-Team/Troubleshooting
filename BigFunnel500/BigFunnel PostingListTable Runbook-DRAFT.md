# BigFunnel PostingListTable Issue Runbook

**Microsoft Bug Issue 4271324 - Exchange On-Premises Operational Guidance**

## Executive Summary

The BigFunnel PostingListTable issue, **Issue 4271324**, causes mailbox-level locks during search operations that can persist for hours, blocking mail delivery and shared mailbox access until the database fails over or the search loop completes.

The core operating model separates **emergency access restoration** from **durable PostingListTable size reduction**:

| Situation | Primary Action | Rationale |
|---|---|---|
| Users actively blocked; mailbox locked; mail delivery queuing with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy` | Database failover / switchover | Releases the mailbox lock and restores access, but does **not** reduce PostingListTable size |
| `BigFunnelPostingListTableTotalSize` at warning or critical threshold, no active lock | Collect diagnostics -> reduce items -> schedule mailbox move | Mailbox move rebuilds BigFunnel structures on the destination and is intended to reduce PostingListTable size |
| Many mailboxes above threshold, such as approximately 2,000 mailboxes beyond 2 GB observed in production | Monitor, prioritize, and batch moves under change control | Exchange 2019 WLM throttling defaults to 10 simultaneous mailbox moves from the same source or to the same target; moving all affected mailboxes is not feasible without automation and batching |

---

## 1. Symptoms and Detection Signals

### Primary Symptom

The primary symptom is **search-driven mailbox unavailability**, especially on shared mailboxes.

Engineering issue description:

> Customer has been noticing mail queuing occurring to a mailbox with the status being `432 4.3.2 STOREDRV.Storage; mailbox server is too busy`. This is caused by a mailbox lock being held. After some troubleshooting, this lock can occur from a few hours to hours or until the database fails over.

Customer-facing symptoms included:

- Users unable to open on-premises shared mailboxes
- Error: **"This server is too busy and cannot respond"**
- HTTP 500 errors during search on shared mailboxes
- Mail delivery delays or queueing
- Search hangs or long delays in Outlook / OWA

One issue was attributed to:

```text
BigFunnelPostingListTableTotalSize: 22.55 GB
Bytes: 24,216,305,664
Expected maximum: below 2 GB
```

### Lab Reproduction

In a lab reproduction, a shared mailbox with:

- **527,391 items**
- **PostingListTable size: 1.7 GB**

produced a roughly **45-second Outlook search delay / hang** when searching for generic terms:

```text
c 2 sky
```

Mail delivery to the mailbox was also delayed while the search was in progress.

### Production Scale Examples

One production environment reported:

| Threshold | Mailbox Count |
|---:|---:|
| Greater than 10 GB | 153 |
| Greater than 20 GB | 42 |
| Greater than 30 GB | 20 |
| Greater than 40 GB | 12 |
| Greater than 50 GB | 6 |

Separately, approximately **2,000 mailboxes** were identified with PostingListTable size beyond **2 GB**, with random mailboxes becoming inaccessible when users attempted to use them.

---

## 2. Detection Signals

| Detection Area | Signal | Collection Method |
|---|---|---|
| User experience | Outlook / OWA search hangs; "server too busy" or 500 errors; shared mailbox cannot be opened | Incident reports, client reproduction, OWA HAR capture |
| Transport / Store | Mail delivery queues with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy` | Transport queue monitoring, Store event logs |
| Search test | `Test-ExchangeSearch` shows timeout or failure | Run `Test-ExchangeSearch`; one related case showed `ResultFound: False`, `SearchTimeInSeconds: 0`, and error `Time out for test thread` |
| BigFunnel metric | `BigFunnelPostingListTableTotalSize` approaching or exceeding thresholds | `Get-MailboxStatistics | fl BigFunnel*` |
| Scale assessment | Multiple at-risk mailboxes on the same database or DAG | Aggregate `Get-MailboxStatistics -Database` filtered by threshold |

---

## 3. Monitoring Thresholds

These thresholds are derived from case guidance and the engineering reproduction environment.

| Level | Threshold | Operator Action |
|---|---:|---|
| Normal | `< 1.7 GB` | Continue periodic monitoring |
| Warning | `>= 1.7 GB` | Start proactive review; confirm growth rate; identify mailbox owner; plan cleanup or move. The 1.7 GB threshold was proposed as an early warning to provide approximately three days of lead time before user impact |
| Critical | `>= 2.0 GB` | Treat as high risk for lock-related user impact; collect diagnostics; prepare remediation. The 2 GB value is cited as the design threshold above which performance issues occur |

> **Important nuance:** Mailbox size alone is not the deciding factor. A mailbox can be relatively small and still have `BigFunnelPostingListTableTotalSize` beyond approximately 2 GB depending on mailbox shape and search behavior.

The alert threshold should be tailored based on the observed growth rate of the posting list table for each mailbox, as usage patterns and application interactions can cause varying rates of increase.

---

## 4. Root Cause and Failure Mode

BigFunnel is the codename for the project that added full-text index capability natively to the Exchange ItemStore.

BigFunnel uses three primary data structures per mailbox, or shard.

### POI - Per-Object Index

A condensed representation of all textual content in a document, stored as a property on each item.

- The **Uncompressed POI**, or UPOI, is a portable format copied during move-mailbox.
- ItemStore converts it to **Compressed POI**, or CPOI, using a per-shard Term Dictionary for storage efficiency.

### Bloom Filter Table

Maintains bloom filter bit-vectors for the top 10K-20K documents by static relevancy.

- Used to efficiently eliminate non-matching documents during query evaluation.
- Expected to average approximately 500 bytes per record at a 1% false-positive rate.

### Posting List Table

An optional overflow structure used only for large mailboxes where the Filter table alone is too slow.

- On large mailboxes, using filters / POI alone is too slow.
- Posting lists provide full-text search capability.
- Posting list ingestion and management is expensive and performed asynchronously.
- Each PL bucket covers a range of terms.
- Actual term-postings data is stored in large long-value fields, estimated at 0.5-1 MB per bucket.

### Failure Mode

The failure mode in **Issue 4271324** occurs when the PostingListTable grows beyond its intended operating range.

Generic search queries drive long-running BigFunnel posting-list decode / query loops under a mailbox lock.

Engineering traces showed the call stack stuck in:

```text
BigFunnel.PostingList.PostingListDecoder.IndexStreamPostingsGroupDecode.ProcessDecoder
```

and related frames.

One iDNA trace showed a list of **6,853 search terms / scopes** causing the problematic loop.

Business impact:

> The long locks cause the mailbox to become unusable till the loop completes thus releasing the lock or the database fails over. Because this is a shared mailbox, this effects multiple users at the same time.

---

## 5. Why Mailbox Moves Help Architecturally

During a move-mailbox operation:

1. BigFunnel copies `Dictionarynext` from the source.
2. The destination stamps it as `Dictionarycurrent`.
3. As individual messages are moved, the POI property is moved and recompressed.
4. Filter records are added as part of item save calls.
5. If the number of filter records exceeds the preferred maximum, 20K, the system starts a background batch-merge request to populate the Posting List table.

This rebuilds the structures from scratch on the destination, eliminating stale entries and accumulated metadata from the source.

---

## 6. Database Failover vs. Mailbox Move

| Dimension | Database Failover / Switchover | Mailbox Move |
|---|---|---|
| Immediate effect | Releases the mailbox lock and restores user access | Does not instantly release an active search lock; mailbox access transfers when move completes |
| PostingListTable effect | Does not inherently reduce `BigFunnelPostingListTableTotalSize`. Observed: 12 GB before DAG flip -> approximately 11.5 GB after flip | Rebuilds BigFunnel structures on destination. Observed results vary: one case showed complete table reduction and rebuild; another showed 6.607 GB -> 5.32 GB after move |
| Speed | Seconds to minutes; estimated approximately 1 minute to complete switchover | Hours to days depending on mailbox size; one 120 GB mailbox move took approximately 48 hours |
| When to use | Emergency: users are actively blocked, mail is queuing, mailbox lock is held | Durable remediation: after diagnostics are collected and content cleanup is performed |
| Prerequisites | Target passive database copy must be healthy and current | Collect `Troubleshoot-ModernSearch` data before moving; notify BigFunnelCSS@microsoft.com |
| Caveats | Does not prevent recurrence; table size persists | Large mailboxes take significant time; can cause white space bloat on destination database |

### Key Engineering Correction

An internal summary stated:

> Failover database to another server reduces BigFunnelPostingListTableTotalSize.

This was corrected:

> This is inaccurate. Failover the database to another server only releases the lock allowing access to the mailbox again. Moving the mailbox to another database after reducing the items in the mailbox will reduce the BigFunnelPostingListTableTotalSize.

Customer-observed evidence:

- DAG flip preserved the table at approximately the same size: **12 GB -> 11.5 GB**
- This confirmed that failover does not rebuild the table.
- A subsequent mailbox move caused the BigFunnel table size to reduce and rebuild itself.
- In another mailbox, the move reduced PostingListTableTotalSize from **6.607 GB -> 5.32 GB**, but the customer noted the table was still above 2 GB and stated:

> The given solution by previous MS engineer is not recreating the table index.

---

## 7. Proactive Monitoring Strategy

Monitor:

- Business-critical shared mailboxes
- High-activity mailboxes
- Databases hosting multiple at-risk mailboxes

The primary metric is:

```text
BigFunnelPostingListTableTotalSize
```

Collect it with:

```powershell
Get-MailboxStatistics | fl BigFun*
```

This displays BigFunnel-related properties, including:

- `BigFunnelPostingListTableTotalSize`
- `BigFunnelNotIndexedCount`
- Other BigFunnel fields

### Recommended Monitoring Cadence

| Population | Recommended Cadence | Notes |
|---|---|---|
| Known impacted or high-risk databases | Every 4 hours | Aligns with BigFunnel's internal TBA retry cycle, configured to run every 4 hours to ingest items that need it |
| Business-critical shared mailboxes | Every 4 hours | Use the 1.7 GB warning threshold to create lead time before impact |
| General shared mailboxes | Daily | Escalate to 4-hour cadence if growth accelerates |
| Post-remediation mailboxes | Daily for 7 days | Confirm the table does not rebound quickly after remediation |

Case discussion guidance:

> Proposed creating a PowerShell script to monitor the posting list table size, suggesting a configurable threshold, for example 1.7 GB for a three-day lead time, to trigger alerts before users are affected, allowing the team to address issues proactively.

---

## 8. Monitoring Automation - PowerShell Script

### Requirements

Run in Exchange Management Shell or a PowerShell session where Exchange cmdlets are available.

Compatible with **Windows PowerShell 5.1**.

```powershell
<#
.SYNOPSIS
Monitors BigFunnelPostingListTableTotalSize for Exchange mailboxes.

.DESCRIPTION
Collects Get-MailboxStatistics output by database, converts
BigFunnelPostingListTableTotalSize to bytes, evaluates warning and critical
thresholds, exports CSV results, and optionally sends email.

.NOTES
Windows PowerShell 5.1 compatible.

Run with an account that has Exchange RBAC permissions to run:
- Get-MailboxDatabase
- Get-MailboxStatistics
#>

[CmdletBinding()]
param(
    [string[]]$Databases,

    [double]$WarningGB = 1.7,

    [double]$CriticalGB = 2.0,

    [string]$OutputPath = (Join-Path $env:ProgramData "ExchangeBigFunnelPostingListMonitor"),

    [switch]$SendEmail,

    [string]$SmtpServer,

    [string]$MailFrom,

    [string[]]$MailTo
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} [{1}] {2}" -f $timestamp, $Level, $Message

    Write-Verbose $line

    if (-not (Test-Path -LiteralPath $script:OutputPath)) {
        New-Item -Path $script:OutputPath -ItemType Directory -Force | Out-Null
    }

    Add-Content -Path $script:LogFile -Value $line
}

function Initialize-ExchangeShell {
    [CmdletBinding()]
    param()

    Write-Verbose "Checking whether Exchange cmdlets are available."

    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        Write-Verbose "Get-MailboxStatistics not found. Attempting to load Exchange snap-in."
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue
    }

    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        throw "Get-MailboxStatistics is not available. Run from Exchange Management Shell or load the Exchange tools."
    }

    Write-Verbose "Exchange cmdlets are available."
}

function Convert-ExchangeSizeToBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        $SizeValue
    )

    Write-Verbose ("Converting size value [{0}] to bytes." -f $SizeValue)

    if ($null -eq $SizeValue) {
        return $null
    }

    if ($SizeValue -is [string] -and $SizeValue -match "Unlimited") {
        return $null
    }

    # Exchange ByteQuantifiedSize objects usually expose ToBytes().
    if ($SizeValue.PSObject.Methods.Name -contains "ToBytes") {
        return [int64]$SizeValue.ToBytes()
    }

    $text = [string]$SizeValue

    # Common Exchange string format: 1.7 GB (1,825,361,920 bytes)
    if ($text -match "\(([0-9,]+)\s+bytes\)") {
        return [int64](($matches[1]) -replace ",", "")
    }

    # Fallback parser for values such as "1.7 GB", "900 MB", "512 KB".
    if ($text -match "^\s*([0-9.]+)\s*(B|KB|MB|GB|TB)\s*$") {
        $number = [double]$matches[1]
        $unit = $matches[2].ToUpperInvariant()

        switch ($unit) {
            "B"  { return [int64]$number }
            "KB" { return [int64]($number * 1KB) }
            "MB" { return [int64]($number * 1MB) }
            "GB" { return [int64]($number * 1GB) }
            "TB" { return [int64]($number * 1TB) }
        }
    }

    throw "Unable to parse size value: $text"
}

function Get-PostingListStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Bytes,

        [Parameter(Mandatory = $true)]
        [int64]$WarningBytes,

        [Parameter(Mandatory = $true)]
        [int64]$CriticalBytes
    )

    Write-Verbose ("Evaluating {0} bytes against warning {1} and critical {2}." -f $Bytes, $WarningBytes, $CriticalBytes)

    if ($Bytes -ge $CriticalBytes) {
        return "Critical"
    }

    if ($Bytes -ge $WarningBytes) {
        return "Warning"
    }

    return "Normal"
}

# Main
$script:OutputPath = $OutputPath

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $OutputPath ("BigFunnelPostingListMonitor-{0}.log" -f $runId)
$csvPath = Join-Path $OutputPath ("BigFunnelPostingListMonitor-{0}.csv" -f $runId)

Write-RunLog "Starting BigFunnel PostingListTable monitor run."

Initialize-ExchangeShell

$warningBytes = [int64]($WarningGB * 1GB)
$criticalBytes = [int64]($CriticalGB * 1GB)

if (-not $Databases -or $Databases.Count -eq 0) {
    Write-RunLog "No databases specified. Discovering mounted mailbox databases."

    $Databases = Get-MailboxDatabase -Status |
        Where-Object { $_.Mounted -eq $true } |
        Select-Object -ExpandProperty Name
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($db in $Databases) {
    Write-RunLog ("Collecting mailbox statistics for database [{0}]." -f $db)

    try {
        $stats = Get-MailboxStatistics -Database $db -ErrorAction Stop

        foreach ($stat in $stats) {
            $property = $stat.PSObject.Properties["BigFunnelPostingListTableTotalSize"]

            if ($null -eq $property) {
                Write-RunLog ("Mailbox [{0}] does not expose BigFunnelPostingListTableTotalSize." -f $stat.DisplayName) "WARN"
                continue
            }

            $bytes = Convert-ExchangeSizeToBytes -SizeValue $property.Value

            if ($null -eq $bytes) {
                continue
            }

            $status = Get-PostingListStatus `
                -Bytes $bytes `
                -WarningBytes $warningBytes `
                -CriticalBytes $criticalBytes

            $results.Add([pscustomobject]@{
                Timestamp                          = Get-Date
                Database                           = $db
                DisplayName                        = $stat.DisplayName
                MailboxGuid                        = $stat.MailboxGuid
                ItemCount                          = $stat.ItemCount
                TotalItemSize                      = [string]$stat.TotalItemSize
                BigFunnelPostingListTableTotalSize = [string]$property.Value
                PostingListBytes                   = $bytes
                PostingListGB                      = [math]::Round(($bytes / 1GB), 3)
                Status                             = $status
                LastLogonTime                      = $stat.LastLogonTime
            })
        }
    }
    catch {
        Write-RunLog ("Failed to collect database [{0}]. Error: {1}" -f $db, $_.Exception.Message) "ERROR"
    }
}

$results |
    Sort-Object Status, PostingListBytes -Descending |
    Export-Csv -NoTypeInformation -Path $csvPath

Write-RunLog ("Exported results to [{0}]." -f $csvPath)

$atRisk = $results | Where-Object { $_.Status -in @("Warning", "Critical") }

if ($SendEmail -and $atRisk.Count -gt 0) {
    if (-not $SmtpServer -or -not $MailFrom -or -not $MailTo) {
        throw "SmtpServer, MailFrom, and MailTo are required when SendEmail is used."
    }

    $subject = "Exchange BigFunnel PostingListTable alert: $($atRisk.Count) mailbox(es) at warning or critical"

    $body = ($atRisk |
        Sort-Object PostingListBytes -Descending |
        Select-Object Database, DisplayName, PostingListGB, Status |
        Format-Table -AutoSize |
        Out-String)

    Write-RunLog "Sending alert email."

    Send-MailMessage `
        -SmtpServer $SmtpServer `
        -From $MailFrom `
        -To $MailTo `
        -Subject $subject `
        -Body $body `
        -Attachments $csvPath
}

Write-RunLog "Monitor run complete."
```

---

## 9. Scheduling Example

Use this example for at-risk databases, running every 4 hours.

Run from an elevated prompt when creating the scheduled task. Replace the script path, account, and database list with environment-specific values.

```cmd
schtasks /Create /TN "Exchange BigFunnel PostingListTable Monitor" /SC HOURLY /MO 4 /RU "DOMAIN\ServiceAccount" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%ProgramData%\ExchangeBigFunnelPostingListMonitor\Monitor-BigFunnelPostingList.ps1"" -Databases DB01,DB02 -WarningGB 1.7 -CriticalGB 2.0"
```

Reference helper threshold:

```powershell
$thresholdBytes = 1.7 * 1GB
```

---

## 10. Manual Remediation Procedures

### A. Emergency Database Failover / Switchover

Use this procedure when users are actively blocked, the mailbox lock is held, or mail delivery is queuing.

#### Step 1 - Capture Minimum Evidence

If time allows:

```powershell
Get-MailboxStatistics "<MailboxIdentity>" | fl DisplayName,Database,BigFunnel*
```

Record:

- Affected mailbox identity
- Database name
- Timestamp of impact

#### Step 2 - Verify Target Copy Health

The database copy that will become the active mailbox database must be healthy and current.

```powershell
Get-MailboxDatabaseCopyStatus "<DatabaseName>"
```

#### Step 3 - Execute the Switchover

`Move-ActiveMailboxDatabase` is the on-premises cmdlet for performing a database or server switchover.

```powershell
Move-ActiveMailboxDatabase `
    -Identity "<DatabaseName>" `
    -ActivateOnServer "<TargetServer>" `
    -MountDialOverride None `
    -MoveComment "BigFunnel lock release for Issue 4271324"
```

#### Step 4 - Verify Activation

```powershell
Get-MailboxDatabaseCopyStatus "<DatabaseName>" | Format-List
```

Confirm that the target server now hosts the active copy and that it is mounted.

#### Step 5 - Validate Recovery and Record Outcome

Confirm:

- Mailbox access is restored
- Mail delivery is restored
- `BigFunnelPostingListTableTotalSize` remains materially unchanged

This confirms that failover released the lock but did not reduce the table.

---

### B. Durable Mailbox Move

Use this procedure for planned, durable remediation after diagnostics have been collected.

#### Pre-Move Requirements - Product Group Guidance

Do **not** move mailboxes without first collecting data and notifying:

```text
BigFunnelCSS@microsoft.com
```

Internal CSS guidance states:

> DO NOT just move the mailbox to see if that works. We need additional data to help determine why this might be occurring.

Run `Troubleshoot-ModernSearch.ps1` against affected mailboxes.

The script determines:

- Whether an item is indexed
- Why it is not indexed
- Diagnostic logs

Example commands:

```powershell
.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -ItemSubject "<ItemSubject>"
```

```powershell
.\Troubleshoot-ModernSearch.ps1 -Server "<ServerName>"
```

Collect all log files from the directory where the script was run. Notify `BigFunnelCSS@microsoft.com` with the case number and confirm logs are uploaded.

#### Pre-Move Content Reduction

Engineering guidance recommended:

> Best to reduce the items in the mailbox, there is a good chunk of them for Audits on the mailbox. They could lower what they currently have set and possibly look into what they currently have set for their MRM settings on some default folders and see if they can reduce those items. After the items have been reduced, the quickest way to then reduce the Posting List Table size is a mailbox move.

Actions to consider, with business approval:

- Review and lower audit log retention settings on affected shared mailboxes
- Apply MRM retention policies to default folders
- Archive older content to archive mailboxes or PST export
- Hard-delete genuinely obsolete items

#### Move Execution

##### Pre-check

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName,Database,TotalItemSize,ItemCount,BigFunnel*
```

##### Create Move Request with Suspended Completion

```powershell
New-MoveRequest `
    -Identity "<MailboxIdentity>" `
    -TargetDatabase "<TargetDatabase>" `
    -BatchName "BF-PLT-Remediation-YYYYMMDD" `
    -SuspendWhenReadyToComplete `
    -BadItemLimit 10
```

`New-MoveRequest` begins an asynchronous mailbox move.

The `-SuspendWhenReadyToComplete` switch suspends the move before it reaches `CompletionInProgress`, allowing controlled cutover during a maintenance window.

The `-BadItemLimit` parameter specifies the maximum number of corrupt items allowed. Microsoft recommends **10 or lower**. Values of **51 or higher** require the `-AcceptLargeDataLoss` switch.

##### Monitor Progress

```powershell
Get-MoveRequest "<MailboxIdentity>" |
    Get-MoveRequestStatistics |
    Format-List DisplayName,Status,StatusDetail,PercentComplete
```

##### Complete During Approved Maintenance Window

```powershell
Resume-MoveRequest "<MailboxIdentity>"
```

##### Post-Move Verification

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName,Database,BigFunnel*
```

#### Move Duration Caveat

One 120 GB mailbox move took approximately **48 hours**. Plan capacity and maintenance windows accordingly for large mailboxes.

#### Move Effectiveness Caveat

Results vary.

Observed examples:

- One move reduced PostingListTable from **6.607 GB -> 5.32 GB**
- Another move caused the table to fully reduce and start rebuilding itself

The degree of reduction depends on how much content was cleaned before the move.

---

## 11. Automated Remediation Strategy

Automation should identify, prepare, and stage remediation rather than silently execute disruptive actions.

| Automation Layer | Criteria | Action |
|---|---|---|
| Detection | `>= 1.7 GB` | Alert; create operational ticket; tag mailbox / database |
| Critical | `>= 2.0 GB` | Require owner review; collect `Troubleshoot-ModernSearch` diagnostics; prepare move or failover plan |
| Active impact | User blocked; mail queuing; search lock suspected | Initiate approved emergency failover |
| Durable remediation | Critical mailbox; diagnostics collected; content owner approves cleanup and move | Create move request with `-SuspendWhenReadyToComplete` and descriptive `-BatchName` |
| Completion | Move reaches auto-suspended state, approximately 95% complete | Resume during approved maintenance window after change approval |

---

## 12. Concurrency and WLM Throttling

Exchange Server 2019 implements workload management, or WLM, throttling.

By default, WLM applies a limit of **10 simultaneous mailbox moves** from the same source or to the same target.

WLM throttling overrides Mailbox Replication Service, or MRS, throttling.

The stalled status, such as:

```text
StalledDueToTarget_MdbReplication
```

is typical and does not mean the migration has a problem. Its purpose is to maintain the performance of higher-priority Exchange workloads.

### Increasing the WLM Limit

Microsoft recommends:

- Do not set the limit above **100**
- Start at **25**
- Increase by **10**
- Monitor Exchange performance at each step

Example:

```powershell
$limit = 25

New-SettingOverride `
    -Name "MdbReplication" `
    -Component WorkloadManagement `
    -Section MdbReplication `
    -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"
```

Repeat for:

- `CiAgeOfLastNotification`
- `MdbAvailability`
- `DiskLatency`
- `MdbDiskWriteLatency`

---

## 13. Database Isolation Strategy

Case guidance recommended creating a dedicated database, such as:

```text
PLT01
```

within each affected DAG to house only problematic shared mailboxes.

This allows targeted failovers that minimize impact on other users and streamlines remediation.

The presence of affected mailboxes across multiple DAGs increases administrative overhead, but automation can reduce the manual effort.

---

## 14. Product Group Guidance and Escalation Expectations

### Data Collection Before Moves

For BigFunnel search-related cases, run `Troubleshoot-ModernSearch.ps1` before mailbox moves where feasible.

The script supports several diagnostic modes.

#### Single Item Analysis

```powershell
.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -ItemSubject "<ItemSubject>"
```

#### Server-Wide Assessment

```powershell
.\Troubleshoot-ModernSearch.ps1 -Server "<ServerName>"
```

#### Category Breakdown

```powershell
.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -Category "NotIndexed"
```

Key diagnostic properties to review:

- `IndexStatus`
- `IndexingErrorMessage`
- `IsPermanentFailure`

For items in permanent failure with:

```text
FailedToConnect: skip adding Poi
```

a temporary `SettingOverride` can enable re-indexing via:

```powershell
Start-MailboxAssistant -Identity "<MailboxIdentity>" -AssistantName BigFunnelRetryFeederTimeBasedAssistant
```

This is available in Exchange 2019 CU11 or later.

The override must be removed after use, as it is not recommended to keep it enabled permanently.

---

## 15. Emergency Access - Do Not Delay Failover for Diagnostics

If users are actively down, do **not** delay an emergency lock-release failover solely to complete deep diagnostics.

Capture the minimum pre-action state:

```powershell
Get-MailboxStatistics "<MailboxIdentity>" | fl DisplayName,Database,BigFunnel*
```

Record:

- Timestamps
- Affected mailbox identity
- Database name
- Reason immediate mitigation was required

Full diagnostic collection can follow after access is restored.

---

## 16. Operational Guardrails and Best Practices

| Guardrail | Guidance | Evidence |
|---|---|---|
| Do not treat failover as durable cleanup | Failover releases the lock but does not reduce PostingListTable size | Engineering correction: failover only releases the lock; moving the mailbox after item reduction reduces the size. Observed: 12 GB -> 11.5 GB post-flip |
| Avoid unsafe data-loss flags in automation | Do not use `-AcceptLargeDataLoss` unless explicitly approved and risk-accepted | Required when `BadItemLimit` is set to 51 or higher in Exchange 2010+ |
| Start with conservative move concurrency | Begin below WLM limits and monitor MRS / WLM status | Default: 10 simultaneous moves from same source / target. Microsoft recommends starting at 25, maximum 100 |
| Align move finalization to maintenance windows | Use `-SuspendWhenReadyToComplete` or `-CompleteAfter` | `New-MoveRequest` supports both patterns for controlled completion |
| Reduce mailbox content before move | Review audit settings, MRM / default folder policies, retention, archive, and item reduction | Engineering guidance: reducing items first produces the best PostingListTable reduction after move |
| Isolate affected shared mailboxes | Dedicated low-density databases reduce failover blast radius | Recommended: create a separate database within each DAG for problematic mailboxes, allowing targeted failovers |
| Never assume mailbox size drives table size | A small mailbox can have a large PostingListTable | Confirmed: mailbox size alone is not the deciding factor; table growth depends on mailbox shape and search behavior |
| Collect diagnostics before moving | Run `Troubleshoot-ModernSearch.ps1` and notify `BigFunnelCSS@microsoft.com` | Internal CSS guidance explicitly prohibits moves without prior data collection |

---

## 17. Operator Decision Flow

### Step 1 - Is There Active User Impact?

Active user impact includes:

- Users cannot open the mailbox
- Searches cause "server too busy" or 500 errors
- Mail delivery is queuing with:

```text
432 4.3.2 STOREDRV.Storage; mailbox server is too busy
```

If yes:

1. Capture minimum evidence.
2. Perform an approved database switchover to release the lock.
3. Continue to durable remediation planning.

### Step 2 - Has Failover Restored Access?

| Result | Action |
|---|---|
| Yes | Access is restored. Continue durable remediation because PostingListTable size persists |
| No | Escalate through Microsoft Support with timestamps, mailbox identity, database name, failover details, and available search diagnostics |

Failure to clear the lock may indicate a different constraint or incomplete switchover.

### Step 3 - Is `BigFunnelPostingListTableTotalSize` >= 2.0 GB?

If yes, treat as **critical**:

1. Collect `Troubleshoot-ModernSearch.ps1` diagnostics.
2. Notify `BigFunnelCSS@microsoft.com`.
3. Plan content reduction followed by mailbox move.

### Step 4 - Is the Mailbox Between 1.7 GB and 2.0 GB?

If yes, treat as **warning**:

1. Alert.
2. Review growth rate.
3. Coordinate with the mailbox owner.
4. Schedule cleanup or move before user impact occurs.

### Step 5 - Before Mailbox Move

Complete the following:

- Run `Troubleshoot-ModernSearch.ps1` and export results
- Run `Get-MailboxStatistics` and record all `BigFunnel*` fields
- Document content reduction actions taken
- Create a change record
- Create the move request with `-SuspendWhenReadyToComplete`
- Resume completion during the approved maintenance window

### Step 6 - After Mailbox Move

Complete the following:

- Re-run `Get-MailboxStatistics`
- Compare before / after `BigFunnelPostingListTableTotalSize`
- If the table size did not materially decrease, evaluate whether additional content reduction is needed before a subsequent move
- Add the mailbox to the monitoring cadence, daily for 7 days, to confirm the table does not rebound

### Step 7 - Validate Search and User Experience

After the mailbox move and initial validation, confirm that the underlying user impact is resolved, not just the metric improvement.

#### Run Search Validation

```powershell
Test-ExchangeSearch "<MailboxIdentity>"
```

Confirm:

- No timeouts or failures
- Search results are returned

#### Client Validation

Test the following client experiences:

- Outlook in cached mode
- Outlook in online mode
- OWA searches with common and broad keywords

Confirm there are no:

- Hangs
- Long delays
- "Server too busy" errors

#### Mail Flow Validation

Confirm:

- No transport queuing
- New mail delivery is timely

### Step 8 - Confirm BigFunnel Health Signals

Evaluate additional BigFunnel-related indicators beyond PostingListTable size.

```powershell
Get-MailboxStatistics "<MailboxIdentity>" | fl BigFunnel*
```

Focus on:

| Signal | Expected Condition |
|---|---|
| `BigFunnelNotIndexedCount` | Should trend low or decreasing |
| `BigFunnelCorruptedCount` | Should be `0` |
| `BigFunnelRetryQueueSize` | Should not be growing |

If anomalies are found:

1. Re-run `Troubleshoot-ModernSearch.ps1`.
2. Consider invoking:

```powershell
Start-MailboxAssistant -Identity "<MailboxIdentity>" -AssistantName BigFunnelRetryFeederTimeBasedAssistant
```

### Step 9 - Document Outcome and Trend

Capture before / after metrics for operational tracking.

| Metric | Before Move | After Move |
|---|---:|---:|
| PostingListTable Size | X GB | Y GB |
| Mailbox Size | X GB | Y GB |
| Item Count | X | Y |
| Search Performance | Impacted / OK | OK |
| User Impact | Yes / No | No |

Store results in the operational tracking system.

Tag the mailbox as one of the following:

| Status | Meaning |
|---|---|
| Remediated | Search, mail flow, and BigFunnel indicators are healthy |
| Partially improved | Metrics improved but additional watch or action is required |
| Requires further action | PostingListTable size, search behavior, or BigFunnel health remains problematic |

### Step 10 - Decide if Further Action Is Required

If `BigFunnelPostingListTableTotalSize` is still `>= 2.0 GB`:

1. Perform additional content reduction.
2. Re-evaluate:
   - Audit log volume
   - High-churn folders, such as Inbox and Sent Items
   - Large conversation threads
3. Plan a second mailbox move if justified.

If the size rebounded quickly, such as within 7 days, investigate:

- Application behavior, including EWS and service accounts
- Automated processes generating content
- Search patterns, especially broad or generic queries

### Step 11 - Return Mailbox to Standard Monitoring

Once stable:

1. Move the mailbox back to the normal monitoring cadence.
2. Keep alerts enabled at:
   - `1.7 GB` warning
   - `2.0 GB` critical
3. Remove any temporary tracking flags or incident status.

### Step 12 - Feed Continuous Improvement Loop

Use insights from the remediation to improve future handling:

- Update automation candidate lists
- Refine thresholds based on growth patterns
- Identify high-risk mailbox profiles, such as:
  - Shared mailboxes
  - High item-churn mailboxes
  - Audit-heavy mailboxes
- Identify databases with clustering of at-risk mailboxes
- Adjust:
  - Move batching strategy
  - Monitoring frequency
  - Cleanup policies, including MRM and retention

### Step 13 - Optional Preventive Optimization

For frequently impacted environments:

1. Isolate high-risk shared mailboxes into dedicated databases.
2. Apply:
   - Stricter retention policies
   - Archive strategies
3. Review:
   - EWS usage patterns
   - Third-party integrations

