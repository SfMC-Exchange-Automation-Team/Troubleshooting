*README written by Copilot. Please report mistakes.*

# Get-PendingReboot

## Summary

`Get-PendingReboot` is a PowerShell function that checks one or more Windows computers for common pending reboot indicators and returns a structured, tri-state result per computer. It evaluates:

*   The `PendingFileRenameOperations` registry value
*   The presence of `pending.xml` in the WinSxS directory

Remote checks use PowerShell Remoting (WinRM) by default, with an optional fallback path that uses Remote Registry and the `ADMIN$` share when WinRM fails. The function can optionally prompt to reboot targets where a pending reboot is detected.

The script includes an **unsupported script disclaimer** in its comment-based help: it is not an official Microsoft product, is not covered by Microsoft Support, and should be validated in a lab and used according to your change management processes.

## Applies to

Based on the script comments and implementation:

*   **PowerShell version**
    *   Windows PowerShell 5.1 (from `.NOTES` → `Compatibility: Windows PowerShell 5.1`)

*   **Operating system / environment**
    *   Windows computers where:
        *   The registry path `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` exists
        *   The `%windir%\WinSxS\pending.xml` file may exist

*   **Remote connectivity mechanisms**
    *   PowerShell Remoting (WinRM) for the primary remote check path (`Test-WSMan`, `Invoke-Command`)
    *   Remote Registry (`[Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey`) when `-EnableFallback` is used and WinRM fails
    *   File share access to `\\<server>\admin$\WinSxS\pending.xml` when `-EnableFallback` is used and WinRM fails

Version details present in the script:

*   `Version: 1.0.0` (in `.NOTES`)
*   History:
    *   `01/28/2026 - 1.0.0 - Initial release (PendingFileRenameOperations + pending.xml)`
    *   `01/29/2026 - 1.0.1 - Single remote hop + fallback option + tri-state propagation fixes`

## What this script does

### Core purpose

For each target computer, `Get-PendingReboot`:

1.  Determines whether it is running locally or remotely.
2.  Checks two indicators:
    *   Registry: `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations`
    *   File: `%windir%\WinSxS\pending.xml`
3.  Aggregates these signals into a tri-state `RebootRequired` value:
    *   `True`  – at least one indicator is positive
    *   `False` – both indicators are present and negative
    *   `Unknown` – insufficient signal data (e.g., failed checks, no signals accessible)
4.  Returns a `PSCustomObject` per target with fields describing:
    *   Reboot state
    *   Individual indicator states
    *   Remote connectivity denial state and classification

It also optionally:

*   Writes status lines to the console (using `Write-Host`) when `-ShowStatus` is used (with some suppression logic).
*   Prompts to restart each target where `RebootRequired` is `True` when `-Prompt` is supplied.
*   Calls `Restart-Computer -ComputerName <target> -Force` when `-Prompt` is used and the user confirms.

### Local checks

For the local computer (where the `Server` name equals `$env:COMPUTERNAME`, case-insensitive), the script:

*   Reads the registry path:

    ```powershell
    Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    ```

    and examines the `PendingFileRenameOperations` value.

*   Builds the local `pending.xml` path:

    ```powershell
    $xmlPath = Join-Path -Path $env:windir -ChildPath 'WinSxS\pending.xml'
    Test-Path -LiteralPath $xmlPath
    ```

*   Uses the helper functions:
    *   `Resolve-RebootRequiredTriState` to combine the two indicators into a tri-state boolean ($true, $false, $null).
    *   `Convert-ToTriStateString` to convert the boolean/null to `"True"`, `"False"`, or `"Unknown"`.

When `-ShowStatus` is enabled and not suppressed:

*   Writes either:
    *   `"Pending reboot detected on <SERVER> (Registry: <value>, pending.xml: <value>)"` (Yellow)
    *   `"No pending reboot detected on <SERVER>"` (Green)
    *   `"Pending reboot state is Unknown on <SERVER> (insufficient signal data)"` (Yellow)

### Remote checks (WinRM primary path)

For remote computers, the function:

