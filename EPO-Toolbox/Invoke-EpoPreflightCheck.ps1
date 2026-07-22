<#
.SYNOPSIS
Runs EPO Toolbox preflight checks.

.DESCRIPTION
Runs read-only preflight checks before Exchange patching. The current
implementation packages and calls Get-PendingReboot.ps1 so pending reboot state
is visible in shell output, GUI output, and structured evidence.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $OutputRoot,
    [string[]] $TargetServers,
    [string] $CorrelationId = ([guid]::NewGuid().Guid),
    [switch] $ValidationOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'Config\ExchangeCuPatch.config.psd1'
}

Import-Module (Join-Path $PSScriptRoot 'Modules\Epo.Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\Epo.Preflight.psm1') -Force

$Config = Import-PowerShellDataFile -Path $ConfigPath
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $env:TEMP 'ExchangeCuDagPatch'
}

if (-not $TargetServers -or $TargetServers.Count -eq 0) {
    if ($Config.ContainsKey('Preflight') -and $Config.Preflight.TargetServers) {
        $TargetServers = @($Config.Preflight.TargetServers)
    }
    elseif ($Config.ContainsKey('Inventory') -and $Config.Inventory.TargetServers) {
        $TargetServers = @($Config.Inventory.TargetServers)
    }
}
$TargetServers = @($TargetServers | ForEach-Object { [string] $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $TargetServers -or $TargetServers.Count -eq 0) {
    $TargetServers = @($env:COMPUTERNAME)
}

$PendingRebootScriptPath = Join-Path $PSScriptRoot 'Scripts\Get-PendingReboot.ps1'
if ($Config.ContainsKey('Preflight') -and -not [string]::IsNullOrWhiteSpace($Config.Preflight.PendingRebootScriptPath)) {
    $ConfiguredPath = [string] $Config.Preflight.PendingRebootScriptPath
    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        $PendingRebootScriptPath = $ConfiguredPath
    }
    else {
        $PendingRebootScriptPath = Join-Path $PSScriptRoot $ConfiguredPath
    }
}

$RunContext = Initialize-EpoRun `
    -CorrelationId $CorrelationId `
    -RunRoot $OutputRoot `
    -StageName 'PreCheck' `
    -Config $Config

Write-Information "EPO Toolbox preflight checks starting. CorrelationId=$CorrelationId TargetServers=$($TargetServers -join ', ')" -InformationAction Continue
Write-EpoEvent -RunContext $RunContext -Phase 'PreCheck' -Step 'Start' -Status 'Started' -Severity 'Info' -Message "Running preflight checks for $($TargetServers.Count) server(s)."

$Preflight = Invoke-EpoPreflightCheck `
    -ServerName $TargetServers `
    -PendingRebootScriptPath $PendingRebootScriptPath `
    -EnablePendingRebootFallback:([bool] $Config.Preflight.EnablePendingRebootFallback) `
    -IncludeSccmRebootState:([bool] $Config.Preflight.IncludeSccmRebootState) `
    -BlockOnPendingReboot:([bool] $Config.Preflight.BlockOnPendingReboot) `
    -BlockOnUnknownRebootState:([bool] $Config.Preflight.BlockOnUnknownRebootState) `
    -DotNetMinimumRelease:([int] $Config.Preflight.DotNetMinimumRelease) `
    -DotNetMinimumVersion:([string] $Config.Preflight.DotNetMinimumVersion) `
    -BlockOnIncompatibleDotNet:([bool] $Config.Preflight.BlockOnIncompatibleDotNet) `
    -EnableDotNetAcceleration:([bool] $Config.Preflight.EnableDotNetAcceleration)

$EvidenceFile = Export-EpoEvidence -RunContext $RunContext -Name 'Preflight' -InputObject $Preflight
$CsvFile = Export-EpoPreflightCsv -RunContext $RunContext -Preflight $Preflight

Write-EpoEvent -RunContext $RunContext -Phase 'PreCheck' -Step 'Complete' -Status $Preflight.Status -Severity $Preflight.Severity -EvidencePath $EvidenceFile -Message "Preflight checks completed."

$ShellRows = foreach ($ServerPreflight in $Preflight.Servers) {
    [pscustomobject] @{
        Server = $ServerPreflight.Server
        Status = $ServerPreflight.Status
        Severity = $ServerPreflight.Severity
        RebootRequired = $ServerPreflight.PendingReboot.RebootRequired
        DotNetVersion = $ServerPreflight.DotNet.DetectedVersion
        DotNetReady = $ServerPreflight.DotNet.IsCompatible
        DotNetAcceleration = $ServerPreflight.DotNet.Acceleration.Status
        ConnectionMethod = $ServerPreflight.PendingReboot.ConnectionMethod
        Blocked = $ServerPreflight.Blocked
    }
}

Write-Information 'EPO Toolbox preflight summary:' -InformationAction Continue
Write-Information -MessageData ($ShellRows | Format-Table -AutoSize | Out-String) -InformationAction Continue

$Preflight | Add-Member -NotePropertyName RunPath -NotePropertyValue $RunContext.RunPath -Force
$Preflight | Add-Member -NotePropertyName EvidenceFile -NotePropertyValue $EvidenceFile -Force
$Preflight | Add-Member -NotePropertyName CsvFile -NotePropertyValue $CsvFile -Force
$Preflight
