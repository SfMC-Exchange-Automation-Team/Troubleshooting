@{
    # Portal-only evidence the toolbox cannot collect.
    #
    # Each entry becomes a section of ManualChecklist.md. Reference data rather than
    # configuration: portal names, paths and the fields support asks for change on
    # Microsoft's schedule, not the customer's.
    Evidence = @{
        CallAnalytics = @{
            Title  = 'Teams admin center - Call Analytics'
            Link   = 'https://admin.teams.microsoft.com'
            Path   = 'Manage users > select user > Meetings & calls > select the session'
            Fields = @(
                'Meeting or call id'
                'Affected modality'
                'Reported root cause area'
                'Participant session details'
            )
            Note   = 'Completed meeting telemetry can take 30 minutes to 2 hours to appear.'
        }
        Cqd = @{
            Title  = 'Call Quality Dashboard'
            Link   = 'https://cqd.teams.microsoft.com'
            Path   = 'CQD > Summary or detailed reports for the affected building, subnet or date range'
            Fields = @(
                'Date range queried'
                'Subnet or building'
                'Poor call percentage'
                'Trend vs baseline'
            )
        }
        CqdTrends = @{
            Title  = 'Call Quality Dashboard trend analysis'
            Link   = 'https://cqd.teams.microsoft.com'
            Path   = 'CQD > Trend reports across the tenant, comparing the impacted period against a known-good baseline period'
            Note   = 'Distinct from the Cqd item, which scopes to one building, subnet or date range. A tenant-wide or service-availability question is answered by the shape of the trend, not by a single slice, so record the baseline period as well as the impacted one.'
            Fields = @(
                'Impacted period'
                'Baseline period compared against'
                'Poor call percentage in each period'
                'Scope of the change: tenant-wide, one region, or one building'
                'Whether the trend correlates with a Service Health advisory'
            )
        }
        EntraSignInLogs = @{
            Title  = 'Microsoft Entra sign-in logs'
            Link   = 'https://entra.microsoft.com'
            Path   = 'Entra ID > Monitoring & health > Sign-in logs (requires at least Reports Reader)'
            Fields = @(
                'Affected UPN'
                'Sign-in window (UTC)'
                'Error code and failure reason'
                'Conditional Access result'
                'CSV or JSON export attached'
            )
        }
        MobileDeviceMetadata = @{
            Title  = 'Mobile device metadata'
            Link   = ''
            Path   = 'Collected from the affected user'
            Fields = @(
                'Device model'
                'OS version'
                'Teams app version'
                'Network type'
                'Managed or unmanaged'
                'Feedback submission time'
            )
        }
        MobileFeedbackSubmission = @{
            Title  = 'Teams mobile feedback with logs attached'
            Link   = ''
            Path   = 'Teams mobile > profile > Settings > Help and feedback > Send feedback, with "Attach logs" enabled'
            Fields = @(
                'Submission time'
                'Case number included in the description'
                'Issue description sent'
            )
        }
        NetworkAssessmentTool = @{
            Title  = 'Teams Network Assessment Tool'
            Link   = 'https://www.microsoft.com/download/details.aspx?id=103017'
            Path   = 'Run on the affected network segment'
            Fields = @(
                'Run duration'
                'Loss, latency and jitter results'
                'Connectivity check results'
            )
        }
        NetworkConnectivityTest = @{
            Title  = 'Microsoft 365 network connectivity test'
            Link   = 'https://connectivity.m365.cloud.microsoft'
            Path   = 'Run from the affected network location'
            Fields = @(
                'UDP packet loss (target below 1.00%)'
                'UDP latency (target below 100 ms)'
                'UDP jitter (target below 30 ms)'
                'Result link or export'
            )
        }
        PurviewAudit = @{
            Title  = 'Purview audit search'
            Link   = 'https://purview.microsoft.com'
            Path   = 'Audit > New search for the affected file and user'
            Fields = @(
                'Date range (UTC)'
                'Operations searched'
                'Result export attached'
            )
        }
        RealTimeAnalytics = @{
            Title  = 'Real-Time Analytics'
            Link   = 'https://admin.teams.microsoft.com'
            Path   = 'Teams admin center > Users > select user > Real-time analytics (live meetings only)'
            Fields = @(
                'Observed during meeting'
                'Live quality indicators'
            )
        }
        RemoteConnectivityAnalyzer = @{
            Title  = 'Remote Connectivity Analyzer - Teams Sign-in'
            Link   = 'https://testconnectivity.microsoft.com/tests/TeamsSignin/input'
            Path   = 'Sign in as the affected user and complete verification'
            Fields = @(
                'Test run time'
                'Pass or fail'
                'Reported error'
            )
        }
        TacRemoteClientLogs = @{
            # The complementary route to this toolbox, not a competitor to it. Use it when
            # nobody can run the toolbox on the machine - a remote user, a locked-down
            # endpoint, or an estate where running an unsigned script is not going to
            # happen. It collects Teams application logs only, so it answers a narrower
            # question than a toolbox bundle, and it is silent: no consent prompt is shown.
            #
            # CHECK FOR A PENDING REQUEST FIRST. The toolbox used to try this itself from the
            # endpoint, which needed a Teams admin session there - something a customer run
            # never has. Moved to this checklist 2026-09-24 (finding 296). A request takes up
            # to 8 hours and expires after 3 days, so one the customer's admin raised this
            # morning is evidence already in flight.
            Title  = 'Teams admin center - remote client log collection'
            Link   = 'https://admin.teams.microsoft.com'
            Path   = 'Users > Manage users > select the user > Client health tab. First check View client logs for a request that is already pending or ready - do not raise a duplicate. Otherwise select the client/version > Request client logs, then View client logs > ready-to-download tab. Allow up to 8 hours, and the Teams client must be running.'
            Fields = @(
                'Already pending or ready before this case (yes / no, and when)'
                'Requested at (UTC)'
                'Client and version selected'
                'Client log status, Pending / ready / Ineligible'
                'Downloaded'
            )
        }
        CviPartnerPortal = @{
            # The one piece of evidence that is both essential and permanently out of
            # reach from Windows. Microsoft's telemetry stops at the partner bot, so the
            # codec-to-cloud media numbers exist only here.
            Title  = 'CVI partner portal (Cisco Control Hub, Pexip Infinity, or Poly)'
            Link   = 'https://admin.webex.com'
            Path   = 'Cisco: Monitoring > Troubleshooting > find the meeting > select the room participant. Pexip: Infinity Admin > Status > Participants.'
            Fields = @(
                'Partner and gateway version'
                'Sending packet loss, codec to cloud'
                'Receiving packet loss, cloud to codec'
                'End-to-end loss where the portal reports it'
                'Codec log bundle reference or TAC log id'
                'Partner-side call or tracking id'
            )
        }
        CviTenantPolicy = @{
            # Answers "did this invite ever carry CVI coordinates?" - a configuration
            # question that rules out a media investigation into a meeting that was never
            # CVI-enabled. The toolbox used to read this itself from the endpoint, which
            # needed a Teams admin session there; a customer run never has one, and the
            # Teams module will not authenticate from a non-interactive host at all.
            # Moved here 2026-09-24 (finding 296). All three commands are read-only.
            Title  = 'Tenant CVI and room video-teleconferencing policy'
            Link   = 'https://admin.teams.microsoft.com'
            Path   = 'Ask the tenant Teams administrator to run, read-only, and send the output: Get-CsVideoInteropServiceProvider; Get-CsTeamsVideoInteropServicePolicy; Get-CsTeamsRoomVideoTeleConferencingPolicy. Then note which policy is assigned to the meeting organizer and to the room resource account.'
            Fields = @(
                'CVI provider configured, and enabled (yes / no)'
                'Provider TenantKey'
                'Video interop policy assigned to the organizer'
                'Room video-teleconferencing policy assigned to the room account'
                'Room policy AreaCode matches the provider TenantKey (yes / no)'
            )
        }
        RoomsAndroidPortal = @{
            # The supported retrieval route for Teams Rooms on Android. It is manual on
            # purpose rather than for want of trying: Microsoft's remote log collection can
            # be TRIGGERED from PowerShell or Graph, but the resulting bundle is only
            # downloadable through the portal. Automating the trigger and then leaving the
            # operator to discover that would be worse than saying so up front.
            Title  = 'Teams Rooms Pro Management portal - log collection'
            Link   = 'https://portal.rooms.microsoft.com'
            Path   = 'Rooms > select the device > Actions > Log Collection > Run. After a few minutes: Activity > Room logs > download icon.'
            Fields = @(
                'Device name and resource account'
                'Log collection run at (UTC)'
                'Logs selected, if prompted'
                'Bundle downloaded'
            )
        }
        RoomsAndroidOem = @{
            # The Android Teams Rooms app runs on the vendor's own platform, so the layer
            # underneath it - and often the more useful layer for hardware, peripheral and
            # network faults - is only visible in the vendor's cloud.
            Title  = 'OEM device portal (Cisco Control Hub, Neat Pulse, Poly Lens, Yealink Device Management)'
            Link   = 'https://admin.webex.com'
            Path   = 'Cisco: Devices > select device > Local Device Controls > System Maintenance > Issues and Diagnostics > System Logs. Enable extended logging before reproducing, and note the timestamp.'
            Fields = @(
                'Vendor and model'
                'Device firmware or RoomOS version'
                'Extended logging enabled before repro'
                'Timestamp of the reproduction'
                'Log bundle reference or vendor support id'
            )
        }
        RoomsProManagementPortal = @{
            Title  = 'Teams Rooms Pro Management portal'
            Link   = 'https://portal.rooms.microsoft.com'
            Path   = 'Select the affected device > health and history'
            Fields = @(
                'Device name'
                'Health state'
                'Recent incidents'
                'Log bundle downloaded'
            )
        }
        ServiceHealth = @{
            Title  = 'Microsoft 365 Service health'
            Link   = 'https://admin.microsoft.com/Adminportal/Home#/servicehealth'
            Path   = 'Service health > Microsoft Teams'
            Fields = @(
                'Active advisories or incidents'
                'Incident id'
                'Stated impact vs observed impact'
            )
        }
        SharePointAdmin = @{
            Title  = 'SharePoint admin context'
            Link   = 'https://admin.microsoft.com'
            Path   = 'SharePoint admin center > affected site'
            Fields = @(
                'Site URL'
                'Storage state'
                'Sharing and access policy'
                'Recycle bin state if restore related'
            )
        }
        TeamsAdminCenterClientHealth = @{
                    # The proactive counterpart to a single collection, and the one thing a local
                    # bundle structurally cannot settle: is this machine alone, or is the estate
                    # doing it too? Trends run over a 28-day window.
                    Title  = 'Teams admin center - client health'
                    Link   = 'https://admin.teams.microsoft.com'
                    Path   = 'Per user: Users > Manage users > select account > Client health tab. Estate-wide: Teams client health.'
                    Fields = @(
                        'Crash count in window'
                        'Launch failures'
                        'Update failures'
                        'Client version reported'
                        'Version status, latest / one or more builds behind / outdated'
                        'Whether other users show the same pattern'
                    )
                }
        TeamsAdminCenterReports = @{
            Title  = 'Teams admin center - usage and quality reports'
            Link   = 'https://admin.teams.microsoft.com'
            Path   = 'Analytics & reports'
            Fields = @(
                'Report used'
                'Date range'
                'Observed anomaly'
            )
        }
        TeamsSignInDiagnostic = @{
            Title  = 'Teams Sign-in diagnostic'
            Link   = 'https://admin.microsoft.com'
            Path   = 'Microsoft 365 admin center > Run Tests: Teams Sign-in'
            Fields = @(
                'Affected user'
                'Test run time'
                'Result summary'
            )
            Note   = 'Requires a Microsoft 365 admin account. Not available for GCC High, DoD, 21Vianet or Germany.'
        }
        VdiBrokerLogs = @{
            Title  = 'VDI broker and host logs'
            Link   = ''
            Path   = 'Collected from the VDI platform (AVD, Citrix, VMware)'
            Fields = @(
                'Broker or host log excerpt'
                'Session id'
                'Optimization pack version'
            )
        }
    }
}

