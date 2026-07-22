---
title: Collect Exchange update inventory
description: Use the EPO Toolbox to collect Exchange CU, HU, and SU installation evidence into a reusable object.
ms.date: 07/22/2026
ms.topic: how-to
---

# Collect Exchange update inventory

The `UpdateInventory` stage collects read-only evidence about installed Exchange Cumulative Updates (CUs), Hotfix Updates (HUs), and Security Updates (SUs). The result is stored in a structured object that later stages can reference.

The stage is safe to run before patching because it does not modify Exchange, Windows services, registry values, DAG membership, or patch media.

## Run from the shell

From the project root, run:

```powershell
.\EPO-Toolbox.ps1 -Stage UpdateInventory -TargetServers EXCH01,EXCH02 -ValidationOnly
```

If `-TargetServers` is omitted, the stage uses `Inventory.TargetServers` from config. If config does not define targets, it collects from the local computer.

The shell displays the inventory request and a summary table so operators can see what was queried.

## Run from the GUI

Launch the dashboard:

```powershell
.\EPO-Toolbox.ps1 -Gui
```

The dashboard includes a visible **Update inventory request** panel. Select or enter target servers in the wizard, or launch the GUI with `-TargetServers`, then use **Refresh inventory** to show the current inventory summary in the GUI.

The GUI uses the same `Get-EpoExchangeUpdateInventory` object as the shell stage.

## Inventory object

The stage returns an object with this structure:

```powershell
[pscustomobject]@{
    InventorySchemaVersion = '1.0'
    CollectedAtUtc = '<UTC timestamp>'
    Servers = @(
        [pscustomobject]@{
            Server = 'EXCH01'
            CollectedAtUtc = '<UTC timestamp>'
            Status = 'Success'
            ExchangeSetup = [pscustomobject]@{
                InstallPath = '<Exchange install path>'
                FileVersion = '<ExSetup.exe file version>'
                ProductVersion = '<ExSetup.exe product version>'
                ExSetupPath = '<ExSetup.exe path>'
            }
            InstalledUpdates = @()
            Evidence = [pscustomobject]@{
                RegistryPaths = @()
                FilePaths = @()
                SetupLogPaths = @()
                Notes = @()
            }
        }
    )
}
```

The returned object also includes `RunPath`, `EvidenceFile`, and `CsvFile` after the stage writes evidence.

## Evidence sources

The inventory stage currently reads:

| Source | Purpose |
| --- | --- |
| `HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup` | Detects Exchange install path and setup version metadata. |
| `ExSetup.exe` file version | Captures the active Exchange setup build. |
| Windows uninstall registry keys | Finds Exchange update entries and classifies them as CU, HU, SU, or Product. |
| `Get-HotFix` | Adds Exchange-related hotfix evidence when available. |
| `C:\ExchangeSetupLogs` | Captures setup/update log file evidence paths and timestamps. |

## Update classification

Update rows include:

| Field | Description |
| --- | --- |
| `Type` | `CU`, `HU`, `SU`, or `Product`. |
| `DisplayName` | Registry or hotfix display name. |
| `KB` | KB identifier parsed from the display name when present. |
| `InstalledOn` | Install date normalized to `yyyy-MM-dd` when possible. |
| `DisplayVersion` | Version from uninstall registry evidence when available. |
| `Publisher` | Publisher from uninstall registry evidence when available. |
| `Source` | Evidence source, such as `UninstallRegistry` or `GetHotFix`. |
| `EvidencePath` | Registry key name or evidence path. |

## Status values

| Status | Meaning |
| --- | --- |
| `Success` | Exchange setup build or update evidence was found. |
| `Warning` | No Exchange setup/update evidence was found. This is expected on non-Exchange machines. |
| `Failed` | Inventory collection failed for the server. The error is stored in `Evidence.Notes`. |

## Output files

The stage writes:

| File | Description |
| --- | --- |
| `Evidence\UpdateInventory.json` | Full inventory object. |
| `Evidence\UpdateInventory.csv` | Flattened server/update rows for review. |
| `Events.jsonl` | Start and completion events. |

## Remote collection

For remote servers, the stage uses PowerShell remoting:

```powershell
Invoke-Command -ComputerName <server>
```

The remote session receives the inventory helper functions and returns the same object shape as local collection.
