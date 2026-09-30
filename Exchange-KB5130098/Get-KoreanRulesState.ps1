#Requires -Version 5.1
<#
.SYNOPSIS
Inspects Korean Rules applicability locally or on explicit remote/CSV targets.
.DESCRIPTION
Detection requires no installation payload and never modifies Exchange files or
services. Lists of four or more targets use compact human output. Full results
remain in $report and the default exports. WhatIf makes no remote connections
and writes no exports. Standard confirmation is opt-in with -Confirm.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium', DefaultParameterSetName='Local', PositionalBinding=$false)]
param(
    [Parameter(Mandatory, Position=0, ParameterSetName='RemoteNames')][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [Parameter(Mandatory, ParameterSetName='RemoteCsv')][ValidateNotNullOrEmpty()][string]$CsvPath,
    [ValidateNotNullOrEmpty()][string]$ReportDirectory,
    [Parameter(ParameterSetName='Local')][switch]$NoAutoElevate,
    [switch]$AsJson,
    [switch]$PassThru,
    [switch]$NoCsv
)
$ErrorActionPreference = 'Stop'
$operation = Join-Path $PSScriptRoot 'private\Invoke-KoreanRulesOperation.ps1'
if (-not (Test-Path -LiteralPath $operation -PathType Leaf)) {
    throw 'Korean Rules package is incomplete. Extract the complete source or deployment package, including its private folder and module; do not copy only the entry-point scripts.'
}
$parameters = @{} + $PSBoundParameters
$parameters.Mode = 'Detect'
if ($PSCmdlet.ParameterSetName -eq 'Local' -and $MyInvocation.PipelineLength -gt 1) {
    $parameters.NoAutoElevate = $true
}
& $operation @parameters
exit $LASTEXITCODE
