<#
.SYNOPSIS
Drives Monitor-BigFunnelPostingList.ps1 into each of its alert states on a
non-production estate, so an operator can see what every state looks like and
test the alerting around it before any of it is trusted in production.

.DESCRIPTION
The monitor's states are easy to describe and hard to see. A healthy dev estate
never crosses a 2 GB posting list table, so the Critical, Warning and Emerging
paths - the three the alerting actually has to handle - go untested until the
day they fire for real, on production, at which point nobody has seen one
before.

This script closes that gap without touching a single mailbox. It runs the
monitor once as a read-only probe, reads the sizes actually present in the
estate, and then solves for the parameters that put those same real mailboxes
into the state you asked for. Nothing is seeded, no mail is sent, no database
is dismounted and no mailbox is modified. The only writes are to -WorkPath.

Two of the states cannot be produced by parameters alone, because they are
statements about change over time rather than about size: Emerging and
Shrinking both need an earlier reading to difference against. For those the
script writes a synthetic baseline CSV into the run directory - a verbatim copy
of the probe's own detail file with one mailbox's PostingListBytes moved, and a
back-dated timestamp in the file name. It is clearly marked, and a
SYNTHETIC-BASELINE.txt is dropped beside it. Never copy one into a real output
directory; the monitor cannot tell it from a genuine earlier run, which is
exactly why it works here.

Run with no -Scenario to get a report of which states this estate can
demonstrate and why the others cannot.

WHAT THIS IS NOT
The thresholds this script computes are scaled to whatever your dev estate
happens to hold. They are demonstration values and they are not production
values - a dev estate with a 30 MB posting list table produces thresholds three
orders of magnitude below the 1.7 / 2.0 GB defaults. Use this to exercise the
alerting path, not to choose thresholds.

.PARAMETER Scenario
The state to produce. Omit to get the reachability report instead.

  Healthy       every mailbox below the lines. Exit 0, Status OK
  Warning       the largest mailbox at or above the warning line. Exit 1
  Critical      the largest mailbox at or above the critical line. Exit 1
  Emerging      below both lines but projected to cross inside 3 days. Exit 6
  Shrinking     a table that came down, which is what the post-remediation
                cadence exists to confirm. Exit 0
  Inconclusive  nothing in scope big enough to prove the counter works.
                Exit 0, Status MetricInconclusive
  Blind         a real monitoring gap: mailboxes large enough to have allocated
                a posting list table, all reading 0 B. Exit 5
  Partial       a database that was not collected. Exit 2

.PARAMETER Scope
Passed to the monitor. Local (default) or All.

.PARAMETER MonitorPath
The monitor to drive. Defaults to Monitor-BigFunnelPostingList.ps1 beside this
script.

.PARAMETER WorkPath
Where the probe and scenario output directories are created. Defaults to a
BigFunnelScenario folder under the current user's TEMP. The scenario's own
directory is emptied at the start of every run so results are reproducible, and
left in place afterwards so they can be read.

.PARAMETER BaselineHoursAgo
How far back to date the synthetic baseline used by Emerging and Shrinking.
Must exceed the monitor's -TrendBaselineHours (24 by default) or the run will
correctly complain that the window is too narrow to divide by.

.EXAMPLE
.\Invoke-BigFunnelScenario.ps1

Runs the probe and reports which scenarios this estate can demonstrate.

.EXAMPLE
.\Invoke-BigFunnelScenario.ps1 -Scenario Critical

Solves thresholds so the largest posting list table in scope reads Critical,
runs the monitor, and prints the log, the summary and a pass/fail check of the
exit code and summary fields against what the scenario promised.

.NOTES
Read-only against Exchange. Requires the same RBAC the monitor requires, and
must be run where the monitor can run - the Exchange Management Shell, or a
session where the Exchange snap-in can be loaded.

Not for production. The point of the exercise is to see the states somewhere
the noise does not matter.
#>

[CmdletBinding()]
param(
    [ValidateSet('Healthy', 'Warning', 'Critical', 'Emerging', 'Shrinking',
                 'Inconclusive', 'Blind', 'Partial')]
    [string]$Scenario,

    [ValidateSet('Local', 'All')]
    [string]$Scope = 'Local',

    [string]$MonitorPath,

    [string]$WorkPath = (Join-Path $env:TEMP 'BigFunnelScenario'),

    [ValidateRange(2, 720)]
    [int]$BaselineHoursAgo = 26
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Full path rather than a bare name. PATHEXT on some workstations does not
# include .EXE, and a scenario harness failing on the host's environment
# instead of on the estate is a confusing way to start.
$script:Ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

#region helpers ---------------------------------------------------------------

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('== ' + $Text) -ForegroundColor Cyan
}