1.  Performs a **DNS precheck**:

    ```powershell
    [System.Net.Dns]::GetHostEntry($Target)
    ```

    *   On failure, it classifies the error via `Get-RemotingFailureInfo`, sets `RemoteConnectionDenied` and related fields, and returns without attempting further checks.

2.  Performs a **WinRM preflight**:

    ```powershell
    Test-WSMan -ComputerName $Target -ErrorAction Stop
    ```

3.  Runs a **single remote hop** via `Invoke-Command`:

    The remote scriptblock:

    *   Attempts to read `PendingFileRenameOperations` from:

        ```powershell
        Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        ```

    *   Attempts to check for `%windir%\WinSxS\pending.xml` using `Test-Path`.

    It returns a `PSCustomObject` containing:

    *   `RegValue`
    *   `RegError`
    *   `PendingXmlExists`
    *   `XmlError`

    The caller then:

    *   Interprets `RegValue`/`RegError` into `$regPending` (nullable bool)
    *   Interprets `PendingXmlExists`/`XmlError` into `$xmlPending` (nullable bool)
    *   Computes `RebootRequired` using the same tri-state logic as local checks.

When `-ShowStatus` is enabled and not suppressed, it writes the same success/unknown status messages as for local checks.

### Fallback path (Remote Registry and ADMIN$ share)

If the WinRM-based remote check fails (inside the `try { Test-WSMan + Invoke-Command } catch { ... }` block):

*   The error is classified via `Get-RemotingFailureInfo`.
*   If `-EnableFallback` is **not** specified:
    *   The script sets `RemoteConnectionDenied` and classification fields, writes a status line, and returns.
*   If `-EnableFallback` **is** specified:
    *   The script attempts:

        1.  **Remote Registry**:

            ```powershell
            $base = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $Target)
            $sub  = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager')
            $val  = $sub.GetValue('PendingFileRenameOperations', $null)
            ```

        2.  **ADMIN$ share for pending.xml**:

            ```powershell
            $adminXml = "\\$Target\admin$\WinSxS\pending.xml"
            Test-Path -LiteralPath $adminXml
            ```

    *   It logs fallback errors internally to the `$fallbackErrors` array.

    *   It computes tri-state results from fallbacks in the same way as the primary path.

If **both** fallback signals are unavailable (both remain `$null`):

*   `RemoteConnectionDenied` is set to `$true`.
*   `RemoteConnectionDeniedClass` is set to `'FallbackFailed'`.
*   `RemoteConnectionDeniedReason` contains a combined message describing WinRM failure classification and fallback error details.

If **at least one** fallback signal is available:

*   The script treats the check as successful (no `RemoteConnectionDenied`), and optionally prompts for reboot and writes status lines, as with the primary path.

### Global flags

In the `end` block, the script sets two global variables:

```powershell
$global:RebootRequired         = $script:anyRebootRequired
$global:RemoteConnectionDenied = $script:anyRemoteDenied
```

These reflect whether **any** processed computer had:

*   `RebootRequired` equal to `'True'`
*   `RemoteConnectionDenied` equal to `$true`

## Prerequisites

Based on the script content:

*   **PowerShell**
    *   Windows PowerShell 5.1

*   **Local operations**
    *   Ability to:
        *   Read from `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager`
        *   Access `%windir%\WinSxS\pending.xml` on the local computer

*   **Remote operations (primary path)**
    *   PowerShell Remoting (WinRM):
        *   Uses `Test-WSMan -ComputerName <server>`
        *   Uses `Invoke-Command -ComputerName <server> -ScriptBlock { ... }`

*   **Remote operations (fallback path)**
    *   Remote Registry API:
        *   `[Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey(...)`
    *   File share access to:
        *   `\\<server>\admin$\WinSxS\pending.xml`

*   **General**
    *   DNS name resolution for remote targets using `[System.Net.Dns]::GetHostEntry($Target)`

Any additional environmental or permission prerequisites are **not specified in the script**.

## Parameters

### Parameters table

