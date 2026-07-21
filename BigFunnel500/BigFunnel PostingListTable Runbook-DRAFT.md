# Troubleshoot Exchange Search Issues Related to BigFunnel Mailbox Search Metadata Growth

**Applies to:** Exchange Server Subscription Edition, Exchange Server 2019

## Summary

In on-premises Exchange Server environments, search operations on mailboxes with oversized BigFunnel search metadata can cause prolonged mailbox unavailability, mail delivery delays, and shared mailbox access failures.

The primary indicator is the `BigFunnelPostingListTableTotalSize` property exposed through `Get-MailboxStatistics`. When this value grows significantly, generic or broad search queries may hold mailbox-level resources for extended periods, blocking other operations until the search completes or the database is switched over to another server.

The core operational model separates two remediation patterns:

| Situation | Primary action | Rationale |
|---|---|---|
| Users actively blocked; mail delivery queuing with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy` | Database switchover using `Move-ActiveMailboxDatabase` | Restores user access by moving the active database copy to another server, but does not reduce `BigFunnelPostingListTableTotalSize` |
| `BigFunnelPostingListTableTotalSize` at an elevated threshold with no active user impact | Collect diagnostics, reduce mailbox content, then schedule a mailbox move | A mailbox move may rebuild search metadata structures on the destination, potentially reducing the table size |
| Many mailboxes above threshold | Monitor, prioritize, and batch moves under change control | Exchange Server 2019 workload management (WLM) throttling defaults to 10 simultaneous mailbox moves from the same source or to the same target; batching and automation are required at scale |

> [!IMPORTANT]
> Database switchover is a **database-scoped** operation. Exchange Server does not support failing over an individual mailbox; all failover actions occur at the database level.

## Table of contents

- [Symptoms](#symptoms)
- [Cause](#cause)
- [Detection and monitoring](#detection-and-monitoring)
- [Monitoring automation](#monitoring-automation)
- [Resolution](#resolution)
- [Database failover vs. mailbox move](#database-failover-vs-mailbox-move)
- [Database isolation strategy](#database-isolation-strategy)
- [Concurrency and WLM throttling](#concurrency-and-wlm-throttling)
- [Automated remediation strategy](#automated-remediation-strategy)
- [Operator decision flow](#operator-decision-flow)
- [Operational guardrails and best practices](#operational-guardrails-and-best-practices)
- [Related articles](#related-articles)

## Symptoms

Users may report one or more of the following symptoms, especially on shared mailboxes:

- Search-driven mailbox unavailability: users cannot open on-premises shared mailboxes, or the mailbox becomes unresponsive during or immediately after a search operation.
- "This server is too busy and cannot respond" error in Outlook or Outlook on the web (OWA).
- HTTP 500 errors during search on shared mailboxes in OWA.
- Mail delivery delays or queuing, with transport logs showing `432 4.3.2 STOREDRV.Storage; mailbox server is too busy`.
- Search hangs or long delays in Outlook online mode or OWA when using broad or generic search terms.

These symptoms can persist for hours until either the search operation completes or the database is switched over to another server.

## Cause

Exchange Server 2019 and Exchange Server SE use BigFunnel as the native full-text indexing subsystem integrated into the Exchange Information Store. BigFunnel maintains several per-mailbox data structures to support search, including a Posting List Table that provides full-text search capability for larger mailboxes.

When the Posting List Table grows significantly beyond its intended operating range, broad search queries can trigger long-running decode and evaluation operations that hold mailbox-level resources. During this time, other operations against the mailbox, including mail delivery and client access, may be blocked.

Key characteristics of this issue:

- Mailbox size alone is not the determining factor. A relatively small mailbox can have a large `BigFunnelPostingListTableTotalSize` depending on the mailbox's content shape, folder structure, and search behavior.
- Shared mailboxes are disproportionately affected because multiple concurrent users searching broadly amplify the likelihood of triggering the condition.
- Database failover restores access but does not reduce the table size. Observed behavior showed that a database availability group (DAG) switchover preserved the table at approximately the same size, such as 12 GB before switchover and approximately 11.5 GB after switchover. This confirms that switchover releases the lock but does not rebuild the search metadata.
- Mailbox moves may rebuild the search structures, but the degree of reduction varies. In one observed case, a mailbox move caused the BigFunnel table to fully reduce and begin rebuilding. In another case, the move reduced `BigFunnelPostingListTableTotalSize` from 6.607 GB to 5.32 GB.

## Detection and monitoring

### Primary metric

The primary metric is `BigFunnelPostingListTableTotalSize`, collected through the `Get-MailboxStatistics` cmdlet, which returns information about a mailbox including size, message count, and last access time.

```powershell
Get-MailboxStatistics -Identity "<MailboxIdentity>" |
    Format-List DisplayName, Database, TotalItemSize, ItemCount, BigFunnel*
