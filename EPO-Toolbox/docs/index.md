---
title: EPO Toolbox documentation
description: Learn how the EPO Toolbox orchestrates Exchange Server patching stages and produces structured operational evidence.
ms.date: 07/21/2026
ms.topic: overview
---

# EPO Toolbox documentation

The EPO Toolbox is a stage-aware PowerShell framework for Exchange Server patching operations. The current implementation focuses on Stage 1, **SOP Analysis**, and establishes the toolbox pattern for stage routing, dynamic readiness findings, and structured run evidence.

The project root is:

```powershell
C:\Users\cuhaafke\OneDrive - Microsoft\Documents\Microsoft Scout\EPO-Toolbox
```

## Runtime target

Use Windows PowerShell 5.1 as the default runtime target. On-premises Exchange Management Shell cmdlets are Windows PowerShell based, and Windows Server does not include PowerShell 7 as an inbox component.

PowerShell 7 can be used later for non-Exchange helper utilities only when a script explicitly opts into it.

## Current implementation

| File | Purpose |
| --- | --- |
| `EPO-Toolbox.ps1` | Stage-aware entry point. Resolves `-Stage Auto` from configuration and dispatches implemented stages. |
| `Invoke-ExchangeCuStage1SopAnalysis.ps1` | Runs Stage 1 SOP analysis. This stage makes no Exchange server changes. |
| `Invoke-EpoUpdateInventory.ps1` | Collects read-only Exchange CU, HU, and SU installation evidence. |
| `Invoke-EpoPreflightCheck.ps1` | Runs read-only preflight checks, including pending reboot detection. |
| `Config\ExchangeCuPatch.config.psd1` | Configuration file for customer/environment metadata, stage awareness, package metadata, Splunk, CrowdStrike, and load balancer settings. |
| `Modules\Epo.Logging.psm1` | Initializes run folders and writes `Run.json`, `Events.jsonl`, evidence JSON, and `Summary.csv`. |
| `Modules\Epo.Stage1.SopAnalysis.psm1` | Produces dynamic SOP gap/risk findings and next-stage input requirements. |
| `Modules\Epo.UpdateInventory.psm1` | Builds the reusable update inventory object for Exchange CU, HU, and SU state. |
| `Modules\Epo.Preflight.psm1` | Wraps packaged preflight checks and returns structured pass/warn/block results. |
| `Modules\Epo.Gui.psm1` | Provides the optional Windows Forms dashboard and wizard. GUI values map to unattended PowerShell parameters and config values. |
| `Scripts\Get-PendingReboot.ps1` | Packaged pending reboot detection function used by the PreCheck stage. |

## Article set

| Article | Description |
| --- | --- |
| [Run Stage 1 SOP analysis](stage-1-sop-analysis.md) | Explains how to run Stage 1 and interpret the output. |
| [Collect Exchange update inventory](update-inventory.md) | Explains how to discover installed Exchange CU, HU, and SU evidence. |
| [Run preflight checks](preflight-checks.md) | Explains pending reboot preflight checks and blocking behavior. |
| [Use the GUI dashboard and wizard](gui-dashboard.md) | Explains the optional GUI mode, prerequisite dashboard, wizard steps, and unattended mapping. |
| [Configure the EPO Toolbox](configuration.md) | Documents `ExchangeCuPatch.config.psd1` settings. |
| [Output and evidence reference](output-reference.md) | Describes generated run folders and output artifacts. |

## Stage model

The toolbox tracks these stages in `Config\ExchangeCuPatch.config.psd1`:

1. `SopAnalysis`
2. `UpdateInventory`
3. `DagDiscovery`
4. `PreCheck`
5. `Maintenance`
6. `PackagePrep`
7. `Install`
8. `PostCheck`
9. `Rollback`
10. `Report`

`SopAnalysis`, `UpdateInventory`, and `PreCheck` are implemented today. Later stages should follow the same pattern: no silent state changes, structured events, evidence output, and clear next-stage requirements.

## Documentation maintenance

Update these Markdown files whenever scripts, configuration, runtime assumptions, process stages, or output formats change.
