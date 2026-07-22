Set-StrictMode -Version 2.0

function Test-EpoGuiPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [string] $OutputRoot
    )

    $Results = New-Object System.Collections.Generic.List[object]

    function Add-Result {
        param(
            [string] $Name,
            [ValidateSet('Pass','Warning','Blocked')] [string] $Status,
            [string] $Detail,
            [string] $PowerShellValue
        )
        $Results.Add([pscustomobject] @{
            Name = $Name
            Status = $Status
            Detail = $Detail
            PowerShellValue = $PowerShellValue
        })
    }

    if ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1) {
        Add-Result -Name 'PowerShell runtime' -Status 'Pass' -Detail "Windows PowerShell $($PSVersionTable.PSVersion) is available." -PowerShellValue '$PSVersionTable.PSVersion'
    }
    else {
        Add-Result -Name 'PowerShell runtime' -Status 'Warning' -Detail "Current runtime is PowerShell $($PSVersionTable.PSVersion). Exchange on-premises stages should run under Windows PowerShell 5.1." -PowerShellValue '$PSVersionTable.PSVersion'
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        Add-Result -Name 'Windows Forms GUI' -Status 'Pass' -Detail 'System.Windows.Forms and System.Drawing loaded successfully.' -PowerShellValue 'Add-Type -AssemblyName System.Windows.Forms,System.Drawing'
    }
    catch {
        Add-Result -Name 'Windows Forms GUI' -Status 'Blocked' -Detail "Windows Forms could not load: $($_.Exception.Message)" -PowerShellValue 'Add-Type -AssemblyName System.Windows.Forms'
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $Config = Import-PowerShellDataFile -Path $ConfigPath
            Add-Result -Name 'Configuration file' -Status 'Pass' -Detail "Configuration loaded from $ConfigPath." -PowerShellValue "-ConfigPath '$ConfigPath'"

            $CurrentStage = ''
            if ($Config.ContainsKey('StageAwareness')) {
                $CurrentStage = [string] $Config.StageAwareness.CurrentStage
            }
            if ($CurrentStage -eq 'SopAnalysis') {
                Add-Result -Name 'Implemented stage' -Status 'Pass' -Detail "Configured current stage '$CurrentStage' is implemented." -PowerShellValue "-Stage '$CurrentStage'"
            }
            else {
                Add-Result -Name 'Implemented stage' -Status 'Warning' -Detail "Configured current stage '$CurrentStage' is reserved but not implemented yet. The GUI can still generate unattended values." -PowerShellValue "-Stage '$CurrentStage'"
            }
        }
        catch {
            Add-Result -Name 'Configuration file' -Status 'Blocked' -Detail "Configuration could not be imported: $($_.Exception.Message)" -PowerShellValue "-ConfigPath '$ConfigPath'"
        }
    }
    else {
        Add-Result -Name 'Configuration file' -Status 'Blocked' -Detail "Configuration file was not found at $ConfigPath." -PowerShellValue "-ConfigPath '$ConfigPath'"
    }

    $RequiredFiles = @(
        'EPO-Toolbox.ps1',
        'Invoke-ExchangeCuStage1SopAnalysis.ps1',
        'Invoke-EpoPreflightCheck.ps1',
        'Scripts\Get-PendingReboot.ps1',
        'Modules\Epo.Logging.psm1',
        'Modules\Epo.Stage1.SopAnalysis.psm1',
        'Modules\Epo.Preflight.psm1'
    )
    $MissingFiles = @($RequiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ToolboxRoot $_)) })
    if ($MissingFiles.Count -eq 0) {
        Add-Result -Name 'Toolbox files' -Status 'Pass' -Detail 'Required toolbox scripts and modules are present.' -PowerShellValue '$PSScriptRoot'
    }
    else {
        Add-Result -Name 'Toolbox files' -Status 'Blocked' -Detail "Missing required file(s): $($MissingFiles -join ', ')" -PowerShellValue '$PSScriptRoot'
    }

    $ResolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) { Join-Path $env:TEMP 'ExchangeCuDagPatch' } else { $OutputRoot }
    try {
        if (-not (Test-Path -LiteralPath $ResolvedOutputRoot)) {
            New-Item -ItemType Directory -Path $ResolvedOutputRoot -Force | Out-Null
        }
        $Probe = Join-Path $ResolvedOutputRoot ("epo-gui-probe-{0}.tmp" -f ([guid]::NewGuid().Guid))
        Set-Content -LiteralPath $Probe -Value 'probe' -Encoding ASCII
        Remove-Item -LiteralPath $Probe -Force
        Add-Result -Name 'Output root' -Status 'Pass' -Detail "Output root is writable: $ResolvedOutputRoot" -PowerShellValue "-OutputRoot '$ResolvedOutputRoot'"
    }
    catch {
        Add-Result -Name 'Output root' -Status 'Blocked' -Detail "Output root is not writable: $($_.Exception.Message)" -PowerShellValue "-OutputRoot '$ResolvedOutputRoot'"
    }

    return @($Results.ToArray())
}

