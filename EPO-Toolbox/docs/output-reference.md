---
title: EPO Toolbox output and evidence reference
description: Review the run output files produced by the EPO Toolbox and how to interpret Stage 1 evidence.
ms.date: 07/21/2026
ms.topic: reference
---

# EPO Toolbox output and evidence reference

The EPO Toolbox writes structured output for each run. The current Stage 1 implementation writes metadata, event logs, JSON evidence, and a CSV summary.

## Default output path

If `-OutputRoot` is not specified, Stage 1 writes output under:

```powershell
%TEMP%\ExchangeCuDagPatch\<CorrelationId>
```

If `-OutputRoot` is specified, Stage 1 writes output under:

```powershell
<OutputRoot>\<CorrelationId>
```

## Output files

| File | Format | Description |
| --- | --- | --- |
| `Run.json` | JSON | Run metadata such as correlation ID, run ID, stage name, customer, environment, and start time. |
| `Events.jsonl` | JSON Lines | Append-only event stream for run lifecycle events. |
| `Evidence\Stage1.SopAnalysis.json` | JSON | Full Stage 1 result, including findings and next-stage requirements. |
| `Summary.csv` | CSV | Manager-friendly summary of Stage 1 findings. |

## Run.json

`Run.json` is created by `Initialize-EpoRun` in `Modules\Epo.Logging.psm1`.

Example fields:

| Field | Description |
| --- | --- |
| `CorrelationId` | Unique run correlation ID. |
| `RunId` | Current implementation uses the same value as `CorrelationId`. |
| `StageName` | Stage that was run. |
| `CustomerName` | Value from config. |
| `Environment` | Value from config. |
| `StartedUtc` | Run start time in UTC. |

## Events.jsonl

`Events.jsonl` is an append-only JSON Lines file. Each line is one event.

Stage 1 currently writes:

- A `Started` event for the SOP analysis phase.
- A completion event with the final status and severity.

Event fields include:

| Field | Description |
| --- | --- |
| `CorrelationId` | Links events across the same run. |
| `RunId` | Unique run identifier. |
| `DagName` | Empty for Stage 1. Future DAG stages should populate it. |
| `Server` | Empty for Stage 1. Future node stages should populate it. |
| `Phase` | High-level lifecycle phase. |
| `Step` | Step inside the phase. |
| `Command` | Command or script invoked, when applicable. |
| `StartTimeUtc` | Event start time. |
| `EndTimeUtc` | Event end time. |
| `DurationMs` | Duration in milliseconds. Current Stage 1 events use `0`. |
| `Status` | Event status. |
| `Severity` | Event severity. |
| `ExitCode` | Process exit code, when applicable. |
| `RetryCount` | Retry count, when applicable. |
| `Changed` | Indicates whether the step modified state. Stage 1 uses `false`. |
| `RollbackAction` | Reserved for future compensating actions. |
| `EvidencePath` | Related evidence file path, when applicable. |
| `Message` | Human-readable event message. |
| `ErrorRecord` | Serialized PowerShell error information, when provided. |

## Stage1.SopAnalysis.json

The Stage 1 evidence file contains the full result object returned by `Invoke-EpoSopAnalysis`.

Key fields:

| Field | Description |
| --- | --- |
| `CorrelationId` | Unique run correlation ID. |
| `StageAwareness` | Current stage, stage index, total stages, previous stage, next stage, and stage order. |
| `ValidationOnly` | Indicates whether `-ValidationOnly` was used. |
| `Status` | Overall status. |
| `Severity` | Overall severity. |
| `GeneratedUtc` | UTC timestamp for evidence generation. |
| `Findings` | Array of SOP findings. |
| `RequiredInputsForNextStage` | Unique list of data needed before progressing. |
| `NextStage` | Next stage in the configured stage order. |

## Finding fields

Each finding includes:

| Field | Description |
| --- | --- |
| `Phase` | SOP phase or process area. |
| `Area` | Friendly area name. |
| `CurrentSopAction` | What the current SOP does. |
| `GapOrRisk` | Gap or risk identified from the SOP. |
| `AutomationResponse` | Required automation behavior. |
| `Status` | Finding status: `Pass`, `Warning`, `Blocked`, or `NotApplicable`. |
| `Severity` | Finding severity: `Info`, `Warning`, `High`, or `Critical`. |
| `DynamicInputs` | Config or runtime inputs used to evaluate the finding. |
| `RequiredNextData` | Information needed to mature the next implementation stage. |

## Summary.csv

`Summary.csv` contains one row per finding with the most important review fields:

- Correlation ID
- Stage
- Phase
- Area
- Current SOP action
- Gap or risk
- Automation response
- Status
- Severity
- Dynamic inputs

Use `Summary.csv` for quick review and `Stage1.SopAnalysis.json` for complete evidence.
