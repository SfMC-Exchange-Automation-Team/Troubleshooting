## Log Collection Guidelines: Exchange + Outlook Troubleshooting

This guide standardizes log collection for common Microsoft Outlook and Exchange troubleshooting scenarios in Microsoft 365 and hybrid environments.

**How to use this guide**

1.  Start with the **Log Collection Matrix** to identify the best matching scenario.
2.  Jump to the linked **detailed scenario subsection** for exact log locations, access instructions, required tools, preconditions, and extra guidance.

***

## Log Collection Matrix (Updated)

| Affected Component      | Subsection Scenario (link)                             | Symptom                                                          | Logs to Collect                                                        | Required Tools                                       |
| ----------------------- | ------------------------------------------------------ | ---------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------- |
| Outlook Desktop         | #outlook-desktop-client-connectivity-failure           | Outlook shows **Disconnected** or cannot connect to mailbox      | Outlook troubleshooting logs                                           | Windows Explorer                                     |
| Outlook Desktop         | #outlook-desktop-profile-creation-autodiscover-failure | Profile setup fails, Autodiscover errors during first-time setup | Outlook troubleshooting logs, Windows Application event logs           | Windows Explorer, Event Viewer                       |
| Outlook Desktop         | #outlook-desktop-shared-mailbox-access-issues          | Shared mailbox disconnects, fails to open, repeated sync resets  | Outlook troubleshooting logs, Entra sign-in logs (when auth suspected) | Windows Explorer, Microsoft Entra admin center       |
| Outlook Desktop         | #outlook-desktop-send-failures-outbox                  | Messages stuck in Outbox or fail silently                        | Outlook troubleshooting logs                                           | Windows Explorer                                     |
| Outlook Desktop         | #outlook-desktop-outlook-crashes                       | Crash on launch or during send/receive                           | Crash dumps (if present), Windows Application event logs               | Windows Explorer, Event Viewer                       |
| Outlook Desktop         | #outlook-desktop-search-indexing-failures              | Missing or partial search results                                | Outlook troubleshooting logs, mailbox statistics (EXO PowerShell)      | Windows Explorer, Exchange Online PowerShell         |
| Outlook Desktop         | #outlook-desktop-authentication-prompt-loop            | Repeated credential prompts or MFA prompt loop                   | Outlook troubleshooting logs, Entra sign-in logs                       | Windows Explorer, Microsoft Entra admin center       |
| Exchange Online         | #exchange-online-mailbox-size-anomalies-warnings       | Mailbox size or quota warnings look incorrect                    | Mailbox statistics (EXO PowerShell), audit logs (Purview)              | Exchange Online PowerShell, Microsoft Purview portal |
| Exchange Online         | #exchange-online-mail-flow-failures-message-trace      | Delayed, rejected, or missing messages                           | Message trace results and report export                                | Exchange admin center                                |
| Exchange Hybrid         | #exchange-hybrid-hybrid-mail-flow-failures             | Cross-premises delivery failures                                 | Message trace results, IIS logs (when HTTP endpoints involved)         | Exchange admin center, IIS Manager, Windows Explorer |
| Exchange Availability   | #exchange-availability-freebusy-lookup-failures        | Free/Busy errors or no data returned                             | Outlook troubleshooting logs, Windows Application event logs           | Windows Explorer, Event Viewer                       |
| Exchange Services (IIS) | #exchange-services-iis-autodiscover-service-failures   | Autodiscover returns HTTP errors                                 | IIS logs                                                               | IIS Manager, Windows Explorer                        |
| Exchange Services (IIS) | #exchange-services-iis-ews-connectivity-issues         | Shared calendar failures or Outlook disconnects tied to EWS      | IIS logs                                                               | IIS Manager, Windows Explorer                        |
| Exchange Services (IIS) | #exchange-services-iis-oab-download-failures           | Offline Address Book download errors                             | IIS logs                                                               | IIS Manager, Windows Explorer                        |
| Exchange Services (IIS) | #exchange-services-iis-activesync-failures             | Mobile sync errors or device partnership failures                | IIS logs                                                               | IIS Manager, Windows Explorer                        |
| Exchange Online         | #exchange-online-service-availability-impact           | Tenant-wide or service-wide outage symptoms                      | Service health incident details                                        | Microsoft 365 admin center                           |
| Windows OS              | #windows-os-performance-resource-degradation           | Outlook hangs, timeouts, general slowness                        | Windows event logs, PerfMon BLG capture                                | Event Viewer, Performance Monitor                    |

