# SfMC Exchange server discovery script: Collect Exchange and OS configuration and health data on the local server

## Summary

This PowerShell script automates the collection of configuration, health, and operating system data from a single on-premises Microsoft Exchange server.

It:

*   Gathers Exchange server, client access, transport, and mailbox configuration using Exchange Management Shell cmdlets.
*   Collects operating system, hardware, networking, and patch information via PowerShell, WMI, and registry queries.
*   Optionally runs the Exchange `HealthChecker.ps1` script and stores its output together with other collected data.
*   Writes start/complete events to the Windows Application event log.
*   Saves all collected data under the Exchange logging path and compresses it into a ZIP file.

Script version (from header): `20240708.1030`  
License: MIT License (included at the top of the script).  
The script is digitally signed (see `SIG # Begin signature block` and `SIG # End signature block` in the file).

***

## Applies to

Based on cmdlets and APIs used, this script applies to:

*   **Microsoft Exchange Server (on-premises)** environments where:
    *   The `Microsoft.Exchange.Management.PowerShell.SnapIn` snap-in is available and loadable with `Add-PSSnapin`.
    *   Exchange cmdlets such as `Get-ExchangeServer`, `Get-MailboxDatabase`, `Get-ClientAccessServer`, etc., are present.
*   **Windows Server** where:
    *   `$env:ExchangeInstallPath` is defined (i.e., Exchange is installed).
    *   WMI / CIM classes such as `Win32_Processor`, `Win32_OperatingSystem`, `Win32_LogicalDisk`, etc., are accessible.
    *   Modules/cmdlets such as `Get-WindowsFeature`, `Get-NetAdapter`, `Get-NetIPAddress`, `Get-NetRoute`, `Get-ScheduledTask`, and `Get-Cluster` are available.

Specific Exchange and Windows Server versions are **not specified in the script.**

***

## What this script does

### High-level workflow

1.  **Displays a legal disclaimer**

    Prints a standard copyright and “AS IS” disclaimer string (`$ScriptDisclaimer`) to the console in yellow.

2.  **Prepares the output directory**

    *   Sets output folder to:

        *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings"`

    *   If the folder does not exist:
        *   Creates it.

    *   If it already exists:
        *   Deletes all existing contents in `Server Settings`.
        *   Deletes existing ZIP files in `"$env:ExchangeInstallPath\Logging\SfMC Discovery"` that match `"$env:COMPUTERNAME*.zip"`.

3.  **Initializes logging**

    *   Uses `Get-NewLoggerInstance` to:
        *   Create a log file named `SfMC-Discovery-<yyyyMMddhhmmss>-Debug.txt` in the output directory.
        *   Configure log rotation based on:
            *   `MaxFileSizeMB = 10`
            *   `CheckSizeIntervalMinutes = 10`
            *   `NumberOfLogsToKeep = 10`
    *   Redirects:
        *   `Write-Host`
        *   `Write-Verbose`
        *   `Write-Warning`  
            through custom wrappers so that these also log to the debug log file via `Write-LoggerInstance`.

