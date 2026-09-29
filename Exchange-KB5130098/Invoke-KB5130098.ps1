#Requires -Version 5.1
<#
.SYNOPSIS
Detects eligibility or applies the narrowly scoped KB5130098 workaround locally.
.DESCRIPTION
No Exchange changes occur in Detect mode. Apply never overwrites existing rules.
Restart is opt-in and requires an approved maintenance window. Workload validation
is always manual. Local interactive runs can request UAC elevation. Human-readable
status/action output is the default, with before/current comparisons for Apply.
-AsJson preserves machine output.
CSV targets accept ComputerName, Fqdn or Name (in that precedence order).
Get-ExchangeServer exports do not require a calculated ComputerName property.
Results remain in caller $report, with paths in $reportFiles. CSV, detailed JSON
and JSON Lines export by default, except previews. -NoCsv suppresses CSV only.
Reports default to C:\Temp\KB5130098-Reports on the calling computer.
See README.txt for rollout gates, exit codes and rollback limits.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Local')]
param(
    [ValidateSet('Detect', 'Apply', 'Rollback')][string]$Mode = 'Detect',
    [Parameter(Mandatory, ParameterSetName = 'RemoteNames')][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [Parameter(Mandatory, ParameterSetName = 'RemoteCsv')][ValidateNotNullOrEmpty()][string]$CsvPath,
    [ValidateNotNullOrEmpty()][string]$ReportDirectory,
    [string]$PayloadDirectory,
    [Parameter(ParameterSetName = 'Local')][string]$StateRoot = (Join-Path $env:ProgramData 'Exchange-KB5130098'),
    [Parameter(ParameterSetName = 'Local')][string]$ReceiptPath,
    [switch]$RestartSearch,
    [switch]$MaintenanceWindowApproved,
    [Parameter(ParameterSetName = 'Local')][switch]$MicrosoftSupportApprovedRollback,
    [Parameter(ParameterSetName = 'Local')][switch]$NoAutoElevate,
    [switch]$AsJson,
    [switch]$PassThru,
    [switch]$NoCsv,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(15, 300)][int]$StabilitySeconds = 30
)
$ErrorActionPreference = 'Stop'
$before = $null
$after = $null
$result = $null
$moduleLoaded = $false
$context = $null
$rows = @()
$files = $null
$exportAttempted = $false
$startedUtc = [DateTime]::UtcNow.ToString('o')
$remote = $PSCmdlet.ParameterSetName -ne 'Local'
try {
    Set-Variable -Name report -Scope Global -Value @() -ErrorAction Stop -WhatIf:$false -Confirm:$false
    Set-Variable -Name reportFiles -Scope Global -Value $null -ErrorAction Stop -WhatIf:$false -Confirm:$false
    if ($AsJson -and $PassThru) { throw 'Choose either -AsJson text or -PassThru objects, not both.' }
    if (-not $PSBoundParameters.ContainsKey('PayloadDirectory')) {
        $PayloadDirectory = Join-Path $PSScriptRoot 'payload'
    }
    Import-Module (Join-Path $PSScriptRoot 'KB5130098.psm1') -Force -ErrorAction Stop
    $moduleLoaded = $true
    if ($remote) {
        if ($Mode -eq 'Rollback') { throw 'Remote Rollback is not supported. Use the owned receipt locally with the required approvals.' }
        $fleetParameters = @{
            Mode=$Mode; PackageDirectory=$PSScriptRoot; PayloadDirectory=$PayloadDirectory
            RestartSearch=$RestartSearch
            MaintenanceWindowApproved=$MaintenanceWindowApproved; Quiet=$AsJson
            NoCsv=$NoCsv
            TimeoutSeconds=$TimeoutSeconds; StabilitySeconds=$StabilitySeconds
        }
        if ($PSCmdlet.ParameterSetName -eq 'RemoteCsv') { $fleetParameters.CsvPath=$CsvPath }
        else { $fleetParameters.ComputerName=$ComputerName }
        if ($PSBoundParameters.ContainsKey('ReportDirectory')) { $fleetParameters.ReportDirectory=$ReportDirectory }
        if ($PSBoundParameters.ContainsKey('WhatIf')) { $fleetParameters.WhatIf=$PSBoundParameters.WhatIf }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $fleetParameters.Confirm=$PSBoundParameters.Confirm }
        $result = Invoke-KBFleet @fleetParameters
        $rows = @($result.ReportData)
        $files = $result.ExportFiles
        Set-Variable -Name report -Scope Global -Value $rows -WhatIf:$false -Confirm:$false
        Set-Variable -Name reportFiles -Scope Global -Value $files -WhatIf:$false -Confirm:$false
        if ($AsJson) { $result | ConvertTo-Json -Depth 12 }
        else {
            Write-Host ("Remote {0}: {1}. Processed {2} of {3} target(s)." -f $Mode,$result.Status,$result.Servers,$result.TargetCount)
            if ($result.Report) { Write-Host "Report: $($result.Report)" }
            Write-KBReportSummary -Rows $rows -Files $files
            if ($PassThru) { $rows }
        }
        exit $result.ExitCode
    }
    $elevation = Invoke-KBAutoElevation -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters `
        -NoAutoElevate:$NoAutoElevate -AsJson:$AsJson -InPipeline:($MyInvocation.PipelineLength -gt 1) `
        -PreviewPreference $WhatIfPreference -ConfirmationPreference ([string]$ConfirmPreference)
    if ($null -ne $elevation) {
        $rows = @($elevation.ReportData)
        $files = $elevation.ExportFiles
        Set-Variable -Name report -Scope Global -Value $rows -WhatIf:$false -Confirm:$false
        Set-Variable -Name reportFiles -Scope Global -Value $files -WhatIf:$false -Confirm:$false
        Write-KBReportSummary -Rows $rows -Files $files
        if ($PassThru) { $rows }
        exit $elevation.ExitCode
    }
    $contextParameters = @{ NoWrite=[bool]$WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('ReportDirectory')) { $contextParameters.ReportDirectory=$ReportDirectory }
    $context = New-KBReportContext @contextParameters
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
    if ($Mode -ne 'Detect') { $before = Invoke-KBLocal -Mode Detect }
    $result = Invoke-KBLocal @parameters
    if ($Mode -eq 'Detect') { $before=$result; $after=$result }
    else { $after=Invoke-KBLocal -Mode Detect }
    $record = [pscustomobject]@{
        Target=$env:COMPUTERNAME; Mode=$Mode; UTC=$startedUtc; Status=$result.Status
        RestartSearch=$RestartSearch.IsPresent; Detection=$before; Current=$after
        Result=$(if ($Mode -eq 'Detect') { $null } else { $result })
        RecoveryAttestation=$null; Error=$null; ObservationError=$null
    }
    $detailPath = if ($context.NoWrite) { $null } else { $context.JsonPath }
    $rows = @(ConvertTo-KBReportRows -Records @($record) -RunId $context.RunId -DetailReportPath $detailPath)
    Set-Variable -Name report -Scope Global -Value $rows -WhatIf:$false -Confirm:$false
    $exportAttempted = $true
    $files = Save-KBReportExports -Context $context -Records @($record) -Rows $rows -NoCsv:$NoCsv
    Set-Variable -Name reportFiles -Scope Global -Value $files -WhatIf:$false -Confirm:$false
    if ($AsJson) {
        $result | ConvertTo-Json -Depth 6
    } else {
        Write-KBConsoleResult -Mode $Mode -Result $result -Before $before -After $after `
            -Preview:$WhatIfPreference -StabilitySeconds $StabilitySeconds
        Write-KBReportSummary -Rows $rows -Files $files
        if ($PassThru) { $rows }
    }
    if ($result.Status -eq 'FilesStagedRestartRequired' -or $result.Status -eq 'RolledBackRestartRequired') {
        exit 10
    }
    if ($result.Status -in @('NotApplicableStop', 'RuleFilesPresentStop')) { exit 20 }
    exit 0
} catch {
    $failure = $_
    $failureRows = $failure.Exception.Data['KB5130098ReportRows']
    $failureFiles = $failure.Exception.Data['KB5130098ReportFiles']
    if ($null -ne $failureRows) { $rows=@($failureRows) }
    if ($null -ne $failureFiles) { $files=$failureFiles }
    if ($remote) {
        $reportPath = $failure.Exception.Data['KB5130098FleetReport']
        if ($reportPath) { [Console]::Error.WriteLine("Remote rollout stopped. Report (including unvisited targets): $reportPath") }
    } elseif ($moduleLoaded) {
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
        $record = [pscustomobject]@{
            Target=$env:COMPUTERNAME; Mode=$Mode; UTC=$startedUtc; Status='FailedStop'
            RestartSearch=$RestartSearch.IsPresent; Detection=$before; Current=$after; Result=$result
            RecoveryAttestation=$null; Error=$failure.Exception.Message; ObservationError=$observationError
        }
        $runId = if ($null -ne $context) { $context.RunId } else { [guid]::NewGuid().ToString('N') }
        $detailPath = if ($null -ne $context -and -not $context.NoWrite) { $context.JsonPath } else { $null }
        $rows = @(ConvertTo-KBReportRows -Records @($record) -RunId $runId -DetailReportPath $detailPath)
        if ($null -ne $context -and -not $exportAttempted) {
            try {
                $files = Save-KBReportExports -Context $context -Records @($record) -Rows $rows -NoCsv:$NoCsv
            } catch {
                [Console]::Error.WriteLine("Report export also failed: $($_.Exception.Message)")
                $files = $_.Exception.Data['KB5130098ReportFiles']
            }
        }
        if (-not $AsJson) {
            Write-KBConsoleResult -Mode $Mode -Result $result -Before $before -After $after `
                -ErrorMessage $failure.Exception.Message -ObservationError $observationError -StabilitySeconds $StabilitySeconds
        }
    }
    Set-Variable -Name report -Scope Global -Value @($rows) -WhatIf:$false -Confirm:$false
    Set-Variable -Name reportFiles -Scope Global -Value $files -WhatIf:$false -Confirm:$false
    if (-not $AsJson -and $moduleLoaded) {
        Write-KBReportSummary -Rows @($rows) -Files $files
        if ($PassThru) { $rows }
    }
    [Console]::Error.WriteLine($failure.Exception.Message)
    exit 1
}
