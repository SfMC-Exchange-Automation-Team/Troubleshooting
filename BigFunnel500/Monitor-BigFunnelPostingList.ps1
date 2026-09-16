#Requires -Version 5.1

<#
.SYNOPSIS
Monitors BigFunnelPostingListTableTotalSize for Exchange mailboxes, with
growth-rate trending and time-to-threshold projection.

.DESCRIPTION
Collects Get-MailboxStatistics output by database, converts
BigFunnelPostingListTableTotalSize to bytes, evaluates thresholds, compares
against an earlier run to derive growth rate and projected days to the
critical threshold, and exports CSV results.

On builds where the posting list table reads 0 B for every mailbox in scope,
growth is measured on IndexPayloadBytes instead and the at-risk mailboxes are
ranked by rate rather than projected to a date. The thresholds are sizes of the
posting list table and have never been validated against the payload counter,
so extrapolating one to the other would be arithmetic on unrelated quantities.
The ordering is still the answer to "which mailbox is next"; only the deadline
is withheld.

Designed to run unattended on a schedule. Every failure mode is contained at
the smallest possible scope: a single unparseable mailbox does not abort its
database, and a single failed database does not abort the run.

.PARAMETER Databases
Explicit database names. When omitted, databases are discovered according to
-Scope.

.PARAMETER Scope
All    - every mounted database in the organization (default). One run answers
         for the whole DAG, which is what somebody running this by hand almost
         always wants: the alternative is running it once per node and adding
         the results up.
Local  - only databases whose active copy is currently mounted on this server.
         Pass this for a scheduled task registered on more than one DAG member.
         Without it each node collects the whole organization, so a 3-node DAG
         does the same work three times and raises three alerts per mailbox.
Ignored when -Databases is supplied.

The default was Local until v1.7.7, for a reason that no longer exists: under
the old in-process snap-in fallback a -Scope All run from a bare powershell.exe
failed ACCESS_DENIED on every remote database and reported Partial. v1.6.x
dropped the snap-in for a remote Exchange runspace, which reaches any database
in the organization regardless of which node holds it. Measured on w25-ex01 in
the same minute: Local collected 50 mailboxes across 2 databases, All collected
97 across all 4, both from a scheduled task under a batch logon.

.PARAMETER ThresholdMode
Fixed     - use -WarningGB and -CriticalGB as given (default).
Adaptive  - raise the thresholds to the population's 95th and 99th percentile
            when those sit above the fixed values. Adaptive only ever raises,
            never lowers: the fixed values remain a floor, so an organization
            whose tables all sit high alerts on genuine outliers instead of on
            everyone, while a healthy organization is unaffected. Falls back to
            Fixed when the sample is smaller than -AdaptiveMinimumSample or
            when the two percentiles do not separate.

.PARAMETER AdaptiveMinimumSample
Smallest mailbox population for which -ThresholdMode Adaptive will compute
percentiles. Below this the percentiles are dominated by a handful of values
and the fixed thresholds are used instead.

.PARAMETER TrendBaselineHours
Minimum age of the run used as the growth baseline. A short window magnifies
noise: at a 4-hour cadence, a 4-hour delta is multiplied by six to reach a
per-day rate, and the projection swings with it. The newest run at least this
old is preferred; if the history is not that deep, the oldest available run is
used instead and the actual window is reported.

Accepts 1 to 8760. Zero is rejected rather than treated as "no minimum":
it would make every baseline old enough by definition, silencing the warning
that the window was too narrow while the rates were still computed and
reported from it.

.PARAMETER MaxRunMinutes
Wall-clock budget for collection. Remaining databases are skipped and reported
as not collected once it is spent, so a slow run cannot overrun its own
schedule interval. 0 disables the budget.

This bounds the work the script does; it cannot interrupt a single store call
that never returns. Set -ExecutionTimeLimit on the scheduled task as the
backstop for that case.

.PARAMETER MaxAlertDetail
Maximum number of per-mailbox alert lines written to the log per category.
A server in a bad state can hold thousands of at-risk mailboxes, and one log
line each turns the run into its own disk-space problem.

.PARAMETER AllocationEvidenceMB
How large a mailbox must be before a 0 B posting list table on it counts as
evidence that the counter is not being populated. Below this a 0 B reading is
reported as NotAllocated and means nothing is wrong.

Only used as a fallback. Where any mailbox in scope has a populated table, the
run calibrates against that instead and this value is ignored - see
Get-AllocationEvidenceBytes.

The default of 64 MB is deliberately well clear of the measured allocation
point. On Exchange Server SE 15.2.2562.17 a mailbox holding 6.87 MB still read
0 B while one holding 16.33 MB had allocated 3.344 MB, so allocation happens
somewhere between the two. 64 MB is roughly four times the upper bound, which
keeps a "the counter is blind here" verdict close to unarguable at the cost of
more runs reporting MetricInconclusive on a small estate.

Lower it if the estate is uniformly small and the inconclusive verdict is
unhelpful; raise it to demand stronger evidence before the run alerts.

.PARAMETER NoElevate
Do not relaunch elevated. The run continues as whatever account started it and,
if that account cannot refresh the stable files, fails honestly with exit 3.

Pass this when the output directory is somewhere the current account already
owns - a scratch path under TEMP, a per-user directory, a test harness - where
the consent prompt would buy nothing. Also the way to run the monitor from a
non-interactive context that has already been given the rights it needs.

.PARAMETER Quiet
Suppress the console report. The log file, the timestamped CSV, latest.csv,
latest-summary.json and the exit code are all unaffected: this switch removes
decoration, never evidence.

Intended for a wrapper or a monitoring agent that reads the exit code or parses
the summary and would otherwise have to skip past a progress block it did not
ask for. Not a quieter mode for an operator - an operator wants the report, and
-Verbose is the switch for wanting more of it.

.PARAMETER PassThru
Emit the collected rows on the success stream in addition to writing them to the
CSV, so the run can be assigned and queried rather than only read:

    $r = .\Monitor-BigFunnelPostingList.ps1 -Scope All -PassThru
    $r | Where-Object Status -eq 'Critical' | Select-Object DisplayName, PostingListGB
    $r | Sort-Object GrowthGBPerDay -Descending | Select-Object -First 5

These are the same objects the report and the CSV are both built from, typed
BigFunnel.PostingListRow, not a re-read of the file. The growth fields come back
as numbers - Import-Csv would hand back text that sorts lexically, so a
Sort-Object on GrowthGBPerDay would put 0.9 above 0.0787.

Off by default because the report already prints and a bare run would follow it
with a hundred objects through the default formatter. Returns nothing across an
elevation relaunch, since the rows are built in the elevated child; the run warns
when both apply.

.PARAMETER ConsoleRelayPath
Internal plumbing, set by the script on itself when it relaunches elevated. Not
for hand use, and it is not a way to capture the report - redirect stdout, or
read the log, for that.

An elevated process cannot attach to the console of the non-elevated one that
asked for it, so the relaunch gets a window of its own that Windows closes as
soon as the run ends. The child writes each console line here as it prints it,
and the parent replays the file into its own window before exiting with the
child's code. Skipped where TEMP is not set, in which case the parent falls back
to reporting the exit code and the log path.

.PARAMETER ExitNonZeroOnAlert
Return a non-zero exit code when the run has something to say: 1 when at-risk
mailboxes are found, 5 when the metric could not be read on any indexed
mailbox. Off by default so that "found problems" is not confused with "the
monitor broke".

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1

Collects every mounted database in the organization, using the default
1.7 GB / 2.0 GB thresholds, and writes to %ProgramData%. One run answers for the
whole DAG regardless of which node it is started from.

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1 -Scope Local

Collects only the databases whose active copy is mounted on this server. This is
the form to schedule when the task is registered on more than one DAG member.

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1 -Databases DB01, DB02 -Verbose

Collects two named databases. The console report appears either way; -Verbose
adds the timestamped log stream underneath it, and lists the mailboxes that hold
a posting list table but are reading Normal.

.EXAMPLE
.\Monitor-BigFunnelPostingList.ps1 -ThresholdMode Adaptive -ThrottleDelaySeconds 30

Raises the thresholds to the population's 95th/99th percentile where those sit
above the fixed values, and pauses 30 seconds between databases to spread the
load on a busy store.

.EXAMPLE
$cred = Get-Credential -Message 'Service account for the monitor task'
Register-ScheduledTask -TaskName 'BigFunnel PostingList Monitor' -Force `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
        '"C:\Scripts\Monitor-BigFunnelPostingList.ps1" -Scope Local')) `
    -Trigger (New-ScheduledTaskTrigger -Once -At 00:05 `
        -RepetitionInterval (New-TimeSpan -Hours 4)) `
    -User $cred.UserName -Password $cred.GetNetworkCredential().Password `
    -RunLevel Highest `
    -Settings (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable)

Schedules the monitor every 4 hours. -ExecutionTimeLimit is the backstop for a
store call that never returns; -MultipleInstances IgnoreNew is belt and braces
alongside the script's own concurrency lock.

-Password is not optional and -User on its own is not equivalent. Without it the
principal defaults to LogonType Interactive, which means "run only when this
user is logged on" - the task registers, never runs, and reports LastTaskResult
0x41303 forever. Ticking "Do not store password", or -LogonType S4U, gives a
task that does run and then cannot open the Exchange runspace, because an S4U
logon carries no network credential and the runspace is a network logon even
against this same server. Confirm with:

    (Get-ScheduledTask -TaskName 'BigFunnel PostingList Monitor').Principal.LogonType

which has to read Password. Where a stored password is not permitted, use
-Credential on the script instead. A gMSA will not work here.

.NOTES
Windows PowerShell 5.1 compatible. Read-only against Exchange.

Exit codes:
  0  Completed. All in-scope databases collected.
  1  Completed, at-risk mailboxes found (-ExitNonZeroOnAlert only).
  2  Completed with partial failure. At least one database was not collected,
     or collection was cut short by -MaxRunMinutes.
  3  Fatal. Pre-flight failed, no databases were in scope, no Exchange
     runspace could be opened, or the run could not publish latest.csv /
     latest-summary.json. The last of those can follow a collection that
     succeeded completely: the figures are in the timestamped CSV, but the two
     files a scheduled consumer polls still describe an earlier run, so the run
     is reported as failed rather than as healthy.
  4  Another instance is already running.
  5  Completed, but every mailbox large enough to have allocated a posting
     list table reported it as 0 B, so no threshold in this run could have
     fired (-ExitNonZeroOnAlert only). Kept distinct from 1 on purpose: 1
     means a mailbox crossed a line, 5 means there was no line to cross.
     Returning 0 here would report "nothing found" from a run that could not
     have found anything. A scope holding only mailboxes too small to have
     allocated does not reach this code - see MetricInconclusive below.
  6  Completed, nothing over threshold, but at least one mailbox is projected
     to cross the critical threshold within 3 days (-ExitNonZeroOnAlert only).
     Kept distinct from 1 so that 1 keeps meaning "over the line now": 1 is
     work today, 6 is work before the weekend. A run cannot return both. Where
     a breach and a projection coexist 1 wins, and the projections are still
     in the log, the CSV, and the Emerging count.

Invoke with powershell.exe -File, not -Command. -Command collapses every
non-zero exit to 1, so 2, 3, 4, 5 and 6 all arrive as "at-risk mailboxes found"
and a caller cannot tell a metric outage or a failed database from a threshold
breach. Measured, not assumed: a script whose only statement is "exit 5"
returns 5 under -File and 1 under -Command, with no errors involved. The
scheduled-task example above already uses -File.

Status values in the detail CSV:
  Critical      at or above the critical threshold
  Warning       at or above the warning threshold
  NotPopulated  BigFunnelPostingListTableTotalSize is 0 B on a mailbox
                BigFunnel reports as indexed (BigFunnelIndexedCount above
                zero) that is also large enough to have allocated the table.
                The metric this monitor is built on is not being populated
                for that mailbox, so its size cannot be read as healthy - it
                cannot be read at all. Confirmed on Exchange Server SE
                15.2.2562.17, where a fully indexed mailbox kept its index in
                BigFunnelTotalPOISize, BigFunnelLargePOITableTotalSize and
                BigFunnelFilterTableTotalSize while the posting list table
                stayed at exactly 0 B. Check IndexPayloadBytes for the size
                that is actually there.
  NotAllocated  the same 0 B reading on an indexed mailbox holding less
                content than this build allocates a posting list table at.
                Expected, not a fault: the table has not been created yet
                because there is not enough in the mailbox to warrant one.
                Reported rather than called Normal because the size still
                cannot be read, but it is not evidence of anything wrong.
                Mailboxes whose TotalItemSize cannot be parsed, or that
                report Unlimited, land here too - they cannot be judged
                either way, and a wrong "nothing is wrong" on one row is
                cheaper than a wrong "your monitoring is blind" on the run.
  Normal        below the warning threshold, with no contradicting counter

Where the allocation bar sits is decided per run, not fixed. Where any mailbox
in scope has a populated posting list table, the smallest such mailbox is a
direct observation of this build's allocation point and is used as the bar,
clamped up to a 16 MB floor. Where none has, -AllocationEvidenceMB is used
instead. Measured on 15.2.2562.17: 3.45 MB and 6.87 MB of content both read
0 B, 16.33 MB read 3.344 MB, so allocation happens between the two.
AllocationEvidenceMB and AllocationEvidenceBasis in latest-summary.json report
the bar in force and which of the two it came from.

If NotPopulated covers every eligible mailbox, this build does not surface the
metric and a clean run proves nothing about posting list growth. Treat that as
a monitoring gap to raise, not as a pass. The run says so itself rather than
leaving it to be noticed: Status in latest-summary.json becomes
MetricUnavailable, and the exit code becomes 5 under -ExitNonZeroOnAlert. The
comparison is against eligible mailboxes rather than all collected rows on
purpose. Health, arbitration, system and archive mailboxes hold no index, so
they can never reach this state and would otherwise mask a total outage; and
mailboxes below the allocation bar read 0 B correctly, so counting them as
witnesses would escalate every small estate to a false outage.

MetricValidation in latest-summary.json carries the run's verdict on its own
instrument, independent of any threshold:
  Confirmed     something in scope has a populated table, so the counter
                demonstrably works here
  Blind         nothing does, and mailboxes large enough to have allocated
                are reading 0 B anyway
  Inconclusive  nothing does, and nothing in scope is large enough to settle
                it either way

On that build the run still answers which mailbox is next. Growth is measured
on IndexPayloadBytes, DaysToCritical is left empty on every row, and the log
carries a "Fastest growing #n" ranking in place of the emerging-risk list,
which is keyed on a projection that cannot be made there.

Which counter to trend on is decided per mailbox, not once per run. An estate
part-way through the transition holds both kinds at once, and a run-level
choice would drag every mailbox onto whichever counter the majority - or in an
earlier revision of this script, any single mailbox - happened to populate.
That put mailboxes reading 0 B onto the posting list table, where their growth
measured as a constant zero and the ranking that exists to name the next
mailbox went blind for most of the population. TrendMetric in
latest-summary.json is then Mixed, and TrendedOnPayload gives the size of the
group that fell back.

Read Emerging as the whole answer only when TrendedOnPayload is 0. Above zero
it can only name mailboxes from the group the thresholds can see, because it is
keyed on a projected date and no date is produced on the fallback path. Alert
on Growing alongside it, and on GrowingRanked for the part of the estate that
has an order but no dates.

Requires Exchange RBAC permission to run:
- Get-ExchangeServer
- Get-MailboxDatabase
- Get-MailboxStatistics

It binds those three through a remote Exchange runspace, opening one against
this server's PowerShell vdir when the session does not already have one, and
reusing an existing import when it does. The in-process snap-in is never used.
That is a hard requirement, not a preference: the snap-in binds the store
in-process and cannot read a database mounted on another DAG member, so a
-Scope All run under it drops every remote database and still reports a
complete-looking result. Measured on a 3-node DAG, same server and minute, the
snap-in saw 50 mailboxes across 2 of 4 databases and the runspace saw 97 across
all 4. A run that cannot open a runspace exits 3 rather than collecting a
subset. Where the local vdir is not the one to use, -ConnectionUri points at
any other Exchange server in the organisation; it does not have to be the node
holding the database.

A run reports on the console without being asked. Every run prints a header, a
line per database as it is collected, any warning or error inline, and then a
verdict block: the run status, the counts behind it, the three worst affected
mailboxes, the paths to the CSV and the log, and the exit code. The status and
the counts are coloured - green for OK, yellow for a finding, red for a failure.

-Verbose adds to that rather than replacing it. What it adds is the timestamped
[INFO]/[WARN]/[ERROR] log stream, the same text that goes to the .log file, so
it is the troubleshooting layer and not the only way to learn what happened. It
also fills in the "Posting list table present on N of M" roll call, which by
default names only the mailboxes that are a finding: a Normal row is the absence
of one, and a verdict block that spends a line each saying mailboxes are fine is
the wall of text this block exists to avoid. The count is printed either way, and
so is a line saying how many were held back, so a clean run still answers "how
many carry the counter" without answering "and here are all their names".
Before v1.7.6 it was the only way: a default run printed nothing at all, which
left an operator with a returned prompt and no idea whether the run had found
something, found nothing, or never looked. Per-mailbox detail is deliberately
NOT echoed - a bad estate holds hundreds of at-risk mailboxes, and one line each
pushes the verdict off the top of the window. It is in the CSV, and in the log.

-Quiet removes the report entirely, for a caller that parses instead of reads.

Where a finding is reported above exit code 0, both are correct: codes 1, 5 and
6 are gated behind -ExitNonZeroOnAlert so that adding this monitor to an
existing scheduler cannot start failing tasks on day one. The report says so on
the line below the exit code rather than leaving the contradiction on screen.

Outputs, written to -OutputPath:
  BigFunnelPostingListMonitor-<runId>.csv   per-run detail, retained
  BigFunnelPostingListMonitor-<runId>.log   per-run log, retained
  latest.csv                                stable copy of the newest detail
  latest-summary.json                       stable run summary for monitoring

The two stable files are deliberately named outside the
BigFunnelPostingListMonitor-* pattern so that neither the baseline scan nor
the retention sweep can pick them up.

latest-summary.json is written on every run that gets far enough to have an
output directory, including runs that abort - unless the file itself cannot be
written, which is the one case the file cannot report about itself. A run that
fails to refresh either stable file exits 3 and names the reason in
PublishErrors, so a consumer polling these two is never left reading an older
run behind a success code. Measured on w25-ex01: a non-elevated session could
create its timestamped CSV and log but not overwrite a latest.csv and
latest-summary.json owned by BUILTIN\Administrators, and before this the run
warned twice and exited 0 with a summary 19 hours stale.

The script elevates itself. If it is not already running as administrator it
relaunches itself with the same parameters under -Verb RunAs, waits for that run
to finish, and exits with its exit code. Start it from an elevated shell and you
never see a prompt; start it from an ordinary one and you approve a prompt. Three
details differ from the usual four-line version of this and all are deliberate:
it waits and propagates the child's exit code, because this script's exit code
is its interface and returning 0 the moment the child starts would report every
run as clean; the relaunch command line is rebuilt from PSBoundParameters
rather than a hand-kept list, so a parameter added later cannot be silently
dropped on the way across; and the child's console report is relayed back into
the window the operator is actually looking at.

That last one matters more than it sounds. An elevated process cannot attach to
the console of the non-elevated one that launched it, so the relaunch gets a
window of its own and Windows closes it the moment the run ends. Without the
relay the operator approves a consent prompt, watches a console flash past, and
is left with two lines and a pointer to a log file - on a script whose entire
reporting layer exists so that a run does not have to be read out of a log
afterwards. The child writes each console line to a relay file in the parent's
TEMP as it prints it, and the parent replays the file, styles included, before
exiting with the child's code. It is written line by line rather than buffered so
that a child that dies mid-run still relays what it managed to say, and the
parent falls back to the old exit-code-and-log-path line if nothing arrives.

Three cases deliberately do not prompt. A non-interactive session has no desktop
to show consent on, so it warns that the task wants -RunLevel Highest and
continues. A run with -Credential cannot relaunch, because a PSCredential does
not cross a process boundary and dropping it would quietly change how the
runspace authenticates. And -NoElevate suppresses it outright, which is what to
pass when the output directory is somewhere the current account already owns -
a scratch path under TEMP, say - and a consent prompt would be pure friction.
In all three the run continues and, if it really cannot publish, fails honestly
with exit 3 rather than silently. Refusing the consent prompt is also exit 3: a
monitor that was not allowed to run has not run.

latest-summary.json always carries the same field
set. Alert on Status not in (OK, MetricInconclusive) and read the counts beside
it for what was found; Completed = false catches the abort reasons and nothing
else, so it is a useful second condition but not a substitute. latest.csv is
only refreshed when a run produced detail, so it can legitimately be older than
the summary beside it - that deliberate skip is not a publish failure and does
not affect the exit code.

Status on a run that completed is one of:
  OK                  the run collected its scope, the counter was readable,
                      and no mailbox is at or approaching a threshold
  PublishFailed       latest.csv could not be refreshed, so the stable files no
                      longer describe the newest run (exit code 3). See
                      PublishErrors for the reason. The matching failure on
                      latest-summary.json cannot appear here for the obvious
                      reason, and shows up only as exit code 3.
  Partial             at least one database was not collected (exit code 2)
  Alert               at least one mailbox is at or above the warning or
                      critical threshold now (exit code 1)
  MetricUnavailable   every eligible mailbox in scope reported the posting
                      list table as 0 B (exit code 5)
  Emerging            nothing has crossed yet, but at least one mailbox is
                      projected to cross critical inside the lead-time
                      window (exit code 6)
  MetricInconclusive  nothing in scope has a populated posting list table and
                      nothing in scope is large enough to have allocated one,
                      so the run cannot say whether the counter works

Reported worst-first where more than one applies: PublishFailed, then Partial,
then Alert, then MetricUnavailable, then Emerging, then MetricInconclusive, then
OK. The order is the exit-code order, so Status and ExitCode never disagree
about which of several conditions a run is reporting.

Alert and Emerging are, unlike the exit codes they parallel, NOT gated on
-ExitNonZeroOnAlert. A run at defaults returns 0 and still reports Status
Alert with Critical and Warning counts beside it: the exit code is the opt-in
signal, the summary file is the record. Before v1.7.2, Status had no branch for
a finding at all, so a run could report Critical 1, Warning 1, ExitCode 1 and
Status OK - and the documented integration, alert when Status is not OK, went
silent on the one condition this script exists to detect.

Completed = false does not cover MetricUnavailable. Such a run completes and
collects everything asked of it; it just cannot read the one counter it exists
to read, so every threshold in it was applied to a constant zero and a clean
result means only that nothing could have been found. Alert on it separately,
as a monitoring gap rather than a pass. Unlike the exit code, this value is not
gated on -ExitNonZeroOnAlert.

MetricInconclusive is not a fault and does not move the exit code. It is the
expected steady state of a small or newly built estate, where every mailbox is
below the allocation bar and 0 B is the correct reading. It is still reported,
because a run whose thresholds were never exercised should not read as a run
that passed them - but alerting on it would fire on every run forever, and an
alert that always fires is an alert that gets muted. To convert it into a real
answer, put one mailbox above the bar.
#>

[CmdletBinding()]
param(
    [string[]]$Databases,

    # All, not Local, since v1.7.7. A run started by hand is expected to answer
    # for the estate, not for whichever node the operator happened to be sitting
    # on - and the remote runspace reaches every database regardless of which
    # node holds it. Scheduled tasks on more than one DAG member want -Scope
    # Local explicitly; see the .PARAMETER block above.
    [ValidateSet('Local', 'All')]
    [string]$Scope = 'All',

    [ValidateRange(0.001, 1024)]
    [double]$WarningGB = 1.7,

    [ValidateRange(0.001, 1024)]
    [double]$CriticalGB = 2.0,

    [ValidateSet('Fixed', 'Adaptive')]
    [string]$ThresholdMode = 'Fixed',

    [ValidateRange(10, 1000000)]
    [int]$AdaptiveMinimumSample = 100,

    # ValidateNotNullOrEmpty because the documented usage sets $out on a line
    # above the command, and running the command without that line binds an
    # empty string here. That reached the pre-flight and exited 3 with
    # "Cannot bind argument to parameter 'LiteralPath'" - a true message about
    # the wrong parameter. Rejecting it at bind time names -OutputPath instead.
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $env:ProgramData 'ExchangeBigFunnelPostingListMonitor'),

    [ValidateRange(0, 3650)]
    [int]$RetentionDays = 30,

    [ValidateRange(0, 300)]
    [int]$ThrottleDelaySeconds = 0,

    # The floor is 1, not 0, and the difference is not cosmetic. Zero makes every
    # baseline on disk old enough by definition, so the newest run always wins,
    # MetMinimum is true by construction, and the warning below about a narrow
    # window magnifying noise can never fire. The rate is still computed and
    # still printed - from whatever gap happened to exist, with nothing on the
    # run saying the sample was too thin to divide by.
    [ValidateRange(1, 8760)]
    [int]$TrendBaselineHours = 24,

    [ValidateRange(0, 1440)]
    [double]$MaxRunMinutes = 60,

    [ValidateRange(1, 10000)]
    [int]$MaxAlertDetail = 25,

    # Fallback only. See Get-AllocationEvidenceBytes: a run that can see the
    # allocation point in its own population uses that instead.
    [ValidateRange(1, 1048576)]
    [int]$AllocationEvidenceMB = 64,

    # Empty means this server, built from its own FQDN at run time. Point it at
    # another Exchange server where the local PowerShell vdir is not the one to
    # use - the runspace only has to be an Exchange server in the same
    # organisation, not the node holding any particular database.
    [string]$ConnectionUri = '',

    # Only needed where the account running the script cannot authenticate to
    # the runspace on its own. Whether it can is decided by the task's LogonType,
    # not by the account: measured on w25-ex01, a task registered with a stored
    # password opened the runspace with Kerberos and no credential, and the same
    # task registered S4U could not open it at all. -Credential is the way out
    # where a stored password is not permitted.
    [System.Management.Automation.PSCredential]$Credential,

    # Suppress the automatic relaunch described in the elevation section of the
    # header. The run continues unelevated, which is correct wherever the output
    # directory is already writable by the account - a per-service directory, or
    # one whose ACL was set deliberately. If it turns out not to be writable the
    # run still fails honestly with exit 3, so this switch trades a UAC prompt
    # for a clear failure, never for a silent one.
    [switch]$NoElevate,

    # Silence the console report described in the reporting section of the
    # header. The log file, latest.csv, latest-summary.json and the exit code
    # are all unaffected - this suppresses decoration, never evidence. Intended
    # for a wrapper or monitoring agent that parses stdout and would otherwise
    # have to skip past a progress block it did not ask for.
    [switch]$Quiet,

    # Emit the collected rows on the success stream as well as writing them to
    # the CSV. Off by default: a bare run would otherwise print the report and
    # then spray a hundred objects through the default formatter underneath it.
    #
    # What comes back is the same [pscustomobject] set the report and the CSV are
    # both built from, not a re-read of the file. That matters most for the growth
    # fields: GrowthGBPerDay and DaysToCritical return as numbers, where Import-Csv
    # would hand back text that sorts lexically and compares wrong.
    #
    # Returns nothing across an elevation relaunch - the rows are built in the
    # child process and the parent only ever sees its exit code. The run says so
    # when both apply rather than returning an empty pipeline silently.
    [switch]$PassThru,

    # Internal plumbing, set by the script on itself. Not for hand use.
    #
    # An elevated process cannot attach to the console of the non-elevated one
    # that asked for it, so the relaunch gets a window of its own and that window
    # closes the moment the run ends. The operator approves a UAC prompt, watches
    # a console flash past, and is returned to their own prompt having been shown
    # two lines and no report - on a script whose whole reporting layer exists so
    # that a run does not have to be read out of a log afterwards.
    #
    # The child writes every console line here as it prints it, and the parent
    # replays the file into the window the operator is actually looking at. A
    # file rather than a pipe because Start-Process cannot combine -Verb RunAs
    # with -RedirectStandardOutput, and written line by line rather than buffered
    # so that a child that dies mid-run still relays what it managed to say.
    [string]$ConsoleRelayPath = '',

    [switch]$ExitNonZeroOnAlert
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ScriptVersion   = '1.11.0'
$script:OutputPath      = $OutputPath
$script:LogFile         = $null
$script:LogFailed       = $false
$script:FailedDbs       = New-Object System.Collections.Generic.List[string]

# Read by Write-Report rather than the switch itself, so the console channel has
# one boolean to test and nothing has to reason about SwitchParameter semantics
# on a hot path.
$script:ReportSilenced  = [bool]$Quiet

# Where Write-Report mirrors itself for a parent process to replay, or empty on
# a run nobody relaunched. Read on every console line, so it is resolved once
# here rather than tested through the parameter each time.
$script:ReportRelay     = [string]$ConsoleRelayPath

# Assigned for real in the elevation region during pre-flight. Declared here
# because StrictMode 2.0 throws on a read of a variable that was never set, and
# an abort before that region still writes a summary.
$script:Elevated        = $false

# Declared here, not at the point of use. StrictMode 2.0 throws on a variable
# that was never assigned, and the finally block reads EmsSession to close the
# runspace - including on an abort that happened before it was ever opened.
$script:EmsSession      = $null
$script:BindingUsed     = ''
$script:EmsUri          = ''

# PowerShell 5.1's -Encoding UTF8 writes a byte-order mark. Harmless in a log,
# but the same encoder is reused for the summary JSON, where a leading BOM
# breaks strict parsers. One BOM-free encoder for both.
$script:Utf8NoBom       = New-Object System.Text.UTF8Encoding($false)

# Incremented from inside a ForEach-Object script block, which runs in a child
# scope: a bare $x++ there would read the parent value and write a local copy,
# silently counting nothing. Script scope makes the write land.
$script:PropertyMissing = 0
$script:ParseFailures   = 0
$script:NoSizeValue     = 0
$script:MailboxesSeen   = 0
$script:DeadlineHit     = $false

# Run-level, unlike $script:DeadlineHit, which is reset per database.
$script:BudgetExceeded  = $false

$script:ThisServer = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($script:ThisServer)) { $script:ThisServer = [System.Net.Dns]::GetHostName() }

