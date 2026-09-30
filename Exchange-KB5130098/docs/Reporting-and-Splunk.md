# Exchange Korean Rules: PowerShell, CSV, JSON, and Splunk reports

This guide applies to `Get-KoreanRulesState.ps1` (Detect only) and
`Set-KoreanRulesState.ps1` (Apply by default; `-Rollback` for local, receipt-bound
rollback). See the [2.0.0 operator guide](../README.md) for prerequisites and
approval/recovery gates. `Install-KoreanRules.ps1` prepares the verified payload
and runtime; its build-result object is not a server-state report.

## Why keep JSON if CSV is easier to read?

JSON, pronounced "Jason," is a structured text format. It keeps field names,
booleans, arrays and nested detail together. It is useful when another script or
system needs to understand the result without scraping a screen or guessing which
spreadsheet column means what.

CSV is a simple table: one row per server, with columns such as ComputerName,
Status, TokenRule, ComplexRule and Error. It is the easiest choice for Excel,
filtering, and sharing a concise inventory.

Both state commands provide these formats without requiring an export switch.

| Output | Use |
|---|---|
| `$report` | Actual PowerShell objects, one flat row per target, retained in the current PowerShell session |
| `$reportFiles` | Paths to this run's JSON, CSV and JSON Lines files |
| `rollout.json` | Detailed report/checkpoint, including nested detection, current state, operation and recovery-attestation data |
| `results.csv` | Default spreadsheet-friendly summary, one row per target |
| `results.jsonl` | Finalized one-JSON-object-per-line summary events for a file collector such as Splunk |

Reports default to `C:\Temp\KB5130098-Reports\<unique-run-id>` on the calling
computer for local and remote runs. `-ReportDirectory` overrides the location.
The directory name is retained for compatibility; the interface migration does
not move reports or operation receipts. `-WhatIf` produces in-memory results but
no persistent reports.

## Run once, then work with the objects

```powershell
.\Get-KoreanRulesState.ps1 -ComputerName EX02.contoso.com

$report
$report | Format-Table ComputerName, Mode, Status, TokenRule, ComplexRule
$report | Where-Object Status -eq 'FailedStop'
$reportFiles
```

The command prints human-readable results and a summary of `$report`. The
variable contains objects, not that formatted display or a JSON string.
The session-level variables are refreshed for each invocation so an earlier run
is not mistaken for the current result.

### Small runs stay detailed; larger runs stay compact

- **1–3 targets:** retain the detailed per-server state/action/next-step blocks.
  Apply and its previews show Before/Current; Detect and rollback show Status.
- **4 or more targets:** automatically omit those detailed blocks, per-target
  progress and target-list dumps. The human output instead ends with aggregated
  **`Status` + `Count`** and report paths, **not a table listing every server**.
- **Errors name the failed target; required interactive recovery prompts still
  appear per server. Neither is suppressed.** A larger restarted rollout still
  pauses for each server's actual workload recovery attestation; compact output
  is not unattended approval.
- Full results remain in `$report`, CSV, detailed JSON and JSONL. Explicit
  `-AsJson` text and `-PassThru` object streams keep their existing contracts;
  the threshold changes only the human display, not the data or target scope.

For example, a reviewed four-server CSV receives compact human output:

```powershell
.\Get-KoreanRulesState.ps1 -CsvPath 'C:\Temp\servers.csv'
$report | Format-Table ComputerName, Mode, Status, TokenRule, ComplexRule
```

The second command explicitly displays the full per-target rows; they are not
automatically enumerated by compact mode. Use `$report | Format-List *` for every
retained field, or filter `$report` to the statuses/servers you need. The summary
counts do not replace or truncate those objects or any export.

Use `-PassThru` when you want explicit pipeline assignment, especially inside a
function that has its own local variable named `report`:

```powershell
$report = .\Get-KoreanRulesState.ps1 -ComputerName EX02.contoso.com -PassThru
$report | Export-Csv -LiteralPath 'C:\Temp\MyReview.csv' -NoTypeInformation -Encoding UTF8
```

