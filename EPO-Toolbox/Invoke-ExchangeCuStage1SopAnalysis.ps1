<#
.SYNOPSIS
Runs Stage 1 of the Exchange CU DAG patching toolbox: current SOP analysis.

.DESCRIPTION
Compares the documented SOP process against automation requirements and emits
dynamic pass/warn/block findings. This stage is intentionally safe: it performs
no server changes and can run before Exchange cmdlets or patch media are present.
Windows PowerShell 5.1 is the default runtime target because on-prem Exchange
Management Shell cmdlets are Windows PowerShell based. Avoid PS7-only syntax
unless a later non-Exchange helper explicitly opts into PowerShell 7.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $OutputRoot,
    [string] $CorrelationId = ([guid]::NewGuid().Guid),
    [switch] $ValidationOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'Config\ExchangeCuPatch.config.psd1'
}

Import-Module (Join-Path $PSScriptRoot 'Modules\Epo.Logging.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Modules\Epo.Stage1.SopAnalysis.psm1') -Force

$Config = Import-PowerShellDataFile -Path $ConfigPath

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $env:TEMP 'ExchangeCuDagPatch'
}

$RunContext = Initialize-EpoRun `
    -CorrelationId $CorrelationId `
    -RunRoot $OutputRoot `
    -StageName 'SopAnalysis' `
    -Config $Config

Write-EpoEvent -RunContext $RunContext -Phase 'SopAnalysis' -Step 'Start' -Status 'Started' -Severity 'Info' -Message 'Starting current SOP analysis.'

$Result = Invoke-EpoSopAnalysis `
    -Config $Config `
    -RunContext $RunContext `
    -ValidationOnly:$ValidationOnly

$EvidenceFile = Export-EpoEvidence -RunContext $RunContext -Name 'Stage1.SopAnalysis' -InputObject $Result
$SummaryFile = Export-EpoSummaryCsv -RunContext $RunContext -Findings $Result.Findings

Write-EpoEvent `
    -RunContext $RunContext `
    -Phase 'SopAnalysis' `
    -Step 'Complete' `
    -Status $Result.Status `
    -Severity $Result.Severity `
    -Message ("SOP analysis completed with {0} finding(s)." -f $Result.Findings.Count)

$Result | Add-Member -NotePropertyName RunPath -NotePropertyValue $RunContext.RunPath -Force
$Result | Add-Member -NotePropertyName EvidenceFile -NotePropertyValue $EvidenceFile -Force
$Result | Add-Member -NotePropertyName SummaryFile -NotePropertyValue $SummaryFile -Force
$Result