#region helpers ---------------------------------------------------------------

function Write-Report {
    # The console channel, and the only one an operator sees without asking for
    # anything. Deliberately separate from Write-RunLog: the log is a forensic
    # record keyed by timestamp and level, and this is a report meant to be read
    # once, while the run is happening, by somebody who has not read the script.
    # Wording that suits one rarely suits the other, so they are written
    # separately rather than one being derived from the other.
    #
    # Write-Host and not Write-Output on purpose. The success stream is a return
    # value; anything emitted there ends up in a caller's variable, or in a
    # pipeline, and a monitoring wrapper doing $r = & monitor.ps1 would collect
    # decoration instead of nothing. Write-Host cannot be captured that way, and
    # its colour is simply dropped when the stream is redirected to a file.
    #
    # Which is also why an elevated relaunch needs the relay below. Write-Host
    # writes to the child's own console and nowhere else, so there is nothing for
    # the parent to capture even in principle.
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [ValidateSet('Plain', 'Head', 'Good', 'Warn', 'Bad', 'Dim')][string]$Style = 'Plain'
    )

    if ($script:ReportSilenced) { return }

    # Relayed before it is printed, so a line that reaches the child's screen is
    # already on its way to the parent's. The style travels with the text: the
    # relay exists to reproduce the report, and a verdict block that arrives in
    # the parent window uncoloured is a different report from the one the child
    # showed.
    #
    # Silent on failure, deliberately. This is the decoration channel - a run
    # that cannot write its relay file has still collected, still written its
    # CSV and still got an exit code, and turning that into a terminating error
    # would trade the evidence for the commentary about it.
    if ($script:ReportRelay) {
        try {
            # Tab-delimited because the report is built with PadRight and never
            # contains one, so the split on the other side cannot land inside a
            # mailbox name that happened to hold the delimiter.
            [System.IO.File]::AppendAllText($script:ReportRelay,
                ("{0}`t{1}{2}" -f $Style, $Text, [Environment]::NewLine),
                (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { $script:ReportRelay = '' }
    }

    $colour = switch ($Style) {
        'Head' { 'Cyan' }
        'Good' { 'Green' }
        'Warn' { 'Yellow' }
        'Bad'  { 'Red' }
        'Dim'  { 'DarkGray' }
        default { '' }
    }
    # Write-Host rejects a null ForegroundColor rather than treating it as
    # "leave it alone", so the uncoloured case is a separate call.
    if ($colour) { Write-Host $Text -ForegroundColor $colour }
    else         { Write-Host $Text }
}

function Show-ConsoleRelay {
    # The other end of the relay Write-Report writes. Replays the file an
    # elevated child left behind into this process's console, and returns how
    # many lines it managed to print so the caller can tell a relay that worked
    # from one that never arrived.
    #
    # A function rather than a dozen lines inline in the elevation region,
    # because the region itself cannot be reached from a test run without a
    # consent prompt nobody can answer, and the parsing here is the part that
    # can go quietly wrong. Lifted out, it is exercised by name.
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    $n = 0
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            # Split once, on the first tab. Report text is built with PadRight
            # and holds none, but splitting on all of them would still be the
            # wrong shape if one ever appeared.
            $tab = $line.IndexOf("`t")
            if ($tab -lt 0) { continue }
            $style = $line.Substring(0, $tab)
            $text  = $line.Substring($tab + 1)
            # Checked against the set Write-Report accepts rather than passed
            # through. A child killed mid-write can leave a truncated last line,
            # and an unexpected style would hit a ValidateSet and throw here -
            # turning a cosmetic loss into a failed parent process.
            if ('Plain', 'Head', 'Good', 'Warn', 'Bad', 'Dim' -notcontains $style) { $style = 'Plain' }
            Write-Report $text $style
            $n++
        }
    }
    catch {
        # Whatever reached the screen still counts as replayed. Reporting zero
        # here would make the caller add its fallback line underneath a report
        # that had already printed.
    }
    return $n
}

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'FATAL')][string]$Level = 'INFO',
        # One line about one mailbox, out of a list that can legitimately run to
        # -MaxAlertDetail entries. Still WARN in the log, because that is where
        # the list is meant to be read, but kept off the console: twenty-five
        # GUIDs scrolling past push the verdict off the top of the window, and
        # burying the conclusion under its own evidence is the same failure as
        # printing nothing at all. The counts and the CSV path in the verdict
        # block are the console's version of this.
        [switch]$RowDetail,
        # A short form for the console while the log keeps $Message in full.
        # The long explanations in this script are worth every word in a file
        # somebody reads after the fact, and are actively harmful on screen: a
        # 70-word sentence wraps to five lines in an 80-column console, and five
        # lines of prose directly above the verdict is how the verdict stops
        # being read. Length is free in the log and expensive on screen, so the
        # two are allowed to differ. An array prints one line per element.
        [string[]]$ConsoleText
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line

    # Logging must never be the reason a monitoring run dies. If the log file
    # is locked, the volume is full, or AV holds a handle, degrade to the
    # console and keep collecting.
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, ($line + [Environment]::NewLine), $script:Utf8NoBom)
        }
        catch {
            if (-not $script:LogFailed) {
                $script:LogFailed = $true
                Write-Warning ('Log file unavailable, continuing without it: {0}' -f $_.Exception.Message)
            }
        }
    }

    # Anything above INFO reaches the console whether or not -Verbose was
    # passed. This is the half of the old behaviour that was actually wrong: a
    # WARN went to the verbose stream, where PowerShell renders it in the same
    # colour and with the same VERBOSE: prefix as every INFO line around it, so
    # the one line worth reading looked exactly like the eighteen that were not.
    # The message is printed without its timestamp and level here - the log
    # keeps those, and on screen they are noise in front of the sentence.
    # The console form is $ConsoleText when one was supplied, and $Message
    # otherwise - so a call site that says nothing about the console keeps the
    # behaviour it had before this parameter existed.
    $onScreen = @(if ($ConsoleText) { $ConsoleText } else { $Message })

    # A bullet rather than an exclamation mark. The line is already yellow, so
    # the '!' was not carrying the severity - it was only adding volume, and a
    # column of them down the left of a collection block reads as shouting at
    # an operator about something the colour had already said. '-' says "list
    # item", which is what these lines are. ERROR and FATAL keep 'X': that is a
    # different severity, and colour alone should not have to carry it.
    #
    # The marker goes on the first line only. Repeating it down every line of a
    # four-line message reads as four separate findings rather than one finding
    # with three parts, and those messages already indent their own sub-lines to
    # hang under the first.
    $marker = ''
    $colour = ''
    switch ($Level) {
        'WARN'  { if (-not $RowDetail) { $marker = '-'; $colour = 'Warn' } }
        'ERROR' { if (-not $RowDetail) { $marker = 'X'; $colour = 'Bad' } }
        'FATAL' { $marker = 'X'; $colour = 'Bad' }
    }
    if ($marker) {
        for ($i = 0; $i -lt $onScreen.Count; $i++) {
            $prefix = if ($i -eq 0) { '  ' + $marker + ' ' } else { '    ' }
            Write-Report ($prefix + $onScreen[$i]) $colour
        }
    }
}

