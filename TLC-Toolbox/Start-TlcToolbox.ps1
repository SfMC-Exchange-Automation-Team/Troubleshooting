<#
.SYNOPSIS
Launches the TLC Toolbox.

.DESCRIPTION
The single entry point for an operator who does not want to remember a command line. Imports the
module and opens the guided collection window.

Everything it does is available directly:

    Import-Module .\Tlc.psd1
    .\TLC-Toolbox.ps1 -Stage Collect -Scenario DesktopLaunchCrash -CaseNumber 12345

This exists so that is not required knowledge on day one.

WPF needs an STA thread. Windows PowerShell 5.1 is always STA. PowerShell 7 is STA by default on
Windows now - measured 7.6.5 - but it was MTA in earlier 7.x, and it can still be put into MTA
deliberately with -MTA or by a host that embeds it. The raw failure says nothing useful about the
cause, so this relaunches itself rather than leaving the operator to work it out. The check is kept
because the condition is still reachable, not because the current default is wrong.

.PARAMETER Console
Import the module and drop to a prompt with the toolbox loaded, instead of opening the window.

.PARAMETER Stage
Run a stage immediately rather than opening anything, through TLC-Toolbox.ps1, and exit with its
code (2 for a Blocked run). Only -Scenario, -CaseNumber, -CorrelationId, -ConsentGrantedBy,
-ConfigPath and -OutputRoot are passed on; for any other parameter, call TLC-Toolbox.ps1 directly.

.PARAMETER CorrelationId
With -Stage: the run to act on, as for packaging a collection made earlier.

.PARAMETER ConsentGrantedBy
With -Stage: who authorised the collection, for this run only.

.PARAMETER NoRelaunch
Internal. Set on the relaunched process so it cannot loop, and by Start-TlcToolbox.cmd and the Start
menu entry. It marks the process as the toolbox's own, which is when the launcher gives it the
toolbox's taskbar identity.

.PARAMETER Install
Internal setup path used by TLC-Toolbox.exe. Installs the declared payload into the stable
per-user program folder and creates its Start menu shortcut without starting a collection.

.EXAMPLE
.\Start-TlcToolbox.ps1

.EXAMPLE
.\Start-TlcToolbox.ps1 -Console

.EXAMPLE
.\Start-TlcToolbox.ps1 -Stage Collect -Scenario Network -CaseNumber 1234567890123456
#>
[CmdletBinding()]
param(
    [switch] $Console,
    [string] $Stage = '',
    [string] $Scenario = '',
    [string] $CaseNumber,
    [string] $ConfigPath,
    [string] $OutputRoot,
    [string] $CorrelationId,
    [string] $ConsentGrantedBy,
    [switch] $Install,
    [switch] $NoRelaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ConstrainedLanguage check before anything else - see TLC-Toolbox.ps1 and finding 152. A
# WDAC or AppLocker managed machine cannot run this toolbox, and without this it fails while
# naming a healthy config file as the cause. Property reads and string comparison only, so the
# check survives the mode it reports on.
$languageMode = 'unknown'
try { $languageMode = "$($ExecutionContext.SessionState.LanguageMode)" } catch { Write-Verbose 'Language mode unavailable; continuing.' }
if ($languageMode -ne 'FullLanguage' -and $languageMode -ne 'unknown') {
    Write-Warning "TLC-Toolbox cannot run in $languageMode mode. This machine restricts PowerShell, usually through WDAC or AppLocker. Nothing has been collected and nothing has been changed."
    Write-Warning 'Options: run from a machine or account not covered by that policy, use the Teams admin center remote log collection instead, or ask the customer to permit this script under their policy.'
    throw "PowerShell is in $languageMode; TLC-Toolbox requires FullLanguage."
}

$toolboxRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifest = Join-Path $toolboxRoot 'Tlc.psd1'

<#
    Start-TlcToolbox.cmd launches this with -WindowStyle Hidden, so there is no console
    to print to. A failure importing the module or opening the window would otherwise be
    completely invisible: the operator double-clicks, nothing happens, and there is
    nothing to report. The message box is the only channel left.

    Defined before anything that can fail, and the whole body below runs inside the
    handler that uses it. It previously sat further down, which left the STA guard's own
    throw outside any handler - and that guard is reached in exactly the configuration
    the .cmd creates (hidden window, -NoRelaunch). A machine that refused STA therefore
    produced the precise failure this function exists to prevent: exit code 1, no window,
    no message, no log.
#>
function Show-TlcStartupError {
    param(
        [Parameter(Mandatory)] $ErrorRecord,
        [string] $LogPath,
        # The dialog is for the window path, which has no console. A stage or console run has
        # one, and may have nobody to dismiss a dialog: from a script, a scheduled task or a
        # hidden process the box was never seen and the run never ended (review 2026-09-30,
        # finding 331).
        [switch] $NoDialog
    )

    $message = "The TLC Toolbox could not start.`n`n$($ErrorRecord.Exception.Message)"
    if ($LogPath) { $message += "`n`nDiagnostics were written to:`n$LogPath" }

    # Always write to the console too, for anyone running this directly.
    Write-Warning $message
    if ($NoDialog) { return }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show($message, 'TLC Toolbox', 'OK', 'Error') | Out-Null
    } catch {
        # WPF itself may be what failed. Nothing further can be shown, and the console
        # message above plus the log file are what remain.
        Write-Verbose "Could not display a message box: $($_.Exception.Message)"
    }
}