function Get-Prop {
    # Import-Csv rows under StrictMode throw on a column that is not there.
    # Baselines and detail files written by different versions of the monitor do
    # not all carry the same columns, so every read goes through this.
    param($Row, [string]$Name)
    if ($null -eq $Row) { return $null }
    $p = $Row.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-Int64Value {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $i = New-Object System.Int64
    if ([int64]::TryParse($s, [ref]$i)) { return $i }
    $d = New-Object System.Double
    if ([double]::TryParse($s, [ref]$d)) { return [int64]$d }
    return $null
}

function Resolve-ThresholdGB {
    # Turns a byte count into a -WarningGB / -CriticalGB value.
    #
    # The monitor converts the other way with [int64][math]::Floor($gb * 1GB),
    # so rounding here and hoping is how a scenario lands one byte on the wrong
    # side of its own threshold and quietly demonstrates the state next door.
    # The conversion is done the monitor's way and then stepped by the smallest
    # representable amount until the relation actually holds.
    #
    # AtMost  - the monitor's byte value will be at or below $Bytes, so a
    #           mailbox of exactly $Bytes is at or above the line.
    # AtLeast - the monitor's byte value will be at or above $Bytes.
    #
    # Returns $null where no value inside the monitor's own
    # ValidateRange(0.001, 1024) satisfies the relation. 0.001 GB is a shade
    # over 1 MB, so an estate whose largest table is under that cannot express
    # a threshold below it at all - which is a real answer, not a failure.
    param(
        [Parameter(Mandatory = $true)][int64]$Bytes,
        [Parameter(Mandatory = $true)][ValidateSet('AtLeast', 'AtMost')][string]$Mode
    )

    if ($Bytes -lt 0) { $Bytes = [int64]0 }
    $g = [math]::Round($Bytes / 1GB, 6)

    if ($Mode -eq 'AtLeast') { if ($g -lt 0.001) { $g = 0.001 } }
    else                     { if ($g -gt 1024)  { $g = 1024.0 } }

    for ($i = 0; $i -le 64; $i++) {
        if ($g -ge 0.001 -and $g -le 1024) {
            $b = [int64][math]::Floor($g * 1GB)
            if ($Mode -eq 'AtLeast' -and $b -ge $Bytes) { return $g }
            if ($Mode -eq 'AtMost'  -and $b -le $Bytes) { return $g }
        }
        if ($Mode -eq 'AtLeast') { $g = [math]::Round($g + 0.000001, 6) }
        else                     { $g = [math]::Round($g - 0.000001, 6) }
    }
    return $null
}

function Format-Invariant {
    # A double rendered under a culture that uses a comma for the decimal
    # separator arrives at the child process as "-WarningGB 0,034", which the
    # command line splits into two arguments and the binder rejects. Formatting
    # is pinned rather than left to the ambient culture.
    param([double]$Value)
    return $Value.ToString('0.##########', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-MonitorArgs {
    param([hashtable]$Settings, [string]$OutDir)

    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add('-OutputPath'); $argv.Add($OutDir)
    foreach ($k in @($Settings.Keys | Sort-Object)) {
        $v = $Settings[$k]
        if ($v -is [bool]) {
            if ($v) { $argv.Add('-' + $k) }
            continue
        }
        $argv.Add('-' + $k)
        if ($v -is [double]) { $argv.Add((Format-Invariant $v)) }
        else                 { $argv.Add([string]$v) }
    }
    return $argv
}

function Invoke-Monitor {
    # Always -File, never -Command. Measured on this build: through -File the
    # monitor's exit code arrives intact, and through -Command a 7 comes back as
    # a 1. The exit code is the whole contract here, so -File it is - which is
    # also why no scenario below passes more than one -Databases value, because
    # -File cannot carry a multi-element string array either.
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][hashtable]$Settings
    )

    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add('-NoProfile')
    $argv.Add('-ExecutionPolicy'); $argv.Add('Bypass')
    $argv.Add('-File');            $argv.Add($script:MonitorResolved)
    foreach ($a in (ConvertTo-MonitorArgs -Settings $Settings -OutDir $OutDir)) { $argv.Add($a) }

    & $script:Ps $argv.ToArray() | Out-Null
    return $LASTEXITCODE
}

function Get-EquivalentCommand {
    param([hashtable]$Settings, [string]$OutDir)
    $parts = @('.\' + (Split-Path -Leaf $script:MonitorResolved))
    foreach ($a in (ConvertTo-MonitorArgs -Settings $Settings -OutDir $OutDir)) {
        if ($a -match '\s') { $parts += ('"' + $a + '"') } else { $parts += $a }
    }
    return ($parts -join ' ')
}

function New-CleanDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Format-MB {
    param($Bytes)
    $b = Get-Int64Value $Bytes
    if ($null -eq $b) { return 'n/a' }
    return ('{0:N1} MB' -f ($b / 1MB))
}

#endregion

#region locate the monitor ----------------------------------------------------

$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($MonitorPath)) {
    $MonitorPath = Join-Path $here 'Monitor-BigFunnelPostingList.ps1'
}
if (-not (Test-Path -LiteralPath $MonitorPath)) {
    throw ("Monitor not found at [{0}]. Pass -MonitorPath." -f $MonitorPath)
}
$script:MonitorResolved = (Resolve-Path -LiteralPath $MonitorPath).ProviderPath

Write-Host ''
Write-Host 'BigFunnel posting list monitor - scenario harness' -ForegroundColor White
Write-Host ('Monitor : ' + $script:MonitorResolved)
Write-Host ('Work    : ' + $WorkPath)
Write-Host 'Read-only against Exchange. No mailbox, database or index is modified.'
Write-Host 'Thresholds below are scaled to this estate. They are not production values.' -ForegroundColor Yellow

#endregion

#region probe -----------------------------------------------------------------

Write-Head 'Probe run - reading the estate as it is'

$probeDir = Join-Path $WorkPath '_probe'
New-CleanDirectory -Path $probeDir

# Thresholds parked at the top of the allowed range so the probe cannot alert on
# anything and cannot be mistaken for a real assessment. It exists to produce a
# detail CSV, which is also the honest source for any synthetic baseline below.
$probeSettings = @{
    Scope          = $Scope
    WarningGB      = 1023.0
    CriticalGB     = 1024.0
    MaxAlertDetail = 1
}
$probeExit = Invoke-Monitor -OutDir $probeDir -Settings $probeSettings
Write-Host ('  monitor exit code {0}' -f $probeExit)

$probeCsv = Join-Path $probeDir 'latest.csv'
if (-not (Test-Path -LiteralPath $probeCsv)) {
    Write-Host ''
    Write-Host 'The probe run produced no detail file, so there is nothing to solve against.' -ForegroundColor Red
    $probeLog = @(Get-ChildItem -LiteralPath $probeDir -Filter '*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime)
    if ($probeLog.Count -gt 0) {
        Write-Host ''
        Get-Content -LiteralPath $probeLog[-1].FullName
    }
    exit 3
}

$rows = @(Import-Csv -LiteralPath $probeCsv)
if ($rows.Count -eq 0) { throw 'The probe collected no mailboxes. Check -Scope and RBAC.' }

Write-Host ('  {0} mailbox(es) collected' -f $rows.Count)

# A probe that exited 2 collected some databases and dropped others, and every
# figure below is therefore drawn from a slice of the estate. Saying so is not
# pedantry: the reachability report reads as a statement about the whole estate,
# and the most common way to land here is running -Scope All from a scheduled
# task, where the monitor's Add-PSSnapin fallback binds the store in-process and
# cannot reach a database mounted on another node. That drops every remote
# database and still produces a plausible-looking report.
if ($probeExit -eq 2) {
    $probeSummaryPath = Join-Path $probeDir 'latest-summary.json'
    $dropped = ''
    if (Test-Path -LiteralPath $probeSummaryPath) {
        $probeSummary = (Get-Content -LiteralPath $probeSummaryPath -Raw) | ConvertFrom-Json
        $dropped = [string](Get-Prop $probeSummary 'FailedDatabases')
    }
    Write-Host ''
    Write-Host '  The probe returned Partial. Everything below describes only the' -ForegroundColor Yellow
    Write-Host '  databases it managed to collect, not the estate.' -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($dropped)) {
        Write-Host ('  Not collected: {0}' -f $dropped) -ForegroundColor Yellow
    }
    if ($Scope -eq 'All') {
        Write-Host '  -Scope All reaches databases on other nodes only from an Exchange' -ForegroundColor Yellow
        Write-Host '  Management Shell. Run this from EMS, or use -Scope Local per node.' -ForegroundColor Yellow
    }
}

# The evidence bar the monitor applies when nothing overrides it, so the
# scenarios below can tell whether this estate reaches a metric verdict on its
# own or has to be pushed into it.
#
# Taken from the monitor's own parameter default rather than hardcoded here, and
# deliberately NOT from the probe's summary: the summary reports the bar that was
# in force, which on an estate with populated tables is the observed allocation
# point, not the configured default. The Inconclusive and Blind runs are scoped
# to a database with nothing populated, where the configured default is what
# applies - so that is the number to reason about.
$defaultEvidenceMB = 64
$monitorText = Get-Content -LiteralPath $script:MonitorResolved -Raw
if ($monitorText -match '\$AllocationEvidenceMB\s*=\s*(\d+)') {
    $defaultEvidenceMB = [int]$Matches[1]
}
$defaultEvidenceBytes = [int64]$defaultEvidenceMB * 1MB

#endregion

#region what the estate can support -------------------------------------------

# One pass over the probe rows. Everything the solver and the reachability
# report need is derived here, so the CSV is read once and interpreted once.
$maxPl    = [int64]0
$topRow   = $null
$dbFacts  = @{}
$dbOrder  = New-Object System.Collections.Generic.List[string]

foreach ($r in $rows) {
    $db = [string](Get-Prop $r 'Database')
    if ([string]::IsNullOrWhiteSpace($db)) { $db = '(unknown)' }
    if (-not $dbFacts.ContainsKey($db)) {
        $dbOrder.Add($db)
        $dbFacts[$db] = [pscustomobject]@{
            Name = $db; Rows = 0; MaxPl = [int64]0; ZeroAboveMB = 0
            IndexedZero = 0; MaxZeroContent = [int64]0
        }
    }
    $f = $dbFacts[$db]
    $f.Rows++

    $pl      = Get-Int64Value (Get-Prop $r 'PostingListBytes')
    $content = Get-Int64Value (Get-Prop $r 'TotalItemBytes')
    $indexed = Get-Int64Value (Get-Prop $r 'BigFunnelIndexedCount')

    if ($null -ne $pl -and $pl -gt 0) {
        if ($pl -gt $f.MaxPl) { $f.MaxPl = $pl }
        if ($pl -gt $maxPl)   { $maxPl = $pl; $topRow = $r }
    }
    elseif ($null -ne $indexed -and $indexed -gt 0) {
        # An indexed mailbox reading 0 B. Whether that is expected or a fault is
        # the whole question -AllocationEvidenceMB exists to answer, and the
        # answer turns on content size, so both counts are kept.
        $f.IndexedZero++
        if ($null -ne $content) {
            if ($content -ge 1MB) { $f.ZeroAboveMB++ }
            if ($content -gt $f.MaxZeroContent) { $f.MaxZeroContent = $content }
        }
    }
}

$blankDbs = @($dbOrder | Where-Object { $dbFacts[$_].MaxPl -eq 0 -and $dbFacts[$_].IndexedZero -gt 0 })
$blindDbs = @($dbOrder | Where-Object { $dbFacts[$_].MaxPl -eq 0 -and $dbFacts[$_].ZeroAboveMB -gt 0 })

# Prefer a database that reaches the state on its own at the shipped bar, so the
# run shows the wording an operator would actually get in production. Only where
# no database does that is the bar moved to force it, and the run says which of
# the two happened.
$natBlank = @($blankDbs | Where-Object { $dbFacts[$_].MaxZeroContent -lt $defaultEvidenceBytes })
$natBlind = @($blindDbs | Where-Object { $dbFacts[$_].MaxZeroContent -ge $defaultEvidenceBytes })

# Can a threshold be placed at or below the largest table? Below roughly 1 MB
# the monitor's own ValidateRange makes that impossible, and no amount of
# solving changes it.
$canCross = ($maxPl -gt 0 -and $null -ne (Resolve-ThresholdGB -Bytes $maxPl -Mode 'AtMost'))

$reasons = @{
    'Healthy'      = @{ Ok = ($rows.Count -gt 0); Why = 'needs at least one mailbox in scope' }
    'Warning'      = @{ Ok = $canCross;           Why = 'needs a populated posting list table of at least ~1 MB, so a threshold can be placed at or below it' }
    'Critical'     = @{ Ok = $canCross;           Why = 'needs a populated posting list table of at least ~1 MB, so a threshold can be placed at or below it' }
    'Emerging'     = @{ Ok = $canCross;           Why = 'needs a populated posting list table of at least ~1 MB to project a crossing date from' }
    'Shrinking'    = @{ Ok = ($maxPl -gt 0);      Why = 'needs at least one populated posting list table to show coming back down' }
    'Inconclusive' = @{ Ok = ($blankDbs.Count -gt 0); Why = 'needs a database where no mailbox has allocated a posting list table' }
    'Blind'        = @{ Ok = ($blindDbs.Count -gt 0); Why = 'needs a database where no mailbox has allocated a posting list table and at least one indexed mailbox holds more than 1 MB' }
    'Partial'      = @{ Ok = ($dbOrder.Count -ge 2);  Why = 'needs two or more databases in scope, so the run budget can collect one and drop another' }
}

# Worth saying out loud which of the two metric verdicts this estate arrives at
# by itself. One of them is what the estate genuinely reports; the other has to
# be induced by moving the bar, and an operator should know which they are
# looking at before they read anything into it.
$notes = @{}
if ($blankDbs.Count -gt 0) {
    if ($natBlank.Count -gt 0) { $notes['Inconclusive'] = 'at the shipped bar, on [' + $natBlank[0] + ']' }
    else { $notes['Inconclusive'] = 'only by raising the evidence bar; at the shipped bar this estate reads Blind' }
}
if ($blindDbs.Count -gt 0) {
    if ($natBlind.Count -gt 0) { $notes['Blind'] = 'at the shipped bar, on [' + $natBlind[0] + '] - a real gap' }
    else { $notes['Blind'] = 'only by lowering the evidence bar; nothing here clears ' + $defaultEvidenceMB + ' MB' }
}

if ([string]::IsNullOrWhiteSpace($Scenario)) {
    Write-Head 'Estate'
    Write-Host ('  largest posting list table : {0}' -f (Format-MB $maxPl))
    if ($null -ne $topRow) {
        Write-Host ('  on mailbox                 : {0} [{1}]' -f
            [string](Get-Prop $topRow 'DisplayName'), [string](Get-Prop $topRow 'Database'))
    }
    Write-Host ('  allocation evidence bar    : {0} MB (the monitor default in force)' -f $defaultEvidenceMB)
    Write-Host ('  databases collected        : {0}' -f $dbOrder.Count)
    foreach ($d in $dbOrder) {
        $f = $dbFacts[$d]
        Write-Host ('    {0,-32} {1,4} mailbox(es), largest table {2}, {3} indexed reading 0 B (largest holds {4})' -f
            $f.Name, $f.Rows, (Format-MB $f.MaxPl), $f.IndexedZero, (Format-MB $f.MaxZeroContent))
    }

    Write-Head 'Scenarios this estate can demonstrate'
    foreach ($k in @('Healthy', 'Warning', 'Critical', 'Emerging', 'Shrinking',
                     'Inconclusive', 'Blind', 'Partial')) {
        if ($reasons[$k].Ok) {
            if ($notes.ContainsKey($k)) {
                Write-Host ('  [ yes ] {0} - {1}' -f $k, $notes[$k]) -ForegroundColor Green
            }
            else {
                Write-Host ('  [ yes ] {0}' -f $k) -ForegroundColor Green
            }
        }
        else {
            Write-Host ('  [ no  ] {0} - {1}' -f $k, $reasons[$k].Why) -ForegroundColor DarkYellow
        }
    }
    Write-Host ''
    Write-Host ('Run one with:  .\{0} -Scenario Critical' -f (Split-Path -Leaf $PSCommandPath))
    Write-Host ''
    exit 0
}

if (-not $reasons[$Scenario].Ok) {
    Write-Host ''
    Write-Host ('Scenario {0} cannot be produced on this estate: {1}.' -f $Scenario, $reasons[$Scenario].Why) -ForegroundColor Red
    Write-Host 'Run without -Scenario for the full reachability report.'
    exit 1
}

#endregion

#region solve -----------------------------------------------------------------

Write-Head ('Solving for scenario: ' + $Scenario)

$settings  = @{ Scope = $Scope; ExitNonZeroOnAlert = $true }
$expect    = New-Object System.Collections.Generic.List[object]
$why       = ''
$synthetic = $null

# Assertions are (field, operator, value) against latest-summary.json, plus the
# process exit code. Declared with the scenario rather than checked by eye, so a
# run that quietly produced the state next door says so.
function Add-Expectation {
    param([string]$Field, [ValidateSet('eq', 'ge')][string]$Op, $Value)
    $expect.Add([pscustomobject]@{ Field = $Field; Op = $Op; Value = $Value })
}

switch ($Scenario) {

    'Healthy' {
        $settings['WarningGB']  = Resolve-ThresholdGB -Bytes ([int64]($maxPl * 1.5) + 1MB) -Mode 'AtLeast'
        $settings['CriticalGB'] = Resolve-ThresholdGB -Bytes ([int64]($maxPl * 2.0) + 2MB) -Mode 'AtLeast'
        $why = 'Both lines placed above the largest table in scope, so every mailbox reads Normal.'
        $expectedExit = 0
        Add-Expectation 'Status'   'eq' 'OK'
        Add-Expectation 'Critical' 'eq' 0
        Add-Expectation 'Warning'  'eq' 0
    }

    'Warning' {
        $settings['WarningGB']  = Resolve-ThresholdGB -Bytes $maxPl -Mode 'AtMost'
        $settings['CriticalGB'] = Resolve-ThresholdGB -Bytes ($maxPl + 1MB) -Mode 'AtLeast'
        $why = ('Warning line placed at or below the largest table ({0}), critical line above it.' -f (Format-MB $maxPl))
        $expectedExit = 1
        Add-Expectation 'Warning' 'ge' 1
    }

    'Critical' {
        $settings['CriticalGB'] = Resolve-ThresholdGB -Bytes $maxPl -Mode 'AtMost'
        $settings['WarningGB']  = Resolve-ThresholdGB -Bytes ([int64][math]::Floor($maxPl * 0.9)) -Mode 'AtMost'
        $why = ('Critical line placed at or below the largest table ({0}).' -f (Format-MB $maxPl))
        $expectedExit = 1
        Add-Expectation 'Critical' 'ge' 1
    }

    'Emerging' {
        # Emerging is not a size, it is a rate: Status still Normal, but
        # DaysToCritical at or under 3. That needs an earlier reading, so this
        # is the first of the two scenarios that writes a synthetic baseline.
        #
        # The delta has to clear the monitor's own 1 MB trend tolerance or the
        # row reads Flat and no rate is derived at all.
        $delta = [int64][math]::Max([double](2MB), [math]::Floor($maxPl * 0.25))
        if ($delta -ge $maxPl) { $delta = [int64][math]::Floor($maxPl / 2) }
        $perDay = ($delta / [double]$BaselineHoursAgo) * 24.0

        # Warning above current so the row stays Normal; critical two days of
        # growth above current so the projection lands inside the 3-day window.
        $settings['WarningGB']  = Resolve-ThresholdGB -Bytes ([int64][math]::Ceiling($maxPl + (0.5 * $perDay))) -Mode 'AtLeast'
        $settings['CriticalGB'] = Resolve-ThresholdGB -Bytes ([int64][math]::Floor($maxPl + (2.0 * $perDay)))   -Mode 'AtMost'
        $synthetic = @{ Guid = [string](Get-Prop $topRow 'MailboxGuid'); Bytes = ($maxPl - $delta) }
        $why = ('Largest table left below both lines, and given a synthetic earlier reading {0} smaller over {1} hours so it projects to cross in about 2 days.' -f
                (Format-MB $delta), $BaselineHoursAgo)
        $expectedExit = 6
        Add-Expectation 'Emerging' 'ge' 1
    }

    'Shrinking' {
        $delta = [int64][math]::Max([double](2MB), [math]::Floor($maxPl * 0.25))
        $settings['WarningGB']  = Resolve-ThresholdGB -Bytes ([int64]($maxPl * 1.5) + 1MB) -Mode 'AtLeast'
        $settings['CriticalGB'] = Resolve-ThresholdGB -Bytes ([int64]($maxPl * 2.0) + 2MB) -Mode 'AtLeast'
        $synthetic = @{ Guid = [string](Get-Prop $topRow 'MailboxGuid'); Bytes = ($maxPl + $delta) }
        $why = ('Largest table given a synthetic earlier reading {0} larger, so this run sees it coming down. Both lines are above it, so the run is otherwise clean.' -f (Format-MB $delta))
        $expectedExit = 0
        Add-Expectation 'Shrinking' 'ge' 1
    }

    'Inconclusive' {
        # Scoped to a database where nothing has allocated a table and nothing
        # is big enough to say whether that is a fault. Where the estate is
        # already like that at the shipped bar the bar is left alone, because
        # then the run prints the message production would print. Only an estate
        # holding mailboxes above the bar needs it raised out of their way.
        $settings.Remove('Scope')
        $settings['WarningGB']  = 1023.0
        $settings['CriticalGB'] = 1024.0
        if ($natBlank.Count -gt 0) {
            $settings['Databases'] = $natBlank[0]
            $why = ('Scoped to [{0}], where no mailbox has allocated a posting list table and the largest indexed mailbox reading 0 B holds {1} - under the {2} MB bar, so this is the verdict at the shipped default with nothing overridden.' -f
                    $natBlank[0], (Format-MB $dbFacts[$natBlank[0]].MaxZeroContent), $defaultEvidenceMB)
        }
        else {
            $settings['Databases']            = $blankDbs[0]
            $settings['AllocationEvidenceMB'] = 1048576
            $why = ('Scoped to [{0}]. Its indexed mailboxes are above the {1} MB bar, so the bar is raised to 1 TB to put them out of reach - at the shipped default this database would read Blind, not Inconclusive.' -f
                    $blankDbs[0], $defaultEvidenceMB)
        }
        $expectedExit = 0
        Add-Expectation 'Status'           'eq' 'MetricInconclusive'
        Add-Expectation 'MetricValidation' 'eq' 'Inconclusive'
    }

    'Blind' {
        # The genuine monitoring gap: mailboxes unarguably large enough to have
        # allocated a table, all reading 0 B. Same preference as above - take it
        # at the shipped bar if the estate offers it, and only drop the bar when
        # nothing in scope is large enough to clear it.
        $settings.Remove('Scope')
        $settings['WarningGB']  = 1023.0
        $settings['CriticalGB'] = 1024.0
        if ($natBlind.Count -gt 0) {
            $settings['Databases'] = $natBlind[0]
            $why = ('Scoped to [{0}], where no mailbox has allocated a posting list table and the largest indexed mailbox reading 0 B holds {1} - over the {2} MB bar, so this is a real monitoring gap at the shipped default with nothing overridden.' -f
                    $natBlind[0], (Format-MB $dbFacts[$natBlind[0]].MaxZeroContent), $defaultEvidenceMB)
        }
        else {
            $settings['Databases']            = $blindDbs[0]
            $settings['AllocationEvidenceMB'] = 1
            $why = ('Scoped to [{0}]. Nothing in it clears the {1} MB bar, so the bar is dropped to 1 MB to make its mailboxes count as evidence - the same readings as the Inconclusive run, opposite verdict, which is the point worth showing.' -f
                    $blindDbs[0], $defaultEvidenceMB)
        }
        $expectedExit = 5
        Add-Expectation 'Status'           'eq' 'MetricUnavailable'
        Add-Expectation 'MetricValidation' 'eq' 'Blind'
    }

    'Partial' {
        # A run budget too small to finish. The budget is checked before each
        # database, so the first is collected and the rest are dropped - a
        # genuine partial rather than a total failure.
        #
        # The other way to reach exit 2 is to name a database that does not
        # exist, which is closer to what a customer actually hits. It is not
        # used here because it needs two -Databases values and powershell.exe
        # -File cannot carry an array; the equivalent command is printed at the
        # end so it can be run by hand from the Exchange Management Shell.
        $settings['MaxRunMinutes'] = 0.001
        $settings['WarningGB']     = 1023.0
        $settings['CriticalGB']    = 1024.0
        $why = 'Run budget set to 60 ms, so the first database is collected and the rest are dropped.'
        $expectedExit = 2
        Add-Expectation 'Status' 'eq' 'Partial'
    }
}

foreach ($k in @('WarningGB', 'CriticalGB')) {
    if ($settings.ContainsKey($k) -and $null -eq $settings[$k]) {
        throw ("Could not express {0} inside the monitor's ValidateRange(0.001, 1024) for this estate. The largest posting list table is {1}." -f $k, (Format-MB $maxPl))
    }
}
if ($settings.ContainsKey('WarningGB') -and $settings.ContainsKey('CriticalGB') -and
    $settings['WarningGB'] -ge $settings['CriticalGB']) {
    throw ("Solved thresholds collapsed onto each other (warning {0} GB, critical {1} GB). The estate's sizes are too close together to separate the two lines at this precision." -f
        $settings['WarningGB'], $settings['CriticalGB'])
}

Write-Host ('  ' + $why)

#endregion

#region run -------------------------------------------------------------------

$runDir = Join-Path $WorkPath $Scenario
New-CleanDirectory -Path $runDir

if ($null -ne $synthetic) {
    # A verbatim copy of the probe's own detail rows with one mailbox's
    # PostingListBytes moved, named with a back-dated run stamp so the monitor's
    # baseline scan - which reads the timestamp out of the file name, not off
    # the file - treats it as a run from $BaselineHoursAgo ago.
    $stamp    = (Get-Date).AddHours(0 - $BaselineHoursAgo).ToString('yyyyMMdd-HHmmss')
    $basePath = Join-Path $runDir ('BigFunnelPostingListMonitor-{0}.csv' -f $stamp)

    $moved = 0
    foreach ($r in $rows) {
        if ([string](Get-Prop $r 'MailboxGuid') -eq $synthetic.Guid) {
            $r.PostingListBytes = [string]$synthetic.Bytes
            $moved++
        }
    }
    if ($moved -eq 0) { throw 'Could not find the target mailbox in the probe detail to build a baseline from.' }

    $rows | Export-Csv -LiteralPath $basePath -NoTypeInformation -Encoding UTF8

    $note = @(
        'SYNTHETIC BASELINE - NOT A REAL RUN'
        ''
        ('Written by Invoke-BigFunnelScenario.ps1 for the {0} scenario.' -f $Scenario)
        ''
        ('The file BigFunnelPostingListMonitor-{0}.csv in this directory is a copy' -f $stamp)
        'of a real probe run with one mailbox''s PostingListBytes changed, and a'
        'back-dated timestamp in its name. It exists so the monitor has an earlier'
        'reading to difference against, because growth and shrink are statements'
        'about change over time and cannot be produced by parameters alone.'
        ''
        ('  mailbox GUID   : {0}' -f $synthetic.Guid)
        ('  value used     : {0} bytes' -f $synthetic.Bytes)
        ('  actual reading : {0} bytes' -f $maxPl)
        ('  dated          : {0} hours before this run' -f $BaselineHoursAgo)
        ''
        'Do not copy this file into a real monitor output directory. The monitor'
        'cannot tell it from a genuine earlier run - which is exactly why it works'
        'here, and exactly why it would corrupt a real trend.'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $runDir 'SYNTHETIC-BASELINE.txt') -Value $note -Encoding UTF8

    Write-Host ('  synthetic baseline written, dated {0} hours back' -f $BaselineHoursAgo) -ForegroundColor Yellow
}

Write-Head 'Monitor run'
Write-Host ('  ' + (Get-EquivalentCommand -Settings $settings -OutDir $runDir)) -ForegroundColor Gray
if ($null -ne $synthetic) {
    # Worth saying plainly: this command on its own does not reproduce the
    # result. Half of what produces it is the back-dated CSV sitting in the
    # output directory, and someone copying the line into a clean directory
    # would get a flat run and reasonably conclude the scenario was wrong.
    Write-Host '  (only reproduces the result while the synthetic baseline is in that directory)' -ForegroundColor Gray
}
Write-Host ''

$actualExit = Invoke-Monitor -OutDir $runDir -Settings $settings

$logFiles = @(Get-ChildItem -LiteralPath $runDir -Filter '*.log' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime)
if ($logFiles.Count -gt 0) { Get-Content -LiteralPath $logFiles[-1].FullName }

$summaryPath = Join-Path $runDir 'latest-summary.json'
$summary     = $null
if (Test-Path -LiteralPath $summaryPath) {
    Write-Head 'latest-summary.json'
    Get-Content -LiteralPath $summaryPath
    # ConvertFrom-Json is available on 5.1 and the file is small; read it back
    # rather than re-deriving anything from the log.
    $summary = (Get-Content -LiteralPath $summaryPath -Raw) | ConvertFrom-Json
}

#endregion

#region verify ----------------------------------------------------------------

Write-Head 'Did it produce what the scenario promised?'

$failures = New-Object System.Collections.Generic.List[string]

if ($actualExit -eq $expectedExit) {
    Write-Host ('  [ ok ] exit code {0}' -f $actualExit) -ForegroundColor Green
}
else {
    Write-Host ('  [FAIL] exit code {0}, expected {1}' -f $actualExit, $expectedExit) -ForegroundColor Red
    $failures.Add(('exit code {0} not {1}' -f $actualExit, $expectedExit))
}

foreach ($e in $expect) {
    $actual = Get-Prop $summary $e.Field
    $ok = $false
    if ($null -ne $actual) {
        if ($e.Op -eq 'eq') { $ok = ([string]$actual -eq [string]$e.Value) }
        else {
            $a = Get-Int64Value $actual
            $ok = ($null -ne $a -and $a -ge [int64]$e.Value)
        }
    }
    $shown = if ($null -eq $actual) { '(absent)' } else { [string]$actual }
    if ($ok) {
        Write-Host ('  [ ok ] {0} = {1}' -f $e.Field, $shown) -ForegroundColor Green
    }
    else {
        Write-Host ('  [FAIL] {0} = {1}, expected {2} {3}' -f $e.Field, $shown, $e.Op, $e.Value) -ForegroundColor Red
        $failures.Add(('{0} was {1}' -f $e.Field, $shown))
    }
}

Write-Host ''
Write-Host ('Artifacts: ' + $runDir)

if ($Scenario -eq 'Partial') {
    Write-Host ''
    Write-Host 'The realistic variant of this state - a database that does not exist - needs' -ForegroundColor Gray
    Write-Host 'an array argument, which powershell.exe -File cannot pass. Run it by hand from' -ForegroundColor Gray
    Write-Host 'the Exchange Management Shell instead:' -ForegroundColor Gray
    Write-Host ('  .\{0} -Databases {1},NoSuchDatabase -OutputPath "{2}" -ExitNonZeroOnAlert' -f
        (Split-Path -Leaf $script:MonitorResolved), $dbOrder[0], $runDir) -ForegroundColor Gray
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host ('Scenario {0} did not reproduce cleanly: {1}.' -f $Scenario, ($failures -join '; ')) -ForegroundColor Red
    Write-Host 'The log above is the evidence. An estate that has changed since the probe ran' -ForegroundColor Red
    Write-Host 'is the usual cause; re-run to re-solve against current readings.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('Scenario {0} reproduced.' -f $Scenario) -ForegroundColor Green
exit 0

#endregion
