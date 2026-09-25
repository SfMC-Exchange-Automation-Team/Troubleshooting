#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility entry point for the former fleet workflow.
.DESCRIPTION
Prefer Invoke-KB5130098.ps1 -ComputerName or -CsvPath for new usage.
For compatibility, this entry point's Apply still includes a Search restart
and requires maintenance approval and recovery attestation after every server.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [ValidateSet('Detect', 'Apply')][string]$Mode = 'Detect',
    [string]$PackageDirectory,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [switch]$MaintenanceWindowApproved,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(15, 300)][int]$StabilitySeconds = 30
)
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('PackageDirectory')) { $PackageDirectory=$PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'KB5130098.psm1') -Force
$parameters = @{
    ComputerName=$ComputerName; Mode=$Mode; PackageDirectory=$PackageDirectory
    ReportDirectory=$ReportDirectory; RestartSearch=($Mode -eq 'Apply')
    MaintenanceWindowApproved=$MaintenanceWindowApproved
    TimeoutSeconds=$TimeoutSeconds; StabilitySeconds=$StabilitySeconds
}
if ($PSBoundParameters.ContainsKey('WhatIf')) { $parameters.WhatIf=$PSBoundParameters.WhatIf }
if ($PSBoundParameters.ContainsKey('Confirm')) { $parameters.Confirm=$PSBoundParameters.Confirm }
$result = Invoke-KBFleet @parameters
if ($result.Status -ne 'NoChanges') { $result }
