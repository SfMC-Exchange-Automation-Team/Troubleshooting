# Search-Logfiles

## Summary

`Search-Logfiles` is a PowerShell function that scans files in a specified directory (and optionally its subdirectories) for one or more text strings. If no search string is specified, it defaults to a set of common error-related terms such as “Exception” and “Error”. Matching lines are written to the console and stored in a global variable for later use, with optional export to CSV or XML on the user’s desktop.

## Applies to

*   PowerShell environments that support:
    *   `Get-ChildItem`
    *   `Get-Content`
    *   `Export-Csv`
    *   `Export-Clixml`
    *   `[System.Environment]::GetFolderPath("Desktop")`
*   Local file system paths accessible to the PowerShell session

Any specific PowerShell or operating system version requirements are:

*   Not specified in the script.

## What this script does

At a high level, `Search-Logfiles`:

1.  Accepts:
    *   An optional search string or array of strings.
    *   An optional directory path to search.
    *   Optional switches to:
        *   Search all file types instead of only `.log` files.
        *   Recurse into subdirectories.
        *   Export results to CSV and/or XML on the desktop.

2.  Determines the search terms:
    *   If `-SearchString` is not provided (or is `$null`), it:
        *   Shows a warning to the user.
        *   Uses a default array of common error strings:
            *   `Exception`
            *   `Error`
            *   `Fail`
            *   `Warn`
            *   `Invalid`
            *   `Cannot`
            *   `Unable`
            *   `Timeout`

3.  Determines the search path:
    *   Defaults to the current working directory (`$pwd.Path`) if `-Path` is not provided.
    *   If the default is used, it displays a warning indicating that it is using the current directory.

4.  Validates the path:
    *   Uses `Test-Path -PathType Container` to ensure the specified path exists and is a directory.
    *   If invalid, it writes an error and stops execution.

5.  Enumerates files:
    *   Uses `Get-ChildItem` with:
        *   `Filter = "*.log"` by default, or `*.*` when `-AllFileTypes` is specified.
        *   `-Recurse` when the `-Recurse` switch is used.
    *   Filters out directories by checking `-not $_.PSIsContainer`.

6.  Searches the content:
    *   Reads each file’s content via `Get-Content`.
    *   Iterates line-by-line and term-by-term using:
        ```powershell
        if ($chunk -like "*$searchTerm*")
        ```
    *   For each match:
        *   Writes a message to the host indicating the matched term, file path, and line number.
        *   Creates a custom PowerShell object with:
            *   `FileName`
            *   `Line`
            *   `Error`
        *   Appends the object to a global array: `$global:Results`.

7.  Reports summary:
    *   If any matches are found:
        *   Writes the total count of results to the host.
        *   Indicates that results are stored in `$Results`.

8.  Optional export:
    *   If `-OutputCsv` is used and results exist:
        *   Exports `$global:Results` to a CSV file on the user’s desktop using `Export-Csv`.
    *   If `-OutputXml` is used and results exist:
        *   Exports `$global:Results` to an XML (CliXML) file on the user’s desktop using `Export-Clixml`.
    *   For each export, it writes the full path of the generated file to the host.
    *   If an output switch is used but there are no results, it shows a “No results to export” warning for that format.

## Prerequisites

Based on the script content, the following prerequisites apply:

*   PowerShell session:
    *   A PowerShell environment with support for:
        *   `Get-ChildItem`
        *   `Get-Content`
        *   `Export-Csv`
        *   `Export-Clixml`
        *   `Write-Host`, `Write-Warning`, `Write-Error`
        *   `[System.Environment]::GetFolderPath("Desktop")`
*   File system access:
    *   Read access to the target directory and its files.
    *   Write access to the Desktop folder for CSV/XML export if `-OutputCsv` or `-OutputXml` are used.
*   Path:
    *   A valid directory path (container) when specifying `-Path`.

Any additional software, module, or network prerequisites are:

*   Not specified in the script.

## Parameters

The function definition is:

