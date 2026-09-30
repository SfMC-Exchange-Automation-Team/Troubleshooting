#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility entry point. Use Install-KoreanRules to prepare installation files.
#>
[CmdletBinding(DefaultParameterSetName='ExistingMedia', PositionalBinding=$false)]
param(
    [Parameter(Position=0, ParameterSetName='ExistingMedia')][Alias('Path')][string]$SqlPackagePath,
    [Parameter(Mandatory, ParameterSetName='Download')][switch]$Download,
    [Parameter(Mandatory, ParameterSetName='ExistingRules')][string]$RuleSourceDirectory,
    [Parameter(Position=1)][string]$OutputDirectory,
    [switch]$ManagementWorkstationConfirmed,
    [string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Install-KoreanRules.ps1') @PSBoundParameters
exit $LASTEXITCODE
