<#
.SYNOPSIS
    Closes the Monitor-BigFunnelPostingList gates that no automated test can reach.

.DESCRIPTION
    Several things about this feature are unprovable from the test suite, for the
    same reason in every case: the suite runs NON-ELEVATED and against a mock, and
    the gates are about what the real, elevated machine actually does.

      GATE A  The Event Log rights split. Measured non-elevated on a workstation:
              creating a source needs administrator, writing to an existing source
              does not, and SourceExists() THROWS for a caller who cannot enumerate
              the log list. The elevated half has never been measured. It matters
              because Initialize-EmitEventSource treats a throw as INDETERMINATE
              rather than as "absent", and that decision is only correct if an
              elevated caller gets a clean $false instead.

      GATE B  A real registration. The suite cannot reach the registration happy
              path at all - Test-IsElevated has no mock hook - so the whole of it is
              tested by lifting the function out with the AST. That proves the logic
              and proves nothing about the scheduler. The specific thing to confirm
              is LogonType Password: commit 54ebad7 measured that -User WITHOUT
              -Password is accepted without complaint, reports success, and registers
              a task that sits at Ready with LastTaskResult 0x41303 and never runs.

    Gate A runs by default and is close to read-only: its one lasting effect is
    creating the event source, which is what a production deployment wants anyway.
    Gate B creates a REAL SCHEDULED TASK and runs a REAL COLLECTION against Exchange,
    so it is behind an explicit switch and cleans up in a finally block.

    Run this ELEVATED on w25-ex01. Paste the RESULTS block at the end into the
    branch-state log, so the gate closes with a measurement rather than an assertion.

.EXAMPLE
    .\Verify-LabGates.ps1
    Gate A only. Measures the Event Log rights split and creates the source.

.EXAMPLE
    .\Verify-LabGates.ps1 -RunGateB -TaskCredential (Get-Credential CONTOSO\svc-bfmon)
    Both gates. Registers, forces one run, checks what landed, then unregisters.

.EXAMPLE
    .\Verify-LabGates.ps1 -RunGateC -RunGateD `
        -TaskCredential (Get-Credential CONTOSO\svc-bfmon) `
        -ProbeCredential (Get-Credential CONTOSO\ordinary.user)
    Gates C and D. -ProbeCredential is the one that matters where UAC is off: an
    ordinary user has no elevated half, so Gate C's probe measures the non-elevated
    write instead of reporting that it could not produce a filtered token.

.EXAMPLE
    .\Verify-LabGates.ps1 -RunGateE -TaskCredential (Get-Credential CONTOSO\svc-bfmon)
    Gate E only - event 1012, the one per-mailbox event no threshold can force.
    Stages a growth rate with Set-BigFunnelDemoState.ps1, then runs the monitor
    against it as a real scheduled task. The rate is a fixture and the gate says
    so; the classifier, the projection and the event are real.
#>
[CmdletBinding()]
param(
    # Gate B is opt-in because it registers a real task and runs a real collection.
    [switch]$RunGateB,

    # Needs a password. That IS the gate - see LogonType Password above.
    [System.Management.Automation.PSCredential]$TaskCredential,

    [string]$EventLogSource = 'BigFunnelPostingListMonitor',

    [string]$TaskName = 'BFGATE Exchange BigFunnel PostingListTable Monitor',

    [string]$OutputPath = (Join-Path $env:ProgramData 'ExchangeBigFunnelPostingListMonitor'),

    # The forced run is a real collection against a real estate. Local scope keeps it
    # to this server; the default of All would sweep the organisation.
    [int]$RunTimeoutMinutes = 15,

    # Gate C drives a NON-elevated write, which needs a filtered token this elevated
    # session cannot produce for itself. Needs -TaskCredential for the same reason B does.
    [switch]$RunGateC,

    # THE ONLY WAY GATE C MEASURES ANYTHING WHERE UAC IS OFF.
    #
    # RunLevel Limited (TASK_RUNLEVEL_LUA) asks for the filtered half of a UAC split
    # token. With EnableLUA=0 there is no split token to take a half of, so an admin
    # account runs full, the probe reports 12, and the gate is permanently
    # inconclusive - measured on w25-ex01 2026-09-17, where this is exactly what
    # happened. Exchange servers and lab builds are both common places to find UAC off.
    #
    # A NON-ADMINISTRATOR account has no elevated half in the first place, so it needs
    # no filtering and RunLevel stops mattering. Supply an ordinary domain user here
    # and the claim gets measured for real rather than diagnosed.
    #
    # Falls back to -TaskCredential when absent, which is the old behaviour.
    [System.Management.Automation.PSCredential]$ProbeCredential,

    # Gate D forces per-mailbox classifications by moving the thresholds under real
    # measured sizes. Two real collections, so it is opt-in and it is not quick.
    [switch]$RunGateD,

    # THE ONLY GATE THAT USES A FIXTURE, AND IT SAYS SO IN ITS OWN OUTPUT.
    #
    # Gate D can force Critical and Warning by moving the thresholds under real
    # sizes, because those two are decided by one reading. 1012 is not: Emerging
    # is Status Normal AND 0 < DaysToCritical <= 3, which needs a growth RATE,
    # which needs two readings that differ. This estate has read the same three
    # values since 2026-09-11, so no threshold anywhere reaches 1012.
    #
    # Set-BigFunnelDemoState.ps1 manufactures the missing earlier reading - one
    # cell in one back-dated CSV - and that is what this gate drives. So what is
    # measured here is the CLASSIFIER AND THE EVENT PATH on a real mailbox, from
    # a growth rate that is fabricated. Everything downstream of the rate is
    # genuine; the rate is not. The gate prints that distinction next to its own
    # result so a PASS cannot be quoted as "we observed growth in the lab".
    #
    # Three real collections. Slower than Gate D, and opt-in for the same reason.
    [switch]$RunGateE,

    # Leave the source behind by default: production wants it, and creating it is the
    # one administrator-only step in the whole emit path.
    [switch]$RemoveEventSource
)

$ErrorActionPreference = 'Stop'
$results = [ordered]@{}
$script:Failed = 0
$script:NotMeasured = 0

function Write-Head { param($Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan; Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray }
function Write-Measured { param($Label, $Value) Write-Host ('  {0} {1}' -f $Label.PadRight(46), $Value) }
function Write-Check {
    param($Label, [bool]$Ok, $Detail = '')
    if (-not $Ok) { $script:Failed++ }
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $col = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ('  {0}  {1} {2}' -f $tag, $Label.PadRight(46), $Detail) -ForegroundColor $col
}

function Write-NotMeasured {
    # A THIRD OUTCOME, and the gates were wrong without it.
    #
    # A check can fail three ways, and only one of them is the product's fault:
    # the thing is broken, the harness could not create the conditions to look at
    # it, or the estate cannot reach the case at all. The first is a FAIL. The
    # other two are NOT MEASURED - the measurement did not happen, so there is no
    # verdict to report in either direction.
    #
    # Measured on w25-ex01 2026-09-17: the gates reported "4 failed" and every
    # one of the four was this. Two were Gate C's token never being filtered, two
    # were Gate D's runs aborting before they collected anything. Nothing was
    # learned about the product, and the tally said it had failed four times.
    # Both gates already SAID "INCONCLUSIVE" and "NOT MEASURED" in their detail
    # text while scoring the line as a failure anyway.
    #
    # Deliberately does NOT touch $script:Failed. A gap that inflates the failure
    # count trains whoever reads it to discount failures.
    param($Label, $Detail = '')
    $script:NotMeasured++
    Write-Host ('  {0}  {1} {2}' -f 'N/M ', $Label.PadRight(46), $Detail) -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
Write-Head 'Pre-flight'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Measured 'Running as' $id.Name
Write-Check 'elevated' $elevated $(if ($elevated) { '' } else { 'BOTH GATES NEED THIS. Re-run as administrator.' })
if (-not $elevated) { exit 1 }

Write-Measured 'Computer' $env:COMPUTERNAME
Write-Measured 'PowerShell' $PSVersionTable.PSVersion
Write-Measured 'Started (UTC)' ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))

$monitor = Join-Path (Split-Path $PSScriptRoot -Parent) 'Monitor-BigFunnelPostingList.ps1'
Write-Check 'monitor script found' (Test-Path -LiteralPath $monitor) $monitor
if (-not (Test-Path -LiteralPath $monitor)) { exit 1 }

# THE MIRROR OF T54, and the reason it is here: the suite asserts the MOCK won, so
# this has to assert the REAL module did. run-tests.ps1 prepends _mockmodules to
# PSModulePath, and a lab gate that ran against the mock would report a clean pass
# having proved nothing at all about this machine.
#
# DISCRIMINATE ON THE PATH, NEVER ON CommandType. ScheduledTasks is a CDXML module,
# so PowerShell generates its commands as FUNCTIONS: measured 2026-09-16 on both
# MEGAPIG and w25-ex01, Get-Command Register-ScheduledTask reports
# Function / ScheduledTasks with a path under %SystemRoot%. The mock is a .psm1 and
# therefore also exports functions, so CommandType cannot tell the two apart at all.
# The first version of this check demanded CommandType -eq 'Cmdlet' and so failed on
# every real machine while passing on none - it cost a lab trip. T54 gets this right
# at run-tests.ps1:2353 by testing Module.Path alone; this is its mirror image.
$reg = Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue
$regPath = if ($reg) { [string]$reg.Module.Path } else { '' }
# AN EMPTY PATH IS NOT A PASS. -notlike '*_mockmodules*' is TRUE for the empty
# string, so excluding the mock without also requiring a known-good location would
# report success for a module it could not identify at all - a false clean in the
# one direction this check exists to prevent.
$realCmdlets = [bool]$reg -and [bool]$regPath -and
               ($regPath -notlike '*_mockmodules*') -and
               ($regPath -like (Join-Path $env:SystemRoot '*'))
