Log Collection Guidelines: Microsoft Teams Troubleshooting

This guide standardizes log collection for common Microsoft Teams troubleshooting scenarios across desktop, web, mobile, Teams Rooms, VDI, meetings, calling, files, identity, network, and tenant-level service health.

How to use this guide

Start with the Log Collection Matrix to identify the best matching scenario.
Jump to the linked detailed scenario subsection for exact log locations, access instructions, required tools, preconditions, and extra guidance.
Collect logs immediately after a clear reproduction of the issue and keep all diagnostics tied to the same repro window. When collecting multiple logs and diagnostics, it is very important that you collect all from the same repro.
Record the exact local timestamp, time zone, affected user, client type, client version, network location, and repro steps. Times in logs are recorded in Coordinated Universal Time (UTC); when opening a support case, inform the support agent of the time difference between the local time the issue occurred and UTC time.
Log Collection Matrix
Affected Component	Subsection Link	Symptom	Logs / Data to Collect	Required ToolsTeams Desktop	Client Launch, Crash, or Performance Issue	Teams fails to launch, crashes, hangs, or is slow	Teams support files, Windows Event Viewer logs, client health data	Teams client, Windows Explorer, Event Viewer, Teams admin center
Teams Desktop	Sign-in or Authentication Failure	Sign-in loop, credential prompt, MFA or Conditional Access block	Teams support files, Entra sign-in logs, Teams Sign-in diagnostic output	Teams client, Microsoft Entra admin center, Microsoft 365 admin center
Teams Web	Teams Web or Browser Reproduction	Issue reproduces only in browser or Teams web	Browser trace, HAR, console output, WebRTC logs for media issues	Edge or Chrome DevTools, browser WebRTC internals
Meetings & Calls	Poor Meeting or Call Quality	Choppy audio, frozen video, dropped call, poor screen sharing	Teams support files, Call Analytics, Real-Time Analytics, CQD, network test results	Teams admin center, CQD, Microsoft 365 Network Connectivity Test
Meetings & Calls	Meeting Join or Setup Failure	User cannot join, call setup fails, lobby or meeting entry issue	Teams support files, meeting telemetry, Entra sign-in logs when auth-related	Teams admin center, Entra admin center
Teams Files	File Upload, Open, Share, or Access Issue	File fails to open, upload, download, share, or restore	Teams logs, browser trace or HAR, SharePoint/OneDrive context, audit data when needed	Teams client, browser DevTools, SharePoint admin center, Purview
Teams Mobile	Mobile Client Issue	Mobile sign-in, calling, files, notifications, or app behavior issue	Mobile diagnostic logs submitted through Teams feedback, Product feedback download	Teams mobile app, Microsoft 365 admin center
Teams Rooms	Teams Rooms Device Issue	Room device issue, meeting join issue, device instability	Teams Rooms logs from Pro Management Portal or local PowerShell collection	Teams Rooms Pro Management Portal, PowerShell
VDI	Teams in VDI Issue	Media optimization issue, fallback, VDI sign-in, VDI call quality	Teams logs, VDI optimization status, SlimCore or WebRTC context, endpoint logs	Teams client, VDI admin tools, Teams admin center
Tenant / Service	Tenant-wide or Service Availability Impact	Broad outage, widespread degradation, multiple users affected	Microsoft 365 Service health, Teams admin center reports, CQD trends	Microsoft 365 admin center, Teams admin center, CQD
Admin / Policy	Teams Policy, Configuration, or Audit Investigation	Unexpected policy behavior, team/channel changes, external access changes	Teams audit logs, policy screenshots/exports, affected user policy assignment	Microsoft Purview, Teams admin center
Network	Network, Firewall, Proxy, or VPN Issue	UDP blocked, TCP fallback, high latency/jitter/loss, proxy impact	Network Connectivity Test, Teams Network Assessment Tool, CQD, Call Analytics	connectivity.m365.cloud.microsoft, Teams Network Assessment Tool, CQD
Detailed Scenarios
Teams Desktop: Client Launch, Crash, or Performance Issue

Symptoms

Teams fails to start, crashes, hangs, becomes unresponsive, launches slowly, or repeatedly reports client-side errors.

Logs to collect

