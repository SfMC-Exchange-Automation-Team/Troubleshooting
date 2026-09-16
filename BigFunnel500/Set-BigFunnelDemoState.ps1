<#
.SYNOPSIS
Puts three real lab mailboxes into a standing Critical / Warning / Emerging
state, so a demonstration can start from a run that already has findings.

.DESCRIPTION
Run this once before a demo. Afterwards, an ordinary monitor run against
-OutputPath reports one Critical mailbox, one Warning and one Emerging, every
time, until the directory is cleared. Nothing grows during the demonstration
and no mailbox is modified.

WHY THIS EXISTS, AND WHAT IT IS HONEST ABOUT

The obvious approach - grow three mailboxes until they cross the real 1.7 / 2.0
GB thresholds - does not work on this estate, and the reason is worth stating
here rather than discovering live:

  * The posting list table tops out at 0.704 GB on the largest seeded mailbox.
    Seeding yield is capped at a few bytes per indexed token and a larger
    vocabulary makes it worse, so 2.0 GB is not reachable by adding mail.
  * Every run recorded on this estate since 2026-09-11 reads the same three
    values. The population is flat, and a flat population cannot produce a
    growth rate, so Emerging cannot fire at all however long you wait.

So this script does two different things, and only one of them is real:

  1. Critical and Warning are REAL. They are the live sizes of the two largest
     seeded mailboxes, measured by the monitor during this run, compared
     against a threshold pair scaled to this estate (-CriticalGB 0.65,
     -WarningGB 0.50) instead of the production 2.0 / 1.7. The mailboxes
     genuinely are that big. Nothing about those two rows is fabricated.

  2. Emerging is a FIXTURE. A growth rate needs two observations, this estate
     only has one distinct observation, so the earlier one is written by this
     script. It collects the real population, back-dates that CSV, and lowers
     exactly one cell in it - the Emerging mailbox's PostingListBytes - by the
     amount that makes today's real size project across the critical threshold
     inside the 3-day Emerging window. One cell, in one file, in a directory
     used for nothing else.

That distinction is written to DEMO-FIXTURE.txt in -OutputPath as well as
printed here, because a demo directory that looks exactly like a production one
is how a fixture ends up being quoted as a measurement.

.PARAMETER OutputPath
The demo directory. Deliberately NOT the production
C:\ProgramData\ExchangeBigFunnelPostingListMonitor: this script deletes every
run file it finds, and the back-dated baseline must be the only history present
or the monitor trends against a real run instead of the fixture.

.PARAMETER MonitorPath
The monitor to drive. Defaults to the copy sitting beside this script.

.PARAMETER CriticalGB
Scaled to what this estate actually holds. At the production 2.0 no mailbox
here can reach it, which is the whole reason this script exists.

.PARAMETER WarningGB
As above, in place of the production 1.7.

.PARAMETER CriticalMailbox
The mailbox nominated to stand Critical. Checked, not assumed: the script
verifies after the fact that it landed there, and fails if it did not.

.PARAMETER WarningMailbox
The mailbox nominated to stand Warning. Must sit between the two thresholds.

.PARAMETER EmergingMailbox
The mailbox nominated to stand Emerging. Must be below -WarningGB, because
Emerging only applies to a row still reading Normal.

.PARAMETER BaselineAgeHours
How far back the fixture baseline is stamped. Must exceed the monitor's
-TrendBaselineHours (24 by default) or the join rejects it as too recent to
divide by.

.PARAMETER TargetDaysToCritical
Where in the 3-day Emerging window the fixture should land. Deliberately not on
the boundary: DaysToCritical is recomputed from the live size at demo time, and
a fixture aimed at 2.99 days drops out of Emerging the moment the mailbox moves
by a few megabytes.

.PARAMETER Scope
Passed straight through to the monitor.

.EXAMPLE
.\Set-BigFunnelDemoState.ps1

