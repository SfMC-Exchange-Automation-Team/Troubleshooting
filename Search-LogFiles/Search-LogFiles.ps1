<# Author: Cullen Haafke
 Written: 24 Jan 2024
 Purpose: Search all log files in a directory for a given string. Defaults to common error strings.
 
 Version History:
 9 May 2024  |  v1.1   - Added $Results variable to store search results for later use.
             |         - Added ExportCsv switch to export results to a CSV file on the desktop.
 10 May 2024 |  v1.2   - Added AllFileTypes switch to search all file types in the directory.
                       - Added warning if no log files are found in the directory.
                       - Added Recurse switch to search all subdirectories.
                       - Added logic to differentiate between files and directories.
11 Nov 2024  |  v1.2.1 - Added OutputXml switch to export results to an XML file on the desktop.
 
#>
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

    if($SearchString -like $null) {
        Write " "
        Write-Host "No search specified. Using common error strings. To specify one, use the -SearchString parameter." -ForegroundColor Yellow
        $SearchString = @("Exception", "Error", "Fail", "Warn", "Invalid", "Cannot", "Unable", "Timeout")
    }

    if ($Path -eq $pwd.Path) {
        Write-Warning "Defaulting to the current working directory - $($pwd.path). Specify a path if needed."
    }

    if (-not (Test-Path $Path -PathType Container)) {
        Write-Error "Invalid path: $Path"
        return
    }

    $fileSearchOptions = @{
        Path = $Path
        Filter = if ($AllFileTypes) { "*.*" } else { "*.log" }
        Recurse = $Recurse
    }

    $files = Get-ChildItem @fileSearchOptions | Where-Object { -not $_.PSIsContainer }
    Write " "

    if ($files.Count -eq 0) {
        Write-Host "No log files found in $Path" -ForegroundColor Yellow
        return
    }

    Write-Host "Found the following files. Searching for '$SearchString':" -ForegroundColor Cyan
    $global:Results = @()

    foreach ($file in $files) {
        Write-Host " "  # Empty line for visual spacing.
        Write-Host "$($file.FullName)" 

        $found = $false
        try {
            $log = Get-Content $file.FullName
            $lineNumber = 0
            foreach ($chunk in $log) {
                $lineNumber++
                foreach ($searchTerm in $SearchString) {
                    if ($chunk -like "*$searchTerm*") {
                        Write-Host "Found '$searchTerm' in " -NoNewline
                        Write-Host "$($file.FullName)" -ForegroundColor Red -NoNewline
                        Write-Host " at line $lineNumber"

                        # Create a custom object and add it to the results array
                        $obj = New-Object -TypeName PSObject -Property @{
                            FileName = $file.FullName
                            Line = $lineNumber
                            Error = $chunk
                        }
                        $global:Results += $obj
                        $found = $true
                    }
                }
            }
            if($found -eq $false) {
                Write-Host "No matches found in " -NoNewline
                Write-Host "$($file.FullName)" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Error accessing file $($file.FullName): $_"
        }
    }
    if($global:Results.Count -gt 0) {
        Write " "
        Write-Host "Results found: $($global:Results.Count)"
        Write-Host "Results can also be found in the variable " -NoNewline
        Write-host '$Results' -ForegroundColor Cyan
    }

    ######################
    ### Output section ###
    ######################

    # stop script if output switches are not used
    if (-not $OutputCsv -and -not $OutputXml) {
        return
    }

    # define $desktopPath for use in both CSV and XML output
    $desktopPath = [System.Environment]::GetFolderPath("Desktop")

    if ($OutputCsv -and $global:Results.Count -gt 0) {
        $csvPath = Join-Path $desktopPath "LogSearchResults - $(Get-date -Format dd-MMM-yyyy_HHmm).csv"
        $global:Results | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "Results have been exported to " -NoNewline
        Write-Host "$csvPath" -ForegroundColor Cyan
    }
    else{
        Write-Host "No results to export to CSV" -ForegroundColor Yellow
    }
    if ($OutputXml -and $global:Results.Count -gt 0) {
        $xmlPath = Join-Path $desktopPath "LogSearchResults - $(Get-date -Format dd-MMM-yyyy_HHmm).xml"
        $global:Results | Export-Clixml -Path $xmlPath
        Write-Host "Results have been exported to " -NoNewline
        Write-Host "$xmlPath" -ForegroundColor Cyan
    }
    else{
        Write-Host "No results to export to XML" -ForegroundColor Yellow
    }
 }

 