Teams desktop support files. There are two types of logs that are automatically created upon request: MS Teams Support Log Files, which contain media and signaling logs in addition to platform logs, and Weblogs, which contain application event logs. Media and signaling logs are encrypted and can only be decrypted by Microsoft Support; Weblogs are text files and readable by any text editor. Weblog file names vary by environment: Public Enterprise = Prod-Weblogs, GCCH = GCCH-Weblogs, DOD = DOD-Weblogs.
Windows Application and System event logs if the issue involves launch failure, crash, or OS-level dependency failure.
Teams client health data. The Teams client health dashboard in the Teams admin center surfaces client crashes, launch failures, and update failures with 7-day and 28-day trend data for all devices in the tenant.

Log location and access instructions

Reproduce the issue, then collect Teams support files immediately.
Windows: Select the Microsoft Teams icon in your system tray and then select Collect support files, or press Ctrl + Alt + Shift + 1.
Mac: Select the Help menu in Microsoft Teams and then select Collect support files, or press Option + Command + Shift + 1.
Wait until the banner showing Downloading web logs is dismissed from the Teams client before retrieving logs from the download location.
Both sets of logs are collected in the Downloads folder by default. The Prod-Weblogs will already be compressed, but the MS Teams Support Log Files need to be compressed before uploading to Microsoft Support.

Files generated

Two sets of files are created:

File / Folder	ContentsDownloads\MSTeams Support Logs\	Slimcore and media logs (encrypted, Microsoft Support only)
Downloads\PROD-WebLogs-<timestamp>.zip	Web diagnostic logs, including per-user diagnostics-logs.txt, calling-debug.txt, settings.json, and cdl-worker logs

Key log files within the PROD-WebLogs archive include diagnostics-logs.txt (client activity logs, best place to start unless investigating calling), calling-debug.txt (calling debug logs with last disposed calls, meeting information, and network detection information), and settings.json (all policy settings in use by the client).

Media stack logs and slimcore logs are different logs; both are collected when media logging is enabled. Slimcore logs show device-level info (camera, mics) and lower-level rendering details. Slimcore logs roll over with latest events in the -0 logfiles, and three copies are kept.

Required tools

Teams desktop client, Windows Explorer or Finder, Event Viewer, Teams admin center.

Preconditions

Issue is recent or reproducible. Capture the Teams version, OS version, client type, and exact timestamp.

Extra guidance

For calling and meeting investigations, media and/or signaling (slimcore logs) are likely required.
Through General Ring (R4), the web log limit is 11 MB across all web logs. Logging is subject to throttling at 2,000 log lines per minute. If log lines appear to be missing, search for DiagnosticsService - skipped in the diagnostic web logs. To prevent throttling in VDI and Rings > 4 (general), have the customer toggle on Extended Logging in Teams Privacy Settings.
To preserve disk space, the size of log files for Microsoft Teams Virtual Desktop (VDI) clients is limited by default. If an issue is encountered on a VDI client, turn Extended Logging on in Teams Privacy settings before reproducing the issue and collecting logs.
Teams Desktop: Sign-in or Authentication Failure

Symptoms

Teams sign-in loop, repeated credential prompts, MFA prompt loop, Conditional Access block, guest tenant access failure, or sign-in error code (e.g., 0xCAA82EE7, 0xCAA82EE2, 0xCAA20004, 0xCAA70004, 0xCAA70007).

Logs to collect

Teams support files (collected as described above).
Microsoft Entra sign-in logs. Microsoft Entra logs all sign-ins into a Microsoft Entra tenant. There are four types of sign-in logs: interactive user sign-ins, non-interactive user sign-ins, service principal sign-ins, and managed identity sign-ins. To view them, sign in to the Microsoft Entra admin center as at least a Reports Reader and browse to Entra ID > Monitoring & health > Sign-in logs.
Teams Sign-in diagnostic output from Microsoft 365 admin center. The Teams Sign-in diagnostic requires a Microsoft 365 administrator account and is not available for Microsoft 365 Government, Microsoft 365 operated by 21Vianet, or Microsoft 365 Germany.

Log location and access instructions