```

For database-wide assessment:

```powershell
Get-MailboxStatistics -Database "<DatabaseName>" |
    Where-Object { $_.BigFunnelPostingListTableTotalSize -ne $null } |
    Sort-Object BigFunnelPostingListTableTotalSize -Descending |
    Select-Object DisplayName, MailboxGuid, ItemCount, TotalItemSize,
        BigFunnelPostingListTableTotalSize |
    Format-Table -AutoSize
```

`Get-MailboxStatistics` requires at least one of the following parameters: `Server`, `Database`, or `Identity`.

### Detection signals

| Detection area | Signal | Collection method |
|---|---|---|
| User experience | Outlook / OWA search hangs; "server too busy" or 500 errors; shared mailbox cannot be opened | Incident reports, client-side reproduction, OWA HTTP Archive (HAR) capture |
| Transport / Store | Mail delivery queues with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy` | Transport queue monitoring, Store event logs |
| Search test | `Test-ExchangeSearch` shows timeout or failure | Run `Test-ExchangeSearch -Identity "<MailboxIdentity>" -Verbose`; the cmdlet creates a hidden test message, waits for indexing, then searches for it |
| BigFunnel metric | `BigFunnelPostingListTableTotalSize` elevated or growing | `Get-MailboxStatistics -Identity "<MailboxIdentity>" \| Format-List BigFunnel*` |
| Scale assessment | Multiple mailboxes with elevated values on the same database or DAG | Aggregate `Get-MailboxStatistics -Database "<DatabaseName>"` filtered by threshold |

### Monitoring thresholds

The following thresholds are operational examples derived from observed environments. They are not official Exchange Server product limits. Adjust them based on the growth rate and impact patterns observed in your environment.

| Level | Example threshold | Operator action |
|---|---:|---|
| Normal | Below approximately 1.7 GB | Continue periodic monitoring |
| Warning | At or above approximately 1.7 GB | Start proactive review; confirm growth rate; identify mailbox owner; plan content cleanup or move. This example warning value was chosen to provide approximately three days of lead time before potential user impact in the observed environment |
| Critical | At or above approximately 2.0 GB | Treat as high risk for search-related user impact; collect diagnostics; prepare remediation |

> [!NOTE]
> Mailbox size alone is not the deciding factor. A mailbox can be relatively small and still have `BigFunnelPostingListTableTotalSize` well above these thresholds depending on its content shape, item count, folder structure, and search patterns.

### Recommended monitoring cadence

| Population | Cadence | Notes |
|---|---|---|
| Known impacted or high-risk databases | Every 4 hours | Aligns with the BigFunnel internal time-based assistant (TBA) retry cycle |
| Business-critical shared mailboxes | Every 4 hours | Use the warning threshold to create lead time before user impact |
| General shared mailboxes | Daily | Escalate to 4-hour cadence if growth accelerates |
| Post-remediation mailboxes | Daily for 7 days | Confirm the table does not rebound quickly after remediation |

### BigFunnel health signals beyond PostingListTable size

When evaluating mailbox search health, review additional BigFunnel properties:

| Signal | Expected condition |
|---|---|
| `BigFunnelNotIndexedCount` | Should trend low or decreasing |
| `BigFunnelCorruptedCount` | Should be 0; moving the mailbox to another database has been observed to reset this value to 0 |
| `BigFunnelStaleCount` | Should not be growing |

## Monitoring automation

The following script collects `BigFunnelPostingListTableTotalSize` for all mailboxes on specified databases, evaluates configurable thresholds, and exports results to CSV.

Run it in Exchange Management Shell or a PowerShell session where Exchange cmdlets are available. The script is compatible with Windows PowerShell 5.1.

> [!NOTE]
> This script uses CSV export for alerting output. The `Send-MailMessage` cmdlet is obsolete and Microsoft recommends not using it because it does not guarantee secure connections to SMTP servers. Integrate the CSV output with your organization's approved monitoring or alerting platform.