function Get-SafeProperty {
    # StrictMode 2.0 turns any access to an absent property into a terminating
    # error. Get-MailboxStatistics does not return a uniform shape across
    # mailbox states (disconnected, soft-deleted, never-logged-on), so every
    # property read goes through here.
    [CmdletBinding()]
    param($InputObject, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-NullableInt64 {
    # Counters arrive as integers from the live cmdlet and as strings from a
    # CSV baseline, and may be absent or empty on either path. Everything that
    # is not a whole number becomes $null so callers can test one way.
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $n = New-Object 'System.Int64'
    if ([int64]::TryParse($text, [ref]$n)) { return $n }
    return $null
}

function Convert-ExchangeSizeToBytes {
    [CmdletBinding()]
    param($SizeValue)

    if ($null -eq $SizeValue) { return $null }

    # Get-MailboxStatistics returns Unlimited<ByteQuantifiedSize>, which is a
    # wrapper. ToBytes() lives on the inner ByteQuantifiedSize, not on the
    # wrapper, so unwrap before testing for it.
    if ($SizeValue.PSObject.Properties.Name -contains 'IsUnlimited') {
        if ($SizeValue.IsUnlimited) { return $null }
        $SizeValue = $SizeValue.Value
        if ($null -eq $SizeValue) { return $null }
    }

    if ($SizeValue.PSObject.Methods.Name -contains 'ToBytes') {
        try { return [int64]$SizeValue.ToBytes() } catch { }
    }

    $text = [string]$SizeValue

    # Catches both a literal string and any wrapper whose ToString() is
    # "Unlimited", regardless of how it was reached.
    if ($text -match 'Unlimited') { return $null }

    # Exchange renders sizes with an invariant thousands separator, e.g.
    # "1.158 GB (1,243,054,080 bytes)". Verified identical under en-US, de-DE
    # and fr-FR, so this regex is culture-safe.
    if ($text -match '\(([0-9,]+)\s+bytes\)') {
        return [int64](($matches[1]) -replace ',', '')
    }

    if ($text -match '^\s*([0-9.]+)\s*(B|KB|MB|GB|TB)\s*$') {
        $number = [double]::Parse($matches[1], [Globalization.CultureInfo]::InvariantCulture)
        switch ($matches[2].ToUpperInvariant()) {
            'B'  { return [int64]$number }
            'KB' { return [int64]($number * 1KB) }
            'MB' { return [int64]($number * 1MB) }
            'GB' { return [int64]($number * 1GB) }
            'TB' { return [int64]($number * 1TB) }
        }
    }

    throw ('Unable to parse size value: {0}' -f $text)
}

function Test-ExchangeBuild {
    # BigFunnelPostingListTableTotalSize is exposed by Exchange 2019 and
    # Exchange Server SE, both of which report 15.2. On 2013 (15.0) and 2016
    # (15.1) the property is simply absent, and without this check the run
    # reports it one skipped mailbox at a time - which reads like a data
    # problem rather than an unsupported platform.
    #
    # Never fatal on its own uncertainty: if the build cannot be established,
    # the run continues and says so.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Server)

    $unknown = {
        param($Reason, $Text)
        [pscustomobject]@{ Known = $false; Supported = $true; Version = [string]$Text; Reason = [string]$Reason }
    }

    if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
        return (& $unknown 'Get-ExchangeServer is not available' '')
    }

    try { $srv = Get-ExchangeServer -Identity $Server -ErrorAction Stop }
    catch { return (& $unknown $_.Exception.Message '') }

    $version = Get-SafeProperty $srv 'AdminDisplayVersion'
    if ($null -eq $version) { return (& $unknown 'AdminDisplayVersion was not returned' '') }

    $major = Get-SafeProperty $version 'Major'
    $minor = Get-SafeProperty $version 'Minor'

    # Falls back to parsing the rendered string, which is the shape that comes
    # back over an implicit remoting session where the typed object is lost.
    if ($null -eq $major -or $null -eq $minor) {
        if ([string]$version -match '(\d+)\.(\d+)') {
            $major = [int]$matches[1]
            $minor = [int]$matches[2]
        }
    }
    if ($null -eq $major -or $null -eq $minor) {
        return (& $unknown 'the build number could not be parsed' $version)
    }

    $supported = ([int]$major -gt 15) -or ([int]$major -eq 15 -and [int]$minor -ge 2)
    return [pscustomobject]@{
        Known     = $true
        Supported = $supported
        Version   = [string]$version
        Reason    = ''
    }
}

function Get-Percentile {
    # Nearest-rank on an already-sorted ascending array. No interpolation:
    # these are byte counts feeding a threshold, and an interpolated value that
    # matches no observed mailbox would be harder to explain than one that does.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][int64[]]$SortedValues,
        [Parameter(Mandatory = $true)][double]$Percentile
    )

    if ($SortedValues.Count -eq 0) { return [int64]0 }

    $rank = [int][math]::Ceiling(($Percentile / 100.0) * $SortedValues.Count)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $SortedValues.Count) { $rank = $SortedValues.Count }
    return [int64]$SortedValues[$rank - 1]
}

function Get-PostingListStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int64]$Bytes,
        [Parameter(Mandatory = $true)][int64]$WarningBytes,
        [Parameter(Mandatory = $true)][int64]$CriticalBytes,
        # Deliberately untyped. PowerShell 5.1 cannot bind $null to [int64], and
        # this arrives as $null on any build that does not expose the counter.
        $IndexedCount = $null,

        # Mailbox content size, and the size above which this build is expected
        # to have allocated a posting list table. Both untyped for the same
        # reason as $IndexedCount: TotalItemSize is absent or Unlimited on some
        # mailboxes, and the evidence point is absent when the caller has not
        # computed one.
        $MailboxBytes = $null,
        $EvidenceBytes = $null
    )

    if ($Bytes -ge $CriticalBytes) { return 'Critical' }
    if ($Bytes -ge $WarningBytes)  { return 'Warning' }

    # Verified on Exchange Server SE 15.2.2562.17: a mailbox with 200 fully
    # indexed messages reported BigFunnelIndexedCount 200, a live searchable
    # index, and roughly 4 MB spread across BigFunnelTotalPOISize,
    # BigFunnelLargePOITableTotalSize and BigFunnelFilterTableTotalSize - while
    # BigFunnelPostingListTableTotalSize stayed at exactly 0 B.
    #
    # Reporting that as Normal is a silent false negative: it is indistinguish-
    # able from a genuinely small mailbox, so on a build that never populates
    # the table every mailbox reads healthy and the monitor never alerts.
    # Zero bytes on a demonstrably indexed mailbox means the metric is
    # unavailable here, which is a different fact from "this mailbox is fine".
    #
    # But not every such mailbox is evidence of that. The table is allocated
    # above a content threshold rather than withheld by the build: measured on
    # the same build, 3.45 MB and 6.87 MB mailboxes read 0 B while a 16.33 MB
    # one had allocated 3.344 MB. Below the allocation point 0 B is the correct
    # reading and nothing is wrong, so calling it NotPopulated raises an alarm
    # on every small mailbox in the estate. That is how the state was behaving
    # before -AllocationEvidenceMB existed, and on an estate of uniformly small
    # mailboxes it escalated a whole run to MetricUnavailable, which is a false
    # positive loud enough to get the monitor muted.
    $indexed = ConvertTo-NullableInt64 $IndexedCount
    if ($Bytes -eq 0 -and $null -ne $indexed -and $indexed -gt 0) {
        $size     = ConvertTo-NullableInt64 $MailboxBytes
        $evidence = ConvertTo-NullableInt64 $EvidenceBytes

        # Unparseable or Unlimited TotalItemSize lands here as $null. The
        # mailbox cannot be judged either way, so it is reported as the benign
        # state rather than the alarming one: a wrong "nothing is wrong" on one
        # row is recoverable, a wrong "your monitoring is blind" trains people
        # to ignore the message.
        if ($null -eq $evidence -or $null -eq $size -or $size -lt $evidence) {
            return 'NotAllocated'
        }
        return 'NotPopulated'
    }

    return 'Normal'
}

function Get-AllocationEvidenceBytes {
    # How large a mailbox has to be before its 0 B posting list table counts as
    # evidence that the counter is not being populated at all.
    #
    # Preferring the population over the configured constant is the same move
    # -ThresholdMode Adaptive already makes, and for the same reason: the
    # estate in front of the script is better evidence about this build than a
    # number chosen in advance. Where any mailbox has a populated table, the
    # smallest such mailbox *is* an observation of the allocation point, so it
    # is used directly.
    #
    # Clamped to a floor because the smallest populated mailbox is only an
    # upper bound on the allocation point, and a mailbox that was large when
    # the table was allocated and has since been emptied is a lower one that
    # lies. Without the clamp a single archived mailbox reading 40 MB of table
    # against 2 MB of content would drop the bar to 2 MB and reclassify most of
    # a healthy estate as NotPopulated. The clamp can only ever move the bar
    # up, which errs toward "expected" - the safe direction, because the cost
    # of a missed outage is one quiet run and the cost of a false outage is a
    # muted monitor.
    [CmdletBinding()]
    param(
        # Not mandatory, and deliberately so: a run that collected nothing still
        # reaches this call, and 5.1 refuses to bind an empty collection to a
        # mandatory parameter. An empty population is a legitimate answer here -
        # it observes nothing and falls through to the configured value.
        $Rows = @(),
        [Parameter(Mandatory = $true)][int64]$FallbackBytes
    )

    # 16 MB: the smallest mailbox measured on 15.2.2562.17 that had actually
    # allocated. Anything below this is a size the table was observed *not* to
    # be allocated at, so it cannot be a credible allocation point.
    $floor = 16MB

    $observed = $null
    foreach ($r in $Rows) {
        $pl = ConvertTo-NullableInt64 (Get-SafeProperty -InputObject $r -Name 'PostingListBytes')
        if ($null -eq $pl -or $pl -le 0) { continue }

        $size = ConvertTo-NullableInt64 (Get-SafeProperty -InputObject $r -Name 'TotalItemBytes')
        if ($null -eq $size) { continue }

        if ($null -eq $observed -or $size -lt $observed) { $observed = $size }
    }

    if ($null -ne $observed) {
        $bytes = [int64]$observed
        if ($bytes -lt $floor) { $bytes = [int64]$floor }
        return [pscustomobject]@{ Bytes = $bytes; Basis = 'Observed' }
    }

    return [pscustomobject]@{ Bytes = $FallbackBytes; Basis = 'Configured' }
}

function Get-TrendMetricForRow {
    # Which counter this mailbox's growth can be measured on.
    # BigFunnelPostingListTableTotalSize is the counter the thresholds describe,
    # so it wins wherever it carries a reading. Where it reads 0 B on a mailbox
    # that demonstrably holds an index, the index is accounted for in the POI and
    # filter tables instead, and IndexPayloadBytes is the only counter that can
    # see it.
    #
    # Asked of one mailbox, not of the run. The previous version made this choice
    # once for the whole scope: if any mailbox anywhere had a populated posting
    # list, every mailbox was trended on it. On an estate mid-transition that is
    # the wrong shape. Measured on a lab estate on 15.2.2562.17, two mailboxes
    # crossing the allocation threshold moved the other eighteen - still reading
    # 0 B, and unchanged in every other respect - onto a counter that is a
    # constant zero for them. The ranking that exists to name the next mailbox
    # went blind for most of the population 27 minutes after it had been working,
    # and nothing about those eighteen had changed. Whether the posting list
    # table is readable is a property of a mailbox, so it is now read off one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Row
    )

    $postingList = ConvertTo-NullableInt64 (Get-SafeProperty -InputObject $Row -Name 'PostingListBytes')
    if ($null -ne $postingList -and $postingList -gt 0) { return 'PostingListBytes' }

    $payload = ConvertTo-NullableInt64 (Get-SafeProperty -InputObject $Row -Name 'IndexPayloadBytes')
    if ($null -ne $payload -and $payload -gt 0) { return 'IndexPayloadBytes' }

    # Neither counter carries a reading, so there is nothing to choose between.
    # Named as the posting list rather than the fallback so the row sorts and
    # reports with the majority, instead of being pushed onto a counter it has no
    # data for either and ranked against mailboxes that do.
    return 'PostingListBytes'
}

function Format-GrowthAnnotation {
    # One growth phrase, used everywhere a mailbox is named. The roll call and the
    # growth list were each deciding separately when to show a rate, when to show
    # a projected date and when to show neither, and they had already drifted
    # apart: the same mailbox printed "critical in 2.5 day(s)" in one block and
    # " 0.0787 GB/day ... critical in 2.5 day(s)" nine lines below it, which reads
    # as two findings about one mailbox rather than one finding printed twice.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Row,

        # Say why there is no rate instead of returning nothing. Worth a word on a
        # finding - an operator looking at a Critical mailbox with no annotation
        # cannot tell whether the script measured it and found it flat, or never
        # had a baseline to measure against, and those carry opposite urgency.
        # Left off for rows that are not findings, where silence is correct.
        [switch]$ExplainAbsence
    )

    $rate = $Row.GrowthGBPerDay
    $days = $Row.DaysToCritical

    if ($null -eq $rate) {
        if ($ExplainAbsence) { return 'no rate yet' }
        return ''
    }
    if ([double]$rate -le 0) {
        if ($ExplainAbsence) { return 'not growing' }
        return ''
    }

    # Signed, because this is a rate and not a size. A bare "0.0787 GB/day" set
    # at the end of a line that already carries "0.453 GB" reads as a second size
    # at a glance down the column; a leading + does not.
    $text = '+{0} GB/day' -f $rate

    if ($null -ne $days -and [double]$days -gt 0) {
        return ('{0}, critical in {1} day(s)' -f $text, $days)
    }

    # An absent date is not a dropped one. Either the mailbox is already past
    # Critical, where a projection to Critical means nothing, or it is trended on
    # IndexPayloadBytes, which the thresholds do not describe at all - and the
    # second needs saying on the row, because the rate beside it is measured on a
    # different counter from the size beside that.
    if ([string]$Row.TrendMetric -eq 'IndexPayloadBytes') {
        return ('{0} on index payload, no projected date' -f $text)
    }
    return $text
}

function Get-PreviousRunBaseline {
    # The run ID embedded in each file name is yyyyMMdd-HHmmss followed by the
    # process id, so the timestamp parses without touching the current culture.
    # That is deliberately more robust than reading a datetime back out of the
    # CSV body.
    #
    # The trailing process id is optional in the pattern below rather than
    # required, and both halves of that matter. It has to be allowed, because
    # without it this function silently stops finding any baseline at all the
    # moment $runId gained a $PID suffix - and the failure is invisible, because
    # "no previous run found" is also what a genuine first run looks like. It
    # has to stay optional, because runs written before that change are still
    # on disk and are still perfectly good baselines.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExcludeFile,
        [int]$MinHours = 24
    )

    $now = Get-Date

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter 'BigFunnelPostingListMonitor-*.csv' -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -ne $ExcludeFile })) {

        if ($file.BaseName -notmatch '(\d{8}-\d{6})(?:-\d+)?$') { continue }
        $stamp = New-Object DateTime
        $parsed = [datetime]::TryParseExact(
            $matches[1], 'yyyyMMdd-HHmmss',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$stamp)
        if (-not $parsed) { continue }
        if ($stamp -ge $now) { continue }

        $candidates.Add([pscustomobject]@{
            File  = $file
            Stamp = $stamp
            Age   = ($now - $stamp).TotalHours
        })
    }
    if ($candidates.Count -eq 0) { return $null }

    # A short window magnifies noise. At a 4-hour cadence the delta is
    # multiplied by six to reach a per-day rate, so a few megabytes of ordinary
    # churn reads as a growth trend and the projection swings run to run.
    # Prefer the newest run that is at least MinHours old; when the history is
    # not yet that deep, fall back to the oldest run on disk, which is the
    # widest window available.
    $ordered   = @($candidates | Sort-Object Stamp -Descending)
    $preferred = @($ordered | Where-Object { $_.Age -ge $MinHours })

    $attempts = New-Object System.Collections.Generic.List[object]
    foreach ($c in $preferred) { $attempts.Add($c) }
    foreach ($c in @($ordered | Where-Object { $_.Age -lt $MinHours } | Sort-Object Stamp)) { $attempts.Add($c) }

    foreach ($candidate in $attempts) {
        try { $rows = @(Import-Csv -LiteralPath $candidate.File.FullName -ErrorAction Stop) }
        catch { continue }
        if ($rows.Count -eq 0) { continue }

        $map = @{}
        foreach ($r in $rows) {
            $guid = [string](Get-SafeProperty $r 'MailboxGuid')
            if ([string]::IsNullOrWhiteSpace($guid)) { continue }

            $bytes = ConvertTo-NullableInt64 (Get-SafeProperty $r 'PostingListBytes')
            if ($null -eq $bytes) { continue }

            # Carried so the search-health counters can be judged as
            # "increasing" rather than against a threshold this script has no
            # business inventing. Payload is here for the same reason the
            # collection gathers it: on a build that never populates the posting
            # list table it is the only counter with a growth signal in it, and
            # a rate needs two readings of the same counter, not one of each.
            #
            # Null on baselines written before that column existed. The join
            # treats that as "no reading" rather than as zero, because zero would
            # turn the whole of the current size into a single run's growth.
            $map[$guid] = [pscustomobject]@{
                Bytes      = $bytes
                Payload    = ConvertTo-NullableInt64 (Get-SafeProperty $r 'IndexPayloadBytes')
                NotIndexed = ConvertTo-NullableInt64 (Get-SafeProperty $r 'BigFunnelNotIndexedCount')
                Stale      = ConvertTo-NullableInt64 (Get-SafeProperty $r 'BigFunnelStaleCount')
            }
        }
        if ($map.Count -eq 0) { continue }

        return [pscustomobject]@{
            Timestamp   = $candidate.Stamp
            AgeHours    = [math]::Round($candidate.Age, 2)
            MetMinimum  = ($candidate.Age -ge $MinHours)
            Sizes       = $map
            Source      = $candidate.File.Name
        }
    }
    return $null
}

function Get-SearchHealth {
    # The runbook's index-health table states the expectations directly:
    # corrupted items should be 0, not-indexed should trend low or decreasing,
    # and stale should not be growing. Two of the three are only answerable
    # against a baseline, which is why this runs after the trend join. Nothing
    # here invents a threshold - it reports "non-zero" and "increased".
    [CmdletBinding()]
    param($Row, $Previous)

    $flags = New-Object System.Collections.Generic.List[string]

    $corrupt = ConvertTo-NullableInt64 $Row.BigFunnelCorruptedCount
    if ($null -ne $corrupt -and $corrupt -gt 0) { $flags.Add('Corrupted=' + $corrupt) }

    if ($null -ne $Previous) {
        $notIndexed = ConvertTo-NullableInt64 $Row.BigFunnelNotIndexedCount
        if ($null -ne $notIndexed -and $null -ne $Previous.NotIndexed -and $notIndexed -gt $Previous.NotIndexed) {
            $flags.Add('NotIndexedUp=+' + ($notIndexed - $Previous.NotIndexed))
        }

        $stale = ConvertTo-NullableInt64 $Row.BigFunnelStaleCount
        if ($null -ne $stale -and $null -ne $Previous.Stale -and $stale -gt $Previous.Stale) {
            $flags.Add('StaleUp=+' + ($stale - $Previous.Stale))
        }
    }

    if ($flags.Count -eq 0) { return 'OK' }
    return ($flags -join '; ')
}

function Remove-ExpiredOutput {
    # A 4-hour cadence writes ~4,400 files a year into ProgramData. Prune.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][int]$Days)

    if ($Days -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$Days)
    try {
        $old = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction Stop |
                 Where-Object { $_.Name -like 'BigFunnelPostingListMonitor-*' -and $_.LastWriteTime -lt $cutoff })
        foreach ($f in $old) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            catch { Write-RunLog ('Could not remove [{0}]: {1}' -f $f.Name, $_.Exception.Message) 'WARN' }
        }
        if ($old.Count -gt 0) { Write-RunLog ('Removed {0} file(s) older than {1} day(s).' -f $old.Count, $Days) }
    }
    catch { Write-RunLog ('Retention sweep skipped: {0}' -f $_.Exception.Message) 'WARN' }
}