```powershell
Function global:Search-Logfiles {
    [CmdletBinding()]
    param(
        [Parameter(Position=0, Mandatory=$false, HelpMessage="Search String required")]
        $SearchString,

        [Parameter(Position=1, Mandatory=$False, HelpMessage="Path to search in")]
        $Path = $pwd.Path,

        [Parameter(Position=2, Mandatory=$False, HelpMessage="Export results to CSV on desktop")]
        [Switch]$OutputCsv,

        [Parameter(Position=3, Mandatory=$False, HelpMessage="Export results to XML on desktop")]
        [Switch]$OutputXml,

        [Parameter(Position=4, Mandatory=$False, HelpMessage="Search all file types")]
        [Switch]$AllFileTypes,
       
        [Parameter(Position=5, Mandatory=$False, HelpMessage="Search all subdirectories")]
        [Switch]$Recurse
    )
    ...
}
```

### Parameter reference

| Name           | Type                    | Required | Position | Default     | Accepts pipeline input | Description (from script)                                                       |
| -------------- | ----------------------- | -------- | -------- | ----------- | ---------------------- | ------------------------------------------------------------------------------- |
| `SearchString` | Not specified (untyped) | No       | 0        | `$null`     | No                     | “Search String required”. If omitted/`$null`, defaults to common error strings. |
| `Path`         | Not specified (untyped) | No       | 1        | `$pwd.Path` | No                     | “Path to search in”. Must be a valid directory/container.                       |
| `OutputCsv`    | `[Switch]`              | No       | 2        | `False`     | No                     | “Export results to CSV on desktop”. Exports matches to a CSV file.              |
| `OutputXml`    | `[Switch]`              | No       | 3        | `False`     | No                     | “Export results to XML on desktop”. Exports matches to an XML (CliXML) file.    |
| `AllFileTypes` | `[Switch]`              | No       | 4        | `False`     | No                     | “Search all file types”. Uses `*.*` instead of `*.log` filter.                  |
| `Recurse`      | `[Switch]`              | No       | 5        | `False`     | No                     | “Search all subdirectories”. Adds recursion to directory search.                |

Additional details such as aliases or `ValueFromPipeline` settings are:

*   Not specified in the script (no aliases or pipeline attributes are declared).

## Output

### On-screen output

The function writes status and result messages to the console using `Write-Host`, including:

*   Warnings when:
    *   No search string is specified (defaults to common error strings).
    *   The default path (current working directory) is being used.
    *   No files are found.
    *   Errors occur while accessing a file.
    *   No results are available for CSV/XML export when the switches are specified.
*   Informational messages:
    *   List of files being searched.
    *   For each match: the search term, file name, and line number.
    *   For files with no matches.
    *   A summary count of total results found.
    *   Paths where CSV/XML export files are written.

These are host messages and are not structured PowerShell pipeline output.

### In-memory results (`$global:Results`)

The script populates a global variable `$global:Results` with a collection (array) of custom PowerShell objects when matches are found.

Each object is created as:

```powershell
$obj = New-Object -TypeName PSObject -Property @{
    FileName = $file.FullName
    Line     = $lineNumber
    Error    = $chunk
}
```

#### Result object fields

| Field      | Type   | Description                                       | Derived from                        |
| ---------- | ------ | ------------------------------------------------- | ----------------------------------- |
| `FileName` | String | Full path to the file where the match was found.  | `$file.FullName`                    |
| `Line`     | Int32  | Line number in the file where the match occurred. | Local `$lineNumber` counter         |
| `Error`    | String | Full line content that matched the search term.   | `$chunk` (the current line content) |

The global variable is initialized as an empty array each time the function runs:

```powershell
$global:Results = @()
```

If no matches are found, `$global:Results` remains empty, and no objects are added.

### Exported files (optional)

When results exist and output switches are used, the script creates files on the Desktop:

*   Desktop path:
    ```powershell
    $desktopPath = [System.Environment]::GetFolderPath("Desktop")
    ```

*   CSV export (when `-OutputCsv` is used and results exist):
    *   File name format:
        *   `LogSearchResults - <dd-MMM-yyyy_HHmm>.csv`
    *   Implemented via:
        ```powershell
        $global:Results | Export-Csv -Path $csvPath -NoTypeInformation
        ```

*   XML export (when `-OutputXml` is used and results exist):
    *   File name format:
        *   `LogSearchResults - <dd-MMM-yyyy_HHmm>.xml`
    *   Implemented via:
        ```powershell
        $global:Results | Export-Clixml -Path $xmlPath
        ```

