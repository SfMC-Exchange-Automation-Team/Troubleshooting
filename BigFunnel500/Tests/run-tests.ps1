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

# Scratch output. The cases below create 33 output directories, and a test run
# must not leave any of them in the working tree.
$scratch = Join-Path $env:TEMP 'BigFunnelMonitorTests'
if (-not (Test-Path -LiteralPath $scratch)) { New-Item -ItemType Directory -Path $scratch -Force | Out-Null }

$pass    = 0
$fail    = 0

if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME = 'W25-EX01' }

# Command auto-loading resolves Get-MailboxDatabase and Get-MailboxStatistics
# from the mock module, so the monitor runs as the top-level -File script and
# its exit codes are the process exit codes.
$env:PSModulePath = (Join-Path $PSScriptRoot '_mockmodules') + ';' + $env:PSModulePath

function Invoke-Monitor {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$Extra = '',
        [hashtable]$WithEnv = @{}
    )

    foreach ($k in $WithEnv.Keys) { Set-Item -Path ('env:' + $k) -Value $WithEnv[$k] }

    # Windows tokenizes on double quotes; single quotes would arrive literally.
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}" {2}' -f $monitor, $OutputPath, $Extra

    $so = Join-Path $env:TEMP 'bf-test-out.txt'
    $se = Join-Path $env:TEMP 'bf-test-err.txt'
    $p = Start-Process -FilePath $psExe -PassThru -Wait -NoNewWindow `
         -ArgumentList $argLine -RedirectStandardOutput $so -RedirectStandardError $se

    foreach ($k in $WithEnv.Keys) { Remove-Item -Path ('env:' + $k) -ErrorAction SilentlyContinue }
    return $p.ExitCode
}

function Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
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
$rc = Invoke-Monitor -OutputPath $d3 -WithEnv @{ MOCK_ACTIVE_ELSEWHERE = '1' }
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
$rc = Invoke-Monitor -OutputPath $d4 -WithEnv @{ MOCK_FAIL_DB = 'CLAB-DAGA-DB02' }
Assert 'exits 2 for partial results' ($rc -eq 2) ('got exit ' + $rc)
$rows4 = Get-Csv $d4
Assert 'surviving databases still collected' ($rows4.Count -eq 10) ('got ' + $rows4.Count + ' rows')
$log4 = Get-Log $d4
Assert 'names the database that failed' (@($log4 | Where-Object { $_ -match 'Not collected: CLAB-DAGA-DB02' }).Count -eq 1)
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
    Assert 'clean run marked completed' ($sum.Completed -eq $true -and $sum.Status -eq 'OK') `
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
    (@($log17 | Where-Object { $_ -match 'Run budget of 0\.05 minute\(s\) is spent; database \[CLAB-DAGA-DB03\]' }).Count -eq 1) `
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
Assert 'skipped database reported as not collected' ($null -ne $sum17 -and $sum17.FailedDatabases -match 'CLAB-DAGA-DB03')

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
# Found by running v1.3.0 against the lab, not by the mock. On w25-ex01, 44 of
# 66 rows were health, arbitration, system and archive mailboxes with no index
# at all. Escalating on notPopulated -eq totalRows therefore never fired, and a
# server where every indexed mailbox was affected reported WARN. The denominator
# has to be the indexed population.
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
Assert 'the log reports the indexed population as the denominator' `
    (@($log21 | Where-Object { $_ -match '15 of 15 indexed mailbox\(es\) \(60 evaluated in total\)' }).Count -eq 1) `
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
Assert 'and a partial outage is not a metric outage' `
    ($null -ne $sum28c -and $sum28c.Status -eq 'OK') `
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
      -WithEnv @{ MOCK_NOTPOPULATED = 'all'; MOCK_FAIL_DB = 'CLAB-DAGA-DB02' }
Assert 'a partial collection outranks the outage verdict' ($rc -eq 2) ('got exit ' + $rc)
$sum28e = Get-Summary $d28e
Assert 'and the summary says Partial, not MetricUnavailable' `
    ($null -ne $sum28e -and $sum28e.Status -eq 'Partial') `
    ('got [' + $(if ($sum28e) { $sum28e.Status } else { 'n/a' }) + ']')

Write-Host ''
Write-Host ('RESULT: ' + $pass + ' passed, ' + $fail + ' failed') -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }

