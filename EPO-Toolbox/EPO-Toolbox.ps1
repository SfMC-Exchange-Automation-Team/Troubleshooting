<#
.SYNOPSIS
Stage-aware entrypoint for the Exchange CU DAG patching toolbox.

.DESCRIPTION
Dispatches the requested stage of the patching process. The framework is intended
to be dynamic: each stage reports where it is in the overall sequence, what it
knows from config/runtime discovery, and what is required before advancing.

Windows PowerShell 5.1 is the default runtime target because on-prem Exchange
Management Shell cmdlets are Windows PowerShell based. Stage 1 intentionally
remains safe to run before Exchange cmdlets, patch media, or DAG connectivity
are available.
#>
[CmdletBinding()]
param(
    [ValidateSet(
        'Auto',
        'SopAnalysis',
        'UpdateInventory',
        'DagDiscovery',
        'PreCheck',
        'Maintenance',
        'PackagePrep',
        'Install',
        'PostCheck',
        'Rollback',
        'Report'
    )]
    [string] $Stage = 'Auto',
    [string] $ConfigPath,
    [string] $OutputRoot,
    [string[]] $TargetServers,
    [string] $CorrelationId = ([guid]::NewGuid().Guid),
    [switch] $ValidationOnly,
    [switch] $Gui
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'Config\ExchangeCuPatch.config.psd1'
}

if ($Gui) {
    Import-Module (Join-Path $PSScriptRoot 'Modules\Epo.Gui.psm1') -Force
    Show-EpoToolboxDashboard `
        -ToolboxRoot $PSScriptRoot `
        -ConfigPath $ConfigPath `
        -OutputRoot $OutputRoot `
        -TargetServers $TargetServers `
        -CorrelationId $CorrelationId `
        -Stage $Stage `
        -ValidationOnly:$ValidationOnly
    return
}

$Config = Import-PowerShellDataFile -Path $ConfigPath
$ResolvedStage = $Stage
if ($ResolvedStage -eq 'Auto') {
    $ResolvedStage = $Config.StageAwareness.CurrentStage
}

switch ($ResolvedStage) {
    'SopAnalysis' {
        & (Join-Path $PSScriptRoot 'Invoke-ExchangeCuStage1SopAnalysis.ps1') `
            -ConfigPath $ConfigPath `
            -OutputRoot $OutputRoot `
            -CorrelationId $CorrelationId `
            -ValidationOnly:$ValidationOnly
        break
    }
    'UpdateInventory' {
        & (Join-Path $PSScriptRoot 'Invoke-EpoUpdateInventory.ps1') `
            -ConfigPath $ConfigPath `
            -OutputRoot $OutputRoot `
            -TargetServers $TargetServers `
            -CorrelationId $CorrelationId `
            -ValidationOnly:$ValidationOnly
        break
    }
    default {
        throw "Stage '$ResolvedStage' is defined in the toolbox sequence but has not been implemented yet."
    }
}