***

# Detailed Scenarios

## Outlook Desktop: Client Connectivity Failure

<a id="outlook-desktop-client-connectivity-failure"></a>

**Symptoms**  
Outlook shows **Disconnected** or cannot connect to mailbox.

**Logs to collect**

*   Outlook troubleshooting logging output. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)

**Log location and access instructions**

1.  In Outlook, enable troubleshooting logging: **File** > **Options** > **Advanced** > under **Other**, select **Enable troubleshooting logging (requires restarting Outlook)**. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Restart Outlook, reproduce the issue, then **exit Outlook** so log data is written out. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  Open Windows Explorer and browse to the Outlook logging folder under your **Temp** directory. Microsoft documents the default Temp location under `…\AppData\Local\Temp`. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)

**Required tools**  
Windows Explorer

**Preconditions**  
Issue is reproducible.

**Extra guidance**  
Turn logging off after capture because logs continue to grow while enabled. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)

***

## Outlook Desktop: Profile Creation Autodiscover Failure

<a id="outlook-desktop-profile-creation-autodiscover-failure"></a>

**Symptoms**  
Profile creation fails, Autodiscover errors during first-time setup.

**Logs to collect**

*   Outlook troubleshooting logs. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
*   Windows **Application** event logs.

**Log location and access instructions**

1.  Enable Outlook troubleshooting logging (same path as above), restart Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Attempt profile creation until failure occurs, then exit Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  Collect Outlook logs from the Outlook logging folder under your Temp directory. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
4.  Collect Windows Application logs in **Event Viewer** and export the relevant entries around the failure time.

**Required tools**  
Windows Explorer, Event Viewer

**Preconditions**  
Failure occurs consistently.

**Extra guidance**  
Do not delete the failed profile until logs are collected (helps preserve reproduction context).

***

## Outlook Desktop: Shared Mailbox Access Issues

<a id="outlook-desktop-shared-mailbox-access-issues"></a>

**Symptoms**  
Shared mailbox disconnects, fails to open, or repeatedly resyncs.

**Logs to collect**

*   Outlook troubleshooting logs. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
*   Microsoft Entra sign-in logs when authentication or Conditional Access is suspected. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-download-logs)

**Log location and access instructions**

1.  Enable Outlook troubleshooting logging, restart Outlook, reproduce, then exit Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Collect Outlook logs from the Outlook logging folder under Temp. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  In Microsoft Entra admin center, download sign-in logs using the built-in download option (CSV or JSON). [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-download-logs)

**Required tools**  
Windows Explorer, Microsoft Entra admin center

**Preconditions**  
Access method is known (automap vs manual) and the issue is observable.

**Extra guidance**  
Record the exact time window and whether credential prompts occurred to correlate to Entra sign-ins.

***

## Outlook Desktop: Send Failures (Outbox)

<a id="outlook-desktop-send-failures-outbox"></a>

**Symptoms**  
Messages stuck in Outbox or fail silently.

**Logs to collect**

*   Outlook troubleshooting logs. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)

**Log location and access instructions**

1.  Enable Outlook troubleshooting logging, restart Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Reproduce send failure, then exit Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  Collect logs from the Outlook logging folder under Temp. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)

**Required tools**  
Windows Explorer

**Preconditions**  
Send failure is reproducible.

**Extra guidance**  
Record timestamp, recipient domain, and any UI error text for correlation.