function New-EpoGuiRuntimeModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [string] $OutputRoot,
        [string[]] $TargetServers,
        [string] $CorrelationId,
        [string] $Stage,
        [switch] $ValidationOnly
    )

    $Config = @{}
    if (Test-Path -LiteralPath $ConfigPath) {
        $Config = Import-PowerShellDataFile -Path $ConfigPath
    }

    $StageOrder = @('SopAnalysis','UpdateInventory','DagDiscovery','PreCheck','Maintenance','PackagePrep','Install','PostCheck','Rollback','Report')
    if ($Config.ContainsKey('StageAwareness') -and $Config.StageAwareness.StageOrder) {
        $StageOrder = @($Config.StageAwareness.StageOrder)
    }

    $ResolvedStage = $Stage
    if ([string]::IsNullOrWhiteSpace($ResolvedStage) -or $ResolvedStage -eq 'Auto') {
        $ResolvedStage = if ($Config.ContainsKey('StageAwareness')) { [string] $Config.StageAwareness.CurrentStage } else { 'SopAnalysis' }
    }

    [pscustomobject] @{
        ToolboxRoot = $ToolboxRoot
        ConfigPath = $ConfigPath
        OutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) { Join-Path $env:TEMP 'ExchangeCuDagPatch' } else { $OutputRoot }
        CorrelationId = if ([string]::IsNullOrWhiteSpace($CorrelationId)) { [guid]::NewGuid().Guid } else { $CorrelationId }
        Stage = $ResolvedStage
        StageOrder = $StageOrder
        ValidationOnly = [bool] $ValidationOnly
        TargetServers = if ($TargetServers -and $TargetServers.Count) { ($TargetServers -join ',') } elseif ($Config.ContainsKey('Preflight') -and $Config.Preflight.TargetServers) { (@($Config.Preflight.TargetServers) -join ',') } elseif ($Config.ContainsKey('Inventory')) { (@($Config.Inventory.TargetServers) -join ',') } else { '' }
        CustomerName = if ($Config.ContainsKey('CustomerName')) { [string] $Config.CustomerName } else { '' }
        Environment = if ($Config.ContainsKey('Environment')) { [string] $Config.Environment } else { '' }
        CuIsoPath = if ($Config.ContainsKey('Package')) { [string] $Config.Package.CuIsoPath } else { '' }
        ExpectedIsoHash = if ($Config.ContainsKey('Package')) { [string] $Config.Package.ExpectedIsoHash } else { '' }
        ExtractRoot = if ($Config.ContainsKey('Package')) { [string] $Config.Package.ExtractRoot } else { 'D:\ExchangeCU\Media' }
        SplunkForwarderName = if ($Config.ContainsKey('Services')) { [string] $Config.Services.SplunkForwarderName } else { 'splunkForwarder' }
        CrowdStrikeServiceNames = if ($Config.ContainsKey('Services')) { (@($Config.Services.CrowdStrikeServiceNames) -join ',') } else { 'CSFalconService' }
        LoadBalancerMode = if ($Config.ContainsKey('LoadBalancer')) { [string] $Config.LoadBalancer.Mode } else { 'None' }
        LoadBalancerAdapterScriptPath = if ($Config.ContainsKey('LoadBalancer')) { [string] $Config.LoadBalancer.AdapterScriptPath } else { '' }
    }
}

function ConvertTo-EpoSingleQuotedString {
    param([string] $Value)
    return "'$($Value -replace '''', '''''')'"
}

function ConvertTo-EpoUnattendedCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Model)

    $ToolboxPath = Join-Path $Model.ToolboxRoot 'EPO-Toolbox.ps1'
    $Parts = New-Object System.Collections.Generic.List[string]
    $Parts.Add("& $(ConvertTo-EpoSingleQuotedString -Value $ToolboxPath)")
    $Parts.Add("-Stage $(ConvertTo-EpoSingleQuotedString -Value $Model.Stage)")
    $Parts.Add("-ConfigPath $(ConvertTo-EpoSingleQuotedString -Value $Model.ConfigPath)")
    $Parts.Add("-OutputRoot $(ConvertTo-EpoSingleQuotedString -Value $Model.OutputRoot)")
    $Parts.Add("-CorrelationId $(ConvertTo-EpoSingleQuotedString -Value $Model.CorrelationId)")
    if (-not [string]::IsNullOrWhiteSpace($Model.TargetServers)) {
        $Parts.Add("-TargetServers $(ConvertTo-EpoSingleQuotedString -Value $Model.TargetServers)")
    }
    if ($Model.ValidationOnly) {
        $Parts.Add('-ValidationOnly')
    }
    return ($Parts -join ' ')
}