Capture the exact error code and timestamp from the Teams sign-in screen.
Run the Teams Sign-in diagnostic: select Run Tests: Teams Sign-in from the Microsoft 365 admin center, enter the email address of the affected user, and select Run Tests.
Run the Microsoft Remote Connectivity Analyzer diagnostic: open a web browser, go to the Teams Sign-in test at https://testconnectivity.microsoft.com/tests/TeamsSignin/input, sign in with the affected user's credentials, enter the verification code, and select Verify.
Export Entra sign-in logs for the affected user and timestamp window (CSV or JSON download from the Entra admin center).
Collect Teams support files immediately after reproducing the sign-in failure.

Required tools

Teams client, Microsoft 365 admin center, Microsoft Entra admin center, browser DevTools (if web sign-in also fails).

Preconditions

Affected user, tenant, client type, and sign-in error are known.

Extra guidance

For error code 0xCAA82EE7 or 0xCAA82EE2, ensure the user has Internet access, then use the Network Assessment Tool to verify that the network and network elements between the user location and the Microsoft network are configured correctly.
For error code 0xCAA20004, this occurs if an issue affects conditional access.
If the error persists after diagnostics and client update, reinstall Teams: uninstall Teams, browse to %appdata%\Microsoft and delete the Teams folder, then download and install Teams.
When opening a support request, collect debug logs and provide the error code displayed on the Teams sign-in screen.
Teams Web or Browser Reproduction

Symptoms

Issue reproduces in Teams web, or only a browser session fails.

Logs to collect

Browser trace or HAR (captured via browser DevTools).
Browser console output.
WebRTC logs for browser-based audio or video issues. For some categories of errors, Microsoft Support might require you to collect a browser trace; a browser trace can provide important details about the state of the Teams client when the error occurs.

Log location and access instructions

Sign in to Teams before starting the browser trace so the trace does not include sensitive sign-in information.
Open DevTools (F12) and begin recording network and console activity.
Reproduce the issue once.
Export the HAR and console output.
For media issues, open a new tab and navigate to:
Microsoft Edge (Chromium): edge://webrtc-internals/
Chrome: chrome://webrtc-internals/
Open the Teams Web application and reproduce the problem. Go back to the WebRTC internals tab — you will see at least two tabs including https://teams.microsoft.com/url. Choose the tab with the Teams application name and save the page content.

Required tools

Microsoft Edge or Chrome, browser DevTools.

Preconditions

Issue reproduces in Teams web or a browser-based Teams component.

Extra guidance

Use Teams desktop logs for desktop-only issues. Use browser traces when the failure is in Teams web, embedded web content, authentication redirects, or file access in browser. For Teams Web log collection, use the keyboard shortcut (Ctrl + Alt + Shift + 1) since the system tray method is not available.

Meetings and Calls: Poor Meeting or Call Quality

Symptoms

Choppy audio, robotic audio, frozen video, dropped meeting, screen sharing delay, high latency, jitter, packet loss, or user reports of poor call quality.

Logs to collect

Teams support files, including media and signaling logs.
Teams admin center meeting/call troubleshooting data. The meeting troubleshooting experience provides three interconnected views: User view (meeting history with weekly quality and activity trends), Meeting view (participant summaries, issue trends, and suggested root cause analysis), and Participant view (session-level telemetry and diagnostics).
CQD data for trends and network/location analysis. CQD is designed to help Teams admins and network engineers optimize the network and keep a close eye on quality, reliability, and the user experience; it looks at aggregate telemetry for an entire organization.
Microsoft 365 Network Connectivity Test results. The tool tests Teams media connectivity (UDP), packet loss, latency, jitter, and shows whether the connection meets quality thresholds: UDP packet loss should be lower than 1.00%, UDP latency should be lower than 100ms, and UDP jitter should be lower than 30ms.

Log location and access instructions

Record meeting ID, organizer, affected user, affected modality (audio/video/screenshare), and exact impact window.
Collect Teams support files immediately after the issue or during the repro.
In Teams admin center, go to Manage users, select the affected user, open the Meetings & calls tab, and select the relevant meeting or call. Completed meeting telemetry can take from 30 minutes to 2 hours to process after the meeting ends; in-progress meetings can be reviewed while live.
For each issue in the meeting view, review: the issue type and description (categorized as Audio, Video, Screenshare, or Other), the participants affected, and possible root cause and recommended actions. Root cause areas include Network, Compute, Device, and Media.
Use CQD for broader trend analysis across buildings, subnets, networks, devices, clients, VPN, proxy, and TCP/UDP patterns. Two curated CQD templates are available for download at https://aka.ms/QERtemplates.
Run the Microsoft 365 Network Connectivity Test from the affected network at https://connectivity.m365.cloud.microsoft.

