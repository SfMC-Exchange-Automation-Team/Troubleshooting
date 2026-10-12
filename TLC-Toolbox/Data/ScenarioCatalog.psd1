@{
    # Scenario catalog. One entry per row of the published Log Collection Matrix.
    #
    # Reference data rather than configuration: a customer never edits this, but the
    # matrix does change when Microsoft publishes new guidance, so it lives in Data\
    # where it can be revised without touching collector code.
    #
    # Lanes describe what the toolbox can actually do:
    #   Auto     - collected with no human action
    #   Prompted - the tool instructs, waits, then verifies and harvests
    #   Manual   - cannot be collected locally; emitted as a checklist stub
    Scenarios = @(
        @{
            Id        = 'DesktopLaunchCrash'
            Name      = 'Teams Desktop: Client Launch, Crash, or Performance Issue'
            Component = 'Teams Desktop'
            Auto     = @('ClientLogs', 'ClientState', 'ClientInventory', 'EventLogs')
            Prompted = @('SupportFiles', 'WebLogs')
            # TeamsAdminCenterClientHealth answers the one question a local bundle
            # structurally cannot: is this machine alone, or is the estate doing it too?
            # TacRemoteClientLogs is the fallback when the prompted lane comes back empty
            # because the user could not or would not run Ctrl + Alt + Shift + 1.
            Manual   = @('TeamsAdminCenterClientHealth', 'TacRemoteClientLogs')
        }
        @{
            Id        = 'DesktopSignIn'
            Name      = 'Teams Desktop: Sign-in or Authentication Failure'
            Component = 'Teams Desktop'
            Auto     = @('ClientLogs', 'ClientState', 'ClientInventory', 'WebView2State')
            Prompted = @('SupportFiles')
            Manual   = @('EntraSignInLogs', 'TeamsSignInDiagnostic', 'RemoteConnectivityAnalyzer')
        }
        @{
            Id        = 'WebClient'
            Name      = 'Teams Web: Browser or Web Client Issue'
            Component = 'Teams Web'
            Auto     = @('BrowserInventory')
            Prompted = @('HarCapture', 'ConsoleOutput', 'WebRtcInternals')
            Manual   = @()
        }
        @{
            Id        = 'CallQuality'
            Name      = 'Meetings and Calls: Poor Meeting or Call Quality'
            Component = 'Meetings and Calls'
            Auto     = @('ClientLogs', 'SlimCoreLogs', 'ClientState', 'NetworkFacts')
            Prompted = @('SupportFiles')
            Manual   = @('CallAnalytics', 'RealTimeAnalytics', 'Cqd', 'NetworkConnectivityTest')
        }
        @{
            Id        = 'MeetingJoin'
            Name      = 'Meetings and Calls: Meeting Join or Setup Failure'
            Component = 'Meetings and Calls'
            Auto     = @('ClientLogs', 'SlimCoreLogs', 'ClientInventory')
            Prompted = @('SupportFiles')
            Manual   = @('CallAnalytics', 'EntraSignInLogs')
        }
        @{
            Id        = 'Files'
            Name      = 'Teams Files: File Upload, Open, Share, or Access Issue'
            Component = 'Teams Files'
            Auto     = @('ClientLogs', 'ClientInventory')
            Prompted = @('HarCapture', 'SupportFiles')
            Manual   = @('SharePointAdmin', 'PurviewAudit')
        }
        @{
            Id        = 'Mobile'
            Name      = 'Teams Mobile: Mobile Client Issue'
            Component = 'Teams Mobile'
            Auto     = @()
            Prompted = @('MobileFeedbackSubmission')
            Manual   = @('MobileDeviceMetadata')
        }
        @{
            Id        = 'Rooms'
            Name      = 'Teams Rooms: Device Issue'
            Component = 'Teams Rooms'
            Auto     = @('SrsV2Logs')
            Prompted = @()
            Manual   = @('RoomsProManagementPortal')
        }
        @{
            Id        = 'Vdi'
            Name      = 'Teams in VDI Issue'
            Component = 'VDI'
            Auto     = @('ClientLogs', 'SlimCorePackage', 'ExtendedLoggingState', 'ClientInventory')
            Prompted = @('SupportFiles')
            Manual   = @('VdiBrokerLogs')
        }
        @{
            Id        = 'TenantService'
            Name      = 'Tenant-wide or Service Availability Impact'
            Component = 'Tenant / Service'
            Auto     = @()
            Prompted = @()
            Manual   = @('ServiceHealth', 'TeamsAdminCenterReports', 'CqdTrends')
        }
        @{
            Id        = 'Network'
            Name      = 'Network, Firewall, Proxy, or VPN Issue'
            Component = 'Network'
            Auto     = @('NetworkFacts', 'ProxyConfiguration', 'UdpReachability')
            Prompted = @()
            Manual   = @('NetworkAssessmentTool', 'NetworkConnectivityTest', 'Cqd')
        }
        @{
            Id        = 'RoomsAndroid'
            Name      = 'Teams Rooms on Android: Device Issue'
            Component = 'Teams Rooms'
            # Not a matrix row. The published matrix has one Rooms entry, written when
            # Teams Rooms meant Windows; Android rooms - Cisco, Neat, Poly, Yealink - are
            # now common and behave nothing like it.
            Source    = 'Extension'
            # Nothing on the device is reachable: no Rigel tree, no PowerShell, no WinRM.
            # What IS collectable is the half that decides most room cases anyway - the
            # network the room sits on - gathered from a laptop on the room's segment. The
            # device's own logs are retrieved through the portal, which is why they sit in
            # the manual lane with the exact click path rather than being silently absent.
            Auto     = @('NetworkFacts', 'ProxyConfiguration', 'UdpReachability')
            Prompted = @()
            Manual   = @('RoomsAndroidPortal', 'RoomsAndroidOem', 'RoomsProManagementPortal')
        }
        @{
            Id        = 'CviRoomSegment'
            Name      = 'Cloud Video Interop: Room Segment Comparison'
            Component = 'Cloud Video Interop'
            # Not a row of the published Log Collection Matrix. Every other entry here is,
            # and that 1:1 relationship is worth keeping visible rather than quietly
            # breaking, so extensions declare themselves. CVI is absent from the matrix
            # because Microsoft treats it as a partner-owned service, but the case still
            # lands on an engineer, and the evidence Microsoft asks for is evidence this
            # toolbox already knows how to gather.
            Source    = 'Extension'
            # Microsoft's published CVI guidance is a single A/B test: a native Teams
            # client on the same network segment as the failing codec. This scenario is
            # that test. The lanes are deliberately the desktop and network ones - the
            # value is not a new collector, it is running the existing ones from the room
            # VLAN and labelling the result as the comparison leg.
            #
            # The tenant CVI policy is MANUAL, not automatic. Reading it needs a Teams admin
            # session on the endpoint, which a customer run never has - the Teams module
            # also refuses to authenticate from any non-interactive host (measured
            # 2026-09-09). Moved here 2026-09-24 by owner decision; finding 296.
            Auto     = @('ClientLogs', 'SlimCoreLogs', 'ClientState', 'ClientInventory',
                         'NetworkFacts', 'ProxyConfiguration', 'UdpReachability',
                         'CviCorrelationHeader')
            Prompted = @('SupportFiles')
            Manual   = @('CviPartnerPortal', 'CviTenantPolicy', 'CallAnalytics', 'Cqd', 'RoomsProManagementPortal')
        }
    )
}

