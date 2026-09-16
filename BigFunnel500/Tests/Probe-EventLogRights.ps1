# Read-only probe of the Event Log rights split on the lab box.
#
# GATE A, and ONLY the half that can be answered without changing anything. The
# open question is narrow: Initialize-EmitEventSource treats a SourceExists()
# THROW as INDETERMINATE and lets the write be the test, because a caller who
# cannot enumerate the log list gets an exception rather than a false. That
# reading is only correct if an ELEVATED caller gets a clean answer instead, and
# nobody has measured that.
#
# EVERY CALL IN HERE IS A READ. No New-EventLog, no Write-EventLog, no task
# registration, no file written on the target. SourceExists() does not create.
# If this script ever grows a write, it stops being the thing that was approved.

[CmdletBinding()]
param(
    [string]$ComputerName = 'w25-ex01',

    # NOT optional in practice, and the first version of this script omitted it.
    # Measured 2026-09-16: this workstation is Entra-joined, NOT domain-joined
    # (dsregcmd: AzureAdJoined YES / DomainJoined NO), so an implicit connection
    # offers a NORTHAMERICA\ token over NTLM pass-through. A box with a matching
    # LOCAL account accepts that - littlepig does - but w25-ex01 is in the lab AD
    # forest, which has never heard of that domain, and refuses with a bare
    # "Access is denied" that reads like a WinRM fault and is not one. The
    # TrustedHosts entry for this host only takes effect WHEN CREDENTIALS ARE
    # PASSED, so without this parameter it was never doing anything.
    [System.Management.Automation.PSCredential]$Credential,

    [string]$EventLogSource = 'BigFunnelPostingListMonitor'
)

$ErrorActionPreference = 'Stop'

$probe = {
    param($SourceName)

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    # A name that certainly does not exist. Under 255 characters on purpose:
    # over that the registry key-name check fires first and this would measure
    # the T58 emit-failure injector instead of the rights split.
    $absent = 'BFGateProbe' + ([guid]::NewGuid().ToString('N'))

    $absentThrew = $false; $absentValue = $null; $absentError = ''
    try { $absentValue = [System.Diagnostics.EventLog]::SourceExists($absent) }
    catch { $absentThrew = $true; $absentError = $_.Exception.Message }

    $realThrew = $false; $realValue = $null
    try { $realValue = [System.Diagnostics.EventLog]::SourceExists($SourceName) }
    catch { $realThrew = $true }

    # Identity evidence, so the result is attributable to a machine rather than
    # to a name that happened to resolve on the LAN.
    $os = Get-CimInstance Win32_OperatingSystem
    $exch = $null
    try {
        $exch = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' -ErrorAction Stop).MsiProductMajor
    } catch { }

    [pscustomobject]@{
        HostName        = $env:COMPUTERNAME
        Domain          = (Get-CimInstance Win32_ComputerSystem).Domain
        OS              = $os.Caption
        OSVersion       = $os.Version
        PSVersion       = $PSVersionTable.PSVersion.ToString()
        RunningAs       = $id.Name
        Elevated        = $elevated
        ExchangeMajor   = $exch
        AbsentThrew     = $absentThrew
        AbsentValue     = $absentValue
        AbsentError     = $absentError
        RealSourceName  = $SourceName
        RealThrew       = $realThrew
        RealValue       = $realValue
    }
}

Write-Host ''
Write-Host ("Read-only Event Log probe -> {0}" -f $ComputerName) -ForegroundColor Cyan
Write-Host ('-' * 46) -ForegroundColor DarkGray

try {
    $icm = @{
        ComputerName = $ComputerName
        ScriptBlock  = $probe
        ArgumentList = $EventLogSource
        ErrorAction  = 'Stop'
    }
    if ($Credential) { $icm['Credential'] = $Credential }
    $r = Invoke-Command @icm
}
catch {
    Write-Host '  COULD NOT CONNECT' -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    if (-not $Credential -and $_.Exception.Message -match 'Access is denied') {
        # Name the likely cause rather than leaving the operator with the raw
        # message. "Access is denied" from an implicit connection is far more
        # often the wrong IDENTITY than the wrong RIGHTS, and the two want
        # opposite fixes - one needs a -Credential, the other needs a group
        # membership change on the target.
        Write-Host '  NO -Credential WAS PASSED, and this is the failure that produces.' -ForegroundColor Yellow
        Write-Host '  An implicit connection offers THIS machine''s logon identity. If this box is' -ForegroundColor Yellow
        Write-Host '  Entra-joined or in a workgroup and the target is in its own AD forest, the' -ForegroundColor Yellow
        Write-Host '  target cannot resolve that identity at all. Re-run with:' -ForegroundColor Yellow
        Write-Host ('    .\Probe-EventLogRights.ps1 -ComputerName {0} -Credential (Get-Credential LABDOMAIN\Administrator)' -f $ComputerName) -ForegroundColor Gray
        Write-Host '  Check the TrustedHosts entry exists too - it is ONLY consulted for explicit creds:' -ForegroundColor Yellow
        Write-Host '    Get-Item WSMan:\localhost\Client\TrustedHosts' -ForegroundColor Gray
        Write-Host ''
    }
    Write-Host '  The gate stays open. This is a connectivity/rights result, not a measurement' -ForegroundColor Yellow
    Write-Host '  of the Event Log behaviour - do not read it as either outcome.' -ForegroundColor Yellow
    exit 2
}

foreach ($p in 'HostName','Domain','OS','OSVersion','PSVersion','RunningAs','Elevated','ExchangeMajor') {
    Write-Host ('  {0} {1}' -f $p.PadRight(16), $r.$p)
}

Write-Host ''
Write-Host '  THE MEASUREMENT' -ForegroundColor Cyan
Write-Host ('  SourceExists(<absent>)  threw={0}  value={1}' -f $r.AbsentThrew, $r.AbsentValue)
if ($r.AbsentThrew) { Write-Host ('    error: ' + $r.AbsentError) -ForegroundColor DarkGray }
Write-Host ('  SourceExists({0})  threw={1}  value={2}' -f $r.RealSourceName, $r.RealThrew, $r.RealValue)

Write-Host ''
if (-not $r.Elevated) {
    Write-Host '  NOT ELEVATED in the remote session. This reproduces the workstation' -ForegroundColor Yellow
    Write-Host '  measurement, not the open half of the gate. Gate stays open.' -ForegroundColor Yellow
}
elseif ($r.AbsentThrew) {
    Write-Host '  ELEVATED AND IT STILL THREW.' -ForegroundColor Red
    Write-Host '  The runbook IMPORTANT block and Initialize-EmitEventSource both describe the' -ForegroundColor Red
    Write-Host '  throw as a non-admin symptom. That is WRONG and needs correcting.' -ForegroundColor Red
}
else {
    Write-Host '  ELEVATED AND IT ANSWERED CLEANLY. This is what the code assumes, and it is' -ForegroundColor Green
    Write-Host '  now measured rather than asserted. The New-EventLog half is still open.' -ForegroundColor Green
}

Write-Host ''
Write-Host '  RESULTS - paste into the branch-state log' -ForegroundColor Cyan
Write-Host ('  host={0} elevated={1} absentThrew={2} absentValue={3} realExists={4} utc={5}' -f `
    $r.HostName, $r.Elevated, $r.AbsentThrew, $r.AbsentValue, $r.RealValue,
    [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