Required tools

Teams client, Teams admin center, CQD, Microsoft 365 Network Connectivity Test.

Preconditions

Meeting or call is identifiable, and the affected user/session is known.

Extra guidance

Real-time telemetry is available for users with Teams Premium license for seven days after the meeting ends. For all other users, real-time telemetry is retained for the duration of the meeting. Aggregated telemetry is available for all users for 30 days after the meeting ends.
Quality is now judged using intelligent media classifiers, which are a set of machine learning models trained on Teams call telemetry to accurately identify if users experienced noticeable media degradation.
CQD is useful for trends but does not always provide a specific cause for a given scenario; it will call out areas for further investigation based on trends.
Audio poor quality thresholds in CQD: Jitter >30 ms, Packet loss rate >10% (0.1), Round-trip time >500 ms.
Most user quality problems can be grouped into: incomplete firewall or proxy configuration, poor Wi-Fi coverage, insufficient bandwidth, VPN, inconsistent or outdated client versions and drivers, unoptimized or built-in audio devices, problematic subnets or network devices.
Meetings and Calls: Meeting Join or Setup Failure

Symptoms

User cannot join, meeting hangs on join, call setup fails, or participant never fully enters the meeting.

Logs to collect

Teams support files.
Teams admin center meeting/call troubleshooting details.
Entra sign-in logs when the issue involves authentication, MFA, Conditional Access, or guest access.
Network Connectivity Test if error codes suggest connectivity or Teams media path issues.

Log location and access instructions

Capture meeting ID, user, timestamp, client, error text, and whether web or mobile can join.
Collect Teams support files immediately after the failed join.
Review Teams admin center meeting/call details for the user and meeting. The In-progress meetings table lists all meetings currently taking place across the tenant; use this to identify and respond to active quality issues in real time.
Export Entra sign-in logs if the join failure includes authentication prompts or policy blocks.

Required tools

Teams client, Teams admin center, Entra admin center, browser.

Preconditions

Affected meeting and user are known.

Extra guidance

The setup failure rate represents any media stream that could not be established; given the severity of the impact on user experience, the goal is to reduce this value to as close to zero as possible.
The most common cause of setup failures is Missing FW Deep Packet Inspection Exemption Rule (network equipment prevented the media path from being established due to deep packet inspection rules) or Missing FW IP Block Exception Rule (network equipment prevented the media path from being established to the Microsoft 365 network).
Teams Files: Upload, Open, Share, or Access Issue

Symptoms

File fails to upload, open, preview, download, share, restore, or access differs between users.

Logs to collect

Teams desktop support files or browser HAR, depending on client.
SharePoint or OneDrive file URL and storage context.
Cross-client validation: Teams desktop, Teams web, and direct SharePoint or OneDrive access.
Purview audit logs when file, team, channel, or sharing activity must be investigated.

Log location and access instructions

Identify where the file was shared:
Files uploaded to a channel are stored in the team's SharePoint folder. These files are available in the Shared tab at the top of each channel.
Files sent in chat are stored in the sender's OneDrive for Business and only shared with the people in that conversation.
Reproduce in Teams desktop and Teams web.
Test direct access in SharePoint or OneDrive. Since all Teams files are stored in SharePoint or OneDrive, SharePoint permissions are the real gatekeeper for who can see, edit, or share files.
If web reproduces, capture HAR and console output.
If desktop-only, collect Teams support files.
If auditing is needed, use Microsoft Purview audit search. The audit log tracks Teams activities such as team creation, team deletion, added channel, deleted channel, and changed channel setting; audit events from private channels are also logged as they are for teams and standard channels.

Required tools

Teams client, browser DevTools, SharePoint or OneDrive admin experience, Microsoft Purview.

Preconditions

File location (channel vs. chat), affected user, and exact action are known.

Extra guidance

Permissions validation approach: If some users can access → validate permissions or sharing. If no users can access → validate content availability or service access. If web works but desktop fails → validate client or authentication signals.
For guest file access issues, check Microsoft Entra external collaboration settings, Microsoft 365 Groups guest access settings, and SharePoint/OneDrive sharing settings in addition to team membership.
File recovery: Deleted items are retained in SharePoint recycle bins for 93 days. When an item is restored, it is restored to the same location from which it was deleted.
Teams Mobile: Mobile Client Issue

