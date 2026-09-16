# Exercises Monitor-BigFunnelPostingList.ps1 against the mock Exchange module.
# Each case runs in its own powershell.exe via -File, the way a scheduled task
# invokes it, so process exit codes are real rather than inferred.

$ErrorActionPreference = 'Continue'
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD'

# Resolved from this script's own location, so the suite runs from wherever the
# repository was cloned. The monitor sits one level up, beside the runbook.
$root    = Split-Path -Parent $PSScriptRoot
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$monitor = Join-Path $root 'Monitor-BigFunnelPostingList.ps1'

# Scratch output. The cases below create 37 output directories, and a test run
# must not leave any of them in the working tree.
$scratch = Join-Path $env:TEMP 'BigFunnelMonitorTests'
if (-not (Test-Path -LiteralPath $scratch)) { New-Item -ItemType Directory -Path $scratch -Force | Out-Null }

$pass    = 0
$fail    = 0

if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME = 'EXCH-01' }

# Command auto-loading resolves Get-MailboxDatabase and Get-MailboxStatistics
# from the mock module, so the monitor runs as the top-level -File script and
# its exit codes are the process exit codes.
$env:PSModulePath = (Join-Path $PSScriptRoot '_mockmodules') + ';' + $env:PSModulePath

# The same mechanism shadows the real ScheduledTasks module, and here it is
# load-bearing rather than convenient: without it the task cases would create
# real scheduled tasks on whatever machine ran the suite. Verified rather than
# assumed - in a child powershell.exe with no explicit import, Get-ScheduledTask
# resolves to a Function out of _mockmodules, not to the system cmdlet.
#
# The store is a file because the monitor runs as a child process: the suite
# registers in one powershell.exe and asserts in another. Scoped to the scratch
# directory so a run cannot inherit a previous run's tasks.
$env:MOCK_TASKSTORE = Join-Path $scratch 'mock-scheduledtasks.json'
Remove-Item -LiteralPath $env:MOCK_TASKSTORE -Force -ErrorAction SilentlyContinue

function Reset-TaskStore {
    Remove-Item -LiteralPath $env:MOCK_TASKSTORE -Force -ErrorAction SilentlyContinue
    # Left over from a case that injected one and failed before its cleanup.
    foreach ($v in 'MOCK_TASK_DENY', 'MOCK_TASK_LOGONTYPE', 'MOCK_TASK_RUNLEVEL', 'MOCK_TASK_STICKY') {
        Remove-Item -Path ('env:' + $v) -ErrorAction SilentlyContinue
    }
}

function Get-MockTask {
    # Reads the store directly rather than through the mock module, so an
    # assertion about what was registered cannot be satisfied by the same code
    # path that registered it.
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $env:MOCK_TASKSTORE)) { return $null }
    $raw = Get-Content -LiteralPath $env:MOCK_TASKSTORE -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $obj = $raw | ConvertFrom-Json
    $prop = $obj.PSObject.Properties | Where-Object { $_.Name -eq $Name }
    if (-not $prop) { return $null }
    return $prop.Value
}

function Invoke-Monitor {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$Extra = '',
        [hashtable]$WithEnv = @{},
        # The monitor relaunches itself elevated whenever it is not already
        # administrator. This harness usually is not, so without -NoElevate
        # every single case would raise a consent prompt and then sit on
        # Start-Process -Wait until somebody answered it. The elevation gate has
        # its own cases below, which pass -TestElevation to reach it on purpose.
        [switch]$TestElevation
    )

    foreach ($k in $WithEnv.Keys) { Set-Item -Path ('env:' + $k) -Value $WithEnv[$k] }

    $noElev = if ($TestElevation) { '' } else { '-NoElevate ' }

    # Windows tokenizes on double quotes; single quotes would arrive literally.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}" {2}{3}' -f $monitor, $OutputPath, $noElev, $Extra

    $so = Join-Path $env:TEMP 'bf-test-out.txt'
    $se = Join-Path $env:TEMP 'bf-test-err.txt'
    $p = Start-Process -FilePath $psExe -PassThru -Wait -NoNewWindow `
         -ArgumentList $argLine -RedirectStandardOutput $so -RedirectStandardError $se

    foreach ($k in $WithEnv.Keys) { Remove-Item -Path ('env:' + $k) -ErrorAction SilentlyContinue }
    return $p.ExitCode
}

function Invoke-MonitorPassThru {
    # Invoke-Monitor redirects the child's stdout to a file and returns an exit
    # code, which is exactly the string round trip -PassThru exists to avoid.
    # Routed through Export-Clixml instead: it preserves the numeric types and
    # the type name, so what these assertions see is what a caller receives.
    #
    # Driven off a generated runner script rather than powershell.exe -Command,
    # because the command would need nested quoting through Start-Process and
    # Windows would tokenize it apart before PowerShell ever saw it.
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$Extra = '',
        # The control case. Same invocation with the switch left off, so "nothing
        # comes back by default" is tested against the same path rather than
        # against a run that differed in some other way as well.
        [switch]$NoPassThru
    )

    $clixml = Join-Path $env:TEMP 'bf-test-passthru.xml'
    Remove-Item -LiteralPath $clixml -Force -ErrorAction SilentlyContinue

    $sw     = if ($NoPassThru) { '' } else { '-PassThru' }
    $runner = Join-Path $env:TEMP 'bf-test-passthru.ps1'
    $body   = @(
        ("`$r = & '{0}' -OutputPath '{1}' -NoElevate {2} {3}" -f $monitor, $OutputPath, $sw, $Extra),
        '$code = $LASTEXITCODE',
        # Collected first and written second. Export-Clixml on an empty pipeline
        # still produces a readable file, which is what the control case reads.
        ("@(`$r) | Export-Clixml -LiteralPath '{0}'" -f $clixml),
        'exit $code'
    ) -join "`r`n"
    Set-Content -LiteralPath $runner -Value $body -Encoding ASCII

    $so = Join-Path $env:TEMP 'bf-test-out.txt'
    $se = Join-Path $env:TEMP 'bf-test-err.txt'
    $p = Start-Process -FilePath $psExe -PassThru -Wait -NoNewWindow `
         -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $runner) `
         -RedirectStandardOutput $so -RedirectStandardError $se
    return $p.ExitCode
}

function Get-PassThruRows {
    $clixml = Join-Path $env:TEMP 'bf-test-passthru.xml'
    if (-not (Test-Path -LiteralPath $clixml)) { return @() }
    return @(Import-Clixml -LiteralPath $clixml)
}

function Get-Warnings {
    # Whatever the last Invoke-Monitor wrote to stderr. Warnings are the only
    # channel the elevation gate has before logging starts, so the tests that
    # care about it have to read this rather than the log.
    #
    # Forced to a scalar string deliberately. Get-Content -Raw yields nothing at
    # all for an empty file, and -match against nothing returns an empty
    # collection rather than $false - which Assert then refuses to bind, or
    # worse, treats as a failure on a case that was fine.
    #
    # Both streams, because in 5.1 only the error stream is mapped to stderr.
    # Write-Warning lands on stdout, so reading stderr alone returns empty and
    # every "did not warn" assertion passes without testing anything.
    $text = ''
    foreach ($f in @('bf-test-out.txt', 'bf-test-err.txt')) {
        $p = Join-Path $env:TEMP $f
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $raw = Get-Content -LiteralPath $p -Raw
        if ($null -ne $raw) { $text += ' ' + ($raw -join ' ') }
    }
    return [string]($text -replace '\s+', ' ')
}

function Get-Stdout {
    # Stdout alone, unlike Get-Warnings, which merges both streams because 5.1
    # maps only the error stream to stderr. The console report is the thing an
    # operator sees, and a test that cannot tell it apart from a warning that
    # happened to land beside it is not testing the report.
    #
    # Lines rather than one string, so a test can count them. Join for a regex.
    $p = Join-Path $env:TEMP 'bf-test-out.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p)
}