function Write-RunSummary {
    # One writer for both the completed and the aborted paths.
    #
    # A monitoring agent polling latest-summary.json needs the same field set
    # every time. It also needs the file to change when a run fails: a
    # pre-flight failure that wrote nothing would leave the previous run's
    # summary in place, and the agent would go on reporting a healthy run
    # indefinitely while the monitor was in fact dead. Every field is declared
    # here with a default, and callers supply only what they measured.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $schema = [ordered]@{
        RunId                = ''
        ScriptVersion        = $script:ScriptVersion
        Timestamp            = (Get-Date).ToString('o')
        DurationSeconds      = 0
        Server               = $script:ThisServer
        Scope                = ''
        ExchangeVersion      = ''
        # How the Exchange cmdlets were bound this run, and where. Worth
        # alerting on if it ever reads anything other than EMS or Existing: the
        # in-process snap-in silently drops databases mounted on other DAG
        # members, so a figure collected under it describes one node rather than
        # the estate. See the binding region for the measurement.
        Binding              = ''
        ConnectionUri        = ''
        # False whenever the run stopped before completing collection, whatever
        # the reason. The single field an alert rule should key on.
        Completed            = $false
        Status               = ''
        # The run's verdict on its own instrument, independent of any threshold:
        # Confirmed, Blind or Inconclusive. Read it before trusting an all-clear
        # - a Blind or Inconclusive run applied every threshold to a constant
        # zero, and only one of those two is a fault.
        MetricValidation     = ''
        # The bar in force this run, and where it came from. Observed means it
        # was derived from the smallest mailbox in scope that had allocated a
        # posting list table, which is a direct measurement of this build's
        # allocation point. Configured means nothing had allocated one and
        # -AllocationEvidenceMB was used instead.
        AllocationEvidenceMB    = 0
        AllocationEvidenceBasis = ''
        ThresholdMode        = ''
        # What actually applied. Adaptive falls back to Fixed on a small or
        # tightly clustered population, and a consumer comparing runs needs to
        # know which happened rather than inferring it from the numbers.
        ThresholdBasis       = ''
        WarningGB            = 0
        CriticalGB           = 0
        ConfiguredWarningGB  = 0
        ConfiguredCriticalGB = 0
        DatabasesInScope     = 0
        DatabasesFailed      = 0
        # Joined rather than left as an array: PowerShell 5.1 serialises a
        # one-element array as a bare scalar, so a consumer would see a string
        # on one run and a list on the next.
        FailedDatabases      = ''
        RunBudgetExceeded    = $false
        MailboxesEvaluated   = 0
        Critical             = 0
        Warning              = 0
        Emerging             = 0
        Shrinking            = 0
        SearchHealthIssues   = 0
        # Mailboxes BigFunnel reports as indexed whose posting list table is
        # nonetheless 0 B, and which are large enough that it should not be. A
        # non-zero count here means the metric this monitor is built on is not
        # populated on this build, and a clean run says nothing about posting
        # list growth.
        NotPopulated         = 0
        # The same 0 B reading below the allocation bar, where it is the correct
        # reading rather than a fault. Counted separately so that a small estate
        # is not mistaken for a blind one - conflating the two is what made an
        # earlier version escalate every lab to a metric outage.
        NotAllocated         = 0
        SkippedUnparseable   = 0
        # Present but unreadable - Unlimited, or an empty property. Separate
        # from SkippedUnparseable because the causes differ, and both are
        # separate from MailboxesEvaluated: the three have to add up against
        # the per-database counts or a row went missing unnoticed.
        SkippedNoSize        = 0
        MissingProperty      = 0
        TrendBaseline        = ''
        TrendWindowHours     = $null
        # Which counter GrowthGBPerDay was measured on. A consumer comparing
        # growth across runs needs it: the same column carries posting list
        # growth on one build and index payload growth on the next, and the two
        # are three orders of magnitude apart. 'Mixed' means both were in use in
        # the one run, which is the normal state of an estate mid-transition -
        # read TrendedOnPayload for how much of it fell on the fallback counter.
        TrendMetric          = ''
        TrendedOnPayload     = 0
        # Rows reading Trend=Growing, on whichever counter measured them.
        # GrowingRanked is the subset that appears in the fastest-first list -
        # the fallback-counter rows, which get an ordering because they can get
        # no date. Growing used to hold that subset alone, which meant a run
        # could report Growing 0 with growing mailboxes plainly in its own CSV.
        #
        # Alert on Critical, Warning and Emerging. Growing is a triage count, not
        # an alert condition: on a run where every posting list is readable it is
        # the ordinary churn of the estate.
        Growing              = 0
        GrowingRanked        = 0
        DetailCsv            = ''
        LogFile              = $script:LogFile
        # Any failure to refresh latest.csv or latest-summary.json, joined.
        # Empty on a healthy run. Non-empty means the two stable files no longer
        # describe the newest run, so ExitCode is 3 even where collection itself
        # succeeded. Joined for the same reason FailedDatabases is.
        PublishErrors        = ''
        # Whether the process that produced this summary held an elevated token.
        # Worth recording because it is the usual reason PublishErrors is not
        # empty, and it is invisible after the fact from the files alone.
        Elevated             = $false
        ExitCode             = 0
    }

    foreach ($k in @($Values.Keys)) {
        # A mistyped key would otherwise vanish silently and the field would
        # report its default, which reads as a real measurement.
        if (-not $schema.Contains($k)) {
            Write-RunLog ('Run summary field [{0}] is not part of the schema and was ignored.' -f $k) 'WARN'
            continue
        }
        $schema[$k] = $Values[$k]
    }

    try {
        # Written without a BOM. PowerShell 5.1's -Encoding UTF8 emits one, and
        # a leading BOM breaks strict JSON parsers on the consuming side.
        $json = ([pscustomobject]$schema) | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
        # Recorded in script scope rather than returned, so a stray write to the
        # success stream from anything added above cannot be mistaken for the
        # result.
        $script:SummaryWritten = $true
    }
    catch {
        Write-RunLog ('Could not write the run summary to [{0}]: {1}' -f $Path, $_.Exception.Message) 'WARN'
        # Recorded so the exit code can reflect it. Without this the run reports
        # success while the file a monitoring agent polls still describes an
        # earlier run - measured on w25-ex01, where a non-elevated session left a
        # summary 19 hours stale, reading Status OK, beside a CSV it had just
        # written, and exited 0.
        $script:StablePublishErrors.Add(('latest-summary.json: {0}' -f $_.Exception.Message))
    }
}

#endregion

#region pre-flight ------------------------------------------------------------

if ($WarningGB -ge $CriticalGB) {
    # Write-Warning, not Write-Error: $ErrorActionPreference is Stop, which
    # would make Write-Error terminating and skip the exit code below.
    Write-Warning ('WarningGB ({0}) must be below CriticalGB ({1}); otherwise the warning tier can never fire.' -f $WarningGB, $CriticalGB)
    exit 3
}

#region elevation -------------------------------------------------------------
#
# Placed before the output directory is created, because an account that cannot
# create the directory should be relaunched rather than told to go away, and
# before the single-instance mutex below, because a parent holding the mutex
# would get its own elevated child refused with exit 4.

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-RelaunchArguments {
    # Rebuild the invocation for the elevated child. Driven off PSBoundParameters
    # rather than a hand-maintained list, so a parameter added later cannot be
    # silently dropped on the way across the process boundary - a relaunch that
    # quietly discards -CriticalGB would report against the wrong threshold.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Bound)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($k -eq 'NoElevate') { continue }
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $parts.Add('-' + $k) }
            continue
        }
        if ($v -is [bool]) { $parts.Add('-{0}:${1}' -f $k, $v); continue }

        $format = {
            param($item)
            $t = [string]$item
            # A value ending in a backslash would escape the closing quote when
            # Windows splits the child's command line, swallowing the next
            # argument. Paths are the common case and a trailing separator is
            # never significant in one.
            while ($t.EndsWith('\')) { $t = $t.Substring(0, $t.Length - 1) }
            '"{0}"' -f ($t -replace '"', '""')
        }

        $parts.Add('-' + $k)
        if ($v -is [array]) { $parts.Add((($v | ForEach-Object { & $format $_ }) -join ',')) }
        else                { $parts.Add((& $format $v)) }
    }
    return ($parts -join ' ')
}

$script:Elevated = Test-IsElevated
if (-not $script:Elevated -and -not $NoElevate) {

    if ($null -ne $Credential) {
        # A PSCredential cannot cross a process boundary, and relaunching
        # without it would silently change how the runspace authenticates -
        # turning an explicit credential into an implicit one.
        Write-Warning 'Not elevated, but -Credential cannot be passed to a new process, so this run continues as it is. Re-run from an elevated session if it fails to publish.'
    }
    elseif (-not [Environment]::UserInteractive) {
        # A scheduled task or service has no desktop to show a consent prompt
        # on, so relaunching would hang until the execution time limit rather
        # than fail. Registering the task with -RunLevel Highest is the fix, and
        # saying so here is more use than a prompt nobody can answer.
        Write-Warning 'Not elevated, and this session is not interactive so it cannot prompt for consent. Register the task with -RunLevel Highest. The run continues and exits 3 if it cannot publish.'
    }
    else {
        $exe = Join-Path $PSHOME 'powershell.exe'

        # A relay file the child writes and this process replays, so the report
        # lands in the window the operator is looking at rather than in the one
        # UAC opens and Windows closes a second later. In the parent's own TEMP:
        # the child is an administrator and can write there, and reading it back
        # afterwards needs no privilege this process does not already have.
        #
        # Removed first. A stale file from an earlier run would be replayed as
        # though it were this one's output, which is worse than no relay at all -
        # it would show a verdict that is not the verdict the exit code carries.
        #
        # Empty where TEMP is not set, which happens in a stripped environment
        # rather than never. The relay is then simply skipped and the run keeps
        # the behaviour it had before: an exit code and a pointer to the log.
        $tempDir = [string]$env:TEMP
        $relay   = ''
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            $relay = Join-Path $tempDir ('BigFunnelPostingListMonitor-relay-{0}.txt' -f $PID)
            try { Remove-Item -LiteralPath $relay -Force -ErrorAction SilentlyContinue } catch { }
        }

        # Added to the bound parameters rather than appended to the string, so it
        # goes through the same quoting as everything else and a TEMP path with a
        # space in it survives the process boundary.
        $bound = @{}
        foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }
        if ($relay) { $bound['ConsoleRelayPath'] = $relay }

        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f
                   $PSCommandPath, (ConvertTo-RelaunchArguments $bound)

        # Said before the consent prompt rather than after an empty pipeline. The
        # rows are built in the child, so a -PassThru run that elevates returns
        # nothing to the caller that asked for them - which is indistinguishable
        # from a run that found no mailboxes at all.
        if ($PassThru) {
            Write-Warning '-PassThru returns nothing across an elevation relaunch, because the rows are built in the elevated child. Re-run from an already-elevated session, or read the CSV the child writes.'
        }

        Write-Report 'Not running as administrator. Relaunching elevated - approve the prompt.' 'Warn'
        try {
            $child = Start-Process -FilePath $exe -ArgumentList $argLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
        }
        catch {
            # Declining the consent prompt lands here. A monitor that was not
            # allowed to run has not run, so this is exit 3 and not a quiet
            # return to the prompt.
            Write-Warning ('Elevation was refused or failed, so nothing was collected: {0}' -f $_.Exception.Message)
            exit 3
        }

        # -Wait, rather than the usual fire-and-forget, because this script's
        # exit code is its interface: a scheduler reads 0/1/2/3/4/5/6 to decide
        # what to do. Returning 0 the instant the child starts would report
        # every run as clean regardless of what it found.
        #
        # PassThru can report a null ExitCode where the process object is torn
        # down early. Treating unknown as failure is the safe direction here.
        $rc = if ($null -eq $child.ExitCode) { 3 } else { $child.ExitCode }

        # The child's window is gone by now. Replay what it printed into this one,
        # styles and all, so the operator reads the run they just approved instead
        # of being told where its log file is and left to go and open it.
        $replayed = Show-ConsoleRelay -Path $relay
        if ($relay) {
            try { Remove-Item -LiteralPath $relay -Force -ErrorAction SilentlyContinue } catch { }
        }

        # Only when the report did not make it across. With the relay working the
        # replayed block already ends in "Exit code N" and the path to the log, so
        # this line would be the same two facts a second time.
        if ($replayed -eq 0) {
            Write-Report ('The elevated run exited {0}. Its log is in {1}.' -f $rc, $OutputPath) 'Dim'
        }
        exit $rc
    }
}
#endregion elevation

try {
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
}
catch {
    Write-Warning ('Cannot create output path [{0}]: {1}' -f $OutputPath, $_.Exception.Message)
    exit 3
}

# The process id is part of the identity. Get-Date has one-second resolution, so
# two runs starting within the same second derive the same log path and append to
# one file. Logging here degrades rather than dies, so the run survives - but the
# line that gets dropped is the refused run's "another instance is already
# running", which is exactly the line that explains a missing run.
$runId          = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID
$runStart       = Get-Date
$script:LogFile = Join-Path $OutputPath ('BigFunnelPostingListMonitor-{0}.log' -f $runId)
$csvPath        = Join-Path $OutputPath ('BigFunnelPostingListMonitor-{0}.csv' -f $runId)

# A timestamped file is right for history, but a monitoring agent wants one
# path it can read on a schedule without globbing for the newest name. Both of
# these sit outside the BigFunnelPostingListMonitor-* pattern, so neither the
# baseline scan nor the retention sweep can touch them. Resolved this early
# because the failure paths write the summary too.
$latestCsv      = Join-Path $OutputPath 'latest.csv'
$latestJson     = Join-Path $OutputPath 'latest-summary.json'

# A long collection against a busy store can overrun the schedule interval.
# Two concurrent runs would double the load on the very component this script
# exists to protect. Global\ needs SeCreateGlobalPrivilege, which the Exchange
# service account has and an interactive tester may not, so fall back rather
# than fail the run over a lock we could not take.
$mutex   = $null
$holding = $false
foreach ($scopePrefix in @('Global\', 'Local\')) {
    try {
        $mutex = New-Object System.Threading.Mutex($false, ($scopePrefix + 'ExchangeBigFunnelPostingListMonitor'))
        break
    }
    catch {
        Write-Warning ('Could not create a {0}scoped mutex: {1}' -f $scopePrefix, $_.Exception.Message)
    }
}

if ($null -ne $mutex) {
    try { $holding = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $holding = $true }

    if (-not $holding) {
        Write-RunLog 'Another instance is already running. Exiting without collecting.' 'WARN'
        exit 4
    }
}
else {
    Write-RunLog 'Proceeding without a concurrency lock; overlapping runs are possible.' 'WARN'
}

$exitCode = 0

# Set at each site that aborts the run, and reported as Status in the summary
# so a monitoring agent gets the reason rather than just a non-zero code.
$abortReason           = ''
$script:SummaryWritten = $false

# Every failure to refresh latest.csv or latest-summary.json. These two are the
# only files a scheduled consumer polls, so failing to publish them is a
# monitoring outage even when the collection behind them was perfect. Collected
# rather than counted, because the reason is what tells you whether it is an ACL,
# a full disk or a file someone left open.
$script:StablePublishErrors = New-Object System.Collections.Generic.List[string]

#region Exchange binding -------------------------------------------------------

function Get-LocalExchangeUri {
    # The PowerShell vdir on this server. USERDNSDOMAIN is absent under some
    # service logons, so the domain is read from WMI when it is missing rather
    # than producing http://SERVER./PowerShell/ and a confusing DNS failure.
    $dom = $env:USERDNSDOMAIN
    if ([string]::IsNullOrWhiteSpace($dom)) {
        try { $dom = [string](Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).Domain }
        catch { $dom = '' }
    }
    $target = $env:COMPUTERNAME
    if (-not [string]::IsNullOrWhiteSpace($dom)) { $target = ('{0}.{1}' -f $env:COMPUTERNAME, $dom) }
    return ('http://{0}/PowerShell/' -f $target)
}

function Get-ExchangeBinding {
    # None   nothing is bound yet.
    # SnapIn the in-process binding. Rejected - see Connect-ExchangeRunspace.
    # Proxy  a remote runspace is already imported, or a test double is loaded.
    #        Either way the caller did not get here through Add-PSSnapin, so it
    #        is left alone.
    $c = Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue
    if ($null -eq $c) { return 'None' }
    if ($c.CommandType -eq 'Cmdlet' -and
        ([string]$c.ModuleName) -like 'Microsoft.Exchange.Management.PowerShell*') { return 'SnapIn' }
    return 'Proxy'
}

function Connect-ExchangeRunspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [System.Management.Automation.PSCredential]$SessionCredential
    )

    $result = @{ Session = $null; Auth = ''; Error = '' }
    $errors = New-Object System.Collections.Generic.List[string]

    # Kerberos first because it is what a domain-joined server actually uses and
    # it is the only one of the three that can be confirmed by name in the log.
    # The others are tried so that a non-Kerberos estate still connects rather
    # than aborting on a mechanism mismatch.
    foreach ($auth in @('Kerberos', 'Negotiate', 'Default')) {
        try {
            $p = @{
                ConfigurationName = 'Microsoft.Exchange'
                ConnectionUri     = $Uri
                Authentication    = $auth
                ErrorAction       = 'Stop'
            }
            if ($null -ne $SessionCredential) { $p['Credential'] = $SessionCredential }
            $result.Session = New-PSSession @p
            $result.Auth    = $auth
            break
        }
        catch {
            $errors.Add(('{0}: {1}' -f $auth, ($_.Exception.Message -replace '\s+', ' ')))
        }
    }

    if ($null -eq $result.Session) {
        $result.Error = ($errors -join ' | ')
        return $result
    }

    try {
        # Three cmdlets, not the whole Exchange command set. A full import takes
        # tens of seconds and builds several hundred proxies this script never
        # calls; these are the three named in the Requires list above.
        #
        # The -Global re-import is not redundant. Import-PSSession called from
        # inside a function puts its proxies in that function's module scope,
        # which is discarded on return - the caller then finds no
        # Get-MailboxStatistics and reports the binding as failed, with a
        # session that is open and working. Same 5.1 module-scope trap as
        # New-PSDrive -Scope Script being invisible to Get-FileHash.
        $m = Import-PSSession -Session $result.Session `
                -CommandName 'Get-ExchangeServer', 'Get-MailboxDatabase', 'Get-MailboxStatistics' `
                -AllowClobber -DisableNameChecking -ErrorAction Stop
        Import-Module $m -Global -DisableNameChecking -Force -ErrorAction Stop
    }
    catch {
        $result.Error = ('proxy import failed: {0}' -f ($_.Exception.Message -replace '\s+', ' '))
        Remove-PSSession -Session $result.Session -ErrorAction SilentlyContinue
        $result.Session = $null
    }
    return $result
}

#endregion

# Declared out here because the finally block reads it, and StrictMode 2.0
# throws on a variable that was never assigned - which would replace the real
# abort reason with a misleading one.
$build                 = $null

