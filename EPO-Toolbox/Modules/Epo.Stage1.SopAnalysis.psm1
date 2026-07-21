Set-StrictMode -Version 2.0

function New-EpoSopFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $CurrentSopAction,
        [Parameter(Mandatory)] [string] $GapOrRisk,
        [Parameter(Mandatory)] [string] $AutomationResponse,
        [ValidateSet('Pass','Warning','Blocked','NotApplicable')]
        [string] $Status = 'Warning',
        [ValidateSet('Info','Warning','High','Critical')]
        [string] $Severity = 'Warning',
        [string[]] $DynamicInputs = @(),
        [string[]] $RequiredNextData = @()
    )

    [pscustomobject] @{
        Phase = $Phase
        Area = $Area
        CurrentSopAction = $CurrentSopAction
        GapOrRisk = $GapOrRisk
        AutomationResponse = $AutomationResponse
        Status = $Status
        Severity = $Severity
        DynamicInputs = $DynamicInputs
        RequiredNextData = $RequiredNextData
    }
}

function Test-EpoConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $Path
    )

    $Current = $Config
    foreach ($Part in ($Path -split '\.')) {
        if ($null -eq $Current -or -not $Current.ContainsKey($Part)) {
            return $false
        }
        $Current = $Current[$Part]
    }

    if ($null -eq $Current) {
        return $false
    }

    if ($Current -is [string]) {
        return -not [string]::IsNullOrWhiteSpace($Current)
    }

    return $true
}

function Get-EpoStagePosition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $StageName
    )

    $StageOrder = @($Config.StageAwareness.StageOrder)
    $Index = [array]::IndexOf($StageOrder, $StageName)
    [pscustomobject] @{
        CurrentStage = $StageName
        StageIndex = $Index
        TotalStages = $StageOrder.Count
        PreviousStage = if ($Index -gt 0) { $StageOrder[$Index - 1] } else { $null }
        NextStage = if ($Index -ge 0 -and $Index -lt ($StageOrder.Count - 1)) { $StageOrder[$Index + 1] } else { $null }
        StageOrder = $StageOrder
    }
}

