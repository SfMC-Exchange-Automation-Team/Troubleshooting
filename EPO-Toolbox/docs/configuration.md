---
title: Configure the EPO Toolbox
description: Understand the current EPO Toolbox configuration file and how it drives stage awareness and Stage 1 SOP analysis.
ms.date: 07/21/2026
ms.topic: reference
---

# Configure the EPO Toolbox

The EPO Toolbox uses a PowerShell data file for configuration:

```powershell
Config\ExchangeCuPatch.config.psd1
```

The configuration file controls stage routing, environment metadata, output defaults, and dynamic Stage 1 findings.

## Top-level settings

| Setting | Description |
| --- | --- |
| `CustomerName` | Customer or tenant label written to run metadata. |
| `Environment` | Environment label written to run metadata, such as `Production`, `QA`, or `Lab`. |
| `RunRoot` | Intended central run output root. Stage 1 currently uses `-OutputRoot` or `%TEMP%\ExchangeCuDagPatch` unless a caller passes this value in. |

## StageAwareness

`StageAwareness` defines the current stage and the ordered patching workflow.

```powershell
StageAwareness = @{
    CurrentStage = 'SopAnalysis'
    StageOrder = @(
        'SopAnalysis'
        'UpdateInventory'
        'DagDiscovery'
        'PreCheck'
        'Maintenance'
        'PackagePrep'
        'Install'
        'PostCheck'
        'Rollback'
        'Report'
    )
}
```

When the main entry point is run with `-Stage Auto`, it uses `StageAwareness.CurrentStage` to select the implementation to run.

Only `SopAnalysis` is implemented today. Other stages are reserved and produce a clear not-implemented error if selected.

## SopAnalysis

`SopAnalysis` contains metadata about the current SOP and risk thresholds.

| Setting | Description |
| --- | --- |
| `SopName` | Friendly SOP name used for documentation and future reports. |
| `SopVersion` | SOP version label. |
| `Sources` | List of SOP or meeting-note sources that informed the analysis. |
| `RiskThresholds.BlockOnCritical` | When true, blocked critical findings can block the overall stage result. |
| `RiskThresholds.WarnOnHigh` | Reserved for warning behavior as high-severity findings are expanded. |

## Package

`Package` contains CU media values used by Stage 1 to determine whether package staging requirements are complete.

| Setting | Description |
| --- | --- |
| `CuIsoPath` | Full path to the Exchange CU ISO. Empty values produce a Stage 1 warning. |
| `ExpectedIsoHash` | Expected hash for CU media validation. Empty values produce a Stage 1 warning. |
| `ExtractRoot` | Local extraction root for CU media preparation. |

Stage 1 does not mount, extract, hash, or unblock files. It only identifies whether required package inputs are present.

## Services

`Services` defines service names that the toolbox needs to reason about.

| Setting | Description |
| --- | --- |
| `SplunkForwarderName` | Splunk forwarder service name. Defaults to `splunkForwarder`. |
| `CrowdStrikeServiceNames` | CrowdStrike service names to capture during AV readiness checks. Defaults to `CSFalconService`. |

Future stages should record original service startup type and status before changing runtime state.

## LoadBalancer

`LoadBalancer` defines how load balancer handling is represented.

| Setting | Description |
| --- | --- |
| `Mode` | Supported design values are `None`, `Manual`, or `Script`. Current default is `None`. |
| `AdapterScriptPath` | Path to a future load balancer adapter script when `Mode` is `Script`. |

Stage 1 reports `LoadBalancer.Mode = None` as a warning because load balancer requirements are still open.

## Inventory

`Inventory` defines default target servers and evidence behavior for the `UpdateInventory` stage.

| Setting | Description |
| --- | --- |
| `TargetServers` | Default Exchange servers to query when `-TargetServers` is not supplied. |
| `IncludeHotFixInventory` | Reserved switch for hotfix inventory collection behavior. |
| `IncludeSetupLogEvidence` | Reserved switch for setup log evidence collection behavior. |

## GUI-generated configuration

The optional GUI wizard can generate a runtime configuration file under:

```powershell
<OutputRoot>\GuiConfig\ExchangeCuPatch.gui.<CorrelationId>.psd1
```

The generated file uses the same schema as `Config\ExchangeCuPatch.config.psd1` and is passed to unattended execution with `-ConfigPath`.

Do not edit generated GUI config files as the source of truth. Update the base config or rerun the wizard instead.

## Configuration guidance

- Keep credentials out of the configuration file.
- Do not store secrets, tokens, or PAM checkout material in `.psd1` files.
- Use absolute Windows paths.
- Prefer explicit values over inferred defaults for production patch windows.
- Update the configuration article when new config keys are added.