try {
    Write-RunLog ('Starting BigFunnel PostingListTable monitor v{0}, run {1}, on {2}.' -f
        $script:ScriptVersion, $runId, $script:ThisServer)

    # The console header. Named separately from the log line above because the
    # log wants one greppable sentence and the screen wants two short ones.
    Write-Report ''
    Write-Report ('BigFunnel PostingListTable monitor v{0}' -f $script:ScriptVersion) 'Head'
    Write-Report ('run {0} on {1}' -f $runId, $script:ThisServer) 'Dim'
    Write-Report ''

    # Echoed in full because the first question asked of any unattended run is
    # "what was it actually configured with", and the answer should be in the
    # log rather than in whoever registered the task.
    Write-RunLog ('Settings: Scope={0}, ThresholdMode={1}, WarningGB={2}, CriticalGB={3}, TrendBaselineHours={4}, MaxRunMinutes={5}, ThrottleDelaySeconds={6}, RetentionDays={7}, MaxAlertDetail={8}, ExitNonZeroOnAlert={9}.' -f
        $Scope, $ThresholdMode, $WarningGB, $CriticalGB, $TrendBaselineHours,
        $MaxRunMinutes, $ThrottleDelaySeconds, $RetentionDays, $MaxAlertDetail, [bool]$ExitNonZeroOnAlert)

    # The Exchange snap-in is deliberately never loaded. It binds the store
    # in-process and reaches only databases mounted on this node, so a -Scope
    # All run under it drops every remote database and still writes a
    # plausible-looking summary. Measured on w25-ex01 2026-09-10, same server,
    # same minute, 4 databases across a 3-node DAG:
    #
    #   snap-in   2 databases failed,  50 mailboxes, Status Partial, exit 2
    #   runspace  0 databases failed,  97 mailboxes, Status OK,      exit 0
    #
    # The call the snap-in cannot make fails in about a second as
    # MapiNetworkErrorException, "Exchange Information Store on server <x> is
    # inaccessible. Make sure that the network is connected" - which reads like
    # an outage on a server that is in fact healthy, and is the single most
    # misleading thing this script used to be able to report.
    #
    # An already-imported runspace is reused rather than replaced, so running
    # from an Exchange Management Shell console costs nothing here. Only the
    # snap-in binding is refused.
    $script:EmsUri = $ConnectionUri
    if ([string]::IsNullOrWhiteSpace($script:EmsUri)) { $script:EmsUri = Get-LocalExchangeUri }

    $binding = Get-ExchangeBinding
    if ($binding -eq 'Proxy') {
        Write-RunLog 'Exchange cmdlets are already bound through a remote runspace in this session. Reusing it.'
        $script:BindingUsed = 'Existing'
    }
    else {
        if ($binding -eq 'SnapIn') {
            Write-RunLog 'The Exchange snap-in is loaded in this session. It cannot reach a database mounted on another DAG member, so a remote runspace is being opened and will take precedence over it.' 'WARN'
        }
        Write-RunLog ('Opening an Exchange runspace at [{0}].' -f $script:EmsUri)
        $script:EmsSession = Connect-ExchangeRunspace -Uri $script:EmsUri -SessionCredential $Credential
        if ($null -eq $script:EmsSession.Session) {
            Write-RunLog ('Could not open an Exchange runspace at [{0}]. {1}' -f
                $script:EmsUri, $script:EmsSession.Error) 'FATAL'

            # The WinRM text above lists five possible causes, and from a
            # scheduled task it is almost never any of them. SEC_E_NO_CREDENTIALS
            # (0x8009030e), or Negotiate refusing to send default credentials,
            # means this logon has no outbound network credential at all. The
            # runspace is a network logon even when the target is this same
            # server, so it fails before any of the things the WinRM text
            # suggests are ever reached.
            #
            # Session 0 is the discriminator: a scheduled task or a service runs
            # there, an interactive console does not. Both conditions together
            # make the cause near-certain, but it is still phrased as the likely
            # one, because a locked-out or expired account presents identically.
            $noCredential = ($script:EmsSession.Error -match '0x8009030e' -or
                             $script:EmsSession.Error -match 'Default credentials with Negotiate')
            $inSession0 = $false
            try { $inSession0 = ((Get-Process -Id $PID).SessionId -eq 0) } catch { }

            if ($noCredential -and $inSession0) {
                Write-RunLog 'Most likely cause: this run has no network credential to authenticate with. It is in session 0, so it is a scheduled task or a service, and opening the runspace is a network logon even though the target is this same server. A task registered with -User but no -Password gets an Interactive or an S4U logon, and neither one carries a network credential.' 'FATAL'
                Write-RunLog "Check it with: (Get-ScheduledTask -TaskName '<name>').Principal.LogonType. It has to read Password. Re-register with -User '<account>' -Password '<password>', or in Task Scheduler select 'Run whether user is logged on or not' and leave 'Do not store password' clear. A gMSA cannot be used here for the same reason." 'FATAL'
            }

            Write-RunLog 'This monitor requires one: the in-process snap-in cannot read a database mounted on another DAG member, and a run under it reports a subset of the estate as though it were the whole of it. Check that the Exchange PowerShell vdir is reachable and that this account has an Exchange RBAC role, or pass -ConnectionUri to point at another Exchange server in the organisation.' 'FATAL'
            $abortReason = 'Cannot open an Exchange runspace'
            if ($noCredential -and $inSession0) { $abortReason = 'No network credential to open an Exchange runspace' }
            $exitCode = 3
            exit $exitCode
        }
        Write-RunLog ('Exchange runspace open, Authentication={0}.' -f $script:EmsSession.Auth)
        $script:BindingUsed = ('EMS ({0})' -f $script:EmsSession.Auth)
    }

    if (-not (Get-Command Get-MailboxStatistics -ErrorAction SilentlyContinue)) {
        Write-RunLog 'Get-MailboxStatistics is still unavailable after binding. The runspace opened but imported nothing usable.' 'FATAL'
        $abortReason = 'Exchange cmdlets unavailable'
        $exitCode = 3
        exit $exitCode
    }

    # Confirm RBAC before collecting, so a permissions problem reports as a
    # fatal pre-flight rather than as every database failing individually.
    #
    # Deliberately the first store call of the run, which makes it also the call
    # implicit remoting announces itself on: the proxy functions Import-PSSession
    # generates print "Creating a new session for implicit remoting of
    # Get-MailboxDatabase command..." when they first find no live session.
    # Measured on w25-ex01, that line reached stdout on a -Quiet run that had
    # promised an empty console - a line a wrapper parsing stdout would have to
    # know to skip. It is emitted with Write-Host, so $InformationPreference does
    # not gate it (5.1 exempts Write-Host on purpose) and only a stream-6
    # redirection removes it. Absorbed here rather than script-wide: on an
    # ordinary run it is honest context about a step that is otherwise several
    # silent seconds, and a caller that asked for silence is the only one it
    # misleads.
    try {
        $probeDb = { $null = Get-MailboxDatabase -ErrorAction Stop | Select-Object -First 1 }
        if ($script:ReportSilenced) { & $probeDb 6>$null } else { & $probeDb }
    }
    catch {
        Write-RunLog ('Cannot enumerate mailbox databases. Check Exchange RBAC for this account. {0}' -f $_.Exception.Message) 'FATAL'
        $abortReason = 'Cannot enumerate mailbox databases (RBAC)'
        $exitCode = 3
        exit $exitCode
    }

    # Fail fast on a build that cannot expose the property at all, rather than
    # producing an empty CSV and a warning per mailbox.
    $build = Test-ExchangeBuild -Server $script:ThisServer
    if ($build.Known) {
        if (-not $build.Supported) {
            Write-RunLog ('This server reports {0}. BigFunnelPostingListTableTotalSize is exposed by Exchange 2019 and Exchange Server SE (15.2) and later; on earlier builds it is absent for every mailbox. Nothing collected.' -f $build.Version) 'FATAL'
            $abortReason = ('Unsupported Exchange build {0}' -f $build.Version)
            $exitCode = 3
            exit $exitCode
        }
        Write-RunLog ('Exchange build: {0}.' -f $build.Version)
    }
    else {
        Write-RunLog ('Exchange build not determined ({0}); continuing, and any missing property will be reported per mailbox.' -f $build.Reason)
    }

    #region database scope ----------------------------------------------------

    # @($null).Count is 1, not 0, so an unbound [string[]] parameter cannot be
    # length-tested directly without falsely reporting one requested database.
    $requested = @()
    if ($null -ne $Databases) {
        $requested = @($Databases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($requested.Count -gt 0) {
        $valid = New-Object System.Collections.Generic.List[string]
        foreach ($name in $requested) {
            try {
                $db = Get-MailboxDatabase -Identity $name -ErrorAction Stop
                $valid.Add([string](Get-SafeProperty $db 'Name'))
            }
            catch {
                Write-RunLog ('Database [{0}] was requested but does not exist or is not visible.' -f $name) 'ERROR'
                $script:FailedDbs.Add([string]$name)
            }
        }
        $targets = @($valid)
    }
    else {
        Write-RunLog ('No databases specified. Discovering with scope [{0}].' -f $Scope)

        # Mounted is populated only on the server hosting the active copy, so
        # filtering on it silently yields nothing when the script runs on a
        # passive DAG node. MountedOnServer is populated from any node.
        $all = @(Get-MailboxDatabase -Status -ErrorAction SilentlyContinue |
                 Where-Object { -not [string]::IsNullOrWhiteSpace([string](Get-SafeProperty $_ 'MountedOnServer')) })

        if ($Scope -eq 'Local') {
            $me = $script:ThisServer
            $targets = @($all |
                Where-Object {
                    $host_ = [string](Get-SafeProperty $_ 'MountedOnServer')
                    ($host_ -split '\.')[0] -eq $me
                } |
                ForEach-Object { [string](Get-SafeProperty $_ 'Name') })

            if ($targets.Count -eq 0 -and $all.Count -gt 0) {
                Write-RunLog ('No active database copies are mounted on {0}, but {1} database(s) are mounted elsewhere in the DAG. Expected on a passive member. -Scope Local was asked for explicitly or inherited from a saved command line; the default is now All, which reaches every database in the organization from one node. Drop -Scope Local to collect the whole DAG here, or keep it and register the task on every member so whichever node holds the active copy is the node that collects it.' -f $me, $all.Count) 'WARN'
            }
        }
        else {
            $targets = @($all | ForEach-Object { [string](Get-SafeProperty $_ 'Name') })
        }
    }

    if ($targets.Count -eq 0) {
        Write-RunLog 'No databases are in scope. Nothing to collect.' 'FATAL'
        $abortReason = 'No databases in scope'
        $exitCode = 3
        exit $exitCode
    }
    Write-RunLog ('{0} database(s) in scope: {1}' -f $targets.Count, ($targets -join ', '))
    Write-Report ('Scope {0} - {1} database(s) in scope' -f $Scope, $targets.Count)

    #endregion

    #region collection --------------------------------------------------------

    $results = New-Object System.Collections.Generic.List[object]
    $first   = $true

    # A wall-clock budget, so a slow collection cannot overrun its own schedule
    # interval and collide with the next run. This bounds the work the script
    # does; it cannot interrupt a single store call that never returns, which
    # is what -ExecutionTimeLimit on the scheduled task is for.
    $deadline = $null
    if ($MaxRunMinutes -gt 0) { $deadline = (Get-Date).AddMinutes($MaxRunMinutes) }

    foreach ($db in $targets) {
        if ($null -ne $deadline -and (Get-Date) -gt $deadline) {
            Write-RunLog ('Run budget of {0} minute(s) is spent; database [{1}] was not collected.' -f $MaxRunMinutes, $db) 'ERROR'
            $script:BudgetExceeded = $true
            $script:FailedDbs.Add([string]$db)
            continue
        }

        if (-not $first -and $ThrottleDelaySeconds -gt 0) { Start-Sleep -Seconds $ThrottleDelaySeconds }
        $first = $false

        Write-RunLog ('Collecting mailbox statistics for database [{0}].' -f $db)

        $script:MailboxesSeen = 0
        $script:DeadlineHit   = $false
        $before = $results.Count

        # Streamed rather than collected with @(...). A production database can
        # hold tens of thousands of mailboxes, and materialising every
        # statistics object before the first one is examined puts the peak
        # memory of a scheduled monitoring task on the same server whose store
        # this script exists to protect.
        #
        # Two consequences of the child scope this introduces:
        #   - counters must be $script: scoped, or ++ writes a local copy
        #   - "continue" does not skip an item here; "return" exits the block
        try {
            Get-MailboxStatistics -Database $db -ErrorAction Stop | ForEach-Object {
                $script:MailboxesSeen++

                # Checked in batches: Get-Date on every mailbox would be its own
                # cost on a population this size.
                if ($null -ne $deadline -and -not $script:DeadlineHit -and
                    ($script:MailboxesSeen % 500) -eq 0 -and (Get-Date) -gt $deadline) {
                    $script:DeadlineHit = $true
                }
                if ($script:DeadlineHit) { return }

                $stat = $_

                # Assigned before the try so the catch cannot fault on an
                # unassigned variable and mask the original error.
                $displayName = '<unknown>'

                # Per-mailbox containment: one unparseable value must not
                # discard the other several thousand mailboxes on this database.
                try {
                    $displayName = [string](Get-SafeProperty $stat 'DisplayName')

                    if ($null -eq $stat.PSObject.Properties['BigFunnelPostingListTableTotalSize']) {
                        $script:PropertyMissing++
                        return
                    }
                    $raw = Get-SafeProperty $stat 'BigFunnelPostingListTableTotalSize'

                    $bytes = Convert-ExchangeSizeToBytes -SizeValue $raw
                    if ($null -eq $bytes) {
                        # Unlimited, or a property that is present but holds
                        # nothing. Dropped rather than recorded as zero, because
                        # a mailbox whose size cannot be read is not a mailbox of
                        # size zero and would otherwise land in the population
                        # the adaptive percentiles are computed from. Counted,
                        # though: without this the CSV is quietly shorter than
                        # the "database returned N mailbox(es)" line above it and
                        # nothing in the run accounts for the difference.
                        $script:NoSizeValue++
                        return
                    }

                    $lastLogon = Get-SafeProperty $stat 'LastLogonTime'

                    # Corroborating index counters. Without these, a 0 B posting
                    # list table cannot be told apart from a mailbox that simply
                    # has no index, and on a build that never populates the
                    # table the whole population reads as healthy.
                    $indexedCount = Get-SafeProperty $stat 'BigFunnelIndexedCount'
                    $poiBytes     = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'BigFunnelTotalPOISize')
                    $largePoi     = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'BigFunnelLargePOITableTotalSize')
                    $filterBytes  = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'BigFunnelFilterTableTotalSize')

                    # Where the index actually lives on builds that leave the
                    # posting list table empty. Summed only from the parts that
                    # parsed, so one absent property does not zero the total.
                    $payload = $null
                    foreach ($part in @($poiBytes, $largePoi, $filterBytes)) {
                        if ($null -ne $part) { $payload = [int64]$payload + [int64]$part }
                    }

                    # Convert-ExchangeSizeToBytes throws on a value it cannot
                    # parse, which is right for the posting list table - that is
                    # the counter this script exists to read, and swallowing a
                    # bad reading there would report a fault as a healthy zero.
                    # It is wrong here. TotalItemSize is only ever used to decide
                    # whether a 0 B posting list table is expected, so an
                    # unreadable one means "cannot judge this mailbox", not
                    # "abandon the row". Letting it throw would take out the
                    # whole mailbox, and on a database where it threw for every
                    # row, the whole database.
                    $mailboxBytes = $null
                    try {
                        $mailboxBytes = Convert-ExchangeSizeToBytes -SizeValue (Get-SafeProperty $stat 'TotalItemSize')
                    }
                    catch { $mailboxBytes = $null }

                    $results.Add([pscustomobject]@{
                        # Named so -PassThru output is identifiable downstream: a
                        # caller can test the type rather than duck-typing on
                        # column names. Consumed by the cast rather than stored,
                        # so it adds no CSV column and nothing else changes shape.
                        PSTypeName                         = 'BigFunnel.PostingListRow'
                        # Round-trip format: unambiguous for any downstream
                        # parser regardless of the collecting server's locale.
                        Timestamp                          = (Get-Date).ToString('o')
                        Server                             = $script:ThisServer
                        Database                           = $db
                        DisplayName                        = $displayName
                        MailboxGuid                        = [string](Get-SafeProperty $stat 'MailboxGuid')
                        ItemCount                          = Get-SafeProperty $stat 'ItemCount'
                        TotalItemSize                      = [string](Get-SafeProperty $stat 'TotalItemSize')
                        # Parsed alongside the display string because the
                        # allocation-evidence test compares against it and
                        # cannot re-derive it from the formatted text without
                        # re-implementing Convert-ExchangeSizeToBytes. Null on
                        # an Unlimited or unparseable value, which the status
                        # classifier treats as "cannot judge".
                        TotalItemBytes                     = $mailboxBytes
                        BigFunnelPostingListTableTotalSize = [string]$raw
                        PostingListBytes                   = $bytes
                        PostingListGB                      = [math]::Round(($bytes / 1GB), 3)
                        # Assigned after collection: -ThresholdMode Adaptive
                        # needs the whole population before it can decide where
                        # the lines fall.
                        Status                             = $null
                        BigFunnelIsEnabled                 = Get-SafeProperty $stat 'BigFunnelIsEnabled'
                        BigFunnelIndexedCount              = $indexedCount
                        BigFunnelMessageCount              = Get-SafeProperty $stat 'BigFunnelMessageCount'
                        BigFunnelTotalPOISize              = [string](Get-SafeProperty $stat 'BigFunnelTotalPOISize')
                        BigFunnelLargePOITableTotalSize    = [string](Get-SafeProperty $stat 'BigFunnelLargePOITableTotalSize')
                        BigFunnelFilterTableTotalSize      = [string](Get-SafeProperty $stat 'BigFunnelFilterTableTotalSize')
                        IndexPayloadBytes                  = $payload
                        BigFunnelNotIndexedCount           = Get-SafeProperty $stat 'BigFunnelNotIndexedCount'
                        BigFunnelCorruptedCount            = Get-SafeProperty $stat 'BigFunnelCorruptedCount'
                        BigFunnelStaleCount                = Get-SafeProperty $stat 'BigFunnelStaleCount'
                        LastLogonTime                      = $(if ($lastLogon -is [datetime]) { $lastLogon.ToString('o') } else { [string]$lastLogon })
                        PreviousBytes                      = $null
                        DeltaBytes                         = $null
                        GrowthGBPerDay                     = $null
                        DaysToCritical                     = $null
                        Trend                              = $null
                        TrendWindowHours                   = $null

                        # Which counter the rate was taken from, and how large
                        # that counter reads on this mailbox. Both are needed
                        # together: a growth rate measured on the index payload
                        # printed beside PostingListGB produces lines reading
                        # "at 0 GB, growing 0.0161 GB/day", which is not a
                        # rounding artifact but two different counters set side
                        # by side as though they were one.
                        TrendMetric                        = $null
                        MeasuredGB                         = $null

                        SearchHealth                       = $null
                    })
                }
                catch {
                    $script:ParseFailures++
                    Write-RunLog ('Skipped mailbox [{0}] on [{1}]: {2}' -f $displayName, $db, $_.Exception.Message) 'WARN' -RowDetail
                }
            }

            if ($script:DeadlineHit) {
                Write-RunLog ('Run budget of {0} minute(s) is spent; [{1}] was cut short after {2} mailbox(es), {3} of which were recorded.' -f
                    $MaxRunMinutes, $db, $script:MailboxesSeen, ($results.Count - $before)) 'ERROR'
                $script:BudgetExceeded = $true
                $script:FailedDbs.Add([string]$db)
            }
            else {
                Write-RunLog ('Database [{0}] returned {1} mailbox(es).' -f $db, $script:MailboxesSeen)
                # Dot leaders because the database names vary in length and a
                # ragged right edge makes the counts hard to compare by eye.
                Write-Report ('  {0} {1} mailbox(es)' -f
                    ([string]$db).PadRight(34, '.'), $script:MailboxesSeen)
            }
        }
        catch {
            Write-RunLog ('Failed to collect database [{0}] after {1} mailbox(es). {2}: {3}' -f
                $db, $script:MailboxesSeen, $_.Exception.GetType().Name, $_.Exception.Message) 'ERROR'
            $script:FailedDbs.Add([string]$db)

            # Streaming means a mid-enumeration failure leaves real rows already
            # collected. They are still valid observations, so keep them and
            # report the database as partial rather than discarding the work.
            if ($results.Count -gt $before) {
                Write-RunLog ('Keeping {0} row(s) collected from [{1}] before the failure.' -f ($results.Count - $before), $db) 'WARN'
            }
            continue
        }
    }

    if ($script:PropertyMissing -gt 0) {
        Write-RunLog ('{0} mailbox(es) did not expose BigFunnelPostingListTableTotalSize. Expected on Exchange 2019 and Exchange Server SE; absence across the whole population indicates an unsupported build.' -f $script:PropertyMissing) 'WARN'
    }
    if ($script:ParseFailures -gt 0) {
        Write-RunLog ('{0} mailbox(es) were skipped because their size value could not be parsed.' -f $script:ParseFailures) 'WARN'
    }
    if ($script:NoSizeValue -gt 0) {
        Write-RunLog ('{0} mailbox(es) were skipped because BigFunnelPostingListTableTotalSize held no readable value - Unlimited, or present but empty. They are absent from the detail below; do not read that as a size of zero.' -f $script:NoSizeValue) 'WARN'
    }

    #endregion

    #region thresholds --------------------------------------------------------

    $warningBytes   = [int64][math]::Floor($WarningGB * 1GB)
    $criticalBytes  = [int64][math]::Floor($CriticalGB * 1GB)
    $thresholdBasis = 'Fixed'

    if ($ThresholdMode -eq 'Adaptive') {
        if ($results.Count -lt $AdaptiveMinimumSample) {
            Write-RunLog ('Adaptive thresholds need at least {0} mailbox(es); {1} were collected, so the fixed values stand.' -f
                $AdaptiveMinimumSample, $results.Count) 'WARN'
        }
        else {
            $ascending = @($results | ForEach-Object { [int64]$_.PostingListBytes } | Sort-Object)
            $p95 = Get-Percentile -SortedValues $ascending -Percentile 95
            $p99 = Get-Percentile -SortedValues $ascending -Percentile 99

            # Adaptive only ever raises. The fixed values stay a floor, so a
            # healthy organization is unaffected and one whose tables all sit
            # high alerts on its outliers rather than on its whole population.
            $adaptiveWarning  = [int64][math]::Max([int64]$warningBytes,  [int64]$p95)
            $adaptiveCritical = [int64][math]::Max([int64]$criticalBytes, [int64]$p99)

            if ($adaptiveWarning -ge $adaptiveCritical) {
                # Happens when the population is tightly clustered and the two
                # percentiles land on the same value. A warning tier that can
                # never fire is worse than no adaptation.
                Write-RunLog ('Adaptive thresholds did not separate (P95 {0} GB, P99 {1} GB); the fixed values stand.' -f
                    [math]::Round($p95 / 1GB, 3), [math]::Round($p99 / 1GB, 3)) 'WARN'
            }
            else {
                $warningBytes   = $adaptiveWarning
                $criticalBytes  = $adaptiveCritical
                $thresholdBasis = 'Adaptive'
                Write-RunLog ('Adaptive thresholds from {0} mailbox(es): P95 {1} GB, P99 {2} GB.' -f
                    $results.Count, [math]::Round($p95 / 1GB, 3), [math]::Round($p99 / 1GB, 3))
            }
        }
    }

    Write-RunLog ('Thresholds in force ({0}): warning {1} GB, critical {2} GB.' -f
        $thresholdBasis, [math]::Round($warningBytes / 1GB, 3), [math]::Round($criticalBytes / 1GB, 3))

    # Computed before the status loop because it needs the whole population:
    # the cheapest evidence about where this build allocates the posting list
    # table is a mailbox on which it already has.
    $evidence = Get-AllocationEvidenceBytes -Rows $results `
        -FallbackBytes ([int64]$AllocationEvidenceMB * 1MB)

    Write-RunLog ('A 0 B posting list table counts as evidence of a metric outage above {0} MB of mailbox content ({1}).' -f
        [math]::Round($evidence.Bytes / 1MB, 1),
        $(if ($evidence.Basis -eq 'Observed') { 'observed from the smallest mailbox in scope that has allocated one' } else { 'configured, no mailbox in scope has allocated one' }))

    foreach ($row in $results) {
        $row.Status = Get-PostingListStatus -Bytes ([int64]$row.PostingListBytes) `
            -WarningBytes $warningBytes -CriticalBytes $criticalBytes `
            -IndexedCount $row.BigFunnelIndexedCount `
            -MailboxBytes $row.TotalItemBytes `
            -EvidenceBytes $evidence.Bytes
    }

    #endregion

    #region trend -------------------------------------------------------------

    # Which counter growth is measured on, and whether a *date* can be put on
    # that growth as opposed to just an ordering. Both are decided per mailbox by
    # Get-TrendMetricForRow. The two run-level values below exist only to
    # describe the run in the log and in the summary; nothing downstream acts on
    # them.
    #
    # The warning and critical thresholds are sizes of the posting list table and
    # nothing else. Measuring growth on a different counter and then
    # extrapolating it to those same thresholds compares two unrelated
    # quantities: on Exchange Server SE 15.2.2562.17 the index payload is
    # single-digit megabytes while the critical line is two gigabytes, so every
    # mailbox measured that way projects out to months and every lead-time window
    # discards all of them. The report that exists to say which mailbox is next
    # then produces nothing at all, on precisely the build the fallback was
    # written for. So a row trended on the fallback counter is ranked by rate and
    # given no date, rather than extrapolated towards a line that has never been
    # validated against it.
    $payloadRows = @($results | Where-Object { (Get-TrendMetricForRow -Row $_) -eq 'IndexPayloadBytes' })
    $postingRows = @($results | Where-Object {
        $pl = ConvertTo-NullableInt64 $_.PostingListBytes
        $null -ne $pl -and $pl -gt 0
    })

    # 'PostingListBytes', 'IndexPayloadBytes' or 'Mixed'. The first two mean what
    # they always did; 'Mixed' is the state that used to be silently collapsed
    # onto whichever counter happened to have one populated mailbox behind it.
    $trendMetric = 'PostingListBytes'
    if ($payloadRows.Count -gt 0 -and $postingRows.Count -eq 0) { $trendMetric = 'IndexPayloadBytes' }
    elseif ($payloadRows.Count -gt 0)                           { $trendMetric = 'Mixed' }

    if ($payloadRows.Count -gt 0 -and $postingRows.Count -eq 0) {
        Write-RunLog ('BigFunnelPostingListTableTotalSize is 0 B for all {0} mailbox(es) in scope, so growth is being measured on IndexPayloadBytes instead. The ordering below is still meaningful - the mailbox at the top is genuinely the one growing fastest. No date is given: the warning and critical thresholds are sizes of the posting list table, they have never been validated against this counter, and a projection towards them would be arithmetic on two unrelated quantities. Use the ranking to decide what to look at first, and establish a threshold for this counter on your own estate before treating any of it as a deadline.' -f $results.Count) 'WARN' -ConsoleText @(
            'No posting list table anywhere in scope. Growth is ranked on IndexPayloadBytes instead.',
            'The ranking is real; the dates are not given, because the thresholds do not apply to that counter. Full reasoning in the log.')
    }
    elseif ($payloadRows.Count -gt 0) {
        # Deliberately does not restate the 0 B condition: the NotPopulated
        # warning above already announces that, once, and an operator scanning
        # the log for it should find one line, not two. This line answers the
        # next question instead - what the run did about it.
        #
        # The denominator is the trended population, not the scope. It used to be
        # $results.Count, which on the lab estate printed "20 of 50 ... the
        # remaining 3" - and 20 plus 3 is not 50. The 27 unaccounted mailboxes
        # were the ones carrying no index at all, which are trended on neither
        # counter and have no business being in a sentence that splits a total in
        # two. The two row sets are disjoint by construction: Get-TrendMetricForRow
        # returns PostingListBytes wherever that counter has a reading, so a
        # mailbox can be in one list or the other but never both.
        #
        # On screen this is deferred, not deleted. It used to print here, at
        # collection time, which is before the baseline has even been loaded -
        # so the run announced how growth was going to be measured roughly ten
        # lines above any growth number, and then never printed a rate at all.
        # Everything between the two was current size. The console copy now goes
        # out with the Growth block in the verdict, where there is something for
        # it to be about; the log keeps it here, in the order it was decided.
        Write-RunLog ('Growth on this run is split across two counters. Of the {1} mailbox(es) carrying a reading to trend, {0} have no posting list table and are trended on IndexPayloadBytes; the other {2} are trended on BigFunnelPostingListTableTotalSize. Both reports below are real: the posting list rows carry a projected date, and the IndexPayloadBytes rows carry a ranking and no date, for the reason given above. Do not read a short Emerging list as the whole answer on a run like this - it can only ever name mailboxes the thresholds can see.' -f
            $payloadRows.Count, ($payloadRows.Count + $postingRows.Count), $postingRows.Count) 'WARN' -RowDetail
    }

    # The warning threshold is only useful if it buys lead time, and lead time
    # requires two observations. Join against an earlier run to turn a point
    # reading into a growth rate.
    $baseline      = Get-PreviousRunBaseline -Path $OutputPath -ExcludeFile $csvPath -MinHours $TrendBaselineHours
    $baselineName  = ''
    $baselineHours = $null

    # Whether the join below actually ran. A baseline being found is not the same
    # thing: it can be found and then rejected for being too recent to divide by.
    # The reporting further down is gated on this rather than on $baseline, so
    # that a run which skipped trending entirely does not print an all-clear
    # about a measurement it never took.
    $trendComputed = $false

    if ($null -eq $baseline) {
        Write-RunLog 'No previous run found. Growth trending begins from the next run.'
    }
    else {
        $baselineName  = $baseline.Source
        $baselineHours = $baseline.AgeHours

        Write-RunLog ('Comparing against [{0}], {1} hour(s) earlier, {2} mailbox(es) baselined.' -f
            $baseline.Source, $baseline.AgeHours, $baseline.Sizes.Count)

        if (-not $baseline.MetMinimum) {
            Write-RunLog ('That window is short of the {0}-hour minimum, so the rates below are extrapolated from a narrow sample. Treat projections as provisional until the history is deeper.' -f $TrendBaselineHours) 'WARN'
        }

        if ($baseline.AgeHours -gt 0.01) {
            $trended    = 0
            $noBaseline = 0
            # Counted per counter, not in total. A run on a mixed estate can be
            # missing a previous reading on one counter and not the other, and a
            # single number cannot say which - it would name whichever metric the
            # run happened to be labelled with.
            $noReading = @{ 'PostingListBytes' = 0; 'IndexPayloadBytes' = 0 }
            $tolerance = 1MB

            foreach ($row in $results) {
                $guid = [string]$row.MailboxGuid
                if ([string]::IsNullOrWhiteSpace($guid)) { continue }

                # Not in the baseline at all: created since it was written, or on
                # a database that failed to collect on that earlier run. Counted
                # rather than dropped in silence, because "nothing is trending"
                # and "the join could not see this part of the estate" produce an
                # identical CSV, and only one of them is an answer. Measured on a
                # lab run that evaluated 47 mailboxes, baselined 45, and said
                # nothing at all about the other two.
                if (-not $baseline.Sizes.ContainsKey($guid)) { $noBaseline++; continue }

                # Per mailbox. A row whose posting list table is populated is
                # trended on it and earns a projected date; a row still reading
                # 0 B is trended on the payload and earns a rank instead. Both
                # happen in the same run on a mixed estate, which is what an
                # estate mid-transition actually looks like.
                $rowMetric   = Get-TrendMetricForRow -Row $row
                $rowProjects = ($rowMetric -eq 'PostingListBytes')

                if ($rowMetric -eq 'IndexPayloadBytes') {
                    $prev    = $baseline.Sizes[$guid].Payload
                    $current = $row.IndexPayloadBytes
                }
                else {
                    $prev    = $baseline.Sizes[$guid].Bytes
                    $current = $row.PostingListBytes
                }

                # Present in the baseline but with no reading for the chosen
                # counter - most often a baseline CSV written before this script
                # collected the payload at all. Skipped rather than treated as
                # zero, because a missing previous value coerced to 0 turns the
                # whole of the current size into one window's growth and parks
                # that mailbox at the top of the ranking for no reason.
                if ($null -eq $prev -or $null -eq $current) { $noReading[$rowMetric]++; continue }

                $delta  = [int64]$current - [int64]$prev
                $perDay = ($delta / $baseline.AgeHours) * 24.0

                $row.PreviousBytes    = [int64]$prev
                $row.DeltaBytes       = $delta
                $row.GrowthGBPerDay   = [math]::Round(($perDay / 1GB), 4)
                $row.TrendWindowHours = $baseline.AgeHours
                $row.TrendMetric      = $rowMetric
                $row.MeasuredGB       = [math]::Round(([int64]$current / 1GB), 3)

                # A direction, with tolerance so ordinary churn does not read as
                # a trend. Shrinking is the signal the runbook's post-
                # remediation cadence is actually asking for: confirmation that
                # the table came down and stayed down.
                if     ($delta -gt $tolerance)       { $row.Trend = 'Growing' }
                elseif ($delta -lt (0 - $tolerance)) { $row.Trend = 'Shrinking' }
                else                                 { $row.Trend = 'Flat' }

                # Skipped entirely when this row's rate came from a counter the
                # thresholds do not describe. Leaving DaysToCritical empty there
                # is the point: an empty column is read as "no projection", where
                # a number computed against the wrong threshold is read as a
                # deadline.
                if ($rowProjects) {
                    if ($perDay -gt 0 -and [int64]$current -lt $criticalBytes) {
                        $row.DaysToCritical = [math]::Round((($criticalBytes - [int64]$current) / $perDay), 2)
                    }
                    elseif ([int64]$current -ge $criticalBytes) {
                        $row.DaysToCritical = 0
                    }
                }
                $trended++
            }
            $trendComputed = $true
            Write-RunLog ('Growth rate computed for {0} mailbox(es) on {1}.' -f $trended, $trendMetric)
            if ($noBaseline -gt 0) {
                Write-RunLog ('{0} of {1} mailbox(es) evaluated were not in the baseline and so have no projection yet. A mailbox created since the baseline was written, or one on a database that failed to collect on that run, has no earlier reading to difference against. A large count here means the ranking covers materially less of the estate than the row count suggests.' -f
                    $noBaseline, $results.Count)
            }
            foreach ($m in @('PostingListBytes', 'IndexPayloadBytes')) {
                if ($noReading[$m] -gt 0) {
                    Write-RunLog ('{0} mailbox(es) were in the baseline but carried no {1} reading there, so no rate could be derived for them. A baseline written by an earlier version of this script does not contain that column; the next run will not have this gap.' -f
                        $noReading[$m], $m) 'WARN'
                }
            }
        }
        else {
            Write-RunLog 'Previous run is too recent to derive a meaningful rate.' 'WARN'
        }
    }

    # Index health. Corrupted items are answerable from this run alone;
    # not-indexed and stale only as a direction of travel, so both cases go
    # through one call and the baseline is optional.
    foreach ($row in $results) {
        $previous = $null
        $guid     = [string]$row.MailboxGuid
        if ($null -ne $baseline -and -not [string]::IsNullOrWhiteSpace($guid) -and $baseline.Sizes.ContainsKey($guid)) {
            $previous = $baseline.Sizes[$guid]
        }
        $row.SearchHealth = Get-SearchHealth -Row $row -Previous $previous
    }

    #endregion

    #region output ------------------------------------------------------------

    # Critical must sort first. A single -Descending applied to both keys
    # orders Status reverse-alphabetically, which puts Critical last.
    # NotPopulated needs an explicit rank too: an unmapped status yields $null
    # from this hashtable, and $null sorts ahead of 0, which would float those
    # rows above Critical. It ranks below Warning because it is a statement
    # about the metric, not about the mailbox, but above Normal because it is
    # the one row type a reader must not skim past.
    #
    # NotAllocated sits between the two. It is a benign state - the mailbox is
    # simply too small to have allocated a table yet - so it must not rank with
    # NotPopulated, which is a monitoring fault. It stays above Normal only so
    # that the rows the thresholds could not be applied to are grouped together
    # rather than scattered through the healthy population.
    $rank = @{ 'Critical' = 0; 'Warning' = 1; 'NotPopulated' = 2; 'NotAllocated' = 3; 'Normal' = 4 }

    # The size key follows whichever counter is in use, for the same reason the
    # ranking below does. PostingListBytes is zero on every row of a 0 B build,
    # so sorting the export by it leaves each status group in collection order -
    # and this is the file the log points at for the detail it had to truncate.
    # Ordering it by the counter that actually varies is what makes that pointer
    # worth following. Read off each row rather than fixed for the run, for the
    # same reason the metric is: on a mixed estate a single key leaves every row
    # the key reads zero for sitting in collection order, which is the state this
    # sort exists to avoid.
    $sizeOfRow = {
        param($Row)
        $name = Get-TrendMetricForRow -Row $Row
        $v    = ConvertTo-NullableInt64 (Get-SafeProperty -InputObject $Row -Name $name)
        if ($null -eq $v) { return [int64]0 }
        return [int64]$v
    }

    $sorted = @($results | Sort-Object `
        @{ Expression = { $rank[[string]$_.Status] }; Descending = $false }, `
        @{ Expression = { & $sizeOfRow $_ }; Descending = $true })

    try {
        $sorted | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-RunLog ('Exported {0} row(s) to [{1}].' -f $sorted.Count, $csvPath)
    }
    catch {
        # The CSV is the deliverable, so failing to write it is a real failure,
        # but the summary below is still worth emitting.
        Write-RunLog ('Failed to export CSV to [{0}]: {1}' -f $csvPath, $_.Exception.Message) 'ERROR'
        $exitCode = 2
    }

    $atRisk   = @($sorted | Where-Object { $_.Status -in @('Warning', 'Critical') })
    $crit     = @($atRisk | Where-Object { $_.Status -eq 'Critical' })
    $notPop   = @($sorted | Where-Object { $_.Status -eq 'NotPopulated' })
    $notAlloc = @($sorted | Where-Object { $_.Status -eq 'NotAllocated' })

    Write-RunLog ('Summary: {0} mailbox(es) evaluated, {1} critical, {2} warning, {3} database(s) failed.' -f
        $sorted.Count, $crit.Count, ($atRisk.Count - $crit.Count), $script:FailedDbs.Count)

    # Denominator for the escalation below. Comparing against every collected
    # row looks right and is not: a real server carries health, arbitration,
    # system and archive mailboxes that hold no index at all, so they can never
    # be NotPopulated and they hold the ratio permanently below 1. Measured in
    # the lab, 44 of 66 rows were in that category, which would have pinned a
    # total outage at WARN forever. Count only mailboxes that have an index,
    # because those are the only ones the posting list table could describe.
    #
    # Narrowed further to mailboxes large enough to have allocated a table. An
    # indexed 4 MB mailbox reading 0 B is not evidence of anything; including it
    # in the denominator was what let a lab estate of small mailboxes escalate
    # itself to a full metric outage. Only mailboxes that should have allocated
    # can testify that the counter is blind.
    $eligible = @($sorted | Where-Object {
        $c = ConvertTo-NullableInt64 $_.BigFunnelIndexedCount
        $s = ConvertTo-NullableInt64 $_.TotalItemBytes
        $null -ne $c -and $c -gt 0 -and $null -ne $s -and $s -ge $evidence.Bytes
    })

    $populated = @($sorted | Where-Object {
        $pl = ConvertTo-NullableInt64 $_.PostingListBytes
        $null -ne $pl -and $pl -gt 0
    })

    # Three-way, because "the counter did not report anything" and "the counter
    # cannot report anything" are different facts and only one of them is a
    # problem. The old two-way version collapsed them and alarmed on both.
    #
    #   Confirmed     something in scope has a populated table, so the counter
    #                 demonstrably works on this build
    #   Blind         nothing has one, and mailboxes large enough to have
    #                 allocated are reading 0 B anyway - a real monitoring gap
    #   Inconclusive  nothing has one, and nothing in scope is large enough to
    #                 prove it either way
    #
    # The flag is carried out of the block because it has to reach both the exit
    # code and the summary. Logging two ERROR lines and then reporting Status OK
    # with exit 0 is the same false negative NotPopulated was added to prevent,
    # moved one layer up: the CSV stops calling a blind mailbox healthy, and then
    # the run calls itself healthy anyway.
    $metricUnavailable  = $false
    $metricInconclusive = $false

    if ($populated.Count -gt 0) {
        $metricValidation = 'Confirmed'
    }
    elseif ($eligible.Count -gt 0) {
        $metricValidation = 'Blind'
    }
    else {
        $metricValidation = 'Inconclusive'
    }

    # Loud on purpose, but only here. If the posting list table is empty across
    # a population that should have allocated one, every threshold in this
    # script is being applied to a constant zero, and a clean run means only
    # that nothing could ever have been found.
    if ($notPop.Count -gt 0) {
        $total = $metricValidation -eq 'Blind' -and $notPop.Count -ge $eligible.Count
        $metricUnavailable = $total
        $lvl   = if ($total) { 'ERROR' } else { 'WARN' }
        Write-RunLog ('{0} of {1} eligible mailbox(es) ({2} evaluated in total) hold more than {3} MB and report BigFunnelIndexedCount above zero while BigFunnelPostingListTableTotalSize reads 0 B. On those mailboxes the index is present but is not accounted for in the posting list table, so this run cannot speak to posting list growth. Verified on Exchange Server SE 15.2.2562.17, where the index sits in the POI and filter tables instead; see the IndexPayloadBytes column.' -f
            $notPop.Count, $eligible.Count, $sorted.Count,
            [math]::Round($evidence.Bytes / 1MB, 1)) $lvl
        if ($total) {
            Write-RunLog 'Every eligible mailbox in scope is in this state, so no mailbox in this run could ever have crossed a threshold. Treat the thresholds here as untested, not as passed.' 'ERROR'
        }
    }

    # Not an alert. Nothing is wrong here - the run simply has no mailbox big
    # enough to say whether the counter works, which is the expected state on a
    # small or newly built estate. Said out loud anyway, because a run whose
    # thresholds were never exercised should not read as a run that passed
    # them. WARN rather than ERROR, and the exit code is left alone: this fires
    # on every run of a permanently small estate, and an alert that always
    # fires is an alert that gets muted.
    if ($metricValidation -eq 'Inconclusive' -and $notAlloc.Count -gt 0) {
        $metricInconclusive = $true

        $largest = 0
        foreach ($r in $notAlloc) {
            $s = ConvertTo-NullableInt64 $r.TotalItemBytes
            if ($null -ne $s -and $s -gt $largest) { $largest = $s }
        }

        Write-RunLog ('{0} indexed mailbox(es) report 0 B, and all of them are below the {1} MB at which this build is expected to allocate a posting list table - the largest holds {2} MB. That is the expected reading for a mailbox that size, not a fault, so no mailbox here is flagged. It also means no threshold in this run was tested: nothing in scope is large enough to show whether the counter works. Seed or wait for a mailbox above {1} MB to settle this either way.' -f
            $notAlloc.Count,
            [math]::Round($evidence.Bytes / 1MB, 1),
            [math]::Round($largest / 1MB, 1)) 'WARN'
    }

    if ($atRisk.Count -gt 0) {
        # Bounded. A badly affected server can hold thousands of at-risk
        # mailboxes, and one log line each would make the monitor its own
        # disk-space problem. The list is already sorted worst-first, so the
        # detail that survives the cap is the detail worth having.
        $shown = 0
        foreach ($r in $atRisk) {
            if ($shown -ge $MaxAlertDetail) { break }
            $shown++

            # Only project forward for mailboxes not already past the line;
            # "0 days to critical" reads as noise on something already critical.
            $trend = ''
            if ($null -ne $r.DaysToCritical -and $r.DaysToCritical -gt 0) {
                $trend = ', growing {0} GB/day, projected critical in {1} day(s)' -f $r.GrowthGBPerDay, $r.DaysToCritical
            }
            elseif ($null -ne $r.GrowthGBPerDay -and $r.GrowthGBPerDay -gt 0) {
                $trend = ', growing {0} GB/day' -f $r.GrowthGBPerDay
            }
            elseif ([string]$r.Trend -eq 'Shrinking') {
                $trend = ', shrinking since the baseline'
            }

            Write-RunLog ('{0}: [{1}] {2} on [{3}] at {4} GB{5}.' -f
                $r.Status, $r.MailboxGuid, $r.DisplayName, $r.Database, $r.PostingListGB, $trend) 'WARN' -RowDetail
        }
        if ($atRisk.Count -gt $shown) {
            Write-RunLog ('...and {0} further at-risk mailbox(es) not listed. Full detail is in [{1}].' -f
                ($atRisk.Count - $shown), $csvPath) 'WARN' -RowDetail
        }
        if ($ExitNonZeroOnAlert -and $exitCode -eq 0) { $exitCode = 1 }
    }

    # Emerging risk: still below the warning line, but trending into critical
    # inside the lead-time window the thresholds are meant to provide.
    #
    # Sorted by how soon each mailbox crosses, not by how large it is now. It
    # used to inherit the export's order - status rank, then size descending -
    # which ranks by the wrong quantity for this list: a mailbox two days out is
    # more urgent than a larger one twelve days out, and this is the one report
    # whose entire purpose is that ordering. The -MaxAlertDetail cap made it
    # worse than cosmetic, because the entry truncated off the bottom was the
    # soonest to cross rather than the least interesting.
    $emerging = @($sorted | Where-Object {
        $_.Status -eq 'Normal' -and $null -ne $_.DaysToCritical -and $_.DaysToCritical -le 3
    } | Sort-Object @{ Expression = { [double]$_.DaysToCritical }; Descending = $false })
    $shown = 0
    foreach ($r in $emerging) {
        if ($shown -ge $MaxAlertDetail) { break }
        $shown++
        Write-RunLog ('Emerging: [{0}] {1} on [{2}] is {3} GB but projected critical in {4} day(s).' -f
            $r.MailboxGuid, $r.DisplayName, $r.Database, $r.PostingListGB, $r.DaysToCritical) 'WARN' -RowDetail
    }
    if ($emerging.Count -gt $shown) {
        Write-RunLog ('...and {0} further emerging mailbox(es) not listed, all of them further out than the ones above.' -f ($emerging.Count - $shown)) 'WARN' -RowDetail
    }

    # Exit 6, not 1. Exit 1 means a mailbox is at or above a threshold now; this
    # means one is still below it and projected to cross inside the lead-time
    # window. Those want different responses - the first is work today, the
    # second is work this weekend - and collapsing them onto one code discards
    # the only thing this report exists to produce.
    #
    # Before this, emerging risk reached the exit code by no path at all: a run
    # could log two mailboxes projected critical in under two days, with
    # -ExitNonZeroOnAlert passed, and still exit 0. A scheduled task alerting on
    # the exit code learned nothing about the lead time the script had just
    # measured. Gated on the switch like 1 and 5, and it cannot displace either,
    # because it is only reached when the exit code is still 0.
    if ($emerging.Count -gt 0 -and $ExitNonZeroOnAlert -and $exitCode -eq 0) {
        $exitCode = 6
    }

    # The same question the emerging report answers - of everything in scope,
    # which mailbox is next - asked where no date can be put on the answer.
    # Emerging is keyed on DaysToCritical, which is deliberately left empty when
    # the rate came from a counter the thresholds do not describe, so those rows
    # are silent there no matter how fast the index is growing. This ranks them
    # instead: fastest first, which is the order in which they become someone's
    # problem even though the run cannot say when.
    #
    # Selected on the row's own metric rather than on a run-level flag. Under the
    # old gate this list appeared only when the entire scope was unreadable, so
    # on a mixed estate the very mailboxes that had no projected date also had no
    # ranking - they fell out of both reports at once.
    #
    # Filtered on Trend rather than on the raw rate, so the same 1 MB tolerance
    # that keeps ordinary churn out of the trend column keeps it out of this list
    # too. Gated on $trendComputed, so a run that never derived a rate stays
    # silent here rather than reporting that nothing grew.
    $growing = @()
    if ($trendComputed) {
        $growing = @($sorted | Where-Object {
            [string]$_.TrendMetric -eq 'IndexPayloadBytes' -and
            [string]$_.Trend -eq 'Growing' -and
            $null -ne $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0
        } | Sort-Object @{ Expression = { [double]$_.GrowthGBPerDay } } -Descending)

        if ($growing.Count -gt 0) {
            Write-RunLog ('{0} mailbox(es) grew over the {1}-hour window, measured on IndexPayloadBytes. They are ranked fastest first below. No projected date is given, for the reason logged above; treat this as the order to work through, not a countdown.' -f
                $growing.Count, $baselineHours) 'WARN'

            $shown = 0
            foreach ($r in $growing) {
                if ($shown -ge $MaxAlertDetail) { break }
                $shown++
                Write-RunLog ('Fastest growing #{0}: [{1}] {2} on [{3}] at {4} GB, growing {5} GB/day on IndexPayloadBytes.' -f
                    $shown, $r.MailboxGuid, $r.DisplayName, $r.Database, $r.MeasuredGB, $r.GrowthGBPerDay) 'WARN' -RowDetail
            }
            if ($growing.Count -gt $shown) {
                Write-RunLog ('...and {0} further growing mailbox(es) not listed. Full detail is in [{1}].' -f
                    ($growing.Count - $shown), $csvPath) 'WARN' -RowDetail
            }
        }
        elseif ($payloadRows.Count -gt 0) {
            Write-RunLog ('No mailbox grew measurably on IndexPayloadBytes over the {0}-hour window.' -f $baselineHours)
        }
    }

    # Every row trending upward, whichever counter its rate came from. The ranked
    # list above covers only the IndexPayloadBytes rows, because those are the
    # ones that get no date and so need an ordering in its place - but a summary
    # field named Growing that counts only those reports 0 on a run whose own CSV
    # plainly shows rows reading Trend=Growing. Measured on a live run: two
    # mailboxes at Trend=Growing, "Growing": 0 in the summary beside them. The
    # count and the ranked list answer different questions, so they are no longer
    # the same number.
    $growingAll = @($sorted | Where-Object { [string]$_.Trend -eq 'Growing' })

    # The runbook's post-remediation cadence asks operators to confirm the
    # table does not rebound. That question needs a shrink signal, not just a
    # size reading.
    $shrinking = @($sorted | Where-Object { [string]$_.Trend -eq 'Shrinking' })
    if ($shrinking.Count -gt 0) {
        Write-RunLog ('{0} mailbox(es) shrank since the baseline, the expected signal after remediation.' -f $shrinking.Count)
    }

    $healthIssues = @($sorted | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.SearchHealth) -and [string]$_.SearchHealth -ne 'OK'
    })
    if ($healthIssues.Count -gt 0) {
        $shown = 0
        foreach ($r in $healthIssues) {
            if ($shown -ge $MaxAlertDetail) { break }
            $shown++
            Write-RunLog ('SearchHealth: [{0}] {1} on [{2}] - {3}.' -f
                $r.MailboxGuid, $r.DisplayName, $r.Database, $r.SearchHealth) 'WARN' -RowDetail
        }
        if ($healthIssues.Count -gt $shown) {
            Write-RunLog ('...and {0} further mailbox(es) with index-health flags.' -f ($healthIssues.Count - $shown)) 'WARN' -RowDetail
        }
        # Deliberately does not move the exit code: table size and index health
        # are separate problems with separate remediations, and quietly
        # redefining what a non-zero exit means would break existing alerting.
        Write-RunLog 'Index-health flags are reported for triage and do not change the exit code.'
    }

    if ($script:FailedDbs.Count -gt 0) {
        Write-RunLog ('Partial results. Not collected: {0}' -f ($script:FailedDbs -join ', ')) 'ERROR'
        $exitCode = 2
    }

    # After the partial-failure check so 2 wins: a run that could not collect a
    # database has a bigger problem than one that collected everything and found
    # the counter empty. Gated on -ExitNonZeroOnAlert for the same reason 1 is -
    # at defaults this script returns 0 for anything short of a breakage and
    # reports through latest-summary.json - but a caller that asked for alert
    # exit codes asked for this one too. "The metric is blind" is the alert.
    if ($metricUnavailable -and $ExitNonZeroOnAlert -and $exitCode -eq 0) {
        $exitCode = 5
    }

    # Guarded on the run having produced rows. A run that collected nothing -
    # every database failed, or the scope matched no mailbox - still reaches here
    # with a header-only CSV, and copying that over latest.csv destroys the last
    # good detail at the exact moment someone goes looking for it. Measured: a
    # 15-row, 6488-byte latest.csv replaced by a 3-byte file by a run that
    # reported exit 2 and was therefore already known to have failed. The failure
    # is signalled by the exit code and the summary; it does not also need to
    # take the previous answer with it.
    if ($sorted.Count -gt 0 -and (Test-Path -LiteralPath $csvPath)) {
        try { Copy-Item -LiteralPath $csvPath -Destination $latestCsv -Force -ErrorAction Stop }
        catch {
            Write-RunLog ('Could not refresh [{0}]: {1}' -f $latestCsv, $_.Exception.Message) 'WARN'
            $script:StablePublishErrors.Add(('latest.csv: {0}' -f $_.Exception.Message))
        }
    }
    elseif ($sorted.Count -eq 0 -and (Test-Path -LiteralPath $latestCsv)) {
        Write-RunLog ('This run produced no rows, so [{0}] has been left untouched and still holds the detail from the last run that collected something. Read it together with this run''s exit code, not instead of it.' -f $latestCsv) 'WARN'
    }

    # A monitor that cannot publish its verdict has not monitored. The
    # collection above may have been flawless, but latest.csv and
    # latest-summary.json are the only two files a scheduled consumer reads, and
    # a stale pair sitting behind a success code is precisely the failure this
    # script exists to expose. Escalated here, before the summary is written, so
    # the ExitCode and Status it carries agree with what the process returns.
    if ($script:StablePublishErrors.Count -gt 0) { $exitCode = 3 }

    # Lifted out of the hashtable below so the console verdict and the published
    # summary cannot drift apart. They used to be one expression, which meant
    # the only way to show the verdict on screen was to recompute it - and two
    # copies of a seven-branch precedence is one copy too many.
    $runStatus = $(
        if ($script:StablePublishErrors.Count -gt 0) { 'PublishFailed' }
        elseif ($exitCode -eq 2)       { 'Partial' }
        elseif ($atRisk.Count -gt 0)   { 'Alert' }
        elseif ($metricUnavailable)    { 'MetricUnavailable' }
        elseif ($emerging.Count -gt 0) { 'Emerging' }
        elseif ($metricInconclusive)   { 'MetricInconclusive' }
        else                           { 'OK' }
    )

    Write-RunSummary -Path $latestJson -Values @{
        RunId                = $runId
        DurationSeconds      = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
        Scope                = $Scope
        ExchangeVersion      = $(if ($build.Known) { [string]$build.Version } else { '' })
        Binding              = $script:BindingUsed
        ConnectionUri        = $script:EmsUri
        Completed            = $true
        # Ungated, unlike the exit code above. A caller reading this file is
        # entitled to the finding whether or not it asked for alert exit codes.
        #
        # Status used to describe only whether the run worked, so a run that
        # found a critical mailbox reported "OK" while Critical read 1 and
        # ExitCode read 1. That was defensible in isolation and wrong in
        # practice: MetricUnavailable is also a finding and did surface here, so
        # the field was already half a signal, and the documented integration -
        # alert when Status is not OK - went silent on exactly the condition the
        # script exists to detect. Measured on w25-ex01: Critical 1, Warning 1,
        # ExitCode 1, Status OK.
        #
        # Ordered worst-first, and deliberately parallel to the exit codes:
        # failing to publish the run at all (3) outranks everything, because a
        # consumer that cannot read this run's verdict learns nothing from the
        # rest of the field; then a database that was never collected (2)
        # outranks a threshold crossed now (1), which outranks a counter that
        # read zero (5), which outranks a mailbox projected to cross later (6).
        # MetricInconclusive sits last before OK because it is not a fault at
        # all - it is a scope too small to prove anything either way.
        #
        # PublishFailed can only ever be read when latest.csv was the file that
        # failed. If the summary itself could not be written this value never
        # reaches disk, which is exactly why the exit code carries it too.
        Status               = $runStatus
        # Confirmed: something in scope has a populated posting list table, so
        # the counter demonstrably works on this build. Blind: nothing is
        # populated and something large enough to have been is sitting at 0 B.
        # Inconclusive: nothing is populated and nothing in scope is big enough
        # to settle it. Read this before trusting an all-clear.
        MetricValidation     = $metricValidation
        AllocationEvidenceMB = [math]::Round($evidence.Bytes / 1MB, 1)
        # Observed = derived from the smallest populated mailbox in this run.
        # Configured = nothing was populated, so -AllocationEvidenceMB was used.
        AllocationEvidenceBasis = $evidence.Basis
        ThresholdMode        = $ThresholdMode
        ThresholdBasis       = $thresholdBasis
        WarningGB            = [math]::Round($warningBytes / 1GB, 3)
        CriticalGB           = [math]::Round($criticalBytes / 1GB, 3)
        ConfiguredWarningGB  = $WarningGB
        ConfiguredCriticalGB = $CriticalGB
        DatabasesInScope     = $targets.Count
        DatabasesFailed      = $script:FailedDbs.Count
        FailedDatabases      = ($script:FailedDbs -join ', ')
        RunBudgetExceeded    = $script:BudgetExceeded
        MailboxesEvaluated   = $sorted.Count
        Critical             = $crit.Count
        Warning              = ($atRisk.Count - $crit.Count)
        Emerging             = $emerging.Count
        Shrinking            = $shrinking.Count
        SearchHealthIssues   = $healthIssues.Count
        NotPopulated         = $notPop.Count
        # Indexed, reading 0 B, and below the allocation evidence bar. Expected,
        # not a fault. Counted separately so a consumer can see the difference
        # between "the counter is blind" and "these mailboxes are small".
        NotAllocated         = $notAlloc.Count
        SkippedUnparseable   = $script:ParseFailures
        SkippedNoSize        = $script:NoSizeValue
        MissingProperty      = $script:PropertyMissing
        TrendBaseline        = $baselineName
        TrendWindowHours     = $baselineHours
        TrendMetric          = $trendMetric
        # Rows trended on the fallback counter. On a 'Mixed' run this is the size
        # of the population the Emerging list structurally cannot see, so a
        # consumer reading Emerging as the whole answer can tell how much of the
        # estate that answer leaves out.
        TrendedOnPayload     = $payloadRows.Count
        Growing              = $growingAll.Count
        GrowingRanked        = $growing.Count
        DetailCsv            = $csvPath
        PublishErrors        = (($script:StablePublishErrors | Select-Object -Unique) -join ' | ')
        Elevated             = $script:Elevated
        ExitCode             = $exitCode
    }
    if ($script:SummaryWritten) {
        Write-RunLog ('Wrote run summary to [{0}].' -f $latestJson)
    }
    else {
        # The summary is the one artefact a scheduled consumer polls. If it could
        # not be written then nothing on disk records this run's verdict, and the
        # exit code is the only channel left to say so. ERROR rather than WARN:
        # this is the difference between a monitor that found nothing and a
        # monitor that reported nothing.
        $exitCode = 3
        Write-RunLog ('The run summary could not be published, so [{0}] still describes an earlier run. Exiting 3 so this run is not mistaken for a healthy one.' -f $latestJson) 'ERROR'
    }

    Remove-ExpiredOutput -Path $OutputPath -Days $RetentionDays
    Write-RunLog ('Monitor run complete. Exit code {0}.' -f $exitCode)

    #region console verdict ---------------------------------------------------
    #
    # The block an operator actually reads. Every number here is taken from the
    # same variables the summary was built from rather than re-derived, so the
    # screen and latest-summary.json cannot disagree - a monitor whose console
    # output contradicts its own published verdict is worse than one that says
    # nothing, which is what this used to do.

    # Worst-first, matching the Status precedence and the exit codes. OK and
    # MetricInconclusive are the two that are not findings.
    $verdictStyle = switch ($runStatus) {
        'OK'                 { 'Good' }
        'MetricInconclusive' { 'Plain' }
        'Emerging'           { 'Warn' }
        'Alert'              { 'Warn' }
        default              { 'Bad' }
    }

    Write-Report ''
    Write-Report ('  RESULT  {0}' -f $runStatus) $verdictStyle
    Write-Report ('  {0} mailbox(es) evaluated in {1}s' -f
        $sorted.Count, [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)) 'Dim'
    Write-Report ''

    # Counts that are zero are still printed. A row missing because it was zero
    # reads identically to a row missing because the script never looked, and
    # the whole complaint this block answers was not being able to tell.
    $rows = @(
        @{ Label = 'Critical';         Value = $crit.Count;                      Bad = ($crit.Count -gt 0) },
        @{ Label = 'Warning';          Value = ($atRisk.Count - $crit.Count);    Bad = (($atRisk.Count - $crit.Count) -gt 0) },
        @{ Label = 'Emerging';         Value = $emerging.Count;                  Bad = $false },
        @{ Label = 'Databases failed'; Value = $script:FailedDbs.Count;          Bad = ($script:FailedDbs.Count -gt 0) }
    )
    foreach ($r in $rows) {
        Write-Report ('    {0} {1}' -f ([string]$r.Label).PadRight(20, ' '), $r.Value) `
                     $(if ($r.Bad) { 'Warn' } else { 'Plain' })
    }
    # Named rather than numbered: "Confirmed" and "Blind" are the words the
    # runbook and the summary use, and a count here would mean nothing.
    Write-Report ('    {0} {1}' -f 'Counter'.PadRight(20, ' '), $metricValidation) `
                 $(if ($metricValidation -eq 'Blind') { 'Bad' } else { 'Plain' })

    # Which mailboxes actually carry the counter this monitor is named after.
    # The run already prints how many - "the other 3 are trended on
    # BigFunnelPostingListTableTotalSize" - and a bare 3 is a worse answer than
    # no answer, because the only way to turn it into names was the 32-column
    # CSV or a log with a line per mailbox in it. On this estate those three are
    # the entire point of the run and they were the hardest thing in the output
    # to find.
    #
    # Self-suppressing above ten. A handful is a list worth reading; a hundred
    # is the CSV's job, and on a healthy estate where every mailbox has a
    # posting list table this block would otherwise be the whole report.
    $namedGuids = New-Object System.Collections.Generic.HashSet[string]
    if ($postingRows.Count -gt 0 -and $postingRows.Count -le 10) {
        # Keyed on GUID rather than on the row objects, because the emerging and
        # at-risk sets are built by separate Where-Object passes and reference
        # equality is not something this code should be relying on.
        $emergingGuids = New-Object System.Collections.Generic.HashSet[string]
        foreach ($r in $emerging) { $null = $emergingGuids.Add([string]$r.MailboxGuid) }

        # Findings only, by default. A Normal row is the absence of a finding,
        # and a verdict block that spends three lines listing mailboxes that are
        # fine is back to being the wall of text this block was shortened out of
        # - on a healthy estate every line here would be one. The count above
        # still says they exist and how many, which is the part that is worth a
        # line on a clean run.
        #
        # -Verbose lists them, rather than a switch of its own: the script
        # already documents -Verbose as the lever for wanting more of the
        # report, and a display nicety does not need its own parameter.
        $interesting = @($postingRows | Where-Object {
            $_.Status -ne 'Normal' -or $emergingGuids.Contains([string]$_.MailboxGuid)
        })
        $showAll = ($VerbosePreference -ne 'SilentlyContinue')
        $toList  = @(if ($showAll) { $postingRows } else { $interesting })
        $hidden  = $postingRows.Count - $toList.Count

        Write-Report ''
        Write-Report ('  Posting list table present on {0} of {1} mailbox(es)' -f
            $postingRows.Count, $sorted.Count) 'Dim'
        foreach ($r in ($toList | Sort-Object { [double]$_.PostingListGB } -Descending)) {
            $null = $namedGuids.Add([string]$r.MailboxGuid)
            # Emerging is not a Status - it is Normal plus a projection inside
            # the lead window - so a row that is driving the Emerging count
            # prints as Normal here and the count above looks unattributable.
            # Labelled with what earned it the count, which is the only reason
            # it is being shown.
            $isEmerging = $emergingGuids.Contains([string]$r.MailboxGuid)
            $label = if ($isEmerging) { 'Emerging' } else { [string]$r.Status }

            # Every finding carries its own rate, not only the Emerging ones.
            # Annotating Emerging alone made growth look like a property of that
            # one label, when "Critical and still climbing 0.08 GB/day" and
            # "Critical and flat since Tuesday" are different problems with
            # different urgency and this block showed them identically. A Normal
            # row stays bare: it is only on screen under -Verbose at all, and a
            # rate on it belongs to the Growth block rather than to a fourth
            # column on a line that is not a finding.
            $isFinding = $isEmerging -or $r.Status -eq 'Critical' -or $r.Status -eq 'Warning'
            $ann  = if ($isFinding) { Format-GrowthAnnotation -Row $r -ExplainAbsence } else { '' }
            $tail = if ($ann) { '  ' + $ann } else { '' }
            Write-Report ('    {0}  {1} on {2}  {3} GB{4}' -f
                $label.PadRight(8, ' '), $r.DisplayName, $r.Database, $r.PostingListGB, $tail) `
                $(if ($r.Status -eq 'Critical') { 'Bad' }
                  elseif ($r.Status -eq 'Warning' -or $isEmerging) { 'Warn' }
                  else { 'Plain' })
        }
        # Said rather than silently dropped. "3 of 97" with nothing under it
        # reads as a block that failed to print, and the names are still the
        # answer to a question somebody will eventually ask - so the run says
        # where to get them instead of pretending there is nothing to get.
        if ($hidden -gt 0) {
            Write-Report ('    {0} reading Normal, not listed. -Verbose lists them.' -f $hidden) 'Dim'
        }
    }
    elseif ($postingRows.Count -gt 10) {
        Write-Report ('    {0} {1} of {2} mailbox(es) - see the report' -f
            'Posting list table'.PadRight(20, ' '), $postingRows.Count, $sorted.Count) 'Plain'
    }

    # Growth, which until now reached the console by no path at all. Every other
    # number in this report is a current size: the counts are sizes against a
    # threshold, the roll call is sizes, "Worst affected" is sizes. The script
    # measures a rate for every trendable mailbox and computes a projected date
    # for the ones the thresholds describe, and all of it went to the log and the
    # CSV only - so a report whose entire justification is lead time never showed
    # any. Emerging was the single growth-derived figure on screen, and it is a
    # count with no rate behind it.
    #
    # This is also where the two-counter warning belongs. It was printing at
    # collection time, above the verdict, explaining how growth would be measured
    # before anything had measured any - the operator read a paragraph about
    # projected dates and then scrolled past nine lines of sizes without meeting
    # one. Said here it is a caveat on the numbers directly beneath it.
    Write-Report ''
    if (-not $trendComputed) {
        # Distinguished from "nothing grew". A first run has no baseline to
        # difference against, and reporting that as zero growth would be the
        # script inventing a measurement it did not take.
        Write-Report '  Growth' 'Dim'
        Write-Report '    No baseline old enough to measure against. The next run is the first that can.' 'Dim'
    }
    else {
        # The window and what it was measured against, because a rate is
        # meaningless without them - 0.02 GB/day off a 40-hour window and off a
        # 40-minute one are not the same claim, and the second is the one that
        # produces a wild projection.
        $baseShort = [string]$baselineName -replace '^BigFunnelPostingListMonitor-', '' -replace '\.csv$', ''
        Write-Report ('  Growth  measured over {0}h, against run {1}' -f $baselineHours, $baseShort) 'Dim'
    }

    # Printed whether or not a rate was computed. Which counters are readable is
    # a property of the estate, not of the baseline: on a first run there is no
    # growth to caveat yet, but the operator still needs to know that a later run
    # can only ever put a date on part of it.
    if ($payloadRows.Count -gt 0 -and $postingRows.Count -gt 0) {
        Write-Report ('    Two counters in use: {0} dated on BigFunnelPostingListTableTotalSize, {1} ranked only on IndexPayloadBytes.' -f
            $postingRows.Count, $payloadRows.Count) 'Warn'
    }
    elseif ($payloadRows.Count -gt 0) {
        Write-Report ('    All {0} trended on IndexPayloadBytes - ranked only, no projected date.' -f
            $payloadRows.Count) 'Warn'
    }

    if ($trendComputed) {
        # Only what the roll call did not already annotate. Every finding now
        # carries its rate on its own line, so listing the same three mailboxes
        # again under a second heading is not emphasis - it is one mailbox read
        # twice by an operator working out whether they are two.
        #
        # What survives the filter is the population nothing else in this report
        # can show: mailboxes that are growing and are not yet a finding. One at
        # 0.2 GB climbing 0.5 GB/day is weeks away from anything the thresholds
        # will say a word about, and it is the most interesting row on the estate.
        # When the roll call self-suppressed above ten, nothing was named and this
        # degrades to the plain fastest-first list it used to be.
        #
        # Both counters in one list, ordered by rate. Splitting them into two
        # headed sections was the first attempt and it reintroduced the problem
        # the split warning exists to flag: whichever list came second read as an
        # afterthought, when the fastest-growing mailbox on the estate is just as
        # likely to be in it. Which counter a row came from is carried on the row
        # instead, by the annotation.
        $fastest = @($sorted | Where-Object {
            $null -ne $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0 -and
            -not $namedGuids.Contains([string]$_.MailboxGuid)
        } | Sort-Object @{ Expression = { [double]$_.GrowthGBPerDay } } -Descending)

        if ($fastest.Count -eq 0) {
            # "Nothing grew" and "nothing else grew" are different claims, and
            # only the second one is true on a run that has just printed three
            # rates directly above this line.
            Write-Report $(if ($namedGuids.Count -gt 0) {
                               '    Nothing else grew measurably over that window.'
                           } else {
                               '    Nothing grew measurably over that window.'
                           }) 'Plain'
        }
        else {
            foreach ($r in ($fastest | Select-Object -First 3)) {
                $null = $namedGuids.Add([string]$r.MailboxGuid)
                # MeasuredGB and not PostingListGB. The size printed here has to
                # be read off the same counter as the rate beside it, or a row
                # trended on the index payload prints as "0 GB, +0.0161 GB/day" -
                # not a rounding artifact but two different counters set side by
                # side as though they were one number.
                Write-Report ('    {0} on {1}  {2} GB  {3}' -f
                    $r.DisplayName, $r.Database, $r.MeasuredGB, (Format-GrowthAnnotation -Row $r)) `
                    $(if ($null -ne $r.DaysToCritical -and [double]$r.DaysToCritical -gt 0 -and
                          [double]$r.DaysToCritical -le 3) { 'Warn' } else { 'Plain' })
            }
            if ($fastest.Count -gt 3) {
                Write-Report ('    ...and {0} more growing, in the report below' -f ($fastest.Count - 3)) 'Dim'
            }
        }
    }

    # A bounded sample of what was found, so the block answers "which ones"
    # without becoming the list it replaced. Three, because the point is to give
    # the operator somewhere to start rather than the whole finding - the CSV
    # named below carries every row, sorted worst-first already.
    #
    # Skipped entirely when the block above already named every at-risk mailbox,
    # which is the normal case on an estate where only a handful of mailboxes
    # have a posting list table at all: the two lists were identical, printed
    # one under the other, under two different headings. Repeating a finding is
    # not emphasis, it is another thing to read before reaching the exit code.
    $unnamed = @($atRisk | Where-Object { -not $namedGuids.Contains([string]$_.MailboxGuid) })
    if ($atRisk.Count -gt 0 -and $unnamed.Count -gt 0) {
        Write-Report ''
        Write-Report '  Worst affected' 'Dim'
        foreach ($r in ($unnamed | Select-Object -First 3)) {
            # Annotated on the same terms as the roll call. On an estate above
            # ten posting-list mailboxes the roll call collapses to a count, so
            # this block is the only place a finding is named at all - and
            # leaving the rate off here would mean the bigger the estate, the
            # less the report says about growth. Everything in $atRisk is a
            # finding by construction, so the absence wording always applies.
            $ann  = Format-GrowthAnnotation -Row $r -ExplainAbsence
            $tail = if ($ann) { '  ' + $ann } else { '' }
            Write-Report ('    {0}  {1} on {2}  {3} GB{4}' -f
                ([string]$r.Status).PadRight(8, ' '), $r.DisplayName, $r.Database, $r.PostingListGB, $tail) `
                $(if ($r.Status -eq 'Critical') { 'Bad' } else { 'Warn' })
        }
        if ($unnamed.Count -gt 3) {
            Write-Report ('    ...and {0} more in the report below' -f ($unnamed.Count - 3)) 'Dim'
        }
    }

    Write-Report ''
    Write-Report ('  Report  {0}' -f $csvPath) 'Dim'
    if ($script:LogFile) { Write-Report ('  Log     {0}' -f $script:LogFile) 'Dim' }
    Write-Report ''
    Write-Report ('  Exit code {0}' -f $exitCode) $verdictStyle
    # The one combination that reliably reads as a contradiction: a RESULT
    # naming a finding directly above a zero. Both are correct - codes 1, 5 and
    # 6 are gated behind -ExitNonZeroOnAlert so that adding the monitor to an
    # existing scheduler cannot start failing tasks on day one - but nothing on
    # screen said so, and the operator is left deciding which half to believe.
    if ($exitCode -eq 0 -and $runStatus -ne 'OK' -and $runStatus -ne 'MetricInconclusive') {
        Write-Report '  0 because -ExitNonZeroOnAlert was not passed. The finding above is still real.' 'Dim'
    }
    Write-Report ''

    # Last, and only on request. Everything above this line went out through
    # Write-Host so that this stream could stay empty by default, which is what
    # makes $r = .\Monitor-BigFunnelPostingList.ps1 -PassThru return rows and
    # nothing else - no report text to strip back out of the result.
    if ($PassThru) { $sorted }

    #endregion

    #endregion
}
catch {
    # Anything unanticipated still produces a log line and a distinct exit
    # code rather than an opaque stack trace in the task history.
    Write-RunLog ('Unhandled failure: {0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message) 'FATAL'
    Write-RunLog ('At: {0}' -f $_.ScriptStackTrace) 'FATAL'
    $abortReason = ('{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message)
    $exitCode = 3
}
finally {
    # Reached on exit as well as on a fall-through, so every abort inside the
    # try lands here. Without this, a run that failed pre-flight would leave
    # the previous run's summary untouched and a monitoring agent would keep
    # reporting the last healthy result while the monitor was dead.
    if (-not $script:SummaryWritten) {
        $abortStatus = $(if ([string]::IsNullOrWhiteSpace($abortReason)) { 'Aborted' } else { $abortReason })

        # There is no such thing as a successful incomplete run, so reaching
        # here with 0 is always wrong. Every abort inside the try sets 3 before
        # it exits; the one that cannot is an interrupt. Ctrl+C is a pipeline
        # stop rather than an exception, so it skips the catch above, runs this
        # finally, and leaves $exitCode at the 0 it was initialised with.
        # Observed on w25-ex01: a run interrupted during database discovery
        # printed "RESULT Aborted" in red directly above "Exit code 0" and
        # published ExitCode 0 beside Completed false - so a scheduler reading
        # the exit code, which is the documented integration, recorded a clean
        # run that never collected a mailbox. Completed false caught it only for
        # a consumer already parsing the summary.
        if ($exitCode -eq 0) { $exitCode = 3 }

        Write-RunSummary -Path $latestJson -Values @{
            RunId                = $runId
            DurationSeconds      = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
            Scope                = $Scope
            Completed            = $false
            Status               = $abortStatus
            # Carried onto the abort path too. Most aborts happen after the
            # build has been read, and dropping it here forces whoever triages
            # the alert back onto the log to answer the first question they will
            # ask. $build is $null only if the abort preceded the probe.
            ExchangeVersion      = $(if ($null -ne $build -and $build.Known) { [string]$build.Version } else { '' })
            ThresholdMode        = $ThresholdMode
            ConfiguredWarningGB  = $WarningGB
            ConfiguredCriticalGB = $CriticalGB
            DatabasesFailed      = $script:FailedDbs.Count
            FailedDatabases      = ($script:FailedDbs -join ', ')
            RunBudgetExceeded    = $script:BudgetExceeded
            SkippedUnparseable   = $script:ParseFailures
            MissingProperty      = $script:PropertyMissing
            PublishErrors        = (($script:StablePublishErrors | Select-Object -Unique) -join ' | ')
            Elevated             = $script:Elevated
            ExitCode             = $exitCode
        }

        # The abort verdict. Without this the whole class of runs that fail
        # before they collect anything - no runspace, nothing in scope, a
        # refused mutex - print a warning or two and then simply stop, which
        # leaves an operator staring at a returned prompt wondering whether it
        # worked. Only on the abort path: the completed path has already
        # printed its own block above.
        Write-Report ''
        Write-Report ('  RESULT  {0}' -f $abortStatus) 'Bad'
        Write-Report '  The run did not complete, so nothing was collected.' 'Dim'
        if ($script:LogFile) { Write-Report ('  Log     {0}' -f $script:LogFile) 'Dim' }
        Write-Report ''
        Write-Report ('  Exit code {0}' -f $exitCode) 'Bad'
        Write-Report ''
    }

    if ($null -ne $mutex) {
        if ($holding) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }

    # Closed here rather than after the collection loop so that an abort mid-run
    # does not leave a runspace open on the Exchange server. Only sessions this
    # script opened are closed: a console that imported its own is left alone,
    # because tearing down the caller's session would be a surprising thing for
    # a read-only monitor to do.
    if ($null -ne $script:EmsSession -and $null -ne $script:EmsSession.Session) {
        Remove-PSSession -Session $script:EmsSession.Session -ErrorAction SilentlyContinue
    }
}

exit $exitCode
