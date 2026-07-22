<#
.SYNOPSIS
Collects Exchange CU, HU, and SU installation evidence.

.DESCRIPTION
Builds a structured inventory object that can be referenced by later EPO Toolbox
stages. The stage is read-only. It emits shell-visible progress and writes JSON
and CSV evidence for both GUI and unattended execution.
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
Import-Module (Join-Path $PSScriptRoot 'Modules\Epo.UpdateInventory.psm1') -Force

$Config = Import-PowerShellDataFile -Path $ConfigPath
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $env:TEMP 'ExchangeCuDagPatch'
}

if (-not $TargetServers -or $TargetServers.Count -eq 0) {
    if ($Config.ContainsKey('Inventory') -and $Config.Inventory.TargetServers) {
        $TargetServers = @($Config.Inventory.TargetServers)
    }
}
$TargetServers = @($TargetServers | ForEach-Object { [string] $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $TargetServers -or $TargetServers.Count -eq 0) {
    $TargetServers = @($env:COMPUTERNAME)
}

$RunContext = Initialize-EpoRun `
    -CorrelationId $CorrelationId `
    -RunRoot $OutputRoot `
    -StageName 'UpdateInventory' `
    -Config $Config

Write-Information "EPO Toolbox update inventory starting. CorrelationId=$CorrelationId TargetServers=$($TargetServers -join ', ')" -InformationAction Continue
Write-EpoEvent -RunContext $RunContext -Phase 'UpdateInventory' -Step 'Start' -Status 'Started' -Severity 'Info' -Message "Collecting update inventory for $($TargetServers.Count) server(s)."

$Inventory = Get-EpoExchangeUpdateInventory -ServerName $TargetServers
$EvidenceFile = Export-EpoEvidence -RunContext $RunContext -Name 'UpdateInventory' -InputObject $Inventory
$CsvFile = Export-EpoUpdateInventoryCsv -RunContext $RunContext -Inventory $Inventory

Write-EpoEvent -RunContext $RunContext -Phase 'UpdateInventory' -Step 'Complete' -Status 'Complete' -Severity 'Info' -EvidencePath $EvidenceFile -Message "Update inventory completed."

$ShellRows = foreach ($ServerInventory in $Inventory.Servers) {
    $CurrentBuild = ''
    if ($ServerInventory.ExchangeSetup -and $ServerInventory.ExchangeSetup.PSObject.Properties['FileVersion']) {
        $CurrentBuild = [string] $ServerInventory.ExchangeSetup.FileVersion
    }
    $CuUpdate = @($ServerInventory.InstalledUpdates | Where-Object Type -eq 'CU' | Select-Object -First 1)
    $HuUpdate = @($ServerInventory.InstalledUpdates | Where-Object Type -eq 'HU' | Select-Object -First 1)
    $SuUpdate = @($ServerInventory.InstalledUpdates | Where-Object Type -eq 'SU' | Select-Object -First 1)
    [pscustomobject] @{
        Server = $ServerInventory.Server
        Status = $ServerInventory.Status
        CurrentBuild = $CurrentBuild
        CU = if ($CuUpdate.Count) { $CuUpdate[0].DisplayName } else { '' }
        LatestHU = if ($HuUpdate.Count) { $HuUpdate[0].DisplayName } else { '' }
        LatestSU = if ($SuUpdate.Count) { $SuUpdate[0].DisplayName } else { '' }
        UpdateCount = @($ServerInventory.InstalledUpdates).Count
    }
}

Write-Information 'EPO Toolbox update inventory summary:' -InformationAction Continue
Write-Information -MessageData ($ShellRows | Format-Table -AutoSize | Out-String) -InformationAction Continue

$Inventory | Add-Member -NotePropertyName RunPath -NotePropertyValue $RunContext.RunPath -Force
$Inventory | Add-Member -NotePropertyName EvidenceFile -NotePropertyValue $EvidenceFile -Force
$Inventory | Add-Member -NotePropertyName CsvFile -NotePropertyValue $CsvFile -Force
$Inventory