Symptoms

Teams mobile sign-in, chat, files, calling, meeting, notification, or app behavior issue.

Logs to collect

Teams mobile diagnostic logs.
Product feedback entry and downloaded log package from Microsoft 365 admin center, when available.

Log location and access instructions

Android: Tap profile picture > Settings > Help & feedback > Enable diagnostic logs > Restart. Reproduce the issue. Then tap profile picture > Settings > Help & feedback > Send feedback > Report a problem. Under "Share relevant content samples and additional log files?" select Yes. Tap Submit.
iOS: Tap profile picture > Settings > Help and feedback > Send Feedback > Report a problem. Enter a description. Under "Share relevant content samples and additional log files?" enable the button. Tap Submit.
Alternatively, in Teams mobile, tap profile picture > Settings > Help and feedback > Send feedback > enable the toggle for Attach logs to help troubleshoot.
Retrieve logs from Microsoft 365 admin center: Go to Health > Product feedback, locate the relevant feedback entry, scroll down to Logs and Attachments, then select Download.zip to download the mobile logs.
Record the exact submission time, user, device OS, Teams mobile version, and issue description.

Required tools

Teams mobile app, Microsoft 365 admin center.

Preconditions

User can submit feedback and log collection is allowed by policy.

Extra guidance

The ability to control feedback has been migrated from the Teams Feedback Policy to the Cloud Policy Service. By default the settings are set to Not Configured, which has the same effect as if you set the policies to enabled.
If policy changes do not reflect on the Teams mobile client, sign out and sign back in. Policy propagation can take up to 8 hours.
If the Report a problem option is missing, verify that feedback policies are not restricted by tenant type (e.g., GCCH, DOD).
Logs are typically free of personal data, however some error types may cause user names or email addresses to be logged.
Starting Sep-T1 (5.17.0), slimcore log collection enablement is on by default for mobile and will be uploaded to OCV.
Teams Rooms: Device Issue

Symptoms

Teams Rooms device fails to join meetings, has audio/video device issues, reports instability, or needs device-level troubleshooting.

Logs to collect

Teams Rooms logs from Pro Management Portal or local log collection script.
Device details, Teams Rooms app version, Windows version, peripherals, and impact window.

Log location and access instructions

Pro Management Portal: Go to Rooms, select the display name of the device you want logs for. In the actions panel, select**"Log Collection"** and select**"Run"**. Once you confirm the desired logs, the logs will be ready for download in the Activity tab after a few minutes.
Local PowerShell collection: In Admin mode, start an elevated command prompt, and issue the following command:
powershell -ExecutionPolicy unrestricted c:\rigel\x64\scripts\provisioning\ScriptLaunch.ps1 CollectSrsV2Logs.ps1


The logs are output as a ZIP file in c:\rigel.

Remote PowerShell collection:
$targetDevice = "<Device fqdn>"
$logFile = invoke-command {$output = Powershell.exe -ExecutionPolicy Bypass -File C:\Rigel\x64\Scripts\Provisioning\ScriptLaunch.ps1 CollectSrsV2Logs.ps1
Get-ChildItem -Path C:\Rigel\*.zip | Sort-Object -Descending -Property LastWriteTime | Select-Object -First 1} -ComputerName $targetDevice
$session = new-pssession -ComputerName $targetDevice
Copy-Item -Path $logFile.FullName -Destination .\ -FromSession $session; invoke-command {remove-item -force C:\Rigel\*.zip} -ComputerName $targetDevice


Required tools

Teams Rooms Pro Management Portal or local admin access and PowerShell.

Preconditions

Device identity and impacted meeting or timeframe are known.

Extra guidance

Downloaded logs on the device can take up disk space. If logs aren't regularly cleaned up, they can interfere with the normal functionality of the room. Teams Rooms deletes downloaded logs after 30 days. IT admins can override the log clean-up using the device registry setting HKLM\SOFTWARE\Microsoft\PPI\SkypeSettings\LogCleanupAgeThreshold.
Cache clearing is also available through the Pro Management Portal: go to Rooms, select the device, select**"Restart device-Clear cache", select"Run", check"Delete Teams cache?", and select"Run"**.
Teams in VDI Issue

