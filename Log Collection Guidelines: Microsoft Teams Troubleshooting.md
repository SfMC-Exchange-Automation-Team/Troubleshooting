## Log Collection Guidelines: Microsoft Teams Troubleshooting

This guide standardizes log collection for common Microsoft Teams troubleshooting scenarios across desktop, web, mobile, Teams Rooms, VDI, meetings, calling, files, identity, network, and tenant-level service health.

**How to use this guide**

1. Start with the **Log Collection Matrix** to identify the best matching scenario.
2. Jump to the linked **detailed scenario subsection** for exact log locations, access instructions, required tools, preconditions, and extra guidance.
3. Collect logs immediately after a clear reproduction of the issue and keep all diagnostics tied to the same repro window.
4. Record the exact local timestamp, time zone, affected user, client type, client version, network location, and repro steps. Times in logs are recorded in Coordinated Universal Time (UTC); when opening a support case, inform the support agent of the time difference between the local time the issue occurred and UTC time.

***

## Log Collection Matrix

| Affected Component | Subsection Link | Symptom | Logs to Collect | Required Tools |
| ------------------ | --------------- | ------- | --------------- | -------------- |
| Teams Desktop | [Client Launch, Crash, or Performance Issue](#teams-desktop-client-launch-crash-or-performance-issue) | Teams fails to launch, crashes, hangs, or is slow | Teams support files, weblogs, Windows event logs, client health data | Teams client, Windows Explorer, Event Viewer, Teams admin center |
| Teams Desktop | [Sign-in or Authentication Failure](#teams-desktop-sign-in-or-authentication-failure) | Sign-in loop, credential prompt, MFA or Conditional Access block | Teams support files, Entra sign-in logs, Teams Sign-in diagnostic output | Teams client, Microsoft Entra admin center, Microsoft 365 admin center |
| Teams Web | [Browser or Web Client Issue](#teams-web-browser-or-web-client-issue) | Issue reproduces only in browser or Teams web | Browser trace, HAR, console output, WebRTC logs | Edge or Chrome DevTools, browser WebRTC internals |
| Meetings and Calls | [Poor Meeting or Call Quality](#meetings-and-calls-poor-meeting-or-call-quality) | Choppy audio, frozen video, dropped call, poor screen sharing | Teams support files, Call Analytics, Real-Time Analytics, CQD, network test results | Teams admin center, CQD, Microsoft 365 Network Connectivity Test |
| Meetings and Calls | [Meeting Join or Setup Failure](#meetings-and-calls-meeting-join-or-setup-failure) | User cannot join, call setup fails, lobby or meeting entry issue | Teams support files, meeting telemetry, Entra sign-in logs when auth-related | Teams admin center, Entra admin center |
| Teams Files | [File Upload, Open, Share, or Access Issue](#teams-files-file-upload-open-share-or-access-issue) | File fails to open, upload, download, share, or restore | Teams logs, browser trace or HAR, SharePoint/OneDrive context, audit data when needed | Teams client, browser DevTools, SharePoint admin center, Purview |
| Teams Mobile | [Mobile Client Issue](#teams-mobile-mobile-client-issue) | Mobile sign-in, calling, files, notifications, or app behavior issue | Mobile diagnostic logs submitted through Teams feedback | Teams mobile app, Microsoft 365 admin center |
| Teams Rooms | [Teams Rooms Device Issue](#teams-rooms-device-issue) | Room device issue, meeting join issue, device instability | Teams Rooms logs from Pro Management Portal or local PowerShell collection | Teams Rooms Pro Management Portal, PowerShell |
| VDI | [Teams in VDI Issue](#teams-in-vdi-issue) | Media optimization issue, fallback, VDI sign-in, VDI call quality | Teams logs, VDI optimization status, SlimCore or WebRTC context, endpoint logs | Teams client, VDI admin tools, Teams admin center |
| Tenant / Service | [Tenant-wide or Service Availability Impact](#tenant-wide-or-service-availability-impact) | Broad outage, widespread degradation, multiple users affected | Microsoft 365 Service health, Teams admin center reports, CQD trends | Microsoft 365 admin center, Teams admin center, CQD |
| Network | [Network, Firewall, Proxy, or VPN Issue](#network-firewall-proxy-or-vpn-issue) | UDP blocked, TCP fallback, high latency/jitter/loss, proxy impact | Network Connectivity Test, Teams Network Assessment Tool, CQD, Call Analytics | connectivity.m365.cloud.microsoft, Teams Network Assessment Tool, CQD |

***

# Detailed Scenarios

## Teams Desktop: Client Launch, Crash, or Performance Issue

**Symptoms**

Teams fails to start, crashes, hangs, becomes unresponsive, launches slowly, or repeatedly reports client-side errors.

**Logs to collect**

- Teams desktop support files. Two types of logs are automatically created upon request: MS Teams Support Log Files (media and signaling logs plus platform logs) and Weblogs (application event logs). Media and signaling logs are encrypted and can only be decrypted by Microsoft Support. Weblogs are text files and readable by any text editor. Weblog file names vary by environment: Public Enterprise = Prod-Weblogs, Public Consumer = Life-Weblogs, GCCH = GCCH-Weblogs, DOD = DOD-Weblogs.
- Windows Application and System event logs if the issue involves launch failure, crash, or OS-level dependency failure. For crashes, Windows records Event ID 1000 (application crash) and Event ID 1001 (Windows Error Reporting) in the Application log.
- Teams client health data from the Teams admin center, which surfaces client crashes, launch failures, and update failures.

**Log location and access instructions**

1. Reproduce the issue, then collect Teams support files immediately.
2. Windows: Select the Microsoft Teams icon in your system tray and then select **Collect support files**, or press **Ctrl + Alt + Shift + 1**.
3. Mac: Select the **Help** menu in Microsoft Teams and then select **Collect support files**, or press **Option + Command + Shift + 1**.
4. Wait until the banner showing **Downloading web logs** is dismissed from the Teams client before retrieving logs from the download location.
5. Both sets of logs are collected in the **Downloads** folder by default. The Prod-Weblogs will already be compressed, but the MS Teams Support Log Files need to be compressed before uploading to Microsoft Support.

**Files generated**

| File / Folder | Contents |
| ------------- | -------- |
| `Downloads\MSTeams Support Logs\` | Slimcore and media logs (encrypted, Microsoft Support only) |
| `Downloads\PROD-WebLogs-<timestamp>.zip` | Web diagnostic logs, including `diagnostics-logs.txt`, `calling-debug.txt`, `settings.json`, and cdl-worker logs |

**Key log files within the PROD-WebLogs archive**

| Filename | Usage |
| -------- | ----- |
| `diagnostics-logs.txt` | Client activity logs; best place to start unless investigating calling |
| `calling-debug.txt` | Calling debug logs with last disposed calls, meeting information, and network detection information |
| `settings.json` | All policy settings in use by the client |
| `cdl-worker-diagnostics-logs.txt` | Logs for the multi-window calling containers |

**Required tools**

Teams desktop client, Windows Explorer or Finder, Event Viewer, Teams admin center.

**Preconditions**

Issue is recent or reproducible. Capture the Teams version, OS version, client type, and exact timestamp.

**Extra guidance**

- For calling and meeting investigations, media and/or signaling (slimcore) logs are likely required.
- Through General Ring (R4), the web log limit is 11 MB across all web logs. Logging is subject to throttling at 2,000 log lines per minute. If log lines appear to be missing, search for `DiagnosticsService - skipped` in the diagnostic web logs. To prevent throttling in VDI and Rings > 4 (general), have the customer toggle on **Extended Logging** in Teams Privacy Settings.
- To preserve disk space, the size of log files for Microsoft Teams VDI clients is limited by default. If an issue is encountered on a VDI client, turn Extended Logging on in Teams Privacy settings before reproducing the issue and collecting logs.
- When multiple accounts are in use from a single client, the generated logs include diagnostic information for all logged-in accounts in Teams, regardless of tenant or cloud.

***

## Teams Desktop: Sign-in or Authentication Failure

**Symptoms**

Teams sign-in loop, repeated credential prompts, MFA prompt loop, Conditional Access block, guest tenant access failure, or sign-in error code (e.g., 0xCAA82EE7, 0xCAA82EE2, 0xCAA20004, 0xCAA70004, 0xCAA70007).

**Logs to collect**

- Teams support files.
- Microsoft Entra sign-in logs. Entra logs all sign-ins into a Microsoft Entra tenant. There are four types of sign-in logs: interactive user sign-ins, non-interactive user sign-ins, service principal sign-ins, and managed identity sign-ins. To view them, sign in to the Microsoft Entra admin center as at least a Reports Reader and browse to **Entra ID > Monitoring & health > Sign-in logs**.
- Teams Sign-in diagnostic output from the Microsoft 365 admin center. The Teams Sign-in diagnostic requires a Microsoft 365 administrator account and is not available for Microsoft 365 Government, Microsoft 365 operated by 21Vianet, or Microsoft 365 Germany.

**Log location and access instructions**

1. Capture the exact error code and timestamp from the Teams sign-in screen.
2. Run the **Teams Sign-in diagnostic**: select **Run Tests: Teams Sign-in** from the Microsoft 365 admin center, enter the email address of the affected user, and select **Run Tests**.
3. Run the **Microsoft Remote Connectivity Analyzer** diagnostic: open a web browser, go to the Teams Sign-in test at `https://testconnectivity.microsoft.com/tests/TeamsSignin/input`, sign in with the affected user's credentials, enter the verification code, and select **Verify**.
4. Export Entra sign-in logs for the affected user and timestamp window (CSV or JSON download from the Entra admin center).
5. Collect Teams support files immediately after reproducing the sign-in failure.

**Required tools**

Teams client, Microsoft 365 admin center, Microsoft Entra admin center, browser DevTools (if web sign-in also fails).

**Preconditions**

Affected user, tenant, client type, and sign-in error are known.

**Extra guidance**

- For error code **0xCAA82EE7** or **0xCAA82EE2**, ensure the user has Internet access, then use the Network Assessment Tool to verify network and network elements between the user location and the Microsoft network are configured correctly.
- For error code **0xCAA20004**, this occurs if an issue affects conditional access.
- If the error persists after diagnostics and client update, reinstall Teams: uninstall Teams, browse to `%appdata%\Microsoft` and delete the Teams folder, then download and install Teams.
- When opening a support request, collect debug logs and provide the error code displayed on the Teams sign-in screen.
- Compare Teams desktop and Teams web. If Teams web works but desktop fails, focus on client cache, WebView2, local device policy, or authentication state. If both fail, broaden to identity, Conditional Access, licensing, tenant policy, network, or service health.

***

## Teams Web: Browser or Web Client Issue

**Symptoms**

Issue reproduces in Teams web, or only a browser session fails.

**Logs to collect**

- Browser trace or HAR (captured via browser DevTools). A browser trace can provide important details about the state of the Teams client when the error occurs.
- Browser console output.
- WebRTC logs for browser-based audio or video issues.

**Log location and access instructions**

1. Sign in to Teams before starting the browser trace so the trace does not include sensitive sign-in information.
2. Open DevTools (F12) and begin recording network and console activity.
3. Reproduce the issue once.
4. Export the HAR and console output.
5. For media issues, open a new tab and navigate to:
   - Microsoft Edge (Chromium): `edge://webrtc-internals/`
   - Chrome: `chrome://webrtc-internals/`
6. Open the Teams Web application and reproduce the problem. Return to the WebRTC internals tab, choose the tab with the Teams application name, and save the page content.

**Required tools**

Microsoft Edge or Chrome, browser DevTools.

**Preconditions**

Issue reproduces in Teams web or a browser-based Teams component.

**Extra guidance**

Use Teams desktop logs for desktop-only issues. Use browser traces when the failure is in Teams web, embedded web content, authentication redirects, or file access in browser. For Teams Web log collection, use the keyboard shortcut (Ctrl + Alt + Shift + 1) since the system tray method is not available.

***

## Meetings and Calls: Poor Meeting or Call Quality

**Symptoms**

Choppy audio, robotic audio, frozen video, dropped meeting, screen sharing delay, high latency, jitter, packet loss, or user reports of poor call quality.

**Logs to collect**

- Teams support files, including media and signaling logs.
- Teams admin center meeting/call troubleshooting data. Three interconnected views are provided: User view (meeting history with weekly quality and activity trends), Meeting view (participant summaries, issue trends, and suggested root cause analysis), and Participant view (session-level telemetry and diagnostics).
- CQD data for trends and network/location analysis.
- Microsoft 365 Network Connectivity Test results.

**Log location and access instructions**

1. Record meeting ID, organizer, affected user, affected modality (audio/video/screenshare), and exact impact window.
2. Collect Teams support files immediately after the issue or during the repro.
3. In Teams admin center, go to **Manage users**, select the affected user, open the **Meetings & calls** tab, and select the relevant meeting or call. Completed meeting telemetry can take from 30 minutes to 2 hours to process after the meeting ends; in-progress meetings can be reviewed while live.
4. For each issue in the meeting view, review the issue type and description (Audio, Video, Screenshare, or Other), the participants affected, and possible root cause and recommended actions. Root cause areas include Network, Compute, Device, and Media.
5. Run the Microsoft 365 Network Connectivity Test from the affected network at `https://connectivity.m365.cloud.microsoft`.

**Quality thresholds (Microsoft 365 Network Connectivity Test)**

| Metric | Threshold |
| ------ | --------- |
| UDP packet loss | Lower than 1.00% |
| UDP latency | Lower than 100 ms |
| UDP jitter | Lower than 30 ms |

**Required tools**

Teams client, Teams admin center, CQD, Microsoft 365 Network Connectivity Test.

**Preconditions**

Meeting or call is identifiable, and the affected user/session is known.

**Extra guidance**

- Real-time telemetry is available for users with Teams Premium license for seven days after the meeting ends. For all other users, real-time telemetry is retained for the duration of the meeting. Aggregated telemetry is available for all users for 30 days after the meeting ends.
- Quality is judged using intelligent media classifiers (machine learning models trained on Teams call telemetry) to identify if users experienced noticeable media degradation.
- If UDP is blocked, Teams might still work using TCP, but audio and video will be impaired.

***

## Meetings and Calls: Meeting Join or Setup Failure

**Symptoms**

User cannot join, meeting hangs on join, call setup fails, or participant never fully enters the meeting.

**Logs to collect**

- Teams support files.
- Teams admin center meeting/call troubleshooting details.
- Entra sign-in logs when the issue involves authentication, MFA, Conditional Access, or guest access.
- Network Connectivity Test if error codes suggest connectivity or Teams media path issues.

**Log location and access instructions**

1. Capture meeting ID, user, timestamp, client, error text, and whether web or mobile can join.
2. Collect Teams support files immediately after the failed join.
3. Review Teams admin center meeting/call details for the user and meeting. The In-progress meetings table lists all meetings currently taking place across the tenant; use this to identify and respond to active quality issues in real time.
4. Export Entra sign-in logs if the join failure includes authentication prompts or policy blocks.

**Required tools**

Teams client, Teams admin center, Entra admin center, browser.

**Preconditions**

Affected meeting and user are known.

**Extra guidance**

Compare desktop, web, and mobile when possible. If only one client fails, focus on client-specific logs. If all clients fail, focus on meeting policy, identity, service health, tenant configuration, or network.

***

## Teams Files: File Upload, Open, Share, or Access Issue

**Symptoms**

File fails to upload, open, preview, download, share, restore, or access differs between users.

**Logs to collect**

- Teams desktop support files or browser HAR, depending on client.
- SharePoint or OneDrive file URL and storage context.
- Cross-client validation: Teams desktop, Teams web, and direct SharePoint or OneDrive access.
- Purview audit logs when file, team, channel, or sharing activity must be investigated.

**Log location and access instructions**

1. Identify where the file was shared:
   - Files uploaded to a channel are stored in the team's SharePoint folder. These files are available in the Shared tab at the top of each channel.
   - Files sent in chat are stored in the sender's OneDrive for Business and only shared with the people in that conversation.
2. Reproduce in Teams desktop and Teams web.
3. Test direct access in SharePoint or OneDrive. Since all Teams files are stored in SharePoint or OneDrive, SharePoint permissions are the real gatekeeper for who can see, edit, or share files.
4. If web reproduces, capture HAR and console output.
5. If desktop-only, collect Teams support files.

**Required tools**

Teams client, browser DevTools, SharePoint or OneDrive admin experience, Microsoft Purview.

**Preconditions**

File location (channel vs. chat), affected user, and exact action are known.

**Extra guidance**

- Permissions validation approach: if some users can access, validate permissions or sharing; if no users can access, validate content availability or service access; if web works but desktop fails, validate client or authentication signals.
- For guest file access issues, check Microsoft Entra external collaboration settings, Microsoft 365 Groups guest access settings, and SharePoint/OneDrive sharing settings in addition to team membership.
- File recovery: deleted items are retained in SharePoint recycle bins for 93 days. When an item is restored, it is restored to the same location from which it was deleted.

***

## Teams Mobile: Mobile Client Issue

**Symptoms**

Teams mobile sign-in, chat, files, calling, meeting, notification, or app behavior issue.

**Logs to collect**

- Teams mobile diagnostic logs.
- Device model, OS version, Teams app version, network type, and whether the device is managed.

**Log location and access instructions**

1. In Teams mobile, tap profile picture > **Settings** > **Help and feedback** > **Send feedback** > enable the toggle for **Attach logs to help troubleshoot**.
2. Reproduce the issue and submit feedback with a description, the case number, and the timestamp.
3. Record the exact submission time, user, device OS, Teams mobile version, and issue description.

**Required tools**

Teams mobile app, Microsoft 365 admin center.

**Preconditions**

User can submit feedback and log collection is allowed by policy.

**Extra guidance**

- Logs are typically free of personal data, however some error types may cause user names or email addresses to be logged.
- Starting Sep-T1 (5.17.0), slimcore log collection enablement is on by default for mobile and will be uploaded to OCV.
- Scope the issue first: how many users impacted, which platform, what feature, what network, what app version, whether the device is managed, and whether the issue reproduces elsewhere. Compare mobile vs desktop vs web, and Wi-Fi vs cellular.

***

## Teams Rooms: Device Issue

**Symptoms**

Teams Rooms device fails to join meetings, has audio/video device issues, reports instability, or needs device-level troubleshooting.

**Logs to collect**

- Teams Rooms logs from Pro Management Portal or local log collection script.
- Device details, Teams Rooms app version, Windows version, peripherals, and impact window.

**Log location and access instructions**

1. Pro Management Portal: Go to **Rooms**, select the display name of the device you want logs for. In the actions panel, select **Log Collection** and select **Run**. Once you confirm the desired logs, the logs will be ready for download in the Activity tab after a few minutes.
2. Local PowerShell collection: In Admin mode, start an elevated command prompt, and issue the following command:

```powershell
powershell -ExecutionPolicy unrestricted c:\rigel\x64\scripts\provisioning\ScriptLaunch.ps1 CollectSrsV2Logs.ps1
```

The logs are output as a ZIP file in `c:\rigel`.

3. Remote PowerShell collection:

```powershell
$targetDevice = "<Device fqdn>"
$logFile = Invoke-Command -ComputerName $targetDevice -ScriptBlock {
    $output = powershell.exe -ExecutionPolicy Bypass -File C:\Rigel\x64\Scripts\Provisioning\ScriptLaunch.ps1 CollectSrsV2Logs.ps1
    Get-ChildItem -Path C:\Rigel\*.zip | Sort-Object -Descending -Property LastWriteTime | Select-Object -First 1
}
$session = New-PSSession -ComputerName $targetDevice
Copy-Item -Path $logFile.FullName -Destination .\ -FromSession $session
Invoke-Command -ComputerName $targetDevice -ScriptBlock { Remove-Item -Force C:\Rigel\*.zip }
```

**Required tools**

Teams Rooms Pro Management Portal or local admin access and PowerShell.

**Preconditions**

Device identity and impacted meeting or timeframe are known.

**Extra guidance**

- Downloaded logs on the device can take up disk space. If logs are not regularly cleaned up, they can interfere with the normal functionality of the room. Teams Rooms deletes downloaded logs after 30 days. IT admins can override the log cleanup using the device registry setting `HKLM\SOFTWARE\Microsoft\PPI\SkypeSettings\LogCleanupAgeThreshold`.
- Cache clearing is also available through the Pro Management Portal: go to Rooms, select the device, select **Restart device - Clear cache**, select **Run**, check **Delete Teams cache?**, and select **Run**.

***

## Teams in VDI Issue

**Symptoms**

VDI Teams call quality issue, optimization missing, fallback mode, VDI sign-in problem, media issue, or endpoint plugin/SlimCore problem.

**Logs to collect**

- Teams support files from the VDI session.
- `Vdi_debug.txt` (main file for VDI-related information, found inside the PROD-WebLogs archive under the Core folder).
- VM Application event logs (filter by Source **Microsoft Teams VDI** and Event ID **0** under Windows Logs\Application).
- VDI endpoint, plugin, and client details.

**Log location and access instructions**

1. Confirm optimization status. In the Teams client, check the VDI Status Indicator (top left in the UI), or select the ellipsis (...) and then **Settings > About**. Values: "AVD SlimCore Media Optimized" indicates the new optimization based on SlimCore; "AVD Media Optimized" indicates optimization based on WebRTC.
2. While running Teams on the VM, press **Ctrl + Alt + Shift + 1**. This produces a ZIP folder in the Downloads folder. Inside `PROD-WebLogs-*.zip`, look for the Core folder and `Vdi_debug.txt`.
3. `Vdi_debug.txt` contains `vdiConnectedState` (shows current active calling stack: `connectedStack: remote` = connected through virtual channel; `connectedStack: local` = fallback mode) and `vdiVersionInfo` (bridge version, remote slimcore version, nodeId, client OS version, RD client version, plugin version).
4. For VDI clients, media logs are only available for the new SlimCore-based VDI solution. For Teams on VDI using legacy WebRTC-based media optimization, contact your VDI provider for instructions on gathering and interpreting media logs.
5. If VDI log size is limited, enable Extended Logging in Teams Privacy settings before repro, then collect logs.

**Required tools**

Teams client in VM, VDI admin tooling, Event Viewer, Teams admin center, endpoint access.

**Preconditions**

VDI platform (AVD/W365/Citrix/Omnissa/Amazon), endpoint OS, Teams version, optimization mode (SlimCore vs. WebRTC vs. fallback), and issue scenario are known.

**Extra guidance**

- Error codes **2000** ("No Plugin") and **2003** ("Virtual Channel not allowed") are the most likely causes when SlimCore optimization does not load. Make sure the Virtual Channel Allow list policy in Citrix Studio allows MSTEAMS, MSTEAM1, MSTEAM2. Make sure the endpoint has the plugin loaded.
- Error code **1260** / deploy error **10083** (`ERROR_ACCESS_DISABLED_BY_POLICY`) usually means Windows Package Manager cannot install the SlimCore MSIX package. AppLocker policies can cause this. Add an exception for SlimCoreVdi packages.
- Error code **3000** / deploy error **24002** (`SlimCore Deployment not needed`) is not an error; this is a good indicator the user is on the new optimization architecture with SlimCore.
- On the endpoint, use PowerShell to verify the SlimCore MSIX package:

```powershell
Get-AppxPackage Microsoft.Teams.SlimCore*
```

***

## Tenant-wide or Service Availability Impact

**Symptoms**

Multiple users, multiple networks, or broad tenant symptoms affect Teams.

**Logs to collect**

- Microsoft 365 Service health incident or advisory details.
- Teams admin center reports.
- CQD trend data.
- Customer impact timeline.

**Log location and access instructions**

1. Check Microsoft 365 admin center > **Health > Service health**. If you are experiencing problems with a cloud service, check the service health to determine whether this is a known issue with a resolution in progress before you call support or spend time troubleshooting.
2. If unable to sign in to the admin center, use the service status page at `https://status.cloud.microsoft`.
3. Capture incident ID, affected services, issue type (incident or advisory), status, estimated start time, and user impact from the Service health detail page.
4. If you are experiencing an issue with a Microsoft 365 service and do not see it listed on the Service health page, select **Report an issue** and complete the short form.
5. Use CQD and Teams admin center to validate whether symptoms are tenant-wide, network-specific, or user-specific.

**Required tools**

Microsoft 365 admin center, Teams admin center, CQD.

**Preconditions**

Impact scope and timeframe are known.

**Extra guidance**

- Service health status definitions: Investigating (gathering more information), Service degradation (issue confirmed, may affect use), Service interruption (significant issue, affects ability to access), Restoring service (cause identified, corrective action in progress), Service restored (corrective action resolved the problem).
- Sign up for email notifications of new incidents that affect your tenant and status changes for active incidents by selecting **Customize > Email** in the Service health page.

***

## Network, Firewall, Proxy, or VPN Issue

**Symptoms**

Poor call quality, failed meeting setup, TCP fallback, blocked media, proxy inspection, high latency, packet loss, jitter, or VPN-related degradation.

**Logs to collect**

- Microsoft 365 Network Connectivity Test report.
- Teams Network Assessment Tool output.
- Teams support files for affected client.
- CQD and Teams admin center telemetry.

**Log location and access instructions**

1. Microsoft 365 Network Connectivity Test: Run from the affected location at `https://connectivity.m365.cloud.microsoft`. The test checks Teams media connectivity including UDP connectivity, packet loss, latency, and jitter. Sign in to your Microsoft 365 tenant so test reports are shared with your administrator and uploaded to the tenant.
2. Teams Network Assessment Tool: Download from the Official Microsoft Download Center. The tool tests connectivity to various Teams servers deployed in the Microsoft Azure network. It collects and outputs loss, jitter, and round trip time during packet exchange. Install location is `%ProgramFiles (x86)%\Microsoft Teams Network Assessment Tool`, and the tool itself is `NetworkAssessmentTool.exe`.
3. Collect Teams support files from a failing client during the same repro window.

**Required tools**

Microsoft 365 Network Connectivity Test, Teams Network Assessment Tool, CQD, Teams admin center.

**Preconditions**

Affected location, network type, VPN/proxy status, and issue timeframe are known.

**Extra guidance**

- If UDP is blocked, Teams might still work using TCP, but audio and video will be impaired. UDP is preferred for real-time media.
- Capture whether the user is on wired, Wi-Fi, VPN, split tunnel, proxy, or SSL inspection.
- Compare results from a known-good location or network.
- Firewall configuration: verify that Microsoft 365 IP ports and addresses are excluded from the firewall. For media-related TCP issues, verify that client media subnets `13.107.64.0/18` and `52.112.0.0/14` are in firewall rules, and that UDP ports 3478-3481 are opened.

***

# Remote Teams Client Log Collection from Teams Admin Center

Use remote collection when user-driven log collection is impractical or when support needs logs from Windows or Mac Teams clients without interrupting the user.

**What it collects**

Remote log collection supports the following log types:

1. Web logs: diagnostics logs, calling logs, central data layer logs, Web Media log.
2. Desktop logs: Shell Diagnostics logs, SlimCore logs including media stack logs.

Procmon traces and OS Event Logs are not collected because they require elevated user access.

**Steps**

1. Go to Teams admin center > **Users** tab > **Manage users**. Navigate to the specific user page.
2. On the user page, the **Client health** tab provides information about client health for all client versions that user is running.
3. Choose the client and version you want to collect diagnostic logs from and select **Request client logs**.
4. Once log collection is started, the **Client log status** column will be set to **Pending**.
5. Once log collection is complete, download and share the logs with your team or Microsoft.
6. To view the status for all logs collected within your tenant, select **View client logs** from the Teams client health page.

**Important notes**

- This feature is currently supported for Windows (non-VDI) and Mac Applications only.
- Accessible to the following roles: Global Administrator, Teams Administrator, Teams Communications Support Engineer, and Teams Communications Support Specialist.
- Logs are stored for 30 days in a Microsoft secure and compliant storage location.
- User consent is not required, and no prompt or message is shown to users when logs are collected.
- Provided the Teams client is running, logs may take up to 8 hours before they are fully available for download in Teams admin center.
- Client log collection is not supported on devices that have both commercial and government cloud accounts added simultaneously to the Teams client.
- Log collection may fail if the user's device is offline. The request will be queued until the device is back online, with a maximum period of 3 days.

***

# Collecting Windows Diagnostic Logs

Windows diagnostic logs (Event Viewer, MSInfo32, DXDiag) can be requested from the customer and uploaded to the case for analysis. Open Command Prompt and run:

```cmd
REM Export Event Viewer logs
wevtutil epl Application %userprofile%\downloads\Application.evtx
wevtutil epl System %userprofile%\downloads\System.evtx

REM Export Msinfo32
Msinfo32 /nfo %userprofile%\downloads\report.nfo

REM Export running tasks
tasklist /m > %userprofile%\downloads\tasklistoutput.txt

REM Export dxdiag
dxdiag /t "%userprofile%\downloads\dxdiag.txt"
```

Request the customer compress the output files from the Downloads folder and upload to the case secure file exchange portal. These files are useful to check for application errors, system and networking errors, driver versions, installed third-party software, running processes, computer hardware, and Windows OS version.

***

# Public References (Microsoft)

- Collect Teams client diagnostic logs: `https://learn.microsoft.com/en-us/microsoftteams/log-files`
- Teams client diagnostic logging in Teams admin center (remote collection): `https://learn.microsoft.com/en-us/microsoftteams/teams-client-diagnostic-logging`
- Browser logs and tracing for Teams: `https://learn.microsoft.com/en-us/microsoftteams/browser-logs-and-tracing-for-teams`
- Monitor and troubleshoot Teams meetings and calls from the Teams admin center: `https://learn.microsoft.com/en-us/microsoftteams/monitor-troubleshoot-teams-meetings-calls`
- Microsoft 365 Network Connectivity Test: `https://connectivity.m365.cloud.microsoft`
- Microsoft Teams Network Assessment Tool: `https://www.microsoft.com/en-us/download/details.aspx?id=103017`
- Microsoft 365 network connectivity test tool documentation: `https://learn.microsoft.com/en-us/microsoft-365/enterprise/office-365-network-mac-perf-onboarding-tool`
- Resolve Teams sign-in errors: `https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-sign-in/resolve-sign-in-errors`
- File storage in Microsoft Teams: `https://support.microsoft.com/en-us/teams/files/file-storage-in-microsoft-teams`
- Send diagnostic log files from Teams mobile app: `https://support.microsoft.com/en-us/teams/platform/send-diagnostic-log-files-from-microsoft-teams-mobile-app`
- Microsoft Teams Rooms maintenance and operations: `https://learn.microsoft.com/en-us/microsoftteams/rooms/rooms-operations`
- Troubleshooting the VDI 2.0 solution for Teams: `https://learn.microsoft.com/en-us/microsoftteams/vdi-2-troubleshooting`
- New VDI solution for Teams (SlimCore): `https://learn.microsoft.com/en-us/microsoftteams/vdi-2`
- Check Microsoft 365 service health: `https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health`
- Microsoft Entra sign-in logs: `https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins`
- Microsoft Teams Connectivity Test: `https://testconnectivity.microsoft.com/tests/teams`