***

## Outlook Desktop: Outlook Crashes

<a id="outlook-desktop-outlook-crashes"></a>

**Symptoms**  
Crash on launch or during send/receive.

**Logs to collect**

*   Crash dumps when Windows Error Reporting LocalDumps are configured, default dump folder is `%LOCALAPPDATA%\CrashDumps`. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps)
*   Windows Application event logs.

**Log location and access instructions**

1.  Open Windows Explorer and check `%LOCALAPPDATA%\CrashDumps` for `.dmp` files. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps)
2.  Export Windows Application logs from **Event Viewer** around the crash time.

**Required tools**  
Windows Explorer, Event Viewer

**Preconditions**  
Crash is recent or reproducible.

**Extra guidance**  
Capture Outlook build and update channel as case context.

***

## Outlook Desktop: Search Indexing Failures

<a id="outlook-desktop-search-indexing-failures"></a>

**Symptoms**  
Missing or partial search results.

**Logs to collect**

*   Outlook troubleshooting logs. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
*   Mailbox statistics collected via Exchange Online PowerShell connection. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps)

**Log location and access instructions**

1.  Enable Outlook troubleshooting logging, reproduce search issue, exit Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Collect Outlook logs from the Outlook logging folder under Temp. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  Connect to Exchange Online PowerShell using the Exchange Online module to collect mailbox statistics as needed. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps)

**Required tools**  
Windows Explorer, Exchange Online PowerShell

**Preconditions**  
Cached Exchange Mode is enabled (when applicable) and issue is reproducible.

**Extra guidance**  
Document folder scope, query terms, date range, expected vs actual results.

***

## Outlook Desktop: Authentication Prompt Loop

<a id="outlook-desktop-authentication-prompt-loop"></a>

**Symptoms**  
Repeated credential prompts, MFA prompt loop.

**Logs to collect**

*   Outlook troubleshooting logs. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
*   Entra sign-in logs. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-download-logs)

**Log location and access instructions**

1.  Enable Outlook troubleshooting logging, reproduce prompt loop, exit Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Collect Outlook logs from the Outlook logging folder under Temp. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  Download Entra sign-in logs (CSV or JSON) from Entra admin center. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-download-logs)

**Required tools**  
Windows Explorer, Microsoft Entra admin center

**Preconditions**  
MFA or Conditional Access is in play, prompt loop can be reproduced.

**Extra guidance**  
Document prompt frequency and approximate start time to align with Entra events.

***

## Exchange Online: Mailbox Size Anomalies / Warnings

<a id="exchange-online-mailbox-size-anomalies-warnings"></a>

**Symptoms**  
Mailbox size or quota warnings appear incorrect.

**Logs to collect**

*   Mailbox statistics via Exchange Online PowerShell. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps)
*   Audit log search results in Microsoft Purview. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/purview/audit-search)

**Log location and access instructions**

1.  Connect to Exchange Online PowerShell and collect mailbox statistics. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps)
2.  In Microsoft Purview, run an audit log search and export results as needed. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/purview/audit-search)

**Required tools**  
Exchange Online PowerShell, Microsoft Purview portal

**Preconditions**  
Warning time is known, and there were no intentional recent changes (retention, archive, policy) relevant to the warning.

**Extra guidance**  
Capture the exact warning timestamp and the values displayed in the warning.

***

## Exchange Online: Mail Flow Failures (Message Trace)

<a id="exchange-online-mail-flow-failures-message-trace"></a>

**Symptoms**  
Delayed, rejected, or missing messages.

**Logs to collect**

*   Message trace results and exports from the modern message trace experience. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac)
*   Full message headers and NDR details when present.

**Log location and access instructions**

1.  In the Exchange admin center, use **Mail flow > Message trace** to trace the message path and download reports as needed. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac)

**Required tools**  
Exchange admin center

**Preconditions**  
Sender, recipient, timeframe, and ideally Message ID are known.

