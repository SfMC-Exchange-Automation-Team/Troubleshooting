# Mock of the Windows ScheduledTasks module.
#
# NAMED ScheduledTasks ON PURPOSE, to shadow the real module. Two mechanisms
# then point the same way and either one alone would do: the harness prepends
# _mockmodules to PSModulePath, so auto-loading finds this one first; and these
# are FUNCTIONS while the real ones are CMDLETS, and PowerShell's command
# precedence puts functions ahead of cmdlets when both are visible. That is
# deliberate belt and braces - a test that silently reached the real scheduler
# would create a real task on the machine running the suite.
#
# The behaviour reproduced here is the measured behaviour from w25-ex01 and from
# commit 54ebad7, not the documented one. The single most important thing this
# file gets right is that -User WITHOUT -Password produces LogonType Interactive
# rather than an error: the real cmdlet accepts it, reports success, and
# registers a task that never runs. A mock that threw instead would make the
# script look correct while the estate failed silently, which is the exact fault
# the registration path exists to prevent.

# The store is file-backed rather than in-memory because the monitor runs as a
# child process: the suite registers in one powershell.exe and asserts in
# another. MOCK_TASKSTORE follows the MOCK_ACTIVE_ELSEWHERE idiom in
# MockExchange.psm1.
function Get-MockTaskStorePath {
    if ($env:MOCK_TASKSTORE) { return $env:MOCK_TASKSTORE }
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'bf-mock-scheduledtasks.json')
}

function Get-MockTaskStore {
    $p = Get-MockTaskStorePath
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($prop in $obj.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
        return $h
    }
    catch { return @{} }
}

function Set-MockTaskStore {
    param($Store)
    $p = Get-MockTaskStorePath
    ([pscustomobject]$Store) | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $p -Encoding UTF8
}

function Clear-MockTaskStore {
    # Exported so a test can start from a known state without knowing the path.
    Remove-Item -LiteralPath (Get-MockTaskStorePath) -Force -ErrorAction SilentlyContinue
}

function New-ScheduledTaskAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Execute,
        [string]$Argument,
        [string]$WorkingDirectory
    )
    [pscustomobject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory }
}

function New-ScheduledTaskTrigger {
    [CmdletBinding()]
    param(
        [switch]$Once, [switch]$Daily, [switch]$AtStartup, [switch]$AtLogOn,
        [datetime]$At,
        [timespan]$RepetitionInterval,
        [timespan]$RepetitionDuration,
        [int]$DaysInterval
    )
    [pscustomobject]@{
        Once               = [bool]$Once
        StartBoundary      = $(if ($PSBoundParameters.ContainsKey('At')) { $At.ToString('o') } else { '' })
        RepetitionInterval = $(if ($PSBoundParameters.ContainsKey('RepetitionInterval')) { $RepetitionInterval.ToString() } else { '' })
        RepetitionDuration = $(if ($PSBoundParameters.ContainsKey('RepetitionDuration')) { $RepetitionDuration.ToString() } else { '' })
    }
}

function New-ScheduledTaskSettingsSet {
    [CmdletBinding()]
    param(
        [string]$MultipleInstances,
        [timespan]$ExecutionTimeLimit,
        [switch]$StartWhenAvailable,
        [switch]$DontStopIfGoingOnBatteries,
        [switch]$AllowStartIfOnBatteries
    )
    [pscustomobject]@{
        MultipleInstances  = $MultipleInstances
        ExecutionTimeLimit = $(if ($PSBoundParameters.ContainsKey('ExecutionTimeLimit')) { $ExecutionTimeLimit.ToString() } else { '' })
        StartWhenAvailable = [bool]$StartWhenAvailable
    }
}