Write-Check 'Register-ScheduledTask is the REAL module' $realCmdlets `
    $(if ($regPath) { $regPath } elseif ($reg) { 'found, but no module path to identify it by' }
      else { 'Register-ScheduledTask not found at all' })
if (-not $realCmdlets) {
    Write-Host '  The mock module is shadowing the real one. Open a fresh session.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# GATE A - the Event Log rights split, elevated
# ---------------------------------------------------------------------------
Write-Head 'GATE A - Event Log rights, ELEVATED'

# A name that certainly does not exist. Under 255 characters on purpose: over that
# the registry key-name check fires first and the probe would measure the wrong
# thing entirely (that trick is how T58 injects a deterministic emit failure).
$absent = 'BFGateProbe' + ([guid]::NewGuid().ToString('N'))

$aExistsThrew = $false
try {
    $aExists = [System.Diagnostics.EventLog]::SourceExists($absent)
    Write-Measured 'SourceExists(<absent>)' $aExists
}
catch {
    $aExistsThrew = $true
    $aExists = $null
    Write-Measured 'SourceExists(<absent>)' ('THREW: ' + $_.Exception.Message)
}

# THE GATE. Non-elevated this throws, which is why Initialize-EmitEventSource reads a
# throw as indeterminate and lets the WRITE be the test. Elevated it is expected to
# answer cleanly. If it throws here too, that function's comment is understating the
# problem and the runbook's IMPORTANT block needs rewording - record which it was.
Write-Check 'elevated SourceExists(<absent>) answers without throwing' `
    (-not $aExistsThrew) $(if ($aExistsThrew) { 'It threw. The runbook says elevated callers get a clean answer - correct it.' } else { "returned $aExists" })

$sourceExistedAlready = $false
try { $sourceExistedAlready = [System.Diagnostics.EventLog]::SourceExists($EventLogSource) } catch { }
Write-Measured 'source already present' $sourceExistedAlready

if (-not $sourceExistedAlready) {
    try {
        New-EventLog -LogName Application -Source $EventLogSource -ErrorAction Stop
        Write-Check 'New-EventLog creates the source when elevated' $true $EventLogSource
    }
    catch {
        Write-Check 'New-EventLog creates the source when elevated' $false $_.Exception.Message
    }
}
else {
    Write-Host '  SKIP  source already existed; creation not exercised this run' -ForegroundColor Yellow
}

# Writing to an existing source. Measured as working non-elevated on a workstation;
# confirm it also works here, because this is the call every scheduled run makes.
$gateAEventId = 1000
try {
    Write-EventLog -LogName Application -Source $EventLogSource -EventId $gateAEventId `
        -EntryType Information -Message ("BFGATE probe`nkey=value`nGate=A") -ErrorAction Stop
    Start-Sleep -Milliseconds 700
    $probe = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'; ProviderName = $EventLogSource; Id = $gateAEventId
    } -MaxEvents 1 -ErrorAction Stop
    Write-Check 'a written event is readable back' ($null -ne $probe) `
        ('id {0}, {1}' -f $probe.Id, $probe.TimeCreated)
}
catch {
    Write-Check 'a written event is readable back' $false $_.Exception.Message
}

$results['GateA_SourceExistsAbsentThrew'] = $aExistsThrew
$results['GateA_SourceExistsAbsentValue'] = $aExists
$results['GateA_SourcePreexisted']        = $sourceExistedAlready

# THE OTHER HALF OF GATE A CANNOT BE DONE FROM THIS SESSION. A non-elevated write to
# the source that now exists is the case a non-elevated ad-hoc run depends on, and an
# elevated session cannot drop its own token honestly enough to prove it. Do it by
# hand, in an ORDINARY PowerShell window:
Write-Host ''
Write-Host '  NON-ELEVATED HALF - run this in an ORDINARY (not elevated) window:' -ForegroundColor Yellow
Write-Host ("    Write-EventLog -LogName Application -Source '{0}' -EventId 1000 -EntryType Information -Message 'non-elevated probe'" -f $EventLogSource) -ForegroundColor Gray
Write-Host '    # expected: succeeds, because the source now exists. Record the result.' -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# GATE B - a real registration
# ---------------------------------------------------------------------------
if (-not $RunGateB) {
    Write-Head 'GATE B - SKIPPED'
    Write-Host '  Re-run with -RunGateB and -TaskCredential to register for real.' -ForegroundColor Yellow
}
else {
    Write-Head 'GATE B - real registration on this machine'

    if (-not $TaskCredential) {
        # Prompting here rather than refusing: this is an interactive lab tool, unlike
        # the monitor itself, which refuses because a prompt inside a scheduled task
        # hangs until the execution time limit kills it.
        $TaskCredential = Get-Credential -Message 'Account to run the scheduled task (a PASSWORD is required - that is the gate)'
    }

    $startedAt = Get-Date
    try {
        # A task name prefixed BFGATE so it can never collide with a production
        # registration, and -TaskStartTime far enough out that only the forced run
        # below ever fires.
        & $monitor -Scope Local -RetentionDays 30 `
            -EmitTo EventLog,RunJson -EventLogSource $EventLogSource `
            -OutputPath $OutputPath `
            -RegisterScheduledTask -TaskName $TaskName `
            -TaskIntervalHours 4 -TaskStartTime 23:55 `
            -TaskCredential $TaskCredential
        $regExit = $LASTEXITCODE
        Write-Check 'registration exits 0' ($regExit -eq 0) ('exit ' + $regExit)

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop

        # THE GATE ITSELF.
        Write-Measured 'LogonType' $task.Principal.LogonType
        Write-Check 'LogonType is Password, not Interactive or S4U' `
            ($task.Principal.LogonType -eq 'Password') `
            $(if ($task.Principal.LogonType -eq 'Interactive') { 'Interactive = a task that never runs (0x41303). See 54ebad7.' } else { '' })

        Write-Check 'RunLevel is Highest' ($task.Principal.RunLevel -eq 'Highest') $task.Principal.RunLevel

        $argLine = $task.Actions[0].Arguments
        Write-Measured 'Action arguments' $argLine
        Write-Check 'action uses -File, never -Command' `
            (($argLine -match '(?i)\s-File\s') -and ($argLine -notmatch '(?i)\s-Command\s')) `
            '-Command collapses every non-zero exit to 1'
        Write-Check 'the task carries -EmitTo across' ($argLine -match '(?i)-EmitTo') ''
        Write-Check 'the task-building parameters are excluded' `
            ($argLine -notmatch '(?i)-RegisterScheduledTask' -and
             $argLine -notmatch '(?i)-TaskCredential' -and
             $argLine -notmatch '(?i)-TaskIntervalHours') ''

        $results['GateB_LogonType'] = [string]$task.Principal.LogonType
        $results['GateB_RunLevel']  = [string]$task.Principal.RunLevel
        $results['GateB_Arguments'] = [string]$argLine

        # Force one run. Start-ScheduledTask rather than waiting for the trigger,
        # because the trigger is hours away by design.
        Write-Host ''
        Write-Host '  Forcing one run. This is a REAL collection and takes minutes.' -ForegroundColor Yellow
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

        # WAIT FOR IT TO START BEFORE WAITING FOR IT TO FINISH, because the two
        # look identical and the gate's whole verdict turns on telling them apart.
        # Start-ScheduledTask returns as soon as the request is queued, and the
        # scheduler takes a second or two more to move the task to Running. Poll
        # straight into the finish loop and a slow transition reads as Ready on the
        # first pass, the loop exits immediately, and LastTaskResult is still the
        # 0x41303 the task was registered with - so a task that was about to run
        # correctly gets reported as exactly the never-ran failure this gate exists
        # to detect. A false FAIL here is worse than a missed one: it condemns the
        # feature on evidence that is really just impatience.
        $startDeadline = (Get-Date).AddSeconds(90)
        $everRan = $false
        do {
            Start-Sleep -Seconds 2
            $state = (Get-ScheduledTask -TaskName $TaskName).State
            if ($state -eq 'Running') { $everRan = $true }
        } while (-not $everRan -and (Get-Date) -lt $startDeadline)

        Write-Check 'the scheduler actually started the task' $everRan `
            $(if ($everRan) { 'observed Running' } else { 'never left Ready in 90s - the run below measured nothing' })

        $deadline = (Get-Date).AddMinutes($RunTimeoutMinutes)
        do {
            Start-Sleep -Seconds 10
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            $state = (Get-ScheduledTask -TaskName $TaskName).State
            Write-Host ('    state {0}, last result 0x{1:X}' -f $state, $info.LastTaskResult) -ForegroundColor DarkGray
        } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

        Write-Check 'the run finished inside the timeout' ($state -ne 'Running') ('state ' + $state)

        # 0x41303 is "has not run"; anything non-zero that is not a documented monitor
        # exit code is a scheduler fault rather than a finding.
        Write-Measured 'LastTaskResult' ('0x{0:X} ({0})' -f $info.LastTaskResult)
        # THE DETAIL MUST BRANCH ON THE RESULT, not only on $everRan. Measured
        # 2026-09-16 on w25-ex01: a clean run printed
        #   PASS  LastTaskResult is not 0x41303 ... that value is exactly the
        #   Interactive-logon failure this gate exists for
        # next to a LastTaskResult of 0x0 - a sentence describing the exact
        # opposite of what had just been measured, sitting beside the word PASS.
        # These lines are the only thing an operator reading the log afterwards
        # has, so a detail that contradicts its own verdict is worse than none.
        $neverRan = $info.LastTaskResult -eq 0x41303
        Write-Check 'LastTaskResult is not 0x41303 (never ran)' (-not $neverRan) `
            $(if (-not $neverRan) { 'the task ran and reported a real exit code' }
              elseif ($everRan) { 'that value is exactly the Interactive-logon failure this gate exists for' }
              else { 'and the task was never seen Running, so read this as the start failure above, NOT as the logon-type finding' })
        Write-Check 'LastTaskResult is a documented monitor exit code (0-7)' `
            ($info.LastTaskResult -ge 0 -and $info.LastTaskResult -le 7) `
            'anything else came from the scheduler, not the script'
        $results['GateB_LastTaskResult'] = ('0x{0:X}' -f $info.LastTaskResult)
        $results['GateB_ObservedRunning'] = $everRan

        # Did the run event actually land?
        try {
            $ev = Get-WinEvent -FilterHashtable @{
                LogName = 'Application'; ProviderName = $EventLogSource; StartTime = $startedAt
            } -ErrorAction Stop
            $runEv = @($ev | Where-Object { $_.Id -ge 1000 -and $_.Id -le 1007 -or $_.Id -eq 1099 })
            $mbxEv = @($ev | Where-Object { $_.Id -ge 1010 -and $_.Id -le 1012 })
            Write-Check 'a run event landed' ($runEv.Count -ge 1) `
                ('ids: ' + (($runEv | ForEach-Object { '{0}/{1}' -f $_.Id, $_.LevelDisplayName }) -join ', '))
            Write-Measured 'per-mailbox events' $mbxEv.Count
            if ($runEv.Count -ge 1) {
                Write-Check 'the payload is key=value' `
                    ($runEv[0].Message -match '(?m)^\w+=') ''
                $results['GateB_RunEventId']   = $runEv[0].Id
                $results['GateB_RunEventType'] = $runEv[0].LevelDisplayName
            }
            $results['GateB_MailboxEventCount'] = $mbxEv.Count
        }
        catch {
            Write-Check 'a run event landed' $false $_.Exception.Message
        }

        # And the per-run JSON?
        $json = @(Get-ChildItem -LiteralPath $OutputPath -Filter 'BigFunnelPostingListMonitor-*.json' `
                    -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $startedAt })
        Write-Check 'a per-run JSON landed' ($json.Count -ge 1) `
            (($json | Select-Object -First 1 -ExpandProperty Name) -join '')
        if ($json.Count -ge 1) {
            $obj = Get-Content -LiteralPath $json[0].FullName -Raw | ConvertFrom-Json
            Write-Measured 'Status / ExitCode' ('{0} / {1}' -f $obj.Status, $obj.ExitCode)
            Write-Measured 'EmitErrors' $(if ($obj.EmitErrors) { $obj.EmitErrors -join '; ' } else { '(none)' })
            Write-Check 'EmitErrors is empty on a healthy emit' `
                (-not $obj.EmitErrors) 'non-empty here means a channel failed without moving the exit code, which is correct behaviour but should be understood'
            $results['GateB_Status']     = [string]$obj.Status
            $results['GateB_ExitCode']   = $obj.ExitCode
            $results['GateB_EmitErrors'] = $(if ($obj.EmitErrors) { $obj.EmitErrors -join '; ' } else { '' })
        }
    }
    catch {
        # WITHOUT THIS, ONE THROW COSTS THE WHOLE TRIP. $ErrorActionPreference is
        # Stop, so any cmdlet in Gate B can terminate the script - and a bare
        # try/finally lets that propagate straight past the RESULTS block at the
        # bottom. The operator is running this on a server they had to RDP into,
        # and the measurement is the only thing they came back with; losing Gate A's
        # results to a Gate B exception is the worst outcome available here.
        Write-Check 'Gate B ran to completion' $false $_.Exception.Message
        $results['GateB_Exception'] = $_.Exception.Message
    }
    finally {
        # ALWAYS, even on a failed assertion above: this created a real task on a real
        # server and leaving it behind is worse than any gate it failed. Ask the
        # SCHEDULER whether a task is there rather than trusting a flag set partway
        # through the try - if registration succeeded and the very next call threw,
        # the flag is still $false and the task is still on the box.
        $present = $false
        try { Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null; $present = $true } catch { }
        if ($present) {
            Write-Host ''
            Write-Host '  Unregistering.' -ForegroundColor Yellow
            try {
                & $monitor -UnregisterScheduledTask -TaskName $TaskName
                Write-Check 'unregister exits 0' ($LASTEXITCODE -eq 0) ('exit ' + $LASTEXITCODE)
            }
            catch {
                Write-Check 'unregister exits 0' $false $_.Exception.Message
            }

            $gone = $false
            try { Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
            catch { $gone = $true }
            Write-Check 'the task is really gone' $gone `
                $(if (-not $gone) { "REMOVE IT BY HAND: Unregister-ScheduledTask -TaskName '$TaskName'" } else { '' })
        }
    }
}