**Extra guidance**  
Attach full NDR and headers for rejection scenarios.

***

## Exchange Hybrid: Hybrid Mail Flow Failures

<a id="exchange-hybrid-hybrid-mail-flow-failures"></a>

**Symptoms**  
Cross-premises delivery failures.

**Logs to collect**

*   Message trace results. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac)
*   IIS logs when the failure is tied to HTTP endpoints (default IIS log directory is `%SystemDrive%\inetpub\logs\LogFiles`). [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage)

**Log location and access instructions**

1.  Run message trace for the impacted timeframe in Exchange admin center. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac)
2.  If IIS logs are required, collect from IIS logging directory (default shown above) or the directory configured in IIS for the site. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)

**Required tools**  
Exchange admin center, IIS Manager, Windows Explorer

**Preconditions**  
Hybrid connectors are involved and you have access to the Exchange server(s) hosting the relevant IIS endpoints.

**Extra guidance**  
Document connector state and the exact impact window for correlation.

***

## Exchange Availability: Free/Busy Lookup Failures

<a id="exchange-availability-freebusy-lookup-failures"></a>

**Symptoms**  
Free/Busy errors or no availability data.

**Logs to collect**

*   Outlook troubleshooting logs. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
*   Windows Application event logs.

**Log location and access instructions**

1.  Enable Outlook troubleshooting logging, reproduce Free/Busy lookup, exit Outlook. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
2.  Collect Outlook logs from the Outlook logging folder under Temp. [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
3.  Export relevant Event Viewer Application entries around the failure time.

**Required tools**  
Windows Explorer, Event Viewer

**Preconditions**  
Issue is reproducible and the scenario is known (hybrid cross-forest or single tenant).

**Extra guidance**  
Enable logging before the actual lookup attempt.

***

## Exchange Services (IIS): Autodiscover Service Failures

<a id="exchange-services-iis-autodiscover-service-failures"></a>

**Symptoms**  
Autodiscover returns HTTP errors.

**Logs to collect**

*   IIS logs.

**Log location and access instructions**

1.  Confirm IIS logging is enabled in IIS Manager. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)
2.  Collect IIS logs from the default IIS log folder `%SystemDrive%\inetpub\logs\LogFiles` unless configured otherwise. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage)

**Required tools**  
IIS Manager, Windows Explorer

**Preconditions**  
IIS logging enabled before reproducing.

**Extra guidance**  
Reproduce after confirming logging is enabled to capture the failing request.

***

## Exchange Services (IIS): EWS Connectivity Issues

<a id="exchange-services-iis-ews-connectivity-issues"></a>

**Symptoms**  
Shared calendar failures or Outlook disconnects tied to EWS.

**Logs to collect**

*   IIS logs.

**Log location and access instructions**

1.  Confirm IIS logging is enabled in IIS Manager. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)
2.  Collect logs from `%SystemDrive%\inetpub\logs\LogFiles` or the directory configured for the site. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)

**Required tools**  
IIS Manager, Windows Explorer

**Preconditions**  
IIS logging enabled.

**Extra guidance**  
Capture exact repro window for correlation.

***

## Exchange Services (IIS): OAB Download Failures

<a id="exchange-services-iis-oab-download-failures"></a>

**Symptoms**  
Offline Address Book download errors.

**Logs to collect**

*   IIS logs.

**Log location and access instructions**

1.  Confirm IIS logging is enabled. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)
2.  Collect IIS logs from `%SystemDrive%\inetpub\logs\LogFiles` or configured IIS log directory. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)

**Required tools**  
IIS Manager, Windows Explorer

**Preconditions**  
IIS logging enabled.

**Extra guidance**  
Reproduce an OAB download after confirming logging.

***

## Exchange Services (IIS): ActiveSync Failures

<a id="exchange-services-iis-activesync-failures"></a>

**Symptoms**  
Mobile sync errors or device partnership failures.