function Register-ScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        $Action, $Trigger, $Settings,
        [string]$User, [string]$Password, [string]$RunLevel, [string]$Description,
        [switch]$Force
    )

    # MOCK_TASK_DENY reproduces the locked-down estate this whole feature exists
    # for: a local administrator who is refused by policy. The message is the
    # real one, because the script matches on its text to tell a policy refusal
    # apart from a genuine fault.
    if ($env:MOCK_TASK_DENY -eq '1') {
        throw 'Access is denied. (Exception from HRESULT: 0x80070005 (E_ACCESSDENIED))'
    }

    $store = Get-MockTaskStore
    if ($store.ContainsKey($TaskName) -and -not $Force) {
        throw ("Cannot create a file when that file already exists. A task with the name '" + $TaskName + "' already exists.")
    }

    # THE MEASURED BEHAVIOUR, and the reason this mock is worth having.
    # -User with -Password stores the password and yields LogonType Password.
    # -User alone is accepted without complaint and yields Interactive: a task
    # that sits at Ready, reports LastTaskResult 0x41303 and never runs. S4U is
    # reachable only by forcing it, because nothing the script sends produces it.
    $logon = 'Interactive'
    if ($User -and $Password) { $logon = 'Password' }
    if ($env:MOCK_TASK_LOGONTYPE) { $logon = $env:MOCK_TASK_LOGONTYPE }

    $level = $(if ($RunLevel) { $RunLevel } else { 'Limited' })
    if ($env:MOCK_TASK_RUNLEVEL) { $level = $env:MOCK_TASK_RUNLEVEL }

    $store[$TaskName] = [pscustomobject]@{
        TaskName    = $TaskName
        State       = 'Ready'
        Description = $Description
        Execute     = $(if ($Action) { [string]$Action.Execute }   else { '' })
        Arguments   = $(if ($Action) { [string]$Action.Arguments } else { '' })
        LogonType   = $logon
        RunLevel    = $level
        UserId      = $User
        Trigger     = $Trigger
        Settings    = $Settings
    }
    Set-MockTaskStore $store
    Get-ScheduledTask -TaskName $TaskName
}

function Get-ScheduledTask {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$TaskName, [string]$TaskPath)

    $store = Get-MockTaskStore

    if (-not $TaskName) {
        return @($store.Keys | ForEach-Object { ConvertTo-MockTaskObject $store[$_] })
    }

    if (-not $store.ContainsKey($TaskName)) {
        # Throws rather than returning $null, because the real cmdlet does and
        # every caller in the monitor is a try/catch around -ErrorAction Stop.
        # A mock that returned $null here would make Unregister-MonitorScheduledTask
        # report "already absent" on a task that was there.
        throw ("No MSFT_ScheduledTask objects found with property 'TaskName' equal to '" + $TaskName + "'.")
    }
    ConvertTo-MockTaskObject $store[$TaskName]
}

function ConvertTo-MockTaskObject {
    # The shape the verification reads: .Principal.LogonType, .Principal.RunLevel
    # and .Actions[0].Arguments. Actions is an ARRAY even with one action,
    # because the script indexes [0].
    param($Raw)
    [pscustomobject]@{
        TaskName    = $Raw.TaskName
        State       = $Raw.State
        Description = $Raw.Description
        Actions     = @([pscustomobject]@{ Execute = $Raw.Execute; Arguments = $Raw.Arguments })
        Principal   = [pscustomobject]@{
            LogonType = $Raw.LogonType
            RunLevel  = $Raw.RunLevel
            UserId    = $Raw.UserId
        }
        Triggers    = @($Raw.Trigger)
        Settings    = $Raw.Settings
    }
}

function Unregister-ScheduledTask {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$TaskName, [string]$TaskPath, [switch]$Confirm)

    $store = Get-MockTaskStore
    if (-not $store.ContainsKey($TaskName)) {
        throw ("No MSFT_ScheduledTask objects found with property 'TaskName' equal to '" + $TaskName + "'.")
    }

    # The same injector as Register, and thrown here for the same reason: an
    # estate that reserves task creation to a management layer usually reserves
    # task REMOVAL too, and the script has its own access-denied branch on this
    # side. Deliberately after the existence check, so the denial lands on a task
    # that is really there - a refusal on a task that does not exist would be
    # testing the wrong branch.
    if ($env:MOCK_TASK_DENY -eq '1') {
        throw 'Access is denied. (Exception from HRESULT: 0x80070005 (E_ACCESSDENIED))'
    }

    # MOCK_TASK_STICKY: report success and remove nothing. This is the only way
    # to reach the branch that exists because Unregister-ScheduledTask cannot be
    # taken at its word, and without it that branch is untestable.
    if ($env:MOCK_TASK_STICKY -eq '1') { return }

    $store.Remove($TaskName)
    Set-MockTaskStore $store
}

Export-ModuleMember -Function New-ScheduledTaskAction, New-ScheduledTaskTrigger,
    New-ScheduledTaskSettingsSet, Register-ScheduledTask, Get-ScheduledTask,
    Unregister-ScheduledTask, Clear-MockTaskStore, Get-MockTaskStorePath
