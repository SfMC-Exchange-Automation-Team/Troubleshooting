Set-StrictMode -Version 2.0

function Initialize-EpoRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CorrelationId,
        [Parameter(Mandatory)] [string] $RunRoot,
        [Parameter(Mandatory)] [string] $StageName,
        [Parameter(Mandatory)] [hashtable] $Config
    )

    $RunPath = Join-Path $RunRoot $CorrelationId
    $EvidencePath = Join-Path $RunPath 'Evidence'
    if (-not (Test-Path -LiteralPath $EvidencePath)) {
        New-Item -ItemType Directory -Path $EvidencePath -Force | Out-Null
    }

    $RunContext = [pscustomobject] @{
        CorrelationId = $CorrelationId
        RunId = $CorrelationId
        StageName = $StageName
        RunRoot = $RunRoot
        RunPath = $RunPath
        EvidencePath = $EvidencePath
        EventsPath = Join-Path $RunPath 'Events.jsonl'
        SummaryPath = Join-Path $RunPath 'Summary.csv'
        StartedUtc = [datetime]::UtcNow
    }

    $RunMetadata = [ordered] @{
        CorrelationId = $RunContext.CorrelationId
        RunId = $RunContext.RunId
        StageName = $RunContext.StageName
        CustomerName = $Config.CustomerName
        Environment = $Config.Environment
        StartedUtc = $RunContext.StartedUtc.ToString('o')
    }

    $RunMetadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RunPath 'Run.json') -Encoding UTF8
    return $RunContext
}

function Write-EpoEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $RunContext,
        [string] $DagName = '',
        [string] $Server = '',
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [string] $Step,
        [Parameter(Mandatory)] [string] $Status,
        [ValidateSet('Debug','Info','Warning','Error','Critical')]
        [string] $Severity = 'Info',
        [string] $Command = '',
        [bool] $Changed = $false,
        [string] $EvidencePath = '',
        [string] $Message = '',
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $Event = [ordered] @{
        CorrelationId = $RunContext.CorrelationId
        RunId = $RunContext.RunId
        DagName = $DagName
        Server = $Server
        Phase = $Phase
        Step = $Step
        Command = $Command
        StartTimeUtc = [datetime]::UtcNow.ToString('o')
        EndTimeUtc = [datetime]::UtcNow.ToString('o')
        DurationMs = 0
        Status = $Status
        Severity = $Severity
        ExitCode = $null
        RetryCount = 0
        Changed = $Changed
        RollbackAction = ''
        EvidencePath = $EvidencePath
        Message = $Message
        ErrorRecord = $null
    }

    if ($PSBoundParameters.ContainsKey('ErrorRecord') -and $null -ne $ErrorRecord) {
        $Event.ErrorRecord = [ordered] @{
            Exception = $ErrorRecord.Exception.Message
            Category = $ErrorRecord.CategoryInfo.ToString()
            FullyQualifiedErrorId = $ErrorRecord.FullyQualifiedErrorId
        }
    }

    $Event | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $RunContext.EventsPath -Encoding UTF8
}

function Export-EpoEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $RunContext,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $InputObject
    )

    $SafeName = $Name -replace '[^a-zA-Z0-9\.\-_]', '_'
    $Path = Join-Path $RunContext.EvidencePath "$SafeName.json"
    $InputObject | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Export-EpoSummaryCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $RunContext,
        [Parameter(Mandatory)] [object[]] $Findings
    )

    $Rows = foreach ($Finding in $Findings) {
        [pscustomobject] @{
            CorrelationId = $RunContext.CorrelationId
            Stage = $RunContext.StageName
            Phase = $Finding.Phase
            Area = $Finding.Area
            CurrentSopAction = $Finding.CurrentSopAction
            GapOrRisk = $Finding.GapOrRisk
            AutomationResponse = $Finding.AutomationResponse
            Status = $Finding.Status
            Severity = $Finding.Severity
            DynamicInputs = ($Finding.DynamicInputs -join '; ')
        }
    }

    $Rows | Export-Csv -LiteralPath $RunContext.SummaryPath -NoTypeInformation -Encoding UTF8
    return $RunContext.SummaryPath
}

Export-ModuleMember -Function Initialize-EpoRun, Write-EpoEvent, Export-EpoEvidence, Export-EpoSummaryCsv