4.  **Writes a “script started” event to the Application log**

    *   Calls:

        ```powershell
        Write-EventLog -LogName Application -Source "MSExchange ADAccess" `
          -EntryType Information -EventId 1031 `
          -Message "The SfMC Exchange Server discovery script has started." `
          -Category 1
        ```

    *   Also prints a corresponding message to the console.

5.  **Loads Exchange Management Shell**

    *   Sets `$ServerName` to the local computer name:

        ```powershell
        $ServerName = $env:COMPUTERNAME
        ```

    *   Loads the Exchange snap-in:

        ```powershell
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn
        ```

    *   Calls `InvokeExchangeCmdlet` to run `Set-ADServerSettings` with `-ViewEntireForest:$True` (note: the `ViewEntireForest` parameter is **not** passed into the cmdlet inside the function; see “Limitations”).

6.  **Collects Exchange server configuration and health**

    Uses the helper function `InvokeExchangeCmdlet` to run Exchange cmdlets and export results to `.xml` files (via `Export-Clixml`) under the output path. All results are selected with:

    ```powershell
    Select-Object * -ExcludeProperty SerializationData, PSComputerName, RunspaceId, PSShowComputerName
    ```

    The script collects:

    *   **General server information**

        *   `Get-ExchangeServer -Identity $ServerName -Status`  
            → `$ServerName-ExchangeServer.xml`
        *   `Get-ExchangeCertificate -Server $ServerName`  
            → `$ServerName-ExchangeCertificate.xml`
        *   `Get-ServerComponentState -Identity $ServerName`  
            → `$ServerName-ServerComponentState.xml`
        *   `Get-ServerHealth -Identity $ServerName`  
            → `$ServerName-ServerHealth.xml`
        *   `Get-ServerMonitoringOverride -Server $ServerName`  
            → `$ServerName-ServerMonitoringOverride.xml`
        *   `Get-EventLogLevel`  
            → `$ServerName-EventLogLevel.xml`
        *   `Get-HealthReport -Identity *`  
            → `$ServerName-HealthReport.xml`

    *   **Client access settings**

        All saved as XML in the output folder, named `$ServerName-<CmdletName>.xml`:

        *   `Get-AutodiscoverVirtualDirectory -Server $ServerName`
        *   `Get-ClientAccessServer`
        *   `Get-EcpVirtualDirectory -Server $ServerName`
        *   `Get-WebServicesVirtualDirectory -Server $ServerName`
        *   `Get-MapiVirtualDirectory -Server $ServerName`
        *   `Get-ActiveSyncVirtualDirectory -Server $ServerName`
        *   `Get-OabVirtualDirectory -Server $ServerName`
        *   `Get-OwaVirtualDirectory -Server $ServerName`
        *   `Get-OutlookAnywhere -Server $ServerName`
        *   `Get-PowerShellVirtualDirectory -Server $ServerName`
        *   `Get-RpcClientAccess -Server $ServerName`

    *   **Transport settings**

        All saved as XML in the output folder:

        *   `Get-ReceiveConnector -Server $ServerName`
        *   `Get-ImapSettings -Server $ServerName`
        *   `Get-PopSettings -Server $ServerName`
        *   `Get-TransportAgent`
        *   `Get-TransportService -Identity $ServerName`
        *   `Get-MailboxTransportService -Identity $ServerName`
        *   `Get-FrontendTransportService -Identity $ServerName`

    *   **Mailbox/DAG settings**

        *   Reads the cluster name:

            ```powershell
            $DagName = (Get-Cluster).Name
            ```

        *   `Get-DatabaseAvailabilityGroup -Identity $DagName -Status`  
            → `$ServerName-DatabaseAvailabilityGroup.xml`

        *   `Get-DatabaseAvailabilityGroupNetwork -Identity $DagName`  
            → `$ServerName-DatabaseAvailabilityGroupNetwork.xml`

        *   `Get-MailboxDatabase -Server $ServerName -Status`  
            → `$ServerName-MailboxDatabase.xml`

        *   `Get-MailboxServer -Identity $ServerName`  
            → `$ServerName-MailboxServer.xml`

7.  **Collects server OS and hardware information**

    Defines a hashtable `$hash` of named commands and runs them via `GetServerData`. For each entry, it:

    *   Executes the command using `Invoke-Expression`.
    *   If any output is returned, writes it to CSV:  
        `$outputPath\$ServerName-<Key>.csv` without type information.

    The collected data includes (keys → commands):

    *   `Partition` – `Get-Disk` and `Get-Partition` info.
    *   `Disk` – `Get-Disk`.
    *   `WindowsFeature` – installed Windows features via `Get-WindowsFeature`.
    *   `HotFix` – installed updates via `Get-HotFix`.
    *   `Culture` – `Get-Culture`.
    *   `NetAdapter` – `Get-NetAdapter`.
    *   `NetIPAddress` – `Get-NetIPAddress` (excluding loopback and APIPA addresses).
    *   `NetOffloadGlobalSetting` – `Get-NetOffloadGlobalSetting`.
    *   `NetRoute` – `Get-NetRoute`.
    *   `ScheduledTask` – non-disabled scheduled tasks via `Get-ScheduledTask`.
    *   `Service` – `Win32_Service` (WMI).
    *   `Processor` – `Win32_Processor` (WMI).
    *   `Product` – `Win32_Product` (WMI).
    *   `LogicalDisk` – `Win32_LogicalDisk` (WMI).
    *   `Bios` – `Win32_BIOS` (WMI).
    *   `OperatingSystem` – `Win32_OperatingSystem` (WMI).
    *   `ComputerSystem` – `Win32_ComputerSystem` (WMI).
    *   `Memory` – `Win32_PhysicalMemory` (WMI).
    *   `PageFile` – `Win32_PageFile` (WMI).
    *   `CrashControl` – crash control settings from the registry key  
        `HKLM:\SYSTEM\CurrentControlSet\Control\crashcontrol`.

8.  **Optional: runs the Exchange HealthChecker script**

    If `-HealthChecker` is `$true`:

    *   Changes directory to:

        ```powershell
        Set-Location $env:ExchangeInstallPath\Scripts
        ```

    *   Unblocks `HealthChecker.ps1`:

        ```powershell
        Unblock-File -Path .\HealthChecker.ps1 -Confirm:$False
        ```

    *   Executes:

        ```powershell
        .\HealthChecker.ps1 `
          -OutputFilePath "$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings" `
          -SkipVersionCheck
        ```

    The contents and behavior of `HealthChecker.ps1` are **not specified in this script.**

9.  **Creates a ZIP archive of the collected data**

    *   Generates a timestamp (`yyyyMMddHHmmss`) and builds a ZIP file path:

        ```powershell
        $zipFolder = "$env:ExchangeInstallPath\Logging\SfMC Discovery\$ServerName-Settings-$ts.zip"
        ```

    *   Calls `ZipCsvResults` to compress everything in the output directory into this ZIP.

    `ZipCsvResults`:

    *   Loads `System.IO.Compression.FileSystem`.
    *   Attempts `CreateFromDirectory($outputPath, $ZipPath)`.
    *   If that fails:
        *   Deletes any existing file at `$ZipPath` (if possible).
        *   Opens the ZIP in `update` mode.
        *   Adds each file from `$outputPath` using `CreateEntryFromFile` with compression level `Fastest`.

10. **Writes a “script completed” event to the Application log**

    *   Calls:

        ```powershell
        Write-EventLog -LogName Application -Source "MSExchange ADAccess" `
          -EntryType Information -EventId 1376 `
          -Message "The SfMC Exchange server discovery script has completed." `
          -Category 1
        ```

    *   Also prints a message to the console.