## Examples

> Note: These examples are constructed based on the script’s parameters and behavior. There are no explicit examples in the script comments.

### Example 1: Use default error strings in the current directory

Searches the current working directory for the default error-related terms in all `.log` files (no recursion, no exports).

```powershell
Search-Logfiles
```

Behavior:

*   Path defaults to `$pwd.Path`.
*   Search terms default to:
    *   `Exception`, `Error`, `Fail`, `Warn`, `Invalid`, `Cannot`, `Unable`, `Timeout`
*   Results are stored in `$Results` if any matches are found.

### Example 2: Search for a specific string in a given folder

Searches all `.log` files in `C:\Logs` for the string `Exception` and shows results on screen, without exporting.

```powershell
Search-Logfiles -SearchString "Exception" -Path "C:\Logs"
```

### Example 3: Recurse into subdirectories and search all file types

Searches all file types under `D:\AppLogs`, including subdirectories, for a custom search string.

```powershell
Search-Logfiles -SearchString "Critical failure" -Path "D:\AppLogs" -AllFileTypes -Recurse
```

### Example 4: Export results to CSV on the desktop

Searches the default `.log` files under `C:\Services\Logs` and exports results to a CSV on the desktop.

```powershell
Search-Logfiles -Path "C:\Services\Logs" -OutputCsv
```

### Example 5: Export results to both CSV and XML, then filter in PowerShell

Searches all file types under a directory, recurses into subdirectories, exports results, and then filters them in-memory:

```powershell
Search-Logfiles -SearchString "Timeout" -Path "E:\WebLogs" -AllFileTypes -Recurse -OutputCsv -OutputXml

# Work with the in-memory results
$Results | Where-Object { $_.FileName -like "*frontend*" } | Select-Object FileName, Line
```

## Error handling and troubleshooting

### Path validation

*   If `-Path` is not a valid container (directory):

    ```powershell
    if (-not (Test-Path $Path -PathType Container)) {
        Write-Error "Invalid path: $Path"
        return
    }
    ```

    *   The function writes an error (`Write-Error`) and stops execution (`return`).

### No files found

*   After enumerating files, if none are found:

    ```powershell
    if ($files.Count -eq 0) {
        Write-Host "No log files found in $Path" -ForegroundColor Yellow
        return
    }
    ```

    *   The function writes a warning-like message in yellow and exits without populating `$Results`.

### File access issues

*   Reading file contents is wrapped in a `try`/`catch` block:

    ```powershell
    try {
        $log = Get-Content $file.FullName
        ...
    } catch {
        Write-Warning "Error accessing file $($file.FullName): $_"
    }
    ```

    *   If an exception occurs (e.g., permission denied, locked file), it:
        *   Writes a warning via `Write-Warning`.
        *   Continues with the next file.

### No matches in a file

*   For each file, if no match is found:

    ```powershell
    if ($found -eq $false) {
        Write-Host "No matches found in " -NoNewline
        Write-Host "$($file.FullName)" -ForegroundColor Green
    }
    ```

    *   A message is printed in green indicating that the file had no matches.

### No results to export

*   For CSV:

    ```powershell
    if ($OutputCsv -and $global:Results.Count -gt 0) {
        ...
    }
    else {
        Write-Host "No results to export to CSV" -ForegroundColor Yellow
    }
    ```

*   For XML:

    ```powershell
    if ($OutputXml -and $global:Results.Count -gt 0) {
        ...
    }
    else {
        Write-Host "No results to export to XML" -ForegroundColor Yellow
    }
    ```

If the corresponding switch is set but no results exist, the script explicitly informs you that there are no results to export.

### Troubleshooting tips (based on script behavior)

*   If you see `Invalid path: <Path>`:
    *   Verify that the path exists and points to a directory, not a file.
*   If you see `No log files found in <Path>`:
    *   Confirm your `-Path`.
    *   Consider using `-AllFileTypes` or `-Recurse` if your logs use non-`.log` extensions or are in subdirectories.
*   If you see warnings like `Error accessing file <file>`:
    *   Check permissions and whether the file is locked or in use.