function Assert {
    param([string]$Name, $Condition, [string]$Detail = '')

    # $Condition was typed [bool] until 2026-09-16, and that turned a malformed
    # assertion into a parameter-binding ERROR rather than a failure: PowerShell
    # cannot cast a multi-element array to bool, so the call threw, the run
    # carried on, and the assertion disappeared from the tally altogether. A
    # suite that reports "0 failed" while quietly not running one of its checks
    # is worse than one that reports the failure.
    #
    # The easy way to write one is with a helper that returns a collection:
    # Get-Log returns a string[], so `$log -notmatch 'x'` evaluates to the
    # non-matching LINES rather than to $false, and a 0- or 1-element result
    # would even cast successfully and pass for the wrong reason. Rejected by
    # type rather than coerced, because coercion is what makes that a silent
    # pass. Join the collection first: `($log -join "`n") -notmatch 'x'`.
    if ($Condition -isnot [bool]) {
        $script:fail++
        $what = if ($null -eq $Condition) { '$null' } else { $Condition.GetType().Name }
        Write-Host ('  FAIL  ' + $Name + '  [malformed assertion: condition is ' + $what +
                    ', not a boolean - join collections before matching]') -ForegroundColor Red
        return
    }

    if ($Condition) { $script:pass++; Write-Host ('  PASS  ' + $Name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ('  FAIL  ' + $Name + '  ' + $Detail) -ForegroundColor Red }
}

function Get-Csv {
    # Filtered on the run prefix: latest.csv now sits in the same directory and
    # would sort ahead of it under a bare *.csv descending sort.
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $f = @(Get-ChildItem -LiteralPath $Dir -Filter 'BigFunnelPostingListMonitor-*.csv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($f.Count -eq 0) { return @() }
    return @(Import-Csv -LiteralPath $f[0].FullName)
}

function Get-Log {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $f = @(Get-ChildItem -LiteralPath $Dir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($f.Count -eq 0) { return @() }
    return @(Get-Content -LiteralPath $f[0].FullName)
}

function Get-Summary {
    param([string]$Dir)
    $p = Join-Path $Dir 'latest-summary.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
}

function Reset-Dir {
    param([string]$Name)
    $d = Join-Path $scratch $Name
    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    return $d
}

function Set-RunAge {
    # Rewrites the newest run's file name so the next run sees it as N hours
    # old. The monitor reads the age from the name, not from the file system,
    # so this is the honest way to age a baseline.
    #
    # The process-id suffix is PRESERVED by default, because the monitor writes
    # one. A helper that quietly dropped it is how a completely dead baseline
    # lookup passed this entire suite: every trending test rewrote the file name
    # into a shape production stopped producing the moment $runId gained a $PID,
    # so the tests exercised a path the script no longer takes. -NoPidSuffix
    # reproduces a run written before the suffix existed, which has to keep
    # working as a baseline - those files are still on disk on real servers.
    param([string]$Dir, [double]$Hours, [switch]$NoPidSuffix)
    $old = @(Get-ChildItem -LiteralPath $Dir -Filter 'BigFunnelPostingListMonitor-*.csv' -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending)
    if ($old.Count -eq 0) { return $null }
    $stamp = (Get-Date).AddHours(-$Hours).ToString('yyyyMMdd-HHmmss')
    $name  = if ($NoPidSuffix) { 'BigFunnelPostingListMonitor-' + $stamp + '.csv' }
             else              { 'BigFunnelPostingListMonitor-' + $stamp + '-4242.csv' }
    Rename-Item -LiteralPath $old[0].FullName -NewName $name
    return $stamp
}

Write-Host ''
Write-Host 'T1  threshold validation: -WarningGB at or above -CriticalGB' -ForegroundColor Cyan
$d1 = Reset-Dir '_t1'
$rc = Invoke-Monitor -OutputPath $d1 -Extra '-WarningGB 5 -CriticalGB 2'
Assert 'rejects inverted thresholds with exit 3' ($rc -eq 3) ('got exit ' + $rc)

Write-Host ''
Write-Host 'T2  healthy run, all databases local' -ForegroundColor Cyan
$d2 = Reset-Dir '_t2'
$rc = Invoke-Monitor -OutputPath $d2
Assert 'exits 0 on a healthy run' ($rc -eq 0) ('got exit ' + $rc)
$rows = Get-Csv $d2
Assert 'CSV holds the parseable mailboxes only' ($rows.Count -eq 15) ('got ' + $rows.Count + ' rows')
Assert 'Critical sorts first' ($rows.Count -gt 0 -and $rows[0].Status -eq 'Critical') ('first row = ' + $(if ($rows.Count) { $rows[0].Status } else { 'n/a' }))
Assert 'Unlimited and unparseable mailboxes excluded, not fatal' (@($rows | Where-Object { $_.DisplayName -match 'Unlimited|Garbage' }).Count -eq 0)
$log = Get-Log $d2
Assert 'run reaches the completion line' (@($log | Where-Object { $_ -match 'Monitor run complete' }).Count -eq 1)
Assert 'unparseable value logged as a per-mailbox skip' (@($log | Where-Object { $_ -match 'Skipped mailbox' }).Count -eq 3) 'one per database'

# The two exclusions above reach the CSV the same way and used to leave the log
# reading "database returned 7 mailbox(es)" against five exported rows, with
# only one of the two missing rows accounted for. An operator reconciling those
# numbers had nothing to reconcile them against.
Assert 'the unreadable size is counted, not silently dropped' `
    (@($log | Where-Object { $_ -match 'held no readable value' }).Count -eq 1) `
    (($log | Where-Object { $_ -match 'skipped' }) -join ' | ')
$sum2 = Get-Summary $d2
Assert 'and the two skip reasons are reported separately' `
    ($null -ne $sum2 -and $sum2.SkippedNoSize -eq 3 -and $sum2.SkippedUnparseable -eq 3) `
    ('noSize=' + $(if ($sum2) { $sum2.SkippedNoSize } else { 'n/a' }) + ' unparseable=' + $(if ($sum2) { $sum2.SkippedUnparseable } else { 'n/a' }))
Assert 'the row count and the skip counts account for every mailbox seen' `
    ($null -ne $sum2 -and ($sum2.MailboxesEvaluated + $sum2.SkippedNoSize + $sum2.SkippedUnparseable) -eq 21) `
    ('evaluated=' + $(if ($sum2) { $sum2.MailboxesEvaluated } else { 'n/a' }))
Assert 'no database was aborted by one bad mailbox' (@($log | Where-Object { $_ -match 'Failed to collect' }).Count -eq 0)
$nonAscii = 'Zo' + [char]0xE9 + ' Bj' + [char]0xF6 + 'rk'
Assert 'non-ASCII display name survives Export-Csv' (@($rows | Where-Object { $_.DisplayName -eq $nonAscii }).Count -eq 3) 'UTF8 encoding'
Assert 'timestamps are round-trip format' ($rows.Count -gt 0 -and $rows[0].Timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')
Assert 'healthy population reports SearchHealth OK' (@($rows | Where-Object { $_.SearchHealth -ne 'OK' }).Count -eq 0)

Write-Host ''
Write-Host 'T3  passive DAG node: no active copies mounted here' -ForegroundColor Cyan
$d3 = Reset-Dir '_t3'
# -Scope Local explicitly, and not by inheriting the default, since v1.7.7 made
# the default All. The passive-member case only exists under Local: an All run
# on this same estate collects all three databases from the node holding none.
$rc = Invoke-Monitor -OutputPath $d3 -Extra '-Scope Local' -WithEnv @{ MOCK_ACTIVE_ELSEWHERE = '1' }
Assert 'exits 3 rather than writing an empty CSV' ($rc -eq 3) ('got exit ' + $rc)
$log3 = Get-Log $d3
Assert 'explains the DAG situation in the log' (@($log3 | Where-Object { $_ -match 'mounted elsewhere in the DAG' }).Count -eq 1)
# A failed run must still refresh latest-summary.json, or a monitoring agent
# polling it would keep reporting the previous healthy run indefinitely.
$sum3 = Get-Summary $d3
Assert 'aborted run still writes a summary' ($null -ne $sum3)
Assert 'summary marks the run incomplete' ($null -ne $sum3 -and $sum3.Completed -eq $false)
Assert 'summary carries the abort reason' ($null -ne $sum3 -and $sum3.Status -eq 'No databases in scope') `
    ('got [' + $(if ($sum3) { $sum3.Status } else { 'n/a' }) + ']')
Assert 'summary carries the fatal exit code' ($null -ne $sum3 -and $sum3.ExitCode -eq 3) ('got ' + $(if ($sum3) { $sum3.ExitCode } else { 'n/a' }))
Assert 'aborted summary keeps the same field set' `
    ($null -ne $sum3 -and $null -ne $sum3.PSObject.Properties['MailboxesEvaluated'] -and $sum3.MailboxesEvaluated -eq 0)

Write-Host ''
Write-Host 'T4  one database unreachable' -ForegroundColor Cyan
$d4 = Reset-Dir '_t4'
$rc = Invoke-Monitor -OutputPath $d4 -WithEnv @{ MOCK_FAIL_DB = 'MDB02' }
Assert 'exits 2 for partial results' ($rc -eq 2) ('got exit ' + $rc)
$rows4 = Get-Csv $d4
Assert 'surviving databases still collected' ($rows4.Count -eq 10) ('got ' + $rows4.Count + ' rows')
$log4 = Get-Log $d4
Assert 'names the database that failed' (@($log4 | Where-Object { $_ -match 'Not collected: MDB02' }).Count -eq 1)
$sum4 = Get-Summary $d4
Assert 'summary distinguishes partial from clean' ($null -ne $sum4 -and $sum4.Completed -eq $true -and $sum4.Status -eq 'Partial') `
    ('completed=' + $(if ($sum4) { $sum4.Completed } else { 'n/a' }) + ' status=' + $(if ($sum4) { $sum4.Status } else { 'n/a' }))

Write-Host ''
Write-Host 'T5  growth trending across two runs' -ForegroundColor Cyan
$d5 = Reset-Dir '_t5'
$rc = Invoke-Monitor -OutputPath $d5
Assert 'first run succeeds with no baseline' ($rc -eq 0) ('got exit ' + $rc)
# Backdate past the 24h minimum so the window is unambiguously wide enough.
$null = Set-RunAge -Dir $d5 -Hours 26
Start-Sleep -Seconds 1
$rc = Invoke-Monitor -OutputPath $d5 -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'second run succeeds' ($rc -eq 0) ('got exit ' + $rc)
# The regression guard. Every trending assertion below is downstream of the
# baseline actually being found, so if the file-name pattern stops matching what
# the script writes, they all go quiet rather than red: no baseline means no
# deltas, no deltas means no rows to filter, and a count of zero reads as
# "nothing grew". Naming the file the log claims to have compared against is the
# only assertion here that fails loudly when the lookup itself is dead.
$log5pre = Get-Log $d5
Assert 'the baseline the script actually wrote is the one it finds' `
    (@($log5pre | Where-Object { $_ -match 'Comparing against \[BigFunnelPostingListMonitor-\d{8}-\d{6}-4242\.csv\]' }).Count -eq 1) `
    (($log5pre | Where-Object { $_ -match 'Comparing against|No previous run' }) -join ' | ')
$rows5 = Get-Csv $d5
$grown = @($rows5 | Where-Object { $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0 })
Assert 'growth rate computed against the previous run' ($grown.Count -ge 3) ('got ' + $grown.Count + ' trended rows')
$proj = @($rows5 | Where-Object { $_.DaysToCritical -and [double]$_.DaysToCritical -gt 0 })
Assert 'days-to-critical projected' ($proj.Count -ge 1) ('got ' + $proj.Count)
$log5 = Get-Log $d5
Assert 'emerging risk flagged below the warning line' (@($log5 | Where-Object { $_ -match 'Emerging:' }).Count -ge 1) 'a Normal mailbox trending into Critical'
Assert 'wide baseline raises no provisional warning' (@($log5 | Where-Object { $_ -match 'short of the' }).Count -eq 0)
Assert 'growing mailboxes labelled Growing' (@($rows5 | Where-Object { $_.Trend -eq 'Growing' }).Count -ge 3)
$flat = @($rows5 | Where-Object { $_.DisplayName -eq 'Shared Helpdesk' })
Assert 'flat mailbox gets no false projection' ($flat.Count -gt 0 -and [string]::IsNullOrEmpty($flat[0].DaysToCritical))
Assert 'flat mailbox labelled Flat' ($flat.Count -gt 0 -and $flat[0].Trend -eq 'Flat') ('got ' + $(if ($flat.Count) { $flat[0].Trend } else { 'n/a' }))

Write-Host ''
Write-Host 'T6  concurrency lock' -ForegroundColor Cyan
$d6 = Reset-Dir '_t6'
$held = $null
foreach ($pfx in @('Global\', 'Local\')) {
    try { $held = New-Object System.Threading.Mutex($false, ($pfx + 'ExchangeBigFunnelPostingListMonitor')); break } catch { }
}
if ($null -ne $held -and $held.WaitOne(0)) {
    $rc = Invoke-Monitor -OutputPath $d6
    Assert 'second instance declines to run, exit 4' ($rc -eq 4) ('got exit ' + $rc)
    $held.ReleaseMutex(); $held.Dispose()
}
else { Write-Host '  SKIP  could not acquire the test mutex' -ForegroundColor Yellow }

Write-Host ''
Write-Host 'T7  output retention' -ForegroundColor Cyan
$d7 = Reset-Dir '_t7'
New-Item -Path $d7 -ItemType Directory -Force | Out-Null
$stale = Join-Path $d7 'BigFunnelPostingListMonitor-20200101-000000.csv'
Set-Content -LiteralPath $stale -Value 'stale' -Encoding ASCII
(Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-400)
# Same age, but outside the run-file naming pattern. Retention must not take it.
$decoy = Join-Path $d7 'latest-decoy.csv'
Set-Content -LiteralPath $decoy -Value 'keep me' -Encoding ASCII
(Get-Item -LiteralPath $decoy).LastWriteTime = (Get-Date).AddDays(-400)
$rc = Invoke-Monitor -OutputPath $d7 -Extra '-RetentionDays 30'
Assert 'stale output pruned' (-not (Test-Path -LiteralPath $stale)) 'file older than retention should be gone'
Assert 'retention sweep leaves non-run files alone' (Test-Path -LiteralPath $decoy)
Assert 'current run output kept' ((Get-Csv $d7).Count -eq 15)

Write-Host ''
Write-Host 'T8  baseline selection prefers a window at least -TrendBaselineHours wide' -ForegroundColor Cyan
$d8 = Reset-Dir '_t8'
$rc = Invoke-Monitor -OutputPath $d8
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$seed = @(Get-ChildItem -LiteralPath $d8 -Filter 'BigFunnelPostingListMonitor-*.csv')[0]
$s2  = (Get-Date).AddHours(-2).ToString('yyyyMMdd-HHmmss')
$s30 = (Get-Date).AddHours(-30).ToString('yyyyMMdd-HHmmss')
$s50 = (Get-Date).AddHours(-50).ToString('yyyyMMdd-HHmmss')
foreach ($s in @($s2, $s30, $s50)) {
    Copy-Item -LiteralPath $seed.FullName -Destination (Join-Path $d8 ('BigFunnelPostingListMonitor-' + $s + '-4242.csv'))
}
Remove-Item -LiteralPath $seed.FullName -Force
$rc = Invoke-Monitor -OutputPath $d8 -WithEnv @{ MOCK_GROWTH = '1.25' }
$log8 = Get-Log $d8
Assert 'skips the 2h run and takes the newest that clears 24h' `
    (@($log8 | Where-Object { $_ -match ('Comparing against \[BigFunnelPostingListMonitor-' + $s30) }).Count -eq 1) `
    ('expected ' + $s30 + '; log said: ' + (($log8 | Where-Object { $_ -match 'Comparing against' }) -join ' | '))
Assert 'does not reach past it to the 50h run' (@($log8 | Where-Object { $_ -match $s50 }).Count -eq 0)

Write-Host ''
Write-Host 'T9  baseline narrower than the minimum is used but marked provisional' -ForegroundColor Cyan
$d9 = Reset-Dir '_t9'
$rc = Invoke-Monitor -OutputPath $d9
$null = Set-RunAge -Dir $d9 -Hours 2
Start-Sleep -Seconds 1
$rc = Invoke-Monitor -OutputPath $d9 -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'run still succeeds on a narrow window' ($rc -eq 0) ('got exit ' + $rc)
$log9 = Get-Log $d9
Assert 'warns the projection is provisional' (@($log9 | Where-Object { $_ -match 'short of the 24-hour minimum' }).Count -eq 1)
$rows9 = Get-Csv $d9
Assert 'still trends rather than refusing' (@($rows9 | Where-Object { $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0 }).Count -ge 3)

Write-Host ''
Write-Host 'T10  index-health counters evaluated' -ForegroundColor Cyan
$d10 = Reset-Dir '_t10'
$rc = Invoke-Monitor -OutputPath $d10
$null = Set-RunAge -Dir $d10 -Hours 26
Start-Sleep -Seconds 1
$rc = Invoke-Monitor -OutputPath $d10 -WithEnv @{ MOCK_CORRUPT = '1'; MOCK_STALE = '1' }
$rows10 = Get-Csv $d10
$ana = @($rows10 | Where-Object { $_.DisplayName -eq 'Ana Ilic' })
Assert 'corrupted items flagged without needing a baseline' `
    ($ana.Count -gt 0 -and $ana[0].SearchHealth -match 'Corrupted=3') `
    ('got [' + $(if ($ana.Count) { $ana[0].SearchHealth } else { 'n/a' }) + ']')
Assert 'not-indexed increase flagged against the baseline' (@($rows10 | Where-Object { $_.SearchHealth -match 'NotIndexedUp=\+50' }).Count -ge 3)
Assert 'stale increase flagged against the baseline' (@($rows10 | Where-Object { $_.SearchHealth -match 'StaleUp=\+25' }).Count -ge 3)
$log10 = Get-Log $d10
Assert 'health issues surface in the log' (@($log10 | Where-Object { $_ -match 'SearchHealth:' }).Count -ge 1)
Assert 'index health does not change the exit code' ($rc -eq 0) ('got exit ' + $rc)

Write-Host ''
Write-Host 'T11  post-remediation shrink is detected' -ForegroundColor Cyan
$d11 = Reset-Dir '_t11'
$rc = Invoke-Monitor -OutputPath $d11
$null = Set-RunAge -Dir $d11 -Hours 26
Start-Sleep -Seconds 1
$rc = Invoke-Monitor -OutputPath $d11 -WithEnv @{ MOCK_GROWTH = '0.5' }
$rows11 = Get-Csv $d11
$ana11 = @($rows11 | Where-Object { $_.DisplayName -eq 'Ana Ilic' })
Assert 'a halved table reports Shrinking' ($ana11.Count -gt 0 -and $ana11[0].Trend -eq 'Shrinking') ('got ' + $(if ($ana11.Count) { $ana11[0].Trend } else { 'n/a' }))
Assert 'no forward projection while shrinking' ($ana11.Count -gt 0 -and [string]::IsNullOrEmpty($ana11[0].DaysToCritical))
$log11 = Get-Log $d11
Assert 'shrink rollup written for post-remediation checks' (@($log11 | Where-Object { $_ -match 'shrank since the baseline' }).Count -eq 1)

Write-Host ''
Write-Host 'T12  alert detail is bounded' -ForegroundColor Cyan
$d12 = Reset-Dir '_t12'
$rc = Invoke-Monitor -OutputPath $d12 -Extra '-MaxAlertDetail 1'
$log12 = Get-Log $d12
Assert 'only one at-risk mailbox detailed' (@($log12 | Where-Object { $_ -match '\[WARN\] (Critical|Warning): \[' }).Count -eq 1) `
    ('got ' + @($log12 | Where-Object { $_ -match '\[WARN\] (Critical|Warning): \[' }).Count)
Assert 'the remainder is rolled up, not dropped silently' (@($log12 | Where-Object { $_ -match 'and 5 further at-risk mailbox' }).Count -eq 1) `
    (($log12 | Where-Object { $_ -match 'further at-risk' }) -join ' | ')

Write-Host ''
Write-Host 'T13  stable outputs for monitoring integration' -ForegroundColor Cyan
$d13 = Reset-Dir '_t13'
New-Item -Path $d13 -ItemType Directory -Force | Out-Null
# Planted before the first run: latest.csv must never be mistaken for a baseline.
$plant = Join-Path $d13 'latest.csv'
Set-Content -LiteralPath $plant -Value @(
    'MailboxGuid,PostingListBytes,BigFunnelNotIndexedCount,BigFunnelStaleCount'
    '00000000-0000-0000-0000-000000000001,1,0,0'
) -Encoding ASCII
$rc = Invoke-Monitor -OutputPath $d13
Assert 'run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$log13 = Get-Log $d13
Assert 'latest.csv is not treated as a trend baseline' (@($log13 | Where-Object { $_ -match 'No previous run found' }).Count -eq 1)
Assert 'latest.csv refreshed to match the run' (@(Import-Csv -LiteralPath $plant).Count -eq 15)
$sumPath = Join-Path $d13 'latest-summary.json'
Assert 'summary json written' (Test-Path -LiteralPath $sumPath)
if (Test-Path -LiteralPath $sumPath) {
    $raw = [System.IO.File]::ReadAllBytes($sumPath)
    Assert 'summary json has no BOM' (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF))
    $sum = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json
    Assert 'summary counts match the run' ($sum.MailboxesEvaluated -eq 15 -and $sum.Critical -eq 3 -and $sum.Warning -eq 3) `
        ('evaluated=' + $sum.MailboxesEvaluated + ' critical=' + $sum.Critical + ' warning=' + $sum.Warning)
    Assert 'summary carries the exit code' ($sum.ExitCode -eq 0) ('got ' + $sum.ExitCode)
    Assert 'FailedDatabases is a string on every run' ($sum.FailedDatabases -is [string]) ('got ' + $sum.FailedDatabases.GetType().Name)
    Assert 'summary carries the script version' (-not [string]::IsNullOrWhiteSpace($sum.ScriptVersion))
    Assert 'summary records which threshold basis applied' ($sum.ThresholdMode -eq 'Fixed' -and $sum.ThresholdBasis -eq 'Fixed') `
        ('mode=' + $sum.ThresholdMode + ' basis=' + $sum.ThresholdBasis)
    Assert 'summary reports run duration' ($sum.DurationSeconds -ge 0)
    Assert 'run budget not flagged on a normal run' ($sum.RunBudgetExceeded -eq $false)
    # 3 critical and 3 warning, asserted above. Before v1.7.2 this same run
    # reported Status OK beside those counts.
    Assert 'a completed run that found something says Alert, not OK' `
        ($sum.Completed -eq $true -and $sum.Status -eq 'Alert') `
        ('completed=' + $sum.Completed + ' status=' + $sum.Status)
}

Write-Host ''
Write-Host 'T14  adaptive thresholds decline a sample that is too small' -ForegroundColor Cyan
$d14 = Reset-Dir '_t14'
$rc = Invoke-Monitor -OutputPath $d14 -Extra '-ThresholdMode Adaptive'
Assert 'run still succeeds' ($rc -eq 0) ('got exit ' + $rc)
$log14 = Get-Log $d14
Assert 'says why the fixed values stand' `
    (@($log14 | Where-Object { $_ -match 'Adaptive thresholds need at least 100 mailbox\(es\); 15 were collected' }).Count -eq 1) `
    (($log14 | Where-Object { $_ -match 'Adaptive' }) -join ' | ')
$sum14 = Get-Summary $d14
Assert 'basis records the fallback, not the request' ($null -ne $sum14 -and $sum14.ThresholdMode -eq 'Adaptive' -and $sum14.ThresholdBasis -eq 'Fixed') `
    ('basis=' + $(if ($sum14) { $sum14.ThresholdBasis } else { 'n/a' }))
Assert 'fixed thresholds still classify' ((Get-Csv $d14 | Where-Object { $_.Status -eq 'Critical' }).Count -eq 3)

Write-Host ''
Write-Host 'T15  adaptive thresholds decline a population that does not separate' -ForegroundColor Cyan
$d15 = Reset-Dir '_t15'
# 15 mailboxes clustered tightly enough that P95 and P99 land on the same value.
$rc = Invoke-Monitor -OutputPath $d15 -Extra '-ThresholdMode Adaptive -AdaptiveMinimumSample 10'
Assert 'run still succeeds' ($rc -eq 0) ('got exit ' + $rc)
$log15 = Get-Log $d15
Assert 'refuses a warning tier that could never fire' `
    (@($log15 | Where-Object { $_ -match 'Adaptive thresholds did not separate' }).Count -eq 1) `
    (($log15 | Where-Object { $_ -match 'Adaptive' }) -join ' | ')
$sum15 = Get-Summary $d15
Assert 'falls back to fixed' ($null -ne $sum15 -and $sum15.ThresholdBasis -eq 'Fixed')
Assert 'fixed thresholds unchanged' ($null -ne $sum15 -and [math]::Abs($sum15.WarningGB - 1.7) -lt 0.01 -and [math]::Abs($sum15.CriticalGB - 2.0) -lt 0.01) `
    ('warn=' + $(if ($sum15) { $sum15.WarningGB } else { 'n/a' }) + ' crit=' + $(if ($sum15) { $sum15.CriticalGB } else { 'n/a' }))

Write-Host ''
Write-Host 'T16  adaptive thresholds engage on a wide population' -ForegroundColor Cyan
$d16 = Reset-Dir '_t16'
# 40 extra mailboxes per database spanning 0.65 GB to 6.5 GB. 135 rows in all,
# so P95 lands on 6.2 GB and P99 on 6.5 GB.
$rc = Invoke-Monitor -OutputPath $d16 -Extra '-ThresholdMode Adaptive -AdaptiveMinimumSample 10' -WithEnv @{ MOCK_BULK = '40' }
Assert 'run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$rows16 = Get-Csv $d16
Assert 'whole population collected' ($rows16.Count -eq 135) ('got ' + $rows16.Count + ' rows')
$sum16 = Get-Summary $d16
Assert 'basis is adaptive' ($null -ne $sum16 -and $sum16.ThresholdBasis -eq 'Adaptive') `
    ('basis=' + $(if ($sum16) { $sum16.ThresholdBasis } else { 'n/a' }))
Assert 'thresholds raised to the population percentiles' `
    ($null -ne $sum16 -and [math]::Abs($sum16.WarningGB - 6.2) -lt 0.05 -and [math]::Abs($sum16.CriticalGB - 6.5) -lt 0.05) `
    ('warn=' + $(if ($sum16) { $sum16.WarningGB } else { 'n/a' }) + ' crit=' + $(if ($sum16) { $sum16.CriticalGB } else { 'n/a' }))
Assert 'configured values preserved alongside the effective ones' `
    ($null -ne $sum16 -and [math]::Abs($sum16.ConfiguredWarningGB - 1.7) -lt 0.01)
Assert 'alerting is on outliers, not on the whole population' `
    ($null -ne $sum16 -and $sum16.Critical -eq 3) ('got ' + $(if ($sum16) { $sum16.Critical } else { 'n/a' }) + ' critical')
Assert 'fixed thresholds would have flagged far more' `
    (@($rows16 | Where-Object { [double]$_.PostingListGB -ge 2.0 }).Count -gt 60) `
    'sanity check that adaptive actually changed the outcome'

Write-Host ''
Write-Host 'T17  run budget stops collection rather than overrunning the schedule' -ForegroundColor Cyan
$d17 = Reset-Dir '_t17'
# 2 seconds per database against a 3-second budget: the budget is spent partway
# through the three databases. Covers the per-database gate; the in-stream gate
# fires every 500 mailboxes and this population is too small.
$rc = Invoke-Monitor -OutputPath $d17 -Extra '-MaxRunMinutes 0.05' -WithEnv @{ MOCK_SLOW_MS = '2000' }
Assert 'exits 2 for partial results' ($rc -eq 2) ('got exit ' + $rc)
$log17 = Get-Log $d17
Assert 'names the database it did not start' `
    (@($log17 | Where-Object { $_ -match 'Run budget of 0\.05 minute\(s\) is spent; database \[MDB03\]' }).Count -eq 1) `
    (($log17 | Where-Object { $_ -match 'Run budget' }) -join ' | ')

# Which database the budget lands on is a race between a 2-second mock delay
# and everything else the run does in that window, and it has been observed to
# fall either side under load. Pinning the row count to 10 made a green suite
# depend on machine load; the invariant that actually matters is that whatever
# was collected before the budget ran out survived, and that the arithmetic
# between "returned N" and the exported rows closes.
$skipped17   = @($log17 | Where-Object { $_ -match 'is spent; database \[' }).Count
$collected17 = @($log17 | Where-Object { $_ -match 'Database \[[^\]]+\] returned' }).Count
Assert 'the budget stopped collection short of the full set' `
    ($skipped17 -ge 1 -and ($skipped17 + $collected17) -eq 3) `
    ('skipped=' + $skipped17 + ' collected=' + $collected17)
Assert 'databases collected before the budget ran out are kept' `
    ((Get-Csv $d17).Count -eq (5 * $collected17) -and (Get-Csv $d17).Count -gt 0) `
    ('got ' + (Get-Csv $d17).Count + ' rows from ' + $collected17 + ' database(s)')
$sum17 = Get-Summary $d17
Assert 'summary flags the overrun for the operator' ($null -ne $sum17 -and $sum17.RunBudgetExceeded -eq $true)
Assert 'skipped database reported as not collected' ($null -ne $sum17 -and $sum17.FailedDatabases -match 'MDB03')

Write-Host ''
Write-Host 'T18  a 0 B posting list table on an indexed mailbox is not Normal' -ForegroundColor Cyan
# The state measured on Exchange Server SE 15.2.2562.17. Before this was
# handled, every mailbox on such a build read Normal and the monitor could
# never alert - a silent false negative, which is the worst outcome a monitor
# can produce.
$d18 = Reset-Dir '_t18'
$rc = Invoke-Monitor -OutputPath $d18 -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'run still succeeds' ($rc -eq 0) ('got exit ' + $rc)
$rows18 = Get-Csv $d18
Assert 'no mailbox is reported Normal' (@($rows18 | Where-Object { $_.Status -eq 'Normal' }).Count -eq 0) `
    (($rows18 | ForEach-Object { $_.Status } | Sort-Object -Unique) -join ',')
Assert 'every parseable mailbox is flagged NotPopulated' `
    (@($rows18 | Where-Object { $_.Status -eq 'NotPopulated' }).Count -eq 15) `
    ('got ' + @($rows18 | Where-Object { $_.Status -eq 'NotPopulated' }).Count)
Assert 'the index size that does exist is carried in the CSV' `
    ($rows18.Count -gt 0 -and [int64]$rows18[0].IndexPayloadBytes -gt 4MB) `
    ('got ' + $(if ($rows18.Count) { $rows18[0].IndexPayloadBytes } else { 'n/a' }))
Assert 'the corroborating counter is carried too' `
    ($rows18.Count -gt 0 -and [int64]$rows18[0].BigFunnelIndexedCount -gt 0)
$log18 = Get-Log $d18
Assert 'the log says the metric is not populated' `
    (@($log18 | Where-Object { $_ -match 'reads 0 B' }).Count -eq 1) `
    (($log18 | Where-Object { $_ -match 'NotPopulated|0 B' }) -join ' | ')
Assert 'a whole-population outage is logged as ERROR, not WARN' `
    (@($log18 | Where-Object { $_ -match '\[ERROR\].*Treat the thresholds here as untested' }).Count -eq 1) `
    (($log18 | Where-Object { $_ -match 'untested' }) -join ' | ')
$sum18 = Get-Summary $d18
Assert 'summary counts the affected mailboxes' ($null -ne $sum18 -and $sum18.NotPopulated -eq 15) `
    ('got ' + $(if ($sum18) { $sum18.NotPopulated } else { 'n/a' }))
Assert 'nothing is counted as at risk, because nothing could be' `
    ($null -ne $sum18 -and $sum18.Critical -eq 0 -and $sum18.Warning -eq 0)

Write-Host ''
Write-Host 'T19  NotPopulated coexists with real threshold hits' -ForegroundColor Cyan
# A mixed population, which is what a DAG mid-upgrade looks like. The new state
# must not displace Critical or Warning, and must not sort above them.
$d19 = Reset-Dir '_t19'
$rc = Invoke-Monitor -OutputPath $d19 -WithEnv @{ MOCK_NOTPOPULATED = 'partial' }
Assert 'run still succeeds' ($rc -eq 0) ('got exit ' + $rc)
$rows19 = Get-Csv $d19
Assert 'Critical still sorts first' ($rows19.Count -gt 0 -and $rows19[0].Status -eq 'Critical') `
    ('first row = ' + $(if ($rows19.Count) { $rows19[0].Status } else { 'n/a' }))
Assert 'threshold hits survive alongside the new state' `
    (@($rows19 | Where-Object { $_.Status -eq 'Critical' }).Count -eq 3 -and
     @($rows19 | Where-Object { $_.Status -eq 'Warning' }).Count -eq 3)
Assert 'the remaining mailboxes are flagged, not passed' `
    (@($rows19 | Where-Object { $_.Status -eq 'NotPopulated' }).Count -eq 9) `
    ('got ' + @($rows19 | Where-Object { $_.Status -eq 'NotPopulated' }).Count)
Assert 'NotPopulated sorts below Warning and above Normal' `
    (@($rows19 | Where-Object { $_.Status -eq 'Normal' }).Count -eq 0 -and
     $rows19[6].Status -eq 'NotPopulated') `
    ('row 7 = ' + $(if ($rows19.Count -gt 6) { $rows19[6].Status } else { 'n/a' }))
$log19 = Get-Log $d19
Assert 'a partial outage is a WARN, not an ERROR' `
    (@($log19 | Where-Object { $_ -match '\[WARN\].*reads 0 B' }).Count -eq 1 -and
     @($log19 | Where-Object { $_ -match 'untested' }).Count -eq 0) `
    (($log19 | Where-Object { $_ -match 'reads 0 B|untested' }) -join ' | ')

Write-Host ''
Write-Host 'T20  a genuinely small mailbox is still Normal' -ForegroundColor Cyan
# The guard has to be narrow. If it fired on 0 bytes alone it would relabel
# every empty and never-logged-on mailbox, and the new state would be noise.
$d20 = Reset-Dir '_t20'
$rc = Invoke-Monitor -OutputPath $d20 -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_NO_INDEXED_COUNT = '1' }
Assert 'run still succeeds' ($rc -eq 0) ('got exit ' + $rc)
$rows20 = Get-Csv $d20
Assert 'without a corroborating counter, 0 B stays Normal' `
    (@($rows20 | Where-Object { $_.Status -eq 'NotPopulated' }).Count -eq 0 -and
     @($rows20 | Where-Object { $_.Status -eq 'Normal' }).Count -eq 15) `
    ('normal=' + @($rows20 | Where-Object { $_.Status -eq 'Normal' }).Count +
     ' notpop=' + @($rows20 | Where-Object { $_.Status -eq 'NotPopulated' }).Count)
$sum20 = Get-Summary $d20
Assert 'and nothing is reported as a metric outage' ($null -ne $sum20 -and $sum20.NotPopulated -eq 0)

Write-Host ''
Write-Host 'T21  unindexed system mailboxes do not mask a total outage' -ForegroundColor Cyan
# Found by running v1.3.0 against the lab, not by the mock. On the lab server,
# 44 of 66 rows were health, arbitration, system and archive mailboxes with no
# index at all. Escalating on notPopulated -eq totalRows therefore never fired,
# and a server where every indexed mailbox was affected reported WARN. The
# denominator has to be the indexed population.
#
# Since v1.6.0 the denominator is narrower still - indexed *and* large enough to
# have allocated a posting list table - so this case now also proves the
# narrowing did not cost the real signal. The system mailboxes hold 0 B of
# content as well as no index, and are excluded on either test; the count is
# unchanged at 15 of 15.
$d21 = Reset-Dir '_t21'
$rc = Invoke-Monitor -OutputPath $d21 -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_SYSTEM_MBX = '15' }
Assert 'run still succeeds' ($rc -eq 0) ('got exit ' + $rc)
$rows21 = Get-Csv $d21
Assert 'the unindexed mailboxes are collected and left Normal' `
    (@($rows21 | Where-Object { $_.Status -eq 'Normal' }).Count -eq 45 -and $rows21.Count -eq 60) `
    ('rows=' + $rows21.Count + ' normal=' + @($rows21 | Where-Object { $_.Status -eq 'Normal' }).Count)
Assert 'the indexed mailboxes are all flagged' `
    (@($rows21 | Where-Object { $_.Status -eq 'NotPopulated' }).Count -eq 15)
$log21 = Get-Log $d21
Assert 'ERROR still fires even though most rows are Normal' `
    (@($log21 | Where-Object { $_ -match '\[ERROR\].*Treat the thresholds here as untested' }).Count -eq 1) `
    (($log21 | Where-Object { $_ -match 'untested|reads 0 B' }) -join ' | ')
Assert 'the log reports the eligible population as the denominator' `
    (@($log21 | Where-Object { $_ -match '15 of 15 eligible mailbox\(es\) \(60 evaluated in total\)' }).Count -eq 1) `
    (($log21 | Where-Object { $_ -match 'reads 0 B' }) -join ' | ')

Write-Host ''
Write-Host 'T22  a baseline written before run IDs carried a process id still works' -ForegroundColor Cyan
# The other half of the same bug. Making the pattern require a process id would
# fix trending going forward and silently discard every run already on disk, so
# the first execution after an upgrade would report no history and the operator
# would lose the lead time exactly when the change was supposed to buy it. The
# suffix has to be optional, not mandatory.
$d22 = Reset-Dir '_t22'
$rc = Invoke-Monitor -OutputPath $d22
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$legacy = Set-RunAge -Dir $d22 -Hours 26 -NoPidSuffix
Start-Sleep -Seconds 1
$rc = Invoke-Monitor -OutputPath $d22 -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'run succeeds against a legacy baseline' ($rc -eq 0) ('got exit ' + $rc)
$log22 = Get-Log $d22
Assert 'the pre-upgrade file is accepted as a baseline' `
    (@($log22 | Where-Object { $_ -match ('Comparing against \[BigFunnelPostingListMonitor-' + $legacy + '\.csv\]') }).Count -eq 1) `
    ('expected ' + $legacy + '; log said: ' + (($log22 | Where-Object { $_ -match 'Comparing against|No previous run' }) -join ' | '))
Assert 'and it produces real growth rates, not just a match' `
    (@(Get-Csv $d22 | Where-Object { $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0 }).Count -ge 3) `
    ('got ' + @(Get-Csv $d22 | Where-Object { $_.GrowthGBPerDay -and [double]$_.GrowthGBPerDay -gt 0 }).Count + ' trended rows')

Write-Host ''
Write-Host 'T23  on a 0 B build the run still says which mailbox is next' -ForegroundColor Cyan
# The gap this closes. Every threshold in this script is a size of the posting
# list table, and on Exchange Server SE 15.2.2562.17 that table reads 0 B on a
# fully indexed mailbox - so a run there produced a clean NotPopulated report
# and nothing an operator could act on before Monday. Growth is measured on the
# payload counter instead and the result is ranked rather than dated, because
# the thresholds have never been validated against that counter.
#
# Deliberately run at shipped defaults. A test that needs a non-default
# parameter to see any output has found a defect, not a setup step.
$d23 = Reset-Dir '_t23'
$rc = Invoke-Monitor -OutputPath $d23 -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d23 -Hours 24
$rc = Invoke-Monitor -OutputPath $d23 -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_GROWTH = '1.5' }
Assert 'the run itself still succeeds' ($rc -eq 0) ('got exit ' + $rc)

$log23  = Get-Log $d23
$rows23 = Get-Csv $d23
$fast23 = @($log23 | Where-Object { $_ -match 'Fastest growing #' })

Assert 'the fallback to the payload counter is announced' `
    (@($log23 | Where-Object { $_ -match 'is 0 B for all 15 mailbox\(es\).*measured on IndexPayloadBytes' }).Count -eq 1) `
    (($log23 | Where-Object { $_ -match 'IndexPayloadBytes' }) -join ' | ')
Assert 'a ranking is produced at default settings' ($fast23.Count -gt 0) ('got ' + $fast23.Count + ' lines')

$rates23 = @($fast23 | ForEach-Object { if ($_ -match 'growing ([0-9.]+) GB/day') { [double]$matches[1] } })
$ordered23 = $true
for ($i = 1; $i -lt $rates23.Count; $i++) { if ($rates23[$i] -gt $rates23[$i - 1]) { $ordered23 = $false } }
Assert 'the ranking is ordered fastest first' ($ordered23 -and $rates23.Count -ge 4) (($rates23 -join ' > '))
Assert 'and is not a single tie masquerading as a ranking' `
    (@($rates23 | Sort-Object -Unique).Count -ge 4) `
    ('only ' + @($rates23 | Sort-Object -Unique).Count + ' distinct rate(s) across ' + $rates23.Count + ' rows')

# The two counters are three orders of magnitude apart, so printing the posting
# list size beside a payload-derived rate yields "at 0 GB, growing 0.02 GB/day".
Assert 'the size printed is the counter the rate was measured on' `
    (@($fast23 | Where-Object { $_ -match ' at 0 GB,' }).Count -eq 0) `
    (($fast23 | Select-Object -First 1) -join '')
Assert 'MeasuredGB is carried in the CSV alongside it' `
    (@($rows23 | Where-Object { $_.MeasuredGB -and [double]$_.MeasuredGB -gt 0 }).Count -ge 4) `
    ('got ' + @($rows23 | Where-Object { $_.MeasuredGB -and [double]$_.MeasuredGB -gt 0 }).Count + ' rows')

# An empty column reads as "no projection"; a number computed against a
# threshold that describes a different counter reads as a deadline.
Assert 'no date is projected on this path' `
    (@($rows23 | Where-Object { $_.DaysToCritical -ne '' }).Count -eq 0) `
    ('populated on ' + @($rows23 | Where-Object { $_.DaysToCritical -ne '' }).Count + ' rows')
Assert 'and none is claimed in the log either' `
    (@($log23 | Where-Object { $_ -match 'projected critical in' }).Count -eq 0)

# The log points at the CSV for the detail it truncated. Sorting that file by a
# column that is zero on every row leaves it in collection order.
$notPop23 = @($rows23 | Where-Object { $_.Status -eq 'NotPopulated' })
$sortedByPayload = $true
for ($i = 1; $i -lt $notPop23.Count; $i++) {
    if ([int64]$notPop23[$i].IndexPayloadBytes -gt [int64]$notPop23[$i - 1].IndexPayloadBytes) { $sortedByPayload = $false }
}
Assert 'the CSV is ordered by the counter that actually varies' `
    ($sortedByPayload -and $notPop23.Count -eq 15) `
    ('rows=' + $notPop23.Count)

$sum23 = Get-Summary $d23
Assert 'the summary names the counter and counts the growers' `
    ($null -ne $sum23 -and $sum23.TrendMetric -eq 'IndexPayloadBytes' -and $sum23.Growing -ge 4) `
    ('metric=' + $(if ($sum23) { $sum23.TrendMetric } else { 'n/a' }) + ' growing=' + $(if ($sum23) { $sum23.Growing } else { 'n/a' }))
Assert 'and Emerging is empty there, which is why Growing has to exist' `
    ($null -ne $sum23 -and $sum23.Emerging -eq 0) `
    ('emerging=' + $(if ($sum23) { $sum23.Emerging } else { 'n/a' }))

Write-Host ''
Write-Host 'T24  a baseline written before the payload column existed is reported, not guessed' -ForegroundColor Cyan
# v1.3.1 wrote IndexPayloadBytes; earlier runs did not. A missing previous value
# coerced to zero turns the whole of the current size into one window's growth
# and parks that mailbox at the top of the ranking on the strength of a column
# that was never there.
$d24 = Reset-Dir '_t24'
$rc = Invoke-Monitor -OutputPath $d24 -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d24 -Hours 24
$oldCsv = @(Get-ChildItem -LiteralPath $d24 -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
@(Import-Csv -LiteralPath $oldCsv.FullName) |
    Select-Object -Property * -ExcludeProperty IndexPayloadBytes |
    Export-Csv -LiteralPath $oldCsv.FullName -NoTypeInformation -Encoding UTF8
$rc = Invoke-Monitor -OutputPath $d24 -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_GROWTH = '1.5' }
Assert 'the run survives the older baseline' ($rc -eq 0) ('got exit ' + $rc)
$log24 = Get-Log $d24
Assert 'the mailboxes with no previous reading are counted and explained' `
    (@($log24 | Where-Object { $_ -match '15 mailbox\(es\) were in the baseline but carried no IndexPayloadBytes reading' }).Count -eq 1) `
    (($log24 | Where-Object { $_ -match 'baseline|reading' }) -join ' | ')
Assert 'and none of them is invented as a grower' `
    (@($log24 | Where-Object { $_ -match 'Fastest growing #' }).Count -eq 0) `
    (($log24 | Where-Object { $_ -match 'Fastest growing' }) -join ' | ')
Assert 'the CSV carries no rate for them either' `
    (@(Get-Csv $d24 | Where-Object { $_.GrowthGBPerDay -ne '' }).Count -eq 0) `
    ('got ' + @(Get-Csv $d24 | Where-Object { $_.GrowthGBPerDay -ne '' }).Count + ' rated rows')

Write-Host ''
Write-Host 'T25  the populated path is unchanged by the fallback' -ForegroundColor Cyan
# The fallback must not leak into the build the thresholds were written for.
# Where the posting list table carries data, the projection is still made, the
# date is still given, and the ranking-without-dates stays out of the log.
$d25 = Reset-Dir '_t25'
$rc = Invoke-Monitor -OutputPath $d25
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d25 -Hours 24
$rc = Invoke-Monitor -OutputPath $d25 -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$log25  = Get-Log $d25
$rows25 = Get-Csv $d25
$sum25  = Get-Summary $d25
Assert 'growth is still measured on the posting list table' `
    ($null -ne $sum25 -and $sum25.TrendMetric -eq 'PostingListBytes') `
    ('metric=' + $(if ($sum25) { $sum25.TrendMetric } else { 'n/a' }))
Assert 'dates are still projected' `
    (@($rows25 | Where-Object { $_.DaysToCritical -ne '' -and [double]$_.DaysToCritical -gt 0 }).Count -ge 3) `
    ('got ' + @($rows25 | Where-Object { $_.DaysToCritical -ne '' }).Count + ' projected rows')
Assert 'the emerging report still fires' `
    (@($log25 | Where-Object { $_ -match 'Emerging: \[' }).Count -ge 1) `
    (($log25 | Where-Object { $_ -match 'Emerging' }) -join ' | ')
Assert 'and the rate-only ranking stays out of it' `
    (@($log25 | Where-Object { $_ -match 'Fastest growing #|measured on IndexPayloadBytes' }).Count -eq 0)
Assert 'MeasuredGB tracks the posting list size on this path' `
    (@($rows25 | Where-Object { $_.MeasuredGB -ne '' -and $_.MeasuredGB -ne $_.PostingListGB }).Count -eq 0) `
    ('mismatched on ' + @($rows25 | Where-Object { $_.MeasuredGB -ne '' -and $_.MeasuredGB -ne $_.PostingListGB }).Count + ' rows')

Write-Host ''
Write-Host 'T26  -TrendBaselineHours 0 is rejected at bind time' -ForegroundColor Cyan
# Zero is not a narrower version of this setting. It makes every baseline old
# enough by definition, so MetMinimum is true whatever the window, the warning
# that the sample was too narrow to divide by never fires, and the rates are
# published anyway. Failing at bind time is the honest response to a value the
# script cannot act on.
$d26 = Reset-Dir '_t26'
$rc = Invoke-Monitor -OutputPath $d26 -Extra '-TrendBaselineHours 0'
Assert 'zero is refused' ($rc -eq 1) ('got exit ' + $rc)
Assert 'and nothing was collected under it' ((Get-Csv $d26).Count -eq 0) ('got ' + (Get-Csv $d26).Count + ' rows')
$d26b = Reset-Dir '_t26b'
$rc = Invoke-Monitor -OutputPath $d26b -Extra '-TrendBaselineHours 1'
Assert 'the narrowest legal window is still accepted' ($rc -eq 0) ('got exit ' + $rc)

Write-Host ''
Write-Host 'T27  a skipped measurement is not an all-clear' -ForegroundColor Cyan
# A baseline can be found and then rejected for being too recent to divide by.
# Gating the report on "a baseline exists" rather than on "a rate was derived"
# prints a reassuring line one line after saying the measurement was skipped,
# and on the 0 B path that reassurance is the only trend statement in the run.
$d27 = Reset-Dir '_t27'
$rc = Invoke-Monitor -OutputPath $d27 -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d27 -Hours 0.001
$rc = Invoke-Monitor -OutputPath $d27 -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_GROWTH = '1.5' }
Assert 'run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$log27 = Get-Log $d27
Assert 'the skip is announced' `
    (@($log27 | Where-Object { $_ -match 'too recent to derive a meaningful rate' }).Count -eq 1) `
    (($log27 | Where-Object { $_ -match 'baseline|recent|Comparing' }) -join ' | ')
Assert 'and no all-clear follows it' `
    (@($log27 | Where-Object { $_ -match 'No mailbox grew measurably' }).Count -eq 0) `
    (($log27 | Where-Object { $_ -match 'No mailbox' }) -join ' | ')
Assert 'and no ranking is claimed either' `
    (@($log27 | Where-Object { $_ -match 'Fastest growing #' }).Count -eq 0)

Write-Host ''
Write-Host 'T28  a total metric outage is not reported as a healthy run' -ForegroundColor Cyan
# NotPopulated fixed the per-mailbox false negative: a 0 B table on an indexed
# mailbox no longer reads Normal. The identical false negative survived one
# layer up. A run where every indexed mailbox is affected cannot ever cross a
# threshold, yet it reported Status OK and exit 0, so a monitoring platform
# keyed on either one read "healthy" from a run that had measured nothing. That
# is the outcome the state was invented to prevent. Reproduced against a live
# Exchange Server SE 15.2.2562.17 lab, where the table reads 0 B on a shared
# mailbox holding 200 indexed messages, before being fixed here.
#
# Exit code 5 is gated on -ExitNonZeroOnAlert deliberately. The switch is off by
# default so "found problems" is not confused with "the monitor broke", and a
# default run has to keep exiting 0 - T18, T21, T23, T24 and T27 all depend on
# that. Status is NOT gated, because it describes the run rather than signalling
# it, and a summary calling an unmeasurable run OK is wrong with or without the
# switch. Before this block, -ExitNonZeroOnAlert had no coverage at all.
$d28 = Reset-Dir '_t28'
$rc = Invoke-Monitor -OutputPath $d28 -Extra '-ExitNonZeroOnAlert' -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'a total outage exits non-zero once alerts are asked for' ($rc -eq 5) ('got exit ' + $rc)
$sum28 = Get-Summary $d28
Assert 'and the summary refuses to call it OK' `
    ($null -ne $sum28 -and $sum28.Status -eq 'MetricUnavailable') `
    ('got [' + $(if ($sum28) { $sum28.Status } else { 'n/a' }) + ']')
Assert 'the run is still reported as completed and collected' `
    ($null -ne $sum28 -and $sum28.Completed -eq $true -and $sum28.NotPopulated -eq 15) `
    ('completed=' + $(if ($sum28) { $sum28.Completed } else { 'n/a' }) +
     ' notpop=' + $(if ($sum28) { $sum28.NotPopulated } else { 'n/a' }))
Assert 'and the new code reaches the summary too' `
    ($null -ne $sum28 -and $sum28.ExitCode -eq 5) `
    ('got ' + $(if ($sum28) { $sum28.ExitCode } else { 'n/a' }))

# Default behaviour is a contract. Five earlier tests assert exit 0 on this
# exact scenario, and none of them passes the switch.
$d28b = Reset-Dir '_t28b'
$rc = Invoke-Monitor -OutputPath $d28b -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'without the switch the exit code is unchanged' ($rc -eq 0) ('got exit ' + $rc)
$sum28b = Get-Summary $d28b
Assert 'but the summary still declines to say OK' `
    ($null -ne $sum28b -and $sum28b.Status -eq 'MetricUnavailable') `
    ('got [' + $(if ($sum28b) { $sum28b.Status } else { 'n/a' }) + ']')

# Narrowness. A partial outage leaves mailboxes that can still cross a
# threshold, so the run remains a valid measurement and must not be relabelled.
$d28c = Reset-Dir '_t28c'
$rc = Invoke-Monitor -OutputPath $d28c -Extra '-ExitNonZeroOnAlert' -WithEnv @{ MOCK_NOTPOPULATED = 'partial' }
Assert 'a partial outage exits on the threshold hits it did find' ($rc -eq 1) ('got exit ' + $rc)
$sum28c = Get-Summary $d28c
Assert 'and a partial outage reads as Alert, not as a metric outage' `
    ($null -ne $sum28c -and $sum28c.Status -eq 'Alert') `
    ('got [' + $(if ($sum28c) { $sum28c.Status } else { 'n/a' }) + ']')

# A real breach is a different alert from an unmeasurable run and cannot be
# displaced by one.
$d28d = Reset-Dir '_t28d'
$rc = Invoke-Monitor -OutputPath $d28d -Extra '-ExitNonZeroOnAlert'
Assert 'an at-risk run still exits 1, not 5' ($rc -eq 1) ('got exit ' + $rc)

# A collection failure outranks both: a total outage worked out from a partial
# collection is not a statement about the estate.
$d28e = Reset-Dir '_t28e'
$rc = Invoke-Monitor -OutputPath $d28e -Extra '-ExitNonZeroOnAlert' `
      -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_FAIL_DB = 'MDB02' }
Assert 'a partial collection outranks the outage verdict' ($rc -eq 2) ('got exit ' + $rc)
$sum28e = Get-Summary $d28e
Assert 'and the summary says Partial, not MetricUnavailable' `
    ($null -ne $sum28e -and $sum28e.Status -eq 'Partial') `
    ('got [' + $(if ($sum28e) { $sum28e.Status } else { 'n/a' }) + ']')

Write-Host ''
Write-Host 'T29  on a mixed estate each mailbox is trended on its own counter' -ForegroundColor Cyan
# The counter to trend on was chosen once for the whole run: if any mailbox
# anywhere had a populated posting list table, every mailbox was measured on it.
# On an estate mid-transition that is the wrong shape. Two mailboxes crossing the
# allocation threshold moved the rest - still reading 0 B, and unchanged in every
# other respect - onto a counter that is a constant zero for them, and the
# ranking that exists to name the next mailbox went blind for most of the
# population. Whether the posting list table is readable is a property of a
# mailbox, so it is read off one.
$d29 = Reset-Dir '_t29'
$rc = Invoke-Monitor -OutputPath $d29 -WithEnv @{ MOCK_NOTPOPULATED = 'partial' }
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d29 -Hours 24
$rc = Invoke-Monitor -OutputPath $d29 -WithEnv @{ MOCK_NOTPOPULATED = 'partial'; MOCK_GROWTH = '1.5' }
Assert 'the run itself still succeeds' ($rc -eq 0) ('got exit ' + $rc)

$log29  = Get-Log $d29
$rows29 = Get-Csv $d29
$sum29  = Get-Summary $d29
$pay29  = @($rows29 | Where-Object { $_.TrendMetric -eq 'IndexPayloadBytes' })
$plt29  = @($rows29 | Where-Object { $_.TrendMetric -eq 'PostingListBytes' })

Assert 'the run reports both counters rather than picking one' `
    ($null -ne $sum29 -and $sum29.TrendMetric -eq 'Mixed') `
    ('metric=' + $(if ($sum29) { $sum29.TrendMetric } else { 'n/a' }))
Assert 'and says how much of the estate fell on the fallback counter' `
    ($null -ne $sum29 -and $sum29.TrendedOnPayload -eq 9) `
    ('got ' + $(if ($sum29) { $sum29.TrendedOnPayload } else { 'n/a' }))
Assert 'the split is recorded per row, not per run' `
    ($pay29.Count -eq 9 -and $plt29.Count -eq 6) `
    ('payload=' + $pay29.Count + ' postinglist=' + $plt29.Count)

# The regression this closes. Trended on the posting list table these nine read
# 0 B in both runs, so every delta was zero and the run found nothing to say
# about them.
Assert 'the 0 B mailboxes produce a real rate again' `
    (@($pay29 | Where-Object { $_.GrowthGBPerDay -ne '' -and [double]$_.GrowthGBPerDay -gt 0 }).Count -eq 6) `
    ('got ' + @($pay29 | Where-Object { $_.GrowthGBPerDay -ne '' -and [double]$_.GrowthGBPerDay -gt 0 }).Count + ' rated rows')
Assert 'without inheriting a projection the thresholds cannot make' `
    (@($pay29 | Where-Object { $_.DaysToCritical -ne '' }).Count -eq 0) `
    ('dated on ' + @($pay29 | Where-Object { $_.DaysToCritical -ne '' }).Count + ' rows')
Assert 'while the readable mailboxes keep theirs' `
    (@($plt29 | Where-Object { $_.DaysToCritical -ne '' }).Count -eq 6) `
    ('dated on ' + @($plt29 | Where-Object { $_.DaysToCritical -ne '' }).Count + ' of ' + $plt29.Count)

# Growing counted only the ranked subset, so a mixed run reported Growing 0 with
# growing mailboxes plainly in its own CSV.
Assert 'Growing counts every growing mailbox, on either counter' `
    ($null -ne $sum29 -and $sum29.Growing -eq 12 -and $sum29.GrowingRanked -eq 6) `
    ('growing=' + $(if ($sum29) { $sum29.Growing } else { 'n/a' }) +
     ' ranked=' + $(if ($sum29) { $sum29.GrowingRanked } else { 'n/a' }))
Assert 'and the two-counter run is announced once' `
    (@($log29 | Where-Object { $_ -match 'Growth on this run is split across two counters' }).Count -eq 1) `
    (($log29 | Where-Object { $_ -match 'split across' }) -join ' | ')

Write-Host ''
Write-Host 'T30  a mailbox projected to cross gets its own exit code' -ForegroundColor Cyan
# Emerging reached the log and the summary but never the exit code, so a
# scheduled task keyed on the exit code - which is the documented way to run this
# - saw exit 0 on a run whose own output named two mailboxes days from critical.
# Exit 6 rather than 1, because "at or above a threshold now" and "still below it
# and projected to cross" want different responses, and exit 1's meaning is a
# contract with everything already consuming it.
$d30 = Reset-Dir '_t30'
$rc = Invoke-Monitor -OutputPath $d30 -Extra '-WarningGB 3.5 -CriticalGB 4.0'
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d30 -Hours 24
$rc = Invoke-Monitor -OutputPath $d30 -Extra '-WarningGB 3.5 -CriticalGB 4.0 -ExitNonZeroOnAlert' `
      -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'an emerging-only run exits 6' ($rc -eq 6) ('got exit ' + $rc)
$sum30 = Get-Summary $d30
Assert 'and it really is emerging-only' `
    ($null -ne $sum30 -and $sum30.Critical -eq 0 -and $sum30.Warning -eq 0 -and $sum30.Emerging -eq 3) `
    ('crit=' + $(if ($sum30) { $sum30.Critical } else { 'n/a' }) +
     ' warn=' + $(if ($sum30) { $sum30.Warning } else { 'n/a' }) +
     ' emerging=' + $(if ($sum30) { $sum30.Emerging } else { 'n/a' }))
Assert 'the new code reaches the summary too' `
    ($null -ne $sum30 -and $sum30.ExitCode -eq 6) `
    ('got ' + $(if ($sum30) { $sum30.ExitCode } else { 'n/a' }))
Assert 'a projection is a finding, so the status names it rather than saying OK' `
    ($null -ne $sum30 -and $sum30.Status -eq 'Emerging') `
    ('got [' + $(if ($sum30) { $sum30.Status } else { 'n/a' }) + ']')

# Default behaviour is a contract: the switch is what turns findings into exit
# codes, and a run without it still exits 0.
$d30b = Reset-Dir '_t30b'
$rc = Invoke-Monitor -OutputPath $d30b -Extra '-WarningGB 3.5 -CriticalGB 4.0'
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d30b -Hours 24
$rc = Invoke-Monitor -OutputPath $d30b -Extra '-WarningGB 3.5 -CriticalGB 4.0' -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'without the switch the exit code is unchanged' ($rc -eq 0) ('got exit ' + $rc)

# A breach outranks a projection. Exit 6 must not displace exit 1 on a run that
# has both, or adding lead time would cost an operator the alert they already
# acted on.
$d30c = Reset-Dir '_t30c'
$rc = Invoke-Monitor -OutputPath $d30c
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d30c -Hours 24
$rc = Invoke-Monitor -OutputPath $d30c -Extra '-ExitNonZeroOnAlert' -WithEnv @{ MOCK_GROWTH = '1.25' }
$sum30c = Get-Summary $d30c
Assert 'a run with both at-risk and emerging exits 1, not 6' ($rc -eq 1) ('got exit ' + $rc)
Assert 'and it genuinely had both' `
    ($null -ne $sum30c -and ($sum30c.Critical + $sum30c.Warning) -gt 0 -and $sum30c.Emerging -gt 0) `
    ('atrisk=' + $(if ($sum30c) { $sum30c.Critical + $sum30c.Warning } else { 'n/a' }) +
     ' emerging=' + $(if ($sum30c) { $sum30c.Emerging } else { 'n/a' }))
# Status is ordered on the same rule as the exit code, so the two cannot name
# different findings about one run.
Assert 'and the status names the breach, matching the exit code' `
    ($null -ne $sum30c -and $sum30c.Status -eq 'Alert') `
    ('got [' + $(if ($sum30c) { $sum30c.Status } else { 'n/a' }) + ']')

Write-Host ''
Write-Host 'T31  the emerging list is ordered by how soon, not by how big' -ForegroundColor Cyan
# The list was filtered out of a set sorted by status and then by size, and never
# re-sorted, so it was published in size order under a heading that promises
# urgency. -MaxAlertDetail made that worse than cosmetic: the entry truncated off
# the bottom was the soonest to cross rather than the least interesting.
#
# The mock scales growth with size, so the biggest mailbox is also the fastest
# and the two orderings agree. The baseline is rewritten to break that tie the
# way a real estate does - a small mailbox filling quickly, a large one nearly
# static - because a test that cannot tell the two orderings apart is not a test
# of the ordering.
$d31 = Reset-Dir '_t31'
$rc = Invoke-Monitor -OutputPath $d31 -Extra '-WarningGB 3.0 -CriticalGB 3.5'
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d31 -Hours 24
$base31 = @(Get-ChildItem -LiteralPath $d31 -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
$rows31 = @(Import-Csv -LiteralPath $base31.FullName)
foreach ($r in $rows31) {
    switch ($r.DisplayName) {
        # 1.20 GB now, so 1.00 GB/day: 2.30 days to 3.5 GB.
        'Emerging Mbx' { $r.PostingListBytes = [string][int64](0.20 * 1GB) }
        # 2.40 GB now, so 0.40 GB/day: 2.75 days. Twice the size, further out.
        'Ana Ilic'     { $r.PostingListBytes = [string][int64](2.00 * 1GB) }
        # 1.80 GB now, so 0.30 GB/day: 5.67 days. Outside the window, and the
        # proof that the three-day filter still applies to the re-sorted list.
        'Bo Persson'   { $r.PostingListBytes = [string][int64](1.50 * 1GB) }
    }
}
$rows31 | Export-Csv -LiteralPath $base31.FullName -NoTypeInformation -Encoding UTF8

$rc = Invoke-Monitor -OutputPath $d31 -Extra '-WarningGB 3.0 -CriticalGB 3.5'
Assert 'the run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$log31 = Get-Log $d31
$em31  = @($log31 | Where-Object { $_ -match 'Emerging: \[' })
Assert 'both mailboxes inside the window are listed' ($em31.Count -eq 6) ('got ' + $em31.Count + ' lines')
Assert 'and the one outside it is not' `
    (@($em31 | Where-Object { $_ -match 'Bo Persson' }).Count -eq 0) `
    (($em31 | Where-Object { $_ -match 'Bo Persson' }) -join ' | ')

$days31 = @($em31 | ForEach-Object { if ($_ -match 'projected critical in ([0-9.]+) day') { [double]$matches[1] } })
$asc31  = $true
for ($i = 1; $i -lt $days31.Count; $i++) { if ($days31[$i] -lt $days31[$i - 1]) { $asc31 = $false } }
Assert 'the list runs soonest first' ($asc31 -and $days31.Count -eq 6) (($days31 -join ' -> '))
Assert 'which is not the same as biggest first' `
    ($em31.Count -gt 0 -and $em31[0] -match 'Emerging Mbx') `
    (($em31 | Select-Object -First 1) -join '')

# The cap keeps the head of the list rather than an arbitrary slice of it.
$d31b = Reset-Dir '_t31b'
$rc = Invoke-Monitor -OutputPath $d31b -Extra '-WarningGB 3.0 -CriticalGB 3.5'
$null = Set-RunAge -Dir $d31b -Hours 24
$base31b = @(Get-ChildItem -LiteralPath $d31b -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
$rows31b = @(Import-Csv -LiteralPath $base31b.FullName)
foreach ($r in $rows31b) {
    switch ($r.DisplayName) {
        'Emerging Mbx' { $r.PostingListBytes = [string][int64](0.20 * 1GB) }
        'Ana Ilic'     { $r.PostingListBytes = [string][int64](2.00 * 1GB) }
        'Bo Persson'   { $r.PostingListBytes = [string][int64](1.50 * 1GB) }
    }
}
$rows31b | Export-Csv -LiteralPath $base31b.FullName -NoTypeInformation -Encoding UTF8
$rc = Invoke-Monitor -OutputPath $d31b -Extra '-WarningGB 3.0 -CriticalGB 3.5 -MaxAlertDetail 1'
Assert 'a truncated list keeps the soonest, not the largest' `
    (@(Get-Log $d31b | Where-Object { $_ -match 'Emerging: \[.*Emerging Mbx' }).Count -eq 1) `
    ((Get-Log $d31b | Where-Object { $_ -match 'Emerging: \[' }) -join ' | ')
Assert 'and says what it truncated' `
    (@(Get-Log $d31b | Where-Object { $_ -match '5 further emerging mailbox\(es\) not listed' }).Count -eq 1) `
    ((Get-Log $d31b | Where-Object { $_ -match 'further emerging' }) -join ' | ')

Write-Host ''
Write-Host 'T32  a run that collects nothing does not erase the last run that did' -ForegroundColor Cyan
# latest.csv is the stable path a monitoring platform reads, and it was rewritten
# unconditionally. A run that collected no rows therefore replaced a full detail
# file with an empty one, so the failure took the previous answer with it - and
# the previous answer was the only detail anyone had. Measured in the lab: 15
# rows and 6488 bytes replaced by 3 bytes, on a run that reported exit 2 and was
# already known to have failed. The exit code and the summary signal the failure;
# they do not need the detail file to signal it as well.
$d32 = Reset-Dir '_t32'
$rc = Invoke-Monitor -OutputPath $d32
Assert 'seed run collects rows' ($rc -eq 0) ('got exit ' + $rc)
$latest32 = Join-Path $d32 'latest.csv'
Assert 'and leaves them in latest.csv' `
    ((Test-Path -LiteralPath $latest32) -and @(Import-Csv -LiteralPath $latest32).Count -eq 15) `
    ('got ' + $(if (Test-Path -LiteralPath $latest32) { @(Import-Csv -LiteralPath $latest32).Count } else { 'no file' }) + ' rows')

$rc = Invoke-Monitor -OutputPath $d32 -WithEnv @{ MOCK_EMPTY = '1' }
$sum32 = Get-Summary $d32
Assert 'the empty run really collected nothing' `
    ($null -ne $sum32 -and $sum32.MailboxesEvaluated -eq 0) `
    ('evaluated=' + $(if ($sum32) { $sum32.MailboxesEvaluated } else { 'n/a' }))
Assert 'and latest.csv still holds the last real result' `
    (@(Import-Csv -LiteralPath $latest32).Count -eq 15) `
    ('got ' + @(Import-Csv -LiteralPath $latest32).Count + ' rows')
Assert 'the run says so rather than leaving it to be discovered' `
    (@(Get-Log $d32 | Where-Object { $_ -match 'has been left untouched' }).Count -eq 1) `
    ((Get-Log $d32 | Where-Object { $_ -match 'latest.csv' }) -join ' | ')

# The stale file must not be mistaken for this run's output. Its own timestamped
# CSV is the empty one, and the summary still counts zero.
Assert 'this run wrote its own empty detail file' `
    ((Get-Csv $d32).Count -eq 0) `
    ('got ' + (Get-Csv $d32).Count + ' rows')

Write-Host ''
Write-Host 'T33  a mailbox missing from the baseline is counted, not dropped' -ForegroundColor Cyan
# The trend join skipped any mailbox with no baseline entry and said nothing
# about how many it skipped, so "nothing is trending" and "the join could not see
# this part of the estate" produced an identical CSV. Seen in the lab on a run
# that evaluated 47 mailboxes, baselined 45, and never accounted for the other
# two. The runbook has always described this line; the script never emitted it.
$d33 = Reset-Dir '_t33'
$rc = Invoke-Monitor -OutputPath $d33
Assert 'seed run succeeds' ($rc -eq 0) ('got exit ' + $rc)
$null = Set-RunAge -Dir $d33 -Hours 24
$base33 = @(Get-ChildItem -LiteralPath $d33 -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
$rows33 = @(Import-Csv -LiteralPath $base33.FullName)
# Four mailboxes the baseline has never seen, which is what a database that
# failed to collect on the previous run leaves behind.
@($rows33 | Select-Object -Skip 4) | Export-Csv -LiteralPath $base33.FullName -NoTypeInformation -Encoding UTF8
$rc = Invoke-Monitor -OutputPath $d33 -WithEnv @{ MOCK_GROWTH = '1.25' }
Assert 'the run survives the shorter baseline' ($rc -eq 0) ('got exit ' + $rc)
$log33 = Get-Log $d33
Assert 'the gap is counted and explained' `
    (@($log33 | Where-Object { $_ -match '4 of 15 mailbox\(es\) evaluated were not in the baseline' }).Count -eq 1) `
    (($log33 | Where-Object { $_ -match 'baseline' }) -join ' | ')
Assert 'and only the matched mailboxes carry a rate' `
    (@(Get-Csv $d33 | Where-Object { $_.GrowthGBPerDay -ne '' }).Count -eq 11) `
    ('got ' + @(Get-Csv $d33 | Where-Object { $_.GrowthGBPerDay -ne '' }).Count + ' rated rows')

# It must stay quiet when there is no gap, or it becomes a line every run carries
# and nobody reads.
Assert 'a complete baseline produces no such line' `
    (@(Get-Log $d25 | Where-Object { $_ -match 'were not in the baseline' }).Count -eq 0) `
    ((Get-Log $d25 | Where-Object { $_ -match 'not in the baseline' }) -join ' | ')

Write-Host ''
Write-Host 'T34  a small estate is not a blind one' -ForegroundColor Cyan
# The false positive that made all of this necessary. NotPopulated was applied to
# any indexed mailbox reading 0 B with no size test at all, so on an estate where
# every mailbox is too small to have allocated a posting list table the run
# escalated itself to a full metric outage: two ERROR lines, Status
# MetricUnavailable, exit 5. Reproduced on w25-ex03, where that is simply what a
# small mailbox looks like.
#
# Measured on Exchange Server SE 15.2.2562.17: 3.45 MB and 6.87 MB of content
# both read 0 B, 16.33 MB read 3.344 MB. Below the allocation point 0 B is the
# correct reading, and a monitor that cries wolf on every small estate gets
# muted - which costs exactly what NotPopulated was added to buy.
$d34 = Reset-Dir '_t34'
$rc = Invoke-Monitor -OutputPath $d34 -Extra '-ExitNonZeroOnAlert' `
      -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_MAILBOX_MB = '4' }
Assert 'a scope of small mailboxes does not raise an alert exit code' ($rc -eq 0) ('got exit ' + $rc)

$rows34 = @(Get-Csv $d34)
Assert 'every small zero-reader is NotAllocated, none is NotPopulated' `
    (@($rows34 | Where-Object { $_.Status -eq 'NotAllocated' }).Count -eq 15 -and
     @($rows34 | Where-Object { $_.Status -eq 'NotPopulated' }).Count -eq 0) `
    (($rows34 | Group-Object Status | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' ')

$log34 = Get-Log $d34
Assert 'and nothing is reported as an error' `
    (@($log34 | Where-Object { $_ -match '\[ERROR\]' }).Count -eq 0) `
    (($log34 | Where-Object { $_ -match '\[ERROR\]' }) -join ' | ')
Assert 'the run says why it could not prove anything, once' `
    (@($log34 | Where-Object { $_ -match 'below the 64 MB at which this build is expected to allocate' }).Count -eq 1) `
    (($log34 | Where-Object { $_ -match 'allocate' }) -join ' | ')

$sum34 = Get-Summary $d34
Assert 'the summary reports it as inconclusive, not as a fault and not as OK' `
    ($null -ne $sum34 -and $sum34.Status -eq 'MetricInconclusive' -and
     $sum34.MetricValidation -eq 'Inconclusive') `
    ('got [' + $(if ($sum34) { $sum34.Status + '/' + $sum34.MetricValidation } else { 'n/a' }) + ']')
Assert 'and it publishes the bar it used and where the bar came from' `
    ($null -ne $sum34 -and $sum34.AllocationEvidenceMB -eq 64 -and
     $sum34.AllocationEvidenceBasis -eq 'Configured' -and
     $sum34.NotAllocated -eq 15 -and $sum34.NotPopulated -eq 0) `
    ('got ' + $(if ($sum34) { '' + $sum34.AllocationEvidenceMB + '/' + $sum34.AllocationEvidenceBasis +
                              ' notalloc=' + $sum34.NotAllocated + ' notpop=' + $sum34.NotPopulated } else { 'n/a' }))

Write-Host ''
Write-Host 'T35  a genuine outage still reads as one' -ForegroundColor Cyan
# The other half of the same guarantee, and the more important half: making the
# monitor quieter is only correct if it stays loud where it should be. Same
# MOCK_NOTPOPULATED=all as T34, at the default 5.2 GB - unarguably large enough
# to have allocated a table. T28 already asserts the exit code and Status here;
# this adds the verdict fields, which are what a consumer now reads to tell a
# blind run from a small one.
$d35 = Reset-Dir '_t35'
$rc = Invoke-Monitor -OutputPath $d35 -Extra '-ExitNonZeroOnAlert' -WithEnv @{ MOCK_NOTPOPULATED = 'all' }
Assert 'large mailboxes reading 0 B still exit 5' ($rc -eq 5) ('got exit ' + $rc)
$sum35 = Get-Summary $d35
Assert 'and are still called a metric outage, explicitly Blind' `
    ($null -ne $sum35 -and $sum35.Status -eq 'MetricUnavailable' -and
     $sum35.MetricValidation -eq 'Blind' -and
     $sum35.NotPopulated -eq 15 -and $sum35.NotAllocated -eq 0) `
    ('got [' + $(if ($sum35) { $sum35.Status + '/' + $sum35.MetricValidation +
                               ' notpop=' + $sum35.NotPopulated + ' notalloc=' + $sum35.NotAllocated } else { 'n/a' }) + ']')
Assert 'the ERROR pair is intact' `
    (@(Get-Log $d35 | Where-Object { $_ -match '\[ERROR\].*Treat the thresholds here as untested' }).Count -eq 1) `
    ((Get-Log $d35 | Where-Object { $_ -match '\[ERROR\]' }) -join ' | ')

Write-Host ''
Write-Host 'T36  the bar is measured off the estate, not assumed' -ForegroundColor Cyan
# Where any mailbox has a populated table, the smallest such mailbox is a direct
# observation of this build's allocation point and beats the configured
# constant - the same move -ThresholdMode Adaptive already makes.
#
# It also exercises the 16 MB clamp. The populated mailboxes here hold 4 MB of
# content, which as a bar would be a lie: a mailbox that was large when the
# table was allocated and has since been emptied is a lower bound, not the
# allocation point. Unclamped it would drag the bar to 4 MB and reclassify the
# zero-readers as NotPopulated, manufacturing the very outage T34 removed.
$d36 = Reset-Dir '_t36'
$rc = Invoke-Monitor -OutputPath $d36 -WithEnv @{ MOCK_NOTPOPULATED = 'partial'; MOCK_MAILBOX_MB = '4' }
Assert 'the run completes' ($rc -eq 0) ('got exit ' + $rc)
$sum36 = Get-Summary $d36
Assert 'one populated table is enough to confirm the counter works' `
    ($null -ne $sum36 -and $sum36.MetricValidation -eq 'Confirmed' -and
     $sum36.Status -notin @('MetricUnavailable', 'MetricInconclusive')) `
    ('got [' + $(if ($sum36) { $sum36.MetricValidation + '/' + $sum36.Status } else { 'n/a' }) + ']')
Assert 'the bar is observed from the population and clamped to the 16 MB floor' `
    ($null -ne $sum36 -and $sum36.AllocationEvidenceBasis -eq 'Observed' -and
     $sum36.AllocationEvidenceMB -eq 16) `
    ('got ' + $(if ($sum36) { '' + $sum36.AllocationEvidenceMB + '/' + $sum36.AllocationEvidenceBasis } else { 'n/a' }))
Assert 'and the zero-readers below it are expected, not flagged' `
    ($null -ne $sum36 -and $sum36.NotAllocated -eq 9 -and $sum36.NotPopulated -eq 0) `
    ('notalloc=' + $(if ($sum36) { $sum36.NotAllocated } else { 'n/a' }) +
     ' notpop=' + $(if ($sum36) { $sum36.NotPopulated } else { 'n/a' }))

Write-Host ''
Write-Host 'T37  a mailbox whose size cannot be read is not accused' -ForegroundColor Cyan
# TotalItemSize is absent, Unlimited or malformed often enough to matter, and the
# size test has to fail in the benign direction: a wrong "nothing is wrong" on
# one row is recoverable, a wrong "your monitoring is blind" on the run trains
# people to ignore the message.
#
# It also covers the collection guard. Convert-ExchangeSizeToBytes throws on a
# value it cannot parse, which is correct for the posting list table and wrong
# here - unguarded it would take out the whole row, and on a database where
# every row threw, the whole database. The evaluated count is the assertion that
# matters: the rows have to survive.
$d37 = Reset-Dir '_t37'
$rc = Invoke-Monitor -OutputPath $d37 -Extra '-ExitNonZeroOnAlert' `
      -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_MAILBOX_MB = 'garbage' }
Assert 'an unreadable size does not raise an alert exit code' ($rc -eq 0) ('got exit ' + $rc)
$sum37 = Get-Summary $d37
Assert 'and does not cost the rows' `
    ($null -ne $sum37 -and $sum37.MailboxesEvaluated -eq 15) `
    ('evaluated=' + $(if ($sum37) { $sum37.MailboxesEvaluated } else { 'n/a' }))
Assert 'unjudgeable mailboxes are NotAllocated, never NotPopulated' `
    (@(Get-Csv $d37 | Where-Object { $_.Status -eq 'NotAllocated' }).Count -eq 15 -and
     @(Get-Csv $d37 | Where-Object { $_.Status -eq 'NotPopulated' }).Count -eq 0) `
    ((Get-Csv $d37 | Group-Object Status | ForEach-Object { $_.Name + '=' + $_.Count }) -join ' ')
Assert 'and the run does not claim to be blind on evidence it does not have' `
    ($null -ne $sum37 -and $sum37.MetricValidation -eq 'Inconclusive') `
    ('got [' + $(if ($sum37) { $sum37.MetricValidation } else { 'n/a' }) + ']')

Write-Host ''
Write-Host 'T38  the store binding is declared, and it is never the snap-in' -ForegroundColor Cyan
# The snap-in binds the store in-process and cannot read a database mounted on
# another DAG member, so a -Scope All run under it reports a subset of the estate
# as though it were all of it, with no error to say so. Measured on a 3-node DAG,
# same server and minute: 50 mailboxes across 2 of 4 databases under the snap-in,
# 97 across all 4 through a runspace.
#
# The mock module supplies the cmdlets as functions, which is the same shape an
# already-imported runspace has, so this also covers the reuse path that lets the
# monitor run from an Exchange Management Shell console without opening a second
# session.
$d38 = Reset-Dir '_t38'
$rc = Invoke-Monitor -OutputPath $d38
Assert 'a session that already has the cmdlets is reused, not rebound' ($rc -eq 0) ('got exit ' + $rc)
$sum38 = Get-Summary $d38
Assert 'and the run publishes which binding it used' `
    ($null -ne $sum38 -and $sum38.Binding -eq 'Existing') `
    ('got [' + $(if ($sum38) { $sum38.Binding } else { 'n/a' }) + ']')
Assert 'along with the runspace it would otherwise have opened' `
    ($null -ne $sum38 -and $sum38.ConnectionUri -match '^http://.+/PowerShell/$') `
    ('got [' + $(if ($sum38) { $sum38.ConnectionUri } else { 'n/a' }) + ']')
Assert 'and no run reports having found the snap-in loaded' `
    (@(Get-Log $d38 | Where-Object { $_ -match 'snap-in is loaded' }).Count -eq 0) ''
# Static, deliberately. The assertions above show this build does not reach for
# the snap-in. This one shows the next build cannot either, and it does not need
# a DAG to demonstrate it on. The comment text is stripped before matching,
# because the code explains at length why the snap-in is refused and naming it
# in a comment is not the same as calling it.
Assert 'the script carries no Add-PSSnapin call at all' `
    (@(Get-Content -LiteralPath $monitor |
       Where-Object { ($_ -replace '#.*$', '') -match 'Add-PSSnapin' }).Count -eq 0) ''

Write-Host ''
Write-Host 'T39  every scheduled-task example registers a task that can actually run' -ForegroundColor Cyan
# Static, for the same reason T38's last case is. This one is not about the
# monitor's behaviour at all - it is about the three places the registration
# command is printed, and it exists because all three were wrong at once.
#
# Measured on a lab DAG member, same account and argument string, three
# registrations minutes apart:
#   -User alone          -> LogonType Interactive. Never runs. LastTaskResult
#                           0x41303, no log file, no output directory.
#   -LogonType S4U       -> runs, cannot open the Exchange runspace, exit 3.
#   -User with -Password -> LogonType Password. Runspace opens, exit 0.
# Only the third is a monitor. Nothing warns you about the other two, which is
# what makes a copied-and-pasted example worth guarding.
$docs = @($monitor, (Join-Path $root 'BigFunnel PostingListTable Runbook.md'))

function Get-CommandBlocks {
    # A window rather than a parser: these are continued commands in markdown and
    # in comment-based help, so there is no reliable end token to match on.
    param([string]$Path, [string]$Opening, [int]$Window = 7)
    $lines = @(Get-Content -LiteralPath $Path)
    $out = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $Opening) {
            $end = [Math]::Min($i + $Window, $lines.Count - 1)
            $out += ($lines[$i..$end] -join ' ')
        }
    }
    return $out
}

$regBlocks = @()
$actBlocks = @()
foreach ($doc in $docs) {
    # Anchored at the start of the line so this matches invocations only. The
    # runbook also names Register-ScheduledTask mid-sentence when explaining what
    # goes wrong, and those paragraphs quote the wrong form on purpose.
    $regBlocks += Get-CommandBlocks -Path $doc -Opening '^\s*Register-ScheduledTask'
    $actBlocks += Get-CommandBlocks -Path $doc -Opening 'New-ScheduledTaskAction' -Window 5
}

Assert 'the examples are still there to check' ($regBlocks.Count -ge 2) `
    ('found ' + $regBlocks.Count + ' Register-ScheduledTask examples')

$noPassword = @($regBlocks | Where-Object { $_ -notmatch '-Password' })
Assert 'no example registers a principal without -Password' ($noPassword.Count -eq 0) `
    ('first offender: ' + $(if ($noPassword.Count) { $noPassword[0].Substring(0, [Math]::Min(90, $noPassword[0].Length)) } else { '' }))

$s4u = @($regBlocks | Where-Object { $_ -match '-LogonType\s+S4U' })
Assert 'and none registers S4U, which cannot open the runspace' ($s4u.Count -eq 0) ''

$viaCommand = @($actBlocks | Where-Object { $_ -match '\s-Command\b' })
Assert 'every task action launches the script with -File, never -Command' ($viaCommand.Count -eq 0) `
    ('first offender: ' + $(if ($viaCommand.Count) { $viaCommand[0].Substring(0, [Math]::Min(90, $viaCommand[0].Length)) } else { '' }))

# The guard above keeps the command right. This one keeps the explanation of why
# it has to be, so a future edit cannot quietly drop the reasoning and leave the
# next reader to rediscover it on a live estate.
$runbook = Get-Content -LiteralPath (Join-Path $root 'BigFunnel PostingListTable Runbook.md') -Raw
Assert 'and the runbook still explains why the logon type decides it' `
    ($runbook -match 'The logon type is load-bearing' -and $runbook -match '0x41303') ''

Write-Host ''
Write-Host 'T40  Status reports the finding, not just whether the run worked' -ForegroundColor Cyan
# Status described only whether the run completed, so a run that found a critical
# mailbox published Critical 1, Warning 1, ExitCode 1 and Status OK side by side.
# Measured on w25-ex01 at v1.7.1, which is where it was caught. Every integration
# note in the runbook says to alert when Status is not OK, so the field went
# silent on the one condition the script exists to detect.
#
# The rest of the suite now asserts Alert and Emerging where they belong. What is
# left to pin down here is the contract around them: OK still means OK, and the
# field does not depend on the exit-code switch.

# A run with nothing to report must still say so, or the fix has traded a false
# negative for a false positive and the field is worthless either way.
$d40 = Reset-Dir '_t40'
$rc = Invoke-Monitor -OutputPath $d40 -Extra '-WarningGB 3.5 -CriticalGB 4.0'
Assert 'a run with no findings exits 0' ($rc -eq 0) ('got exit ' + $rc)
$sum40 = Get-Summary $d40
Assert 'and still says OK' `
    ($null -ne $sum40 -and $sum40.Status -eq 'OK') `
    ('got [' + $(if ($sum40) { $sum40.Status } else { 'n/a' }) + ']')
Assert 'because it genuinely found nothing' `
    ($null -ne $sum40 -and $sum40.Critical -eq 0 -and $sum40.Warning -eq 0 -and $sum40.Emerging -eq 0) `
    ('crit=' + $(if ($sum40) { $sum40.Critical } else { 'n/a' }) +
     ' warn=' + $(if ($sum40) { $sum40.Warning } else { 'n/a' }) +
     ' emerging=' + $(if ($sum40) { $sum40.Emerging } else { 'n/a' }))

# -ExitNonZeroOnAlert is an opt-in for the exit code only. The summary file is
# the record of what the run found, and a run at defaults is the common case: if
# Status were gated too, the default deployment would be back where it started.
$d40b = Reset-Dir '_t40b'
$rc = Invoke-Monitor -OutputPath $d40b
Assert 'the same estate at defaults exits 0' ($rc -eq 0) ('got exit ' + $rc)
$sum40b = Get-Summary $d40b

$d40c = Reset-Dir '_t40c'
$rc = Invoke-Monitor -OutputPath $d40c -Extra '-ExitNonZeroOnAlert'
Assert 'and exits 1 with the switch' ($rc -eq 1) ('got exit ' + $rc)
$sum40c = Get-Summary $d40c

Assert 'but Status is Alert either way, because the switch only moves the exit code' `
    ($null -ne $sum40b -and $null -ne $sum40c -and
     $sum40b.Status -eq 'Alert' -and $sum40c.Status -eq 'Alert') `
    ('defaults=[' + $(if ($sum40b) { $sum40b.Status } else { 'n/a' }) +
     '] switched=[' + $(if ($sum40c) { $sum40c.Status } else { 'n/a' }) + ']')
Assert 'and the counts beside it agree on both runs' `
    ($null -ne $sum40b -and $null -ne $sum40c -and
     $sum40b.Critical -eq $sum40c.Critical -and $sum40b.Warning -eq $sum40c.Warning -and
     $sum40b.Critical -gt 0) `
    ('defaults=' + $(if ($sum40b) { '' + $sum40b.Critical + '/' + $sum40b.Warning } else { 'n/a' }) +
     ' switched=' + $(if ($sum40c) { '' + $sum40c.Critical + '/' + $sum40c.Warning } else { 'n/a' }))

# Precedence. A run that did not collect its whole scope is not entitled to
# report what it found as the answer, however alarming the part it did collect.
$d40d = Reset-Dir '_t40d'
$rc = Invoke-Monitor -OutputPath $d40d -Extra '-ExitNonZeroOnAlert' -WithEnv @{ MOCK_FAIL_DB = 'MDB02' }
Assert 'an incomplete collection exits 2 even with breaches in the part it read' ($rc -eq 2) ('got exit ' + $rc)
$sum40d = Get-Summary $d40d
Assert 'and Partial outranks Alert, matching the exit code again' `
    ($null -ne $sum40d -and $sum40d.Status -eq 'Partial' -and
     ($sum40d.Critical + $sum40d.Warning) -gt 0) `
    ('status=[' + $(if ($sum40d) { $sum40d.Status } else { 'n/a' }) +
     '] atrisk=' + $(if ($sum40d) { $sum40d.Critical + $sum40d.Warning } else { 'n/a' }))

Write-Host ''
Write-Host 'T41  a run that cannot publish its verdict is not a healthy run' -ForegroundColor Cyan
# Measured on w25-ex01. A non-elevated session could create its own timestamped
# CSV and log in C:\ProgramData\ExchangeBigFunnelPostingListMonitor, but could
# not overwrite a latest.csv and latest-summary.json owned by
# BUILTIN\Administrators from an earlier elevated run. The run warned twice and
# exited 0, leaving a summary 19 hours stale that still read Status OK. Anything
# alerting on that file was reading yesterday's verdict with no way to tell.
# Collection succeeding is not the same as the result reaching the two files a
# scheduled consumer actually polls.
$d41 = Reset-Dir '_t41'
$rc = Invoke-Monitor -OutputPath $d41
$sum41 = Get-Summary $d41
Assert 'a healthy run publishes cleanly and says so' `
    ($rc -eq 0 -and $null -ne $sum41 -and [string]::IsNullOrEmpty($sum41.PublishErrors)) `
    ('exit ' + $rc + ' errors=[' + $(if ($sum41) { $sum41.PublishErrors } else { 'n/a' }) + ']')

# latest.csv held open exclusively. A read-only attribute would not do it -
# Copy-Item -Force overwrites those quite happily, which is exactly the sort of
# test that passes while proving nothing.
$latest41 = Join-Path $d41 'latest.csv'
$fs = [System.IO.File]::Open($latest41, 'Open', 'ReadWrite', 'None')
try { $rc = Invoke-Monitor -OutputPath $d41 } finally { $fs.Close(); $fs.Dispose() }
$sum41b = Get-Summary $d41
Assert 'an unrefreshable latest.csv exits 3, not 0' ($rc -eq 3) ('got exit ' + $rc)
Assert 'and the summary calls it PublishFailed' `
    ($null -ne $sum41b -and $sum41b.Status -eq 'PublishFailed' -and $sum41b.ExitCode -eq 3) `
    ('status=[' + $(if ($sum41b) { $sum41b.Status } else { 'n/a' }) +
     '] exitcode=' + $(if ($sum41b) { $sum41b.ExitCode } else { 'n/a' }))
Assert 'and names which file failed and why' `
    ($null -ne $sum41b -and $sum41b.PublishErrors -match 'latest\.csv') `
    ('errors=[' + $(if ($sum41b) { $sum41b.PublishErrors } else { 'n/a' }) + ']')
# The collection itself was fine. The point is that a good collection does not
# rescue a run whose result never reached the consumer.
Assert 'while the collection behind it still succeeded' `
    ($null -ne $sum41b -and $sum41b.MailboxesEvaluated -eq 15) `
    ('evaluated=' + $(if ($sum41b) { $sum41b.MailboxesEvaluated } else { 'n/a' }))

# The summary itself unwritable. This is the case the file cannot report about
# itself, so the exit code is the only channel left.
$json41 = Join-Path $d41 'latest-summary.json'
$before = (Get-Summary $d41).RunId
Set-ItemProperty -LiteralPath $json41 -Name IsReadOnly -Value $true
try { $rc = Invoke-Monitor -OutputPath $d41 }
finally { Set-ItemProperty -LiteralPath $json41 -Name IsReadOnly -Value $false }
Assert 'an unwritable summary exits 3' ($rc -eq 3) ('got exit ' + $rc)
Assert 'and the stale summary on disk is left describing the earlier run' `
    ((Get-Summary $d41).RunId -eq $before) `
    ('runid moved from ' + $before + ' to ' + (Get-Summary $d41).RunId)
Assert 'and the log says the verdict was never published' `
    (@(Get-Log $d41 | Where-Object { $_ -match 'could not be published' }).Count -ge 1) `
    ((Get-Log $d41 | Where-Object { $_ -match 'summary' }) -join ' | ')

# Regression guard for the documented legitimate case. A run that collected no
# rows deliberately leaves latest.csv alone; that skip is not a publish failure
# and must not start exiting 3.
$d41e = Reset-Dir '_t41e'
$rc = Invoke-Monitor -OutputPath $d41e
$rc = Invoke-Monitor -OutputPath $d41e -WithEnv @{ MOCK_EMPTY = '1' }
$sum41e = Get-Summary $d41e
Assert 'a deliberate skip of latest.csv is still not a publish failure' `
    ($rc -ne 3 -and $null -ne $sum41e -and [string]::IsNullOrEmpty($sum41e.PublishErrors)) `
    ('exit ' + $rc + ' errors=[' + $(if ($sum41e) { $sum41e.PublishErrors } else { 'n/a' }) + ']')

Write-Host ''
Write-Host 'T42  the elevation gate, and the honesty of opting out of it' -ForegroundColor Cyan
# The suite runs unelevated, so every case here reaches the gate with a split
# token. That also means none of them may let the gate fire: a consent prompt in
# an automated run blocks Start-Process -Wait until somebody answers it. What is
# reachable without a prompt is the -NoElevate path and the guarantee behind it,
# which is that opting out degrades into a visible failure and never a silent
# success. The relaunch itself is covered by T43 and by reading the source below.
$d42 = Reset-Dir '_t42'
$rc = Invoke-Monitor -OutputPath $d42
$sum42 = Get-Summary $d42
Assert '-NoElevate runs to completion without attempting a relaunch' `
    ($rc -eq 0 -and (Get-Warnings) -notmatch 'Relaunching elevated') `
    ('exit ' + $rc + ' warnings=[' + (Get-Warnings) + ']')
Assert 'and the summary records whether the run that published was elevated' `
    ($null -ne $sum42 -and $sum42.PSObject.Properties.Name -contains 'Elevated' -and
     $sum42.Elevated -eq $false) `
    ('field=' + ($sum42.PSObject.Properties.Name -contains 'Elevated') +
     ' value=' + $(if ($sum42) { $sum42.Elevated } else { 'n/a' }))

# The real w25-ex01 case: an ACL that denies this account the two stable files.
# Elevating is what fixes it, so -NoElevate is an operator saying "do not ask me,
# I know what I am doing" - and the contract is that they still find out.
$d42b = Reset-Dir '_t42b'
$rc = Invoke-Monitor -OutputPath $d42b
$latest42b = Join-Path $d42b 'latest.csv'
& icacls.exe $latest42b '/deny' ($env:USERNAME + ':(W)') 2>&1 | Out-Null
try { $rc = Invoke-Monitor -OutputPath $d42b }
finally { & icacls.exe $latest42b '/remove:d' $env:USERNAME 2>&1 | Out-Null }
Assert 'an ACL denial under -NoElevate exits 3 instead of reporting success' `
    ($rc -eq 3) ('got exit ' + $rc)
$sum42b = Get-Summary $d42b
Assert 'with the reason recorded against the file that refused the write' `
    ($null -ne $sum42b -and $sum42b.PublishErrors -match 'latest\.csv') `
    ('errors=[' + $(if ($sum42b) { $sum42b.PublishErrors } else { 'n/a' }) + ']')

# Read from the source because the behaviour cannot be provoked here, and both
# of these regress silently. Dropping -Wait turns every relaunch into an
# immediate exit 0, which is the exact defect v1.7.3 was written to remove;
# dropping the UserInteractive guard turns a scheduled non-elevated task from a
# warning into a hang on a prompt with no desktop to show it.
$src42 = Get-Content -LiteralPath $monitor -Raw
$gate42 = [regex]::Match($src42, '(?s)#region elevation.*?#endregion elevation').Value
Assert 'the gate fires on nothing more than "not administrator, not opted out"' `
    ($gate42 -match '\$script:Elevated\s*=\s*Test-IsElevated' -and
     $gate42 -match 'if\s*\(-not\s*\$script:Elevated\s*-and\s*-not\s*\$NoElevate\)') `
    'expected the plain two-term condition'
Assert 'it waits for the child, so the exit code is the child''s and not 0' `
    ($gate42 -match 'Start-Process[^\r\n]*-Verb RunAs[^\r\n]*-Wait' -and $gate42 -match 'exit \$rc') `
    'expected -Wait on the relaunch and exit $rc after it'
Assert 'and a non-interactive session is warned rather than left on a prompt' `
    ($gate42 -match '\[Environment\]::UserInteractive' -and $gate42 -match 'RunLevel Highest') `
    'expected the non-interactive branch to name -RunLevel Highest'

# The scenario harness drives the monitor several times into a directory it owns
# under -WorkPath. If it ever stops passing -NoElevate, a demo that used to run
# unattended starts asking for consent once per scenario.
$scenario42 = Join-Path (Split-Path -Parent $monitor) 'Invoke-BigFunnelScenario.ps1'
Assert 'the scenario harness opts its child monitor runs out of elevation' `
    ((Test-Path -LiteralPath $scenario42) -and
     (Get-Content -LiteralPath $scenario42 -Raw) -match "ConvertTo-MonitorArgs[\s\S]*?\`$argv\.Add\('-NoElevate'\)") `
    ('scenario present: ' + (Test-Path -LiteralPath $scenario42))

Write-Host ''
Write-Host 'T43  the elevated child is relaunched with the same run, not a similar one' -ForegroundColor Cyan
# The relaunch itself needs a consent prompt, so it cannot be driven from a test
# run. The part that can go wrong silently can be: if the rebuilt command line
# drops -CriticalGB, the elevated child collects happily and reports against the
# wrong threshold, and nothing in the output says so. So the builder is lifted
# out of the script by name and exercised directly.
$fnAst = [System.Management.Automation.Language.Parser]::ParseFile($monitor, [ref]$null, [ref]$null).
         FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                              $n.Name -eq 'ConvertTo-RelaunchArguments' }, $true)
Assert 'the argument builder is still there to test' ($fnAst.Count -eq 1) ('found ' + $fnAst.Count)
if ($fnAst.Count -eq 1) {
    . ([scriptblock]::Create($fnAst[0].Extent.Text))

    $bound = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $bound['Databases']          = @('DB one', 'DB two')
    $bound['CriticalGB']         = 2.5
    $bound['Scope']              = 'All'
    $bound['OutputPath']         = 'C:\Program Files\bf out\'
    $bound['ExitNonZeroOnAlert'] = [System.Management.Automation.SwitchParameter]::Present
    $bound['NoElevate']          = [System.Management.Automation.SwitchParameter]::Present
    $line = ConvertTo-RelaunchArguments $bound -Exclude 'NoElevate'

    Assert 'a threshold crosses intact, so the child judges by the same numbers' `
        ($line -match '-CriticalGB "2\.5"') $line
    Assert 'a value with a space stays one argument' `
        ($line -match '-Scope "All"') $line
    # Deliberately ONE quoted token, not -Databases "DB one","DB two". The
    # earlier spelling reads better and does not work: powershell.exe -File does
    # not split comma lists, so the child received the whole thing as a single
    # element either way. Joining first and quoting once is the honest spelling
    # of what actually crosses, and the only form that survives a value with a
    # space in it. The round trip below is what proves it.
    Assert 'an array crosses as one argument, because -File cannot carry more' `
        ($line -match '-Databases "DB one,DB two"') $line
    # A trailing backslash would escape the closing quote when Windows splits
    # the child's command line, swallowing whatever argument came next.
    Assert 'a path ending in a separator cannot escape its own closing quote' `
        (($line -match '-OutputPath "C:\\Program Files\\bf out"') -and ($line -notmatch 'out\\"')) $line
    Assert 'a switch crosses as a switch, with no value appended' `
        (($line -match '-ExitNonZeroOnAlert(\s|$)') -and ($line -notmatch '-ExitNonZeroOnAlert "')) $line
    # Passing it on would be harmless but dishonest: the child is elevated, so
    # the gate never runs there, and the line should describe what it does.
    # Excluded by the caller now rather than hardcoded here, because the task
    # registration reuses this builder and excludes a different set.
    Assert 'and -NoElevate is not passed on to a child that is already elevated' `
        ($line -notmatch 'NoElevate') $line

    # And the half that reads the line back. Lifted the same way, because the
    # two are one mechanism: the builder writes an argument string and this
    # re-splits it, and testing either alone proves nothing about the pair.
    $splitAst = [System.Management.Automation.Language.Parser]::ParseFile($monitor, [ref]$null, [ref]$null).
                FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                                      $n.Name -eq 'Split-BoundList' }, $true)
    Assert 'the list splitter is there to test too' ($splitAst.Count -eq 1) ('found ' + $splitAst.Count)
    if ($splitAst.Count -eq 1) {
        . ([scriptblock]::Create($splitAst[0].Extent.Text))
        Assert 'it recovers both names from what -File actually delivers' `
            (((Split-BoundList 'DB one,DB two') -join '/') -eq 'DB one/DB two')
        Assert 'splitting a real array is a no-op, so an interactive caller is unaffected' `
            (((Split-BoundList @('DB one', 'DB two')) -join '/') -eq 'DB one/DB two')
        Assert 'an unbound parameter stays empty rather than becoming one blank entry' `
            ((Split-BoundList $null).Count -eq 0)
        Assert 'and stray whitespace around a separator does not become a database name' `
            (((Split-BoundList 'DB one , DB two ,') -join '/') -eq 'DB one/DB two')
    }
}

Write-Host ''
Write-Host 'T43b a list parameter survives the process boundary it is sent across' -ForegroundColor Cyan
# T43 checks the two halves. This checks the whole thing, through a real
# Start-Process -File, which is how BOTH the elevation relaunch and the
# registered scheduled task invoke this script.
#
# It exists because the assertion it replaces passed for four versions while the
# defect was live. That assertion checked the SHAPE of the generated string and
# never handed it to a child, so it could not distinguish an encoding that reads
# correctly from one that survives. Measured, the old encoding did not: the
# child bound -Databases to a single element, the string 'DB one,DB two', found
# no database by that name, and fell through to discovering every database
# instead - a silently wrong scope on an otherwise clean-looking run.
#
# Two nonexistent names, because the monitor logs one line per requested
# database it cannot find. Two lines means the list was split; one line naming
# them both together means it was not.
$d43b  = Reset-Dir '_t43b'
$rc43b = Invoke-Monitor -OutputPath $d43b -Extra '-Databases "No Such DB one,No Such DB two"'
$log43b = (Get-Log $d43b) -join "`n"

Assert 'both names arrive as separate databases, not as one string containing a comma' `
    (($log43b -match 'Database \[No Such DB one\]') -and ($log43b -match 'Database \[No Such DB two\]')) $log43b
Assert 'and neither is reported under the joined name the command line carried' `
    ($log43b -notmatch 'No Such DB one,No Such DB two') $log43b
Assert 'a name with a space in it still arrives intact' `
    ($log43b -notmatch 'Database \[No\]') $log43b

Write-Host ''
Write-Host 'T44  what a run says on screen when nobody asked it to say anything' -ForegroundColor Cyan
$d44  = Reset-Dir '_t44'
$rc44 = Invoke-Monitor -OutputPath $d44
$out44 = Get-Stdout
$t44   = ($out44 -join "`n")
$log44 = Get-Log $d44
$sum44 = Get-Summary $d44

Assert 'a default run reaches a verdict on screen without -Verbose' `
    ($t44 -match 'RESULT\s+\w+') $t44
Assert 'and identifies which version reached it' `
    ($t44 -match 'PostingListTable monitor v\d+\.\d+\.\d+') $t44
Assert 'and names each database as it is collected, with what it found there' `
    (($t44 -match 'MDB01\.+\s+\d+ mailbox') -and ($t44 -match 'MDB03\.+\s+\d+ mailbox')) $t44
Assert 'and points at both files it just wrote' `
    (($t44 -match 'Report\s+\S+\.csv') -and ($t44 -match 'Log\s+\S+\.log')) $t44
Assert 'and states the exit code it is about to return' `
    ($t44 -match ('Exit code ' + $rc44)) $t44

# The flood guard. -MaxAlertDetail allows 25 per-mailbox lines per category and
# there are four categories, so echoing them would push the verdict a hundred
# lines off the top of the window on exactly the estate that needs reading.
$rowLines = @($log44 | Where-Object { $_ -match '\[WARN\]\s+(Critical|Warning): \[' })
Assert 'per-mailbox findings are written to the log' `
    ($rowLines.Count -gt 0) ('log rows: ' + $rowLines.Count)
Assert 'but are kept off the console, where they would bury the verdict' `
    ($t44 -notmatch '(Critical|Warning): \[') $t44

# Kept off, not hidden: an operator who cannot see WHICH mailbox has to open the
# CSV before they know whether to care.
$worst = @($out44 | Where-Object { $_ -match '^\s+(Critical|Warning)\s+.+\sGB(\s\s\S.*)?$' })
Assert 'the worst affected are still named, bounded to three' `
    (($worst.Count -gt 0) -and ($worst.Count -le 3)) ('worst rows: ' + $worst.Count)
Assert 'and the console says how many more it did not show' `
    ($t44 -match 'and \d+ more in the report below') $t44
# Above ten posting-list mailboxes the roll call collapses to a count, so this
# block is the only place a finding gets named - and a name with no rate beside
# it would mean the bigger the estate, the less the report says about growth.
# This run has no baseline, so what the tail has to carry is the absence.
Assert 'and each carries a growth annotation, not a bare size' `
    (@($worst | Where-Object { $_ -match 'GB\s\s(no rate yet|not growing|\+[\d.]+ GB/day)' }).Count -eq $worst.Count) `
    ($worst -join "`n")

# Alert above a zero reads as a contradiction, and both halves are correct.
Assert 'a finding reported above exit code 0 is explained, not left contradictory' `
    (($rc44 -ne 0) -or ($t44 -match 'ExitNonZeroOnAlert was not passed')) $t44

$d44q   = Reset-Dir '_t44q'
$rc44q  = Invoke-Monitor -OutputPath $d44q -Extra '-Quiet'
$out44q = Get-Stdout
$sum44q = Get-Summary $d44q

Assert '-Quiet leaves the console completely empty' `
    (@($out44q | Where-Object { $_.Trim() -ne '' }).Count -eq 0) ($out44q -join '|')
Assert 'and suppresses decoration, never evidence: the exit code is unchanged' `
    ($rc44q -eq $rc44) ('quiet ' + $rc44q + ' vs ' + $rc44)
Assert 'and the summary still reaches disk carrying the same verdict' `
    (($null -ne $sum44q) -and ($null -ne $sum44) -and ($sum44q.Status -eq $sum44.Status)) `
    ('quiet ' + $sum44q.Status + ' vs ' + $sum44.Status)
Assert 'and the log is written exactly as it would have been' `
    ((Get-Log $d44q).Count -gt 0)

$d44v  = Reset-Dir '_t44v'
$null  = Invoke-Monitor -OutputPath $d44v -Extra '-Verbose'
$t44v  = ((Get-Stdout) -join "`n")
$both  = Get-Warnings

# The half of the old behaviour that was wrong was not that -Verbose showed too
# much - it is that it was the only channel there was.
Assert '-Verbose adds the log stream underneath the report rather than replacing it' `
    (($t44v -match 'RESULT\s+\w+') -and ($both -match 'VERBOSE: \d{4}-\d{2}-\d{2}')) $t44v

Write-Host ''
Write-Host 'T45  the default scope answers for the DAG, not for this node' -ForegroundColor Cyan
# The estate where the distinction is visible: every active copy is mounted
# somewhere other than the node running the script. Under the old Local default
# this run found nothing and exited 3 - which is what it looks like from a node
# that simply is not holding anything today.
$d45  = Reset-Dir '_t45'
$rc45 = Invoke-Monitor -OutputPath $d45 -WithEnv @{ MOCK_ACTIVE_ELSEWHERE = '1' }
$sum45 = Get-Summary $d45
$t45   = ((Get-Stdout) -join "`n")

Assert 'a run with no -Scope collects databases mounted on other nodes' `
    ($rc45 -eq 0) ('got exit ' + $rc45)
Assert 'and the summary records the scope it actually used' `
    (($null -ne $sum45) -and ($sum45.Scope -eq 'All')) ('got [' + $(if ($sum45) { $sum45.Scope } else { 'n/a' }) + ']')
Assert 'and it evaluated mailboxes rather than reporting an empty estate' `
    (($null -ne $sum45) -and ($sum45.MailboxesEvaluated -gt 0)) ('got ' + $(if ($sum45) { $sum45.MailboxesEvaluated } else { 'n/a' }))
# The console names the scope, so an operator can tell at a glance which
# question the numbers below it answer.
Assert 'and the console says which scope the count belongs to' `
    ($t45 -match 'Scope All - \d+ database\(s\) in scope') $t45

# The opposite half, on the identical estate: Local still declines them, which
# is what makes it worth passing explicitly for a per-node scheduled task.
$d45l  = Reset-Dir '_t45l'
$rc45l = Invoke-Monitor -OutputPath $d45l -Extra '-Scope Local' -WithEnv @{ MOCK_ACTIVE_ELSEWHERE = '1' }
Assert '-Scope Local on the same estate still collects nothing, deliberately' `
    ($rc45l -eq 3) ('got exit ' + $rc45l)
Assert 'and the log points at the default rather than just naming the problem' `
    (@(Get-Log $d45l | Where-Object { $_ -match 'the default is now All' }).Count -eq 1)

Write-Host ''
Write-Host 'T46  an incomplete run never reports a clean exit code' -ForegroundColor Cyan
# Every abort inside the main try sets 3 before it exits. The one that cannot is
# an interrupt: Ctrl+C is a pipeline stop rather than an exception, so it skips
# the catch, runs the finally, and leaves $exitCode at the 0 it started as.
# Observed on w25-ex01 - "RESULT Aborted" in red directly above "Exit code 0",
# and ExitCode 0 published beside Completed false, so a scheduler reading the
# exit code recorded a clean run that never collected a mailbox.
#
# Asserted at the source, because the trigger is a console interrupt this
# harness cannot deliver to a child process without also killing the finally
# block it is trying to test.
$src46 = Get-Content -LiteralPath $monitor -Raw
$fin46 = if ($src46 -match '(?s)if \(-not \$script:SummaryWritten\) \{(.{0,2000})') { $Matches[1] } else { '' }
Assert 'the abort block is still there to test' ($fin46 -ne '') 'finally block not matched'
Assert 'and coerces a zero exit code before it publishes the summary' `
    (($fin46 -match 'if \(\$exitCode -eq 0\) \{ \$exitCode = 3 \}') -and
     ($fin46.IndexOf('if ($exitCode -eq 0) { $exitCode = 3 }') -lt $fin46.IndexOf('Write-RunSummary'))) $fin46
# The existing abort paths must keep their own codes - the coercion is a floor
# for the interrupt case, not a blanket overwrite.
Assert 'an abort that already chose its exit code keeps it' `
    ($rc45l -eq 3) ('got exit ' + $rc45l)

Write-Host ''
Write-Host 'T47  the console says which mailboxes, and says it in fewer words' -ForegroundColor Cyan
# Two complaints about the same block of output, from an operator reading a real
# run: the mixed-counter explanation wrapped to five lines of prose immediately
# above the verdict, and the only thing it actually reported - that three
# mailboxes carry a posting list table - could not be turned into three names
# without opening a 32-column CSV.
#
# MOCK_NOTPOPULATED=partial is the mixed estate: rows 1 and 2 of each database
# keep a populated posting list table, the rest read 0 B, so both counters are
# in use on the same run.
$d47 = Reset-Dir '_t47'
$rc47 = Invoke-Monitor -OutputPath $d47 -WithEnv @{ MOCK_NOTPOPULATED = 'partial' }
$out47 = (Get-Stdout) -join "`n"
$log47 = (Get-Log $d47) -join "`n"

Assert 'the mixed-counter run completes' ($rc47 -eq 0) ('got exit ' + $rc47)

# The reasoning is not deleted, it is relocated. A shorter console that also
# lost the explanation would be a worse outcome than the wall of text.
Assert 'the full explanation is still written to the log' `
    ($log47 -match 'Growth on this run is split across two counters' -and
     $log47 -match 'Do not read a short Emerging list as the whole answer') $log47
Assert 'but the paragraph does not reach the console' `
    ($out47 -notmatch 'Do not read a short Emerging list as the whole answer') $out47
# Moved, not deleted. It used to print at collection time, above the verdict and
# roughly ten lines above any growth number - explaining how growth would be
# measured before anything had measured any. It now sits under the Growth
# heading, as a caveat on the rates directly beneath it.
Assert 'the console states the split instead, on its own line' `
    ($out47 -match 'Two counters in use: \d+ dated on BigFunnelPostingListTableTotalSize, \d+ ranked only on IndexPayloadBytes') $out47
$idxGrowth47 = $out47.IndexOf('Growth')
$idxSplit47  = $out47.IndexOf('Two counters in use')
$idxResult47 = $out47.IndexOf('RESULT')
Assert 'and it sits with the growth numbers rather than above the verdict' `
    ($idxGrowth47 -gt 0 -and $idxSplit47 -gt $idxGrowth47 -and $idxSplit47 -gt $idxResult47) `
    ('growth ' + $idxGrowth47 + ' split ' + $idxSplit47 + ' result ' + $idxResult47)

# The question the count raised. A run that says "3" and makes the operator go
# and find out which 3 has reported a number instead of an answer.
Assert 'the console names how many carry a posting list table, out of how many' `
    ($out47 -match 'Posting list table present on \d+ of \d+ mailbox\(es\)') $out47
$pl47 = @(Get-Csv $d47 | Where-Object { [int64]$_.PostingListBytes -gt 0 })
Assert 'the mock estate really is mixed, so the block above is being tested' `
    ($pl47.Count -gt 0 -and $pl47.Count -lt (Get-Csv $d47).Count) ('populated ' + $pl47.Count)
$named47 = @($pl47 | Where-Object { $out47.Contains($_.DisplayName) })
Assert 'and names every one of them on screen' `
    ($named47.Count -eq $pl47.Count) ('named ' + $named47.Count + ' of ' + $pl47.Count)
Assert 'with the size that made it worth naming' `
    ($out47 -match 'Ana Ilic on \S+\s+[\d.]+ GB') $out47

# Naming them made the block below it redundant. On this estate every at-risk
# mailbox is one of the few carrying a posting list table, so "Worst affected"
# reprinted the same two rows under a second heading - which is not emphasis,
# it is another thing to read before reaching the exit code.
$atRisk47 = @(Get-Csv $d47 | Where-Object { $_.Status -eq 'Critical' -or $_.Status -eq 'Warning' })
Assert 'the run really did find at-risk mailboxes, so the block could have printed' `
    ($atRisk47.Count -gt 0) ('at risk ' + $atRisk47.Count)
Assert 'and every one of them was named in the block above' `
    (@($atRisk47 | Where-Object { -not $out47.Contains($_.DisplayName) }).Count -eq 0) $out47
Assert 'so Worst affected is not printed a second time under a new heading' `
    ($out47 -notmatch 'Worst affected') $out47

# Self-suppressing, or the block becomes the report on a healthy estate where
# every mailbox has one. MOCK_BULK pushes the populated count past the bound.
$d47b = Reset-Dir '_t47b'
$null = Invoke-Monitor -OutputPath $d47b -WithEnv @{ MOCK_BULK = '20' }
$out47b = (Get-Stdout) -join "`n"
Assert 'a large populated estate gets a count rather than a roll call' `
    ($out47b -notmatch 'Posting list table present on' -and
     $out47b -match 'Posting list table\s+\d+ of \d+ mailbox\(es\) - see the report') $out47b
# The other half of the suppression above: with nothing named, the bounded
# sample has to come back, or removing the duplicate would have removed the
# only place the console says which mailboxes were found.
Assert 'and still gets the bounded Worst affected sample, since nothing was named' `
    ($out47b -match 'Worst affected') $out47b

Write-Host ''
Write-Host 'T48  the roll call names findings, not mailboxes that are fine' -ForegroundColor Cyan
# The same operator, one run later: on a healthy estate every row in the block
# T47 added reads Normal, so a block that exists to answer "which ones are a
# problem" spends three lines answering "none of them, here they are anyway".
# A Normal row is the absence of a finding and does not earn a line in a verdict
# block; the count above it already says how many carry the counter.
#
# One database, so the populated count stays inside the ten-row bound and the
# roll call actually prints. MDB01 alone gives five evaluated mailboxes: Ana
# critical, Bo warning, and three sitting under the 1.7 GB threshold.
$d48  = Reset-Dir '_t48'
$rc48 = Invoke-Monitor -OutputPath $d48 -Extra '-Databases MDB01'
$out48 = (Get-Stdout) -join "`n"

Assert 'the single-database run completes' ($rc48 -eq 0) ('got exit ' + $rc48)

$rows48   = @(Get-Csv $d48 | Where-Object { [int64]$_.PostingListBytes -gt 0 })
$normal48 = @($rows48 | Where-Object { $_.Status -eq 'Normal' })
$found48  = @($rows48 | Where-Object { $_.Status -ne 'Normal' })
Assert 'the estate under test really is mixed Normal and not, so this proves something' `
    ($normal48.Count -gt 0 -and $found48.Count -gt 0) `
    ('normal ' + $normal48.Count + ' findings ' + $found48.Count)

# The count is not what was objected to - it is one line, and it is the answer
# to "does anything here carry the counter at all".
Assert 'the count still prints on a run with nothing to name' `
    ($out48 -match 'Posting list table present on \d+ of \d+ mailbox\(es\)') $out48
Assert 'the mailboxes that are a finding are still named' `
    (@($found48 | Where-Object { -not $out48.Contains($_.DisplayName) }).Count -eq 0) $out48
# Matched on the roll call's own line shape rather than the bare name, so this
# does not pass or fail on some unrelated line that happens to mention it.
Assert 'and the Normal ones are not listed one per line' `
    ($out48 -notmatch '(?m)^\s+Normal\s+\S') $out48
# Held back, not hidden. "5 of 97" with two rows under it reads as a block that
# gave up halfway; saying how many were withheld, and how to see them, keeps the
# console honest about what it chose not to print.
Assert 'the console says how many it held back, and how to get them' `
    ($out48 -match ('\s' + $normal48.Count + ' reading Normal, not listed\. -Verbose lists them\.')) $out48

# The switch. -Verbose rather than a parameter of its own: the script already
# documents it as the lever for wanting more of the report.
$d48b = Reset-Dir '_t48b'
$null = Invoke-Monitor -OutputPath $d48b -Extra '-Databases MDB01 -Verbose'
$out48b = (Get-Stdout) -join "`n"
Assert '-Verbose lists the Normal rows, in the same shape as the rest' `
    ($out48b -match '(?m)^\s+Normal\s+Shared Helpdesk on MDB01\s+[\d.]+ GB') $out48b
Assert 'and then has nothing left to say it held back' `
    ($out48b -notmatch 'reading Normal, not listed') $out48b
Assert 'while the findings are still named, not replaced by the full list' `
    (@($found48 | Where-Object { -not $out48b.Contains($_.DisplayName) }).Count -eq 0) $out48b

Write-Host ''
Write-Host 'T49  the console reports growth, not just current size' -ForegroundColor Cyan
# Every other number in the verdict block is a current size: the counts are sizes
# against a threshold, the roll call is sizes, Worst affected is sizes. The
# script measures a rate for every trendable mailbox and projects a date for the
# ones the thresholds describe, and all of it went to the log and the CSV only -
# so a report whose entire justification is lead time never printed any lead
# time. Emerging was the one growth-derived figure on screen, and it is a count.

# A first run has nothing to difference against, and must say so rather than
# reporting no growth - which would be the script publishing a measurement it
# never took.
$d49 = Reset-Dir '_t49'
$rc49 = Invoke-Monitor -OutputPath $d49 -Extra '-WarningGB 3.0 -CriticalGB 3.5'
$out49 = (Get-Stdout) -join "`n"
Assert 'the seed run succeeds' ($rc49 -eq 0) ('got exit ' + $rc49)
Assert 'a first run says it has no baseline rather than reporting zero growth' `
    ($out49 -match 'No baseline old enough to measure against') $out49
Assert 'and does not claim a rate it could not have measured' `
    ($out49 -notmatch 'GB/day') $out49

# Now give it one. Rates are set per mailbox so the expected ordering is known
# and differs from size order - the mock scales growth with size, so without
# this the two orderings agree and the test cannot tell them apart.
$null = Set-RunAge -Dir $d49 -Hours 24
$base49 = @(Get-ChildItem -LiteralPath $d49 -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
$rows49 = @(Import-Csv -LiteralPath $base49.FullName)
foreach ($r in $rows49) {
    switch ($r.DisplayName) {
        # 1.20 GB now, was 0.20 - 1.00 GB/day, the fastest on the estate and
        # nowhere near the largest, which is the point.
        'Emerging Mbx' { $r.PostingListBytes = [string][int64](0.20 * 1GB) }
        # 2.40 GB now, was 2.00 - 0.40 GB/day. Twice the size, slower.
        'Ana Ilic'     { $r.PostingListBytes = [string][int64](2.00 * 1GB) }
        # 1.80 GB now, was 1.65 - 0.15 GB/day.
        'Bo Persson'   { $r.PostingListBytes = [string][int64](1.65 * 1GB) }
    }
}
$rows49 | Export-Csv -LiteralPath $base49.FullName -NoTypeInformation -Encoding UTF8

$rc49b = Invoke-Monitor -OutputPath $d49 -Extra '-WarningGB 3.0 -CriticalGB 3.5'
$out49b = (Get-Stdout) -join "`n"
Assert 'the trended run succeeds' ($rc49b -eq 0) ('got exit ' + $rc49b)

# A rate is meaningless without the window it was measured over and the run it
# was measured against - 0.02 GB/day off 40 hours and off 40 minutes are not the
# same claim, and the second is what produces a wild projection.
Assert 'the growth heading names the window and the baseline run' `
    ($out49b -match 'Growth\s+measured over [\d.]+h, against run \d{8}-\d{6}') $out49b
Assert 'and a rate in GB/day actually reaches the console' `
    ($out49b -match '(?m)^\s+\S.*\+[\d.]+ GB/day') $out49b
Assert 'with the projected date on rows the thresholds can describe' `
    ($out49b -match 'Emerging Mbx on \S+\s+[\d.]+ GB\s+\+[\d.]+ GB/day, critical in [\d.]+ day\(s\)') $out49b

# Ordered by rate, which is the only ordering this block can justify. Size order
# would duplicate the roll call directly above it.
#
# The rate is signed in the output. A bare number at the end of a line that
# already carries "1.2 GB" reads as a second size at a glance down the column,
# so the + is load-bearing rather than decoration - and matching on it here is
# what stops this regex also capturing the size.
$rates49 = @([regex]::Matches($out49b, '(?m)\+([\d.]+) GB/day') |
             ForEach-Object { [double]$_.Groups[1].Value })
Assert 'the block lists more than one mailbox, so ordering means something' `
    ($rates49.Count -ge 2) ('got ' + $rates49.Count + ' rows')
$desc49 = $true
for ($i = 1; $i -lt $rates49.Count; $i++) { if ($rates49[$i] -gt $rates49[$i - 1]) { $desc49 = $false } }
Assert 'and orders them fastest first' $desc49 ($rates49 -join ', ')
Assert 'the fastest growing mailbox is the one climbing, not the biggest' `
    ($out49b -match 'Emerging Mbx on \S+\s+[\d.]+ GB\s+\+1 GB/day') $out49b

# Bounded like Worst affected, and honest about the truncation.
$csv49 = @(Get-Csv $d49 | Where-Object { $_.GrowthGBPerDay -ne '' -and [double]$_.GrowthGBPerDay -gt 0 })
Assert 'more mailboxes grew than the block prints, so the cap is under test' `
    ($csv49.Count -gt 3) ('got ' + $csv49.Count + ' growing rows')
Assert 'so it caps at three and says how many it left out' `
    ($rates49.Count -eq 3 -and $out49b -match ('and ' + ($csv49.Count - 3) + ' more growing, in the report below')) `
    ('printed ' + $rates49.Count + ' of ' + $csv49.Count)

# The mixed-counter estate: rows trended on IndexPayloadBytes carry a rate but
# can carry no date, and the block has to say which is which on the row itself.
#
# The baseline's payload counters are lowered rather than left alone, because
# the mock emits the same IndexPayloadBytes on every run unless growth is
# configured - so an untouched baseline differences to zero and the run reports
# "nothing grew", which is true but tests none of this.
$d49c = Reset-Dir '_t49c'
$null = Invoke-Monitor -OutputPath $d49c -WithEnv @{ MOCK_NOTPOPULATED = 'partial' }
$null = Set-RunAge -Dir $d49c -Hours 24
$base49c = @(Get-ChildItem -LiteralPath $d49c -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
$rows49c = @(Import-Csv -LiteralPath $base49c.FullName)
foreach ($r in $rows49c) {
    if ($r.IndexPayloadBytes -ne '' -and [int64]$r.IndexPayloadBytes -gt 0) {
        $r.IndexPayloadBytes = [string]([int64]([int64]$r.IndexPayloadBytes * 0.5))
    }
}
$rows49c | Export-Csv -LiteralPath $base49c.FullName -NoTypeInformation -Encoding UTF8

$rc49c = Invoke-Monitor -OutputPath $d49c -WithEnv @{ MOCK_NOTPOPULATED = 'partial' }
$out49c = (Get-Stdout) -join "`n"
Assert 'the mixed-counter trended run completes' ($rc49c -eq 0) ('got exit ' + $rc49c)
$pay49c = @(Get-Csv $d49c | Where-Object {
    $_.TrendMetric -eq 'IndexPayloadBytes' -and $_.GrowthGBPerDay -ne '' -and [double]$_.GrowthGBPerDay -gt 0 })
Assert 'payload-trended rows really did grow, so the annotation is under test' `
    ($pay49c.Count -gt 0) ('got ' + $pay49c.Count + ' growing payload rows')
Assert 'a row with no projectable counter says so, and names the counter it is on' `
    ($out49c -match '\+[\d.]+ GB/day on index payload, no projected date') $out49c
Assert 'and the two-counter caveat sits with those rates, not above the verdict' `
    ($out49c.IndexOf('Two counters in use') -gt $out49c.IndexOf('Growth')) `
    ('growth ' + $out49c.IndexOf('Growth') + ' split ' + $out49c.IndexOf('Two counters in use'))

Write-Host ''
Write-Host 'T50  a finding carries its own rate, and is not then repeated below' -ForegroundColor Cyan
# The complaint this answers: every figure in the verdict block was a current
# size, and the one growth-derived number on screen - the Emerging count - had no
# rate behind it. A rate belongs on the finding it qualifies, because "Critical
# and still climbing 0.4 GB/day" and "Critical and flat since Tuesday" are
# different problems and the block was showing them identically.
#
# One database, so the populated count stays inside the ten-row bound and the
# roll call actually prints. Above ten it self-suppresses, which T49 covers.
$d50 = Reset-Dir '_t50'
$null = Invoke-Monitor -OutputPath $d50 -Extra '-Databases MDB01 -WarningGB 1.5 -CriticalGB 2.2'

# Two movers and a deliberate stayer. Bo is left untouched so a finding that did
# not move is under test too - an unannotated Warning cannot be told apart from
# one the script never measured, and that ambiguity is what -ExplainAbsence
# exists to close.
$null = Set-RunAge -Dir $d50 -Hours 24
$base50 = @(Get-ChildItem -LiteralPath $d50 -Filter 'BigFunnelPostingListMonitor-*.csv' | Sort-Object Name -Descending)[0]
$rows50 = @(Import-Csv -LiteralPath $base50.FullName)
foreach ($r in $rows50) {
    switch ($r.DisplayName) {
        # 2.40 GB now, was 2.00 - climbing 0.40 GB/day and already past Critical,
        # so a projection to Critical is meaningless and the row has to carry a
        # rate with no date rather than a negative one.
        'Ana Ilic'     { $r.PostingListBytes = [string][int64](2.00 * 1GB) }
        # 1.20 GB now, was 0.20 - 1.00 GB/day, which puts it one day off the
        # 2.2 GB Critical line and makes it Emerging while still reading Normal.
        'Emerging Mbx' { $r.PostingListBytes = [string][int64](0.20 * 1GB) }
    }
}
$rows50 | Export-Csv -LiteralPath $base50.FullName -NoTypeInformation -Encoding UTF8

$rc50 = Invoke-Monitor -OutputPath $d50 -Extra '-Databases MDB01 -WarningGB 1.5 -CriticalGB 2.2'
$out50 = (Get-Stdout) -join "`n"
Assert 'the trended single-database run completes' ($rc50 -eq 0) ('got exit ' + $rc50)

Assert 'a Critical finding carries its rate on its own line' `
    ($out50 -match '(?m)^\s+Critical\s+Ana Ilic on MDB01\s+[\d.]+ GB\s+\+0\.4 GB/day\s*$') $out50
# No date on a mailbox already past Critical. DaysToCritical goes negative there,
# and "critical in -0.5 day(s)" is worse than saying nothing at all.
Assert 'and no projected date, because it is already past the line' `
    ($out50 -notmatch 'Ana Ilic on MDB01.*critical in') $out50
Assert 'an Emerging finding carries both its rate and its date' `
    ($out50 -match '(?m)^\s+Emerging\s+Emerging Mbx on MDB01\s+[\d.]+ GB\s+\+1 GB/day, critical in [\d.]+ day\(s\)') $out50
Assert 'a finding that did not move says so, rather than being left bare' `
    ($out50 -match '(?m)^\s+Warning\s+Bo Persson on MDB01\s+[\d.]+ GB\s+not growing') $out50

# The other half of the request: in line with the finding rather than somewhere
# else. Naming one mailbox twice under two headings is not emphasis - it is an
# operator reading it twice and working out whether they are two mailboxes.
$seen50e = @([regex]::Matches($out50, 'Emerging Mbx on MDB01')).Count
$seen50a = @([regex]::Matches($out50, 'Ana Ilic on MDB01')).Count
Assert 'the Emerging mailbox is named once in the whole report, not twice' `
    ($seen50e -eq 1) ('named ' + $seen50e + ' times')
Assert 'and so is the Critical one' ($seen50a -eq 1) ('named ' + $seen50a + ' times')

# The block still earns its place: it is where the window and the baseline run
# are named, and those are the provenance for every inline rate above it.
Assert 'the growth heading still prints, since it dates the rates above it' `
    ($out50 -match 'Growth\s+measured over [\d.]+h, against run \d{8}-\d{6}') $out50
# "Nothing grew" and "nothing else grew" are different claims, and only the
# second one is true on a run that has just printed two rates.
Assert 'and the block says nothing ELSE grew, not that nothing grew' `
    ($out50 -match 'Nothing else grew measurably over that window') $out50

Write-Host ''
Write-Host 'T51  -PassThru returns the rows, not a re-read of the CSV' -ForegroundColor Cyan
# The report was the whole interface: an exit code, a CSV and a JSON. The rows it
# prints from are already [pscustomobject]s built once at collection, so handing
# them back costs nothing and is the difference between reading a result and
# querying one.
$d51 = Reset-Dir '_t51'
$rc51 = Invoke-MonitorPassThru -OutputPath $d51 -Extra '-Databases MDB01'
$r51  = @(Get-PassThruRows)
$csv51 = @(Get-Csv $d51)
Assert 'the run completes' ($rc51 -eq 0) ('got exit ' + $rc51)
Assert 'rows come back on the success stream' ($r51.Count -gt 0) ('got ' + $r51.Count + ' rows')
Assert 'and there is one per evaluated mailbox, matching the CSV' `
    ($r51.Count -eq $csv51.Count) ('objects ' + $r51.Count + ' csv ' + $csv51.Count)
# Matched on the suffix. Export-Clixml prefixes "Deserialized." on the way back
# in, which is an artifact of how this harness gets the objects across a process
# boundary and not something an in-process caller ever sees - $r = & monitor.ps1
# hands back a plain BigFunnel.PostingListRow.
Assert 'they are typed, so a caller can test for them rather than duck-type' `
    ($r51[0].PSObject.TypeNames[0] -match 'BigFunnel\.PostingListRow$') ($r51[0].PSObject.TypeNames[0])

# The point of returning objects rather than pointing at the CSV. Import-Csv
# hands back text, and text sorts lexically - 0.9 above 0.0787 - which is
# precisely wrong for the field an operator most wants to sort on.
Assert 'sizes come back as numbers, not as text that sorts lexically' `
    ($r51[0].PostingListGB -is [double]) ($r51[0].PostingListGB.GetType().Name)
Assert 'and the rows answer a Where-Object the way the report does' `
    (@($r51 | Where-Object { $_.Status -eq 'Critical' }).Count -eq
     @($csv51 | Where-Object { $_.Status -eq 'Critical' }).Count) `
    ('objects ' + @($r51 | Where-Object { $_.Status -eq 'Critical' }).Count)

# The whole reason the report goes out through Write-Host. If any of it were
# Write-Output it would be sitting in this collection, and every caller would
# have to filter the decoration back out of their own result.
$leaked51 = @($r51 | Where-Object { $_ -is [string] }).Count
Assert 'no report text leaked into the stream alongside them' `
    ($leaked51 -eq 0) ('got ' + $leaked51 + ' strings')

# Off by default, or a bare run prints its report and then sprays a hundred
# objects through the default formatter underneath it.
$d51b = Reset-Dir '_t51b'
$null = Invoke-MonitorPassThru -OutputPath $d51b -Extra '-Databases MDB01' -NoPassThru
$r51b = @(Get-PassThruRows)
Assert 'and without the switch the success stream stays empty' `
    ($r51b.Count -eq 0) ('got ' + $r51b.Count + ' rows')

Write-Host ''
Write-Host 'T52  the elevated child does not take the report down with its window' -ForegroundColor Cyan
# The relaunch needs a consent prompt, so the full round trip cannot be driven
# from a test run. It splits cleanly in two, though, and both halves can be:
# the child writing the relay, tested by running with the path passed directly,
# and the parent replaying it, tested by reading the source the way T43 does.
$d52   = Reset-Dir '_t52'
$relay = Join-Path $env:TEMP 'bf-test-relay.txt'
Remove-Item -LiteralPath $relay -Force -ErrorAction SilentlyContinue
$null  = Invoke-Monitor -OutputPath $d52 -Extra ('-ConsoleRelayPath "{0}"' -f $relay)
$out52 = Get-Stdout

Assert 'the child writes a relay file when it is given somewhere to write one' `
    (Test-Path -LiteralPath $relay) $relay

$lines52 = @(if (Test-Path -LiteralPath $relay) { [System.IO.File]::ReadAllLines($relay) })
Assert 'and it is not empty, on a run that printed a report' `
    ($lines52.Count -gt 0) ('relay lines: ' + $lines52.Count)

# Style first, tab, then the text. The delimiter is load-bearing: the parent
# splits on it to decide the colour, and a line that arrived without one would
# be dropped rather than printed uncoloured.
$styles52 = @('Plain', 'Head', 'Good', 'Warn', 'Bad', 'Dim')
$malformed52 = @($lines52 | Where-Object {
    $i = $_.IndexOf("`t")
    ($i -lt 0) -or ($styles52 -notcontains $_.Substring(0, $i))
})
Assert 'every relayed line carries a style the parent can act on' `
    ($malformed52.Count -eq 0) ($malformed52 -join "`n")

# The claim the relay has to support is not "some output arrived" but "the
# operator reads the run they approved". Same lines, same order, same text.
$decoded52 = @($lines52 | ForEach-Object { $_.Substring($_.IndexOf("`t") + 1) })
Assert 'and replaying it reproduces the console report exactly, line for line' `
    ((($decoded52 -join "`n")) -eq (($out52 -join "`n"))) `
    (("relay:`n" + ($decoded52 -join "`n") + "`n`nconsole:`n" + ($out52 -join "`n")))

# Colour is part of the report, not decoration on top of it: a verdict block
# that arrives in the parent window all one colour is a different report.
Assert 'the styles really travel, rather than everything arriving as Plain' `
    (@($lines52 | Where-Object { $_ -notmatch '^Plain\t' }).Count -gt 0) ($lines52 -join "`n")

# -Quiet means no console output. Relaying a report the child deliberately did
# not print would make the parent louder than the run it is standing in for.
$d52q = Reset-Dir '_t52q'
Remove-Item -LiteralPath $relay -Force -ErrorAction SilentlyContinue
$null = Invoke-Monitor -OutputPath $d52q -Extra ('-Quiet -ConsoleRelayPath "{0}"' -f $relay)
Assert '-Quiet relays nothing, so the parent cannot print what the child suppressed' `
    (-not (Test-Path -LiteralPath $relay)) $relay
Remove-Item -LiteralPath $relay -Force -ErrorAction SilentlyContinue

# The parent half. Lifted out of the source by name and run for real, the way
# T43 exercises the argument builder - the elevation region around it needs a
# consent prompt nobody can answer from a test run, but the parsing inside it is
# where a relay goes quietly wrong, and that part is ordinary code.
$relayFn = [System.Management.Automation.Language.Parser]::ParseFile($monitor, [ref]$null, [ref]$null).
           FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                                $n.Name -eq 'Show-ConsoleRelay' }, $true)
Assert 'the replay is a function, so it can be tested without a consent prompt' `
    ($relayFn.Count -eq 1) ('found ' + $relayFn.Count)

if ($relayFn.Count -eq 1) {
    . ([scriptblock]::Create($relayFn[0].Extent.Text))

    # Stubbed so the test can see what the replay dispatched, rather than
    # watching it scroll past. Same signature the real one has.
    $script:Replayed = New-Object System.Collections.ArrayList
    function Write-Report {
        param([string]$Text = '', [string]$Style = 'Plain')
        $null = $script:Replayed.Add(@{ Text = $Text; Style = $Style })
    }

    $fixture = Join-Path $env:TEMP 'bf-test-relay-fixture.txt'
    [System.IO.File]::WriteAllText($fixture, @(
        "Head`tBigFunnel PostingListTable monitor v9.9.9",
        "Plain`t",
        "Bad`t  RESULT  Alert",
        # No tab: what a child killed part-way through its last write leaves.
        "Dim",
        # A style that is not in the set, for the same reason - this reaches a
        # ValidateSet on the real Write-Report and must not throw there.
        "Nonsense`t  a line whose style did not survive",
        "Dim`t  Exit code 1"
    ) -join "`r`n")

    $n52 = Show-ConsoleRelay -Path $fixture
    Assert 'a well-formed relay replays every line it can read' `
        ($n52 -eq 5) ('replayed ' + $n52)
    Assert 'and a truncated last line is skipped rather than printed as garbage' `
        (@($script:Replayed | Where-Object { $_.Text -eq 'Dim' }).Count -eq 0) 'printed the style as text'
    Assert 'an unreadable style degrades to Plain instead of throwing' `
        (@($script:Replayed | Where-Object { $_.Text -match 'did not survive' -and $_.Style -eq 'Plain' }).Count -eq 1) `
        (($script:Replayed | ForEach-Object { $_.Style + '|' + $_.Text }) -join "`n")
    Assert 'and the styles that were readable are dispatched as they were written' `
        ((@($script:Replayed)[0].Style -eq 'Head') -and (@($script:Replayed)[2].Style -eq 'Bad')) `
        (($script:Replayed | ForEach-Object { $_.Style + '|' + $_.Text }) -join "`n")
    Assert 'an empty report line survives the round trip as an empty line' `
        (@($script:Replayed)[1].Text -eq '') ('got [' + @($script:Replayed)[1].Text + ']')

    # Nothing to replay is the case the caller's fallback line exists for, and
    # it has to be reported as zero rather than as a failure.
    $script:Replayed.Clear()
    Assert 'a relay that was never written replays nothing and says so' `
        ((Show-ConsoleRelay -Path (Join-Path $env:TEMP 'bf-no-such-relay.txt')) -eq 0) 'expected 0'
    Assert 'and an empty path is not treated as the current directory' `
        ((Show-ConsoleRelay -Path '') -eq 0) 'expected 0'
    Assert 'and neither case prints anything at all' `
        ($script:Replayed.Count -eq 0) ('printed ' + $script:Replayed.Count)

    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    Remove-Item -Path 'function:Write-Report' -Force -ErrorAction SilentlyContinue
}

$src52 = Get-Content -LiteralPath $monitor -Raw
Assert 'the relaunch passes the relay path to the child it starts' `
    ($src52 -match "bound\['ConsoleRelayPath'\]\s*=\s*\`$relay") 'not passed to the child'
Assert 'and replays it after the child exits, then deletes it' `
    ($src52 -match '(?s)\$replayed = Show-ConsoleRelay -Path \$relay.{0,200}Remove-Item -LiteralPath \$relay') 'no replay or no cleanup'
# A relay that never arrived must not leave the operator with nothing at all.
Assert 'and falls back to the exit code and log path when nothing came back' `
    ($src52 -match '(?s)if \(\$replayed -eq 0\)\s*\{\s*Write-Report \(.The elevated run exited') 'no fallback'

Write-Host ''
Write-Host 'T53  a registration run refuses rather than leaving a task that never runs' -ForegroundColor Cyan
# End to end, in a child process, the way a scheduled task would invoke it. The
# harness is not elevated, which is not a limitation here - it is the case the
# refusal exists for, and it is the one an operator hits first.
Reset-TaskStore
$d53  = Reset-Dir '_t53'
$rc53 = Invoke-Monitor -OutputPath $d53 -Extra '-RegisterScheduledTask -Scope Local'
$log53 = (Get-Log $d53) -join "`n"
$out53 = (Get-Stdout) -join "`n"

Assert 'an unelevated registration exits 7, its own code, not 0 and not 3' `
    ($rc53 -eq 7) ('got exit ' + $rc53)
# The assertion that matters more than the exit code. A refusal that still left
# a task behind would be the exact failure the feature exists to prevent.
Assert 'and nothing at all was registered' `
    ($null -eq (Get-MockTask 'Exchange BigFunnel PostingListTable Monitor')) 'a task was created anyway'
Assert 'the log names the missing elevated token as the reason' `
    ($log53 -match 'needs an elevated token') $log53
# The three things that each suppress the automatic relaunch are the three ways
# an operator arrives here by accident, so the message has to list them.
Assert 'and names -NoElevate, -Credential and -TaskCredential as the suppressors' `
    (($log53 -match '-NoElevate') -and ($log53 -match '-TaskCredential')) $log53
Assert 'the console gets the short form, not the paragraph' `
    ($out53 -match 'Cannot register the task: this run is not elevated\.') $out53

# A registration run is local work against the scheduler. Binding a runspace
# first would make it fail on a node where Exchange is not reachable yet, for a
# reason that has nothing to do with the task.
Assert 'the run reports itself as a task operation, not as a collection' `
    ($out53 -match 'scheduled task operation on') $out53
Assert 'and collects nothing: no CSV' (@(Get-Csv $d53).Count -eq 0) 'a CSV was written'
Assert 'and no run summary either' ($null -eq (Get-Summary $d53)) 'a summary was written'
# The directory and the log ARE created, deliberately: every refusal above is a
# diagnosis, and a diagnosis nobody can read afterwards is not one.
Assert 'but the log is still written, because the refusal is the output' `
    ($log53.Length -gt 0) 'no log'
Assert 'and the exit code is printed where the operator is looking' `
    ($out53 -match 'Exit code 7') $out53

Write-Host ''
Write-Host 'T54  removal is confirmed rather than assumed' -ForegroundColor Cyan
# The mock is imported here by explicit path rather than left to auto-loading.
# The child processes above resolve it by PSModulePath, which is verified; this
# process needs it too, to seed a task for the cases below, and an explicit
# import is the difference between "the mock won" and "something won". From here
# on the real ScheduledTasks cmdlets are shadowed in this process as well, which
# is the safe direction: the suite cannot touch the machine's own scheduler.
Import-Module (Join-Path $PSScriptRoot '_mockmodules\ScheduledTasks\ScheduledTasks.psm1') -Force
Assert 'the suite talks to the mock scheduler, never the real one' `
    ((Get-Command Register-ScheduledTask).Module.Path -like '*_mockmodules*') `
    ([string](Get-Command Register-ScheduledTask).Module.Path)

function New-MockTask {
    # Seeds through the mock's own writer rather than by hand, so what a test
    # seeds cannot drift from the shape Get-ScheduledTask reads back.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Arguments = '-NoProfile -File "C:\Scripts\Monitor-BigFunnelPostingList.ps1" -Scope Local',
        [string]$RunLevel  = 'Highest'
    )
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Arguments
    Register-ScheduledTask -TaskName $Name -Action $a -User 'CONTOSO\svc-bf' `
        -Password 'pw' -RunLevel $RunLevel -Force | Out-Null
}

$tn54 = 'Exchange BigFunnel PostingListTable Monitor'

Reset-TaskStore
$d54  = Reset-Dir '_t54'
$rc54 = Invoke-Monitor -OutputPath $d54 -Extra '-UnregisterScheduledTask'
Assert 'removing a task that is not there exits 0, so a teardown can run twice' `
    ($rc54 -eq 0) ('got exit ' + $rc54)
Assert 'and says there was nothing to remove, rather than reporting a removal' `
    (((Get-Log $d54) -join "`n") -match 'No scheduled task named') ((Get-Log $d54) -join "`n")

Reset-TaskStore
New-MockTask -Name $tn54
$d54b  = Reset-Dir '_t54b'
$rc54b = Invoke-Monitor -OutputPath $d54b -Extra '-UnregisterScheduledTask'
Assert 'removing one that is there exits 0' ($rc54b -eq 0) ('got exit ' + $rc54b)
Assert 'and it is gone from the store, checked outside the code that removed it' `
    ($null -eq (Get-MockTask $tn54)) 'still registered'
Assert 'and the removal is reported to the operator' `
    (((Get-Stdout) -join "`n") -match ('Removed: ' + [regex]::Escape($tn54))) ((Get-Stdout) -join "`n")

# Unregister-ScheduledTask cannot be taken at its word. Without an injector this
# branch is unreachable, and an unreachable branch is one nobody has ever run.
Reset-TaskStore
New-MockTask -Name $tn54
$d54c  = Reset-Dir '_t54c'
$rc54c = Invoke-Monitor -OutputPath $d54c -Extra '-UnregisterScheduledTask' -WithEnv @{ MOCK_TASK_STICKY = '1' }
Assert 'a removal that reports success and removes nothing is caught, and exits 7' `
    ($rc54c -eq 7) ('got exit ' + $rc54c)
Assert 'and the log says success was reported but the task is still registered' `
    (((Get-Log $d54c) -join "`n") -match 'reported success but .* is still registered') ((Get-Log $d54c) -join "`n")
Assert 'the task really is still there, so the check was not a false alarm' `
    ($null -ne (Get-MockTask $tn54)) 'the task went after all'

# Estates that reserve task creation to a management layer usually reserve
# removal too, so the diagnosis has to be available on this side as well.
Reset-TaskStore
New-MockTask -Name $tn54
$d54d  = Reset-Dir '_t54d'
$rc54d = Invoke-Monitor -OutputPath $d54d -Extra '-UnregisterScheduledTask' -WithEnv @{ MOCK_TASK_DENY = '1' }
Assert 'a removal blocked by policy exits 7' ($rc54d -eq 7) ('got exit ' + $rc54d)
Assert 'and is named as policy rather than passed through as a raw HRESULT' `
    (((Get-Log $d54d) -join "`n") -match 'Policy in this estate may reserve scheduled task changes') ((Get-Log $d54d) -join "`n")
Reset-TaskStore

Write-Host ''
Write-Host 'T55  the registration itself, lifted out of the script by name' -ForegroundColor Cyan
# Registering needs an elevated token, and the event source below needs one too.
# Neither gate can be passed from a test run, so the choice is between testing
# these the way T52 tests the relay replay - parsed out by name and run for real
# with its dependencies stubbed - and not testing them at all.

function Get-MonitorPartText {
    # Returns the source text of named functions and named script-scope
    # assignments, to be dot-sourced by the CALLER. Deliberately not dot-sourced
    # in here: a definition dot-sourced inside a function lands in that
    # function's scope and vanishes when it returns, which would leave every
    # assertion below silently exercising nothing.
    #
    # Parsed rather than matched with a regex. A brace inside one of this
    # script's comments would defeat any pattern; the AST cannot be fooled by
    # one, and a name that is not found is reported rather than skipped.
    param([Parameter(Mandatory = $true)][string[]]$Name)

    $ast   = [System.Management.Automation.Language.Parser]::ParseFile($monitor, [ref]$null, [ref]$null)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Name) {
        $hit = @($ast.FindAll({ param($x)
            ($x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n) -or
            ($x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq $n)
        }, $true))
        if ($hit.Count -ne 1) {
            Assert ('lifting [' + $n + '] out of the monitor finds exactly one definition') `
                ($hit.Count -eq 1) ('found ' + $hit.Count)
            continue
        }
        $parts.Add($hit[0].Extent.Text)
    }
    return ($parts -join [Environment]::NewLine)
}

$lifted = Get-MonitorPartText -Name @(
    'Test-TaskCommandLine', 'ConvertTo-RelaunchArguments',
    'Register-MonitorScheduledTask', 'Test-MonitorScheduledTaskRegistration',
    '$script:RunEventMap', '$script:MailboxEventMap',
    'ConvertTo-KeyValueText', 'Write-EmitEventChannel'
)
Assert 'all eight parts come out of the monitor' ($lifted.Length -gt 0) 'nothing lifted'
. ([scriptblock]::Create($lifted))

# The two console channels, captured instead of printed, so a test can read what
# a refusal actually said rather than watch it scroll past.
$script:Logged   = New-Object System.Collections.ArrayList
$script:Reported = New-Object System.Collections.ArrayList
function Write-RunLog {
    param([string]$Message, [string]$Level = 'INFO', [switch]$RowDetail, [string[]]$ConsoleText)
    $null = $script:Logged.Add($Level + '|' + $Message + '|' + ($ConsoleText -join ' '))
}
function Write-Report {
    param([string]$Text = '', [string]$Style = 'Plain')
    $null = $script:Reported.Add($Style + '|' + $Text)
}

$script:Elevated = $true
$MaxRunMinutes   = 45
$tc55 = New-Object System.Management.Automation.PSCredential(
            'CONTOSO\svc-bf', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
$tn55 = 'BF Test Registration'

# -Command collapses every non-zero exit to 1 at the scheduler, so 2 to 6 arrive
# indistinguishable. This is the one assertion about a registered action that
# cannot be allowed to drift.
Assert 'a -File action passes the command line check' `
    (Test-TaskCommandLine -Arguments '-NoProfile -File "C:\x.ps1" -Scope Local') 'rejected a -File action'
Assert 'a -Command action is rejected' `
    (-not (Test-TaskCommandLine -Arguments '-NoProfile -Command "& C:\x.ps1"')) 'accepted -Command'
Assert 'and -Command loses even when -File is also present' `
    (-not (Test-TaskCommandLine -Arguments '-File "C:\x.ps1" -Command "& x"')) 'accepted a mixed line'
Assert 'a parameter that merely starts with -File is not mistaken for it' `
    (-not (Test-TaskCommandLine -Arguments '-FilePath "C:\x.ps1"')) 'matched -FilePath'
Assert 'and an empty command line is not a -File one' `
    (-not (Test-TaskCommandLine -Arguments '')) 'accepted an empty line'

Reset-TaskStore
$script:Logged.Clear()
$b55 = @{
    RegisterScheduledTask = [switch]$true
    TaskName              = $tn55
    TaskIntervalHours     = 6
    Scope                 = 'Local'
    WarningGB             = 3.5
    CriticalGB            = 4.25
    Credential            = $tc55
    ConsoleRelayPath      = 'C:\Temp\bf-relay.txt'
}
$r55 = Register-MonitorScheduledTask -Bound $b55 -Name $tn55 -IntervalHours 6 `
           -StartTime '02:15' -TaskCred $tc55
$t55 = Get-MockTask $tn55

Assert 'a registration with a credential returns 0' ($r55 -eq 0) ('got ' + $r55)
Assert 'and the task is in the store' ($null -ne $t55) 'nothing registered'
if ($null -ne $t55) {
    # Interactive never runs; S4U runs and then cannot open the runspace. Only
    # Password is a working monitor, and the script reads it back to check.
    Assert 'registered with LogonType Password, the only one that works' `
        ([string]$t55.LogonType -eq 'Password') ([string]$t55.LogonType)
    Assert 'and RunLevel Highest, which the counters need' `
        ([string]$t55.RunLevel -eq 'Highest') ([string]$t55.RunLevel)
    Assert 'the action invokes the script with -File' `
        (Test-TaskCommandLine -Arguments ([string]$t55.Arguments)) ([string]$t55.Arguments)
    Assert 'and never with -Command' `
        ([string]$t55.Arguments -notmatch '(?i)(^|\s)-Command(\s|$)') ([string]$t55.Arguments)
    Assert 'it runs non-interactively, because a task has no desktop to prompt on' `
        ([string]$t55.Arguments -match '(?i)-NonInteractive') ([string]$t55.Arguments)

    # The reason the argument line is rebuilt from PSBoundParameters rather than
    # from a hand-maintained list: a task that schedules a different run from the
    # one that was typed is worse than no task.
    Assert 'the run that was typed round-trips into the task: -Scope' `
        ([string]$t55.Arguments -match '-Scope "Local"') ([string]$t55.Arguments)
    Assert 'and its thresholds come across too' `
        (([string]$t55.Arguments -match '-WarningGB "3\.5"') -and
         ([string]$t55.Arguments -match '-CriticalGB "4\.25"')) ([string]$t55.Arguments)

    # The exclusions. Each of these means something to the registration and
    # nothing inside the task, and two of them cannot cross into one at all.
    Assert 'the switch that asked for the registration does not go into the task' `
        ([string]$t55.Arguments -notmatch '(?i)-RegisterScheduledTask') ([string]$t55.Arguments)
    Assert 'nor do the parameters that describe how to build it' `
        (([string]$t55.Arguments -notmatch '(?i)-TaskName') -and
         ([string]$t55.Arguments -notmatch '(?i)-TaskIntervalHours')) ([string]$t55.Arguments)
    # A PSCredential does not survive a command line, and the relay belongs to a
    # parent process that will not exist when the scheduler starts this.
    Assert 'and neither -Credential nor -ConsoleRelayPath is written into it' `
        (([string]$t55.Arguments -notmatch '(?i)-Credential') -and
         ([string]$t55.Arguments -notmatch '(?i)-ConsoleRelayPath')) ([string]$t55.Arguments)
}
Assert 'an explicit -Scope draws no warning' `
    ((($script:Logged) -join "`n") -notmatch '-Scope was not given') (($script:Logged) -join "`n")

# The default is All, and on a DAG that means every node sweeping the whole
# organisation and writing several full sets of files describing one estate.
# Loud rather than fatal: -Scope All on exactly one node is a legitimate thing
# to want.
Reset-TaskStore
$script:Logged.Clear()
$b55b = @{ RegisterScheduledTask = [switch]$true; TaskName = $tn55 }
$r55b = Register-MonitorScheduledTask -Bound $b55b -Name $tn55 -IntervalHours 4 `
            -StartTime '00:05' -TaskCred $tc55
Assert 'omitting -Scope still registers, because a deliberate -Scope All is valid' `
    ($r55b -eq 0) ('got ' + $r55b)
Assert 'but it warns, naming the default it silently inherited' `
    ((($script:Logged) -join "`n") -match 'WARN\|-Scope was not given.*default, All') (($script:Logged) -join "`n")
Assert 'and tells the operator which one they probably wanted' `
    ((($script:Logged) -join "`n") -match '-Scope Local') (($script:Logged) -join "`n")

# A credential object with no user name reaches the second guard. The first one
# tests [Environment]::UserInteractive, which a test run cannot make false and
# must not try: on an interactive harness that branch falls through to
# Get-Credential and the suite would sit on a prompt until somebody answered it.
# Asserted against the source instead, below.
Reset-TaskStore
$script:Logged.Clear()
$r55c = Register-MonitorScheduledTask -Bound @{ Scope = 'Local' } -Name $tn55 `
            -IntervalHours 4 -StartTime '00:05' -TaskCred ([pscustomobject]@{ UserName = '' })
Assert 'a blank user name is refused rather than registered' ($r55c -eq 7) ('got ' + $r55c)
Assert 'and nothing was written to the scheduler' ($null -eq (Get-MockTask $tn55)) 'a task was created'
Assert 'the refusal says why: a task with no password never runs' `
    ((($script:Logged) -join "`n") -match 'registered without a password never runs') (($script:Logged) -join "`n")

$src55 = Get-Content -LiteralPath $monitor -Raw
Assert 'a session that cannot prompt refuses instead of hanging on Get-Credential' `
    ($src55 -match '(?s)if \(-not \[Environment\]::UserInteractive\)\s*\{.{0,1200}?return 7.{0,120}?\}.{0,300}?Get-Credential') `
    'the non-interactive refusal does not precede the prompt'

# Policy refusal. The most likely reason this call fails in a managed estate,
# and the reason the whole emit half of this work exists.
Reset-TaskStore
$script:Logged.Clear()
$env:MOCK_TASK_DENY = '1'
$r55d = Register-MonitorScheduledTask -Bound @{ Scope = 'Local' } -Name $tn55 `
            -IntervalHours 4 -StartTime '00:05' -TaskCred $tc55
Reset-TaskStore
Assert 'a registration blocked by policy exits 7 rather than throwing' ($r55d -eq 7) ('got ' + $r55d)
Assert 'and is diagnosed as policy, not passed through as a bare HRESULT' `
    ((($script:Logged) -join "`n") -match 'policy prevents local administrators from creating scheduled tasks') (($script:Logged) -join "`n")
Assert 'the operator is pointed at the runbook command to hand over' `
    ((($script:Logged) -join "`n") -match 'runbook') (($script:Logged) -join "`n")
Assert 'and the underlying error is still recorded, not swallowed' `
    ((($script:Logged) -join "`n") -match '0x80070005') (($script:Logged) -join "`n")

# Verification reads the task back from the scheduler rather than trusting what
# was sent to it, which is the only way to catch a management layer rewriting
# the registration. Each injector below is a rewrite that reports success.
Reset-TaskStore
$script:Logged.Clear()
$env:MOCK_TASK_LOGONTYPE = 'Interactive'
New-MockTask -Name $tn55
$v55i = Test-MonitorScheduledTaskRegistration -Name $tn55
Remove-Item -Path 'env:MOCK_TASK_LOGONTYPE' -ErrorAction SilentlyContinue
Assert 'a task that came back Interactive fails verification' ($v55i -eq 7) ('got ' + $v55i)
Assert 'and is named as one that sits at Ready reporting 0x41303' `
    ((($script:Logged) -join "`n") -match '0x41303') (($script:Logged) -join "`n")
Assert 'leaving it in place is called out as worse than having no task' `
    ((($script:Logged) -join "`n") -match 'worse than having no task') (($script:Logged) -join "`n")

Reset-TaskStore
$script:Logged.Clear()
$env:MOCK_TASK_LOGONTYPE = 'S4U'
New-MockTask -Name $tn55
$v55s = Test-MonitorScheduledTaskRegistration -Name $tn55
Remove-Item -Path 'env:MOCK_TASK_LOGONTYPE' -ErrorAction SilentlyContinue
Assert 'S4U fails verification too, though the task does run' ($v55s -eq 7) ('got ' + $v55s)
# The distinction is the whole point: S4U is the one that looks healthy in the
# scheduler and fails at the runspace every time.
Assert 'and it is named as the runspace failure, not as a task that never starts' `
    (((($script:Logged) -join "`n") -match '0x8009030e') -and
     ((($script:Logged) -join "`n") -notmatch '0x41303')) (($script:Logged) -join "`n")

Reset-TaskStore
$script:Logged.Clear()
$env:MOCK_TASK_RUNLEVEL = 'Limited'
New-MockTask -Name $tn55
$v55r = Test-MonitorScheduledTaskRegistration -Name $tn55
Remove-Item -Path 'env:MOCK_TASK_RUNLEVEL' -ErrorAction SilentlyContinue
Assert 'a task that came back Limited fails verification' ($v55r -eq 7) ('got ' + $v55r)
Assert 'and says the monitor needs an elevated token to read the counters' `
    ((($script:Logged) -join "`n") -match 'RunLevel is Limited, not Highest') (($script:Logged) -join "`n")

Reset-TaskStore
$script:Logged.Clear()
New-MockTask -Name $tn55 -Arguments '-NoProfile -Command "& C:\x.ps1"'
$v55c = Test-MonitorScheduledTaskRegistration -Name $tn55
Assert 'an action rewritten to -Command fails verification' ($v55c -eq 7) ('got ' + $v55c)
Assert 'and says why: exit codes 2 to 6 become indistinguishable' `
    ((($script:Logged) -join "`n") -match 'collapses every non-zero exit code to 1') (($script:Logged) -join "`n")

Reset-TaskStore
$script:Logged.Clear()
$v55m = Test-MonitorScheduledTaskRegistration -Name 'BF No Such Task'
Assert 'a task that cannot be read back afterwards is an error, not a pass' `
    ($v55m -eq 7) ('got ' + $v55m)
Assert 'and it is reported as a failed read-back, not as a failed registration' `
    ((($script:Logged) -join "`n") -match 'could not read it back') (($script:Logged) -join "`n")
Reset-TaskStore

Write-Host ''
Write-Host 'T56  the event channel maps a status to one published id and entry type' -ForegroundColor Cyan
# These numbers are a contract. They go in the runbook, and a customer's Splunk
# alerts are written against them, so renumbering one silently is a broken
# dashboard on somebody else's estate. Pinned here as literals rather than read
# out of the same table the script uses.
$script:EmitErrors   = New-Object System.Collections.Generic.List[string]
$script:EmitWritten  = New-Object System.Collections.ArrayList
$script:MockSourceOk = $true
$script:MockWriteOk  = $true

function Initialize-EmitEventSource {
    param([string]$Source)
    return $script:MockSourceOk
}
function Write-EmitEvent {
    param([string]$Source, [int]$EventId, [string]$EntryType, [string]$Message)
    $null = $script:EmitWritten.Add([pscustomobject]@{
        Source = $Source; EventId = $EventId; EntryType = $EntryType; Message = $Message })
    return $script:MockWriteOk
}

function New-EmitPayload {
    param([string]$Status, [bool]$Completed = $true)
    [ordered]@{
        RunId                = '20260916-120000-4242'
        ScriptVersion        = '1.11.0'
        Timestamp            = '2026-09-16T12:00:00'
        Server               = 'EXCH-01'
        Status               = $Status
        Completed            = $Completed
        ConfiguredWarningGB  = 3.5
        ConfiguredCriticalGB = 4.25
    }
}

function Invoke-EmitChannel {
    param($Payload, $AtRisk = @(), $Emerging = @(), [int]$MaxDetail = 25)
    $script:EmitWritten.Clear()
    $script:EmitErrors.Clear()
    $script:Logged.Clear()
    Write-EmitEventChannel -Source 'BFTest' -Payload $Payload `
        -AtRisk $AtRisk -Emerging $Emerging -MaxDetail $MaxDetail
    # The leading comma is load-bearing. PowerShell unrolls a returned array, so
    # a plain @(...) holding ONE event arrives at the caller as a bare object
    # with no .Count - and every case here that emits exactly one event is a
    # case worth getting right. The comma wraps it, the unroll takes the wrapper
    # off, and the array survives at any length including zero.
    return ,@($script:EmitWritten)
}

# Findings are Warnings and monitor faults are Errors, mirroring the exit-code
# philosophy: a full posting list table is the estate's problem, and a monitor
# that could not measure one is this script's.
$expect56 = @(
    @{ Status = 'OK';                 Id = 1000; Type = 'Information' }
    @{ Status = 'Emerging';           Id = 1001; Type = 'Warning'     }
    @{ Status = 'Alert';              Id = 1002; Type = 'Warning'     }
    @{ Status = 'Partial';            Id = 1003; Type = 'Error'       }
    @{ Status = 'MetricUnavailable';  Id = 1004; Type = 'Error'       }
    @{ Status = 'MetricInconclusive'; Id = 1005; Type = 'Information' }
    @{ Status = 'PublishFailed';      Id = 1006; Type = 'Error'       }
)
foreach ($e in $expect56) {
    $w = Invoke-EmitChannel -Payload (New-EmitPayload -Status $e.Status)
    Assert ('status ' + $e.Status + ' writes exactly one run event') `
        ($w.Count -eq 1) ('wrote ' + $w.Count)
    if ($w.Count -eq 1) {
        Assert ('  as event ' + $e.Id + ', ' + $e.Type) `
            (($w[0].EventId -eq $e.Id) -and ($w[0].EntryType -eq $e.Type)) `
            ('got ' + $w[0].EventId + '/' + $w[0].EntryType)
    }
}
Assert 'the seven mapped statuses are the whole table, with nothing extra in it' `
    ($script:RunEventMap.Count -eq 7) ('table has ' + $script:RunEventMap.Count + ' entries')

# The abort path's Status is a free-form reason by design, so it is never in the
# table. That is not an unknown status - it is the single most important event
# this channel carries, because a monitor that stopped reporting looks exactly
# like an estate with nothing wrong.
$w56a = Invoke-EmitChannel -Payload (New-EmitPayload -Status 'Aborted: the run exceeded -MaxRunMinutes' -Completed $false)
Assert 'an aborted run is emitted as 1007, an Error' `
    (($w56a.Count -eq 1) -and ($w56a[0].EventId -eq 1007) -and ($w56a[0].EntryType -eq 'Error')) `
    ((($w56a | ForEach-Object { [string]$_.EventId + '/' + $_.EntryType }) -join ','))
Assert 'and the free-form reason travels with it, so the event says what happened' `
    (($w56a.Count -eq 1) -and ($w56a[0].Message -match 'exceeded -MaxRunMinutes')) `
    ((($w56a | ForEach-Object { $_.Message }) -join ' '))
Assert 'an abort is not counted as a mapping gap' `
    ($script:EmitErrors.Count -eq 0) ((($script:EmitErrors) -join ' | '))

# A completed run carrying a status the table has never heard of means the
# precedence chain grew and this map did not. Emitted under a reserved id rather
# than dropped: a missing event and a run that never happened look the same to a
# forwarder.
$w56u = Invoke-EmitChannel -Payload (New-EmitPayload -Status 'Sideways')
Assert 'an unmapped status on a completed run is emitted as 1099, a Warning' `
    (($w56u.Count -eq 1) -and ($w56u[0].EventId -eq 1099) -and ($w56u[0].EntryType -eq 'Warning')) `
    ((($w56u | ForEach-Object { [string]$_.EventId + '/' + $_.EntryType }) -join ','))
Assert 'and the gap is recorded, so it reaches the summary rather than only the log' `
    (((($script:EmitErrors) -join ' ')) -match 'status \[Sideways\] has no event id mapping') ((($script:EmitErrors) -join ' | '))

# Per-mailbox events: the reason an alert can name a mailbox rather than a count.
$rows56 = @(
    [pscustomobject]@{ Status = 'Critical'; Database = 'MDB01'; DisplayName = 'Ana Ilic'
                       MailboxGuid = '11111111-1111-1111-1111-111111111111'
                       PostingListGB = 5.2; TotalItemSize = '12 GB'; ItemCount = 90000
                       BigFunnelIndexedCount = 89000; Trend = 'Growing'
                       GrowthGBPerDay = 0.4; DaysToCritical = '' }
    [pscustomobject]@{ Status = 'Warning'; Database = 'MDB02'; DisplayName = 'Bo Persson'
                       MailboxGuid = '22222222-2222-2222-2222-222222222222'
                       PostingListGB = 3.9; TotalItemSize = '8 GB'; ItemCount = 40000
                       BigFunnelIndexedCount = 39000; Trend = 'Flat'
                       GrowthGBPerDay = 0; DaysToCritical = '' }
)
$emg56 = @(
    [pscustomobject]@{ Status = 'OK'; Database = 'MDB01'; DisplayName = 'Emerging Mbx'
                       MailboxGuid = '33333333-3333-3333-3333-333333333333'
                       PostingListGB = 2.1; TotalItemSize = '5 GB'; ItemCount = 20000
                       BigFunnelIndexedCount = 19000; Trend = 'Growing'
                       GrowthGBPerDay = 1.0; DaysToCritical = 2.1 }
)
$w56m = Invoke-EmitChannel -Payload (New-EmitPayload -Status 'Alert') -AtRisk $rows56 -Emerging $emg56
Assert 'a run event plus one per named mailbox' ($w56m.Count -eq 4) ('wrote ' + $w56m.Count)
Assert 'Critical is 1010, Warning is 1011, Emerging is 1012' `
    ((@($w56m | Where-Object { $_.EventId -eq 1010 }).Count -eq 1) -and
     (@($w56m | Where-Object { $_.EventId -eq 1011 }).Count -eq 1) -and
     (@($w56m | Where-Object { $_.EventId -eq 1012 }).Count -eq 1)) `
    ((($w56m | ForEach-Object { [string]$_.EventId }) -join ','))
# All three are findings about the estate, not faults in the monitor, however
# bad the number is.
Assert 'and all three are Warnings, whatever the number says' `
    (@($w56m | Where-Object { $_.EventId -ge 1010 -and $_.EntryType -ne 'Warning' }).Count -eq 0) `
    ((($w56m | ForEach-Object { [string]$_.EventId + '/' + $_.EntryType }) -join ','))
# Emerging is a trend verdict, not a row Status. The emerging row above carries
# Status OK on purpose: taking its own Status would emit it as nothing at all.
Assert 'an emerging mailbox is emitted on its trend, not on its row status' `
    (@($w56m | Where-Object { $_.EventId -eq 1012 -and $_.Message -match 'Finding=Emerging' }).Count -eq 1) `
    ((($w56m | ForEach-Object { $_.Message }) -join ' | '))
Assert 'each mailbox event names the mailbox, which is the point of having them' `
    (@($w56m | Where-Object { $_.Message -match 'DisplayName="Ana Ilic"' }).Count -eq 1) `
    ((($w56m | ForEach-Object { $_.Message }) -join ' | '))
Assert 'and carries the run id, so it correlates with the run event' `
    (@($w56m | Where-Object { $_.Message -match 'RunId=20260916-120000-4242' }).Count -eq 4) `
    ((($w56m | ForEach-Object { $_.Message }) -join ' | '))
Assert 'and the thresholds it was judged against' `
    (@($w56m | Where-Object { $_.EventId -eq 1010 -and $_.Message -match 'CriticalGB=4\.25' }).Count -eq 1) `
    ((($w56m | ForEach-Object { $_.Message }) -join ' | '))

# A badly affected server holding thousands of at-risk mailboxes would otherwise
# make the monitor its own Event Log problem. The lists are already sorted
# worst-first, so the detail that survives the cap is the detail worth having.
$many56 = @(1..8 | ForEach-Object {
    [pscustomobject]@{ Status = 'Critical'; Database = 'MDB01'; DisplayName = ('Mbx ' + $_)
                       MailboxGuid = ('00000000-0000-0000-0000-00000000000' + $_)
                       PostingListGB = 5.0; TotalItemSize = '10 GB'; ItemCount = 1
                       BigFunnelIndexedCount = 1; Trend = 'Flat'; GrowthGBPerDay = 0; DaysToCritical = '' }
})
$w56c = Invoke-EmitChannel -Payload (New-EmitPayload -Status 'Alert') -AtRisk $many56 -MaxDetail 3
Assert '-MaxAlertDetail bounds the mailbox events, run event aside' `
    ($w56c.Count -eq 4) ('wrote ' + $w56c.Count)
Assert 'and the ones that were dropped are counted in the log rather than lost quietly' `
    ((($script:Logged) -join "`n") -match '5 further at-risk mailbox\(es\) were not emitted') (($script:Logged) -join "`n")

# There is no value in several hundred mailbox events with no run event to
# correlate them against, and every one of them would fail the same way.
$script:MockWriteOk = $false
$w56f = Invoke-EmitChannel -Payload (New-EmitPayload -Status 'Alert') -AtRisk $rows56 -Emerging $emg56
$script:MockWriteOk = $true
Assert 'a run event that could not be written stops the mailbox events too' `
    ($w56f.Count -eq 1) ('wrote ' + $w56f.Count)

$script:MockSourceOk = $false
$w56s = Invoke-EmitChannel -Payload (New-EmitPayload -Status 'Alert') -AtRisk $rows56
$script:MockSourceOk = $true
Assert 'and a source that could not be prepared writes nothing at all' `
    ($w56s.Count -eq 0) ('wrote ' + $w56s.Count)

Write-Host ''
Write-Host 'T57  the key=value payload a forwarder reads with no configuration' -ForegroundColor Cyan
# Splunk extracts key=value with no configuration, and Event Viewer renders it
# with no parser. Both matter: the operator triaging at 3am is reading the
# event, not the index.
$kv57 = ConvertTo-KeyValueText ([ordered]@{
    Status    = 'OK'
    Server    = 'EXCH-01'
    Name      = 'Ana Ilic'
    Note      = "line one`r`nline two"
    Quoted    = 'he said "no"'
    Elevated  = $true
    Missing   = $null
    Number    = 4.25
})
$lines57 = @($kv57 -split '\r?\n')

Assert 'one line per field, and no field split across two' ($lines57.Count -eq 8) ('got ' + $lines57.Count)
Assert 'a value with no whitespace is left unquoted, the way Splunk prefers it' `
    (($lines57 -contains 'Status=OK') -and ($lines57 -contains 'Server=EXCH-01')) ($kv57)
# An unquoted value containing a space is where field extraction stops - and it
# stops silently, taking every later field on the line with it.
Assert 'a value containing a space is quoted' `
    ($lines57 -contains 'Name="Ana Ilic"') ($kv57)
# A value carrying a line break splits one record into two at the forwarder, and
# the second half arrives as an event with no timestamp and no context.
Assert 'a newline inside a value is folded to a space, not left to split the record' `
    ($lines57 -contains 'Note="line one line two"') ($kv57)
# Backslash-escaping is what a JSON reader expects and not what Event Viewer
# renders, and these two readers see the same string.
Assert 'an embedded double quote becomes a single one rather than a backslash escape' `
    ($lines57 -contains 'Quoted="he said ''no''"') ($kv57)
Assert 'a boolean is rendered lower case, the way a search language compares it' `
    ($lines57 -contains 'Elevated=true') ($kv57)
Assert 'a null is an empty value, not the word null and not a missing key' `
    ($lines57 -contains 'Missing=') ($kv57)
Assert 'and a number keeps its own text, unquoted' `
    ($lines57 -contains 'Number=4.25') ($kv57)

# The stubs and the pretend elevated token stop here: everything below runs in a
# child process, and anything left defined would be a trap for the next case
# appended to this file rather than a convenience.
foreach ($f in 'Write-Report', 'Write-RunLog', 'Initialize-EmitEventSource', 'Write-EmitEvent') {
    Remove-Item -Path ('function:' + $f) -Force -ErrorAction SilentlyContinue
}
$script:Elevated = $false

Write-Host ''
Write-Host 'T58  the per-run JSON, its sweep, and an emit failure that moves nothing' -ForegroundColor Cyan
# Back to full runs in a child process. The claim under test is the one rule the
# whole emit region is built around: these are additional channels, never the
# stable contract, so turning one on cannot start failing a scheduler on day one.
$d58  = Reset-Dir '_t58'
$rc58 = Invoke-Monitor -OutputPath $d58 -Extra '-Databases MDB01'
$sum58 = Get-Summary $d58
Assert 'the baseline run, with no -EmitTo at all, completes' ($rc58 -eq 0) ('got exit ' + $rc58)
Assert 'and writes no per-run JSON, so the default behaviour is unchanged' `
    (@(Get-ChildItem -LiteralPath $d58 -Filter 'BigFunnelPostingListMonitor-*.json' -ErrorAction SilentlyContinue).Count -eq 0) `
    'a per-run JSON appeared without being asked for'

$d58b  = Reset-Dir '_t58b'
$rc58b = Invoke-Monitor -OutputPath $d58b -Extra '-Databases MDB01 -EmitTo RunJson'
$runJson58 = @(Get-ChildItem -LiteralPath $d58b -Filter 'BigFunnelPostingListMonitor-*.json' -ErrorAction SilentlyContinue)
Assert '-EmitTo RunJson exits the same as the run without it' ($rc58b -eq $rc58) ('got exit ' + $rc58b)
Assert 'and writes exactly one per-run JSON' ($runJson58.Count -eq 1) ('got ' + $runJson58.Count)

if ($runJson58.Count -eq 1) {
    $per58  = Get-Content -LiteralPath $runJson58[0].FullName -Raw | ConvertFrom-Json
    $stab58 = Get-Summary $d58b
    Assert 'it carries the same schema as the stable summary, field for field' `
        (@($per58.PSObject.Properties).Count -eq @($stab58.PSObject.Properties).Count) `
        ('per-run ' + @($per58.PSObject.Properties).Count + ' vs stable ' + @($stab58.PSObject.Properties).Count)
    Assert 'and describes the same run' `
        ([string]$per58.RunId -eq [string]$stab58.RunId) ([string]$per58.RunId + ' vs ' + [string]$stab58.RunId)
    Assert 'with the same verdict' `
        ([string]$per58.Status -eq [string]$stab58.Status) ([string]$per58.Status + ' vs ' + [string]$stab58.Status)
    # The reason it carries an exit code at all: latest-summary.json cannot
    # describe a run whose own publish failed, and this one can.
    Assert 'and the exit code the run actually returned' `
        ([int]$per58.ExitCode -eq $rc58b) ('json ' + $per58.ExitCode + ' vs process ' + $rc58b)
    # Named INSIDE the pattern on purpose, which is the exact mirror of why the
    # two stable files are named outside it.
    Assert 'its name sits inside the retention pattern, so no new rotation code exists' `
        ($runJson58[0].Name -like 'BigFunnelPostingListMonitor-*') $runJson58[0].Name
}

# The other half of that naming decision, proved rather than asserted: the sweep
# takes the per-run file and leaves both stable files alone.
$aged58 = $runJson58 | Select-Object -First 1
if ($aged58) {
    # Retention reads LastWriteTime, not the name - unlike the baseline lookup,
    # which reads the name. Aging it the wrong way would test nothing.
    (Get-Item -LiteralPath $aged58.FullName).LastWriteTime = (Get-Date).AddDays(-3)
    $rc58c = Invoke-Monitor -OutputPath $d58b -Extra '-Databases MDB01 -EmitTo RunJson -RetentionDays 1'
    Assert 'the second run completes' ($rc58c -eq 0) ('got exit ' + $rc58c)
    Assert 'and the aged per-run JSON is swept by the existing retention pass' `
        (-not (Test-Path -LiteralPath $aged58.FullName)) $aged58.Name
    Assert 'while latest-summary.json survives it, being named outside the pattern' `
        (Test-Path -LiteralPath (Join-Path $d58b 'latest-summary.json')) 'latest-summary.json was swept'
    Assert 'and so does latest.csv' `
        (Test-Path -LiteralPath (Join-Path $d58b 'latest.csv')) 'latest.csv was swept'
    Assert 'the second run left its own per-run JSON behind, unaged' `
        (@(Get-ChildItem -LiteralPath $d58b -Filter 'BigFunnelPostingListMonitor-*.json').Count -eq 1) `
        ('got ' + @(Get-ChildItem -LiteralPath $d58b -Filter 'BigFunnelPostingListMonitor-*.json').Count)
}

# A forced Event Log failure, and one that is forced the same way on every
# machine. MEASURED on PS 5.1.26100: a source name over 255 characters fails the
# registry key name check in SourceExists AND in Write-EventLog, before either
# one reaches a rights check - so this behaves identically elevated or not, and
# it can never create a source or write an event on the machine running the
# suite. A short made-up name would not do: elevated, the script would create it
# for real.
$badSrc58 = 'BFTestSource' + ('x' * 250)
$d58d  = Reset-Dir '_t58d'
$rc58d = Invoke-Monitor -OutputPath $d58d -Extra ('-Databases MDB01 -EmitTo EventLog -EventLogSource {0}' -f $badSrc58)
$sum58d = Get-Summary $d58d
$log58d = (Get-Log $d58d) -join "`n"

Assert 'an Event Log channel that fails outright does not move the exit code' `
    ($rc58d -eq $rc58) ('emit run exited ' + $rc58d + ', the same run without it exited ' + $rc58)
Assert 'and does not change the verdict either' `
    ([string]$sum58d.Status -eq [string]$sum58.Status) ([string]$sum58d.Status + ' vs ' + [string]$sum58.Status)
# A customer whose only channel is the Event Log cannot read a summary field
# explaining why the Event Log is empty - so it is WARNed in the log as well.
Assert 'the failure is recorded in EmitErrors rather than lost' `
    (-not [string]::IsNullOrWhiteSpace([string]$sum58d.EmitErrors)) 'EmitErrors is empty'
Assert 'and names what actually went wrong' `
    ([string]$sum58d.EmitErrors -match 'Registry key names') ([string]$sum58d.EmitErrors)
Assert 'and is WARNed in the log too, which is the one place certain to exist' `
    ($log58d -match 'Could not write event \d+ to source') $log58d
# PublishErrors is the stable contract and exits 3. EmitErrors is not, and must
# never leak into it.
Assert 'an emit failure never reaches PublishErrors' `
    ([string]::IsNullOrWhiteSpace([string]$sum58d.PublishErrors)) ([string]$sum58d.PublishErrors)
# Invoke-RunEmit has to run AFTER the summary is written, so the field that
# describes an emit failure is written before the failure happens. The second,
# best-effort write is what closes that gap, and this is the assertion that
# proves it ran.
Assert 'EmitErrors reaches the stable summary despite being filled in after it was written' `
    ([string]$sum58d.EmitErrors -match 'EventLog:') ([string]$sum58d.EmitErrors)

Reset-TaskStore

Write-Host ''

Write-Host ('RESULT: ' + $pass + ' passed, ' + $fail + ' failed') -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