function Export-EpoGuiConfigDataFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Model)

    $RunConfigRoot = Join-Path $Model.OutputRoot 'GuiConfig'
    if (-not (Test-Path -LiteralPath $RunConfigRoot)) {
        New-Item -ItemType Directory -Path $RunConfigRoot -Force | Out-Null
    }
    $Path = Join-Path $RunConfigRoot ("ExchangeCuPatch.gui.{0}.psd1" -f $Model.CorrelationId)
    $CrowdStrikeServices = @($Model.CrowdStrikeServiceNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $CrowdStrikeText = if ($CrowdStrikeServices.Count) {
        "@($((@($CrowdStrikeServices | ForEach-Object { ConvertTo-EpoSingleQuotedString -Value $_ })) -join ', '))"
    }
    else {
        '@()'
    }

    $Content = @"
@{
    CustomerName = $(ConvertTo-EpoSingleQuotedString -Value $Model.CustomerName)
    Environment  = $(ConvertTo-EpoSingleQuotedString -Value $Model.Environment)
    RunRoot = $(ConvertTo-EpoSingleQuotedString -Value $Model.OutputRoot)
    StageAwareness = @{
        CurrentStage = $(ConvertTo-EpoSingleQuotedString -Value $Model.Stage)
        StageOrder = @($(($Model.StageOrder | ForEach-Object { ConvertTo-EpoSingleQuotedString -Value $_ }) -join ', '))
    }
    SopAnalysis = @{
        SopName = 'Exchange Server 2019 CU DAG Patching SOP'
        SopVersion = 'Current'
        Sources = @()
        RiskThresholds = @{
            BlockOnCritical = `$true
            WarnOnHigh = `$true
        }
    }
    Package = @{
        CuIsoPath = $(ConvertTo-EpoSingleQuotedString -Value $Model.CuIsoPath)
        ExpectedIsoHash = $(ConvertTo-EpoSingleQuotedString -Value $Model.ExpectedIsoHash)
        ExtractRoot = $(ConvertTo-EpoSingleQuotedString -Value $Model.ExtractRoot)
    }
    Services = @{
        SplunkForwarderName = $(ConvertTo-EpoSingleQuotedString -Value $Model.SplunkForwarderName)
        CrowdStrikeServiceNames = $CrowdStrikeText
    }
    LoadBalancer = @{
        Mode = $(ConvertTo-EpoSingleQuotedString -Value $Model.LoadBalancerMode)
        AdapterScriptPath = $(ConvertTo-EpoSingleQuotedString -Value $Model.LoadBalancerAdapterScriptPath)
    }
    Inventory = @{
        TargetServers = @($(($Model.TargetServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { ConvertTo-EpoSingleQuotedString -Value $_ }) -join ', '))
        IncludeHotFixInventory = `$true
        IncludeSetupLogEvidence = `$true
    }
    Preflight = @{
        TargetServers = @($(($Model.TargetServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { ConvertTo-EpoSingleQuotedString -Value $_ }) -join ', '))
        PendingRebootScriptPath = '.\Scripts\Get-PendingReboot.ps1'
        EnablePendingRebootFallback = `$true
        IncludeSccmRebootState = `$false
        BlockOnPendingReboot = `$true
        BlockOnUnknownRebootState = `$true
    }
}
"@
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    $Model.ConfigPath = $Path
    return $Path
}

function New-EpoLabel {
    param([string] $Text, [int] $X, [int] $Y, [int] $Width = 120)
    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = $Text
    $Label.Location = New-Object System.Drawing.Point($X, $Y)
    $Label.Size = New-Object System.Drawing.Size($Width, 20)
    return $Label
}

function New-EpoTextBox {
    param([string] $Text, [int] $X, [int] $Y, [int] $Width = 360)
    $TextBox = New-Object System.Windows.Forms.TextBox
    $TextBox.Text = $Text
    $TextBox.Location = New-Object System.Drawing.Point($X, $Y)
    $TextBox.Size = New-Object System.Drawing.Size($Width, 22)
    return $TextBox
}