```powershell
<#
.SYNOPSIS
Monitors BigFunnelPostingListTableTotalSize for Exchange mailboxes.

.DESCRIPTION
Collects Get-MailboxStatistics output by database, converts
BigFunnelPostingListTableTotalSize to bytes, evaluates warning and critical
thresholds, and exports CSV results.

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
    [string]$OutputPath = (Join-Path $env:ProgramData "ExchangeBigFunnelPostingListMonitor")
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

    if ($Bytes -ge $CriticalBytes) {
        return "Critical"
    }

    if ($Bytes -ge $WarningBytes) {
        return "Warning"
    }

    return "Normal"
}

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

if ($atRisk.Count -gt 0) {
    Write-RunLog ("Alert: {0} mailbox(es) at warning or critical threshold." -f $atRisk.Count)

    $atRisk |
        Sort-Object PostingListBytes -Descending |
        Select-Object Database, DisplayName, PostingListGB, Status |
        Format-Table -AutoSize
}

Write-RunLog "Monitor run complete."
```

### Scheduling example

Use this example for at-risk databases, running every 4 hours. Run from an elevated prompt. Replace the script path, account, and database list with environment-specific values.

```cmd
schtasks /Create /TN "Exchange BigFunnel PostingListTable Monitor" /SC HOURLY /MO 4 /RU "DOMAIN\ServiceAccount" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%ProgramData%\ExchangeBigFunnelPostingListMonitor\Monitor-BigFunnelPostingList.ps1"" -Databases DB01,DB02 -WarningGB 1.7 -CriticalGB 2.0"
```

## Resolution

### Emergency: database switchover to restore access

Use this procedure when users are actively blocked, the mailbox is inaccessible, or mail delivery is queuing. Do not delay an emergency switchover solely to complete deep diagnostics.

#### Step 1: Capture minimum evidence

If time allows:

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName, Database, BigFunnel*
```

Record the affected mailbox identity, database name, and timestamp of impact.

#### Step 2: Verify target copy health

The database copy that will become the active mailbox database must be healthy and current.

```powershell
Get-MailboxDatabaseCopyStatus "<DatabaseName>"
```

The `Get-MailboxDatabaseCopyStatus` cmdlet returns health and status information about one or more mailbox database copies. Confirm the target copy shows a healthy status with minimal copy queue length.

#### Step 3: Execute the switchover

`Move-ActiveMailboxDatabase` is the on-premises cmdlet for performing a database or server switchover within a Database Availability Group (DAG). Activating a mailbox database copy designates a specific passive copy as the new active copy by dismounting the current active database and mounting the database copy on the specified server.

```powershell
Move-ActiveMailboxDatabase `
    -Identity "<DatabaseName>" `
    -ActivateOnServer "<TargetServer>" `
    -MountDialOverride None `
    -MoveComment "Search-related mailbox access mitigation"
```

Estimated time to complete: approximately 1 minute.

#### Step 4: Verify activation

```powershell
Get-MailboxDatabaseCopyStatus "<DatabaseName>" | Format-List
```

Confirm that the target server now hosts the active copy and that it is mounted.

#### Step 5: Validate recovery

Confirm:

- Mailbox access is restored.
- Mail delivery is restored.
- `BigFunnelPostingListTableTotalSize` remains materially unchanged. This confirms that switchover released the lock but did not reduce the table.

If access is not restored after switchover, escalate through Microsoft Support with timestamps, mailbox identity, database name, switchover details, and available search diagnostics. Failure to clear the lock may indicate a different constraint or incomplete switchover.

### Durable remediation: mailbox move

Use this procedure for planned, durable remediation. A mailbox move is a supported Exchange operation and may rebuild search metadata structures on the destination, potentially reducing `BigFunnelPostingListTableTotalSize`. However, the degree of reduction varies and is not guaranteed.

#### Pre-move: collect diagnostics

Before moving mailboxes affected by search issues, collect diagnostic data using the [Troubleshoot-ModernSearch script](https://microsoft.github.io/CSS-Exchange/Search/Troubleshoot-ModernSearch/) from the Microsoft CSS-Exchange repository. This script can quickly determine whether an item is indexed or not, and why it is not indexed.

```powershell
.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -ItemSubject "<ItemSubject>"

