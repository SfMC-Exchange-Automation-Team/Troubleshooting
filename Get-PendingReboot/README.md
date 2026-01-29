*README written by Copilot. Please report mistakes.*

# Get-PendingReboot (PowerShell)

## Summary
**Get-PendingReboot** checks one or more Windows computers for common “pending reboot” indicators and returns a structured, pipeline-friendly result. It is designed for patching workflows, maintenance windows, and health validation, where you need a consistent way to determine whether a reboot is required before proceeding.

> **UNSUPPORTED SCRIPT DISCLAIMER**
>
> This PowerShell function is provided **as-is** as an unsupported script. It is not an official Microsoft product and is not covered by Microsoft Support. Use at your own risk. Validate in a lab and follow your change management and maintenance window processes before using in production.

---

## Symptoms
You may need this function if you are seeing one or more of the following:

- A patching or deployment workflow reports “reboot required” but the reason is unclear.
- A server remains flagged as “pending reboot” after multiple restarts.
- You need to check reboot state across many machines and return results as objects (not strings).
- Remote checks fail intermittently due to WinRM, firewall, name resolution, or authentication issues, and you need those failures categorized.

---

## Cause
Windows reboot requirements do not come from a single universal flag. Different subsystems record “work that must finish at boot” in different ways. This function intentionally checks **multiple** indicators because each one reflects a different class of pending work.

### Why multiple reboot indicators exist

#### 1) `PendingFileRenameOperations` (registry)
Some installers, hotfixes, and servicing operations must replace or delete files that are currently in use. Windows provides the **MoveFileEx** API with the **MOVEFILE_DELAY_UNTIL_REBOOT** option to schedule file rename/delete work for the next boot.   
At startup, **Session Manager** processes these queued rename/delete commands by reading the `HKLM\System\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations` value. 

So, if `PendingFileRenameOperations` has entries, it usually means:  
- “A file operation could not complete while the OS was running, so it was scheduled for boot-time completion.”

#### 2) `pending.xml` (WinSxS servicing file)
Windows Component-Based Servicing (CBS) maintains “pending” work for updates and servicing operations. Many troubleshooting guides and servicing workflows treat the presence of `%windir%\WinSxS\pending.xml` as a strong signal that servicing work is incomplete and may require a reboot to finish or to unblock other servicing commands. 

So, if `pending.xml` exists, it often means:  
- “Servicing operations have pending actions that have not been fully committed.”

> Note: `pending.xml` is commonly used as a practical reboot heuristic in troubleshooting and servicing guidance.   
> This script uses file presence as an indicator, not as a guarantee of a required reboot in every possible scenario.

#### 3) Why “Unknown” exists (tri-state output)
When the function cannot confidently validate an indicator (for example, remote connectivity is denied), it returns **Unknown** instead of guessing. This prevents false “No reboot required” results when the system could not be checked.

---

## Resolution
### Use the function to detect reboot requirements (local or remote)

#### Step 1: Load the function
Dot-source the script or add it to your function library/profile.

