@{
    CustomerName = 'Contoso'
    Environment  = 'Production'

    # %SystemDrive%, not a literal C:. Windows is not always on C - a reimaged or
    # multi-boot endpoint can be on D or E - and a hardcoded letter would send the run
    # to a drive that may not exist, or worse, to one that does and belongs to
    # something else. Resolve-TlcPath expands this at use time, so the same config file
    # works on any machine.
    RunRoot = '%SystemDrive%\TLC-Toolbox\Runs'

    StageAwareness = @{
        CurrentStage = 'Scope'
        # The pipeline as built. This list is descriptive - nothing dispatches on it -
        # but it is copied verbatim into Plan.json, which ships inside the handover
        # bundle, so it should not advertise stages that do not exist.
        #
        # 'PreCheck' and 'Report' were planned and are deliberately not here. Readiness
        # is already covered by Scope, which emits the lane counts and the manual
        # checklist before anything is collected, and reporting is covered by
        # Blockers.csv and Summary.csv. -Stage still accepts both names and answers with
        # a Warning blocker naming them as unimplemented, because a clear message beats
        # a parameter validation error for someone working from older notes.
        StageOrder = @(
            'Scope'
            'Collect'
            'Validate'
            'Package'
        )
    }

    Scope = @{
        DefaultScenario = ''
        RequireCaseNumber = $true
        # Window either side of the reported impact time that evidence is gathered for.
        ReproWindowBeforeMinutes = 30
        ReproWindowAfterMinutes = 30
    }

    Collection = @{
        # Verified 2026-08-21 against MSTeams 26225.1803.5037.3180. New Teams writes
        # rolling logs here with no user action, which is what makes retrospective
        # collection possible after a sporadic issue has already cleared.
        ClientLogRoot = '%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
        ClientStateRoot = '%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'
        ClientLogPatterns = @(
            'MSTeams_*.log'
            'MSTeamsNM_SlimCore_*.log'
            'MSTeamsBackgroundEcs_*.log'
            # Added 2026-09-06 after enumerating the folder rather than trusting the
            # pattern list. Teams writes 14 distinct log families and this list covered
            # three of them, so bundles were missing evidence the client had already
            # written. Every entry below is still window-selected, so a family with 118
            # files on disk contributes only the handful that overlap the repro window.
            #
            # Launcher_*: the launch sequence and the running-vs-previous build pair.
            # The toolbox already PARSED these for update history without ever putting
            # them in the bundle, so the reviewer could see the conclusion and not the
            # evidence. First thing to read on a launch or crash case.
            'Launcher_*.log'
            # Update and autostart paths. A client that failed to update, or failed to
            # start with Windows, leaves its explanation here and nowhere else.
            'MSTeamsUpdate_*.log'
            'MSTeamsBackgroundUpdate_*.log'
            'MSTeamsAutoStarter_*.log'
        )
        # Which of the families above are ROLLING - written continuously while the client
        # is alive, and rotated by age. This is not about what gets collected: everything
        # in ClientLogPatterns is collected either way, by window overlap.
        #
        # It is about what the dashboard is allowed to CLAIM. The oldest and newest of
        # these set three tiles - Logs go back, Window covered, and Teams activity - and
        # the sparse families are wrong for all three. MSTeamsAutoStarter_*.log is written
        # once per Windows-startup launch, so files survive over a year; bounding
        # retention across it reported "Logs go back 397.2 days" against real logs that
        # stopped at 26, and let Window covered say "Covered" for a 200-day-old incident.
        # MSTeamsBackgroundUpdate_*.log is written by a task that runs whether or not the
        # Teams UI exists, so it reported "Just now" for a client dead nine hours.
        #
        # Add a family here only if Teams writes it continuously while the client runs.
        ClientRollingLogPatterns = @(
            'MSTeams_*.log'
            'MSTeamsNM_SlimCore_*.log'
        )
        ClientStateFiles = @(
            'app_settings.json'
            'previous_session_data.json'
            'crash_reports_cache.json'
            # uae.json is the unexpected-app-exit record: quit_reason, machine_locked,
            # memory_availability, oops_page_shown, user_initiated_update. That is the
            # client's own account of why it last went away, in well under a kilobyte.
            'uae.json'
            # Media and device settings: selected speaker, microphone and camera, noise
            # suppression, echo cancellation, AGC. "Which device was it actually using"
            # is one of the first questions on a call-quality case and the answer was
            # not in the bundle.
            'cmd_settings.json'
            # ECS request parameters: flight ring, region, cloud, licence category and
            # add-on plans. This is what answers "it works for everyone except this
            # user" - a different ring or a missing licence is visible here and nowhere
            # else the toolbox collects.
            #
            # It carries userId and tenantId in clear. That is deliberate and safe: the
            # privacy gate inventories and masks identifiers, and an id the gate can see
            # is better than one hiding in a file nobody collected.
            'ecs_request_param.json'
            'tma_request_param.json'
        )

        # User-initiated collection (Ctrl+Alt+Shift+1) lands here.
        #
        # Check this on a managed estate before relying on it. Known Folder Move
        # redirects Downloads - commonly into OneDrive - and Teams writes its web logs
        # to wherever the shell says Downloads is, not to the default path. Pointing at
        # the wrong folder does not fail: it finds nothing and reports that the user's
        # action produced no files. The real location is in
        # HKCU:\...\Explorer\User Shell Folders under {374DE290-123F-4565-9164-39C4925E467B}.
        SupportFileDropFolder = '%USERPROFILE%\Downloads'
        WebLogPatterns = @(
            'Prod-Weblogs*'
            'Life-Weblogs*'
            'GCCH-Weblogs*'
            'DOD-Weblogs*'
        )
        SupportLogPatterns = @(
            'MSTeams Support Logs*'
            'MSTeams Diagnostics Log*'
        )

        IncludeEventLogs = $true

        # One entry per log, because one filter for all of them was silently throwing
        # most of the evidence away. Ids and Levels are OR'd within an entry: Get-WinEvent
        # ANDs everything in a FilterHashtable, so the collector runs one query per
        # dimension and merges. That is not gold-plating - Application event 1001, the
        # Windows Error Reporting record, is logged at Information, so a Critical/Error
        # level filter drops every crash report while looking correct.
        #
        # Levels: 1 Critical, 2 Error, 3 Warning, 4 Information, 5 Verbose.
        #
        # Each Levels list below was set from the level distribution the channel actually
        # produces on a real machine, not from a house style. Getting this wrong is quiet:
        # a channel with nothing at Error returns nothing and reads as a clean window.
        EventLogs = @(
            @{
                # 1000 application crash, 1001 Windows Error Reporting, 1002 application
                # hang. Kept as ids because 1001 is Information and no level filter would
                # reach it.
                LogName = 'Application'
                Ids     = @(1000, 1001, 1002)
                Levels  = @(1, 2)
            }
            @{
                # Kernel-Power 41 is Critical; 6008, 7000, 7009 and 7031 are Error, so
                # levels cover the named ids without having to keep a list current. The
                # previous 1000/1001 filter matched two System events in thirty days.
                LogName = 'System'
                Levels  = @(1, 2)
            }
            @{
                # MSIX staging and per-user registration failures, which appear in
                # neither Application nor System.
                LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'
                Levels  = @(1, 2, 3)
            }
            @{
                # Token and PRT failures - the local evidence the sign-in scenario had
                # none of. Measured: this channel logs nothing at Information at all.
                LogName = 'Microsoft-Windows-AAD/Operational'
                Levels  = @(1, 2, 3)
            }
            @{
                # The other half of the same story. Microsoft writes CloudAP ERROR events to
                # Operational and INFORMATION events here, so the PRT acquisition flow - 1006
                # opening it, 1022 naming the endpoint, 1007 closing it with the final result -
                # is only ever in this channel. Without it the Operational errors have no
                # sequence around them.
                #
                # Disabled by default on Windows, and the toolbox will not enable it: that
                # changes machine state and needs elevation. Collected when a customer or an
                # earlier engineer has already turned it on, and reported as present-but-off
                # otherwise, so an empty section is never mistaken for a quiet one.
                LogName = 'Microsoft-Windows-AAD/Analytic'
            }
            @{
                # Warning is the only signal here; measured 435 warnings and zero errors
                # over a week, so an Error-only filter would return nothing.
                LogName = 'Microsoft-Windows-User Device Registration/Admin'
                Levels  = @(1, 2, 3)
            }
            @{
                # Shared by every app on the machine, so it needs both filters. Verbose
                # here is transport keep-alive traffic, and the message filter keeps the
                # two things that bear on Teams: records naming the package, and the
                # platform-level notice that push cannot be received at all. Unfiltered
                # this channel supplied 202 of 211 events in a one-hour window, almost
                # all of them other applications' toasts and pings.
                LogName      = 'Microsoft-Windows-PushNotification-Platform/Operational'
                Levels       = @(1, 2, 3, 4)
                MessageMatch = 'MSTeams|Cloud Notifications'
            }
        )

        # Per log, not per run. One noisy channel must not be able to crowd out the
        # others, and an unfiltered channel needs a ceiling.
        MaxEventsPerLog = 400

        # No MaxLogAgeDays here, deliberately. One existed, was documented as an "age
        # ceiling for candidate logs", and was never read by any code - and wiring it up
        # would have broken the tool rather than fixed it. Selection is by window overlap
        # (Select-TlcLogFileInWindow), which is the whole point: an incident from three
        # weeks ago whose logs are still on disk must remain collectable. An age ceiling
        # would silently exclude exactly the retrospective case this toolbox exists for.
        MaxBundleSizeMB = 512
    }

    Rooms = @{
        # Teams Rooms devices keep the collector under the Rigel tree. Kept in config
        # rather than hard-coded so the collector can be pointed at a fixture for
        # testing, and so a device with a non-default layout stays supportable.
        #
        # This one stays a literal C: on purpose, unlike RunRoot. It is not a path this
        # toolbox chooses - it is where the Rooms image puts the vendor collector, and
        # the published guidance refers to it by that name. %SystemDrive% here would be
        # the local engineer's drive letter, not the remote device's, which is the wrong
        # machine entirely. A device that differs is handled by editing this value.
        RigelRoot = 'C:\Rigel'
        ScriptLaunchRelativePath = 'x64\Scripts\Provisioning\ScriptLaunch.ps1'
        CollectScriptName = 'CollectSrsV2Logs.ps1'
        CollectTimeoutMinutes = 15
        # The published guidance ends with "Remove-Item -Force C:\Rigel\*.zip", which
        # deletes every bundle on the device including one another engineer may be
        # mid-collection on. Only the file this run produced is removed.
        RemoveCollectedZipFromDevice = $true
    }

    Privacy = @{
        # New Teams emits diagnostics for every signed-in account regardless of
        # tenant or cloud, so collecting on a customer endpoint can sweep in
        # unrelated tenants. Blocking is the safe default.
        #
        # Verified 2026-08-21: the rolling client logs this toolbox collects contain
        # no UPNs and no tenant GUIDs. The reliable multi-account signal is
        # app_settings.json -> active_users, which lists one object id per signed-in
        # account. The gate is therefore built on account ids, not on tenant ids that
        # are not present in the evidence.
        BlockOnUnknownAccount = $true
        # Object ids known to belong to the customer or engagement. An account seen
        # in the evidence that is not listed here is treated as foreign.
        KnownAccountIds = @()
        # Optional. If a tenant GUID does appear in evidence, anything other than
        # these is reported as foreign.
        KnownTenantIds = @()
        HomeTenantId = ''
        RequireConsent = $true
        ConsentGrantedBy = ''
        # Mask third-party email addresses in HAR files before the privacy gate (the domain is kept,
        # the person is not). The affected user and the operator stay readable. A single OneDrive
        # listing carried 7,397 addresses. Client logs are not touched. Finding 313.
        ScrubUpn = $true
        # Bytes scanned per file when looking for identifiers and tokens. 0 scans every file
        # whole, in chunks, which is the only setting under which a clean verdict covers the whole
        # bundle. The old default of 8 MB read the first 8 MB of each file and said nothing about
        # the rest - and HAR exports, the likeliest place for a token, are often larger.
        # A positive value is a cap, and the gate then names each file it read only in part.
        MaxScanBytesPerFile = 0
    }

    Thresholds = @{
        BlockOnCritical = $true
        WarnOnHigh = $true
    }
}