### Helper functions defined but not used in the main flow

The script defines several additional functions that are **not called** in the main script body:

*   `Invoke-ScriptBlockHandler` – Wrapper for running script blocks locally or remotely via `Invoke-Command`, with optional credentials and session options.
*   `CheckOrgCollectionStarted` – Checks for event ID `1125` from source `MSExchange ADAccess` and optionally interacts with the `ExchangeOrgDiscovery` scheduled task.
*   `CheckServerCollectionStarted` – Checks for event ID `1031` from source `MSExchange ADAccess` and interacts with the `ExchangeServerDiscovery` scheduled task.
*   `ConnectRemotePowerShell` – Attempts to open a remote Exchange PowerShell session against `$ExchangeServer` using Kerberos and imports it as session "SfMC".
*   `GetExchangeInstallPath` – Uses `Get-ExchangeServer` and a directory search in Active Directory to retrieve `msexchinstallpath`.

These helpers are present but **not invoked** by the main script logic.

***

## Prerequisites

All prerequisites below are derived from cmdlets and APIs used in the script.

### Environment

*   A server where **Microsoft Exchange Server** is installed and:
    *   `$env:ExchangeInstallPath` is set.
    *   `Microsoft.Exchange.Management.PowerShell.SnapIn` can be loaded with `Add-PSSnapin`.
