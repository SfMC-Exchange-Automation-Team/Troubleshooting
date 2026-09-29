#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility entry point. Use Install-KoreanRules to prepare installation files.
#>
[CmdletBinding(DefaultParameterSetName='ExistingMedia')]
param(
    [Parameter(Mandatory, ParameterSetName='ExistingMedia')][string]$SqlPackagePath,
    [Parameter(Mandatory, ParameterSetName='Download')][switch]$Download,
    [Parameter(Mandatory, ParameterSetName='ExistingRules')][string]$RuleSourceDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$ManagementWorkstationConfirmed,
    [string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Install-KoreanRules.ps1') @PSBoundParameters
