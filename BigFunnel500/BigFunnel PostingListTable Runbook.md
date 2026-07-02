BigFunnel PostingListTable Issue Runbook
Microsoft Bug Issue 4271324 — Exchange On-Premises Operational Guidance
0. Executive Summary

The BigFunnel PostingListTable issue (Issue 4271324) causes mailbox-level locks during search operations that can persist for hours, blocking mail delivery and shared mailbox access until the database fails over or the search loop completes. The core operating model separates emergency access restoration (database failover) from durable PostingListTable size reduction (mailbox move after content cleanup).

Situation	Primary Action	RationaleUsers actively blocked; mailbox locked; mail delivery queuing with 432 4.3.2 STOREDRV.Storage; mailbox server is too busy	Database failover / switchover	Releases the mailbox lock and restores access but does not reduce PostingListTable size
BigFunnelPostingListTableTotalSize at warning or critical threshold, no active lock	Collect diagnostics → reduce items → schedule mailbox move	Mailbox move rebuilds BigFunnel structures on destination; intended to reduce PostingListTable size
Many mailboxes above threshold (e.g., ~2,000 mailboxes with table size beyond 2 GB observed in production)	Monitor, prioritize, batch moves under change control	Exchange 2019 WLM throttling defaults to 10 simultaneous mailbox moves from the same source or to the same target; customer reported that moving all 2,000+ affected mailboxes is not feasible without automation and batching
1. Symptoms and Detection Signals

Primary symptom: Search-driven mailbox unavailability on shared mailboxes. The engineering issue description states: "Customer has been noticing mail queuing occurring to a mailbox with the status being '432 4.3.2 STOREDRV.Storage; mailbox server is too busy'. This is caused by a mailbox lock being held. After some troubleshooting, this lock can occur from a few hours to hours or until the database fails over."

Customer-facing symptoms included users unable to open on-premises shared mailboxes with the error**"This server is too busy and cannot respond"** and 500 errors during search on shared mailboxes. The issue was attributed to BigFunnelPostingListTableTotalSize: 22.55 GB (24,216,305,664 bytes), where the maximum should have been below 2 GB.

In a lab reproduction, a shared mailbox with 527,391 items and a PostingListTable of 1.7 GB produced a ~45 second Outlook search delay/hang when searching for the generic terms "c 2 sky." Mail delivery to the mailbox was also delayed while the search was in progress.

At production scale, one environment reported 153 shared mailboxes with BigFunnelPostingListTableTotalSize greater than 10 GB, 42 greater than 20 GB, 20 greater than 30 GB, 12 greater than 40 GB, and 6 greater than 50 GB. Separately, approximately 2,000 mailboxes were identified with the table size beyond 2 GB, with random mailboxes becoming inaccessible when users attempted to use them.

Detection Area	Signal	Collection MethodUser experience	Outlook/OWA search hangs; "server too busy" or 500 errors; shared mailbox cannot be opened	Incident reports, client reproduction, OWA HAR capture
Transport/Store	Mail delivery queues with 432 4.3.2 STOREDRV.Storage; mailbox server is too busy	Transport queue monitoring, Store event logs
Search test	Test-ExchangeSearch shows timeout or failure	Run Test-ExchangeSearch <Mailbox>; one related case showed ResultFound: False, SearchTimeInSeconds: 0, and error "Time out for test thread"
BigFunnel metric	BigFunnelPostingListTableTotalSize approaching or exceeding thresholds	Get-MailboxStatistics <Mailbox> | fl BigFunnel*
Scale assessment	Multiple at-risk mailboxes on same database or DAG	Aggregate Get-MailboxStatistics -Database <DB> filtered by threshold
Monitoring Thresholds

These operational thresholds are derived from case guidance and the engineering reproduction environment:

Level	Threshold	Operator ActionNormal	< 1.7 GB	Continue periodic monitoring
Warning	≥ 1.7 GB	Start proactive review; confirm growth rate; identify mailbox owner; plan cleanup or move. The 1.7 GB threshold was proposed as an early warning to give approximately three days of lead time before user impact
Critical	≥ 2.0 GB	Treat as high risk for lock-related user impact; collect diagnostics; prepare remediation. The 2 GB value is cited as the design threshold above which performance issues occur

