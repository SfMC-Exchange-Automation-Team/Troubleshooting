#Requires -Version 5.1
<#
.SYNOPSIS
Applies the guarded Korean Rules workaround locally or on remote/CSV targets.
.DESCRIPTION
Requires a verified bundled or locally prepared payload. Never overwrites
existing rules. RestartSearch remains explicit; schedule any restart appropriately.
MaintenanceWindowApproved is an optional compatibility switch, not a gate.
Restarted remote rollout remains serial with per-server recovery attestation.
Rollback is local, receipt-bound and requires Microsoft Support approval.
Lists of four or more targets use compact output without hiding errors or
recovery prompts. Full results remain in $report and default exports.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium', DefaultParameterSetName='Local', PositionalBinding=$false)]
param(
    [Parameter(Mandatory, Position=0, ParameterSetName='RemoteNames')][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [Parameter(Mandatory, ParameterSetName='RemoteCsv')][ValidateNotNullOrEmpty()][string]$CsvPath,
    [ValidateNotNullOrEmpty()][string]$ReportDirectory,
    [string]$PayloadDirectory,
    [Parameter(ParameterSetName='Local')][string]$StateRoot,
    [Parameter(ParameterSetName='Local')][switch]$Rollback,
    [Parameter(ParameterSetName='Local')][string]$ReceiptPath,
    [Parameter(ParameterSetName='Local')][switch]$MicrosoftSupportApprovedRollback,
    [Parameter(ParameterSetName='Local')][switch]$NoAutoElevate,
    [switch]$RestartSearch,
    [switch]$MaintenanceWindowApproved,
    [switch]$AsJson,
    [switch]$PassThru,
    [switch]$NoCsv,
    [ValidateRange(30,600)][int]$TimeoutSeconds=120,
    [ValidateRange(15,300)][int]$StabilitySeconds=30
)
$ErrorActionPreference = 'Stop'
$operation = Join-Path $PSScriptRoot 'private\Invoke-KoreanRulesOperation.ps1'
if (-not (Test-Path -LiteralPath $operation -PathType Leaf)) {
    throw 'Korean Rules package is incomplete. Extract the complete source or deployment package, including its private folder and module; do not copy only the entry-point scripts.'
}
$parameters = @{} + $PSBoundParameters
$parameters.Remove('Rollback')
$parameters.Mode = if ($Rollback) { 'Rollback' } else { 'Apply' }
if ($PSCmdlet.ParameterSetName -eq 'Local' -and $MyInvocation.PipelineLength -gt 1) {
    $parameters.NoAutoElevate = $true
}
& $operation @parameters
exit $LASTEXITCODE
