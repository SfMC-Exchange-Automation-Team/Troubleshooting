#Requires -Version 5.1
<#
.SYNOPSIS
Detects eligibility or applies the narrowly scoped KB5130098 workaround locally.
.DESCRIPTION
No Exchange changes occur in Detect mode. Apply never overwrites existing rules.
Restart is opt-in and requires an approved maintenance window. Workload validation
is always manual. Local interactive runs can request UAC elevation. Human-readable
before/action/current output is the default; -AsJson preserves machine output.
See README.txt for rollout gates, exit codes and rollback limits.
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
    [switch]$NoAutoElevate,
    [switch]$AsJson,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(15, 300)][int]$StabilitySeconds = 30
)
$ErrorActionPreference = 'Stop'
$before = $null
$after = $null
$result = $null
$moduleLoaded = $false
try {
    if (-not $PSBoundParameters.ContainsKey('PayloadDirectory')) {
        $PayloadDirectory = Join-Path $PSScriptRoot 'payload'
    }
    Import-Module (Join-Path $PSScriptRoot 'KB5130098.psm1') -Force -ErrorAction Stop
    $moduleLoaded = $true
    $elevation = Invoke-KBAutoElevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters `
        -NoAutoElevate:$NoAutoElevate -AsJson:$AsJson -InPipeline:($MyInvocation.PipelineLength -gt 1) `
        -PreviewPreference $WhatIfPreference -ConfirmationPreference ([string]$ConfirmPreference)
    if ($null -ne $elevation) { exit $elevation.ExitCode }
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
    if (-not $AsJson) { $before = Invoke-KBLocal -Mode Detect }
    $result = Invoke-KBLocal @parameters
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 6
    } else {
        $after = if ($Mode -eq 'Detect') { $result } else { Invoke-KBLocal -Mode Detect }
        Write-KBConsoleResult -Mode $Mode -Result $result -Before $before -After $after `
            -Preview:$WhatIfPreference -StabilitySeconds $StabilitySeconds
    }
    if ($result.Status -eq 'FilesStagedRestartRequired' -or $result.Status -eq 'RolledBackRestartRequired') {
        exit 10
    }
    if ($result.Status -in @('NotApplicableStop', 'RuleFilesPresentStop')) { exit 20 }
    exit 0
} catch {
    $failure = $_
    if (-not $AsJson -and $moduleLoaded) {
        $observationError = $null
        if ($null -ne $before -and $null -eq $after) {
            try { $after = Invoke-KBLocal -Mode Detect } catch { $observationError = $_.Exception.Message }
        }
        $receiptPath = $failure.Exception.Data['KB5130098ReceiptPath']
        if ($receiptPath) {
            $result = [pscustomobject]@{
                Status = 'FailedStopAndContactSupport'
                ReceiptPath = $receiptPath
                CreatedFiles = @($failure.Exception.Data['KB5130098CreatedFiles'])
            }
        }
        Write-KBConsoleResult -Mode $Mode -Result $result -Before $before -After $after `
            -ErrorMessage $failure.Exception.Message -ObservationError $observationError -StabilitySeconds $StabilitySeconds
    }
    [Console]::Error.WriteLine($failure.Exception.Message)
    exit 1
}
