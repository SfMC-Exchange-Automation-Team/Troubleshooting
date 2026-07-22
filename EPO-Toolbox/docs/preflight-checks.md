---
title: Run EPO Toolbox preflight checks
description: Use the EPO Toolbox PreCheck stage to detect pending reboot state before Exchange patching.
ms.date: 07/22/2026
ms.topic: how-to
---

# Run EPO Toolbox preflight checks

The `PreCheck` stage runs read-only checks before Exchange patching. The current implementation detects whether target servers are pending a reboot by using the packaged `Get-PendingReboot.ps1` function.

Pending reboot state is a blocking preflight condition because Exchange setup can fail or behave unpredictably when a server requires a reboot.

## Packaged script

The toolbox includes this script:

```powershell
Scripts\Get-PendingReboot.ps1
```

The source script was added from:

```powershell
C:\Users\cuhaafke\OneDrive - Microsoft\Scripting\PowerShell\Function Library\Get-PendingReboot.ps1
```

The toolbox references the packaged copy by default through:

```powershell
Preflight.PendingRebootScriptPath = '.\Scripts\Get-PendingReboot.ps1'
```

## Run from the shell

Run preflight checks from the project root:

```powershell
.\EPO-Toolbox.ps1 -Stage PreCheck -TargetServers EXCH01,EXCH02 -ValidationOnly
```

The shell displays the request and summary table so the operator can see the pending reboot check in real time.

## Run from the GUI

Launch the dashboard:

```powershell
.\EPO-Toolbox.ps1 -Gui
```

The dashboard includes a **Preflight pending reboot request** panel. Use **Refresh preflight** to run the same pending reboot check and display server status in the GUI.

The GUI and shell use the same `Invoke-EpoPreflightCheck` object.

## Preflight object

The stage returns an object with this structure:

```powershell
[pscustomobject]@{
    PreflightSchemaVersion = '1.0'
    CollectedAtUtc = '<UTC timestamp>'
    Status = 'Pass | Warning | Blocked'
    Severity = 'Info | Warning | Critical'
    Checks = @('PendingReboot')
    Servers = @()
}
```

Each server row includes:

| Field | Description |
| --- | --- |
| `Server` | Target server name. |
| `Status` | `Pass`, `Warning`, or `Blocked`. |
| `Severity` | `Info`, `Warning`, or `Critical`. |
| `Blocked` | Boolean value indicating whether patching should stop for this server. |
| `PendingReboot.RebootRequired` | `True`, `False`, or `Unknown`. |
| `PendingReboot.ConnectionMethod` | `Local`, `WinRM`, `Fallback`, or `None`. |
| `PendingReboot.RemoteConnectionFailureReason` | Connection or collection failure detail when available. |

## Blocking behavior

Current config defaults:

```powershell
Preflight = @{
    EnablePendingRebootFallback = $true
    IncludeSccmRebootState = $false
    BlockOnPendingReboot = $true
    BlockOnUnknownRebootState = $true
}
```

With these defaults:

- `RebootRequired = True` blocks patching.
- `RebootRequired = Unknown` blocks patching.
- `RebootRequired = False` passes the pending reboot gate.

## Output files

The stage writes:

| File | Description |
| --- | --- |
| `Evidence\Preflight.json` | Full preflight object. |
| `Evidence\Preflight.csv` | Flattened pending reboot check rows. |
| `Events.jsonl` | Start and completion events. |