Important nuance: Mailbox size alone is not the deciding factor. A mailbox can be relatively small and still have BigFunnelPostingListTableTotalSize beyond ~2 GB depending on mailbox shape and search behavior. The alert threshold should be tailored based on the observed growth rate of the posting list table for each mailbox, as usage patterns and application interactions can cause varying rates of increase.

2. Root Cause and Failure Mode

BigFunnel is the codename for the project that added full-text index capability natively to the Exchange ItemStore. BigFunnel uses three primary data structures per mailbox (shard):

POI (Per-Object-Index): A condensed representation of all textual content in a document, stored as a property on each item. The Uncompressed POI (UPOI) is a portable format copied during move-mailbox; ItemStore converts it to Compressed POI (CPOI) using a per-shard Term Dictionary for storage efficiency.
Bloom Filter Table: Maintains bloom filter bit-vectors for the top 10K–20K documents by static relevancy. Used to efficiently eliminate non-matching documents during query evaluation, expected to average ~500 bytes per record at 1% false-positive rate.
Posting List Table: An optional overflow structure used only for large mailboxes where the Filter table alone is too slow. On large mailboxes, using filters/POI alone is too slow, so posting lists provide full-text search capability. Posting list ingestion and management is expensive and performed asynchronously. Each PL bucket covers a range of terms, with actual term-postings data stored in large long-value fields (estimated 0.5–1 MB per bucket).

The failure mode in Issue 4271324 occurs when the PostingListTable grows beyond its intended operating range. Generic search queries drive long-running BigFunnel posting-list decode/query loops under a mailbox lock. Engineering traces showed the call stack stuck in BigFunnel.PostingList.PostingListDecoder.IndexStreamPostingsGroupDecode.ProcessDecoder and related frames, with a list of 6,853 search terms/scopes in one iDNA trace causing the problematic loop. The business impact: "The long locks cause the mailbox to become unusable till the loop completes thus releasing the lock or the database fails over. Because this is a shared mailbox, this effects multiple users at the same time."

Why mailbox moves help architecturally: During a move-mailbox, the BigFunnel subsystem copies Dictionarynext from the source and stamps it as Dictionarycurrent on the destination. As individual messages are moved, the POI property is moved and recompressed. Filter records are added as part of item save calls. If the number of filter records exceeds the preferred maximum (20K), the system kicks off a background batch-merge request to populate the Posting List table. This rebuilds the structures from scratch on the destination, eliminating stale entries and accumulated metadata from the source.

3. Database Failover vs. Mailbox Move
Dimension	Database Failover / Switchover	Mailbox MoveImmediate effect	Releases the mailbox lock; restores user access	Does not instantly release an active search lock; mailbox access transfers when move completes
PostingListTable effect	Does not inherently reduce BigFunnelPostingListTableTotalSize. Observed: 12 GB before DAG flip → ~11.5 GB after flip	Rebuilds BigFunnel structures on destination. Observed results vary: one case showed complete table reduction and rebuild; another showed 6.607 GB → 5.32 GB after move
Speed	Seconds to minutes (estimated ~1 minute to complete the switchover)	Hours to days depending on mailbox size; one 120 GB mailbox move took ~48 hours
When to use	Emergency: users are actively blocked, mail is queuing, the mailbox lock is held	Durable remediation: after diagnostics collected and content cleanup performed
Prerequisites	Target passive database copy must be healthy and current	Collect Troubleshoot-ModernSearch data before moving; notify BigFunnelCSS@microsoft.com
Caveats	Does not prevent recurrence; table size persists	Large mailboxes take significant time; can cause white space bloat on destination database

Key engineering correction: An internal summary stated "Failover database to another server reduces BigFunnelPostingListTableTotalSize." This was corrected: "This is inaccurate. Failover the database to another server only releases the lock allowing access to the mailbox again. Moving the mailbox to another database after reducing the items in the mailbox will reduce the BigFunnelPostingListTableTotalSize."

