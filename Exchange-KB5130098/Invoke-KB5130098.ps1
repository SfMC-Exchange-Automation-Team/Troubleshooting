#Requires -Version 5.1
<#
.SYNOPSIS
Detects eligibility or applies the narrowly scoped KB5130098 workaround locally.
.DESCRIPTION
No Exchange changes occur in Detect mode. Apply never overwrites existing rules.
Restart is opt-in and requires an approved maintenance window. Workload validation
is always manual. See README.txt for rollout gates, exit codes and rollback limits.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Detect', 'Apply', 'Rollback')][string]$Mode = 'Detect',
    [string]$PayloadDirectory,
    [string]$StateRoot = (Join-Path $env:ProgramData 'Exchange-KB5130098'),
    [string]$ReceiptPath,
    [switch]$RestartSearch,
    [switch]$MaintenanceWindowApproved,
    [switch]$MicrosoftSupportApprovedRollback,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(15, 300)][int]$StabilitySeconds = 30
)
$ErrorActionPreference = 'Stop'
try {
    if (-not $PSBoundParameters.ContainsKey('PayloadDirectory')) {
        $PayloadDirectory = Join-Path $PSScriptRoot 'payload'
    }
    Import-Module (Join-Path $PSScriptRoot 'KB5130098.psm1') -Force -ErrorAction Stop
    $parameters = @{
        Mode = $Mode
        PayloadDirectory = $PayloadDirectory
        StateRoot = $StateRoot
        RestartSearch = $RestartSearch
        MaintenanceWindowApproved = $MaintenanceWindowApproved
        MicrosoftSupportApprovedRollback = $MicrosoftSupportApprovedRollback
        TimeoutSeconds = $TimeoutSeconds
        StabilitySeconds = $StabilitySeconds
    }
    if ($ReceiptPath) { $parameters.ReceiptPath = $ReceiptPath }
    if ($PSBoundParameters.ContainsKey('WhatIf')) { $parameters.WhatIf = $PSBoundParameters.WhatIf }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $parameters.Confirm = $PSBoundParameters.Confirm }
    $result = Invoke-KBLocal @parameters
    $result | ConvertTo-Json -Depth 6
    if ($result.Status -eq 'FilesStagedRestartRequired' -or $result.Status -eq 'RolledBackRestartRequired') {
        exit 10
    }
    if ($result.Status -in @('NotApplicableStop', 'RuleFilesPresentStop')) { exit 20 }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
