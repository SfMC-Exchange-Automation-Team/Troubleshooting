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
| `Config\ExchangeCuPatch.config.psd1` | Configuration file for customer/environment metadata, stage awareness, package metadata, Splunk, CrowdStrike, and load balancer settings. |
| `Modules\Epo.Logging.psm1` | Initializes run folders and writes `Run.json`, `Events.jsonl`, evidence JSON, and `Summary.csv`. |
| `Modules\Epo.Stage1.SopAnalysis.psm1` | Produces dynamic SOP gap/risk findings and next-stage input requirements. |

## Article set

| Article | Description |
| --- | --- |
| [Run Stage 1 SOP analysis](stage-1-sop-analysis.md) | Explains how to run Stage 1 and interpret the output. |
| [Configure the EPO Toolbox](configuration.md) | Documents `ExchangeCuPatch.config.psd1` settings. |
| [Output and evidence reference](output-reference.md) | Describes generated run folders and output artifacts. |

## Stage model

The toolbox tracks these stages in `Config\ExchangeCuPatch.config.psd1`:

1. `SopAnalysis`
2. `DagDiscovery`
3. `PreCheck`
4. `Maintenance`
5. `PackagePrep`
6. `Install`
7. `PostCheck`
8. `Rollback`
9. `Report`

Only `SopAnalysis` is implemented today. Later stages should follow the same pattern: no silent state changes, structured events, evidence output, and clear next-stage requirements.

## Documentation maintenance

Update these Markdown files whenever scripts, configuration, runtime assumptions, process stages, or output formats change.
