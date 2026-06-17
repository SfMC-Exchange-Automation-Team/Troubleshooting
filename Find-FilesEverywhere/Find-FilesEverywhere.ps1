# Global function to search for a string pattern across user, sync, and mapped drive locations.
# Author: Cullen Haafke (SfMC)
# First release: 17 June 2026

function global:Find-FileEverywhere {
    <#
    .SYNOPSIS
        Searches for items matching a string pattern across user, sync, and mapped drive locations.

    .DESCRIPTION
        This function enumerates relevant drive roots and recursively searches for items
        whose names match the provided search string. Each root is searched in parallel
        using runspaces for performance. By default, the system drive search is scoped to the
        current user's profile folder. Use -FullCDrive to search the entire system drive.
        Designed for Windows PowerShell 5.1 compatibility.

        Scout fork improvements:
        - Safer path de-duplication with path-boundary checks.
        - Optional -MaxThreads and -Quiet controls.
        - User-visible pauses are preserved, and suppressed by -Quiet.
        - Runspace pool cleanup in a finally block.
        - Access-denied/search errors are counted with ErrorVariable.
        - Content searches stop at the first matching line per file.

    .PARAMETER SearchString
        The string or wildcard pattern to match against file names, for example:
        "report", "*.xlsx", or "*budget*".

    .PARAMETER FullCDrive
        If specified, searches the entire system drive instead of just the current user's profile folder.

    .PARAMETER IncludeContent
        If specified, also searches inside file contents for the SearchString in common text files.

    .PARAMETER MaxDepth
        Optional. Limits recursion depth. Default is unlimited (0).

    .PARAMETER ExcludePaths
        Optional. Array of folder paths, folder names, or partial path strings to skip.

    .PARAMETER MaxThreads
        Optional. Maximum number of parallel runspaces. Defaults to the processor count.

    .PARAMETER Quiet
        Suppresses status messages written to the host. Results are still returned to the pipeline.

    .EXAMPLE
        Find-FileEverywhere -SearchString "*budget*"

    .EXAMPLE
        Find-FileEverywhere -SearchString "*.docx" -FullCDrive -MaxThreads 4

    .EXAMPLE
        Find-FileEverywhere -SearchString "report" -IncludeContent -MaxDepth 5 -ExcludePaths @("node_modules", ".git") -Quiet
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, HelpMessage = "The string or wildcard pattern to search for in file names.")]
        [ValidateNotNullOrEmpty()]
        [string]$SearchString,

        [Parameter(Mandatory = $false, HelpMessage = "Search the entire system drive instead of just the current user profile.")]
        [switch]$FullCDrive,

        [Parameter(Mandatory = $false, HelpMessage = "Also search inside file contents for the string.")]
        [switch]$IncludeContent,

        [Parameter(Mandatory = $false, HelpMessage = "Maximum folder recursion depth. 0 = unlimited.")]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxDepth = 0,

        [Parameter(Mandatory = $false, HelpMessage = "Array of folder names or paths to exclude from the search.")]
        [string[]]$ExcludePaths = @(),

        [Parameter(Mandatory = $false, HelpMessage = "Maximum number of parallel runspaces.")]
        [ValidateRange(1, 64)]
        [int]$MaxThreads = [Environment]::ProcessorCount,

        [Parameter(Mandatory = $false, HelpMessage = "Suppress host status messages.")]
        [switch]$Quiet
    )

    Begin {
        function Normalize-DirectoryPath {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Path
            )

            $fullPath = [System.IO.Path]::GetFullPath($Path)
            $rootPath = [System.IO.Path]::GetPathRoot($fullPath)

            if ($fullPath.Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $rootPath
            }

            return $fullPath.TrimEnd('\')
        }

        function Test-IsPathCovered {
            param(
                [Parameter(Mandatory = $true)]
                [string]$CandidatePath,

                [Parameter(Mandatory = $true)]
                [string]$ExistingRoot
            )

            $candidate = Normalize-DirectoryPath -Path $CandidatePath
            $existing = Normalize-DirectoryPath -Path $ExistingRoot

            if ($candidate.Equals($existing, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }

            $existingPrefix = $existing
            if (-not $existingPrefix.EndsWith('\')) {
                $existingPrefix = "$existingPrefix\"
            }

            return $candidate.StartsWith($existingPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        }

        function Add-SearchRoot {
            param(
                [Parameter(Mandatory = $true)]
                [AllowEmptyCollection()]
                [System.Collections.ArrayList]$Roots,

                [Parameter(Mandatory = $true)]
                [string]$Path,

                [Parameter(Mandatory = $true)]
                [string]$Label
            )

            if (-not (Test-Path -LiteralPath $Path)) {
                Write-Verbose "Search root not found: $Path"
                return
            }

            $normalizedPath = Normalize-DirectoryPath -Path $Path
            $alreadyCovered = $false

            foreach ($root in $Roots) {
                if (Test-IsPathCovered -CandidatePath $normalizedPath -ExistingRoot $root.Path) {
                    $alreadyCovered = $true
                    break
                }
            }

            if ($alreadyCovered) {
                Write-Verbose "Search root is already covered. Skipping: $normalizedPath"
                return
            }

            [void]$Roots.Add(@{
                Path  = $normalizedPath
                Label = $Label
            })
            Write-Verbose "Added search root: [$Label] $normalizedPath"
        }

        function Write-Status {
            param(
                [Parameter(Mandatory = $true)]
                [string]$Message,

                [Parameter(Mandatory = $false)]
                [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray
            )

            if (-not $Quiet) {
                Write-Host $Message -ForegroundColor $ForegroundColor
            }
        }

        function Start-VisibilityPause {
            param(
                [Parameter(Mandatory = $true)]
                [ValidateRange(1, 60)]
                [int]$Seconds
            )

            if (-not $Quiet) {
                Start-Sleep -Seconds $Seconds
            }
        }

        function Format-MatchCount {
            param(
                [Parameter(Mandatory = $true)]
                [ValidateRange(0, [int]::MaxValue)]
                [int]$Count,

                [switch]$IncludeTotal
            )

            $noun = if ($Count -eq 1) { "match" } else { "matches" }
            if ($IncludeTotal) {
                return "$Count total $noun"
            }

            return "$Count $noun"
        }

        Write-Verbose "=========================================="
        Write-Verbose "Find-FileEverywhere - Execution Starting"
        Write-Verbose "=========================================="
        Write-Verbose "Search String    : $SearchString"
        Write-Verbose "Full System Drive: $FullCDrive"
        Write-Verbose "Include Content  : $IncludeContent"
        Write-Verbose "Max Depth        : $(if ($MaxDepth -eq 0) { 'Unlimited' } else { $MaxDepth })"
        Write-Verbose "Max Threads      : $MaxThreads"
        Write-Verbose "Exclude Paths    : $($ExcludePaths -join ', ')"
        Write-Verbose "------------------------------------------"

        if ($SearchString -notmatch '\*|\?') {
            $fileFilter = "*${SearchString}*"
            Write-Verbose "No wildcards detected in SearchString. Auto-wrapping to: $fileFilter"
        }
        else {
            $fileFilter = $SearchString
            Write-Verbose "Wildcards detected. Using SearchString as-is: $fileFilter"
        }

        $searchRoots = [System.Collections.ArrayList]::new()
        $systemDriveRoot = [System.IO.Path]::GetPathRoot($env:SystemDrive)
        if (-not $systemDriveRoot) {
            $systemDriveRoot = [System.IO.Path]::GetPathRoot($env:SystemRoot)
        }

        if ($FullCDrive) {
            Add-SearchRoot -Roots $searchRoots -Path $systemDriveRoot -Label "System Drive (Full)"
        }
        else {
            $userProfile = $env:USERPROFILE
            if ($userProfile -and (Test-Path -LiteralPath $userProfile)) {
                Add-SearchRoot -Roots $searchRoots -Path $userProfile -Label "User Profile"
            }
            else {
                Write-Verbose "User profile path not found. Falling back to full system drive."
                Add-SearchRoot -Roots $searchRoots -Path $systemDriveRoot -Label "System Drive (Fallback)"
            }
        }

        $personalOneDrive = $env:OneDrive
        if ($personalOneDrive -and ($personalOneDrive -ne $env:OneDriveCommercial)) {
            Add-SearchRoot -Roots $searchRoots -Path $personalOneDrive -Label "Personal OneDrive"
        }
        else {
            Write-Verbose "Personal OneDrive path not found, not configured, or same as corporate OneDrive. Skipping."
        }

        $corpOneDrive = $env:OneDriveCommercial
        if ($corpOneDrive) {
            Add-SearchRoot -Roots $searchRoots -Path $corpOneDrive -Label "Corporate OneDrive"
        }
        else {
            Write-Verbose "Corporate OneDrive path not found or not configured. Skipping."
        }

        Write-Verbose "Enumerating additional physical and mapped drives..."
        $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
            $_.Root -and
            -not $_.Root.Equals($systemDriveRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $_.Root)
        }

        foreach ($drive in $drives) {
            Add-SearchRoot -Roots $searchRoots -Path $drive.Root -Label "$($drive.Name): Drive"
        }

        Write-Verbose "------------------------------------------"
        Write-Verbose "Total search roots to scan: $($searchRoots.Count)"
        foreach ($root in $searchRoots) {
            Write-Verbose "  -> [$($root.Label)] $($root.Path)"
        }
        Write-Verbose "------------------------------------------"

        $searchScriptBlock = {
            param(
                [string]$RootPath,
                [string]$RootLabel,
                [string]$FileFilter,
                [string]$RawSearchString,
                [bool]$DoContentSearch,
                [int]$Depth,
                [string[]]$Exclusions
            )

            function Test-ShouldExcludePath {
                param(
                    [Parameter(Mandatory = $true)]
                    [string]$Path,

                    [string[]]$Patterns
                )

                if (-not $Patterns -or $Patterns.Count -eq 0) {
                    return $false
                }

                foreach ($pattern in $Patterns) {
                    if ([string]::IsNullOrWhiteSpace($pattern)) {
                        continue
                    }

                    if ($Path.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        return $true
                    }
                }

                return $false
            }

            function Add-SearchResult {
                param(
                    [Parameter(Mandatory = $true)]
                    [hashtable]$ResultMap,

                    [Parameter(Mandatory = $true)]
                    [System.IO.FileInfo]$File,

                    [Parameter(Mandatory = $true)]
                    [string]$MatchType,

                    [string]$ContentPreview
                )

                if ($ResultMap.ContainsKey($File.FullName)) {
                    if ($ContentPreview) {
                        $ResultMap[$File.FullName].ContentMatch = $ContentPreview
                    }
                    return
                }

                $ResultMap[$File.FullName] = [PSCustomObject]@{
                    MatchType    = $MatchType
                    FileName     = $File.Name
                    FullPath     = $File.FullName
                    SizeKB       = [Math]::Round($File.Length / 1KB, 2)
                    LastModified = $File.LastWriteTime
                    DriveRoot    = $RootLabel
                    ContentMatch = $ContentPreview
                }
            }

            $resultsByPath = @{}
            $errorCount = 0

            $gciParams = @{
                Path          = $RootPath
                Filter        = $FileFilter
                File          = $true
                Recurse       = $true
                ErrorAction   = 'SilentlyContinue'
                ErrorVariable = 'fileNameSearchErrors'
            }

            if ($Depth -gt 0) {
                $gciParams['Depth'] = $Depth
            }

            $files = @(Get-ChildItem @gciParams)
            $errorCount += @($fileNameSearchErrors).Count

            foreach ($file in $files) {
                if (Test-ShouldExcludePath -Path $file.FullName -Patterns $Exclusions) {
                    continue
                }

                Add-SearchResult -ResultMap $resultsByPath -File $file -MatchType "FileName" -ContentPreview $null
            }

            if ($DoContentSearch) {
                $textExtensions = @(
                    '.txt', '.log', '.csv', '.ps1', '.psm1', '.psd1', '.xml',
                    '.json', '.yaml', '.yml', '.md', '.html', '.htm', '.css',
                    '.js', '.ts', '.py', '.cfg', '.ini', '.conf', '.bat', '.cmd'
                )

                $contentGciParams = @{
                    Path          = $RootPath
                    File          = $true
                    Recurse       = $true
                    ErrorAction   = 'SilentlyContinue'
                    ErrorVariable = 'contentSearchErrors'
                }

                if ($Depth -gt 0) {
                    $contentGciParams['Depth'] = $Depth
                }

                $textFiles = @(Get-ChildItem @contentGciParams | Where-Object {
                    $textExtensions -contains $_.Extension.ToLowerInvariant()
                })
                $errorCount += @($contentSearchErrors).Count

                foreach ($textFile in $textFiles) {
                    if (Test-ShouldExcludePath -Path $textFile.FullName -Patterns $Exclusions) {
                        continue
                    }

                    if ($textFile.Length -gt 50MB) {
                        continue
                    }

                    try {
                        $hit = Select-String -LiteralPath $textFile.FullName -Pattern $RawSearchString -SimpleMatch -List -ErrorAction Stop
                        if ($hit) {
                            $preview = $hit.Line
                            if ($preview.Length -gt 200) {
                                $preview = $preview.Substring(0, 200) + "..."
                            }

                            Add-SearchResult -ResultMap $resultsByPath -File $textFile -MatchType "Content" -ContentPreview $preview
                        }
                    }
                    catch [System.Management.Automation.ItemNotFoundException] {
                        $errorCount++
                    }
                    catch [System.UnauthorizedAccessException] {
                        $errorCount++
                    }
                    catch [System.IO.IOException] {
                        $errorCount++
                    }
                }
            }

            return [PSCustomObject]@{
                Results    = @($resultsByPath.Values)
                ErrorCount = $errorCount
            }
        }
    }

    Process {
        if ($searchRoots.Count -eq 0) {
            Write-Warning "No valid search roots were discovered. Nothing to search."
            return
        }

        $poolSize = [Math]::Min($searchRoots.Count, $MaxThreads)
        Write-Verbose "Creating runspace pool with max threads: $poolSize"

        $runspacePool = $null
        $runspaceJobs = [System.Collections.ArrayList]::new()
        $allResults = [System.Collections.ArrayList]::new()
        $totalErrors = 0

        try {
            $runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $poolSize)
            $runspacePool.Open()

            foreach ($root in $searchRoots) {
                Write-Status -Message "  Searching $($root.Label). Please wait..." 
                Write-Verbose "Launching runspace for: $($root.Label) -> $($root.Path)"

                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $runspacePool

                [void]$ps.AddScript($searchScriptBlock.ToString())
                [void]$ps.AddParameter("RootPath", $root.Path)
                [void]$ps.AddParameter("RootLabel", $root.Label)
                [void]$ps.AddParameter("FileFilter", $fileFilter)
                [void]$ps.AddParameter("RawSearchString", $SearchString)
                [void]$ps.AddParameter("DoContentSearch", [bool]$IncludeContent)
                [void]$ps.AddParameter("Depth", $MaxDepth)
                [void]$ps.AddParameter("Exclusions", $ExcludePaths)

                $asyncResult = $ps.BeginInvoke()

                [void]$runspaceJobs.Add(@{
                    PowerShell  = $ps
                    AsyncResult = $asyncResult
                    Label       = $root.Label
                })
            }

            Write-Status -Message "  All search threads launched. Waiting for results..." -ForegroundColor Yellow
            Start-VisibilityPause -Seconds 1
            Write-Verbose "All $($runspaceJobs.Count) runspace jobs submitted. Collecting results..."

            foreach ($job in $runspaceJobs) {
                try {
                    $output = $job.PowerShell.EndInvoke($job.AsyncResult)

                    if ($output) {
                        foreach ($item in $output) {
                            $matchCount = 0

                            if ($item.Results) {
                                $matchCount = @($item.Results).Count
                                foreach ($result in $item.Results) {
                                    [void]$allResults.Add($result)
                                }
                            }

                            $totalErrors += $item.ErrorCount
                            Write-Status -Message "  Completed: $($job.Label) - $(Format-MatchCount -Count $matchCount) found."
                            Write-Verbose "Runspace completed: $($job.Label) - $matchCount results, $($item.ErrorCount) errors."
                        }
                    }
                    else {
                        Write-Status -Message "  Completed: $($job.Label) - $(Format-MatchCount -Count 0) found."
                        Write-Verbose "Runspace completed: $($job.Label) - No output returned."
                    }
                }
                catch {
                    Write-Warning "Error collecting results from $($job.Label): $($_.Exception.Message)"
                    Write-Verbose "Exception on runspace $($job.Label): $($_.Exception.Message)"
                    $totalErrors++
                }
                finally {
                    $job.PowerShell.Dispose()
                }
            }
        }
        finally {
            if ($runspacePool) {
                Write-Verbose "Closing and disposing runspace pool."
                $runspacePool.Close()
                $runspacePool.Dispose()
            }
        }
    }

    End {
        Write-Verbose "=========================================="
        Write-Verbose "Find-FileEverywhere - Execution Complete"
        Write-Verbose "=========================================="
        Write-Verbose "Total results     : $($allResults.Count)"
        Write-Verbose "Total errors      : $totalErrors"
        Write-Verbose "------------------------------------------"

        if ($allResults.Count -eq 0) {
            Write-Status -Message "  No files matched '$SearchString' across any scanned location." -ForegroundColor Red
            return
        }

        Write-Status -Message "  Search complete. $(Format-MatchCount -Count $allResults.Count -IncludeTotal) found." -ForegroundColor Green
        Start-VisibilityPause -Seconds 3
        $allResults | Sort-Object DriveRoot, FileName
    }
}
