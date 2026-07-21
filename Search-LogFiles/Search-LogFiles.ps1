<#
 Author: Cullen Haafke
 Scout fork: Microsoft Scout
 Written: 24 Jan 2024
 Purpose: Search log files in a directory for one or more strings. Defaults to common error strings.

 Version History:
 9 May 2024
 v1.1 - Added $Results variable to store search results for later use.
      - Added ExportCsv switch to export results to a CSV file on the desktop.

 10 May 2024
 v1.2 - Added AllFileTypes switch to search all file types in the directory.
      - Added warning if no log files are found in the directory.
      - Added Recurse switch to search all subdirectories.
      - Added logic to differentiate between files and directories.

 11 Nov 2024
 v1.2.1 - Added OutputXml switch to export results to an XML file on the desktop.

 02 Feb 2026
 v1.3 - Added FileName parameter to target a single file instead of searching the entire directory.

 17 Jun 2026
 v1.4-Scout - Streamed file searching with Select-String instead of loading entire files into memory.
            - Added typed parameters, literal search matching by default, output path control, and pipeline output.
            - Fixed output messages so CSV/XML "no results" messages only appear when requested.

 18 Jun 2026
 v1.5-Scout - Added parallel file searching with a configurable ThrottleLimit.
 v1.5.1-Scout - Changed parallel search to a bounded queue so large file sets do not appear stuck while all jobs are queued.
 v1.5.2-Scout - Added NoParallel and ShowTiming switches for comparing serial vs parallel performance.
 v1.5.3-Scout - Made switches name-only and collect extra bare arguments as additional search strings.
 v1.5.4-Scout - Restored original per-file terminal display while keeping Match/Text in stored results.
#>

