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
# this has to assert the REAL cmdlets did. run-tests.ps1 prepends _mockmodules to
# PSModulePath, and a lab gate that ran against the mock would report a clean pass
# having proved nothing at all about this machine.
$reg = Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue
$realCmdlets = $reg -and $reg.CommandType -eq 'Cmdlet' -and
               ($reg.Module.Path -notlike '*_mockmodules*')
Write-Check 'Register-ScheduledTask is the REAL cmdlet' $realCmdlets `
    ('{0} / {1}' -f $reg.CommandType, $reg.ModuleName)
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
    $registered = $false
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
        $registered = $true

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
        Write-Check 'LastTaskResult is not 0x41303 (never ran)' `
            ($info.LastTaskResult -ne 0x41303) `
            'that value is exactly the Interactive-logon failure this gate exists for'
        Write-Check 'LastTaskResult is a documented monitor exit code (0-7)' `
            ($info.LastTaskResult -ge 0 -and $info.LastTaskResult -le 7) `
            'anything else came from the scheduler, not the script'
        $results['GateB_LastTaskResult'] = ('0x{0:X}' -f $info.LastTaskResult)

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
    finally {
        # ALWAYS, even on a failed assertion above: this created a real task on a real
        # server and leaving it behind is worse than any gate it failed.
        if ($registered) {
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
