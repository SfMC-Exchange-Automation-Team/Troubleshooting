#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility entry point. Use Get-KoreanRulesState or Set-KoreanRulesState.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium', DefaultParameterSetName='Local', PositionalBinding=$false)]
param(
    [ValidateSet('Detect','Apply','Rollback')][string]$Mode='Detect',
    [Parameter(Mandatory, Position=0, ParameterSetName='RemoteNames')][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [Parameter(Mandatory, ParameterSetName='RemoteCsv')][ValidateNotNullOrEmpty()][string]$CsvPath,
    [ValidateNotNullOrEmpty()][string]$ReportDirectory,
    [string]$PayloadDirectory,
    [Parameter(ParameterSetName='Local')][string]$StateRoot,
    [Parameter(ParameterSetName='Local')][string]$ReceiptPath,
    [switch]$RestartSearch,
    [switch]$MaintenanceWindowApproved,
    [Parameter(ParameterSetName='Local')][switch]$MicrosoftSupportApprovedRollback,
    [Parameter(ParameterSetName='Local')][switch]$NoAutoElevate,
    [switch]$AsJson,
    [switch]$PassThru,
    [switch]$NoCsv,
    [ValidateRange(30,600)][int]$TimeoutSeconds=120,
    [ValidateRange(15,300)][int]$StabilitySeconds=30
)
$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'KoreanRules.psm1') -PathType Leaf)) {
    $packageRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
$operation = Join-Path $packageRoot 'private\Invoke-KoreanRulesOperation.ps1'
if (-not (Test-Path -LiteralPath $operation -PathType Leaf)) {
    throw 'Korean Rules package is incomplete. Extract the complete source or deployment package, including its private folder and module; do not copy only the entry-point scripts.'
}
$parameters = @{} + $PSBoundParameters
if ($PSCmdlet.ParameterSetName -eq 'Local' -and $MyInvocation.PipelineLength -gt 1) {
    $parameters.NoAutoElevate = $true
}
& $operation @parameters
exit $LASTEXITCODE