Symptoms

VDI Teams call quality issue, optimization missing, fallback mode, VDI sign-in problem, media issue, or endpoint plugin/SlimCore problem.

Logs to collect

Teams support files from the VDI session.
VDI optimization status from Teams client.
Endpoint plugin/SlimCore evidence where applicable.
Network and media telemetry from Teams admin center.

Log location and access instructions

Confirm optimization status. You can check in the Teams client that you're optimized with the new architecture by looking at the VDI Status Indicator (top left in the UI). Users can also select the ellipsis (…) on the top bar, then select Settings > About. The Teams and client versions are listed there. "AVD SlimCore Media Optimized" = new optimization based on SlimCore; "AVD Media Optimized" = optimization based on WebRTC.
Collect Teams support files using the standard method.
For VDI clients, media logs are only available for the new Slimcore-based VDI solution. For Teams on VDI using legacy WebRTC-based media optimization, contact your VDI provider for instructions on gathering and interpreting media logs.
If VDI log size is limited, enable Extended Logging in Teams Privacy settings before repro, then collect logs.
On the endpoint, use PowerShell to verify the SlimCore MSIX package: Get-AppxPackage Microsoft.Teams.SlimCore*.
If not optimized, the user can select the three dots and choose Optimize virtual desktop and restart to attempt a repair.

Required tools

Teams client, VDI admin tooling, Teams admin center, endpoint access.

Preconditions

VDI platform (AVD/W365/Citrix/Omnissa/Amazon), endpoint OS, Teams version, optimization mode (SlimCore vs. WebRTC vs. fallback), and issue scenario are known.

Extra guidance

For the new SlimCore-based optimization, MsTeamsVdi.exe is the process that makes all TCP/UDP network connections to Teams relays/conference servers. Any endpoint-based QoS marking must be applied to MsTeamsVdi.exe.
WebRTC-based optimization for Windows-based endpoints connecting to Citrix and AVD/Windows 365 environments will reach End of Support October 1, 2026 and End of Availability April 1, 2027.
Mac endpoints: Logs are stored in ~/Library/Application Support/Microsoft/TeamsVDI.
Tenant-wide or Service Availability Impact

Symptoms

Multiple users, multiple networks, or broad tenant symptoms affect Teams.

Logs to collect

Microsoft 365 Service health incident or advisory details.
Teams admin center reports.
CQD trend data.
Customer impact timeline.

Log location and access instructions

Check Microsoft 365 admin center > Health > Service health. You can view the health of Microsoft services, including Microsoft Teams, on the Service health page. If you're experiencing problems with a cloud service, check the service health to determine whether this is a known issue with a resolution in progress before you call support or spend time troubleshooting.
If unable to sign in to the admin center, use the service status page at https://status.cloud.microsoft.
Capture incident ID, affected services, issue type (incident or advisory), status, estimated start time, and user impact from the Service health detail page.
If you're experiencing an issue with a Microsoft 365 service and don't see it listed on the Service health page, select Report an issue and complete the short form.
Use CQD and Teams admin center to validate whether symptoms are tenant-wide, network-specific, or user-specific.

Required tools

Microsoft 365 admin center, Teams admin center, CQD.

Preconditions

Impact scope and timeframe are known.

Extra guidance

Service health status definitions: Investigating (gathering more information), Service degradation (issue confirmed, may affect use), Service interruption (significant issue, affects ability to access), Restoring service (cause identified, corrective action in progress), Service restored (corrective action resolved the problem).
Sign up for email notifications of new incidents that affect your tenant and status changes for active incidents by selecting Customize > Email in the Service health page.
Teams Policy, Configuration, or Audit Investigation

Symptoms

Unexpected policy behavior, external access change, team/channel membership issue, meeting policy issue, or suspicious administrative/user activity.

Logs to collect

Purview audit log search results.
Teams admin center policy assignment screenshots or exports.
Entra audit/sign-in logs if identity or access policy is involved.

Log location and access instructions