try {
    if ($Install) {
        Import-Module $manifest -Force -ErrorAction Stop
        Install-TlcApplication -ToolboxRoot $toolboxRoot
        return
    }
    if ($Stage) {
        $arguments = @{ Stage = $Stage }
        if ($Scenario) { $arguments['Scenario'] = $Scenario }
        if ($CaseNumber) { $arguments['CaseNumber'] = $CaseNumber }
        if ($ConfigPath) { $arguments['ConfigPath'] = $ConfigPath }
        if ($OutputRoot) { $arguments['OutputRoot'] = $OutputRoot }
        # Packaging an earlier collection needs the run it acts on, and consent is given per
        # run. Without these two, stage mode could not package anything (review 2026-09-30).
        if ($CorrelationId) { $arguments['CorrelationId'] = $CorrelationId }
        if ($PSBoundParameters.ContainsKey('ConsentGrantedBy')) { $arguments['ConsentGrantedBy'] = $ConsentGrantedBy }
        # Called in-process, so TLC-Toolbox.ps1 sees an 'Internal' origin and returns its
        # result rather than exiting 2 for a refused run. That code has to be raised HERE or
        # the headless path would report every Blocked run as success - the defect finding 290
        # fixed at the entry point would survive one layer up.
        $stageOutput = @(& (Join-Path $toolboxRoot 'TLC-Toolbox.ps1') @arguments)
        $stageOutput
        $stageResult = @($stageOutput | Where-Object {
                # The run result is an ordered DICTIONARY, whose keys are not properties - a
                # PSObject.Properties test alone would never match it and every Blocked run
                # would still exit 0 from here.
                ($_ -is [System.Collections.IDictionary] -and $_.Contains('Status')) -or
                ($_ -and $_.PSObject.Properties.Name -contains 'Status')
            }) | Select-Object -Last 1
        if ($stageResult -and $stageResult.Status -eq 'Blocked') { exit 2 }
        return
    }

    if ($Console) {
        Import-Module $manifest -Force
        Write-Information 'TLC Toolbox module imported. Try: Get-TlcScenarioCatalog' -InformationAction Continue
        return
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        if ($NoRelaunch) {
            throw 'Could not obtain an STA thread, which WPF requires. Run this from Windows PowerShell, or start pwsh with -STA.'
        }

        $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        Write-Information "Restarting in STA mode ($shell)..." -InformationAction Continue
        & $shell -STA -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path -NoRelaunch
        exit $LASTEXITCODE
    }

    Import-Module $manifest -Force -ErrorAction Stop

    # The taskbar identity, so the window gets its own button and icon instead of grouping
    # with PowerShell, and a pin of the Start menu entry reopens the toolbox. It has to be set
    # before the first window, because the taskbar reads it when a button is created.
    #
    # Only in a process the toolbox started for itself. The .cmd, the Start menu entry and the
    # STA relaunch all pass -NoRelaunch; without it this is the operator's own console or the
    # ISE, whose identity is not the toolbox's to change. A refusal changes nothing else: the
    # window opens grouped with PowerShell, as it always did. Finding 341.
    if ($NoRelaunch) { $null = Set-TlcProcessAppId -AppId (Get-TlcAppUserModelId) }
    Show-TlcWizard -ToolboxRoot $toolboxRoot
} catch {
    $failure = $_
    $logPath = ''
    try {
        Import-Module (Join-Path $toolboxRoot 'Modules\Tlc.Logging.psm1') -Force -ErrorAction Stop
        $logPath = Write-TlcStartupFailure -ErrorRecord $failure -Context 'TLC Toolbox launcher'
    } catch {
        Write-Verbose "Could not write a startup failure log: $($_.Exception.Message)"
    }

    Show-TlcStartupError -ErrorRecord $failure -LogPath $logPath -NoDialog:([bool]$Stage -or [bool]$Console -or $Install)
    exit 1
}