*   Windows Server environment with:
    *   Access to the **Application** event log and the source **MSExchange ADAccess** already registered.
    *   The ability to load the **Failover Cluster** cmdlets (`Get-Cluster`).
    *   Access to the **ScheduledTasks** cmdlets (`Get-ScheduledTask`, `Start-ScheduledTask`) – used in helper functions.

### Permissions

The script itself does not explicitly check for roles/rights, but based on the operations it performs:

*   **Exchange permissions** sufficient to run:
    *   `Get-ExchangeServer`, `Get-MailboxServer`, `Get-MailboxDatabase`, `Get-ClientAccessServer`, `Get-TransportService`, `Get-DatabaseAvailabilityGroup`, etc.
*   **Local administrative rights** are typically required to:
    *   Write to `"$env:ExchangeInstallPath\Logging\..."`.
    *   Write events to the Application event log with source `MSExchange ADAccess`.
    *   Query WMI classes such as `Win32_OperatingSystem`, `Win32_Processor`, `Win32_Service`, etc.
    *   Access crash control registry keys under `HKLM:\SYSTEM\CurrentControlSet\Control\crashcontrol`.

The exact required RBAC roles or group memberships are **not specified in the script.**

### External script dependency

*   `HealthChecker.ps1` must exist in:

    *   `"$env:ExchangeInstallPath\Scripts"`

    if you plan to use `-HealthChecker $true`.

The script does not validate the presence of `HealthChecker.ps1` before attempting to run it.

***

## Parameters

### Parameter list

| Name            | Type     | Required | Default value                                                | Accepts pipeline input | Description                                                                                        |
| --------------- | -------- | -------- | ------------------------------------------------------------ | ---------------------- | -------------------------------------------------------------------------------------------------- |
| `HealthChecker` | `bool`   | Yes      | None (mandatory, must be supplied)                           | No                     | Controls whether `HealthChecker.ps1` is executed. If `$true`, the script runs `HealthChecker.ps1`. |
| `LogFile`       | `string` | No       | `"$env:ExchangeInstallPath\Logging\SfMC Discovery\SfMC.log"` | No                     | Declared but **not used** anywhere in the script body. Has no effect on behavior in this version.  |

Additional notes:

*   There are **no aliases** defined for the parameters.
*   The script does **not** declare support for pipeline input on any parameter.

***

## Output

### PowerShell pipeline output

*   The script **does not return any objects to the pipeline**.
*   All meaningful output is written to:
    *   Files on disk (XML, CSV, ZIP).
    *   The Application event log.
    *   The console (via `Write-Host`).

### Files written

All file paths and names below come directly from the script.

| Artifact type            | Location / pattern                                                                                                        | Format          | Description                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------- | --------------- | ---------------------------------------------------------------------------------------------------------- |
| Debug log                | `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings\SfMC-Discovery-<yyyyMMddhhmmss>-Debug.txt"`             | Text            | Logging of script activity. Created and maintained by `Get-NewLoggerInstance` / `Write-LoggerInstance`.    |
| Exchange XML output      | `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings\$ServerName-*.xml"`                                     | CLIXML (`.xml`) | `Export-Clixml` output from Exchange cmdlets (server, CAS, transport, mailbox, DAG, health, etc.).         |
| OS/Hardware CSV output   | `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings\$ServerName-<Key>.csv"`                                 | CSV             | `Export-Csv` output from `GetServerData` for keys like `Disk`, `Partition`, `NetAdapter`, `HotFix`, etc.   |
| HealthChecker output     | `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings\*"` (exact filenames determined by `HealthChecker.ps1`) | Not specified   | Files generated by `HealthChecker.ps1` when `-HealthChecker $true`; format and structure not defined here. |
| Consolidated ZIP archive | `"$env:ExchangeInstallPath\Logging\SfMC Discovery\$ServerName-Settings-<yyyyMMddHHmmss>.zip"`                             | ZIP             | ZIP archive containing all files in the `Server Settings` directory (XML, CSV, and HealthChecker output).  |

