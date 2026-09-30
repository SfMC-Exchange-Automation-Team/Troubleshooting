#Requires -Version 5.1
<#
.SYNOPSIS
Compatibility entry point for the former fleet workflow.
.DESCRIPTION
Prefer Get-KoreanRulesState.ps1 or Set-KoreanRulesState.ps1 for new usage.
For compatibility, this entry point's Apply still includes a Search restart
and requires maintenance approval and recovery attestation after every server.
Reports default to C:\Temp\KB5130098-Reports on the calling computer.
Standard PowerShell confirmation is opt-in with -Confirm at the default
ConfirmPreference; maintenance approval and recovery attestation still apply.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', PositionalBinding=$false)]
param(
    [Parameter(Mandatory, Position=0)][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [ValidateSet('Detect', 'Apply')][string]$Mode = 'Detect',
    [string]$PackageDirectory,
    [ValidateNotNullOrEmpty()][string]$ReportDirectory,
    [switch]$MaintenanceWindowApproved,
    [switch]$NoCsv,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(15, 300)][int]$StabilitySeconds = 30
)
$ErrorActionPreference = 'Stop'
Set-Variable -Name report -Scope Global -Value @() -ErrorAction Stop -WhatIf:$false -Confirm:$false
Set-Variable -Name reportFiles -Scope Global -Value $null -ErrorAction Stop -WhatIf:$false -Confirm:$false
if (-not $PSBoundParameters.ContainsKey('PackageDirectory')) { $PackageDirectory=$PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'KoreanRules.psm1') -Force
$parameters = @{
    ComputerName=$ComputerName; Mode=$Mode; PackageDirectory=$PackageDirectory
    RestartSearch=($Mode -eq 'Apply')
    MaintenanceWindowApproved=$MaintenanceWindowApproved
    NoCsv=$NoCsv
    TimeoutSeconds=$TimeoutSeconds; StabilitySeconds=$StabilitySeconds
}
if ($PSBoundParameters.ContainsKey('ReportDirectory')) { $parameters.ReportDirectory=$ReportDirectory }
if ($PSBoundParameters.ContainsKey('WhatIf')) { $parameters.WhatIf=$PSBoundParameters.WhatIf }
if ($PSBoundParameters.ContainsKey('Confirm')) { $parameters.Confirm=$PSBoundParameters.Confirm }
try {
    $result = Invoke-KBFleet @parameters
    Set-Variable -Name report -Scope Global -Value @($result.ReportData) -WhatIf:$false -Confirm:$false
    Set-Variable -Name reportFiles -Scope Global -Value $result.ExportFiles -WhatIf:$false -Confirm:$false
    Write-KBReportSummary -Rows @($result.ReportData) -Files $result.ExportFiles
    if ($result.Status -ne 'NoChanges') { $result }
} catch {
    $rows = @($_.Exception.Data['KB5130098ReportRows'] | Where-Object { $null -ne $_ })
    $files = $_.Exception.Data['KB5130098ReportFiles']
    Set-Variable -Name report -Scope Global -Value $rows -WhatIf:$false -Confirm:$false
    Set-Variable -Name reportFiles -Scope Global -Value $files -WhatIf:$false -Confirm:$false
    Write-KBReportSummary -Rows $rows -Files $files
    throw
}