function global:Search-LogFiles {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false, HelpMessage = "String or strings to search for")]
        [Alias("Pattern")]
        [string[]]$SearchString,

        [Parameter(Position = 1, Mandatory = $false, HelpMessage = "Directory path to search in")]
        [ValidateNotNullOrEmpty()]
        [string]$Path = $pwd.Path,

        [Parameter(Mandatory = $false, HelpMessage = "Export results to CSV")]
        [switch]$OutputCsv,

        [Parameter(Mandatory = $false, HelpMessage = "Export results to XML")]
        [switch]$OutputXml,

        [Parameter(Mandatory = $false, HelpMessage = "Search all file types")]
        [switch]$AllFileTypes,

        [Parameter(Mandatory = $false, HelpMessage = "Search all subdirectories")]
        [switch]$Recurse,

        [Parameter(Mandatory = $false, HelpMessage = "Single file to search (full path, or file name relative to -Path)")]
        [string]$FileName,

        [Parameter(Mandatory = $false, HelpMessage = "Directory where CSV/XML output files are written")]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath = [System.Environment]::GetFolderPath("Desktop"),

        [Parameter(Mandatory = $false, HelpMessage = "Treat -SearchString values as regular expressions instead of literal text")]
        [switch]$Regex,

        [Parameter(Mandatory = $false, HelpMessage = "Maximum number of files to search at the same time")]
        [ValidateRange(1, 256)]
        [int]$ThrottleLimit = [Math]::Max(1, [Environment]::ProcessorCount),

        [Parameter(Mandatory = $false, HelpMessage = "Search files serially using a single Select-String call")]
        [switch]$NoParallel,

        [Parameter(Mandatory = $false, HelpMessage = "Show elapsed time and throughput details")]
        [switch]$ShowTiming,

        [Parameter(ValueFromRemainingArguments = $true, Mandatory = $false, DontShow = $true)]
        [string[]]$AdditionalSearchString
    )

    $specifiedSearchString = @()
    if ($SearchString) {
        $specifiedSearchString += $SearchString
    }
    if ($AdditionalSearchString) {
        $specifiedSearchString += $AdditionalSearchString
    }
    $SearchString = @($specifiedSearchString | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if (-not $SearchString -or $SearchString.Count -eq 0) {
        Write-Host "No search specified. Using common error strings. To specify one, use the -SearchString parameter." -ForegroundColor Yellow
        $SearchString = @("Exception", "Error", "Fail", "Warn", "Invalid", "Cannot", "Unable", "Timeout")
    }

    if ($PSBoundParameters.ContainsKey("Path") -eq $false) {
        Write-Warning "Defaulting to the current working directory - $($pwd.Path). Specify a path if needed."
    }

    $files = @()

    if (-not [string]::IsNullOrWhiteSpace($FileName)) {
        if (Test-Path -LiteralPath $FileName -PathType Leaf) {
            $files = @(Get-Item -LiteralPath $FileName -ErrorAction Stop)
        }
        else {
            if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
                Write-Error "Invalid path: $Path (when using -FileName, -Path must be a directory unless -FileName is a full file path)."
                return
            }

            $candidate = Join-Path -Path $Path -ChildPath $FileName
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Write-Error "Invalid file: $candidate"
                return
            }

            $files = @(Get-Item -LiteralPath $candidate -ErrorAction Stop)
        }

        if ($Recurse) {
            Write-Warning "-Recurse was specified but -FileName targets a single file. -Recurse will be ignored."
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Error "Invalid path: $Path"
            return
        }

        $fileSearchOptions = @{
            LiteralPath = $Path
            File        = $true
            ErrorAction = "Stop"
        }

        if ($Recurse) {
            $fileSearchOptions.Recurse = $true
        }

        if (-not $AllFileTypes) {
            $fileSearchOptions.Filter = "*.log"
        }

        try {
            $files = @(Get-ChildItem @fileSearchOptions)
        }
        catch {
            Write-Error "Unable to enumerate files in '$Path': $_"
            return
        }
    }

    if ($files.Count -eq 0) {
        $targetDescription = if ($AllFileTypes) { "files" } else { "log files" }
        Write-Host "No $targetDescription found in $Path" -ForegroundColor Yellow
        return
    }

    $effectiveThrottleLimit = [Math]::Min($ThrottleLimit, $files.Count)
    $searchMode = if ($NoParallel -or $effectiveThrottleLimit -eq 1) { "serial" } else { "parallel" }
    $modeDescription = if ($searchMode -eq "parallel") { "parallel throttle limit $effectiveThrottleLimit" } else { "serial Select-String" }
    Write-Verbose "Found $($files.Count) file(s). Searching for: $($SearchString -join ', ') using $modeDescription"

    $searchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($searchMode -eq "serial") {
        $searchErrors = @()
        $selectStringOptions = @{
            LiteralPath   = [string[]]($files | ForEach-Object { $_.FullName })
            Pattern       = $SearchString
            AllMatches    = $true
            ErrorAction   = "SilentlyContinue"
            ErrorVariable = "searchErrors"
        }

        if (-not $Regex) {
            $selectStringOptions.SimpleMatch = $true
        }

        $global:Results = Select-String @selectStringOptions |
            ForEach-Object {
                [pscustomobject]@{
                    FileName = $_.Path
                    Line     = $_.LineNumber
                    Match    = $_.Pattern
                    Text     = $_.Line.Trim()
                }
            }

        foreach ($searchError in $searchErrors) {
            Write-Warning $searchError.ToString()
        }
    }
    else {
        $searchScript = {
            param(
                [string]$FilePath,
                [string[]]$Patterns,
                [bool]$UseRegex
            )

            $selectStringOptions = @{
                LiteralPath = $FilePath
                Pattern     = $Patterns
                AllMatches  = $true
                ErrorAction = "Stop"
            }

            if (-not $UseRegex) {
                $selectStringOptions.SimpleMatch = $true
            }

            try {
                Select-String @selectStringOptions |
                    ForEach-Object {
                        [pscustomobject]@{
                            RecordType = "Result"
                            FileName   = $_.Path
                            Line       = $_.LineNumber
                            Match      = $_.Pattern
                            Text       = $_.Line.Trim()
                        }
                    }
            }
            catch {
                [pscustomobject]@{
                    RecordType = "Warning"
                    FileName   = $FilePath
                    Message    = "Error accessing file ${FilePath}: $_"
                }
            }
        }

        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $effectiveThrottleLimit)
        $runspacePool.Open()
        $jobs = New-Object System.Collections.ArrayList
        $records = New-Object System.Collections.ArrayList
        $fileQueue = New-Object System.Collections.Queue

        foreach ($file in $files) {
            $fileQueue.Enqueue($file)
        }

        try {
            while ($fileQueue.Count -gt 0 -or $jobs.Count -gt 0) {
                while ($fileQueue.Count -gt 0 -and $jobs.Count -lt $effectiveThrottleLimit) {
                    $file = $fileQueue.Dequeue()
                    Write-Verbose "Starting $($file.FullName)"
                    $powerShell = [powershell]::Create()
                    $powerShell.RunspacePool = $runspacePool
                    [void]$powerShell.AddScript($searchScript).AddArgument($file.FullName).AddArgument($SearchString).AddArgument([bool]$Regex)

                    [void]$jobs.Add([pscustomobject]@{
                        PowerShell = $powerShell
                        Handle     = $powerShell.BeginInvoke()
                        FileName   = $file.FullName
                    })
                }

                $completedJobs = @($jobs | Where-Object { $_.Handle.IsCompleted })

                if ($completedJobs.Count -eq 0) {
                    Start-Sleep -Milliseconds 100
                    continue
                }

                foreach ($job in $completedJobs) {
                    try {
                        foreach ($record in $job.PowerShell.EndInvoke($job.Handle)) {
                            [void]$records.Add($record)
                        }
                        Write-Verbose "Completed $($job.FileName)"
                    }
                    catch {
                        [void]$records.Add([pscustomobject]@{
                            RecordType = "Warning"
                            FileName   = $job.FileName
                            Message    = "Error searching file $($job.FileName): $_"
                        })
                    }
                    finally {
                        $job.PowerShell.Dispose()
                        [void]$jobs.Remove($job)
                    }
                }
            }
        }
        finally {
            foreach ($job in $jobs) {
                if ($job.PowerShell) {
                    $job.PowerShell.Dispose()
                }
            }

            $runspacePool.Close()
            $runspacePool.Dispose()
        }

        $global:Results = foreach ($record in $records) {
            if ($record.RecordType -eq "Warning") {
                Write-Warning $record.Message
            }
            else {
                [pscustomobject]@{
                    FileName = $record.FileName
                    Line     = $record.Line
                    Match    = $record.Match
                    Text     = $record.Text
                }
            }
        }
    }

    $global:Results = @($global:Results)
    $searchStopwatch.Stop()

    Write-Host " "
    Write-Host "Found the following files. Searching for '$($SearchString -join ', ')':" -ForegroundColor Cyan

    foreach ($file in $files) {
        Write-Host " "
        Write-Host $file.FullName

        $fileMatches = @($global:Results | Where-Object { $_.FileName -eq $file.FullName })
        if ($fileMatches.Count -eq 0) {
            Write-Host "No matches found in " -NoNewline
            Write-Host $file.FullName -ForegroundColor Green
            continue
        }

        foreach ($match in $fileMatches) {
            Write-Host "Found '$($match.Match)' in " -NoNewline
            Write-Host $match.FileName -ForegroundColor Red -NoNewline
            Write-Host " at line $($match.Line)"
        }
    }

    if ($ShowTiming) {
        $filesPerSecond = if ($searchStopwatch.Elapsed.TotalSeconds -gt 0) { $files.Count / $searchStopwatch.Elapsed.TotalSeconds } else { 0 }
        Write-Host ("Search completed in {0:n2} seconds ({1:n1} files/sec)" -f $searchStopwatch.Elapsed.TotalSeconds, $filesPerSecond) -ForegroundColor Cyan
    }

    if ($global:Results.Count -gt 0) {
        Write-Host " "
        Write-Host "Results found: $($global:Results.Count)" -ForegroundColor Cyan
        Write-Host "Results can also be found in the variable " -NoNewline
        Write-Host '$Results' -ForegroundColor Cyan
    }

    if (-not $OutputCsv -and -not $OutputXml) {
        return
    }

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        Write-Error "Invalid output path: $OutputPath"
        return
    }

    $timestamp = Get-Date -Format "dd-MMM-yyyy_HHmm"

    if ($OutputCsv) {
        if ($global:Results.Count -gt 0) {
            $csvPath = Join-Path -Path $OutputPath -ChildPath "LogSearchResults - $timestamp.csv"
            $global:Results | Export-Csv -LiteralPath $csvPath -NoTypeInformation
            Write-Host "Results have been exported to " -NoNewline
            Write-Host $csvPath -ForegroundColor Cyan
        }
        else {
            Write-Host "No results to export to CSV" -ForegroundColor Yellow
        }
    }

    if ($OutputXml) {
        if ($global:Results.Count -gt 0) {
            $xmlPath = Join-Path -Path $OutputPath -ChildPath "LogSearchResults - $timestamp.xml"
            $global:Results | Export-Clixml -LiteralPath $xmlPath
            Write-Host "Results have been exported to " -NoNewline
            Write-Host $xmlPath -ForegroundColor Cyan
        }
        else {
            Write-Host "No results to export to XML" -ForegroundColor Yellow
        }
    }

    return
}