Before you can view audit data, you need to turn on auditing in the Microsoft Purview portal. Audit data is only available from the point at which you turn on auditing.
To retrieve audit logs for Teams activities, use the Microsoft Purview portal. Select specific activities to search for by selecting the checkbox next to one or more activities.
The audit log tracks activities such as: team creation, team deletion, added channel, deleted channel, changed channel setting. For a complete list, see the Teams activities section in the audit log activities reference.
The length of time that an audit record is retained and searchable depends on the Microsoft 365 or Office 365 subscription and the license type assigned to users.
If 5,000 results are found, you can probably assume there are more than 5,000 events that met the search criteria. Refine the search criteria and rerun the search, or export all results by selecting Export > Download all results.

Required tools

Microsoft Purview, Teams admin center, Microsoft Entra admin center.

Preconditions

Auditing must be enabled before events can be viewed.

Extra guidance

When membership changes are made through Microsoft Entra ID, Microsoft 365 admin portal, or Microsoft 365 Groups Graph API, Teams audit messages and the General channel show an existing owner of the team as the initiator, not the actual initiator of the action. In these scenarios, check Microsoft Entra ID or Microsoft 365 Group audit logs to see the relevant information.
By using Microsoft Defender for Cloud Apps integration, you can set activity policies to enforce automated processes using the app provider's APIs — for example, monitoring the addition of external users or mass deletion of Teams sites.
Network, Firewall, Proxy, or VPN Issue

Symptoms

Poor call quality, failed meeting setup, TCP fallback, blocked media, proxy inspection, high latency, packet loss, jitter, or VPN-related degradation.

Logs to collect

Microsoft 365 Network Connectivity Test report.
Teams Network Assessment Tool output.
Teams support files for affected client.
CQD and Teams admin center telemetry.

Log location and access instructions

Microsoft 365 Network Connectivity Test: Run from the affected location at https://connectivity.m365.cloud.microsoft. The test checks Teams media connectivity including UDP connectivity, packet loss, latency, and jitter. If UDP is blocked, Teams might still work using TCP, but audio and video will be impaired. Sign in to your Microsoft 365 tenant so test reports are shared with your administrator and uploaded to the tenant.
Teams Network Assessment Tool: Download from the Official Microsoft Download Center (version 1.9.0.0). The tool tests connectivity to various Teams servers deployed in the Microsoft Azure network. It collects and outputs loss, jitter, and round trip time during packet exchange. Install location is %ProgramFiles (x86)%\Microsoft Teams Network Assessment Tool, and the tool itself is NetworkAssessmentTool.exe.
Review CQD for TCP usage, proxy usage, VPN patterns, and subnet/building quality data. TCP is considered a failback transport; UDP is preferred for real-time media. The most common cause of TCP usage is missing exception rules in firewalls or proxies.
Collect Teams support files from a failing client during the same repro window.

Required tools

Microsoft 365 Network Connectivity Test, Teams Network Assessment Tool, CQD, Teams admin center.

Preconditions

Affected location, network type, VPN/proxy status, and issue timeframe are known.

Extra guidance

Firewall configuration: Verify that Microsoft 365 IP ports and addresses are excluded from the firewall. For media-related TCP issues, verify that client media subnets 13.107.64.0/18 and 52.112.0.0/14 are in firewall rules, and that UDP ports 3478–3481 are opened (these are the required media ports; otherwise the client will fail back to TCP port 443).
HTTP proxies are not the preferred path for establishing media sessions. Almost all proxies force TCP as opposed to allowing UDP. It is recommended to configure the client to directly connect to Teams service, especially for media-based traffic.
VPN appliances aren't traditionally designed to handle real-time media workloads. Consider implementing a VPN split-tunnel solution to help reduce VPN as a source of poor quality.
Wi-Fi drivers should be included in patch management strategy. Many quality issues are corrected by maintaining up-to-date Wi-Fi drivers. For Wi-Fi networks, 5 GHz provides less background interference and higher speeds and should be prioritized when deploying VoIP over Wi-Fi.
Remote Teams Client Log Collection from Teams Admin Center

Use remote collection when user-driven log collection is impractical or when support needs logs from Windows or Mac Teams clients without interrupting the user.

What it collects

Remote log collection supports the following log types:

Web logs — diagnostics logs, calling logs, central data layer logs, Web Media log
Desktop Logs — Shell Diagnostics logs, Slimcore logs including media stack logs

Procmon traces and OS Event Logs are not collected because they require elevated user access.

Steps