Do not assign the normal human-only success stream without `-PassThru`; run the
command normally and then inspect `$report`, or use the example above.
`-AsJson` and `-PassThru` are alternatives, not a combination.
For Excel distribution, prefer the automatic CSV: a manual `Export-Csv` of the
raw objects does not add the script's formula-text protection.

To omit the automatic CSV while retaining the objects and JSON exports:

```powershell
.\Get-KoreanRulesState.ps1 -ComputerName EX02.contoso.com -NoCsv
```

The same reporting options apply to `Set-KoreanRulesState.ps1`; they do not
authorize Apply, restart or rollback. In particular, restarted remote Apply
requires an interactive human workflow and refuses `-AsJson` before connecting.
A JSON `-WhatIf` plan is allowed because it performs no restart or attestation.

The automatic CSV prefixes potentially executable spreadsheet strings with an
apostrophe. JSON and the in-memory objects retain the original text. This avoids
treating an error message beginning with `=`, `+`, `-` or `@` as an Excel formula.
Review report contents before sharing them: hostnames, local paths and error
messages can still be sensitive.

## PowerShell process boundaries

- Extract/copy the complete code package, including the `private` folder and
  shared module. Get, Set and the legacy state wrapper fail explicitly with
  a **package is incomplete** error when those components are missing; a copied
  wrapper alone is not a successful no-op. Restore the complete package.
- Running either state script directly in your existing PowerShell session
  retains `$report` and `$reportFiles` there.
- A new external `powershell.exe` process cannot set variables in an unrelated
  parent shell. Read its saved exports or capture its explicit JSON output.
- Automatic UAC uses a private, data-only result handoff. After the elevated
  window closes, the original invoking session receives the rows and file paths.
  The temporary handoff directory permits only the initiating user, SYSTEM and
  Administrators; it is removed afterward. It contains no credentials or code.
- If an elevation or result handoff fails, the script reports the failure rather
  than inventing success or blindly rerunning the operation.

## Failures, previews and unfinished fleets

The report distinguishes `FailedStop`, `NotRun`, `NoChanges`,
`FilesStagedRestartRequired` and `OperatorConfirmedRecovery`. It does not turn a
file's presence into a recovery claim. These machine status/error keys remain
compatible with the legacy wrappers; the new tool name does not rename them.

From 2.0.1, Set records `RuleFilesPresentStop` and `NotApplicableStop` as expected
skips and continues to later targets, rather than changing those observations to
`FailedStop`. Their Error stays empty. `ActionTaken` explicitly says skipped/no
changes, and `ApplicabilityReason` explains existing/partial rules or found versus
required identity. RestartRequested is intent, not evidence of a performed restart;
skipped targets have RestartCompleted=false and no recovery attestation.
Actual operational failures still halt Set and leave subsequent targets NotRun.

For an interrupted serial rollout, the final exports include the observed failed
target and the untouched targets as `NotRun`. A hard process termination may leave
only the detailed checkpoint, not finalized CSV/JSONL; do not treat that as a
completed run.

CSV, JSON and JSONL export errors are explicit failures. Available in-memory
rows and completed files are retained, but missing files are not claimed as
successful exports. `-WhatIf` and a declined remote plan do not generate files.

## Is JSON Splunk-friendly?

Yes, **with a defined ingestion contract**. Splunk does not become correctly
configured merely because a filename ends in `.json`.

Use **`results.jsonl`**, not `rollout.json`, for new file-monitor ingestion:

- UTF-8 without a byte-order mark.
- Exactly one complete JSON object on each physical line.
- A stable scalar-field schema (`SchemaVersion = 1`).
- `RunId`, `TimestampUtc`, `ComputerName`, `Mode`, `Status` and action/error fields.
- `TimestampUtc` is report-finalization time in UTC, with three fractional digits
  and a literal `Z`; it is not a message-delivery timestamp.
- JSON booleans remain booleans; missing observations remain explicit.
- The finalized JSONL is published once per run, including a graceful failure.
  It is not rewritten for each progress checkpoint.

The detailed `rollout.json` is deliberately rewritten as a fleet progresses.
Monitoring that checkpoint as though every rewrite were a new final event can
create duplicate or misleading results. CSV and JSONL are views of the same
server results; do not ingest both as separate operational events.

## Example Splunk file-monitor setup