Prepares the demo and prints the single command to run in front of an audience.
#>
[CmdletBinding()]
param(
    [string]$OutputPath      = 'C:\ProgramData\ExchangeBigFunnelPostingListMonitor-demo',
    [string]$MonitorPath     = (Join-Path $PSScriptRoot 'Monitor-BigFunnelPostingList.ps1'),
    [double]$CriticalGB      = 0.65,
    [double]$WarningGB       = 0.50,
    [string]$CriticalMailbox = 'bfseed03',
    [string]$WarningMailbox  = 'bfseed01',
    [string]$EmergingMailbox = 'bfseed02',
    [int]$BaselineAgeHours   = 48,
    [double]$TargetDaysToCritical = 2.5,
    [ValidateSet('Local', 'All')]
    [string]$Scope           = 'All'
)

$ErrorActionPreference = 'Stop'

function Fail { param([string]$m) Write-Host ('  FAILED  ' + $m) -ForegroundColor Red; exit 1 }
function Step { param([string]$m) Write-Host ('  ' + $m) -ForegroundColor Cyan }
function Note { param([string]$m) Write-Host ('    ' + $m) -ForegroundColor DarkGray }

if (-not (Test-Path -LiteralPath $MonitorPath)) { Fail ('Monitor not found at ' + $MonitorPath) }

Write-Host ''
Write-Host '  BigFunnel demo state' -ForegroundColor Cyan
Write-Host ('  thresholds for this estate: Warning {0} GB, Critical {1} GB' -f $WarningGB, $CriticalGB) -ForegroundColor DarkGray
Write-Host ''

