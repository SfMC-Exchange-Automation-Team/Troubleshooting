---
title: Use the EPO Toolbox GUI dashboard and wizard
description: Launch the optional EPO Toolbox GUI, review operational panels, and map wizard values to unattended PowerShell execution.
ms.date: 07/22/2026
ms.topic: how-to
---

# Use the EPO Toolbox GUI dashboard and wizard

The EPO Toolbox includes an optional Windows Forms GUI mode. The GUI opens to an operational dashboard and can launch a wizard.

The GUI does not replace unattended execution. Every dashboard and wizard value maps to PowerShell parameters or configuration values so the same run can be repeated from the command line.

## Launch the GUI

Run the toolbox with `-Gui`:

```powershell
cd 'C:\Users\cuhaafke\OneDrive - Microsoft\Documents\Microsoft Scout\EPO-Toolbox'
.\EPO-Toolbox.ps1 -Gui
```

You can combine `-Gui` with the same parameters used by unattended mode:

```powershell
.\EPO-Toolbox.ps1 `
    -Gui `
    -Stage SopAnalysis `
    -ValidationOnly `
    -OutputRoot '\\central-share\ExchangeCU\Runs'
```

## Startup prerequisite evidence

The dashboard runs `Test-EpoGuiPrerequisites` from `Modules\Epo.Gui.psm1`, but it does not show the prerequisite grid on the landing page. The checks are stored as evidence for troubleshooting and error handling.

Startup prerequisite evidence is written under:

```powershell
<OutputRoot>\GuiPrerequisites\
```

The files are:

| File | Description |
| --- | --- |
| `GuiPrerequisites.<CorrelationId>.json` | Full prerequisite result object. |
| `GuiPrerequisites.<CorrelationId>.csv` | Flat prerequisite rows for quick review. |

Current prerequisite checks include:

| Check | Blocking behavior | PowerShell mapping |
| --- | --- | --- |
| PowerShell runtime | Warns if the session is not Windows PowerShell 5.1. | `$PSVersionTable.PSVersion` |
| Windows Forms GUI | Blocks if `System.Windows.Forms` or `System.Drawing` cannot load. | `Add-Type -AssemblyName System.Windows.Forms,System.Drawing` |
| Configuration file | Blocks if the config file is missing or cannot be imported. | `-ConfigPath` |
| Implemented stage | Passes for `SopAnalysis`; warns for reserved stages. | `-Stage` |
| Toolbox files | Blocks if required scripts or modules are missing. | `$PSScriptRoot` |
| Output root | Blocks if the output root cannot be created or written to. | `-OutputRoot` |

The dashboard shows a short status line with the evidence path. The **Open wizard** button is disabled when any startup prerequisite is blocked.

## Server dashboard landing page

The GUI landing page defaults to a server dashboard. When the Exchange Management Shell cmdlets are available, the default view attempts to show the DAG that contains the server running the toolbox.

Use the **View** drop-down to switch between:

| View | Description |
| --- | --- |
| `Current DAG` | Servers in the DAG that contains the local server running the toolbox. This is the default view. |
| `Current AD site` | Exchange servers in the local server's Active Directory site. |
| `All Exchange servers` | All Exchange servers returned by `Get-ExchangeServer`. |

If Exchange cmdlets are not available, the dashboard falls back to the local computer and records the discovery limitation in the status model.

The server grid is a framework view that currently displays:

| Column | Source |
| --- | --- |
| `Server` | Exchange topology discovery or fallback target list. |
| `Patch` | Exchange setup build from inventory evidence. |
| `CU` | Common CU name resolved from the Exchange build when possible. |
| `Reboot` | Pending reboot state from the preflight check. |
| `.NET` | .NET Framework version detected by preflight. |
| `Compile` | Whether `mscorsvw.exe` is currently running. |
| `Maint` | Maintenance mode state from `Get-ServerComponentState` when available. |
| `Ping` | ICMP reachability. |
| `RDP` | Quiet TCP 3389 probe. This is a placeholder for a richer RDP/connectivity test later. |
| `WinRM` | `Test-WSMan` result. |

Use **Refresh dashboard** to rerun discovery and status collection.

## Wizard steps

The wizard uses three tabs.

| Step | Purpose |
| --- | --- |
| `1. Runtime` | Captures stage, validation-only mode, output root, correlation ID, customer name, and environment. |
| `2. Stage values` | Captures package, Splunk, CrowdStrike, and load balancer values that currently feed Stage 1 analysis and future patching stages. |
| `3. Review` | Shows the generated unattended command and lets the operator copy it. |