# ---------------------------------------------------------------------------
# GATE C - the non-elevated write, which an elevated session cannot fake
# ---------------------------------------------------------------------------
# THIS IS THE HALF OF GATE A THAT USED TO BE LEFT MANUAL, and why it was manual is
# worth keeping rather than deleting: an elevated process cannot drop its own token
# honestly enough to prove that a NON-elevated caller can write to a source that
# already exists. The whole emit design rests on that asymmetry - create the source
# once as administrator, write to it forever after under whatever token the run
# happens to hold - so asserting it from an elevated session assumes the thing being
# tested.
#
# WINRM CANNOT DO IT EITHER, and that is the trap that makes this gate necessary
# rather than merely convenient. A PSSession hands a domain administrator a FULL
# token, so a remote probe measures the elevated case a second time and reports a
# confident pass having proved nothing. Measured 2026-09-16: the manual attempt
# instead went into the wrong window entirely and failed on a machine where the
# source had never existed, which looks identical to a real failure.
#
# A scheduled task with RunLevel Limited is the one remotely-drivable way to get a
# genuinely filtered token - TASK_RUNLEVEL_LUA is the same UAC split token an
# ordinary window gets.
#
# THE VERDICT TRAVELS AS AN EXIT CODE, not as a file. The probe runs under a filtered
# token that may have write access nowhere useful, so a result file is best-effort
# detail only; LastTaskResult is always readable and cannot be denied to us.
#   10 = not elevated, write SUCCEEDED   <- the gate
#   11 = not elevated, write FAILED
#   12 = token was ELEVATED, so RunLevel Limited did not filter: INCONCLUSIVE, not a
#        pass and not a fail, because it measured the wrong thing
#   13 = the probe threw before it could decide
if (-not $RunGateC) {
    Write-Head 'GATE C - SKIPPED'
    Write-Host '  Re-run with -RunGateC and -TaskCredential for the non-elevated write.' -ForegroundColor Yellow
    Write-Host '  Add -ProbeCredential with an ORDINARY USER if UAC is off on this box, or the' -ForegroundColor Yellow
    Write-Host '  probe can only report 12 (token was never filtered).' -ForegroundColor Yellow
}
else {
    Write-Head 'GATE C - a genuinely non-elevated write'

    if (-not $TaskCredential) {
        $TaskCredential = Get-Credential -Message 'Account for the Limited-runlevel probe task (a PASSWORD is required)'
    }

    # The account the PROBE runs as, which is not necessarily the account that
    # registers it. A non-admin here is what turns a 12 into a 10 or an 11 - see
    # the -ProbeCredential comment in the param block.
    $probeCred = if ($ProbeCredential) { $ProbeCredential } else { $TaskCredential }
    $results['GateC_ProbeAccount']   = $probeCred.UserName
    $results['GateC_ProbeIsDistinct'] = [bool]$ProbeCredential
    Write-Measured 'probe runs as' ($probeCred.UserName + $(if ($ProbeCredential) { '' } else { ' (same as -TaskCredential)' }))
    if (-not $ProbeCredential) {
        Write-Host '  No -ProbeCredential: if that account is an administrator and UAC is off, this' -ForegroundColor DarkGray
        Write-Host '  gate can only report 12. Pass an ordinary user to measure it.' -ForegroundColor DarkGray
    }

    $gateCTask = 'BFGATEC Non-Elevated Event Write'
    $probeDir  = Join-Path $env:ProgramData 'BFGateC'
    $probeFile = Join-Path $probeDir 'nonelev-probe.ps1'
    $resultFn  = Join-Path $probeDir 'result.txt'

    # Taken before registration, and used both to decide whether the task really ran
    # and to bound the event query. A second early rather than late: LastRunTime has
    # whole-second resolution, so a mark taken in the same second as the start can be
    # equal to it and read as "never ran".
    $startedAtC = (Get-Date).AddSeconds(-1)

    try {
        if (-not (Test-Path -LiteralPath $probeDir)) {
            New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
        }

        # Best-effort only, and deliberately not asserted. A filtered admin token keeps
        # the USER sid and loses the Administrators one, so it inherits ProgramData's
        # read-only-for-Users ACL. Granting Modify lets the probe leave a message
        # behind; if the grant fails the exit code still carries the verdict.
        # Granted to the PROBE account, which may not be the registering one.
        try {
            $acl  = Get-Acl -LiteralPath $probeDir
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $probeCred.UserName, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $probeDir -AclObject $acl
        }
        catch {
            Write-Host ('  (could not grant write on {0}: {1} - relying on the exit code)' -f $probeDir, $_.Exception.Message) -ForegroundColor DarkGray
        }

        # Placeholders rather than -f, because the body is full of braces.
        $probeBody = @'
$ErrorActionPreference = 'Stop'
$src  = '__SOURCE__'
$out  = '__OUT__'
$elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$code = 13
$msg  = 'the probe threw before deciding'
try {
    if ($elev) {
        $code = 12
        $msg  = 'token was ELEVATED - RunLevel Limited did not filter, so this measured the wrong thing'
    }
    else {
        try {
            Write-EventLog -LogName Application -Source $src -EventId 1000 -EntryType Information -Message 'Gate C: non-elevated write to an existing source'
            $code = 10
            $msg  = 'write succeeded under a filtered token'
        }
        catch {
            $code = 11
            $msg  = $_.Exception.Message
        }
    }
}
catch { $code = 13; $msg = $_.Exception.Message }
try { Set-Content -LiteralPath $out -Encoding UTF8 -Value @("elevated=$elev", "code=$code", "message=$msg") } catch { }
exit $code
'@
        $probeBody = $probeBody.Replace('__SOURCE__', $EventLogSource).Replace('__OUT__', $resultFn)
        Set-Content -LiteralPath $probeFile -Value $probeBody -Encoding UTF8

        if (Test-Path -LiteralPath $resultFn) { Remove-Item -LiteralPath $resultFn -Force }

        # -File, never -Command, for the same reason the monitor's own action uses it:
        # -Command collapses every non-zero exit to 1, and this gate reads the exit code.
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $probeFile)
        $trigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.Date.AddDays(1).AddHours(23).AddMinutes(55))

        try {
            Register-ScheduledTask -TaskName $gateCTask -Action $action -Trigger $trigger `
                -User $probeCred.UserName `
                -Password $probeCred.GetNetworkCredential().Password `
                -RunLevel Limited -Force | Out-Null
        }
        catch {
            # A NON-ADMIN PROBE ACCOUNT NEEDS "Log on as a batch job". Without
            # SeBatchLogonRight the registration fails here rather than at run time,
            # and the message names the account rather than the missing right - which
            # reads as a bad password. That is a property of the estate, not of the
            # monitor, so it is NOT MEASURED rather than a failure.
            Write-NotMeasured 'probe task registered' $_.Exception.Message
            Write-Host ''
            Write-Host ('  LIKELY CAUSE: {0} may lack "Log on as a batch job" on this machine.' -f $probeCred.UserName) -ForegroundColor Yellow
            Write-Host '  Grant it in secpol.msc under Local Policies > User Rights Assignment, or use' -ForegroundColor Yellow
            Write-Host '  an account that already has it. The monitor is not involved in this either way.' -ForegroundColor Yellow
            throw ('NOT-MEASURED: the probe task could not be registered as {0}' -f $probeCred.UserName)
        }

        $ct = Get-ScheduledTask -TaskName $gateCTask -ErrorAction Stop
        $results['GateC_RunLevel']  = $ct.Principal.RunLevel
        $results['GateC_LogonType'] = $ct.Principal.LogonType
        Write-Check 'probe task registered with RunLevel Limited' `
            ($ct.Principal.RunLevel -eq 'Limited') ('RunLevel ' + $ct.Principal.RunLevel)
        Write-Check 'probe task LogonType is Password' `
            ($ct.Principal.LogonType -eq 'Password') ('LogonType ' + $ct.Principal.LogonType)

        Start-ScheduledTask -TaskName $gateCTask

        # Same two-stage wait Gate B learned the hard way: a task about to run correctly
        # must not be read as one that never ran.
        $deadline = (Get-Date).AddMinutes(3)
        $everRan  = $false
        while ((Get-Date) -lt $deadline) {
            $info = Get-ScheduledTaskInfo -TaskName $gateCTask
            $st   = (Get-ScheduledTask -TaskName $gateCTask).State
            if ($st -eq 'Running') { $everRan = $true }
            if ($everRan -and $st -ne 'Running') { break }
            if ($info.LastRunTime -gt $startedAtC) { $everRan = $true }
            Start-Sleep -Seconds 2
        }
        Start-Sleep -Seconds 2

        $info = Get-ScheduledTaskInfo -TaskName $gateCTask
        $code = $info.LastTaskResult
        $results['GateC_LastTaskResult'] = ('0x{0:X}' -f $code)
        Write-Measured 'LastTaskResult' ('0x{0:X} ({0})' -f $code)

        $msg = ''
        if (Test-Path -LiteralPath $resultFn) {
            $msg = ((Get-Content -LiteralPath $resultFn) -join '; ')
            Write-Measured 'probe said' $msg
        }
        $results['GateC_ProbeDetail'] = $msg

        Write-Check 'the probe task actually ran' ($code -ne 0x41303) `
            $(if ($code -eq 0x41303) { '0x41303 = never ran. Nothing was measured.' } else { '' })

        # THE GATE. 12 is not a failure of the feature - it is a failure of the
        # harness to create the conditions, and reporting it as a feature failure
        # would condemn working code on evidence about the test.
        #
        # MEASURED ON w25-ex01 2026-09-17: this is exactly what came back. The
        # first version of this branch still called Write-Check with $false, so
        # it printed the word INCONCLUSIVE next to the word FAIL and added two to
        # the failure count. It now scores as NOT MEASURED, which is what the
        # surrounding comment always claimed it did.
        if ($code -eq 12) {
            Write-NotMeasured 'the probe token was NOT elevated' `
                'RunLevel Limited did not filter the token, so the write was never tested non-elevated.'

            # WHY it did not filter, because "inconclusive" without a cause is a
            # dead end that gets re-run identically next trip. TASK_RUNLEVEL_LUA
            # asks for the filtered half of a UAC split token - and if UAC is off
            # there is no split token to take a half of, so every admin process
            # runs full and Limited is silently a no-op. Exchange servers and lab
            # builds are both common places to find EnableLUA=0.
            $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            $enableLua = $null; $filterAdmin = $null
            try { $enableLua   = (Get-ItemProperty -Path $uacKey -Name EnableLUA -ErrorAction Stop).EnableLUA } catch { }
            try { $filterAdmin = (Get-ItemProperty -Path $uacKey -Name FilterAdministratorToken -ErrorAction Stop).FilterAdministratorToken } catch { }

            $results['GateC_EnableLUA']               = $(if ($null -eq $enableLua)   { 'unreadable' } else { $enableLua })
            $results['GateC_FilterAdministratorToken'] = $(if ($null -eq $filterAdmin) { 'unreadable' } else { $filterAdmin })
            Write-Measured 'EnableLUA' $results['GateC_EnableLUA']
            Write-Measured 'FilterAdministratorToken' $results['GateC_FilterAdministratorToken']

            if ($enableLua -eq 0) {
                Write-Host ''
                Write-Host '  CAUSE: UAC is OFF on this machine (EnableLUA=0). There is no split token,' -ForegroundColor Yellow
                Write-Host '  so RunLevel Limited cannot filter anything and this gate can never pass' -ForegroundColor Yellow
                Write-Host ('  here as {0}.' -f $probeCred.UserName) -ForegroundColor Yellow
                if ($ProbeCredential) {
                    # -ProbeCredential WAS supplied and the token still came back
                    # elevated, which means the account is an administrator. That is
                    # the one thing the parameter cannot fix, and saying "UAC is off"
                    # alone would send the operator to the wrong knob.
                    Write-Host ''
                    Write-Host ('  AND {0} IS AN ADMINISTRATOR on this box - that is why it is still' -f $probeCred.UserName) -ForegroundColor Yellow
                    Write-Host '  elevated. -ProbeCredential only helps with an account that has no' -ForegroundColor Yellow
                    Write-Host '  elevated half at all. Use an ordinary domain user.' -ForegroundColor Yellow
                    $results['GateC_Verdict'] = 'NOT-MEASURED: -ProbeCredential account is itself an administrator'
                }
                else {
                    Write-Host '  Pass -ProbeCredential with an ordinary (non-administrator) account: it has' -ForegroundColor Yellow
                    Write-Host '  no elevated half to drop, so RunLevel stops mattering and this measures.' -ForegroundColor Yellow
                    $results['GateC_Verdict'] = 'NOT-MEASURED: UAC disabled, RunLevel Limited is a no-op here'
                }
            }
            elseif ($ProbeCredential) {
                Write-Host ''
                Write-Host ('  CAUSE: {0} came back elevated with UAC on, so it is an administrator and' -f $probeCred.UserName) -ForegroundColor Yellow
                Write-Host '  RunLevel Limited should have filtered it. Check FilterAdministratorToken' -ForegroundColor Yellow
                Write-Host '  above, or use an ordinary domain user, which needs no filtering.' -ForegroundColor Yellow
                $results['GateC_Verdict'] = 'NOT-MEASURED: -ProbeCredential account elevated despite UAC being on'
            }
            else {
                $results['GateC_Verdict'] = 'NOT-MEASURED: token was elevated, cause not established'
            }
        }
        else {
            Write-Check 'the probe token was NOT elevated' ($code -eq 10 -or $code -eq 11) ''
            Write-Check 'NON-ELEVATED write to an existing source SUCCEEDS' ($code -eq 10) `
                $(if ($code -eq 10) { 'this is the assumption the whole emit path rests on' }
                  elseif ($code -eq 11) { 'IT DOES NOT. The runbook and the script comment at Monitor:1726 are both wrong.' }
                  else { 'the probe threw before deciding - see GateC_ProbeDetail' })
        }

        # Corroborate from the log itself rather than trusting the probe's own word.
        $cEv = @(Get-WinEvent -FilterHashtable @{
                    LogName      = 'Application'
                    ProviderName = $EventLogSource
                    StartTime    = $startedAtC
                } -ErrorAction SilentlyContinue |
                 Where-Object { $_.Message -like '*Gate C*' })
        $results['GateC_EventLanded'] = $cEv.Count

        # ON 12 THE PROBE DELIBERATELY DID NOT WRITE, so an absent event is the
        # correct outcome and asserting on it measures nothing. Scoring it FAIL -
        # which is what happened on w25-ex01 - turns one gap into two, and the
        # second one reads like a broken event channel.
        if ($code -eq 12) {
            Write-NotMeasured 'and the event is really in the log' `
                'the probe returned 12 without writing, so there was never an event to find'
        }
        else {
            Write-Check 'and the event is really in the log' ($cEv.Count -ge 1) `
                ('{0} matching event(s)' -f $cEv.Count)
        }
    }
    catch {
        # A registration the estate refuses is a harness limitation, not a product
        # failure. It is raised with this prefix so the two can be told apart here;
        # the diagnosis was already printed where it was detected.
        if ($_.Exception.Message -like 'NOT-MEASURED:*') {
            $results['GateC_Verdict'] = $_.Exception.Message
        }
        else {
            Write-Check 'Gate C ran to completion' $false $_.Exception.Message
            $results['GateC_Exception'] = $_.Exception.Message
        }
    }
    finally {
        # Ask the scheduler, never a flag - see Gate B.
        $present = $false
        try { Get-ScheduledTask -TaskName $gateCTask -ErrorAction Stop | Out-Null; $present = $true } catch { }
        if ($present) {
            try {
                Unregister-ScheduledTask -TaskName $gateCTask -Confirm:$false
                $gone = $false
                try { Get-ScheduledTask -TaskName $gateCTask -ErrorAction Stop | Out-Null } catch { $gone = $true }
                Write-Check 'probe task removed' $gone `
                    $(if (-not $gone) { "REMOVE IT BY HAND: Unregister-ScheduledTask -TaskName '$gateCTask'" } else { '' })
            }
            catch { Write-Check 'probe task removed' $false $_.Exception.Message }
        }
        try { if (Test-Path -LiteralPath $probeDir) { Remove-Item -LiteralPath $probeDir -Recurse -Force } } catch { }
    }
}

# ---------------------------------------------------------------------------
# GATE D - the per-mailbox event path, 1010 / 1011 / 1012
# ---------------------------------------------------------------------------
# UNEXERCISED ON REAL HARDWARE UNTIL NOW, and for an honest reason: the lab estate is
# healthy, so Status came back OK and MailboxEventCount was 0. The suite covers this
# path against fixtures, but fixtures cannot show that a real row from a real
# Get-MailboxStatistics survives ConvertTo-KeyValueText and lands as an event.
#
# THE THRESHOLDS ARE MOVED, NOT THE DATA. Sizes stay whatever the estate really
# reports; -WarningGB and -CriticalGB are placed underneath them so real mailboxes
# classify. Classification is `$Bytes -ge $CriticalBytes -> Critical`, else
# `-ge $WarningBytes -> Warning` (Monitor:1145-1146), so bracketing is exact.
#
# OUTPUT GOES SOMEWHERE ELSE ON PURPOSE. These runs produce CSV and JSON full of
# Critical classifications that are artefacts of the thresholds, not findings about
# the estate. Writing them into the real output directory would leave evidence that
# reads as a genuine incident to anyone who finds it later.
#
# 1012 (Emerging) IS NOT FORCEABLE THIS WAY and the gate says so rather than
# failing: Emerging needs Status Normal AND DaysToCritical <= 3, which needs a growth
# rate, which needs the estate to actually be growing between baselines. A static lab
# cannot produce one. Reported as NOT-MEASURED, which is different from failed.
#
# ATTEMPTED ONCE AND ABORTED, 2026-09-17 on w25-ex01. The first version ran the
# monitor inline and both runs died on the WinRM double hop before collecting.
# The collection is now a registered scheduled task - the reasoning is at the run
# loop below, because that is where someone tempted to simplify it will be.
if (-not $RunGateD) {
    Write-Head 'GATE D - SKIPPED'
    Write-Host '  Re-run with -RunGateD to exercise the per-mailbox event path.' -ForegroundColor Yellow
}
else {
    Write-Head 'GATE D - per-mailbox events against real rows'

    $gateDOut = Join-Path $env:ProgramData 'BFGateD'

    # A name of its own, not $TaskName. Gate B's task and this one can be present
    # at the same moment if a gate dies between register and unregister, and two
    # gates sharing a name means the survivor's cleanup removes the other's task
    # out from under it.
    $gateDTask = 'BFGATED Exchange BigFunnel PostingListTable Forced Thresholds'

    try {
        # Read what the estate really reports before choosing anything.
        $csv = Get-ChildItem -LiteralPath $OutputPath -Filter '*.csv' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $csv) { throw ('No CSV under {0} to size the thresholds from. Run the monitor once first.' -f $OutputPath) }

        Write-Measured 'sizing from' $csv.Name
        $rows  = @(Import-Csv -LiteralPath $csv.FullName)
        $sizes = @($rows | ForEach-Object { [double]$_.PostingListGB } | Where-Object { $_ -gt 0 })
        $maxGB = if ($sizes.Count) { ($sizes | Measure-Object -Maximum).Maximum } else { 0 }

        $results['GateD_RowsInCsv']    = $rows.Count
        $results['GateD_RowsWithSize'] = $sizes.Count
        $results['GateD_MaxGB']        = $maxGB
        Write-Measured 'rows / with a size / largest GB' ('{0} / {1} / {2}' -f $rows.Count, $sizes.Count, $maxGB)

        # THE CRITICAL RUN CANNOT USE Warn = Crit, AND THIS GATE LEARNED THAT THE
        # EXPENSIVE WAY. Monitor:2066 refuses WarningGB -ge CriticalGB with exit 3,
        # correctly - if they are equal the warning tier can never fire. On
        # 2026-09-17 the Critical run asked for 0.001/0.001, exited 3 before printing
        # its banner, and collected nothing, while the Warning run passed cleanly.
        # THE PRODUCT WAS RIGHT AND THIS HARNESS WAS WRONG: it requested the exact
        # configuration the monitor exists to refuse.
        #
        # So Warn must sit strictly below Crit, and Crit must sit at or below a real
        # mailbox or nothing classifies Critical at all. Both are
        # ValidateRange(0.001, 1024), so the smallest legal pair is 0.001 / 0.002 -
        # and THAT is what the estate has to reach for this gate to mean anything,
        # not 0.001. The old guard let an estate through that could satisfy the
        # Warning run and never the Critical one, which would have read as a product
        # failure.
        $critFloor = 0.002

        if ($maxGB -lt $critFloor) {
            Write-NotMeasured 'the estate can support this test' `
                ('no mailbox reaches {0} GB - the smallest -CriticalGB that still leaves room for a lower -WarningGB. Unreachable by any legal pair.' -f $critFloor)
            $results['GateD_Verdict'] = 'NOT-MEASURED: estate below the threshold floor'
        }
        else {
            Write-Check 'the estate can support this test' $true ('largest posting list is {0} GB' -f $maxGB)

            # THE COLLECTION RUNS AS A SCHEDULED TASK, NOT IN THIS SESSION.
            #
            # The first version ran the monitor inline with & $monitor, on the
            # reasoning that a collection in the session is not a second hop.
            # That was wrong, and w25-ex01 proved it on 2026-09-17: the MONITOR
            # opens an Exchange runspace, which is a network logon, and over WinRM
            # the credential that authenticated the PSSession cannot be delegated
            # onward. Both runs exited 3 with "A specified logon session does not
            # exist" before collecting a single mailbox - and the gate then scored
            # two FAILs for events that never had a chance to be emitted.
            #
            # A task registered with -User AND -Password gets LogonType Password,
            # which DOES carry a network credential. That is precisely the
            # asymmetry Gate B exists to prove, so Gate D now leans on it - and it
            # is also the configuration a customer actually deploys, which makes
            # this the more faithful test of the two rather than merely the one
            # that works.
            if (-not $TaskCredential) {
                $TaskCredential = Get-Credential -Message 'Account to run the forced-threshold collection (a PASSWORD is required - it is what carries the network credential)'
            }
            if (-not $TaskCredential) { throw 'Gate D needs -TaskCredential to reach a collection. Nothing was run.' }

            # Crit strictly above Warn in BOTH rows - see $critFloor above. The
            # Critical run may also emit 1011s for anything landing between the two
            # thresholds; that is correct behaviour and the assertion below counts
            # 1010 specifically rather than assuming the run produced nothing else.
            $runs = @(
                @{ Label = 'Critical'; Id = 1010; Warn = 0.001; Crit = $critFloor }
                @{ Label = 'Warning';  Id = 1011; Warn = 0.001; Crit = 1024  }
            )

            # A run that completed, by exit code: 0 clean, 1 alert, 2 partial,
            # 6 emerging. 3 fatal / 4 already running / 5 blind / 7 task failure
            # all mean the thresholds were never applied to a single mailbox, so
            # an absent 1010 says nothing at all about the event path.
            $collectedCodes = @(0, 1, 2, 6)

            foreach ($r in $runs) {
                Write-Host ''
                Write-Host ('  Forcing {0} (-WarningGB {1} -CriticalGB {2}) as a scheduled task - a real collection, please wait.' -f
                    $r.Label, $r.Warn, $r.Crit) -ForegroundColor DarkGray

                $mark = Get-Date
                Start-Sleep -Seconds 1
                try {
                    # Registered through the PRODUCT's own switch rather than
                    # Register-ScheduledTask directly, so the argument line is
                    # built by ConvertTo-RelaunchArguments exactly as it would be
                    # for a customer. A parameter this gate silently loses is a
                    # parameter the feature silently loses.
                    & $monitor -RegisterScheduledTask -TaskName $gateDTask `
                        -Scope Local -RetentionDays 30 `
                        -WarningGB $r.Warn -CriticalGB $r.Crit `
                        -EmitTo EventLog,RunJson -EventLogSource $EventLogSource `
                        -OutputPath $gateDOut `
                        -TaskIntervalHours 24 -TaskStartTime '23:57' `
                        -TaskCredential $TaskCredential
                    $regEx = $LASTEXITCODE
                    $results[('GateD_{0}_RegisterExit' -f $r.Label)] = $regEx

                    if ($regEx -ne 0) {
                        Write-NotMeasured ('{0} run registers its task' -f $r.Label) `
                            ('registration exited {0} - 7 is a policy refusal. Nothing was collected.' -f $regEx)
                        continue
                    }

                    $dTask = Get-ScheduledTask -TaskName $gateDTask -ErrorAction Stop
                    Write-Check ('{0} run: LogonType is Password' -f $r.Label) `
                        ($dTask.Principal.LogonType -eq 'Password') `
                        ([string]$dTask.Principal.LogonType + ' - anything else carries no network credential and cannot open the runspace')

                    Start-ScheduledTask -TaskName $gateDTask -ErrorAction Stop

                    # Two-stage wait, for the reason spelled out in Gate B: a slow
                    # Ready->Running transition is indistinguishable from a run
                    # that already finished, and reading the second as the first
                    # condemns a task that was about to work.
                    $startBy = (Get-Date).AddSeconds(90)
                    $ran = $false
                    do {
                        Start-Sleep -Seconds 2
                        if ((Get-ScheduledTask -TaskName $gateDTask).State -eq 'Running') { $ran = $true }
                    } while (-not $ran -and (Get-Date) -lt $startBy)

                    $dInfo = Get-ScheduledTaskInfo -TaskName $gateDTask
                    $by    = (Get-Date).AddMinutes($RunTimeoutMinutes)
                    do {
                        Start-Sleep -Seconds 10
                        $dState = (Get-ScheduledTask -TaskName $gateDTask).State
                        $dInfo  = Get-ScheduledTaskInfo -TaskName $gateDTask
                        Write-Host ('    state {0}, last result 0x{1:X}' -f $dState, $dInfo.LastTaskResult) -ForegroundColor DarkGray
                    } while ($dState -eq 'Running' -and (Get-Date) -lt $by)

                    $ex = $dInfo.LastTaskResult
                    $results[('GateD_{0}_ExitCode' -f $r.Label)] = $ex
                    Write-Measured ('{0} run exit code' -f $r.Label) $ex

                    if (-not $ran) {
                        Write-NotMeasured ('{0} run emits event {1}' -f $r.Label, $r.Id) `
                            'the scheduler never moved the task out of Ready in 90s'
                        continue
                    }
                    if ($collectedCodes -notcontains $ex) {
                        Write-NotMeasured ('{0} run emits event {1}' -f $r.Label, $r.Id) `
                            ('the run exited {0} without collecting, so the thresholds were never applied to a mailbox' -f $ex)
                        continue
                    }

                    $ev = @(Get-WinEvent -FilterHashtable @{
                                LogName      = 'Application'
                                ProviderName = $EventLogSource
                                StartTime    = $mark
                            } -ErrorAction SilentlyContinue)
                    $hit = @($ev | Where-Object { $_.Id -eq $r.Id })
                    $results[('GateD_{0}_{1}Count' -f $r.Label, $r.Id)] = $hit.Count

                    Write-Check ('{0} run emits event {1}' -f $r.Label, $r.Id) ($hit.Count -ge 1) `
                        ('{0} event(s) of id {1}' -f $hit.Count, $r.Id)

                    if ($hit.Count -ge 1) {
                        $first = $hit[0]
                        Write-Check ('  {0} event is a Warning, not an Error' -f $r.Id) `
                            ($first.LevelDisplayName -eq 'Warning') $first.LevelDisplayName
                        Write-Check ('  {0} payload is key=value' -f $r.Id) `
                            ($first.Message -match '(?m)^\s*Finding=') ''
                        Write-Check ('  {0} payload names the finding correctly' -f $r.Id) `
                            ($first.Message -match ('(?m)^\s*Finding=' + $r.Label)) ''
                        # The field-disclosure claim in the runbook, checked against a real event.
                        Write-Check ('  {0} carries MailboxGuid and DisplayName' -f $r.Id) `
                            (($first.Message -match '(?m)^\s*MailboxGuid=') -and
                             ($first.Message -match '(?m)^\s*DisplayName=')) `
                            'the runbook states these leave the box - this is the check that it is true'
                    }
                }
                finally {
                    # ASK THE SCHEDULER, never a flag this loop set itself: a
                    # registration that threw partway can still have left a task
                    # behind, and every `continue` above jumps straight here.
                    $dPresent = $false
                    try { $null = Get-ScheduledTask -TaskName $gateDTask -ErrorAction Stop; $dPresent = $true } catch { }
                    if ($dPresent) {
                        try { Unregister-ScheduledTask -TaskName $gateDTask -Confirm:$false -ErrorAction Stop }
                        catch {
                            Write-Check ('{0} run: probe task removed' -f $r.Label) $false $_.Exception.Message
                            Write-Host ('  Remove the task "{0}" by hand.' -f $gateDTask) -ForegroundColor Red
                        }
                    }
                }
            }

            # 1012 is reported here, never forced here. Gate D moves thresholds,
            # and no threshold can produce Emerging: it needs a growth RATE, not a
            # size. Gate E stages one and measures the event for real.
            $emergingRows = @($rows | Where-Object {
                $_.Status -eq 'Normal' -and $_.DaysToCritical -and ([double]$_.DaysToCritical -le 3) })
            $results['GateD_EmergingCandidates'] = $emergingRows.Count
            if ($emergingRows.Count -ge 1) {
                Write-Measured '1012 candidates present' $emergingRows.Count
            }
            else {
                Write-Host ''
                Write-Host '  1012 (Emerging) is out of reach of THIS gate - no row has DaysToCritical <= 3,' -ForegroundColor DarkGray
                Write-Host '  which needs a real growth rate between baselines. Moving thresholds cannot' -ForegroundColor DarkGray
                Write-Host '  manufacture one. Run -RunGateE, which stages the rate and then measures the' -ForegroundColor DarkGray
                Write-Host '  event. Not counted as a gap here: Gate E is where that verdict belongs.' -ForegroundColor DarkGray
                $results['GateD_1012'] = 'OUT-OF-SCOPE: needs a growth rate, see Gate E'
            }
        }
    }
    catch {
        Write-Check 'Gate D ran to completion' $false $_.Exception.Message
        $results['GateD_Exception'] = $_.Exception.Message
    }
    finally {
        # The forced-threshold output is misleading evidence if it survives.
        try {
            if (Test-Path -LiteralPath $gateDOut) {
                Remove-Item -LiteralPath $gateDOut -Recurse -Force
                Write-Host ('  Removed {0} - its CSV/JSON describe thresholds, not the estate.' -f $gateDOut) -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host ('  COULD NOT REMOVE {0}: {1}' -f $gateDOut, $_.Exception.Message) -ForegroundColor Red
            Write-Host '  Delete it by hand - its contents read as a real incident.' -ForegroundColor Red
        }
    }
}

# ---------------------------------------------------------------------------
# GATE E - event 1012, the one no threshold can force
# ---------------------------------------------------------------------------
if (-not $RunGateE) {
    Write-Head 'GATE E - SKIPPED'
    Write-Host '  Re-run with -RunGateE to measure 1012 (Emerging) against a staged growth rate.' -ForegroundColor Yellow
}
else {
    Write-Head 'GATE E - 1012 (Emerging), from a STAGED growth rate'

    Write-Host '  WHAT IS REAL HERE AND WHAT IS NOT, before any result below is read:' -ForegroundColor Yellow
    Write-Host '    REAL       the mailbox, its live size, the classifier, the projection' -ForegroundColor Yellow
    Write-Host '               arithmetic, the event write and everything read back out.' -ForegroundColor Yellow
    Write-Host '    FABRICATED the earlier reading the growth rate is differenced against.' -ForegroundColor Yellow
    Write-Host '               One cell, in one back-dated CSV, in a scratch directory.' -ForegroundColor Yellow
    Write-Host '    A PASS HERE IS NOT "we observed growth in the lab". It is "given a' -ForegroundColor Yellow
    Write-Host '    growth rate, the monitor classifies Emerging and emits 1012".' -ForegroundColor Yellow

    $gateEOut   = Join-Path $env:ProgramData 'BFGateE'
    $gateEShim  = Join-Path $env:ProgramData 'BFGateE-stage.ps1'
    $gateELog   = Join-Path $env:ProgramData 'BFGateE-stage.log'

    # Two tasks, two names, and neither is $TaskName or Gate D's - see the note on
    # $gateDTask. A gate that dies between register and unregister leaves its task
    # behind, and a shared name means the next gate's cleanup removes it out from
    # under the one still using it.
    $gateEStageTask = 'BFGATEE Stage BigFunnel Growth Fixture'
    $gateETask      = 'BFGATEE Exchange BigFunnel PostingListTable Emerging'

    # 30, not the demo script's default 48, and the difference is load-bearing.
    # The fixture works backwards from today's real size:
    #     perDay   = (critical - current) / TargetDaysToCritical
    #     baseline = current - perDay * (BaselineAgeHours / 24)
    # so a WIDER baseline age demands a SMALLER earlier reading, and at 48 hours
    # with TargetDaysToCritical 2.5 the earlier reading has to satisfy
    # current > 0.444 * critical or it comes out negative and the script refuses.
    # At 30 hours that relaxes to current > critical / 3, which this estate clears
    # comfortably. It still has to exceed the monitor's -TrendBaselineHours (24)
    # or the join rejects it as too recent to divide by - 30 clears that by six
    # hours, which is margin enough for a multi-minute gate.
    $baselineHours = 30
    $targetDays    = 2.5

    try {
        $demo = Join-Path (Split-Path $PSScriptRoot -Parent) 'Set-BigFunnelDemoState.ps1'
        if (-not (Test-Path -LiteralPath $demo)) {
            Write-NotMeasured 'the growth fixture is available' `
                ('Set-BigFunnelDemoState.ps1 not found beside the monitor at {0}' -f $demo)
            $results['GateE_Verdict'] = 'NOT-MEASURED: fixture script not deployed'
        }
        else {

        # Size from what the estate really reports, exactly as Gate D does, rather
        # than from the demo script's defaults. Those defaults were chosen against
        # one estate on one day; a gate that inherits them reports a mailbox-name
        # failure on any other box and looks like a product fault.
        $eCsv = Get-ChildItem -LiteralPath $OutputPath -Filter '*.csv' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $eCsv) { throw ('No CSV under {0} to pick mailboxes from. Run the monitor once first.' -f $OutputPath) }

        Write-Measured 'sizing from' $eCsv.Name
        $eRows  = @(Import-Csv -LiteralPath $eCsv.FullName)
        $eSized = @($eRows | Where-Object { $_.PostingListBytes -and ([double]$_.PostingListGB -gt 0) } |
                    Sort-Object { [double]$_.PostingListBytes } -Descending)

        $results['GateE_RowsWithSize'] = $eSized.Count
        Write-Measured 'rows with a measurable posting list' $eSized.Count

        if ($eSized.Count -lt 3) {
            # THREE distinct sizes, not three mailboxes. Emerging only applies to a
            # row still reading Normal, so the staged estate needs one mailbox above
            # Critical, one between the thresholds, and one below Warning - which
            # cannot be built out of two.
            Write-NotMeasured 'the estate can support this test' `
                ('{0} mailbox(es) have a measurable posting list; the three tiers need three.' -f $eSized.Count)
            $results['GateE_Verdict'] = 'NOT-MEASURED: fewer than three sized mailboxes'
        }
        else {
            $cName = [string]$eSized[0].DisplayName
            $wName = [string]$eSized[1].DisplayName
            $eName = [string]$eSized[2].DisplayName
            $cGB   = [double]$eSized[0].PostingListGB
            $wGB   = [double]$eSized[1].PostingListGB
            $eGB   = [double]$eSized[2].PostingListGB

            # MIDPOINTS, not the measured sizes themselves. -CriticalGB set exactly
            # to the largest mailbox's rounded GB is a coin toss: the CSV column is
            # rounded and the comparison is not, so a mailbox reading 0.704 GB can
            # sit a few hundred KB under a 0.704 threshold and quietly classify
            # Normal. Half the gap to the next mailbox is margin in both directions.
            $eCrit = [math]::Round((($wGB + $cGB) / 2), 4)
            $eWarn = [math]::Round((($eGB + $wGB) / 2), 4)

            Write-Measured 'Critical  (real size / threshold)' ('{0} {1} GB / {2} GB' -f $cName.PadRight(14), $cGB, $eCrit)
            Write-Measured 'Warning   (real size / threshold)' ('{0} {1} GB / {2} GB' -f $wName.PadRight(14), $wGB, $eWarn)
            Write-Measured 'Emerging  (real size, below both)' ('{0} {1} GB' -f $eName.PadRight(14), $eGB)

            # Every one of these is a condition the demo script asserts for itself
            # and fails on. Checked here first so an estate that cannot be staged
            # costs nothing instead of costing three collections.
            $separated = ($eWarn -gt $eGB) -and ($eWarn -le $wGB) -and
                         ($eCrit -gt $wGB) -and ($eCrit -le $cGB) -and
                         ($eWarn -lt $eCrit) -and ($eWarn -ge 0.001) -and ($eCrit -le 1024)

            # The fixture arithmetic, run before the fixture is built - see
            # $baselineHours. Reproduced rather than approximated, because a
            # near-miss here surfaces 20 minutes later as a bare exit code.
            $curBytes  = [int64]$eSized[2].PostingListBytes
            $critBytes = [int64]($eCrit * 1GB)
            $perDay    = ($critBytes - $curBytes) / $targetDays
            $baseBytes = $curBytes - [int64]($perDay * ($baselineHours / 24.0))
            $reachable = ($baseBytes -gt 0)

            if (-not $separated) {
                Write-NotMeasured 'the three tiers separate' `
                    ('sizes {0} / {1} / {2} GB do not admit an ordered threshold pair' -f $cGB, $wGB, $eGB)
                $results['GateE_Verdict'] = 'NOT-MEASURED: mailbox sizes do not separate into three tiers'
            }
            elseif (-not $reachable) {
                Write-NotMeasured 'the growth rate is constructible' `
                    ('{0} at {1} GB would need a negative earlier reading to reach {2} GB in {3} days' -f
                     $eName, $eGB, $eCrit, $targetDays)
                $results['GateE_Verdict'] = 'NOT-MEASURED: fixture baseline would be negative'
            }
            else {
                Write-Check 'the estate can support this test' $true `
                    ('three tiers separate, and the fixture baseline lands at {0} GB' -f [math]::Round($baseBytes / 1GB, 3))

                if (-not $TaskCredential) {
                    $TaskCredential = Get-Credential -Message 'Account to stage and run the Emerging fixture (a PASSWORD is required - it is what carries the network credential)'
                }
                if (-not $TaskCredential) { throw 'Gate E needs -TaskCredential to reach a collection. Nothing was run.' }

                # -------------------------------------------------------------
                # 1. Stage the fixture, AS A SCHEDULED TASK
                # -------------------------------------------------------------
                # Same double hop Gate D hit, same remedy. Set-BigFunnelDemoState
                # calls the monitor twice and the monitor opens an Exchange
                # runspace, which is a network logon; over WinRM the credential
                # that authenticated this session cannot be delegated onward.
                #
                # THIS ONE DOES NOT GO THROUGH THE PRODUCT'S -RegisterScheduledTask,
                # and that is deliberate rather than an oversight: that switch
                # registers the MONITOR, and what has to run here is the fixture
                # builder. Gate D exercises the product's registration path; this
                # task exists only to carry a credential, so it is registered
                # directly and the emit run below goes through the product switch.
                #
                # Wrapped in a generated shim for one reason: a scheduled task
                # discards console output, and Set-BigFunnelDemoState has six
                # distinct refusals each naming exactly what was wrong. Without a
                # transcript a staging failure arrives as "LastTaskResult 1" and
                # costs a second trip to diagnose. The shim is one file, removed
                # in the finally with everything else.
                $sq = { param([string]$s) return ($s -replace "'", "''") }
                $shim = @(
                    "`$ErrorActionPreference = 'Continue'"
                    ("Start-Transcript -LiteralPath '{0}' -Force | Out-Null" -f (& $sq $gateELog))
                    "`$rc = 99"
                    'try {'
                    # One line, no continuations. A trailing backtick followed by a
                    # stray space is a syntax error in a file nobody will ever read.
                    ("    & '{0}' -OutputPath '{1}' -MonitorPath '{2}' -CriticalGB {3} -WarningGB {4} -CriticalMailbox '{5}' -WarningMailbox '{6}' -EmergingMailbox '{7}' -BaselineAgeHours {8} -TargetDaysToCritical {9} -Scope Local" -f
                        (& $sq $demo), (& $sq $gateEOut), (& $sq $monitor), $eCrit, $eWarn,
                        (& $sq $cName), (& $sq $wName), (& $sq $eName), $baselineHours, $targetDays)
                    "    `$rc = `$LASTEXITCODE"
                    '}'
                    'catch {'
                    "    Write-Host ('SHIM CAUGHT: ' + `$_.Exception.Message)"
                    "    `$rc = 98"
                    '}'
                    'finally { try { Stop-Transcript | Out-Null } catch { } }'
                    "exit `$rc"
                )
                Set-Content -LiteralPath $gateEShim -Value $shim -Encoding UTF8

                $stageAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $gateEShim)
                # NO TRIGGER. A task with none registers fine and can only be started
                # on demand, which is exactly what this is - it must never fire on
                # its own, least of all after the gate has gone.
                #
                # DOUBLE the per-run timeout, because this task is TWO collections:
                # Set-BigFunnelDemoState collects the estate to build the baseline
                # from, then collects again to verify the fixture took. Giving it a
                # single run's budget kills it partway through the second one, which
                # lands as a staging failure that reads exactly like a product fault.
                $stageTimeout  = $RunTimeoutMinutes * 2
                $stageSettings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit (New-TimeSpan -Minutes $stageTimeout) `
                    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

                $null = Register-ScheduledTask -TaskName $gateEStageTask `
                    -Action $stageAction -Settings $stageSettings `
                    -User $TaskCredential.UserName `
                    -Password $TaskCredential.GetNetworkCredential().Password `
                    -RunLevel Highest -Force

                $sTask = Get-ScheduledTask -TaskName $gateEStageTask -ErrorAction Stop
                Write-Measured 'staging task LogonType' $sTask.Principal.LogonType

                if ($sTask.Principal.LogonType -ne 'Password') {
                    # Not a FAIL: this task is harness, not product. Anything other
                    # than Password means it will sit at Ready and never run - the
                    # 54ebad7 failure - so nothing downstream gets measured either
                    # way, and scoring it as a defect would condemn working code.
                    Write-NotMeasured 'the fixture could be staged' `
                        ('staging task registered as {0}, which carries no network credential' -f $sTask.Principal.LogonType)
                    $results['GateE_Verdict'] = 'NOT-MEASURED: staging task logon type'
                }
                else {
                    Write-Host ('  Staging the fixture - three collections, this is the slow part.') -ForegroundColor DarkGray
                    Start-ScheduledTask -TaskName $gateEStageTask -ErrorAction Stop

                    # Two-stage wait, for the reason Gate D documents: a slow
                    # Ready->Running transition is indistinguishable from a run
                    # that already finished.
                    $sBy = (Get-Date).AddSeconds(90)
                    $sRan = $false
                    do {
                        Start-Sleep -Seconds 2
                        if ((Get-ScheduledTask -TaskName $gateEStageTask).State -eq 'Running') { $sRan = $true }
                    } while (-not $sRan -and (Get-Date) -lt $sBy)

                    $sState = (Get-ScheduledTask -TaskName $gateEStageTask).State
                    $sBy    = (Get-Date).AddMinutes($stageTimeout)
                    do {
                        Start-Sleep -Seconds 10
                        $sState = (Get-ScheduledTask -TaskName $gateEStageTask).State
                        $sInfo  = Get-ScheduledTaskInfo -TaskName $gateEStageTask
                        Write-Host ('    staging: state {0}, last result 0x{1:X}' -f $sState, $sInfo.LastTaskResult) -ForegroundColor DarkGray
                    } while ($sState -eq 'Running' -and (Get-Date) -lt $sBy)

                    $sInfo = Get-ScheduledTaskInfo -TaskName $gateEStageTask
                    $results['GateE_StageResult'] = ('0x{0:X}' -f $sInfo.LastTaskResult)

                    # THE TRANSCRIPT IS PRINTED WHENEVER STAGING DID NOT RETURN 0,
                    # here, in this output, rather than left on the box for someone
                    # to go and find. The trip script captures this stream; it does
                    # not capture C:\ProgramData.
                    if ($sInfo.LastTaskResult -ne 0 -and (Test-Path -LiteralPath $gateELog)) {
                        Write-Host ''
                        Write-Host '  --- staging transcript, last 30 lines --------------------' -ForegroundColor DarkGray
                        Get-Content -LiteralPath $gateELog -Tail 30 |
                            ForEach-Object { Write-Host ('  | ' + $_) -ForegroundColor DarkGray }
                        Write-Host '  ----------------------------------------------------------' -ForegroundColor DarkGray
                    }

                    # ASSERT THE STAGED STATE FROM THE MONITOR'S OWN OUTPUT, not
                    # from the staging exit code. The demo script verifies itself,
                    # but reading latest.csv here means the gate's precondition is
                    # established by the gate rather than taken on trust from the
                    # thing it is about to test.
                    $eLatest = Join-Path $gateEOut 'latest.csv'
                    $staged  = $null
                    if (Test-Path -LiteralPath $eLatest) {
                        $staged = @(Import-Csv -LiteralPath $eLatest | Where-Object { $_.DisplayName -eq $eName })[0]
                    }

                    # Emerging is not a Status. It is Normal AND a projection inside
                    # three days, which is how the monitor decides it and therefore
                    # how this is checked - not by looking for a word that never
                    # appears in the column.
                    $stagedDays = if ($staged -and -not [string]::IsNullOrWhiteSpace($staged.DaysToCritical)) {
                        [double]$staged.DaysToCritical } else { $null }
                    $stagedOk = ($null -ne $staged) -and ($staged.Status -eq 'Normal') -and
                                ($null -ne $stagedDays) -and ($stagedDays -gt 0) -and ($stagedDays -le 3)

                    if (-not $stagedOk) {
                        Write-NotMeasured 'the fixture reached an Emerging row' `
                            $(if ($null -eq $staged) { ('no row for {0} in {1}' -f $eName, $eLatest) }
                              else { ('{0}: Status {1}, DaysToCritical [{2}]' -f $eName, $staged.Status, $staged.DaysToCritical) })
                        $results['GateE_Verdict'] = 'NOT-MEASURED: fixture did not produce an Emerging row'
                    }
                    else {
                        Write-Check 'the fixture reached an Emerging row' $true `
                            ('{0}: Normal, {1} GB/day, critical in {2} day(s)' -f
                             $eName, $staged.GrowthGBPerDay, $staged.DaysToCritical)
                        $results['GateE_StagedDaysToCritical'] = $staged.DaysToCritical
                        $results['GateE_StagedGrowthGBPerDay'] = $staged.GrowthGBPerDay

                        # ---------------------------------------------------------
                        # 2. Run the monitor over it, THROUGH THE PRODUCT'S OWN
                        #    registration switch, exactly as Gate D does
                        # ---------------------------------------------------------
                        # Same thresholds as the staging run, or the Emerging row
                        # reclassifies and the event under test never had a chance.
                        # The fixture baseline is 30 hours old and the staging run's
                        # own CSV is minutes old, so Get-PreviousRunBaseline - newest
                        # run at least -TrendBaselineHours old - can only pick the
                        # fixture. -RetentionDays 30 keeps it: at 1 it would be swept
                        # before it was read.
                        $mark = Get-Date
                        Start-Sleep -Seconds 1

                        & $monitor -RegisterScheduledTask -TaskName $gateETask `
                            -Scope Local -RetentionDays 30 `
                            -WarningGB $eWarn -CriticalGB $eCrit `
                            -EmitTo EventLog,RunJson -EventLogSource $EventLogSource `
                            -OutputPath $gateEOut `
                            -TaskIntervalHours 24 -TaskStartTime '23:53' `
                            -TaskCredential $TaskCredential
                        $eRegEx = $LASTEXITCODE
                        Write-Check 'emit run registered (exit 0)' ($eRegEx -eq 0) ('exit ' + $eRegEx)

                        if ($eRegEx -ne 0) {
                            Write-NotMeasured '1012 emitted' 'the emit run could not be registered, so it never ran'
                            $results['GateE_Verdict'] = 'NOT-MEASURED: emit task registration failed'
                        }
                        else {
                            $eTask = Get-ScheduledTask -TaskName $gateETask -ErrorAction Stop
                            Write-Check 'emit run: LogonType is Password' `
                                ($eTask.Principal.LogonType -eq 'Password') `
                                ([string]$eTask.Principal.LogonType + ' - anything else carries no network credential and cannot open the runspace')

                            Start-ScheduledTask -TaskName $gateETask -ErrorAction Stop

                            $eBy  = (Get-Date).AddSeconds(90)
                            $eRan = $false
                            do {
                                Start-Sleep -Seconds 2
                                if ((Get-ScheduledTask -TaskName $gateETask).State -eq 'Running') { $eRan = $true }
                            } while (-not $eRan -and (Get-Date) -lt $eBy)

                            $eState = (Get-ScheduledTask -TaskName $gateETask).State
                            $eBy    = (Get-Date).AddMinutes($RunTimeoutMinutes)
                            do {
                                Start-Sleep -Seconds 10
                                $eState = (Get-ScheduledTask -TaskName $gateETask).State
                                $eInfo  = Get-ScheduledTaskInfo -TaskName $gateETask
                                Write-Host ('    emit: state {0}, last result 0x{1:X}' -f $eState, $eInfo.LastTaskResult) -ForegroundColor DarkGray
                            } while ($eState -eq 'Running' -and (Get-Date) -lt $eBy)

                            $eInfo = Get-ScheduledTaskInfo -TaskName $gateETask
                            $results['GateE_EmitResult'] = ('0x{0:X}' -f $eInfo.LastTaskResult)

                            # A run that COMPLETED, by exit code: 0 clean, 1 alert,
                            # 2 partial, 6 emerging. 3 fatal / 4 already running /
                            # 5 blind / 7 task failure all mean the thresholds never
                            # reached a single mailbox, so an absent 1012 would say
                            # nothing at all about the event path.
                            $eCollected = @(0, 1, 2, 6) -contains [int]$eInfo.LastTaskResult

                            if (-not $eCollected) {
                                Write-NotMeasured '1012 emitted' `
                                    ('the emit run exited 0x{0:X}, which means it never classified a mailbox' -f $eInfo.LastTaskResult)
                                $results['GateE_Verdict'] = 'NOT-MEASURED: emit run did not complete a collection'
                            }
                            else {
                                $eEv = @(Get-WinEvent -FilterHashtable @{
                                            LogName      = 'Application'
                                            ProviderName = $EventLogSource
                                            StartTime    = $mark
                                        } -ErrorAction SilentlyContinue)

                                $e1012 = @($eEv | Where-Object { $_.Id -eq 1012 })
                                $results['GateE_1012Count'] = $e1012.Count
                                # Recorded, not asserted: the staged estate also puts
                                # one mailbox over each threshold, so this run emits
                                # 1010 and 1011 as a side effect. Gate D is where
                                # those two are the claim.
                                $results['GateE_1010Count'] = @($eEv | Where-Object { $_.Id -eq 1010 }).Count
                                $results['GateE_1011Count'] = @($eEv | Where-Object { $_.Id -eq 1011 }).Count

                                # THE VERDICT. Everything above this line established
                                # that a mailbox really was classified Emerging by
                                # the monitor's own published output. If no 1012
                                # followed, the event path is broken - that is a
                                # product failure and it is scored as one.
                                Write-Check 'Emerging run emits event 1012' ($e1012.Count -ge 1) `
                                    ('{0} event(s) of id 1012' -f $e1012.Count)

                                if ($e1012.Count -ge 1) {
                                    $f = $e1012[0]
                                    Write-Check '  1012 is a Warning, not an Error' `
                                        ($f.LevelDisplayName -eq 'Warning') $f.LevelDisplayName
                                    Write-Check '  1012 payload is key=value' `
                                        ($f.Message -match '(?m)^\s*Finding=') ''
                                    Write-Check '  1012 payload names the finding correctly' `
                                        ($f.Message -match '(?m)^\s*Finding=Emerging') ''
                                    Write-Check '  1012 carries MailboxGuid and DisplayName' `
                                        (($f.Message -match '(?m)^\s*MailboxGuid=') -and
                                         ($f.Message -match '(?m)^\s*DisplayName=')) `
                                        'the runbook states these leave the box - this is the check that it is true'

                                    # THE TWO ASSERTIONS ONLY THIS GATE CAN MAKE.
                                    #
                                    # Gate D proves 1010/1011 carry a payload. It
                                    # cannot prove the event describes the mailbox
                                    # that caused it, because it forces whole tiers
                                    # at once. Exactly one mailbox was staged
                                    # Emerging here, so the event has a name to match.
                                    Write-Check '  1012 names the mailbox that was staged' `
                                        ($f.Message -match ('(?m)^\s*DisplayName="?' + [regex]::Escape($eName) + '"?\s*$')) `
                                        $eName

                                    # And Emerging is the one finding whose whole
                                    # substance is the projection. A 1012 that
                                    # arrives without it tells a forwarder that
                                    # something is growing and nothing about how
                                    # fast or how long is left.
                                    $dtcOk = $false
                                    $dtcTxt = ''
                                    if ($f.Message -match '(?m)^\s*DaysToCritical="?([0-9.]+)"?\s*$') {
                                        $dtcTxt = $Matches[1]
                                        $dtc = [double]$dtcTxt
                                        $dtcOk = ($dtc -gt 0) -and ($dtc -le 3)
                                    }
                                    Write-Check '  1012 carries the projection that defines it' $dtcOk `
                                        ('DaysToCritical=[{0}] - must be inside (0, 3]' -f $dtcTxt)
                                    $results['GateE_EventDaysToCritical'] = $dtcTxt

                                    $results['GateE_Verdict'] = 'MEASURED: 1012 emitted from a staged growth rate'
                                }
                                else {
                                    $results['GateE_Verdict'] = 'FAILED: row was Emerging, no 1012 followed'
                                }
                            }
                        }
                    }
                }
            }
        }

        }
    }
    catch {
        Write-Check 'Gate E ran to completion' $false $_.Exception.Message
        $results['GateE_Exception'] = $_.Exception.Message
    }
    finally {
        # ASK THE SCHEDULER, never a flag this block set itself: a registration
        # that threw partway can still have left a task behind, and every path
        # above jumps straight here.
        foreach ($t in @($gateEStageTask, $gateETask)) {
            $present = $false
            try { $null = Get-ScheduledTask -TaskName $t -ErrorAction Stop; $present = $true } catch { }
            if ($present) {
                try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop }
                catch {
                    Write-Host ('  COULD NOT REMOVE TASK "{0}": {1}' -f $t, $_.Exception.Message) -ForegroundColor Red
                    Write-Host '  Remove it by hand.' -ForegroundColor Red
                }
            }
        }

        # THE FIXTURE MUST NOT SURVIVE THE GATE. Set-BigFunnelDemoState writes
        # DEMO-FIXTURE.txt precisely because a demo directory looks exactly like a
        # production one; leaving the directory behind on a server means the next
        # person to find it has a CSV containing one fabricated cell and a note
        # saying so, sitting beside real monitoring output.
        foreach ($p in @($gateEOut, $gateEShim, $gateELog)) {
            try {
                if (Test-Path -LiteralPath $p) {
                    Remove-Item -LiteralPath $p -Recurse -Force
                    Write-Host ('  Removed {0}' -f $p) -ForegroundColor DarkGray
                }
            }
            catch {
                Write-Host ('  COULD NOT REMOVE {0}: {1}' -f $p, $_.Exception.Message) -ForegroundColor Red
                Write-Host '  Delete it by hand - it contains a fabricated growth rate.' -ForegroundColor Red
            }
        }
    }
}