function Invoke-EpoSopAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [pscustomobject] $RunContext,
        [switch] $ValidationOnly
    )

    $Findings = New-Object System.Collections.Generic.List[object]
    $Stage = Get-EpoStagePosition -Config $Config -StageName 'SopAnalysis'

    $HasIsoPath = Test-EpoConfigValue -Config $Config -Path 'Package.CuIsoPath'
    $HasIsoHash = Test-EpoConfigValue -Config $Config -Path 'Package.ExpectedIsoHash'
    $HasSplunkName = Test-EpoConfigValue -Config $Config -Path 'Services.SplunkForwarderName'
    $HasCrowdStrikeNames = Test-EpoConfigValue -Config $Config -Path 'Services.CrowdStrikeServiceNames'
    $LoadBalancerMode = $Config.LoadBalancer.Mode

    $Findings.Add((New-EpoSopFinding `
        -Phase 'PackageStaging' `
        -Area 'Package staging and distribution' `
        -CurrentSopAction 'ISO sourced from regional file share; Xcopy distributes media to Exchange servers; ADS lock removal is referenced manually.' `
        -GapOrRisk 'Hash verification, extraction validation, and alternate data stream handling are not systematic.' `
        -AutomationResponse 'Stage package metadata in config, validate ISO hash, mount or extract locally, detect Zone.Identifier streams, and remove them with Unblock-File before setup.' `
        -Status $(if ($HasIsoPath -and $HasIsoHash) { 'Pass' } else { 'Warning' }) `
        -Severity $(if ($HasIsoPath -and $HasIsoHash) { 'Info' } else { 'High' }) `
        -DynamicInputs @('Package.CuIsoPath', 'Package.ExpectedIsoHash', 'Package.ExtractRoot') `
        -RequiredNextData @('Final CU ISO path', 'Expected file hash', 'Current Xcopy syntax used by patching team')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'CredentialAccess' `
        -Area 'Credential access' `
        -CurrentSopAction 'Org ID checkout and CA PAM login are external to the script.' `
        -GapOrRisk 'Credentials are operationally external and must not be persisted by automation.' `
        -AutomationResponse 'Accept PSCredential in memory or rely on a pre-authenticated PAM session; never write credentials to disk or logs.' `
        -Status 'Pass' `
        -Severity 'Info' `
        -DynamicInputs @('Runtime credential/session state') `
        -RequiredNextData @('Confirm whether PAM session or PSCredential will be used')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'SplunkHandling' `
        -Area 'Splunk forwarder state' `
        -CurrentSopAction 'SOP references sc config splunkForwarder START=Disabled.' `
        -GapOrRisk 'Changing startup type does not stop a running service and does not preserve original runtime state.' `
        -AutomationResponse 'Capture startup type and status, stop only when approved, restore exact prior state on success or rollback, and emit a ForwarderRestored event.' `
        -Status $(if ($HasSplunkName) { 'Pass' } else { 'Warning' }) `
        -Severity $(if ($HasSplunkName) { 'Info' } else { 'High' }) `
        -DynamicInputs @('Services.SplunkForwarderName', 'Service startup type', 'Service status') `
        -RequiredNextData @('Confirm exact Splunk service name in all regions')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'AvReadiness' `
        -Area 'AV and CrowdStrike readiness' `
        -CurrentSopAction 'CrowdStrike is current AV; behavior during CU setup is unverified; prior AV interference caused failures.' `
        -GapOrRisk 'Exchange file, folder, process, and extension exclusions may be incomplete; disabling AV without approval increases security exposure.' `
        -AutomationResponse 'Validate Microsoft-recommended Exchange exclusions, capture CrowdStrike service/log state, and require an explicit customer-approved override before any disable action.' `
        -Status $(if ($HasCrowdStrikeNames) { 'Warning' } else { 'Blocked' }) `
        -Severity $(if ($HasCrowdStrikeNames) { 'High' } else { 'Critical' }) `
        -DynamicInputs @('Services.CrowdStrikeServiceNames', 'Exchange install path', 'AV exclusion inventory') `
        -RequiredNextData @('CrowdStrike exclusion validation method', 'Customer position on temporary AV disable during test install')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'MaintenanceMode' `
        -Area 'DAG maintenance procedure' `
        -CurrentSopAction 'SOP uses StartDagServerMaintenance.ps1 and StopDagServerMaintenance.ps1; maintenance applies to mailbox-hosting servers.' `
        -GapOrRisk 'Transport draining, queue redirection, ServerWideOffline, activation policy, cluster pause, and queue-empty verification are not all formalized as gates.' `
        -AutomationResponse 'Implement the full Microsoft DAG maintenance workflow with verification gates before install begins.' `
        -Status 'Warning' `
        -Severity 'High' `
        -DynamicInputs @('DAG membership', 'Mailbox role presence', 'Queue state', 'Cluster node state') `
        -RequiredNextData @('Confirm mailbox-only vs mixed-role handling', 'Confirm transport redirect target selection rules')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'InstallExecution' `
        -Area 'CU setup execution and observability' `
        -CurrentSopAction 'SOP runs Setup.exe /IAcceptExchangeServerLicenseTerms_DiagnosticDataON /Mode:Upgrade /DoNotEnableEP.' `
        -GapOrRisk 'No live setup log tailing, stdout/stderr capture, no-log-growth detection, or automated failure diagnosis is documented.' `
        -AutomationResponse 'Use an absolute Setup.exe path, capture stdout and stderr, tail C:\ExchangeSetupLogs\ExchangeSetup.log, detect no-log-growth, and run SetupLogReviewer.ps1 on failure.' `
        -Status 'Warning' `
        -Severity 'Critical' `
        -DynamicInputs @('Absolute Setup.exe path', 'License switch', 'DoNotEnableEP setting', 'Setup log growth') `
        -RequiredNextData @('No-log-growth threshold', 'Approved timeout/diagnostic behavior')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'PostInstallValidation' `
        -Area 'Post-install validation gates' `
        -CurrentSopAction 'SOP validates services, queue, DB status, and build number; separate engineer health checks are run manually.' `
        -GapOrRisk 'Post checks are not formal pass/fail gates with structured evidence and consolidated reporting.' `
        -AutomationResponse 'Convert each validation into structured JSON/CSV evidence and block progression when required gates fail.' `
        -Status 'Warning' `
        -Severity 'High' `
        -DynamicInputs @('ExpectedBuild', 'Service health', 'Replication health', 'Mail flow', 'Queue state') `
        -RequiredNextData @('Expected build for target CU', 'Queue length thresholds', 'HealthChecker path')))

    $Findings.Add((New-EpoSopFinding `
        -Phase 'LoadBalancer' `
        -Area 'Load balancer integration' `
        -CurrentSopAction 'Current SOP has no explicit load balancer changes; meeting notes flag LB handling as open.' `
        -GapOrRisk 'A server may remain in rotation during maintenance unless external LB handling is confirmed.' `
        -AutomationResponse 'Provide a configurable LB adapter mode: None, Manual, or Script, and record pre/post LB membership evidence when enabled.' `
        -Status $(if ($LoadBalancerMode -eq 'None') { 'Warning' } else { 'Pass' }) `
        -Severity $(if ($LoadBalancerMode -eq 'None') { 'High' } else { 'Info' }) `
        -DynamicInputs @('LoadBalancer.Mode', 'LoadBalancer.AdapterScriptPath') `
        -RequiredNextData @('Confirm if LB changes are required', 'If yes, provide script/API method or manual checkpoint owner')))

    $BlockingFindings = @($Findings | Where-Object { $_.Status -eq 'Blocked' })
    $CriticalFindings = @($Findings | Where-Object { $_.Severity -eq 'Critical' })
    $WarningFindings = @($Findings | Where-Object { $_.Status -eq 'Warning' })

    $Status = 'Pass'
    $Severity = 'Info'
    if ($BlockingFindings.Count -gt 0 -and $Config.SopAnalysis.RiskThresholds.BlockOnCritical) {
        $Status = 'Blocked'
        $Severity = 'Critical'
    }
    elseif ($CriticalFindings.Count -gt 0) {
        $Status = 'Warning'
        $Severity = 'Critical'
    }
    elseif ($WarningFindings.Count -gt 0) {
        $Status = 'Warning'
        $Severity = 'High'
    }

    $FindingArray = @($Findings.ToArray())
    $StageAwareness = [ordered] @{
        CurrentStage = $Stage.CurrentStage
        StageIndex = $Stage.StageIndex
        TotalStages = $Stage.TotalStages
        PreviousStage = $Stage.PreviousStage
        NextStage = $Stage.NextStage
        StageOrder = @($Stage.StageOrder)
    }

    [pscustomobject] @{
        CorrelationId = $RunContext.CorrelationId
        StageAwareness = $StageAwareness
        ValidationOnly = [bool] $ValidationOnly
        Status = $Status
        Severity = $Severity
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        Findings = $FindingArray
        RequiredInputsForNextStage = @($FindingArray | ForEach-Object { $_.RequiredNextData } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        NextStage = $Stage.NextStage
    }
}

Export-ModuleMember -Function Invoke-EpoSopAnalysis, New-EpoSopFinding