## Unattended mapping

The GUI builds a runtime model with `New-EpoGuiRuntimeModel`. The model maps UI values to these PowerShell values:

| GUI value | PowerShell value |
| --- | --- |
| Stage | `-Stage` |
| Validation only | `-ValidationOnly` |
| Output root | `-OutputRoot` |
| Correlation ID | `-CorrelationId` |
| Target servers | `-TargetServers` |
| Config path | `-ConfigPath` |
| Customer name | `CustomerName` in the generated config file |
| Environment | `Environment` in the generated config file |
| CU ISO path | `Package.CuIsoPath` |
| Expected ISO hash | `Package.ExpectedIsoHash` |
| Extract root | `Package.ExtractRoot` |
| Splunk service | `Services.SplunkForwarderName` |
| CrowdStrike services | `Services.CrowdStrikeServiceNames` |
| Load balancer mode | `LoadBalancer.Mode` |
| Load balancer adapter script | `LoadBalancer.AdapterScriptPath` |

## Update inventory panel

The dashboard server grid includes the update inventory result as patch/build/CU columns. This keeps update inventory visible without requiring a separate landing-page table.

The **Refresh inventory** button calls `Get-EpoExchangeUpdateInventory` and displays:

- Server
- Status
- Exchange build
- Detected CU
- Latest detected HU
- Latest detected SU

The shell equivalent is:

```powershell
.\EPO-Toolbox.ps1 -Stage UpdateInventory -TargetServers EXCH01,EXCH02 -ValidationOnly
```

## Preflight pending reboot and .NET readiness

The dashboard server grid includes key preflight results: pending reboot state, .NET readiness, and `mscorsvw.exe` compile activity.

The shell equivalent is:

```powershell
.\EPO-Toolbox.ps1 -Stage PreCheck -TargetServers EXCH01,EXCH02 -ValidationOnly
```

## Virtual directory health popup

Select a server in the dashboard grid and click **Check virtual directories**.

The current framework opens a popup and attempts to enumerate configured Exchange virtual directories on the selected server by using the available Exchange virtual directory cmdlets:

- `Get-OwaVirtualDirectory`
- `Get-EcpVirtualDirectory`
- `Get-WebServicesVirtualDirectory`
- `Get-MapiVirtualDirectory`
- `Get-ActiveSyncVirtualDirectory`
- `Get-OabVirtualDirectory`
- `Get-PowerShellVirtualDirectory`

For each internal or external URL found, the framework attempts a lightweight HTTP `HEAD` request and records the status code. Authentication-style responses such as `401` or `403` are treated as reachable because many Exchange virtual directories require authentication.

This is intentionally a framework implementation. The response-code policy can be made stricter per virtual directory as customer requirements are confirmed.

## Generated GUI config

When the wizard runs the toolbox, it writes a generated config file under:

```powershell
<OutputRoot>\GuiConfig\ExchangeCuPatch.gui.<CorrelationId>.psd1
```

The generated config file contains the wizard values and is passed back into unattended execution with `-ConfigPath`.

## Copy the unattended command

The dashboard and wizard both show a command preview generated by `ConvertTo-EpoUnattendedCommand`.

Example:

```powershell
& 'C:\...\EPO-Toolbox.ps1' -Stage 'SopAnalysis' -ConfigPath 'C:\...\ExchangeCuPatch.gui.<id>.psd1' -OutputRoot 'C:\...\ExchangeCuDagPatch' -CorrelationId '<id>' -ValidationOnly
```

Use this command for scheduled, scripted, or remote execution after values are confirmed in the GUI.

## UI direction

The EPO Toolbox will continue to use Windows Forms for the GUI so the tool remains PowerShell-first and easy to run on Windows Server systems.

Future GUI work should use modern WinForms techniques where practical:

- Prefer clean dashboard panels over dense grid-first landing pages.
- Keep prerequisite and diagnostic details available as evidence instead of making them the primary visual focus.
- Use consistent spacing, larger controls, and concise status text.
- Keep operational blockers visible with clear color and text.
- Preserve a one-to-one mapping between GUI values and unattended PowerShell parameters or config keys.

## Current limitations

- The GUI currently runs only the implemented `SopAnalysis` stage. Reserved stages can be selected for planning, but they are not implemented yet.
- Startup prerequisite details are stored as evidence rather than shown on the landing page. Operational checks such as update inventory and preflight status remain visible on the dashboard.
- Windows Forms requires a desktop-capable Windows session. Use unattended mode on Server Core or non-interactive hosts.