| Name             | Type       | Required | Pipeline input                                         | Aliases                          | Default                     | Description                                                                                                                                                  |
| ---------------- | ---------- | -------- | ------------------------------------------------------ | -------------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Server`         | `string[]` | No       | `ValueFromPipeline`, `ValueFromPipelineByPropertyName` | `ComputerName`, `CN`, `Computer` | `@($env:COMPUTERNAME)`      | Target computer name(s). Accepts pipeline input. When omitted, the local computer name from `$env:COMPUTERNAME` is used.                                     |
| `Prompt`         | `switch`   | No       | None                                                   | None                             | Not specified in the script | If reboot is detected, prompt to initiate reboot. When confirmed with `Y`, the script calls `Restart-Computer -Force`.                                       |
| `ShowStatus`     | `switch`   | No       | None                                                   | None                             | Not specified in the script | Emit console status lines using `Write-Host`. When running against multiple targets or pipeline input, status output is suppressed to avoid noisy pipelines. |
| `EnableFallback` | `switch`   | No       | None                                                   | None                             | Not specified in the script | When WinRM preflight fails, attempt fallback checks using Remote Registry and the `ADMIN$` share.                                                            |

**Status suppression behavior (for `ShowStatus`):**

*   When `-ShowStatus` is used:
    *   If multiple servers are passed (`$Server.Count -gt 1`) **or**
    *   If input is coming from the pipeline (`$MyInvocation.ExpectingInput`),
    *   Then a local variable `$suppressStatus` is set to `$true`, and status lines for each target are suppressed to reduce noise.

## Output

### Per-target output object

For each server, the function returns a `PSCustomObject` with these properties:

| Field                          | Type                | Values / meaning                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------ | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Server`                       | `string`            | The target name passed in (`$Target`).                                                                                                                                                                                                                                                                                                                                                        |
| `RebootRequired`               | `string`            | Aggregated reboot state as a string: `"True"`, `"False"`, or `"Unknown"`. Computed from registry and pending.xml signals using tri-state logic.                                                                                                                                                                                                                                               |
| `RegistryPending`              | `string`            | `"True"`, `"False"`, or `"Unknown"`. Indicates whether the `PendingFileRenameOperations` registry value was detected as non-null. If the registry check failed, the result is `"Unknown"`.                                                                                                                                                                                                    |
| `PendingXmlPresent`            | `string`            | `"True"`, `"False"`, or `"Unknown"`. Indicates whether `%windir%\WinSxS\pending.xml` (or `\\<server>\admin$\WinSxS\pending.xml` in fallback) exists. If the check failed, the result is `"Unknown"`.                                                                                                                                                                                          |
| `RemoteConnectionDenied`       | `bool`              | `$true` when remote connectivity prevented checks and no usable fallback signals were obtained (for remote targets). `$false` otherwise. Local targets do not set this to `$true`.                                                                                                                                                                                                            |
| `RemoteConnectionDeniedClass`  | `string` or `$null` | Classification of the remote connectivity failure, or `$null` if connectivity was sufficient or the check was local. Possible values observed in the script include: `'Unknown'`, `'NameResolutionOrBadTarget'`, `'ConnectionBlocked'`, `'ConnectionRefused'`, `'WinRMClientCannotProcess'`, `'AccessDenied'`, `'AuthOrTrustConfig'`, `'Timeout'`, `'SessionOpenFailed'`, `'FallbackFailed'`. |
| `RemoteConnectionDeniedReason` | `string` or `$null` | Human-readable explanation of the remote connectivity failure. Derived from the error record or constructed for fallback failures. `$null` when there was no connectivity denial.                                                                                                                                                                                                             |

### Tri-state aggregation logic for `RebootRequired`

The script uses this logic (in `Resolve-RebootRequiredTriState`):

1.  If **either** `RegistryPending` or `PendingXmlPresent` is `$true`  
    → `RebootRequired` = `$true` → `"True"`.
2.  Else if **both** signals are **non-null** and `$false`  
    → `RebootRequired` = `$false` → `"False"`.
3.  Else  
    → `RebootRequired` = `$null` → `"Unknown"`.

### Global variables

After processing all input in the `end` block, the script sets:

*   `$global:RebootRequired`
    *   `[$bool]` flag reflecting whether any processed object had `.RebootRequired -eq 'True'`.