### Event log entries

The script writes two events to the **Application** log with source **MSExchange ADAccess**:

| Event ID | Source                | Type        | Message (exact string)                                     |
| -------- | --------------------- | ----------- | ---------------------------------------------------------- |
| 1031     | `MSExchange ADAccess` | Information | `The SfMC Exchange Server discovery script has started.`   |
| 1376     | `MSExchange ADAccess` | Information | `The SfMC Exchange server discovery script has completed.` |

The script also defines helper functions that read events with IDs `1125` and `1031`, but those functions are not invoked.

***

## Examples

> Note: The script file name is not specified in the code. Replace `<ScriptName>.ps1` with the actual file name you are using.

### Example 1: Run discovery without HealthChecker

Run the script and collect Exchange and OS data only.

```powershell
# From an elevated Exchange Management Shell
.\<ScriptName>.ps1 -HealthChecker $false
```

Expected behavior (based on the script):

*   Clears and recreates the `Server Settings` folder under `"$env:ExchangeInstallPath\Logging\SfMC Discovery"`.
*   Runs all Exchange discovery cmdlets and OS collection commands.
*   Writes XML and CSV files into `Server Settings`.
*   Creates a ZIP file named similar to `COMPUTERNAME-Settings-YYYYMMDDHHMMSS.zip` in `"$env:ExchangeInstallPath\Logging\SfMC Discovery"`.
*   Writes event IDs 1031 and 1376 to the Application event log.

### Example 2: Run discovery including HealthChecker

Run discovery and also execute `HealthChecker.ps1`.

```powershell
# From an elevated Exchange Management Shell
.\<ScriptName>.ps1 -HealthChecker $true
```

Expected additional behavior:

*   After collecting Exchange and OS data, the script:
    *   Changes directory to `"$env:ExchangeInstallPath\Scripts"`.
    *   Unblocks and runs `HealthChecker.ps1` with `-OutputFilePath` pointing to `Server Settings`.
*   Any files generated by `HealthChecker.ps1` are included in the final ZIP.

***

## Error handling and troubleshooting

### Error handling in Exchange cmdlets

*   Exchange-related calls are made through `InvokeExchangeCmdlet`, which wraps the invocation in a `try { } catch { }` block:

    *   On success:
        *   The result is piped to `Select-Object` (excluding several technical properties) and then to `Export-Clixml`.
    *   On failure:
        *   Writes to the console:  
            `Failed to run: InvokeExchangeCmdlet` (with `-ForegroundColor Red`).
        *   Calls `InvokeCatchActionError` with a `$CatchActionFunction`, but in this script, **no `CatchActionFunction` is supplied**, so no additional handling occurs.

### Error handling in OS collection (GetServerData)

*   Each command in `$hash` is executed in a `try { } catch { }` block:

    *   On failure:
        *   The script writes a console message:  
            `Error: <ErrorRecord> when running the cmdlet: <CommandName>`
    *   If no results are returned (`$null`), no CSV is written for that key.

### ZIP creation

*   `ZipCsvResults` attempts to create the ZIP with `CreateFromDirectory`.
*   If that fails, it:
    *   Tries to delete the existing ZIP file at the target path (if any).
    *   Opens a ZIP in `update` mode and adds each file individually, catching and warning on failures:  
        `Write-Warning "failed to add"` for affected files.

