<#
.SYNOPSIS
    Closes the two Monitor-BigFunnelPostingList gates that no automated test can reach.

.DESCRIPTION
    Two things about this feature are unprovable from the test suite, for the same
    reason in both cases: the suite runs NON-ELEVATED and against a mock, and both
    gates are about what the real, elevated machine actually does.

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

    # Gate D forces per-mailbox classifications by moving the thresholds under real
    # measured sizes. Two real collections, so it is opt-in and it is not quick.
    [switch]$RunGateD,

    # Leave the source behind by default: production wants it, and creating it is the
    # one administrator-only step in the whole emit path.
    [switch]$RemoveEventSource
)

$ErrorActionPreference = 'Stop'
$results = [ordered]@{}
$script:Failed = 0

function Write-Head { param($Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan; Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray }
function Write-Measured { param($Label, $Value) Write-Host ('  {0} {1}' -f $Label.PadRight(46), $Value) }
function Write-Check {
    param($Label, [bool]$Ok, $Detail = '')
    if (-not $Ok) { $script:Failed++ }
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $col = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ('  {0}  {1} {2}' -f $tag, $Label.PadRight(46), $Detail) -ForegroundColor $col
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
}
else {
    Write-Head 'GATE C - a genuinely non-elevated write'

    if (-not $TaskCredential) {
        $TaskCredential = Get-Credential -Message 'Account for the Limited-runlevel probe task (a PASSWORD is required)'
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
        try {
            $acl  = Get-Acl -LiteralPath $probeDir
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $TaskCredential.UserName, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
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

        Register-ScheduledTask -TaskName $gateCTask -Action $action -Trigger $trigger `
            -User $TaskCredential.UserName `
            -Password $TaskCredential.GetNetworkCredential().Password `
            -RunLevel Limited -Force | Out-Null

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

        # THE GATE. 12 is called out separately because it is not a failure of the
        # feature - it is a failure of the harness to create the conditions, and
        # reporting it as a feature failure would condemn working code.
        if ($code -eq 12) {
            Write-Check 'the probe token was NOT elevated' $false `
                'RunLevel Limited did not filter the token. INCONCLUSIVE - the write was never tested non-elevated.'
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
        Write-Check 'and the event is really in the log' ($cEv.Count -ge 1) `
            ('{0} matching event(s)' -f $cEv.Count)
    }
    catch {
        Write-Check 'Gate C ran to completion' $false $_.Exception.Message
        $results['GateC_Exception'] = $_.Exception.Message
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
if (-not $RunGateD) {
    Write-Head 'GATE D - SKIPPED'
    Write-Host '  Re-run with -RunGateD to exercise the per-mailbox event path.' -ForegroundColor Yellow
}
else {
    Write-Head 'GATE D - per-mailbox events against real rows'

    $gateDOut = Join-Path $env:ProgramData 'BFGateD'
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

        # -WarningGB and -CriticalGB are ValidateRange(0.001, 1024), so a mailbox under
        # 1 MB cannot be reached by any legal threshold. Say that plainly instead of
        # running twice and reporting two empty passes.
        if ($maxGB -lt 0.001) {
            Write-Check 'the estate can support this test' $false `
                'no mailbox reaches 0.001 GB, the floor of -CriticalGB. NOT MEASURED, not failed.'
            $results['GateD_Verdict'] = 'NOT-MEASURED: estate below the threshold floor'
        }
        else {
            Write-Check 'the estate can support this test' $true ('largest posting list is {0} GB' -f $maxGB)

            $runs = @(
                @{ Label = 'Critical'; Id = 1010; Warn = 0.001; Crit = 0.001 }
                @{ Label = 'Warning';  Id = 1011; Warn = 0.001; Crit = 1024  }
            )

            foreach ($r in $runs) {
                Write-Host ''
                Write-Host ('  Forcing {0} (-WarningGB {1} -CriticalGB {2}) - a real collection, please wait.' -f
                    $r.Label, $r.Warn, $r.Crit) -ForegroundColor DarkGray

                $mark = Get-Date
                Start-Sleep -Seconds 1
                & $monitor -Scope Local -RetentionDays 30 `
                    -WarningGB $r.Warn -CriticalGB $r.Crit `
                    -EmitTo EventLog,RunJson -EventLogSource $EventLogSource `
                    -OutputPath $gateDOut
                $ex = $LASTEXITCODE

                $ev = @(Get-WinEvent -FilterHashtable @{
                            LogName      = 'Application'
                            ProviderName = $EventLogSource
                            StartTime    = $mark
                        } -ErrorAction SilentlyContinue)
                $hit = @($ev | Where-Object { $_.Id -eq $r.Id })

                $results[('GateD_{0}_ExitCode' -f $r.Label)] = $ex
                $results[('GateD_{0}_{1}Count' -f $r.Label, $r.Id)] = $hit.Count
                Write-Measured ('{0} run exit code' -f $r.Label) $ex
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

            # 1012 is reported, never forced. See the header.
            $emergingRows = @($rows | Where-Object {
                $_.Status -eq 'Normal' -and $_.DaysToCritical -and ([double]$_.DaysToCritical -le 3) })
            $results['GateD_EmergingCandidates'] = $emergingRows.Count
            if ($emergingRows.Count -ge 1) {
                Write-Measured '1012 candidates present' $emergingRows.Count
            }
            else {
                Write-Host ''
                Write-Host '  1012 (Emerging) NOT MEASURED - no row has DaysToCritical <= 3, which needs a' -ForegroundColor Yellow
                Write-Host '  real growth rate between baselines. A static lab cannot manufacture one, and' -ForegroundColor Yellow
                Write-Host '  moving thresholds cannot either. This is a gap, not a failure.' -ForegroundColor Yellow
                $results['GateD_1012'] = 'NOT-MEASURED: no growth rate in this estate'
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
if ($script:Failed -eq 0) {
    Write-Host ('  GATES: 0 failed' -f $script:Failed) -ForegroundColor Green
}
else {
    Write-Host ('  GATES: {0} failed' -f $script:Failed) -ForegroundColor Red
}
exit $(if ($script:Failed) { 1 } else { 0 })