# ---------------------------------------------------------------------------
if ($RemoveEventSource) {
    try {
        Remove-EventLog -Source $EventLogSource -ErrorAction Stop
        Write-Host ''
        Write-Host ('  Removed event source {0}.' -f $EventLogSource) -ForegroundColor Yellow
    }
    catch { Write-Host ('  Could not remove event source: ' + $_.Exception.Message) -ForegroundColor Red }
}
else {
    Write-Host ''
    Write-Host ('  Event source {0} LEFT IN PLACE - production needs it, and creating it' -f $EventLogSource) -ForegroundColor DarkGray
    Write-Host '  is the one administrator-only step in the emit path. -RemoveEventSource to undo.' -ForegroundColor DarkGray
}

Write-Head 'RESULTS - paste this block into the branch-state log'
Write-Host ('  machine={0}  ps={1}  utc={2}' -f $env:COMPUTERNAME, $PSVersionTable.PSVersion, [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
foreach ($k in $results.Keys) { Write-Host ('  {0}={1}' -f $k, $results[$k]) }
Write-Host ''

# NOT MEASURED IS REPORTED ON ITS OWN LINE, never folded into the failure count.
# A gate that could not create its conditions has proved nothing, and rolling
# that into "N failed" both condemns working code and hides the real gaps behind
# a number that looks like a test result.
if ($script:NotMeasured -gt 0) {
    Write-Host ('  NOT MEASURED: {0} - conditions could not be created, so there is no verdict' -f $script:NotMeasured) -ForegroundColor Yellow
}
if ($script:Failed -eq 0) {
    Write-Host '  GATES: 0 failed' -ForegroundColor Green
}
else {
    Write-Host ('  GATES: {0} failed' -f $script:Failed) -ForegroundColor Red
}

# Exit reflects FAILURES ONLY. A run that measured nothing exits 0 with the gaps
# named above it - it has not found a defect, and saying otherwise would make the
# trip script treat an inconclusive trip as a broken product.
exit $(if ($script:Failed) { 1 } else { 0 })