function Show-EpoToolboxWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [pscustomobject] $Model)

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = 'EPO Toolbox Wizard'
    $Form.Size = New-Object System.Drawing.Size(760, 560)
    $Form.StartPosition = 'CenterScreen'

    $Tabs = New-Object System.Windows.Forms.TabControl
    $Tabs.Location = New-Object System.Drawing.Point(12, 12)
    $Tabs.Size = New-Object System.Drawing.Size(720, 430)

    $RuntimeTab = New-Object System.Windows.Forms.TabPage
    $RuntimeTab.Text = '1. Runtime'
    $StageTab = New-Object System.Windows.Forms.TabPage
    $StageTab.Text = '2. Stage values'
    $ReviewTab = New-Object System.Windows.Forms.TabPage
    $ReviewTab.Text = '3. Review'
    $Tabs.TabPages.AddRange(@($RuntimeTab, $StageTab, $ReviewTab))

    $StageDropDown = New-Object System.Windows.Forms.ComboBox
    $StageDropDown.DropDownStyle = 'DropDownList'
    $StageDropDown.Location = New-Object System.Drawing.Point(150, 28)
    $StageDropDown.Size = New-Object System.Drawing.Size(220, 24)
    [void] $StageDropDown.Items.AddRange([object[]] $Model.StageOrder)
    $StageDropDown.SelectedItem = $Model.Stage

    $ValidationCheckBox = New-Object System.Windows.Forms.CheckBox
    $ValidationCheckBox.Text = 'Validation only'
    $ValidationCheckBox.Location = New-Object System.Drawing.Point(150, 62)
    $ValidationCheckBox.Size = New-Object System.Drawing.Size(180, 24)
    $ValidationCheckBox.Checked = $Model.ValidationOnly

    $OutputRootText = New-EpoTextBox -Text $Model.OutputRoot -X 150 -Y 96 -Width 500
    $CorrelationText = New-EpoTextBox -Text $Model.CorrelationId -X 150 -Y 130 -Width 300
    $CustomerText = New-EpoTextBox -Text $Model.CustomerName -X 150 -Y 164 -Width 220
    $EnvironmentText = New-EpoTextBox -Text $Model.Environment -X 150 -Y 198 -Width 220
    $TargetServersText = New-EpoTextBox -Text $Model.TargetServers -X 150 -Y 232 -Width 500

    $RuntimeTab.Controls.AddRange(@(
        (New-EpoLabel -Text 'Stage' -X 24 -Y 30),
        $StageDropDown,
        $ValidationCheckBox,
        (New-EpoLabel -Text 'Output root' -X 24 -Y 98),
        $OutputRootText,
        (New-EpoLabel -Text 'Correlation ID' -X 24 -Y 132),
        $CorrelationText,
        (New-EpoLabel -Text 'Customer name' -X 24 -Y 166),
        $CustomerText,
        (New-EpoLabel -Text 'Environment' -X 24 -Y 200),
        $EnvironmentText,
        (New-EpoLabel -Text 'Target servers' -X 24 -Y 234),
        $TargetServersText
    ))

    $CuIsoText = New-EpoTextBox -Text $Model.CuIsoPath -X 180 -Y 28 -Width 480
    $HashText = New-EpoTextBox -Text $Model.ExpectedIsoHash -X 180 -Y 62 -Width 480
    $ExtractRootText = New-EpoTextBox -Text $Model.ExtractRoot -X 180 -Y 96 -Width 320
    $SplunkText = New-EpoTextBox -Text $Model.SplunkForwarderName -X 180 -Y 150 -Width 220
    $CrowdStrikeText = New-EpoTextBox -Text $Model.CrowdStrikeServiceNames -X 180 -Y 184 -Width 320

    $LbModeDropDown = New-Object System.Windows.Forms.ComboBox
    $LbModeDropDown.DropDownStyle = 'DropDownList'
    $LbModeDropDown.Location = New-Object System.Drawing.Point(180, 238)
    $LbModeDropDown.Size = New-Object System.Drawing.Size(140, 24)
    [void] $LbModeDropDown.Items.AddRange([object[]] @('None','Manual','Script'))
    $LbModeDropDown.SelectedItem = $Model.LoadBalancerMode
    $LbAdapterText = New-EpoTextBox -Text $Model.LoadBalancerAdapterScriptPath -X 180 -Y 272 -Width 480

    $StageTab.Controls.AddRange(@(
        (New-EpoLabel -Text 'CU ISO path' -X 24 -Y 30 -Width 140),
        $CuIsoText,
        (New-EpoLabel -Text 'Expected ISO hash' -X 24 -Y 64 -Width 140),
        $HashText,
        (New-EpoLabel -Text 'Extract root' -X 24 -Y 98 -Width 140),
        $ExtractRootText,
        (New-EpoLabel -Text 'Splunk service' -X 24 -Y 152 -Width 140),
        $SplunkText,
        (New-EpoLabel -Text 'CrowdStrike services' -X 24 -Y 186 -Width 140),
        $CrowdStrikeText,
        (New-EpoLabel -Text 'Load balancer mode' -X 24 -Y 240 -Width 140),
        $LbModeDropDown,
        (New-EpoLabel -Text 'LB adapter script' -X 24 -Y 274 -Width 140),
        $LbAdapterText
    ))

    $CommandBox = New-Object System.Windows.Forms.TextBox
    $CommandBox.Location = New-Object System.Drawing.Point(20, 24)
    $CommandBox.Size = New-Object System.Drawing.Size(660, 120)
    $CommandBox.Multiline = $true
    $CommandBox.ScrollBars = 'Vertical'
    $CommandBox.ReadOnly = $true

    $ReviewNote = New-Object System.Windows.Forms.Label
    $ReviewNote.Location = New-Object System.Drawing.Point(20, 160)
    $ReviewNote.Size = New-Object System.Drawing.Size(660, 80)
    $ReviewNote.Text = 'All wizard inputs map to PowerShell values. Running from the wizard writes a temporary GUI config file, then launches the same unattended command shown above.'

    $CopyButton = New-Object System.Windows.Forms.Button
    $CopyButton.Text = 'Copy unattended command'
    $CopyButton.Location = New-Object System.Drawing.Point(20, 260)
    $CopyButton.Size = New-Object System.Drawing.Size(190, 30)

    $ReviewTab.Controls.AddRange(@($CommandBox, $ReviewNote, $CopyButton))

    function Sync-ModelFromControls {
        $Model.Stage = [string] $StageDropDown.SelectedItem
        $Model.ValidationOnly = [bool] $ValidationCheckBox.Checked
        $Model.OutputRoot = $OutputRootText.Text
        $Model.CorrelationId = $CorrelationText.Text
        $Model.CustomerName = $CustomerText.Text
        $Model.Environment = $EnvironmentText.Text
        $Model.TargetServers = $TargetServersText.Text
        $Model.CuIsoPath = $CuIsoText.Text
        $Model.ExpectedIsoHash = $HashText.Text
        $Model.ExtractRoot = $ExtractRootText.Text
        $Model.SplunkForwarderName = $SplunkText.Text
        $Model.CrowdStrikeServiceNames = $CrowdStrikeText.Text
        $Model.LoadBalancerMode = [string] $LbModeDropDown.SelectedItem
        $Model.LoadBalancerAdapterScriptPath = $LbAdapterText.Text
        $CommandBox.Text = ConvertTo-EpoUnattendedCommand -Model $Model
    }

    $InputControls = @($StageDropDown, $ValidationCheckBox, $OutputRootText, $CorrelationText, $CustomerText, $EnvironmentText, $TargetServersText, $CuIsoText, $HashText, $ExtractRootText, $SplunkText, $CrowdStrikeText, $LbModeDropDown, $LbAdapterText)
    foreach ($Control in $InputControls) {
        $Control.Add_TextChanged({ Sync-ModelFromControls })
        if ($Control -is [System.Windows.Forms.ComboBox]) {
            $Control.Add_SelectedIndexChanged({ Sync-ModelFromControls })
        }
        if ($Control -is [System.Windows.Forms.CheckBox]) {
            $Control.Add_CheckedChanged({ Sync-ModelFromControls })
        }
    }

    $BackButton = New-Object System.Windows.Forms.Button
    $BackButton.Text = 'Back'
    $BackButton.Location = New-Object System.Drawing.Point(390, 458)
    $BackButton.Size = New-Object System.Drawing.Size(80, 30)
    $BackButton.Add_Click({
        if ($Tabs.SelectedIndex -gt 0) { $Tabs.SelectedIndex-- }
    })

    $NextButton = New-Object System.Windows.Forms.Button
    $NextButton.Text = 'Next'
    $NextButton.Location = New-Object System.Drawing.Point(480, 458)
    $NextButton.Size = New-Object System.Drawing.Size(80, 30)
    $NextButton.Add_Click({
        if ($Tabs.SelectedIndex -lt ($Tabs.TabPages.Count - 1)) { $Tabs.SelectedIndex++ }
        Sync-ModelFromControls
    })

    $RunButton = New-Object System.Windows.Forms.Button
    $RunButton.Text = 'Run'
    $RunButton.Location = New-Object System.Drawing.Point(570, 458)
    $RunButton.Size = New-Object System.Drawing.Size(75, 30)
    $RunButton.Add_Click({
        try {
            Sync-ModelFromControls
            $ConfigCopy = Export-EpoGuiConfigDataFile -Model $Model
            $CommandBox.Text = ConvertTo-EpoUnattendedCommand -Model $Model
            $ToolboxPath = Join-Path $Model.ToolboxRoot 'EPO-Toolbox.ps1'
            $Targets = @($Model.TargetServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            & $ToolboxPath -Stage $Model.Stage -ConfigPath $ConfigCopy -OutputRoot $Model.OutputRoot -TargetServers $Targets -CorrelationId $Model.CorrelationId -ValidationOnly:([bool] $Model.ValidationOnly)
            [System.Windows.Forms.MessageBox]::Show('Toolbox run completed. Review the output root for run evidence.', 'EPO Toolbox', 'OK', 'Information') | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'EPO Toolbox run failed', 'OK', 'Error') | Out-Null
        }
    })

    $CloseButton = New-Object System.Windows.Forms.Button
    $CloseButton.Text = 'Close'
    $CloseButton.Location = New-Object System.Drawing.Point(655, 458)
    $CloseButton.Size = New-Object System.Drawing.Size(75, 30)
    $CloseButton.Add_Click({ $Form.Close() })

    $CopyButton.Add_Click({
        Sync-ModelFromControls
        [System.Windows.Forms.Clipboard]::SetText($CommandBox.Text)
    })

    $Form.Controls.AddRange(@($Tabs, $BackButton, $NextButton, $RunButton, $CloseButton))
    Sync-ModelFromControls
    [void] $Form.ShowDialog()
}