These are **configuration examples for the customer's Splunk administrator**,
not settings that the script installs. Review them against the customer's Splunk
version, deployment topology, index policy and access controls. No connection to
the customer's Splunk instance or end-to-end Splunk validation is claimed.

### 1. Input on the collector/forwarder

Use an approved index in place of `YOUR_APPROVED_INDEX`. The Splunk service
identity must be able to read the caller's reports directory.
The example retains the existing `exchange:kb5130098:result` sourcetype and report
path for compatibility; they are not a different product or a migration step.

```ini
[monitor://C:\Temp\KB5130098-Reports\*\results.jsonl]
disabled = 0
index = YOUR_APPROVED_INDEX
sourcetype = exchange:kb5130098:result
crcSalt = <SOURCE>
```

The wildcard covers one per-run subdirectory. Monitor only finalized
`results.jsonl` files, not the `.new` temporary files or detailed checkpoints.
Keep each finalized file at its original path: with `crcSalt = <SOURCE>`, copying
the same event file into another monitored path can ingest it again.

### 2. Event boundaries and timestamp parsing

Place the parsing stanza on the appropriate parsing tier, typically the indexer
or heavy forwarder for ordinary file monitoring, as directed by the Splunk owner:

```ini
[exchange:kb5130098:result]
CHARSET = UTF-8
SHOULD_LINEMERGE = false
LINE_BREAKER = ([\r\n]+)
TIME_PREFIX = "TimestampUtc"\s*:\s*"
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%3NZ
MAX_TIMESTAMP_LOOKAHEAD = 24
TZ = UTC
TRUNCATE = 262144
```

Validate that the event-size limit exceeds the largest record in the customer's
actual error cases. A truncated JSON record is not a valid event.

### 3. Search-time field extraction

On the search-head tier, use:

```ini
[exchange:kb5130098:result]
KV_MODE = json
```

This example chooses **search-time** JSON field extraction. Do not also enable
`INDEXED_EXTRACTIONS = JSON` for the same sourcetype; Splunk's configuration
specification warns that combining them extracts the fields twice.

For an existing ingestion route that already parses JSON at index time, the
Splunk owner should keep that model and adapt the example rather than layering
another extractor over it.

## Validate ingestion before creating alerts

Start with one known test run and a small approved index. Check:

1. The event count equals the number of expected server rows in the JSONL.
2. Each event has the correct RunId, ComputerName, Status and UTC timestamp.
3. `_time` matches TimestampUtc, with no unexpected local-time offset.
4. Fields are not duplicated or multivalued because two extraction models ran.
5. New ingestion has no repeated `(RunId, ComputerName)` pairs.
6. `NotRun` targets are not counted as successfully checked or remediated.

The Splunk metadata `host` normally identifies the collector/calling computer.
Use the exported **ComputerName** field for the Exchange target.

Example searches, after the approved sourcetype is configured:

```spl
index=YOUR_APPROVED_INDEX sourcetype="exchange:kb5130098:result"
| table _time RunId ComputerName Mode Status ActionTaken Error
```

```spl
index=YOUR_APPROVED_INDEX sourcetype="exchange:kb5130098:result"
| stats count by ComputerName Status
```

```spl
index=YOUR_APPROVED_INDEX sourcetype="exchange:kb5130098:result"
| stats count by RunId ComputerName
| where count > 1
```

Do not equate `RestartCompleted=true`, green Present text, or a successful ingest
with workload recovery. RecoveryAttested means an operator supplied the required
attestation; the original workload still needs its documented checks.

## Configuration references

The example was checked against Splunk's published configuration specifications;
confirm the equivalent settings for the installed version:

- [Splunk-owned props.conf specification](https://github.com/splunk/vscode-extension-splunk/blob/9d03f87be69783ad54581518ce1380baeebbc32c/spec_files/9.2/props.conf.spec)
- [Splunk-owned inputs.conf specification](https://github.com/splunk/vscode-extension-splunk/blob/9d03f87be69783ad54581518ce1380baeebbc32c/spec_files/9.2/inputs.conf.spec)
- [Packaged usage and recovery gates](../README.txt)
- [Current three-command workflow and compact-output rules](../README.md)