Customer-observed evidence: The DAG flip preserved the table at approximately the same size (12 GB → 11.5 GB), confirming failover does not rebuild the table. The subsequent mailbox move caused the BigFunnel table size to reduce and rebuild itself. In another mailbox, the move reduced PostingListTableTotalSize from 6.607 GB to 5.32 GB, but the customer noted the table was still above 2 GB and "The given solution by previous MS engineer is not recreating the table index".

4. Proactive Monitoring Strategy

Monitor business-critical shared mailboxes, high-activity mailboxes, and databases hosting multiple at-risk mailboxes. The primary metric is BigFunnelPostingListTableTotalSize, collected via Get-MailboxStatistics, which returns mailbox size, item count, access timestamps, and move history. Use Get-MailboxStatistics <Mailbox> | fl BigFun* to view all BigFunnel-related properties including BigFunnelPostingListTableTotalSize, BigFunnelNotIndexedCount, and others.

Population	Recommended Cadence	NotesKnown impacted or high-risk databases	Every 4 hours	Aligns with BigFunnel's internal TBA (retry) cycle, which is configured to run every 4 hours to ingest items that need it
Business-critical shared mailboxes	Every 4 hours	Use the 1.7 GB warning threshold to create lead time before impact
General shared mailboxes	Daily	Escalate to 4-hour cadence if growth accelerates
Post-remediation mailboxes	Daily for 7 days	Confirm the table does not rebound quickly after remediation

The monitoring strategy was proposed in case discussions: "Proposed creating a PowerShell script to monitor the posting list table size, suggesting a configurable threshold (e.g., 1.7 GB for a three-day lead time) to trigger alerts before users are affected, allowing the team to address issues proactively."

5. Monitoring Automation — PowerShell Script

Requirements: Run in Exchange Management Shell or a PowerShell session where Exchange cmdlets are available. Compatible with Windows PowerShell 5.1.

<#
.SYNOPSIS
    Monitors BigFunnelPostingListTableTotalSize for Exchange mailboxes.

.DESCRIPTION
    Collects Get-MailboxStatistics output by database, converts
    BigFunnelPostingListTableTotalSize to bytes, evaluates warning and
    critical thresholds, exports CSV results, and optionally sends email.