function Show-EpoToolboxDashboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [string] $OutputRoot,
        [string[]] $TargetServers,
        [string] $CorrelationId,
        [string] $Stage,
        [switch] $ValidationOnly
    )

    $Prerequisites = Test-EpoGuiPrerequisites -ToolboxRoot $ToolboxRoot -ConfigPath $ConfigPath -OutputRoot $OutputRoot
    $Blocked = @($Prerequisites | Where-Object { $_.Status -eq 'Blocked' })

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = 'EPO Toolbox'
    $Form.Size = New-Object System.Drawing.Size(860, 720)
    $Form.StartPosition = 'CenterScreen'

    $Title = New-Object System.Windows.Forms.Label
    $Title.Text = 'EPO Toolbox Dashboard'
    $Title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $Title.Location = New-Object System.Drawing.Point(18, 16)
    $Title.Size = New-Object System.Drawing.Size(420, 30)

    $Status = New-Object System.Windows.Forms.Label
    $Status.Location = New-Object System.Drawing.Point(20, 52)
    $Status.Size = New-Object System.Drawing.Size(700, 36)
    if ($Blocked.Count) {
        $Status.Text = "Dashboard prerequisites found $($Blocked.Count) blocker(s). Resolve blocked items before opening the wizard."
        $Status.ForeColor = [System.Drawing.Color]::DarkRed
    }
    else {
        $Status.Text = 'Dashboard prerequisites are sufficient to open the wizard. Later patching stages may add more gates.'
        $Status.ForeColor = [System.Drawing.Color]::DarkGreen
    }

    $List = New-Object System.Windows.Forms.ListView
    $List.Location = New-Object System.Drawing.Point(20, 100)
    $List.Size = New-Object System.Drawing.Size(800, 190)
    $List.View = 'Details'
    $List.FullRowSelect = $true
    [void] $List.Columns.Add('Status', 90)
    [void] $List.Columns.Add('Prerequisite', 180)
    [void] $List.Columns.Add('PowerShell value', 190)
    [void] $List.Columns.Add('Detail', 420)

    foreach ($Prerequisite in $Prerequisites) {
        $Item = New-Object System.Windows.Forms.ListViewItem($Prerequisite.Status)
        [void] $Item.SubItems.Add($Prerequisite.Name)
        [void] $Item.SubItems.Add($Prerequisite.PowerShellValue)
        [void] $Item.SubItems.Add($Prerequisite.Detail)
        if ($Prerequisite.Status -eq 'Blocked') {
            $Item.ForeColor = [System.Drawing.Color]::DarkRed
        }
        elseif ($Prerequisite.Status -eq 'Warning') {
            $Item.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        else {
            $Item.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        [void] $List.Items.Add($Item)
    }

    $CommandPreview = New-Object System.Windows.Forms.TextBox
    $CommandPreview.Location = New-Object System.Drawing.Point(20, 302)
    $CommandPreview.Size = New-Object System.Drawing.Size(800, 44)
    $CommandPreview.Multiline = $true
    $CommandPreview.ReadOnly = $true

    $Model = New-EpoGuiRuntimeModel -ToolboxRoot $ToolboxRoot -ConfigPath $ConfigPath -OutputRoot $OutputRoot -TargetServers $TargetServers -CorrelationId $CorrelationId -Stage $Stage -ValidationOnly:$ValidationOnly
    $CommandPreview.Text = ConvertTo-EpoUnattendedCommand -Model $Model

    $InventoryLabel = New-Object System.Windows.Forms.Label
    $InventoryLabel.Text = "Update inventory request: TargetServers=$($Model.TargetServers)"
    $InventoryLabel.Location = New-Object System.Drawing.Point(20, 356)
    $InventoryLabel.Size = New-Object System.Drawing.Size(800, 20)

    $InventoryList = New-Object System.Windows.Forms.ListView
    $InventoryList.Location = New-Object System.Drawing.Point(20, 382)
    $InventoryList.Size = New-Object System.Drawing.Size(800, 80)
    $InventoryList.View = 'Details'
    $InventoryList.FullRowSelect = $true
    [void] $InventoryList.Columns.Add('Server', 120)
    [void] $InventoryList.Columns.Add('Status', 90)
    [void] $InventoryList.Columns.Add('Build', 120)
    [void] $InventoryList.Columns.Add('CU', 180)
    [void] $InventoryList.Columns.Add('HU', 180)
    [void] $InventoryList.Columns.Add('SU', 180)

    function Refresh-GuiInventory {
        try {
            Import-Module (Join-Path $ToolboxRoot 'Modules\Epo.UpdateInventory.psm1') -Force
            $Targets = @($Model.TargetServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if (-not $Targets.Count) { $Targets = @($env:COMPUTERNAME) }
            $InventoryLabel.Text = "Update inventory request: TargetServers=$($Targets -join ', ')"
            $InventoryList.Items.Clear()
            $Inventory = Get-EpoExchangeUpdateInventory -ServerName $Targets
            foreach ($ServerInventory in $Inventory.Servers) {
                $CuUpdate = @($ServerInventory.InstalledUpdates | Where-Object Type -eq 'CU' | Select-Object -First 1)
                $HuUpdate = @($ServerInventory.InstalledUpdates | Where-Object Type -eq 'HU' | Select-Object -First 1)
                $SuUpdate = @($ServerInventory.InstalledUpdates | Where-Object Type -eq 'SU' | Select-Object -First 1)
                $Cu = if ($CuUpdate.Count) { $CuUpdate[0].DisplayName } else { '' }
                $Hu = if ($HuUpdate.Count) { $HuUpdate[0].DisplayName } else { '' }
                $Su = if ($SuUpdate.Count) { $SuUpdate[0].DisplayName } else { '' }
                $Item = New-Object System.Windows.Forms.ListViewItem($ServerInventory.Server)
                [void] $Item.SubItems.Add($ServerInventory.Status)
                $Build = if ($ServerInventory.ExchangeSetup -and $ServerInventory.ExchangeSetup.PSObject.Properties['FileVersion']) { [string] $ServerInventory.ExchangeSetup.FileVersion } else { '' }
                [void] $Item.SubItems.Add($Build)
                [void] $Item.SubItems.Add([string] $Cu)
                [void] $Item.SubItems.Add([string] $Hu)
                [void] $Item.SubItems.Add([string] $Su)
                [void] $InventoryList.Items.Add($Item)
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Update inventory failed', 'OK', 'Error') | Out-Null
        }
    }

    $PreflightLabel = New-Object System.Windows.Forms.Label
    $PreflightLabel.Text = "Preflight pending reboot request: TargetServers=$($Model.TargetServers)"
    $PreflightLabel.Location = New-Object System.Drawing.Point(20, 470)
    $PreflightLabel.Size = New-Object System.Drawing.Size(800, 20)

    $PreflightList = New-Object System.Windows.Forms.ListView
    $PreflightList.Location = New-Object System.Drawing.Point(20, 496)
    $PreflightList.Size = New-Object System.Drawing.Size(800, 90)
    $PreflightList.View = 'Details'
    $PreflightList.FullRowSelect = $true
    [void] $PreflightList.Columns.Add('Server', 120)
    [void] $PreflightList.Columns.Add('Status', 90)
    [void] $PreflightList.Columns.Add('Severity', 90)
    [void] $PreflightList.Columns.Add('RebootRequired', 120)
    [void] $PreflightList.Columns.Add('Connection', 120)
    [void] $PreflightList.Columns.Add('Blocked', 90)
    [void] $PreflightList.Columns.Add('Reason', 260)

    function Refresh-GuiPreflight {
        try {
            Import-Module (Join-Path $ToolboxRoot 'Modules\Epo.Preflight.psm1') -Force
            $Targets = @($Model.TargetServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if (-not $Targets.Count) { $Targets = @($env:COMPUTERNAME) }
            $ScriptPath = Join-Path $ToolboxRoot 'Scripts\Get-PendingReboot.ps1'
            $PreflightLabel.Text = "Preflight pending reboot request: TargetServers=$($Targets -join ', ')"
            $PreflightList.Items.Clear()
            $Preflight = Invoke-EpoPreflightCheck -ServerName $Targets -PendingRebootScriptPath $ScriptPath -EnablePendingRebootFallback -BlockOnPendingReboot $true -BlockOnUnknownRebootState $true
            foreach ($ServerPreflight in $Preflight.Servers) {
                $Item = New-Object System.Windows.Forms.ListViewItem($ServerPreflight.Server)
                [void] $Item.SubItems.Add($ServerPreflight.Status)
                [void] $Item.SubItems.Add($ServerPreflight.Severity)
                [void] $Item.SubItems.Add([string] $ServerPreflight.PendingReboot.RebootRequired)
                [void] $Item.SubItems.Add([string] $ServerPreflight.PendingReboot.ConnectionMethod)
                [void] $Item.SubItems.Add([string] $ServerPreflight.Blocked)
                [void] $Item.SubItems.Add([string] $ServerPreflight.PendingReboot.RemoteConnectionFailureReason)
                if ($ServerPreflight.Blocked) {
                    $Item.ForeColor = [System.Drawing.Color]::DarkRed
                }
                elseif ($ServerPreflight.Status -eq 'Warning') {
                    $Item.ForeColor = [System.Drawing.Color]::DarkOrange
                }
                else {
                    $Item.ForeColor = [System.Drawing.Color]::DarkGreen
                }
                [void] $PreflightList.Items.Add($Item)
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Preflight check failed', 'OK', 'Error') | Out-Null
        }
    }

    $WizardButton = New-Object System.Windows.Forms.Button
    $WizardButton.Text = 'Open wizard'
    $WizardButton.Location = New-Object System.Drawing.Point(425, 610)
    $WizardButton.Size = New-Object System.Drawing.Size(105, 30)
    $WizardButton.Enabled = $Blocked.Count -eq 0
    $WizardButton.Add_Click({ Show-EpoToolboxWizard -Model $Model })

    $CopyButton = New-Object System.Windows.Forms.Button
    $CopyButton.Text = 'Copy command'
    $CopyButton.Location = New-Object System.Drawing.Point(540, 610)
    $CopyButton.Size = New-Object System.Drawing.Size(105, 30)
    $CopyButton.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($CommandPreview.Text) })

    $CloseButton = New-Object System.Windows.Forms.Button
    $CloseButton.Text = 'Close'
    $InventoryButton = New-Object System.Windows.Forms.Button
    $InventoryButton.Text = 'Refresh inventory'
    $InventoryButton.Location = New-Object System.Drawing.Point(145, 610)
    $InventoryButton.Size = New-Object System.Drawing.Size(125, 30)
    $InventoryButton.Add_Click({ Refresh-GuiInventory })

    $PreflightButton = New-Object System.Windows.Forms.Button
    $PreflightButton.Text = 'Refresh preflight'
    $PreflightButton.Location = New-Object System.Drawing.Point(285, 610)
    $PreflightButton.Size = New-Object System.Drawing.Size(125, 30)
    $PreflightButton.Add_Click({ Refresh-GuiPreflight })

    $CloseButton.Location = New-Object System.Drawing.Point(655, 610)
    $CloseButton.Size = New-Object System.Drawing.Size(80, 30)
    $CloseButton.Add_Click({ $Form.Close() })

    $Form.Controls.AddRange(@($Title, $Status, $List, $CommandPreview, $InventoryLabel, $InventoryList, $PreflightLabel, $PreflightList, $InventoryButton, $PreflightButton, $WizardButton, $CopyButton, $CloseButton))
    [void] $Form.ShowDialog()
}

Export-ModuleMember -Function Test-EpoGuiPrerequisites, New-EpoGuiRuntimeModel, ConvertTo-EpoUnattendedCommand, Export-EpoGuiConfigDataFile, Show-EpoToolboxDashboard