```powershell
. .\Get-PendingReboot.ps1
````

#### Step 2: Run checks

**Local computer**

```powershell
Get-PendingReboot
```

**Multiple computers**

```powershell
'EXCH01','EXCH02' | Get-PendingReboot | Select Server, RebootRequired
```

**Interactive mode (status + optional reboot prompt)**

```powershell
Get-PendingReboot -Server EXCH01 -ShowStatus -Prompt
```

If you use `-Prompt` and a reboot is detected, the function can initiate a reboot via `Restart-Computer`. [\[woshub.com\]](https://woshub.com/windows-keeps-asking-to-restart/)

***

## How it works

### Connection preflight (remote targets)

For remote servers, the function performs prechecks before querying indicators:

1.  **DNS resolution check** using `[System.Net.Dns]::GetHostEntry()` to catch name-resolution or invalid target issues early.
2.  **WinRM preflight** using `Test-WSMan` to verify the WinRM endpoint is reachable. `Test-WSMan` submits an identification request to determine whether the WinRM service is running on a local or remote computer. [\[winhelponline.com\]](https://www.winhelponline.com/blog/dism-error-3017-reboot-required/)

### Indicator checks (local or remote)

Minimum indicator set checked:

*   Registry value: `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations`
*   File existence: `%windir%\WinSxS\pending.xml`

### Result logic

*   `RebootRequired = True` if **either** indicator is present.
*   `RebootRequired = False` if both indicators are absent.
*   `RebootRequired = Unknown` if the function cannot complete required checks (for example, remote access denied).

***

## Parameters

### `-Server` (aliases: `ComputerName`, `CN`, `Computer`)

One or more target computer names. Accepts pipeline input.

```powershell
Get-PendingReboot -Server EXCH01,EXCH02
```

### `-Prompt`

If set and a reboot is required, prompts whether to reboot the target. If the user selects “Y”, it calls `Restart-Computer -ComputerName <target> -Force`. [\[woshub.com\]](https://woshub.com/windows-keeps-asking-to-restart/)

### `-ShowStatus`

If set, emits console status lines (`Write-Host`) intended for interactive runs.  
When running against multiple targets or pipeline input, the function suppresses status lines by default to avoid noisy pipelines.

***

## Output

The function returns a `PSCustomObject` for each target with tri-state fields.

| Field                          | Meaning                                             | Values                     |
| ------------------------------ | --------------------------------------------------- | -------------------------- |
| `Server`                       | Target name                                         | String                     |
| `RebootRequired`               | Aggregated reboot state based on checked indicators | `True`, `False`, `Unknown` |
| `RegistryPending`              | Whether `PendingFileRenameOperations` has entries   | `True`, `False`, `Unknown` |
| `PendingXmlPresent`            | Whether `%windir%\WinSxS\pending.xml` exists        | `True`, `False`, `Unknown` |
| `RemoteConnectionDenied`       | Whether remote connectivity prevented checks        | `True`, `False`            |
| `RemoteConnectionDeniedClass`  | Classified reason for remoting failure              | String or null             |
| `RemoteConnectionDeniedReason` | Friendly explanation of denial class                | String or null             |

***

## Remoting failure classification (and console colors)

When `-ShowStatus` is used and the function detects a remoting failure, it prints a single status line:

*   **Yellow**: “Soft” failures (currently name resolution or invalid target)
*   **Red**: “Blocked” failures (WinRM unreachable, refused, auth issues, access denied, timeouts, etc.)

| Class                       | Color  | What it usually means                                   |
| --------------------------- | ------ | ------------------------------------------------------- |
| `NameResolutionOrBadTarget` | Yellow | DNS resolution failed or target name is invalid         |
| `ConnectionBlocked`         | Red    | WinRM unreachable or blocked (firewall/service/network) |
| `ConnectionRefused`         | Red    | Remote host refused WSMan/WinRM connection              |
| `WinRMClientCannotProcess`  | Red    | WinRM client cannot process request (auth/trust/config) |
| `AccessDenied`              | Red    | Access denied (permissions/authorization)               |
| `AuthOrTrustConfig`         | Red    | Kerberos/TrustedHosts/HTTPS/authentication problem      |
| `Timeout`                   | Red    | WinRM connection timed out                              |
| `SessionOpenFailed`         | Red    | Failed to open WSMan/WinRM session                      |
| `Unknown`                   | Red    | Unclassified remoting failure                           |

***

## Practical guidance: interpreting results

### When `RebootRequired = True`

At least one indicator suggests reboot-requiring work is pending. Typical reasons:

*   Boot-time file rename/delete operations scheduled via `PendingFileRenameOperations`. [\[github.com\]](https://github.com/Huachao/azure-content/blob/master/markdown%20templates/markdown-template-for-support-articles-troubleshoot.md), [\[github.com\]](https://github.com/Huachao/azure-content/blob/master/markdown%20templates/markdown-template-for-support-articles-cause-resolution.md?plain=1)
*   Servicing work still pending as indicated by `pending.xml`. [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexa), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/sysinternals/downloads/pendmoves)

### When `RebootRequired = False`

Neither indicator is present based on what this function checks. This does not guarantee there are no other reboot signals outside the minimum set.

### When `RebootRequired = Unknown`

The function could not complete checks (most commonly due to remote connectivity denial). Treat this as “needs attention” rather than “no reboot required.”

***

## Requirements

*   **Windows PowerShell 5.1**
*   For remote checks:
    *   WinRM enabled and reachable
    *   `Test-WSMan` must succeed for the target (used as a preflight) [\[winhelponline.com\]](https://www.winhelponline.com/blog/dism-error-3017-reboot-required/)

***

## References

*   Microsoft Learn: `Test-WSMan` (WinRM connectivity check) [\[winhelponline.com\]](https://www.winhelponline.com/blog/dism-error-3017-reboot-required/)
*   Microsoft Learn: `Restart-Computer` (reboot behavior) [\[woshub.com\]](https://woshub.com/windows-keeps-asking-to-restart/)
*   Microsoft Learn: Sysinternals PendMoves and MoveFile (Session Manager reads `PendingFileRenameOperations`) [\[github.com\]](https://github.com/Huachao/azure-content/blob/master/markdown%20templates/markdown-template-for-support-articles-troubleshoot.md)
*   Microsoft Learn: `MoveFileEx` API (supports delayed rename/delete until reboot) [\[github.com\]](https://github.com/Huachao/azure-content/blob/master/markdown%20templates/markdown-template-for-support-articles-cause-resolution.md?plain=1)
*   Microsoft Learn contributor guidance: Markdown reference (general markdown authoring) [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/restart-computer?view=powershell-7.5)
*   Support article markdown templates (Cause/Resolution and Troubleshoot) [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/powershell/module/microsoft.wsman.management/test-wsman?view=powershell-7.5), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/contribute/content/markdown-reference)
*   Examples of servicing guidance where `pending.xml` is treated as a pending servicing indicator [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexa), [\[learn.microsoft.com\]](https://learn.microsoft.com/en-us/sysinternals/downloads/pendmoves)

***

## Author and version history

*   **Author**: Cullen Haafke (Microsoft, SfMC)
*   **Compatibility**: Windows PowerShell 5.1
*   **Version**: 1.0.0
*   **Version History**
    *   01/28/2026 - 1.0.0 | Initial release (basic checks: `PendingFileRenameOperations` + `pending.xml`)

```