*   `$global:RemoteConnectionDenied`
    *   `[$bool]` flag reflecting whether any processed object had `.RemoteConnectionDenied -eq $true`.

These global variables are kept “for backwards compatibility” according to the inline comment.

## Examples

All examples below are consistent with the script’s parameters and behavior.

### Example 1: Check the local computer

```powershell
Get-PendingReboot
```

Checks the local computer (default `Server` is `@($env:COMPUTERNAME)`) and returns the tri-state reboot status.

### Example 2: Check a single remote computer via pipeline

```powershell
'EXCH01' | Get-PendingReboot | Select Server, RebootRequired
```

Checks a remote computer and selects only the `Server` and `RebootRequired` properties from the output object.

### Example 3: Interactive check with status and reboot prompt

```powershell
Get-PendingReboot -Server EXCH01 -ShowStatus -Prompt
```

*   Shows status messages for the remote check.

*   If a pending reboot is detected, prompts:

    ```text
    Reboot EXCH01? Y/N
    ```

*   If the response matches `'^[Yy]$'`, calls:

    ```powershell
    Restart-Computer -ComputerName EXCH01 -Force
    ```

### Example 4: Multiple remote servers with fallback enabled

```powershell
'EXCH01','EXCH02','EXCH03' |
    Get-PendingReboot -EnableFallback |
    Format-Table Server, RebootRequired, RemoteConnectionDeniedClass
```

*   Uses pipeline input to check multiple remote computers.
*   Enables the fallback path (Remote Registry and `ADMIN$`) when WinRM fails.
*   Displays each server’s reboot requirement and any remoting failure classification.

### Example 5: Using the global flags after a batch run

```powershell
'EXCH01','EXCH02','EXCH03' | Get-PendingReboot | Out-Null

"Any pending reboot detected: $global:RebootRequired"
"Any remote connection denied: $global:RemoteConnectionDenied"
```

*   Runs the checks and discards per-target output.
*   Uses the global variables set in the `end` block to see if **any** server requires a reboot or had remote connectivity denied.

## Error handling and troubleshooting

### Error handling strategy

The script uses multiple `try`/`catch` blocks and helper functions to classify and surface errors:

*   **Name resolution errors**
    *   `Get-HostEntry` calls are wrapped in `try`/`catch`.
    *   Failures are classified via `Get-RemotingFailureInfo` and result in:
        *   `RemoteConnectionDenied = $true`
        *   `RemoteConnectionDeniedClass = 'NameResolutionOrBadTarget'`
        *   `RemoteConnectionDeniedReason = 'Name resolution failed or target invalid'`

*   **WinRM / remoting errors**
    *   Both `Test-WSMan` and `Invoke-Command` are wrapped in a single `try` block.
    *   On exception:
        *   The error is classified in `Get-RemotingFailureInfo` based on message patterns and `FullyQualifiedErrorId`.
        *   If `-EnableFallback` is **not** set:
            *   The script sets `RemoteConnectionDenied = $true` and populates classification fields.
        *   If `-EnableFallback` **is** set:
            *   The script attempts the Remote Registry and `ADMIN$` fallback path.

*   **Registry and pending.xml read errors (local and remote)**
    *   Local:
        *   Failures during `Get-ItemProperty` or `Test-Path` are caught.
        *   On failure, the corresponding local variable (`$regPending`, `$xmlPending`) is set to `$null`.
    *   Remote:
        *   The remote scriptblock records errors as `RegError` and `XmlError` string fields.
        *   The caller treats non-empty error strings as failures and sets corresponding booleans to `$null`.

*   **Fallback errors**
    *   Fallback attempts collect error messages into `$fallbackErrors`:
        *   For Remote Registry failures (e.g., subkey not accessible).
        *   For `ADMIN$` access failures (via `Test-Path`).
    *   If both fallback signals are `$null`, the script:
        *   Sets `RemoteConnectionDenied = $true`
        *   Sets class to `'FallbackFailed'`
        *   Combines WinRM failure class and fallback errors into `RemoteConnectionDeniedReason`.

### Remoting failure classification

`Get-RemotingFailureInfo` inspects the exception message and `FullyQualifiedErrorId` to assign:

*   `NameResolutionOrBadTarget`
*   `ConnectionBlocked`
*   `ConnectionRefused`
*   `WinRMClientCannotProcess`
*   `AccessDenied`
*   `AuthOrTrustConfig`
*   `Timeout`
*   `SessionOpenFailed`
*   `Unknown` (default when no pattern matches)

These are then used as `RemoteConnectionDeniedClass`.

### Status lines and colors

*   **Remote failures**:
    *   `Write-StatusLine` writes a line of the form:

        ```text
        Remoting <SERVER> <Class> <Reason>
        ```

    *   If `StateClass -eq 'NameResolutionOrBadTarget'` → `ForegroundColor = Yellow`

    *   All other classes → `ForegroundColor = Red`

*   **Reboot state messages**:
    *   Pending reboot detected → Yellow text
    *   No pending reboot → Green text
    *   Unknown state → Yellow text

Status lines can be suppressed when processing multiple servers or pipeline input, as described earlier.

### Troubleshooting guidance based on script behavior

*   If `RemoteConnectionDenied = $true`:
    *   Check `RemoteConnectionDeniedClass` and `RemoteConnectionDeniedReason` for the categorized reason.
*   If `RebootRequired = 'Unknown'`:
    *   At least one of the indicator checks produced `$null` (e.g., registry or pending.xml checks failed or were inaccessible).
    *   The script does not provide additional troubleshooting steps beyond verbose messages.

Additional troubleshooting steps beyond what is described here are **not specified in the script**.

## Limitations

The following limitations are directly observable from the implementation:

*   **Indicators checked**
    *   Only two indicators are considered:
        *   `PendingFileRenameOperations` registry value
        *   `%windir%\WinSxS\pending.xml`
    *   Other possible reboot indicators are **not referenced** in the script.

*   **Tri-state behavior**
    *   `RebootRequired` can be `"Unknown"` when:
        *   One or both underlying signals are `$null`.
        *   Fallback or primary remote checks do not produce definitive results.

*   **Remote-only mechanisms**
    *   Remote operations rely on:
        *   DNS (`GetHostEntry`)
        *   WinRM (`Test-WSMan`, `Invoke-Command`)
        *   Optional fallback using Remote Registry and the `ADMIN$` share.
    *   The script does not include alternative remote mechanisms beyond those.

*   **No persistent logging**
    *   The script writes:
        *   Status lines via `Write-Host`
        *   Diagnostic details via `Write-Verbose`
    *   It does **not** write logs to files, event logs, or external systems.

*   **Global state**
    *   The script sets the global variables `$global:RebootRequired` and `$global:RemoteConnectionDenied` in the `end` block.
    *   Reuse of these global variables in other scripts or sessions may require caution; further guidance is **not specified in the script**.

Any additional behavioral limitations beyond the above are **not specified in the script**.

## Security and permissions considerations

From the mechanisms used in the script:

*   **Local access**
    *   Reads from:
        *   `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager`
    *   Checks file existence in:
        *   `$env:windir\WinSxS\pending.xml`

*   **Remote access (primary path)**
    *   Uses PowerShell Remoting:
        *   `Test-WSMan -ComputerName <server>`
        *   `Invoke-Command -ComputerName <server> -ScriptBlock { ... }`

*   **Remote access (fallback path)**
    *   Uses Remote Registry:
        *   `[Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $Target)`
    *   Uses the `ADMIN$` administrative share:
        *   `\\<server>\admin$\WinSxS\pending.xml`

*   **Reboot action**
    *   When `-Prompt` is used and the user answers `Y`:
        *   The script calls:
            ```powershell
            Restart-Computer -ComputerName <target> -Force
            ```

Specific required permissions, user rights, and security configurations for these operations are **not specified in the script**.

## FAQ

### How do I run Get-PendingReboot against multiple computers?

`Server` is a `string[]` parameter that also accepts pipeline input (`ValueFromPipeline` and `ValueFromPipelineByPropertyName`).

Examples:

```powershell
# Array input
Get-PendingReboot -Server 'EXCH01','EXCH02','EXCH03'

# Pipeline input
'EXCH01','EXCH02','EXCH03' | Get-PendingReboot
```