.\Troubleshoot-ModernSearch.ps1 -Server "<ServerName>"

.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<MailboxIdentity>" -Category "NotIndexed"
```

The script supports parameters including `-MailboxIdentity`, `-ItemSubject`, `-MatchSubjectSubstring`, `-FolderName`, `-DocumentId`, `-Category`, `-Server`, and `-IsArchive`.

Collect all log files from the directory where the script was run and upload them to the Microsoft Support case before proceeding with the move.

#### Pre-move: content reduction

Before moving the mailbox, reduce its content where possible. Reducing items first produces the best metadata reduction after the move. Actions to consider, with business approval:

- Review and lower audit log retention settings on affected shared mailboxes.
- Apply messaging records management (MRM) retention policies to default folders.
- Archive older content to archive mailboxes or PST export.
- Hard-delete genuinely obsolete items.

#### Move execution

##### Pre-check

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName, Database, TotalItemSize, ItemCount, BigFunnel*
```

##### Create move request

`New-MoveRequest` begins the process of an asynchronous mailbox move. Use `-CompleteAfter` for scheduled completion, which Microsoft recommends over `-SuspendWhenReadyToComplete`.

```powershell
$CompleteAfter = (Get-Date).Date.AddDays(1).AddHours(22) # Next maintenance window

New-MoveRequest `
    -Identity "<MailboxIdentity>" `
    -TargetDatabase "<TargetDatabase>" `
    -BatchName "BF-PLT-Remediation-YYYYMMDD" `
    -CompleteAfter $CompleteAfter `
    -BadItemLimit 10
```

The `-BadItemLimit` parameter specifies the maximum number of corrupt items allowed before the request fails. The default value is 0. Microsoft recommends a value of 10 or lower. If you set this value to 51 or higher, you must also use the `-AcceptLargeDataLoss` switch.

Alternatively, use `-SuspendWhenReadyToComplete` to suspend the move before it reaches `CompletionInProgress`, then resume manually during a maintenance window:

```powershell
New-MoveRequest `
    -Identity "<MailboxIdentity>" `
    -TargetDatabase "<TargetDatabase>" `
    -BatchName "BF-PLT-Remediation-YYYYMMDD" `
    -SuspendWhenReadyToComplete `
    -BadItemLimit 10
```

##### Monitor progress

```powershell
Get-MoveRequest "<MailboxIdentity>" |
    Get-MoveRequestStatistics |
    Format-List DisplayName, Status, StatusDetail, PercentComplete, BadItemsEncountered
```

##### Complete during approved maintenance window

If using `-SuspendWhenReadyToComplete`:

```powershell
Resume-MoveRequest "<MailboxIdentity>"
```

##### Post-move verification

```powershell
Get-MailboxStatistics "<MailboxIdentity>" |
    Format-List DisplayName, Database, BigFunnel*
```

#### Move duration considerations

Large mailbox moves can take significant time. Plan capacity and maintenance windows accordingly.

#### Move effectiveness

Results vary. The degree of `BigFunnelPostingListTableTotalSize` reduction depends on how much content was cleaned before the move. Some moves produce a complete table rebuild, while others produce a partial reduction. If the table size did not materially decrease, evaluate whether additional content reduction is needed before a subsequent move.

### Search index retry for unindexed items

The `Start-MailboxAssistant` cmdlet is available only in Exchange Server 2019 Cumulative Update 11 (CU11) or later. It starts the `BigFunnelRetryFeederTimeBasedAssistant` assistant, which indexes mailbox items that were not indexed previously.

