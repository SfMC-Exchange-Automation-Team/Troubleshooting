@{
    RootModule        = ''
    ModuleVersion = '0.1.59'
    GUID              = 'c4e9a17b-5d2f-4a86-9f31-7b0c8e5d24af'
    Author            = 'Cullen Haafke'
    Description       = 'TLC Toolbox: Microsoft Teams log collection. Scenario-scoped evidence capture, retrospective client log harvest, privacy gating and verified handover bundles.'
    PowerShellVersion = '5.1'

    # Load order matters. Path and Logging come first because everything else writes
    # through them; Configuration follows because the collectors take a config
    # section; the collectors then load in the order a run uses them, and the UI
    # last because it drives the rest rather than being called by it.
    NestedModules = @(
        'Modules\Tlc.Logging.psm1'
        'Modules\Tlc.Config.psm1'
        'Modules\Tlc.Scope.psm1'
        'Modules\Tlc.Collect.Desktop.psm1'
        'Modules\Tlc.Collect.Rooms.psm1'
        'Modules\Tlc.Collect.Web.psm1'
        'Modules\Tlc.Collect.Network.psm1'
        'Modules\Tlc.Capture.psm1'
        'Modules\Tlc.Collect.Cvi.psm1'
        'Modules\Tlc.Manual.psm1'
        'Modules\Tlc.Fleet.psm1'
        'Modules\Tlc.Privacy.psm1'
        'Modules\Tlc.Package.psm1'
        'Modules\Tlc.History.psm1'
        'Modules\Tlc.Settings.psm1'
        'Modules\Tlc.Localization.psm1'
        'Modules\Tlc.Ui.psm1'
        'Modules\Tlc.Ui.Theme.psm1'
        'Modules\Tlc.Ui.Metrics.psm1'
        'Modules\Tlc.Ui.Shortcut.psm1'
        'Modules\Tlc.Ui.Wizard.psm1'
    )

    # A curated surface rather than everything the modules export. Helpers that
    # exist to serve one collector stay internal so the supported shape is the one
    # documented, not whatever happens to be reachable.
    FunctionsToExport = @(
        # Run lifecycle and diagnostics
        'Invoke-TlcNativeCommand'
        'ConvertTo-TlcNativeFilePath'
        'Initialize-TlcRun'
        'Test-TlcDiskFullError'
        'Get-TlcRemoteConnectHint'
        'Get-TlcRun'
        'Complete-TlcRun'
        'Write-TlcEvent'
        'Write-TlcStopProgress'
        'Write-TlcBlocker'
        'Export-TlcEvidence'
        'Get-TlcEnvironmentFact'
        'Start-TlcToolLog'
        'Write-TlcToolLog'
        'Get-TlcToolLogPath'
        'Write-TlcStartupFailure'

        # Configuration
        'Import-TlcDataFile'
        'Import-TlcConfig'
        'Resolve-TlcPath'
        'Get-TlcEffectiveConfig'
        'Protect-TlcConfigValue'
        'Merge-TlcLocalConfig'
        'Add-TlcKnownAccountId'
        'Get-TlcLocalConfigPath'
        'Get-TlcUserConfigPath'

        # Scope and scenarios
        'Get-TlcDataPath'
        'Get-TlcScenarioCatalog'
        'Get-TlcManualCatalog'
        'Resolve-TlcScenario'
        'ConvertTo-TlcUtc'
        'New-TlcScopeRecord'
        'Test-TlcRunRequest'

        # Collection
        'Invoke-TlcClientLogCollection'
        'Save-TlcRotatedClientLog'
        'Get-TlcLogSpan'
        'Get-TlcSpanGap'
        'Get-TlcClientInventory'
        'Get-TlcCacheFootprint'
        'Get-TlcMachineFact'
        'Get-TlcAudioDeviceFact'
        'Get-TlcPowerFact'
        'Get-TlcClientUpdateHistory'
        'Get-TlcWebViewCrashFact'
        'Get-TlcTacCorrelation'
        'Get-TlcLaunchEnvironmentFact'
        'Get-TlcInterferingModuleFact'
        'Get-TlcMeetingAddinFact'
        'Get-TlcMeetingAddinHealth'
        'Get-TlcDeviceJoinState'
        'Get-TlcAppxPackage'
        'Copy-TlcClientState'
        'Get-TlcEventLogEvidence'
        'Invoke-TlcSupportFilePrompt'
        'ConvertFrom-TlcLogTimestamp'
        'Select-TlcLogFileInWindow'
        # Also needed by Tlc.Ui.Metrics, which is a sibling nested module and so can
        # only reach commands this list makes global. A nested module does not inherit
        # another nested module's private session state, so anything left off here is
        # invisible to the rest of the toolbox as well as to the caller.
        'Get-TlcLogFileStart'
        'Export-TlcLogExcerpt'
        'Get-TlcLogNoiseNote'
        'Export-TlcLogTimeline'
        'Copy-TlcOpenFile'
        'Invoke-TlcRoomsLogCollection'
        'Test-TlcRoomsDevice'
        'Get-TlcRoomsPackageFact'
        'Get-TlcRoomsProvisioningInventory'
        'Get-TlcRoomsBundleInventory'
        'Invoke-TlcWebCollection'
        'Request-TlcBrowserCapture'
        'Get-TlcWebLogNetworkState'
        'Invoke-TlcWebLogTrigger'
        'Get-TlcWebLogAccount'
        'Invoke-TlcVdiCollection'
        'Invoke-TlcNetworkCollection'
        'Get-TlcLocalBlockFact'
        'Test-TlcProxyReachability'
        'Write-TlcNetworkCauseRow'
        'Get-TlcAudioProblem'
        'Get-TlcClockFact'
        'Get-TlcClockProblem'
        'Select-TlcTeamsFaultEvent'
        'Select-TlcSignInFaultEvent'
        'Test-TlcFileHeldForWrite'
        'Test-TlcStunReachability'
        'Get-TlcTeamsWebViewMemory'
        'Get-TlcSystemMemory'
        'Get-TlcCaptureSample'
        'Invoke-TlcCaptureSession'
        'Get-TlcCaptureSummary'
        'Stop-TlcCaptureSession'
        'Get-TlcDeepCaptureOption'
        'Get-TlcDeepCaptureReason'
        'Get-TlcStaleCaptureTrace'
        'Get-TlcIsElevated'
        'Get-TlcDeepCaptureMarkerPath'
        'Stop-TlcDeepCapture'
        'Start-TlcDeepCapture'
        'Get-TlcTenantCloudFact'
        'Get-TlcCloudEndpoint'
        'Get-TlcQosPolicyFact'
        'Get-TlcNetworkIntermediation'
        'Get-TlcWifiFact'
        'Resolve-TlcDnsChain'
        'Get-TlcTlsCertificateFact'
        'Measure-TlcMediaPathQuality'

        # Cloud Video Interop and conference rooms
        'New-TlcCorrelationHeader'
        'Format-TlcCorrelationHeader'
        'Get-TlcCviPolicyFact'
        'Get-TlcRemoteLogCollectionFact'
        'Invoke-TlcCviCollection'

        'New-TlcManualChecklist'

        # Privacy and packaging
        'Get-TlcIdentityInventory'
        'Protect-TlcHarCredential'
        'Protect-TlcHarAddress'
        'ConvertTo-TlcShareableIdentityInventory'
        'Test-TlcPrivacyGate'
        'Get-TlcPackageRefusalText'
        'Format-TlcRefusalText'
        'New-TlcConsentRecord'
        'Protect-TlcIdentifier'
        'Find-TlcUpn'
        'Get-TlcCurrentUserUpn'
        'New-TlcBundle'
        'Assert-TlcBundleScope'
        'New-TlcSessionArchive'
        'New-TlcZipArchive'
        'Get-TlcFileHash'
        'Test-TlcBundleIntegrity'

        # User interface
        'Initialize-TlcUi'
        'Show-TlcCapabilityComparison'
        'Show-TlcConfirmation'
        'Show-TlcSessionLogPicker'
        'Get-TlcUiRoot'
        'Import-TlcXaml'
        'Get-TlcUiElement'
        'Sync-TlcUiPaint'
        'Set-TlcUiBanner'
        'Show-TlcWizard'
        'Show-TlcDetailWindow'
        'Get-TlcCrashDetail'
        'New-TlcUiCommand'
        'ConvertTo-TlcWindowTranscript'
        'Add-TlcRunOutput'
        'Update-TlcCaptureChart'
        'Initialize-TlcCaptureReading'
        'Update-TlcRunLoading'
        'Update-TlcStopProgress'
        'Update-TlcTranscriptView'
        'Get-TlcRunSummaryWindowText'
        'Set-TlcRunActionButton'
        'Get-TlcWizardConsent'
        'Set-TlcWizardConsentAccount'
        'Set-TlcWizardScenarioName'
        'Initialize-TlcWizardScenarioList'
        'Get-TlcWizardSelectedScenario'
        'Get-TlcDeepCaptureReasonText'
        'Update-TlcWizardConsentField'
        'Get-TlcChevronOpacity'
        'Test-TlcScenarioSupportsCapture'
        'ConvertTo-TlcCaptureIntervalSeconds'
        'ConvertFrom-TlcWizardTimeText'

        # Case memory
        'Test-TlcDarkMode'
        'Get-TlcThemePath'
        'ConvertTo-TlcDarkThemeXaml'
        'Set-TlcWindowDarkChrome'
        'Set-TlcWindowChromeFromSurface'
        'Get-TlcHistoryPath'
        'Get-TlcCaseHistory'
        'Add-TlcCaseHistoryEntry'
        'Remove-TlcCaseHistoryEntry'

        # Operator preferences and display language.
        #
        # Every one of these is reachable from a WPF event handler - the settings button
        # reads the table, applies it and saves the choice - and a handler resolves names
        # against the caller's scope. A function missing from this list is not a style
        # problem: it throws the moment the button is pressed, and only then.
        'Get-TlcSettingsPath'
        'Get-TlcSettings'
        'Set-TlcSettings'
        'Get-TlcLanguage'
        'Test-TlcLanguageSupported'
        'Get-TlcThemeOption'
        'Test-TlcThemeSupported'
        'Get-TlcLanguagePath'
        'Import-TlcLanguageData'
        'Import-TlcStringTable'
        'Get-TlcStringTable'
        'Get-TlcString'
        'Get-TlcTileText'
        'Get-TlcScenarioDisplayName'
        'Get-TlcMetricText'
        'Get-TlcMetricDetail'
        'Set-TlcWizardString'
        'Show-TlcSettingsWindow'

        # The toolbox's own icon and taskbar identity, and the Start menu entry that shares
        # it. The launcher calls the app ID pair from its own scope, and the Settings button
        # calls Update-TlcShortcutSetting from a handler in Tlc.Ui.Wizard, so both reach these
        # only through this list. Finding 341.
        'Get-TlcIconPath'
        'Set-TlcProcessAppId'
        'Get-TlcProcessAppId'
        'Get-TlcAppUserModelId'
        'Get-TlcShortcutState'
        'Install-TlcShortcut'
        'Install-TlcApplication'
        'Set-TlcWindowLauncherIdentity'
        'Uninstall-TlcShortcut'
        'Update-TlcShortcutSetting'

        # Dashboard metrics
        'New-TlcMetricText'
        'New-TlcMetricList'
        'Join-TlcMetricText'
        'Get-TlcNetworkPathPart'
        'Get-TlcLogInventory'
        'Get-TlcClientMetric'
        'Get-TlcLogVolumeMetric'
        'Get-TlcRetentionMetric'
        'Get-TlcActivityMetric'
        'Get-TlcCoverageMetric'
        'Get-TlcCrashMetric'
        'Get-TlcNetworkPathMetric'
        'Get-TlcUpdateMetric'
        'Get-TlcSignInMetric'
        'Get-TlcBrokerAccount'
        'Get-TlcToolChoice'
        'Get-TlcCapabilityComparison'
        'Get-TlcAdminCenterProcedure'
        'Get-TlcPlatform'
        'Get-TlcPlatformSignal'
        'Get-TlcPlatformAdvisoryText'
        'Invoke-TlcFleetCollection'
        'Get-TlcFleetEndpoint'
        'Invoke-TlcFleetPrivacyGate'
        'Get-TlcFleetReadiness'
        'Invoke-TlcRemoteClientLogCollection'
        'Invoke-TlcSmbClientLogCollection'
        'Compare-TlcEndpoint'
        'Get-TlcCallMarker'
        'Invoke-TlcInteractiveLaunch'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # Everything the toolbox ships, declared rather than implied. Without this a
    # consumer copying "the module" takes the .psm1 files and leaves the markup, the
    # theme, the banner and the scenario data behind - and the failure lands later, at
    # the point the wizard tries to load a XAML file that is not there.
    #
    # Assets\TLC-Banner-nochev.png is supplied artwork, not generated output.
    # Tools\ and Tests\ are deliberately absent: they are development scaffolding, not
    # part of what a customer receives. Tlc.FileList.Tests.ps1 checks this list against
    # what is actually on disk, because a hand-maintained manifest of files is stale
    # the first time someone adds one.
    FileList = @(
        'Tlc.psd1'
        'TLC-Toolbox.ps1'
        'Start-TlcToolbox.ps1'
        'TLC-Toolbox.exe'
        'Start-TlcToolbox.cmd'
        'Collect-TeamsLogs.cmd'
        'Invoke-TlcQuickCollect.ps1'

        # The header loads the two pieces. The wordmark and the chevrons are supplied as
        # separate artwork and installed by Tools\Update-TlcBannerAssets.ps1, which trims
        # transparent padding off the wordmark - padding matters because the two are
        # pinned to opposite edges and the gap between them flexes with the window.
        #
        # TLC-Banner-nochev.png is the wordmark artwork as supplied - the same design with
        # the chevrons left off, which is what the name says. It is the SOURCE the wordmark
        # pieces are cut from, so it ships alongside them: regenerating the header without
        # it means going back to whoever holds the original.
        #
        # It replaced TLC-Banner-clear.png, which was the design combined into one image
        # including chevrons. That was never loaded by the window and was not the source of
        # anything, so it was carrying a name that suggested otherwise.
        'Assets\TLC-Banner-nochev.png'
        'Assets\TLC-Wordmark.png'
        'Assets\TLC-Wordmark-Dark.png'
        'Assets\TLC-Chevrons.png'

        # The window and Start menu icon. Generated by Tools\New-TlcIcon.ps1, which is its
        # source: eight sizes drawn separately rather than one image scaled, so the small ones
        # stay legible. Deliberately not the Teams-like glyph from the banner, which in a
        # taskbar would be mistaken for Teams itself.
        'Assets\TLC-Toolbox.ico'

        'Config\TeamsLogCollection.config.psd1'

        'Data\ScenarioCatalog.psd1'
        'Data\ManualEvidence.psd1'
        'Data\InterferingModules.psd1'
        'Data\LaunchEnvironment.psd1'
        'Data\EventIdReference.psd1'
        'Data\CloudEndpoints.psd1'
        'Modules\Tlc.Logging.psm1'
        'Modules\Tlc.Config.psm1'
        'Modules\Tlc.Scope.psm1'
        'Modules\Tlc.Collect.Desktop.psm1'
        'Modules\Tlc.Collect.Rooms.psm1'
        'Modules\Tlc.Collect.Web.psm1'
        'Modules\Tlc.Collect.Network.psm1'
        'Modules\Tlc.Capture.psm1'
        'Modules\Tlc.Collect.Cvi.psm1'
        'Modules\Tlc.Manual.psm1'
        'Modules\Tlc.Fleet.psm1'
        'Modules\Tlc.Privacy.psm1'
        'Modules\Tlc.Package.psm1'
        'Modules\Tlc.History.psm1'
        'Modules\Tlc.Settings.psm1'
        'Modules\Tlc.Localization.psm1'
        'Modules\Tlc.Ui.psm1'
        'Modules\Tlc.Ui.Theme.psm1'
        'Modules\Tlc.Ui.Metrics.psm1'
        'Modules\Tlc.Ui.Shortcut.psm1'
        'Modules\Tlc.Ui.Wizard.psm1'

        'Ui\Wizard.xaml'
        'Ui\Detail.xaml'
        'Ui\Settings.xaml'
        'Ui\Theme.xaml'

        'Lang\de-DE.psd1'
        'Lang\en-US.psd1'
        'Lang\es-ES.psd1'
        'Lang\fr-FR.psd1'
        'Lang\hi-IN.psd1'
        'Lang\it-IT.psd1'
        'Lang\ja-JP.psd1'
        'Lang\pt-BR.psd1'
        'Lang\ru-RU.psd1'
        'Lang\ta-IN.psd1'
        'Lang\zh-CN.psd1'
    )

    PrivateData = @{
        PSData = @{
            Tags       = @('Teams', 'Diagnostics', 'SfMC', 'LogCollection')
            ProjectUri = 'https://github.com/SfMC-Exchange-Automation-Team/Troubleshooting'
        }
    }
}