### Cluster and DAG issues

*   The script calls `(Get-Cluster).Name` unconditionally.
*   If the server is not part of a cluster or the `FailoverClusters` tools are not available, `Get-Cluster` may fail.
*   In that case, the dependent DAG discovery commands may not execute successfully, and the corresponding XML files may not be created.

### Event log and task-related helpers

*   Functions `CheckOrgCollectionStarted` and `CheckServerCollectionStarted` query the Application log and scheduled tasks (`ExchangeOrgDiscovery`, `ExchangeServerDiscovery`), but these functions are not called by the main script.
*   Troubleshooting with these helpers would require manual invocation; their behavior is defined by the script but not integrated.

### General troubleshooting guidance (script-based)

If expected files or ZIP output are missing:

*   Check that:
    *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings"` exists and contains XML/CSV files.
    *   The final ZIP file is present in `"$env:ExchangeInstallPath\Logging\SfMC Discovery"`.
*   Look at the debug log file in `Server Settings` (`SfMC-Discovery-*-Debug.txt`) for timestamped entries describing progress and potential errors.
*   Review the Application event log for event IDs `1031` (start) and `1376` (completion) from `MSExchange ADAccess`.

***

## Limitations

All limitations below are derived directly from the script implementation.

1.  **Local server only**

    *   The main script always uses `$env:COMPUTERNAME` and does not expose any parameter to specify a remote server.
    *   Helper functions for remote invocation (`Invoke-ScriptBlockHandler`, `ConnectRemotePowerShell`) are defined but **not used**.

2.  **Exchange Management Shell dependency**

    *   The script relies on `Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn`.
    *   This means it is designed for on-premises Exchange Management Shell; it does not target Exchange Online PowerShell.

3.  **Single DAG assumption for mailbox data**

    *   DAG discovery uses the **cluster name** from `Get-Cluster` as the DAG identity.
    *   If `Get-Cluster` fails or if the DAG identity does not match the cluster name, DAG-related XML files may not be produced.

4.  **`Set-ADServerSettings` parameter usage**

    *   `InvokeExchangeCmdlet` exposes a `ViewEntireForest` parameter but never passes it to the underlying Exchange cmdlet.
    *   The main script calls `InvokeExchangeCmdlet -Cmdlet "Set-ADServerSettings" -ViewEntireForest:$True`, but the internal invocation does not actually apply `-ViewEntireForest $true`.

5.  **`LogFile` parameter is unused**

    *   The `LogFile` parameter is declared but never referenced.
    *   Changing its value has no effect on the script behavior.

6.  **Potential WMI and module availability**

    *   WMI-dependent commands (`Get-WmiObject`) and PowerShell modules (`Net*`, `ScheduledTasks`) must be present.
    *   On systems where these are missing or restricted, some CSV files will not be generated.

7.  **File system side effects**

    *   On each run, the script **deletes all contents** of the `Server Settings` directory and removes ZIPs matching the local server name in the parent `SfMC Discovery` folder.
    *   This behavior may remove previous data collections for the same server.

8.  **Digital signature considerations**

    *   The script includes a large `SIG # Begin signature block` / `SIG # End signature block` region.
    *   Modifying the script content will invalidate this signature; any signature validation policies may then block execution.

***

## Security and permissions considerations

All statements here are strictly based on the operations visible in the script.

1.  **Event log writes**

    *   The script uses `Write-EventLog` with source `MSExchange ADAccess` to log start and completion events.
    *   This requires permission to write to the Application event log under that source.

2.  **File system access**

    *   Writes to:
        *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings"`
        *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery"` (for ZIP files)
    *   The executing account must have write permissions in these paths.

3.  **Exchange cmdlets**

    *   Calls many Exchange cmdlets that typically require administrative or specialized RBAC roles.
    *   The script does **not** enforce or validate role membership; it assumes the caller has appropriate permissions.