# --- 1. A directory with no history in it -----------------------------------
# The fixture baseline has to be the only candidate. Get-PreviousRunBaseline
# takes the NEWEST run at least -TrendBaselineHours old, so one leftover real
# run from yesterday silently wins and the Emerging row quietly goes flat -
# which reads like the script did nothing, rather than like a stale directory.
Step ('Clearing ' + $OutputPath)
if (Test-Path -LiteralPath $OutputPath) {
    $old = @(Get-ChildItem -LiteralPath $OutputPath -File -ErrorAction SilentlyContinue)
    if ($old.Count -gt 0) {
        Note ('removing {0} file(s) from the previous demo' -f $old.Count)
        $old | Remove-Item -Force
    }
}
else {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

# --- 2. Collect the estate for real -----------------------------------------
Step 'Collecting the live estate (this is an ordinary monitor run)'
& $MonitorPath -OutputPath $OutputPath -Scope $Scope -Quiet `
               -WarningGB $WarningGB -CriticalGB $CriticalGB -NoElevate
$collectRc = $LASTEXITCODE
Note ('monitor exited ' + $collectRc)

$seed = @(Get-ChildItem -LiteralPath $OutputPath -Filter 'BigFunnelPostingListMonitor-*.csv' |
          Sort-Object Name -Descending)
if ($seed.Count -eq 0) { Fail 'The collection run wrote no CSV. Nothing to build a baseline from.' }
$rows = @(Import-Csv -LiteralPath $seed[0].FullName)
Note ('collected {0} mailbox(es)' -f $rows.Count)

# --- 3. Check the nominated mailboxes really do stand where they are told to -
# Asserted before the fixture is built, so a renamed or missing seed mailbox
# fails here with a name in the message, rather than as a puzzling Normal row
# in front of an audience.
function Get-NamedRow {
    param($Set, [string]$Name)
    return @($Set | Where-Object { $_.DisplayName -eq $Name })[0]
}

$critRow = Get-NamedRow $rows $CriticalMailbox
$warnRow = Get-NamedRow $rows $WarningMailbox
$emrgRow = Get-NamedRow $rows $EmergingMailbox
foreach ($pair in @(@($CriticalMailbox, $critRow), @($WarningMailbox, $warnRow), @($EmergingMailbox, $emrgRow))) {
    if ($null -eq $pair[1]) { Fail ('Mailbox [{0}] was not collected. Check the name and -Scope.' -f $pair[0]) }
}

$critGB = [double]$critRow.PostingListGB
$warnGB = [double]$warnRow.PostingListGB
$emrgGB = [double]$emrgRow.PostingListGB
Note ('{0,-12} {1,7} GB  nominated Critical' -f $CriticalMailbox, $critGB)
Note ('{0,-12} {1,7} GB  nominated Warning'  -f $WarningMailbox,  $warnGB)
Note ('{0,-12} {1,7} GB  nominated Emerging' -f $EmergingMailbox, $emrgGB)

if ($critGB -lt $CriticalGB) {
    Fail ('{0} holds {1} GB, below -CriticalGB {2}. Lower the threshold or pick a larger mailbox.' -f $CriticalMailbox, $critGB, $CriticalGB)
}
if ($warnGB -lt $WarningGB -or $warnGB -ge $CriticalGB) {
    Fail ('{0} holds {1} GB, which is not between -WarningGB {2} and -CriticalGB {3}.' -f $WarningMailbox, $warnGB, $WarningGB, $CriticalGB)
}
if ($emrgGB -ge $WarningGB) {
    Fail ('{0} holds {1} GB, at or above -WarningGB {2}. Emerging only applies to a mailbox still reading Normal.' -f $EmergingMailbox, $emrgGB, $WarningGB)
}

# --- 4. Build the fixture baseline ------------------------------------------
# The monitor derives the trend window from the run-id stamp in the FILE NAME,
# not from the file's timestamp on disk, so back-dating is a rename. That is
# deliberate on its side: a file time is trivially clobbered by a copy, and a
# run id is not.
$criticalBytes = [int64]($CriticalGB * 1GB)
$currentBytes  = [int64]$emrgRow.PostingListBytes
$perDay        = ($criticalBytes - $currentBytes) / $TargetDaysToCritical
$delta         = [int64]($perDay * ($BaselineAgeHours / 24.0))
$baselineBytes = $currentBytes - $delta

if ($baselineBytes -le 0) {
    Fail ('The gap from {0} GB to critical is too wide to cover in {1} day(s) from a {2}-hour baseline: the earlier reading would have to be negative. Raise -TargetDaysToCritical or widen -BaselineAgeHours.' -f $emrgGB, $TargetDaysToCritical, $BaselineAgeHours)
}

Step ('Back-dating a baseline {0} hours and lowering one cell in it' -f $BaselineAgeHours)
Note ('{0}: {1} GB now, {2} GB in the fixture baseline' -f
      $EmergingMailbox, [math]::Round($currentBytes / 1GB, 3), [math]::Round($baselineBytes / 1GB, 3))
Note ('gives {0} GB/day, projecting critical in about {1} day(s)' -f
      [math]::Round(($perDay / 1GB), 4), $TargetDaysToCritical)

foreach ($r in $rows) {
    if ($r.DisplayName -ne $EmergingMailbox) { continue }
    # PostingListBytes is the only column the baseline join reads. The other
    # two are kept consistent anyway: this file is meant to be readable by a
    # person checking what was changed, and a row whose bytes and GB disagree
    # invites the wrong conclusion about which one was edited.
    $r.PostingListBytes = $baselineBytes
    $r.PostingListGB    = [math]::Round(($baselineBytes / 1GB), 3)
    $r.BigFunnelPostingListTableTotalSize = '{0} B (DEMO FIXTURE - not a measurement)' -f $baselineBytes
}

$stamp        = (Get-Date).AddHours(-1 * $BaselineAgeHours).ToString('yyyyMMdd-HHmmss')
$baselinePath = Join-Path $OutputPath ('BigFunnelPostingListMonitor-{0}-000000.csv' -f $stamp)
$rows | Export-Csv -LiteralPath $baselinePath -NoTypeInformation -Encoding UTF8

# Everything the collection run left behind goes, including its own CSV: it is
# a same-minute duplicate of the baseline and would be preferred over it the
# moment it aged past -TrendBaselineHours.
Get-ChildItem -LiteralPath $OutputPath -File |
    Where-Object { $_.FullName -ne $baselinePath } |
    Remove-Item -Force

# --- 5. Prove it, rather than announce it -----------------------------------
Step 'Verifying: running the monitor exactly as the demo will'
& $MonitorPath -OutputPath $OutputPath -Scope $Scope -Quiet `
               -WarningGB $WarningGB -CriticalGB $CriticalGB -NoElevate
$verifyRc = $LASTEXITCODE

$latest = Join-Path $OutputPath 'latest.csv'
if (-not (Test-Path -LiteralPath $latest)) { Fail 'The verification run published no latest.csv.' }
$check = @(Import-Csv -LiteralPath $latest)
$c = Get-NamedRow $check $CriticalMailbox
$w = Get-NamedRow $check $WarningMailbox
$e = Get-NamedRow $check $EmergingMailbox
if ($null -eq $c -or $null -eq $w -or $null -eq $e) { Fail 'The verification run did not collect all three nominated mailboxes.' }

Write-Host ''
$ok = $true
foreach ($t in @(
    @{ N = $CriticalMailbox; Want = 'Critical'; Got = $c.Status },
    @{ N = $WarningMailbox;  Want = 'Warning';  Got = $w.Status })) {
    $good = ($t.Got -eq $t.Want)
    if (-not $good) { $ok = $false }
    Write-Host ('  {0}  {1,-12} Status {2}' -f $(if ($good) { 'OK  ' } else { 'BAD ' }), $t.N, $t.Got) `
               -ForegroundColor $(if ($good) { 'Green' } else { 'Red' })
}

# Emerging is not a Status - it is Normal plus a projection inside 3 days,
# which is exactly how the monitor decides it. Checked the same way here,
# rather than by looking for a word that never appears in the column.
$eDays = if ([string]::IsNullOrWhiteSpace($e.DaysToCritical)) { $null } else { [double]$e.DaysToCritical }
$eGood = ($e.Status -eq 'Normal' -and $null -ne $eDays -and $eDays -gt 0 -and $eDays -le 3)
if (-not $eGood) { $ok = $false }
Write-Host ('  {0}  {1,-12} Status {2}, {3} GB/day, critical in {4} day(s)' -f
            $(if ($eGood) { 'OK  ' } else { 'BAD ' }), $EmergingMailbox, $e.Status, $e.GrowthGBPerDay, $e.DaysToCritical) `
           -ForegroundColor $(if ($eGood) { 'Green' } else { 'Red' })

$fixture = @(
    'DEMO FIXTURE - this directory is not a monitoring record.',
    ('Prepared ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' by Set-BigFunnelDemoState.ps1'),
    '',
    'REAL, measured live from the estate:',
    ('  ' + $CriticalMailbox + ' at ' + $critGB + ' GB -> Critical against -CriticalGB ' + $CriticalGB),
    ('  ' + $WarningMailbox + ' at ' + $warnGB + ' GB -> Warning against -WarningGB ' + $WarningGB),
    '  Those sizes are genuine. Only the thresholds are scaled: at the',
    '  production 1.7 / 2.0 GB no mailbox on this estate reaches either,',
    '  because the posting list table tops out at about 0.704 GB here.',
    '',
    'FABRICATED, by this script:',
    ('  One cell. ' + $EmergingMailbox + ' PostingListBytes in the back-dated'),
    ('  baseline CSV was set to ' + $baselineBytes + ' (' + [math]::Round($baselineBytes / 1GB, 3) + ' GB).'),
    ('  Its real current size, ' + $emrgGB + ' GB, is untouched and was measured.'),
    '  The difference is what produces the growth rate behind Emerging.',
    '  This estate has been flat since 2026-09-11, so there is no real',
    '  earlier reading to difference against.',
    '',
    'No mailbox was modified. No mail was added. Nothing here needs undoing',
    'beyond deleting this directory.'
)
Set-Content -LiteralPath (Join-Path $OutputPath 'DEMO-FIXTURE.txt') -Value $fixture -Encoding UTF8

Write-Host ''
if (-not $ok) { Fail 'The demo state was not reached. See the rows above.' }

Write-Host '  Ready. The command to run in front of an audience:' -ForegroundColor Green
Write-Host ''
Write-Host ('    .\Monitor-BigFunnelPostingList.ps1 -Scope {0} -WarningGB {1} -CriticalGB {2} -OutputPath "{3}" -ExitNonZeroOnAlert' -f
            $Scope, $WarningGB, $CriticalGB, $OutputPath) -ForegroundColor White
Write-Host ''
Note ('exit code will be 1 (alert). The verification run above exited ' + $verifyRc + '.')
Note ('what is real and what is not: ' + (Join-Path $OutputPath 'DEMO-FIXTURE.txt'))
Note 'Re-run this script before each demo - once a demo run ages past 24 hours it'
Note 'becomes a baseline candidate itself and the Emerging row goes flat again.'
Write-Host ''