*   If `$Results` appears empty:
    *   No matches were found, or an earlier error caused the function to return before populating it.

## Limitations

All limitations below are derived from observable script behavior:

*   **Local file system only**:
    *   The script operates on paths accessible to the local PowerShell session via `Get-ChildItem` and `Get-Content`.
    *   No support for remote computers is implemented (no `-ComputerName` or remoting logic).

*   **Search pattern behavior**:
    *   The script uses the `-like "*$searchTerm*"` pattern, performing substring matches with wildcard prefix and suffix.
    *   It does not use regular expressions (no `-match`) or case-sensitive operators.

*   **Global state usage**:
    *   Results are stored in `$global:Results`, potentially overwriting any existing global variable with the same name.

*   **File type assumptions**:
    *   When `-AllFileTypes` is used, it attempts to read all files as text via `Get-Content`, which may not be optimal for binary files.

*   **No filtering by metadata**:
    *   The script does not filter by file size, date, or other metadata beyond extension and recursion.

*   **No encoding control**:
    *   The script does not specify encoding in `Get-Content`, relying on PowerShell defaults.

*   **Export dependency on Desktop**:
    *   CSV and XML export paths rely on `[System.Environment]::GetFolderPath("Desktop")`. Environments without a Desktop concept may behave differently.

Any additional constraints not directly visible in the script are:

*   Not specified in the script.

## Security and permissions considerations

From the script’s behavior, the following security-related points apply:

*   **Read-only against existing files**:
    *   The script does not modify or delete any existing files.
    *   It only reads file contents via `Get-Content`.

*   **Creation of new files**:
    *   When `-OutputCsv` and/or `-OutputXml` are used, it writes new files to the Desktop folder:
        *   `LogSearchResults - <timestamp>.csv`
        *   `LogSearchResults - <timestamp>.xml`

*   **Required permissions**:
    *   Read permissions on:
        *   The specified directory (`-Path` or default `$pwd.Path`).
        *   All files within that directory and optional subdirectories (when `-Recurse`).
    *   Write permissions on:
        *   The Desktop folder for export operations.

*   **Scope of results**:
    *   Results are stored in a global variable (`$global:Results`) and are therefore visible outside the function in the current PowerShell session.

Network, elevated, or remote permissions beyond these are:

*   Not specified in the script.

## FAQ

### Does this script support searching multiple remote computers?

No. The script operates only on file paths accessible to the current PowerShell session. It does not include any parameters (such as `-ComputerName`) or remoting logic.

### What happens if no search string is provided?

If `-SearchString` is omitted or `$null`, the script:

*   Notifies you that no search string was specified.
*   Automatically uses the following default search terms:
    *   `Exception`, `Error`, `Fail`, `Warn`, `Invalid`, `Cannot`, `Unable`, `Timeout`.

### How do I know when there are no results?

If no matches are found:

*   Each file will show a message like `No matches found in <file>` in green.
*   `$global:Results` will remain empty (no objects are added).
*   If you specified `-OutputCsv` or `-OutputXml`, you will see:
    *   `No results to export to CSV` and/or `No results to export to XML` in yellow.

### Does the script change or delete any existing files?

No. The script only reads existing files with `Get-Content`. It does not modify or delete them. The only write operations are:

*   Creating new CSV/XML files on the Desktop when `-OutputCsv` and/or `-OutputXml` are used.

### Where are the results stored and how can I use them?

Matches are stored in a global variable named `$Results` (`$global:Results`). Each item has:

*   `FileName`
*   `Line`
*   `Error`

You can further process the results, for example:

```powershell
$Results | Where-Object { $_.Error -like "*timeout*" } | Select-Object FileName, Line, Error
```

### Can I search subdirectories and all file types?

Yes:

*   Use `-Recurse` to search subdirectories.
*   Use `-AllFileTypes` to search all file types (`*.*`) instead of only `.log` files.

Example:

```powershell
Search-Logfiles -Path "C:\Logs" -AllFileTypes -Recurse
```

### What permissions do I need to run this script successfully?

You need:

*   Read permission to the target directory and files.
*   Write permission to your Desktop folder if you use `-OutputCsv` or `-OutputXml`.

The script does not contain any additional elevation or credential-handling logic.