4.  **WMI, registry, and system info**

    *   Uses `Get-WmiObject` for various system components, and reads from `HKLM:\SYSTEM\CurrentControlSet\Control\crashcontrol`.
    *   Typically requires local administrative permissions (or equivalent) to succeed reliably.

5.  **Remote execution helpers**

    *   `Invoke-ScriptBlockHandler` and `ConnectRemotePowerShell` support:
        *   Remote execution with the `-Credential` parameter.
        *   Session options (`New-PSSessionOption -ProxyAccessType NoProxyServer`).
    *   These helpers are **not used in the main script**, but if called manually, they execute script blocks or Exchange cmdlets on remote systems, so credentials should be handled securely.

6.  **HealthChecker.ps1 execution**

    *   When `-HealthChecker $true`, the script unblocks and executes `HealthChecker.ps1`.
    *   Any security considerations of `HealthChecker.ps1` (such as what it reads or modifies) are not visible in this script and are **not specified here**.

***

## FAQ

### Does this script support running against multiple or remote Exchange servers?

No.  
The main script only uses the local computer name via `$env:COMPUTERNAME` and does not accept a server parameter or computer list. While helper functions for remote execution are defined (`Invoke-ScriptBlockHandler`, `ConnectRemotePowerShell`), they are not called in the main workflow.

***

### What happens if a command fails or returns no data?

If an Exchange or OS command fails:

*   `InvokeExchangeCmdlet` and `GetServerData` catch the error and write a message to the console.
*   No XML/CSV file is created for that particular command if the result is `$null`.

There is no explicit “unknown” value written; missing or empty output files indicate that the corresponding data was not captured.

***

### What permissions do I need to run this script successfully?

The script assumes the caller can:

*   Load `Microsoft.Exchange.Management.PowerShell.SnapIn`.
*   Run Exchange cmdlets such as `Get-ExchangeServer`, `Get-MailboxDatabase`, `Get-DatabaseAvailabilityGroup`, etc.
*   Write to:
    *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings"`
    *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery"`
*   Write Application event log entries with source `MSExchange ADAccess`.
*   Query WMI classes and registry keys used in the script.

Exact RBAC roles or local group memberships are **not specified** in the script.

***

### Does this script modify any Exchange or system configuration?

Partially:

*   It calls `Set-ADServerSettings` (without parameters). In Exchange, this cmdlet manipulates directory view settings for the current session; the script does not pass any specific properties.
*   It writes to:
    *   The Application event log (event IDs 1031 and 1376).
    *   The file system under `"$env:ExchangeInstallPath\Logging\SfMC Discovery"`.

The script does **not** change Exchange server roles, databases, connectors, or OS configuration based on any parameters or logic present in the script.

***

### Where are logs and collected data stored?

All collected data and the debug log are written under:

*   Output folder:

    *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings"`

*   Final ZIP archive:

    *   `"$env:ExchangeInstallPath\Logging\SfMC Discovery\$env:COMPUTERNAME-Settings-<timestamp>.zip"`

The debug log file is named similar to:

*   `SfMC-Discovery-<yyyyMMddhhmmss>-Debug.txt` within the `Server Settings` folder.

***

### How can I tell if the script completed successfully?

Based on the script:

*   Check the Application event log for:
    *   Event ID **1031** from source `MSExchange ADAccess` – script started.
    *   Event ID **1376** from source `MSExchange ADAccess` – script completed.
*   Confirm that:
    *   XML and CSV files exist in `"$env:ExchangeInstallPath\Logging\SfMC Discovery\Server Settings"`.
    *   A ZIP file named `"$env:COMPUTERNAME-Settings-<timestamp>.zip"` exists in `"$env:ExchangeInstallPath\Logging\SfMC Discovery"`.

***

If you’d like, I can next help you design a README or runbook snippet for your team that explains when and how to use this script in your Exchange environment.