**Logs to collect**

*   IIS logs.

**Log location and access instructions**

1.  Confirm IIS logging is enabled. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)
2.  Collect IIS logs from `%SystemDrive%\inetpub\logs\LogFiles` or configured IIS log directory. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)

**Required tools**  
IIS Manager, Windows Explorer

**Preconditions**  
ActiveSync is enabled for the affected user and the issue can be reproduced.

**Extra guidance**  
Document device model and OS and capture the sync attempt time.

***

## Exchange Online: Service Availability Impact

<a id="exchange-online-service-availability-impact"></a>

**Symptoms**  
Tenant-wide or service-wide outage symptoms.

**Logs to collect**

*   Service health incident details from Microsoft 365 admin center. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health?view=o365-worldwide)

**Log location and access instructions**

1.  In Microsoft 365 admin center, go to **Health > Service health** to review incident details and capture timestamps and incident identifiers. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health?view=o365-worldwide)

**Required tools**  
Microsoft 365 admin center

**Preconditions**  
Impact window is known.

**Extra guidance**  
Capture incident ID, impacted workload(s), start time, and latest status update.

***

## Windows OS: Performance / Resource Degradation

<a id="windows-os-performance-resource-degradation"></a>

**Symptoms**  
Outlook hangs, timeouts, general slowness.

**Logs to collect**

*   Windows Application and System event logs
*   Performance Monitor (PerfMon) BLG capture

**Log location and access instructions**

1.  Export relevant Application and System logs from Event Viewer during the impact window.
2.  Use Performance Monitor to capture a BLG during peak impact and save locally.

**Required tools**  
Event Viewer, Performance Monitor

**Preconditions**  
Peak impact window is known.

**Extra guidance**  
Capture during impact to correlate CPU, memory pressure, and disk latency.

***

# Microsoft Support and Recovery Assistant (SaRA)

SaRA is a Microsoft diagnostic tool that runs tests to identify issues and provides the best solution for the identified problem. It can also suggest next steps if it cannot resolve the issue. [\[microsoft.com\]](https://www.microsoft.com/en-us/download/details.aspx?id=103391)

**Recommended use cases**

*   Outlook setup, connectivity, sign-in, and profile related problems where guided diagnostics are appropriate. [\[microsoft.com\]](https://www.microsoft.com/en-us/download/details.aspx?id=103391)

**Download**

*   Enterprise Version of SaRA is available from the Official Microsoft Download Center. [\[microsoft.com\]](https://www.microsoft.com/en-us/download/details.aspx?id=103391)

***

# Public References (Microsoft)

*   Outlook troubleshooting logging option and log location guidance: <https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5> [\[support.mi...rosoft.com\]](https://support.microsoft.com/en-us/office/what-is-the-enable-logging-troubleshooting-option-0fdc446d-d1d4-42c7-bd73-74ffd4034af5)
*   Download SaRA (Enterprise): <https://www.microsoft.com/en-us/download/details.aspx?id=103391> [\[microsoft.com\]](https://www.microsoft.com/en-us/download/details.aspx?id=103391)
*   Message trace in the modern Exchange admin center: <https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/exchange/monitoring/trace-an-email-message/message-trace-modern-eac)
*   Connect to Exchange Online PowerShell: <https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps)
*   Search the audit log (Purview): <https://learn.microsoft.com/en-us/purview/audit-search> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/purview/audit-search)
*   Download logs in Microsoft Entra ID: <https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-download-logs> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/howto-download-logs)
*   IIS default log directory and management: <https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/managing-iis-log-file-storage)
*   Configure logging in IIS: <https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/iis/manage/provisioning-and-managing-iis/configure-logging-in-iis)
*   Windows user-mode dump collection and default dump folder: <https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps)
*   Check Microsoft 365 service health: <https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health?view=o365-worldwide> [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/microsoft-365/enterprise/view-service-health?view=o365-worldwide)

***