> [!CAUTION]
> Before using `Start-MailboxAssistant`, you must first create a setting override as described in [Incomplete search results after installing an Exchange Server 2019 update](https://support.microsoft.com/topic/incomplete-search-results-after-installing-an-exchange-server-2019-update-96ae2ef0-4569-4327-8d0c-8a3c1abdc1f6). Incorrect usage of the setting override cmdlets can cause serious damage to your Exchange organization. This damage could require you to reinstall Exchange. Only use these cmdlets as instructed by product documentation or under the direction of Microsoft Customer Service and Support.

```powershell
Start-MailboxAssistant -Identity "<MailboxIdentity>" -AssistantName BigFunnelRetryFeederTimeBasedAssistant
```

The `AssistantName` parameter value `BigFunnelRetryFeederTimeBasedAssistant` is case-sensitive.

The setting override must be removed after the re-indexing completes. It is not recommended to keep it enabled permanently, as it can increase CPU usage.

## Database failover vs. mailbox move

| Dimension | Database failover / switchover | Mailbox move |
|---|---|---|
| Immediate effect | Releases the mailbox lock and restores user access | Does not instantly release an active search lock; mailbox access transfers when the move completes |
| PostingListTable effect | Does not inherently reduce `BigFunnelPostingListTableTotalSize` | May rebuild BigFunnel structures on the destination; the degree of reduction varies |
| Speed | Seconds to minutes; estimated approximately 1 minute to complete switchover | Hours to days depending on mailbox size |
| When to use | Emergency: users are actively blocked, mail is queuing | Durable remediation: after diagnostics are collected and content cleanup is performed |
| Prerequisites | Target passive database copy must be healthy and current | Collect Troubleshoot-ModernSearch data before moving; open a Microsoft Support request if the issue is recurring |
| Caveats | Does not prevent recurrence; table size persists | Large mailboxes take significant time; may cause white space growth on the destination database |

> [!NOTE]
> Database failover and mailbox moves have different effects on `BigFunnelPostingListTableTotalSize`. Failover may restore mailbox accessibility by releasing locks but does not rebuild the BigFunnel posting list table. Mailbox moves can trigger a table rebuild and reduce the reported size, although the degree of reduction may vary and may not result in a complete index recreation in every case.

## Database isolation strategy

For environments with many affected shared mailboxes, consider creating a dedicated, low-density database within each affected DAG to house only the problematic shared mailboxes.

This strategy allows targeted switchovers that minimize impact on other users and streamlines remediation. Move the affected shared mailbox to the dedicated database first, then perform a switchover of that database if needed. This approach avoids affecting other users on the original database.

## Concurrency and WLM throttling

Exchange Server 2019 implements workload management (WLM) throttling. By default, WLM applies a limit of 10 simultaneous mailbox moves from the same source or to the same target. WLM throttling overrides Mailbox Replication Service (MRS) throttling.

A stalled status such as `StalledDueToTarget_MdbReplication`, `StalledDueToTarget_MdbAvailability`, or `StalledDueToTarget_DiskLatency` is typical during migration and does not mean the migration has a problem. The purpose of throttling is to maintain the performance of higher-priority Exchange Server workloads.

### Advanced: increasing the WLM limit

> [!CAUTION]
> Incorrect usage of the setting override cmdlets can cause serious damage to your Exchange organization. This damage could require you to reinstall Exchange. Only use these cmdlets as instructed by product documentation or under the direction of Microsoft Customer Service and Support.

Microsoft recommends:

- Do not set the WLM limit to a value greater than 100.
- Start by changing the WLM limit to 25.
- Monitor Exchange Server performance during the migration.
- To further increase, successively increase the WLM limit by 10 and monitor performance at each step.

To set a WLM limit of 25:

```powershell
$limit = 25

New-SettingOverride -Name "MdbReplication" -Component WorkloadManagement `
    -Section MdbReplication -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "CiAgeOfLastNotification" -Component WorkloadManagement `
    -Section CiAgeOfLastNotification -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "MdbAvailability" -Component WorkloadManagement `
    -Section MdbAvailability -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "DiskLatency" -Component WorkloadManagement `
    -Section DiskLatency -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"

New-SettingOverride -Name "MdbDiskLatency" -Component WorkloadManagement `
    -Section MdbDiskWriteLatency -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"
```

To further update the limit, for example to 35:

```powershell
$limit = 35

Set-SettingOverride -Identity "MdbReplication" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "CiAgeOfLastNotification" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "MdbAvailability" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "DiskLatency" -Parameters @("MaxConcurrency=$limit")
Set-SettingOverride -Identity "MdbDiskLatency" -Parameters @("MaxConcurrency=$limit")
```

Verify the configuration:

```powershell
Get-SettingOverride -Identity "MdbReplication" | Select-Object -ExpandProperty Parameters
```

The setting override cmdlets, such as `New-SettingOverride` and `Set-SettingOverride`, store Exchange customizations in Active Directory. The settings can be organization-wide or server-specific, and they persist across Exchange Cumulative Updates (CUs).

## Automated remediation strategy

Automation should identify, prepare, and stage remediation rather than silently execute disruptive actions.

| Automation layer | Criteria | Action |
|---|---|---|
| Detection | At or above warning threshold | Alert; create operational ticket; tag mailbox and database |
| Critical | At or above critical threshold | Require owner review; collect Troubleshoot-ModernSearch diagnostics; prepare move or switchover plan |
| Active impact | User blocked; mail queuing; search lock suspected | Initiate approved emergency database switchover |
| Durable remediation | Critical mailbox; diagnostics collected; content owner approves cleanup and move | Create move request with `-CompleteAfter` and descriptive `-BatchName` |
| Completion | Move completes during scheduled window | Validate search and BigFunnel metrics |

## Operator decision flow

### Step 1: Is there active user impact?

Active user impact includes:

- Users cannot open the mailbox.
- Searches cause "server too busy" or 500 errors.
- Mail delivery is queuing with `432 4.3.2 STOREDRV.Storage; mailbox server is too busy`.

If yes:

1. Capture minimum evidence with `Get-MailboxStatistics`.
2. Perform an approved database switchover to release the lock.
3. Continue to durable remediation planning.

### Step 2: Has switchover restored access?

| Result | Action |
|---|---|
| Yes | Access is restored. Continue durable remediation because `BigFunnelPostingListTableTotalSize` persists |
| No | Escalate through Microsoft Support with timestamps, mailbox identity, database name, switchover details, and available search diagnostics |

### Step 3: Is `BigFunnelPostingListTableTotalSize` at or above the critical threshold?

If yes, treat as critical:

1. Collect `Troubleshoot-ModernSearch.ps1` diagnostics.
2. Open a Microsoft Support request and provide the collected data.
3. Plan content reduction followed by mailbox move.

### Step 4: Is the mailbox between the warning and critical thresholds?

If yes, treat as warning:

1. Alert.
2. Review growth rate.
3. Coordinate with the mailbox owner.
4. Schedule cleanup or move before user impact occurs.

### Step 5: Before mailbox move

Complete the following:

1. Run `Troubleshoot-ModernSearch.ps1` and export results.
2. Run `Get-MailboxStatistics` and record all `BigFunnel*` fields.
3. Document content reduction actions taken.
4. Create a change record.
5. Create the move request with `-CompleteAfter` or `-SuspendWhenReadyToComplete`.
6. Complete the move during the approved maintenance window.

### Step 6: After mailbox move

1. Re-run `Get-MailboxStatistics` and compare before/after `BigFunnelPostingListTableTotalSize`.
2. If the table size did not materially decrease, evaluate whether additional content reduction is needed before a subsequent move.
3. Add the mailbox to the monitoring cadence, daily for 7 days, to confirm the table does not rebound.

### Step 7: Validate search and user experience

#### Search validation

```powershell
Test-ExchangeSearch -Identity "<MailboxIdentity>" -Verbose
```

`Test-ExchangeSearch` creates a hidden message and an attachment in the specified mailbox that is visible only to Exchange Search, waits for the message to be indexed, then searches for the content. It reports success or failure depending on whether the message is found after the interval set by the `IndexingTimeoutInSeconds` parameter. The default is 120 seconds.

Confirm that there are no timeouts or failures and that search results are returned.

#### Client validation

Test the following client experiences:

- Outlook in cached mode.
- Outlook in online mode.
- OWA searches with common and broad keywords.

Confirm there are no hangs, long delays, or "server too busy" errors.

#### Mail flow validation

Confirm there is no transport queuing and that new mail delivery is timely.

### Step 8: Review BigFunnel health signals

```powershell
Get-MailboxStatistics "<MailboxIdentity>" | Format-List BigFunnel*
```

Focus on `BigFunnelNotIndexedCount`, `BigFunnelCorruptedCount`, and `BigFunnelStaleCount`.

If anomalies are found:

1. Re-run `Troubleshoot-ModernSearch.ps1`.
2. Consider invoking `Start-MailboxAssistant` with `BigFunnelRetryFeederTimeBasedAssistant` if running Exchange Server 2019 CU11 or later and the required setting override is in place.

### Step 9: Document outcome

Capture before/after metrics for operational tracking.

| Metric | Before move | After move |
|---|---:|---:|
| PostingListTable size | X GB | Y GB |
| Mailbox size | X GB | Y GB |
| Item count | X | Y |
| Search performance | Impacted / OK | OK |
| User impact | Yes / No | No |

Tag the mailbox with one of the following statuses:

| Status | Meaning |
|---|---|
| Remediated | Search, mail flow, and BigFunnel indicators are healthy |
| Partially improved | Metrics improved but additional monitoring or action is required |
| Requires further action | PostingListTable size, search behavior, or BigFunnel health remains problematic |

### Step 10: Decide if further action is required

If `BigFunnelPostingListTableTotalSize` is still at or above the critical threshold:

1. Perform additional content reduction.
2. Re-evaluate audit log volume, high-churn folders such as Inbox and Sent Items, and large conversation threads.
3. Plan a second mailbox move if justified.

If the size rebounded quickly within 7 days, investigate:

- Application behavior, including Exchange Web Services (EWS) and service accounts.
- Automated processes generating content.
- Search patterns, especially broad or generic queries.

### Step 11: Return to standard monitoring

Once stable:

1. Move the mailbox back to the normal monitoring cadence.
2. Keep alerts enabled at the warning and critical thresholds.
3. Remove any temporary tracking flags or incident status.

### Step 12: Continuous improvement

Use insights from the remediation to improve future handling:

- Refine thresholds based on observed growth patterns.
- Identify high-risk mailbox profiles: shared mailboxes, high item-churn mailboxes, and audit-heavy mailboxes.
- Identify databases with clustering of at-risk mailboxes.
- Adjust move batching strategy, monitoring frequency, and cleanup policies such as MRM and retention.

### Step 13: Optional preventive optimization

For frequently impacted environments:

- Isolate high-risk shared mailboxes into dedicated databases.
- Apply stricter retention policies and archive strategies.
- Review EWS usage patterns and third-party integrations.

## Operational guardrails and best practices

| Guardrail | Guidance |
|---|---|
| Do not treat failover as durable cleanup | Failover releases the lock but does not reduce `BigFunnelPostingListTableTotalSize` |
| Avoid unsafe data-loss flags in automation | Do not use `-AcceptLargeDataLoss` unless explicitly approved; it is required when `BadItemLimit` is 51 or higher |
| Start with conservative move concurrency | Begin at or below WLM defaults of 10; Microsoft recommends starting at 25 when increasing, maximum 100 |
| Align move finalization to maintenance windows | Use `-CompleteAfter` preferred, or `-SuspendWhenReadyToComplete` for controlled completion |
| Reduce mailbox content before move | Review audit settings, MRM/default folder policies, retention, archive, and item reduction for best results |
| Isolate affected shared mailboxes | Dedicated low-density databases reduce failover blast radius |
| Never assume mailbox size drives table size | A small mailbox can have a large `BigFunnelPostingListTableTotalSize`; growth depends on content shape and search behavior |
| Collect diagnostics before moving | Run `Troubleshoot-ModernSearch.ps1` and provide results to Microsoft Support |
| Do not use `Send-MailMessage` | The cmdlet is obsolete and does not guarantee secure SMTP connections; use CSV export and approved monitoring platforms |

## Related articles

- [Get-MailboxStatistics](https://learn.microsoft.com/powershell/module/exchangepowershell/get-mailboxstatistics)
- [Move-ActiveMailboxDatabase](https://learn.microsoft.com/powershell/module/exchangepowershell/move-activemailboxdatabase)
- [Activate mailbox database copies](https://learn.microsoft.com/exchange/high-availability/manage-ha/activate-db-copies)
- [New-MoveRequest](https://learn.microsoft.com/powershell/module/exchangepowershell/new-moverequest)
- [Test-ExchangeSearch](https://learn.microsoft.com/powershell/module/exchangepowershell/test-exchangesearch)
- [Start-MailboxAssistant](https://learn.microsoft.com/powershell/module/exchangepowershell/start-mailboxassistant)
- [Get-MailboxDatabaseCopyStatus](https://learn.microsoft.com/powershell/module/exchangepowershell/get-mailboxdatabasecopystatus)
- [Mailboxes are stalled during migration](https://learn.microsoft.com/troubleshoot/exchange/migration/mailboxes-stalled-during-migration)
- [New-SettingOverride](https://learn.microsoft.com/powershell/module/exchangepowershell/new-settingoverride)
- [Troubleshoot-ModernSearch](https://microsoft.github.io/CSS-Exchange/Search/Troubleshoot-ModernSearch/)