.NOTES
    Windows PowerShell 5.1 compatible.
    Run with an account that has Exchange RBAC permissions to run
    Get-MailboxDatabase and Get-MailboxStatistics.
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
        [Parameter(Mandatory = $true)][string]$Message,
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
        [Parameter(Mandatory = $false)]$SizeValue
    )

    Write-Verbose ("Converting size value [{0}] to bytes." -f $SizeValue)

    if ($null -eq $SizeValue) { return $null }

    if ($SizeValue -is [string] -and $SizeValue -match "Unlimited") { return $null }

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
        [Parameter(Mandatory = $true)][int64]$Bytes,
        [Parameter(Mandatory = $true)][int64]$WarningBytes,
        [Parameter(Mandatory = $true)][int64]$CriticalBytes
    )

    Write-Verbose ("Evaluating {0} bytes against warning {1} and critical {2}." -f $Bytes, $WarningBytes, $CriticalBytes)

    if ($Bytes -ge $CriticalBytes) { return "Critical" }
    if ($Bytes -ge $WarningBytes) { return "Warning" }
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
            if ($null -eq $bytes) { continue }

            $status = Get-PostingListStatus -Bytes $bytes -WarningBytes $warningBytes -CriticalBytes $criticalBytes

            $results.Add([pscustomobject]@{
                Timestamp                         = Get-Date
                Database                          = $db
                DisplayName                       = $stat.DisplayName
                MailboxGuid                       = $stat.MailboxGuid
                ItemCount                         = $stat.ItemCount
                TotalItemSize                     = [string]$stat.TotalItemSize
                BigFunnelPostingListTableTotalSize = [string]$property.Value
                PostingListBytes                  = $bytes
                PostingListGB                     = [math]::Round(($bytes / 1GB), 3)
                Status                            = $status
                LastLogonTime                     = $stat.LastLogonTime
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
    $body = ($atRisk | Sort-Object PostingListBytes -Descending |
        Select-Object Database, DisplayName, PostingListGB, Status |
        Format-Table -AutoSize | Out-String)

    Write-RunLog "Sending alert email."
    Send-MailMessage -SmtpServer $SmtpServer -From $MailFrom -To $MailTo -Subject $subject -Body $body -Attachments $csvPath
}

Write-RunLog "Monitor run complete."

Scheduling Example (at-risk databases, every 4 hours)
# Run from an elevated prompt when creating the scheduled task.
# Replace script path, account, and database list with environment-specific values.
schtasks /Create /TN "Exchange BigFunnel PostingListTable Monitor" `
    /SC HOURLY /MO 4 `
    /RU "DOMAIN\ServiceAccount" `
    /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%ProgramData%\ExchangeBigFunnelPostingListMonitor\Monitor-BigFunnelPostingList.ps1`" -Databases DB01,DB02 -WarningGB 1.7 -CriticalGB 2.0"


A reference helper function for filtering shared mailboxes above 1.7 GB was also shared in case correspondence:

# Helper: BigFunnelPostingListTableTotal Greater than 1.7 GB
$thresholdBytes = 1.7 * 1GB

6. Manual Remediation Procedures
A. Emergency Database Failover / Switchover

Use this procedure when users are actively blocked, the mailbox lock is held, or mail delivery is queuing.

Step 1 — Capture minimum evidence (if time allows):

Get-MailboxStatistics "<AffectedMailbox>" | fl DisplayName,Database,BigFunnel*


Record the affected mailbox identity, database name, and timestamp of impact.

Step 2 — Verify target copy health: The database copy that will become the active mailbox database must be healthy and current.

Get-MailboxDatabaseCopyStatus "<DatabaseName>"


Step 3 — Execute the switchover: Move-ActiveMailboxDatabase is the on-premises cmdlet for performing a database or server switchover.

Move-ActiveMailboxDatabase -Identity "<DatabaseName>" `
    -ActivateOnServer "<TargetServer>" `
    -MountDialOverride None `
    -MoveComment "BigFunnel lock release for Issue 4271324"


Step 4 — Verify activation:

Get-MailboxDatabaseCopyStatus "<DatabaseName>" | Format-List


Confirm the target server now hosts the active copy and that it is mounted.

Step 5 — Validate recovery and record outcome: Confirm mailbox access and mail delivery are restored. Re-run Get-MailboxStatistics and document that the PostingListTable size remains materially unchanged (confirming failover released the lock but did not reduce the table).

B. Durable Mailbox Move

Use this procedure for planned, durable remediation after diagnostics have been collected.

Pre-move requirements — Product Group guidance:

Do NOT move mailboxes without first collecting data and notifying BigFunnelCSS@microsoft.com. The internal CSS guidance states: "DO NOT just move the mailbox to see if that works. We need additional data to help determine why this might be occurring."

Run Troubleshoot-ModernSearch.ps1 against affected mailboxes. The script determines whether an item is indexed, why it is not indexed, and outputs diagnostic logs. Run it with the -MailboxIdentity and -ItemSubject parameters for specific items, or with the -Server parameter for a server-wide assessment:
.\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<Alias>" -ItemSubject "<MessageSubject>"
.\Troubleshoot-ModernSearch.ps1 -Server <ServerName>

Collect all log files from the directory where the script was run.
Notify BigFunnelCSS@microsoft.com with the case number and confirm logs are uploaded.

Pre-move content reduction:

Engineering guidance recommended: "Best to reduce the items in the mailbox, there is a good chunk of them for Audits on the mailbox. They could lower what they currently have set and possibly look into what they currently have set for their MRM settings on some default folders and see if they can reduce those items. After the items have been reduced, the quickest way to then reduce the Posting List Table size is a mailbox move."

Actions to consider (with business approval):

Review and lower audit log retention settings on affected shared mailboxes
Apply MRM retention policies to default folders
Archive older content to archive mailboxes or PST export
Hard-delete genuinely obsolete items

Move execution:

# Pre-check
Get-MailboxStatistics "<MailboxIdentity>" | Format-List DisplayName,Database,TotalItemSize,ItemCount,BigFunnel*

# Create move request with suspended completion
New-MoveRequest -Identity "<MailboxIdentity>" `
    -TargetDatabase "<TargetDatabase>" `
    -BatchName "BF-PLT-Remediation-YYYYMMDD" `
    -SuspendWhenReadyToComplete `
    -BadItemLimit 10


New-MoveRequest begins an asynchronous mailbox move. The -SuspendWhenReadyToComplete switch suspends the move before it reaches CompletionInProgress status, allowing controlled cutover during a maintenance window. The -BadItemLimit parameter specifies the maximum number of corrupt items allowed; Microsoft recommends 10 or lower. Values of 51 or higher require the -AcceptLargeDataLoss switch.

# Monitor progress
Get-MoveRequest "<MailboxIdentity>" | Get-MoveRequestStatistics |
    Format-List DisplayName,Status,StatusDetail,PercentComplete

# Complete during approved maintenance window
Resume-MoveRequest "<MailboxIdentity>"

# Post-move verification
Get-MailboxStatistics "<MailboxIdentity>" | Format-List DisplayName,Database,BigFunnel*


Move duration caveat: One 120 GB mailbox move took approximately 48 hours. Plan capacity and maintenance windows accordingly for large mailboxes.

Move effectiveness caveat: Results vary. One move reduced the PostingListTable from 6.607 GB to 5.32 GB — a reduction but not a full rebuild to near-zero. Another move caused the table to "full reduced and started to rebuild itself". The degree of reduction depends on how much content was cleaned before the move.

7. Automated Remediation Strategy

Automation should identify, prepare, and stage remediation rather than silently execute disruptive actions.

Automation Layer	Criteria	ActionDetection	≥ 1.7 GB	Alert; create operational ticket; tag mailbox/database
Critical	≥ 2.0 GB	Require owner review; collect Troubleshoot-ModernSearch diagnostics; prepare move or failover plan
Active impact	User blocked; mail queuing; search lock suspected	Initiate approved emergency failover (Section 6A)
Durable remediation	Critical mailbox; diagnostics collected; content owner approves cleanup + move	Create move request with -SuspendWhenReadyToComplete and descriptive -BatchName
Completion	Move reaches auto-suspended state (95% complete)	Resume during approved maintenance window after change approval
Concurrency and WLM Throttling

Exchange Server 2019 implements workload management (WLM) throttling. By default, WLM applies a limit of 10 simultaneous mailbox moves from the same source or to the same target. WLM throttling overrides Mailbox Replication Service (MRS) throttling. The stalled status (e.g., StalledDueToTarget_MdbReplication) is typical and does not mean the migration has a problem — its purpose is to maintain the performance of higher-priority Exchange workloads.

To increase the WLM limit, Microsoft recommends not setting it above 100, starting at 25, and increasing by 10 while monitoring Exchange performance at each step. The New-SettingOverride cmdlet with -Component WorkloadManagement is used to adjust the limit:

$limit = 25
New-SettingOverride -Name "MdbReplication" -Component WorkloadManagement `
    -Section MdbReplication -Parameters @("MaxConcurrency=$limit") `
    -Reason "Allow more simultaneous mailbox moves"
# Repeat for CiAgeOfLastNotification, MdbAvailability, DiskLatency, MdbDiskWriteLatency

Database Isolation Strategy

Case guidance recommended creating a dedicated database (e.g., "PLT01") within each affected DAG to house only problematic shared mailboxes. This allows targeted failovers that minimize impact on other users and streamlines remediation. The presence of affected mailboxes across multiple DAGs increases administrative overhead, but automation can reduce the manual effort.

8. Product Group Guidance and Escalation Expectations
Data Collection Before Moves

For BigFunnel search-related cases, run Troubleshoot-ModernSearch.ps1 before mailbox moves where feasible. The script supports several diagnostic modes:

Single item analysis: .\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<Alias>" -ItemSubject "<Subject>"
Server-wide assessment: .\Troubleshoot-ModernSearch.ps1 -Server <ServerName>
Category breakdown: .\Troubleshoot-ModernSearch.ps1 -MailboxIdentity "<Alias>" -Category "NotIndexed"

Key diagnostic properties to review include IndexStatus, IndexingErrorMessage, and IsPermanentFailure.

For items in permanent failure with FailedToConnect: skip adding Poi, a temporary SettingOverride can enable re-indexing via Start-MailboxAssistant -Identity <Mailbox> -AssistantName BigFunnelRetryFeederTimeBasedAssistant (available in Exchange 2019 CU11 or later). The override must be removed after use, as it is not recommended to keep on permanently.

Fix Timeline Communication

Do not provide a committed CU, HU, or release date unless Microsoft has provided an official customer-ready statement. Internal guidance explicitly corrected a prior statement: "Do not provide that the fix will be released in the next CU update. That has never been provided in any official statement from PG." The issue has been marked as "Approved for vNext CU1," but engineering noted "that doesn't mean it will be in CU1 for Exchange SE as the work hasn't been completed" and until it is checked into code, the timeline should not be communicated as confirmed.

Emergency Access — Do Not Delay Failover for Diagnostics

If users are actively down, do not delay an emergency lock-release failover solely to complete deep diagnostics. Capture the minimum pre-action state (Get-MailboxStatistics output, timestamps, affected mailbox identity) and record why immediate mitigation was required. Full diagnostic collection can follow after access is restored.

9. Operational Guardrails and Best Practices
Guardrail	Guidance	EvidenceDo not treat failover as durable cleanup	Failover releases the lock but does not reduce PostingListTable size	Engineering correction: failover only releases the lock; moving the mailbox after item reduction reduces the size. Observed: 12 GB → 11.5 GB post-flip
Avoid unsafe data-loss flags in automation	Do not use -AcceptLargeDataLoss unless explicitly approved and risk-accepted	Required when BadItemLimit is set to 51 or higher in Exchange 2010+
Start with conservative move concurrency	Begin below WLM limits; monitor MRS/WLM status	Default: 10 simultaneous moves from same source/target. Microsoft recommends starting at 25, max 100
Align move finalization to maintenance windows	Use -SuspendWhenReadyToComplete or -CompleteAfter	New-MoveRequest supports both patterns for controlled completion
Reduce mailbox content before move	Review audit settings, MRM/default folder policies, retention, archive, and item reduction	Engineering guidance: reducing items first produces the best PostingListTable reduction after move
Isolate affected shared mailboxes	Dedicated low-density databases reduce failover blast radius	Recommended: create a separate database within each DAG for problematic mailboxes, allowing targeted failovers
Never assume mailbox size drives table size	A small mailbox can have a large PostingListTable	Confirmed: mailbox size alone is not the deciding factor; table growth depends on mailbox shape and search behavior
Collect diagnostics before moving	Run Troubleshoot-ModernSearch.ps1 and notify BigFunnelCSS@microsoft.com	Internal CSS guidance explicitly prohibits moves without prior data collection
10. Operator Decision Flow

1. Is there active user impact? If users cannot open the mailbox, searches are causing "server too busy" or 500 errors, or mail delivery is queuing with 432 4.3.2 STOREDRV.Storage, capture minimum evidence and perform an approved database switchover to release the lock (Section 6A).

2. Has failover restored access?

Yes: Access is restored. Continue to Step 3 for durable remediation because the PostingListTable size persists.
No: Escalate through Microsoft Support with timestamps, mailbox identity, database name, failover details, and any available search diagnostics. The failure to clear the lock may indicate a different constraint or an incomplete switchover.

3. Is BigFunnelPostingListTableTotalSize ≥ 2.0 GB? Treat as critical. Collect Troubleshoot-ModernSearch.ps1 diagnostics. Notify BigFunnelCSS@microsoft.com. Plan content reduction followed by mailbox move.

4. Is the mailbox between 1.7 GB and 2.0 GB? Treat as warning. Alert, review growth rate, coordinate with the mailbox owner, and schedule cleanup or move before user impact occurs.

5. Before mailbox move:

Run Troubleshoot-ModernSearch.ps1 and export results
Run Get-MailboxStatistics and record all BigFunnel* fields
Document content reduction actions taken
Create a change record
Create the move request with -SuspendWhenReadyToComplete
Resume completion during the approved maintenance window

6. After mailbox move:

Re-run Get-MailboxStatistics and compare before/after BigFunnelPostingListTableTotalSize
If the table size did not materially decrease, evaluate whether additional content reduction is needed before a subsequent move
Add the mailbox to the monitoring cadence (daily for 7 days) to confirm the table does not rebound