When `-ShowStatus` is used with multiple servers or pipeline input, status lines are automatically suppressed to avoid noisy output.

***

### What does "Unknown" mean for RebootRequired, RegistryPending, or PendingXmlPresent?

The script uses tri-state logic:

*   `RegistryPending` and `PendingXmlPresent` are computed as nullable booleans and then converted to strings:
    *   `$true` → `"True"`
    *   `$false` → `"False"`
    *   `$null` → `"Unknown"`

`RebootRequired` is computed from those:

*   If at least one signal is `$true` → `"True"`.
*   If both signals are non-null and `$false` → `"False"`.
*   Otherwise → `"Unknown"`.

So `"Unknown"` means the script did not have enough reliable signal data from the registry and/or pending.xml checks to determine `True` or `False`.

***

### What connectivity does the script require for remote checks?

For remote targets, the script attempts, in order:

1.  DNS name resolution via:

    ```powershell
    [System.Net.Dns]::GetHostEntry($Target)
    ```

2.  WinRM preflight via:

    ```powershell
    Test-WSMan -ComputerName $Target
    ```

3.  A single-hop remote scriptblock via:

    ```powershell
    Invoke-Command -ComputerName $Target -ScriptBlock { ... }
    ```

If WinRM fails and `-EnableFallback` is used, it then attempts:

*   Remote Registry access via `OpenRemoteBaseKey`
*   File access via the `\\<server>\admin$` share

If all applicable connectivity paths fail to produce usable signals, the script sets:

*   `RemoteConnectionDenied = $true`
*   `RemoteConnectionDeniedClass` and `RemoteConnectionDeniedReason` to describe the failure.

***

### Does the script make any changes to the target computers?

The script primarily **reads** state:

*   Local and remote registry values.
*   Local and remote file existence (pending.xml).

However, when the `-Prompt` switch is used and a pending reboot is detected:

*   The script prompts:

    ```text
    Reboot <SERVER>? Y/N
    ```

*   If the user responds with `Y` (matches `'^[Yy]$'`) and `ShouldProcess` confirms, it calls:

    ```powershell
    Restart-Computer -ComputerName <SERVER> -Force
    ```

This restarts the target computer. Without `-Prompt`, the script does not initiate reboots.

***

### Does the script log to a file or external system?

No.

The script:

*   Returns a `PSCustomObject` per target with detailed properties.
*   Writes status messages via `Write-Host` (optional, controlled by `-ShowStatus` and suppression logic).
*   Writes diagnostic information via `Write-Verbose`.
*   Sets two global variables at the end:
    *   `$global:RebootRequired`
    *   `$global:RemoteConnectionDenied`

It does **not** write to log files, event logs, or external logging systems.

***

### What do the RemoteConnectionDeniedClass values mean?

When `RemoteConnectionDenied` is `$true`, the script sets `RemoteConnectionDeniedClass` to one of several classification strings based on the remoting error. Possible values visible in the script include:

*   `NameResolutionOrBadTarget` – name resolution failed or target is invalid (DNS / network path related).
*   `ConnectionBlocked` – WinRM is unreachable (for example, blocked or unavailable).
*   `ConnectionRefused` – the remote host refused the WSMan/WinRM connection.
*   `WinRMClientCannotProcess` – the WinRM client cannot process the request (auth, trust, or configuration issues).
*   `AccessDenied` – access is denied (permissions or authorization).
*   `AuthOrTrustConfig` – authentication or trust configuration issues (e.g., Kerberos, TrustedHosts, HTTPS).
*   `Timeout` – WinRM connection timed out.
*   `SessionOpenFailed` – failed to open a WSMan/WinRM session.
*   `FallbackFailed` – WinRM failed and the fallback mechanisms (Remote Registry and `ADMIN$`) did not return usable signals.
*   `Unknown` – remoting failed but the error did not match any known patterns.

The corresponding `RemoteConnectionDeniedReason` provides a short, human-readable description.

***

If you plan to publish this in an internal KB or documentation portal, do you want a condensed “operator quick reference” version (focused on examples and result interpretation) in addition to this full article?