Go to Teams admin center > Users tab > Manage users. Navigate to the specific user page.
On the user page, the Client health tab provides information about client health for all client versions that user is running.
Choose the client and version you want to collect diagnostic logs from and select Request client logs.
Once log collection is started, the Client log status column will be set to Pending.
Once log collection is complete, download and share the logs with your team or Microsoft.
To view the status for all logs collected within your tenant, select View client logs from the Teams client health page.

Important notes

This feature is currently supported for Windows (non-VDI) and Mac Applications only.
Accessible to the following roles: Global Administrator, Teams Administrator, Teams Communications Support Engineer, and Teams Communications Support Specialist.
Logs are stored for 30 days in a Microsoft secure and compliant storage location.
User consent is not required, and no prompt or message is shown to users when logs are collected.
Provided Teams client is running, logs may take up to 8 hours before they are fully available for download in Teams admin center.
Client log collection isn't supported on devices that have both commercial and government cloud accounts added simultaneously to the Teams client.
Log collection may fail if the user's device is offline. The request will be queued until the device is back online, with a maximum period of 3 days.
Teams Meeting Add-in for Outlook

When troubleshooting the Teams Meeting add-in for classic Outlook, verify that Microsoft Teams Meeting Add-in for Microsoft Office is in the Active Application Add-ins list in Outlook (File > Options > Add-ins tab). If the add-in is in the Disabled Application Add-ins list, select Manage > COM Add-ins, select Go, and re-enable it.

The new Outlook for Windows does not support the Teams COM add-in; it contains a native Teams meeting capability instead.

To reregister the add-in loader, navigate to %LocalAppData%\Microsoft\TeamsMeetingAddin, select the subfolder with the version number, and run the appropriate regsvr32.exe command for your Office architecture (64-bit or 32-bit).

If the add-in still doesn't appear, check the registry at HKEY_CURRENT_USER\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect and verify that the LoadBehavior value is set to 3.

Public References (Microsoft)
Collect Teams client diagnostic logs: https://learn.microsoft.com/en-us/microsoftteams/log-files
Teams client diagnostic logging in Teams admin center (remote collection): https://learn.microsoft.com/en-us/microsoftteams/teams-client-diagnostic-logging
Teams client health dashboard: https://learn.microsoft.com/en-us/microsoftteams/teams-client-health
Browser logs and tracing for Teams: https://learn.microsoft.com/en-us/microsoftteams/browser-logs-and-tracing-for-teams
Monitor and troubleshoot Teams meetings and calls from the Teams admin center: https://learn.microsoft.com/en-us/microsoftteams/monitor-troubleshoot-teams-meetings-calls
Use real-time telemetry to troubleshoot poor meeting quality: https://learn.microsoft.com/en-us/microsoftteams/use-real-time-telemetry-to-troubleshoot-poor-meeting-quality
Use CQD to manage call and meeting quality: https://learn.microsoft.com/en-us/microsoftteams/quality-of-experience-review-guide
Microsoft 365 Network Connectivity Test: https://connectivity.m365.cloud.microsoft
Microsoft Teams Network Assessment Tool: https://www.microsoft.com/download/details.aspx?id=103017
Resolve Teams sign-in errors: https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-sign-in/resolve-sign-in-errors
Search the audit log for Teams events: https://learn.microsoft.com/en-us/purview/audit-teams-audit-log-events
Send diagnostic log files from Teams mobile app: https://support.microsoft.com/en-us/teams/platform/send-diagnostic-log-files-from-microsoft-teams-mobile-app
Manage feedback policies in Microsoft Teams: https://learn.microsoft.com/en-us/microsoftteams/manage-feedback-policies-in-teams
Microsoft Teams Rooms maintenance and operations: https://learn.microsoft.com/en-us/microsoftteams/rooms/rooms-operations
Resolve issues with Teams Meeting add-in for Outlook: https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/meetings/resolve-teams-meeting-add-in-issues
Teams for Virtualized Desktop Infrastructure (VDI): https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy
New VDI solution for Teams (SlimCore): https://learn.microsoft.com/en-us/microsoftteams/vdi-2
File storage in Microsoft Teams: https://support.microsoft.com/en-us/teams/files/file-storage-in-microsoft-teams
Check Microsoft 365 service health: https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health
Microsoft Entra sign-in logs: https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins
Microsoft Teams Connectivity Test: https://testconnectivity.microsoft.com/tests/teams
