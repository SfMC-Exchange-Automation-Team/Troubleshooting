# Find-FileEverywhere

## Applies to

- Windows PowerShell 5.1
- Windows 10 and Windows 11
- Local file system, OneDrive folders, mapped drives, and attached file-system drives

## Summary

`Find-FileEverywhere` searches for files by name across ALL common Windows storage locations. By default, it searches the current user's profile folder on the system drive and then adds sync folders and other mapped or physical drives when those paths are not already covered.


## Script location

Save the script in a PowerShell function or module folder that is appropriate for your environment.

## Function

```powershell
Find-FileEverywhere
```

## Syntax

```powershell
Find-FileEverywhere
    [-SearchString] <String>
    [-FullCDrive]
    [-IncludeContent]
    [-MaxDepth <Int32>]
    [-ExcludePaths <String[]>]
    [-MaxThreads <Int32>]
    [-Quiet]
    [<CommonParameters>]
```

## Description

`Find-FileEverywhere` builds a list of search roots and scans each root in parallel by using a runspace pool. If the search string does not contain `*` or `?`, the function automatically wraps it in wildcards so that a search for `budget` behaves like `*budget*`.

The function returns structured objects to the pipeline. It also writes progress-style status messages to the host unless `-Quiet` is specified.

<img width="576" height="384" alt="image" src="https://github.com/user-attachments/assets/c7a0bac1-8d05-46c9-a124-8f4aa7360fdb" />


## Search roots

The function searches these locations when available:

| Order | Location | Notes |
| --- | --- | --- |
| 1 | User profile on the system drive | Default behavior unless `-FullCDrive` is used. |
| 2 | Full system drive | Used when `-FullCDrive` is specified or as a fallback if the user profile cannot be found. |
| 3 | Personal OneDrive | Added when configured and not already covered by another root. |
| 4 | Corporate OneDrive | Added when configured and not already covered by another root. |
| 5 | Other file-system drives | Includes mapped and physical drives other than the system drive. |

The Scout fork normalizes directory paths and uses path-boundary checks to avoid duplicate scans. For example, it avoids treating one similarly named profile directory as covered only because another profile directory has a shared prefix.

## Parameters

| Parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `SearchString` | `String` | Yes | None | File name text or wildcard pattern to search for. If no wildcard is supplied, the value is wrapped with `*`. |
| `FullCDrive` | `Switch` | No | Off | Searches the full system drive instead of only the current user's profile. |
| `IncludeContent` | `Switch` | No | Off | Searches inside supported text files for the literal search string. |
| `MaxDepth` | `Int32` | No | `0` | Limits recursion depth. `0` means unlimited depth. |
| `ExcludePaths` | `String[]` | No | Empty array | Skips paths containing any provided folder name, partial path, or path string. Matching is case-insensitive. |
| `MaxThreads` | `Int32` | No | Processor count | Sets the maximum number of parallel runspaces. Valid range is `1` through `64`. |
| `Quiet` | `Switch` | No | Off | Suppresses host status messages and visibility pauses. Results are still returned to the pipeline. |

## Examples

### Example 1: Search for a file name fragment

```powershell
. ".\Find-FileEverywhere-Scout.ps1"
Find-FileEverywhere -SearchString "budget"
```

Searches for file names containing `budget`. Because no wildcard is provided, the function searches as `*budget*`.

### Example 2: Search for Excel files across the full C drive

```powershell
Find-FileEverywhere -SearchString "*.xlsx" -FullCDrive
```

Searches the full system drive, sync folders, and other discovered drives for `.xlsx` files.

### Example 3: Search file names and supported text file contents

```powershell
Find-FileEverywhere -SearchString "Contoso" -IncludeContent -MaxDepth 5 -ExcludePaths @("node_modules", ".git", "AppData")
```

Searches file names and common text file contents for `Contoso`, limits recursion depth to five levels, and skips common noisy directories.

### Example 4: Return results without status messages

```powershell
$results = Find-FileEverywhere -SearchString "invoice" -Quiet
$results | Format-Table FileName, FullPath, LastModified -AutoSize
```

Suppresses status messages and pauses, which is useful for automation or when assigning output to a variable.

### Example 5: Limit parallelism

```powershell
Find-FileEverywhere -SearchString "*.ps1" -MaxThreads 4
```

Limits the search to four parallel runspaces, which can be useful on slower disks or network drives.

## Output

The function returns one object per matching file.

| Property | Description |
| --- | --- |
| `MatchType` | `FileName` when the file name matched, or `Content` when only file content matched. |
| `FileName` | Name of the matching file. |
| `FullPath` | Full file-system path to the matching file. |
| `SizeKB` | File size in kilobytes, rounded to two decimal places. |
| `LastModified` | Last write time of the file. |
| `DriveRoot` | Friendly label for the root where the match was found. |
| `ContentMatch` | First matching content line preview when `-IncludeContent` finds a match. Long previews are truncated to 200 characters. |

## Supported content-search file types

When `-IncludeContent` is specified, the function searches files with these extensions:

```text
.txt, .log, .csv, .ps1, .psm1, .psd1, .xml, .json, .yaml, .yml,
.md, .html, .htm, .css, .js, .ts, .py, .cfg, .ini, .conf, .bat, .cmd
```

Files larger than 50 MB are skipped during content search.

## Operational notes

- The function uses `Get-ChildItem -Recurse` for file discovery.
- File-name searches use the `-Filter` parameter for efficient provider-side filtering.
- Content searches use `Select-String -SimpleMatch -List` so each file stops scanning after the first matching line.
- Access-denied and search errors are counted internally and emitted through verbose output.
- Results are sorted by `DriveRoot` and then `FileName`.
- Status messages use correct singular/plural wording, such as `1 match found` or `2 matches found`.
- User-visible pauses are intentionally preserved for interactive visibility and are suppressed by `-Quiet`.

## Troubleshooting

### No files matched the search string

Confirm that the search string is correct. If you are using wildcards, verify that the pattern matches the file name exactly as expected.

```powershell
Find-FileEverywhere -SearchString "*report*"
```

### The search takes too long

Use `-MaxDepth`, `-ExcludePaths`, or `-MaxThreads` to reduce the search scope.

```powershell
Find-FileEverywhere -SearchString "report" -MaxDepth 4 -ExcludePaths @("AppData", "node_modules", ".git") -MaxThreads 4
```

### Content search misses a file

Verify that the file extension is in the supported text extension list and that the file is 50 MB or smaller.

### Access-denied folders are encountered

The function continues when access-denied errors occur. Run with `-Verbose` to see total error counts at the end of execution.

```powershell
Find-FileEverywhere -SearchString "report" -Verbose
```

## Change history

| Version | Date | Notes |
| --- | --- | --- |
| Initial Release (Scout fork) | 2026-06-17 | Added safer path de-duplication, `-MaxThreads`, `-Quiet`, improved cleanup, counted search errors, first-match content scanning, preserved visibility pauses, and singular/plural match wording. |

