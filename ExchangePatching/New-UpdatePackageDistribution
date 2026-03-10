function New-UpdatePackageDistribution {
    <#
    .SYNOPSIS
        Distributes Exchange SU/CU packages (file or folder) to every Exchange server in the organization using RoboCopy.

    .DESCRIPTION
        - Enumerates Exchange servers via Get-ExchangeServer (must be run in Exchange Management Shell).
        - Groups servers by AD site and optionally performs a two-hop distribution:
            1) Copy from the runner to one "seed" server per site.
            2) From the seed server, copy to other servers in the same site.
        - Uses RoboCopy with logging and interprets exit codes (>= 8 indicates failure).
        - Provides a visible timer while each RoboCopy run is in progress.
        - Outputs a detailed object report and can optionally export CSV/JSON.
        - Includes an email notification payload placeholder (not sent).

    .PARAMETER PackagePath
        Path to the update package content. Can be a folder (recommended) or a file (ISO/EXE/MSP).

    .PARAMETER DestinationSubPath
        Destination subfolder under the remote system drive (default: ProgramData\ExchangeUpdateStaging\<PackageName>).

    .PARAMETER PackageName
        Optional override for the package folder name used at destination.

    .PARAMETER DistributionMode
        TwoHop (default) or Direct.
        - TwoHop: Seed per AD site then copy within site from seed.
        - Direct: Copy from runner to every server.

    .PARAMETER SiteSeedMap
        Optional hashtable mapping Site -> SeedServerName.
        Example: @{ "CN=Default-First-Site-Name" = "EXCH01" }
        If not provided, the first server (alphabetical) in each site is used.

    .PARAMETER ThrottleLimit
        Max concurrent fan-out copy jobs per site (TwoHop) or per site loop pacing (Direct still runs serially here).

    .PARAMETER RobocopyRetries
        RoboCopy /R value.

    .PARAMETER RobocopyWaitSeconds
        RoboCopy /W value.

    .PARAMETER RobocopyMT
        RoboCopy /MT value (multi-threading).

    .PARAMETER UseRestartableMode
        Uses RoboCopy /Z (restartable mode).

    .PARAMETER LogRoot
        Root folder for logs (default: %TEMP%\New-UpdatePackageDistribution\<PackageName>_<timestamp>).

    .PARAMETER ExportCsvPath
        Optional CSV export path.

    .PARAMETER ExportJsonPath
        Optional JSON export path.

    .PARAMETER EnableEmailNotification
        Builds an email payload object for future integration (does not send).

    .EXAMPLE
        New-UpdatePackageDistribution -PackagePath "\\dfs\software\Exchange\CU15" -Verbose

    .EXAMPLE
        New-UpdatePackageDistribution -PackagePath "D:\Software\Exchange2019CU15.iso" -DistributionMode Direct -Verbose
    #>

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationSubPath = "ProgramData\ExchangeUpdateStaging",

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$PackageName,

        [Parameter(Mandatory = $false)]
        [ValidateSet("TwoHop", "Direct")]
        [string]$DistributionMode = "TwoHop",

        [Parameter(Mandatory = $false)]
        [hashtable]$SiteSeedMap,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 64)]
        [int]$ThrottleLimit = 4,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]$RobocopyRetries = 2,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 600)]
        [int]$RobocopyWaitSeconds = 5,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 128)]
        [int]$RobocopyMT = 16,

        [Parameter(Mandatory = $false)]
        [bool]$UseRestartableMode = $true,

        [Parameter(Mandatory = $false)]
        [string]$LogRoot,

        [Parameter(Mandatory = $false)]
        [string]$ExportCsvPath,

        [Parameter(Mandatory = $false)]
        [string]$ExportJsonPath,

        [Parameter(Mandatory = $false)]
        [switch]$EnableEmailNotification
    )

    begin {
        # Region: Helper Functions

        function Test-IsAdmin {
            [CmdletBinding()]
            param()
            try {
                $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
                return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            } catch {
                return $false
            }
        }

        function Start-SelfElevateIfNeeded {
            [CmdletBinding()]
            param()

            if (Test-IsAdmin) {
                Write-Verbose "Process is elevated."
                return $true
            }

            Write-Verbose "Process is not elevated. Attempting self-elevation..."

            try {
                # Re-run the exact command line if available
                $line = $MyInvocation.Line
                if (:IsNullOrWhiteSpace($line)) {
                    throw "Unable to determine the invoking command line."
                }

                $args = @(
                    "-NoProfile"
                    "-ExecutionPolicy", "Bypass"
                    "-Command", $line
                )

                Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args | Out-Null
                Write-Warning "Relaunched in an elevated PowerShell session. Re-run will continue in the elevated window."
                return $false
            } catch {
                throw "This function must be run from an elevated (Run as Administrator) Exchange Management Shell. Elevation attempt failed: $($_.Exception.Message)"
            }
        }

        function Test-IsExchangeManagementShell {
            [CmdletBinding()]
            param()
            return (Get-Command -Name Get-ExchangeServer -ErrorAction SilentlyContinue) -ne $null
        }

        function Get-RemoteSystemDrive {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$ComputerName
            )

            Write-Verbose ("[{0}] Determining remote system drive..." -f $ComputerName)

            try {
                if (Test-WSMan -ComputerName $ComputerName -ErrorAction Stop) {
                    $drive = Invoke-Command -ComputerName $ComputerName -ScriptBlock { $env:SystemDrive } -ErrorAction Stop
                    if ($drive -and ($drive -is [string])) {
                        Write-Verbose ("[{0}] Remote system drive: {1}" -f $ComputerName, $drive)
                        return $drive
                    }
                }
            } catch {
                Write-Verbose ("[{0}] WinRM system drive query failed: {1}" -f $ComputerName, $_.Exception.Message)
            }

            # Fallback assumption
            Write-Verbose ("[{0}] Falling back to 'C:' for system drive (assumption due to remoting limits)." -f $ComputerName)
            return "C:"
        }

        function Convert-RobocopyExitCode {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [int]$ExitCode
            )

            # RoboCopy return codes are bitmapped.
            # Any value >= 8 indicates at least one failure.
            if ($ExitCode -ge 8) { return "Failure" }
            return "Success"
        }

        function Invoke-RobocopyWithTimer {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Source,

                [Parameter(Mandatory = $true)]
                [string]$Destination,

                [Parameter(Mandatory = $true)]
                [string]$LogFilePath,

                [Parameter(Mandatory = $true)]
                [int]$Retries,

                [Parameter(Mandatory = $true)]
                [int]$WaitSeconds,

                [Parameter(Mandatory = $true)]
                [int]$MT,

                [Parameter(Mandatory = $true)]
                [bool]$UseZ,

                [Parameter(Mandatory = $true)]
                [string]$Activity
            )

            Write-Verbose ("Invoke-RobocopyWithTimer: Source='{0}' Destination='{1}'" -f $Source, $Destination)

            # Ensure log directory exists
            $logDir = Split-Path -Path $LogFilePath -Parent
            if (-not (Test-Path -Path $logDir)) {
                Write-Verbose ("Creating log directory: {0}" -f $logDir)
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }

            # Build RoboCopy arguments
            $args = New-Object System.Collections.Generic.List[string]

            $sourceItem = Get-Item -LiteralPath $Source -ErrorAction Stop
            if ($sourceItem.PSIsContainer) {
                # Source is folder
                $args.Add(("`"{0}`"" -f $sourceItem.FullName))
                $args.Add(("`"{0}`"" -f $Destination))
                $args.Add("*.*")
                $args.Add("/E")
            } else {
                # Source is file
                $args.Add(("`"{0}`"" -f $sourceItem.Directory.FullName))
                $args.Add(("`"{0}`"" -f $Destination))
                $args.Add(("`"{0}`"" -f $sourceItem.Name))
                $args.Add("/E")
            }

            # Retry behavior
            $args.Add(("/R:{0}" -f $Retries))
            $args.Add(("/W:{0}" -f $WaitSeconds))

            # Performance and resiliency
            if ($MT -gt 0) { $args.Add(("/MT:{0}" -f $MT)) }
            if ($UseZ) { $args.Add("/Z") }

            # Logging
            $args.Add("/TEE")
            $args.Add(("/LOG+:`"{0}`"" -f $LogFilePath))

            # Reduce log noise while still being useful
            $args.Add("/NP")   # No progress
            $args.Add("/NFL")  # No file list
            $args.Add("/NDL")  # No directory list

            $cmdLine = "robocopy.exe {0}" -f ($args -join " ")
            Write-Verbose ("RoboCopy command: {0}" -f $cmdLine)

            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            # Start RoboCopy
            $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList ($args -join " ") -PassThru -NoNewWindow

            # Visible timer loop
            while (-not $proc.HasExited) {
                $elapsed = $sw.Elapsed
                $status = ("Elapsed: {0:hh\:mm\:ss}" -f $elapsed)
                Write-Progress -Activity $Activity -Status $status -PercentComplete 0
                Start-Sleep -Seconds 1
            }

            $sw.Stop()
            Write-Progress -Activity $Activity -Completed

            $exitCode = $proc.ExitCode
            $resultText = Convert-RobocopyExitCode -ExitCode $exitCode

            Write-Verbose ("RoboCopy completed. ExitCode={0} Result={1} Duration={2:hh\:mm\:ss}" -f $exitCode, $resultText, $sw.Elapsed)

            [pscustomobject]@{
                Source      = $Source
                Destination = $Destination
                LogFile     = $LogFilePath
                ExitCode    = $exitCode
                Result      = $resultText
                Duration    = $sw.Elapsed
            }
        }

        function New-SafeName {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Value
            )
            return ($Value -replace '[\\\/:\*\?"<>\|]', '_')
        }

        # EndRegion: Helper Functions

        # Region: Validation and Setup

        if (-not (Start-SelfElevateIfNeeded)) {
            # We launched an elevated session, stop execution in the current (non-elevated) one.
            return
        }

        if (-not (Test-IsExchangeManagementShell)) {
            throw "Get-ExchangeServer was not found. Run this from Exchange Management Shell on an Exchange management host."
        }

        if (-not (Test-Path -LiteralPath $PackagePath)) {
            throw ("PackagePath not found: {0}" -f $PackagePath)
        }

        # Resolve package name if not provided
        if (-not $PackageName) {
            $item = Get-Item -LiteralPath $PackagePath -ErrorAction Stop
            if ($item.PSIsContainer) {
                $PackageName = Split-Path -Path $item.FullName -Leaf
            } else {
                $PackageName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
            }
        }

        # Log root default
        if (-not $LogRoot) {
            $ts = (Get-Date).ToString("yyyyMMdd_HHmmss")
            $LogRoot = Join-Path -Path $env:TEMP -ChildPath ("New-UpdatePackageDistribution\{0}_{1}" -f $PackageName, $ts)
        }

        if (-not (Test-Path -Path $LogRoot)) {
            Write-Verbose ("Creating log root: {0}" -f $LogRoot)
            New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
        }

        Write-Verbose ("LogRoot: {0}" -f $LogRoot)
        Write-Verbose ("PackageName: {0}" -f $PackageName)
        Write-Verbose ("DistributionMode: {0}" -f $DistributionMode)
        Write-Verbose ("DestinationSubPath: {0}" -f $DestinationSubPath)

        $overallSw = [System.Diagnostics.Stopwatch]::StartNew()

        # Results list
        $results = New-Object System.Collections.Generic.List[object]

        # EndRegion: Validation and Setup
    }

    process {
        # Region: Discover Exchange servers

        Write-Verbose "Enumerating Exchange servers with Get-ExchangeServer..."
        $servers = Get-ExchangeServer -Status -ErrorAction Stop

        if (-not $servers) {
            throw "No Exchange servers returned by Get-ExchangeServer."
        }

        # Build a normalized inventory
        $inventory = foreach ($s in $servers) {
            [pscustomobject]@{
                Name = [string]$s.Name
                Site = [string]$s.Site
                Fqdn = [string]$s.Fqdn
            }
        }

        $siteGroups = $inventory | Group-Object -Property Site
        Write-Verbose ("Found {0} AD site group(s) containing Exchange servers." -f $siteGroups.Count)

        # EndRegion: Discover Exchange servers

        # Region: Distribution

        foreach ($siteGroup in $siteGroups) {
            $siteName = $siteGroup.Name
            $siteSafe = New-SafeName -Value $siteName

            $siteServers = @($siteGroup.Group | Sort-Object -Property Name)
            Write-Verbose ("Processing site '{0}' with {1} server(s)." -f $siteName, $siteServers.Count)

            # Determine seed server
            $seedServer = $null
            if ($SiteSeedMap -and $SiteSeedMap.ContainsKey($siteName)) {
                $seedServer = [string]$SiteSeedMap[$siteName]
                Write-Verbose ("Seed override used for site '{0}': {1}" -f $siteName, $seedServer)
            } else {
                $seedServer = @($siteServers)[0].Name
                Write-Verbose ("No seed override for site '{0}'. Using seed: {1}" -f $siteName, $seedServer)
            }

            if ($DistributionMode -eq "TwoHop") {
                # Check WinRM to seed server
                $canRemoting = $false
                try {
                    if (Test-WSMan -ComputerName $seedServer -ErrorAction Stop) {
                        $canRemoting = $true
                    }
                } catch {
                    $canRemoting = $false
                }

                if ($canRemoting) {
                    Write-Verbose ("TwoHop mode enabled. WinRM available to seed server: {0}" -f $seedServer)

                    # Determine seed destination
                    $seedSystemDrive = Get-RemoteSystemDrive -ComputerName $seedServer
                    $seedDriveLetter = $seedSystemDrive.TrimEnd(":")
                    $seedDestLocal = Join-Path -Path ($seedSystemDrive + "\") -ChildPath (Join-Path -Path $DestinationSubPath -ChildPath $PackageName)
                    $seedDestUNC = "\\{0}\{1}$\{2}\{3}" -f $seedServer, $seedDriveLetter, $DestinationSubPath, $PackageName

                    # Ensure destination exists on seed server
                    if ($PSCmdlet.ShouldProcess($seedServer, ("Create destination folder {0}" -f $seedDestLocal))) {
                        Write-Verbose ("Creating seed destination directory: {0} on {1}" -f $seedDestLocal, $seedServer)
                        Invoke-Command -ComputerName $seedServer -ScriptBlock {
                            param($Path)
                            if (-not (Test-Path -LiteralPath $Path)) {
                                New-Item -Path $Path -ItemType Directory -Force | Out-Null
                            }
                        } -ArgumentList $seedDestLocal -ErrorAction Stop
                    }

                    # Step 1: Copy to seed
                    $seedLog = Join-Path -Path $LogRoot -ChildPath ("{0}\SeedCopy_{1}.log" -f $siteSafe, $seedServer)

                    if ($PSCmdlet.ShouldProcess($seedServer, ("Seed copy package to {0}" -f $seedDestUNC))) {
                        $seedCopyResult = Invoke-RobocopyWithTimer -Source $PackagePath -Destination $seedDestUNC -LogFilePath $seedLog `
                            -Retries $RobocopyRetries -WaitSeconds $RobocopyWaitSeconds -MT $RobocopyMT -UseZ $UseRestartableMode `
                            -Activity ("Seed copy to {0} ({1})" -f $seedServer, $siteName)

                        $results.Add([pscustomobject]@{
                            Site        = $siteName
                            Phase       = "Seed"
                            From        = "Runner"
                            To          = $seedServer
                            Destination = $seedDestUNC
                            ExitCode    = $seedCopyResult.ExitCode
                            Result      = $seedCopyResult.Result
                            Duration    = $seedCopyResult.Duration
                            LogFile     = $seedCopyResult.LogFile
                        }) | Out-Null

                        if ($seedCopyResult.Result -ne "Success") {
                            Write-Verbose ("Seed copy failed for site '{0}'. Skipping fan-out for this site." -f $siteName)
                            continue
                        }
                    }

                    # Step 2: Fan-out to other servers in same site
                    $targets = @($siteServers | Where-Object { $_.Name -ne $seedServer })

                    if ($targets.Count -eq 0) {
                        Write-Verbose ("No fan-out targets in site '{0}' beyond seed '{1}'." -f $siteName, $seedServer)
                        continue
                    }

                    Write-Verbose ("Fan-out from seed '{0}' to {1} server(s). ThrottleLimit={2}" -f $seedServer, $targets.Count, $ThrottleLimit)

                    $jobList = New-Object System.Collections.Generic.List[object]

                    foreach ($t in $targets) {
                        # Throttle running jobs
                        while (@($jobList | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
                            Start-Sleep -Seconds 1
                        }

                        $targetServer = $t.Name

                        $job = Start-Job -ScriptBlock {
                            param(
                                $SeedServer,
                                $TargetServer,
                                $DestinationSubPath,
                                $PackageName,
                                $SeedLocalPath,
                                $Retries,
                                $WaitSeconds,
                                $MT,
                                $UseZ,
                                $LogRootSafe,
                                $SiteName
                            )

                            function Convert-RobocopyExitCode {
                                param([int]$ExitCode)
                                if ($ExitCode -ge 8) { return "Failure" }
                                return "Success"
                            }

                            function New-SafeName {
                                param([string]$Value)
                                return ($Value -replace '[\\\/:\*\?"<>\|]', '_')
                            }

                            function Invoke-RobocopyNoProgress {
                                param(
                                    [string]$Source,
                                    [string]$Destination,
                                    [string]$LogFilePath,
                                    [int]$Retries,
                                    [int]$WaitSeconds,
                                    [int]$MT,
                                    [bool]$UseZ
                                )

                                $logDir = Split-Path -Path $LogFilePath -Parent
                                if (-not (Test-Path -Path $logDir)) {
                                    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
                                }

                                $args = New-Object System.Collections.Generic.List[string]

                                $sourceItem = Get-Item -LiteralPath $Source -ErrorAction Stop
                                if ($sourceItem.PSIsContainer) {
                                    $args.Add(("`"{0}`"" -f $sourceItem.FullName))
                                    $args.Add(("`"{0}`"" -f $Destination))
                                    $args.Add("*.*")
                                    $args.Add("/E")
                                } else {
                                    $args.Add(("`"{0}`"" -f $sourceItem.Directory.FullName))
                                    $args.Add(("`"{0}`"" -f $Destination))
                                    $args.Add(("`"{0}`"" -f $sourceItem.Name))
                                    $args.Add("/E")
                                }

                                $args.Add(("/R:{0}" -f $Retries))
                                $args.Add(("/W:{0}" -f $WaitSeconds))
                                if ($MT -gt 0) { $args.Add(("/MT:{0}" -f $MT)) }
                                if ($UseZ) { $args.Add("/Z") }

                                $args.Add(("/LOG+:`"{0}`"" -f $LogFilePath))
                                $args.Add("/NP")
                                $args.Add("/NFL")
                                $args.Add("/NDL")

                                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                                $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList ($args -join " ") -PassThru -NoNewWindow -Wait
                                $sw.Stop()

                                [pscustomobject]@{
                                    ExitCode = $proc.ExitCode
                                    Result   = Convert-RobocopyExitCode -ExitCode $proc.ExitCode
                                    Duration = $sw.Elapsed
                                    LogFile  = $LogFilePath
                                }
                            }

                            # Determine target system drive via WinRM
                            $targetSystemDrive = "C:"
                            try {
                                if (Test-WSMan -ComputerName $TargetServer -ErrorAction Stop) {
                                    $targetSystemDrive = Invoke-Command -ComputerName $TargetServer -ScriptBlock { $env:SystemDrive } -ErrorAction Stop
                                }
                            } catch {
                                $targetSystemDrive = "C:"
                            }

                            $driveLetter = $targetSystemDrive.TrimEnd(":")
                            $destUNC = "\\{0}\{1}$\{2}\{3}" -f $TargetServer, $driveLetter, $DestinationSubPath, $PackageName

                            # Attempt to create destination folder on target
                            try {
                                $destLocal = Join-Path -Path ($targetSystemDrive + "\") -ChildPath (Join-Path -Path $DestinationSubPath -ChildPath $PackageName)
                                Invoke-Command -ComputerName $TargetServer -ScriptBlock {
                                    param($Path)
                                    if (-not (Test-Path -LiteralPath $Path)) {
                                        New-Item -Path $Path -ItemType Directory -Force | Out-Null
                                    }
                                } -ArgumentList $destLocal -ErrorAction Stop
                            } catch {
                                # Continue. RoboCopy may still succeed if permissions allow it to create directories.
                            }

                            $siteSafeLocal = New-SafeName -Value $SiteName
                            $logFile = Join-Path -Path $LogRootSafe -ChildPath ("{0}\FanOut_{1}_from_{2}.log" -f $siteSafeLocal, $TargetServer, $SeedServer)

                            # Copy from seed local path to target UNC
                            $copyResult = Invoke-RobocopyNoProgress -Source $SeedLocalPath -Destination $destUNC -LogFilePath $logFile `
                                -Retries $Retries -WaitSeconds $WaitSeconds -MT $MT -UseZ $UseZ

                            [pscustomobject]@{
                                Site        = $SiteName
                                Phase       = "FanOut"
                                From        = $SeedServer
                                To          = $TargetServer
                                Destination = $destUNC
                                ExitCode    = $copyResult.ExitCode
                                Result      = $copyResult.Result
                                Duration    = $copyResult.Duration
                                LogFile     = $copyResult.LogFile
                            }
                        } -ArgumentList $seedServer, $targetServer, $DestinationSubPath, $PackageName, $seedDestLocal, $RobocopyRetries, $RobocopyWaitSeconds, $RobocopyMT, $UseRestartableMode, $LogRoot, $siteName

                        $jobList.Add($job) | Out-Null
                    }

                    # Collect results
                    foreach ($j in $jobList) {
                        $jobResult = Receive-Job -Job $j -Wait -AutoRemoveJob
                        if ($jobResult) {
                            $results.Add($jobResult) | Out-Null
                        }
                    }

                    continue
                } else {
                    Write-Verbose ("TwoHop requested but WinRM not available to seed '{0}'. Falling back to Direct mode for site '{1}'." -f $seedServer, $siteName)
                }
            }

            # Direct mode (or fallback)
            foreach ($t in $siteServers) {
                $targetServer = $t.Name

                $targetSystemDrive = Get-RemoteSystemDrive -ComputerName $targetServer
                $targetDriveLetter = $targetSystemDrive.TrimEnd(":")
                $destUNC = "\\{0}\{1}$\{2}\{3}" -f $targetServer, $targetDriveLetter, $DestinationSubPath, $PackageName

                $logFile = Join-Path -Path $LogRoot -ChildPath ("{0}\DirectCopy_{1}.log" -f $siteSafe, $targetServer)

                if ($PSCmdlet.ShouldProcess($targetServer, ("Direct copy package to {0}" -f $destUNC))) {
                    $copyResult = Invoke-RobocopyWithTimer -Source $PackagePath -Destination $destUNC -LogFilePath $logFile `
                        -Retries $RobocopyRetries -WaitSeconds $RobocopyWaitSeconds -MT $RobocopyMT -UseZ $UseRestartableMode `
                        -Activity ("Direct copy to {0} ({1})" -f $targetServer, $siteName)

                    $results.Add([pscustomobject]@{
                        Site        = $siteName
                        Phase       = "Direct"
                        From        = "Runner"
                        To          = $targetServer
                        Destination = $destUNC
                        ExitCode    = $copyResult.ExitCode
                        Result      = $copyResult.Result
                        Duration    = $copyResult.Duration
                        LogFile     = $copyResult.LogFile
                    }) | Out-Null
                }
            }
        }

        # EndRegion: Distribution
    }

    end {
        # Region: Wrap-up and Reporting

        $overallSw.Stop()

        $successes = @($results | Where-Object { $_.Result -eq "Success" })
        $failures  = @($results | Where-Object { $_.Result -ne "Success" })

        Write-Verbose ("Overall duration: {0:hh\:mm\:ss}" -f $overallSw.Elapsed)
        Write-Verbose ("Total operations: {0} Successes: {1} Failures: {2}" -f $results.Count, $successes.Count, $failures.Count)

        # Optional exports
        if ($ExportCsvPath) {
            Write-Verbose ("Exporting CSV to: {0}" -f $ExportCsvPath)
            $results | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Force
        }

        if ($ExportJsonPath) {
            Write-Verbose ("Exporting JSON to: {0}" -f $ExportJsonPath)
            $results | ConvertTo-Json -Depth 6 | Out-File -FilePath $ExportJsonPath -Encoding UTF8 -Force
        }

        # Email notification placeholder (no sending here)
        $emailPayload = $null
        if ($EnableEmailNotification) {
            Write-Verbose "EnableEmailNotification specified. Building email payload object (not sent)."

            $nl = :NewLine

            $failureLines = @()
            foreach ($f in $failures) {
                $failureLines += ("Site={0} Phase={1} From={2} To={3} ExitCode={4} Log={5}" -f `
                    $f.Site, $f.Phase, $f.From, $f.To, $f.ExitCode, $f.LogFile)
            }

            $bodyLines = @()
            $bodyLines += ("Package: {0}" -f $PackageName)
            $bodyLines += ("DistributionMode: {0}" -f $DistributionMode)
            $bodyLines += ("Total operations: {0}" -f $results.Count)
            $bodyLines += ("Successes: {0}" -f $successes.Count)
            $bodyLines += ("Failures: {0}" -f $failures.Count)
            $bodyLines += ("LogRoot: {0}" -f $LogRoot)
            $bodyLines += ""
            $bodyLines += "Failures detail:"
            if ($failureLines.Count -gt 0) {
                $bodyLines += $failureLines
            } else {
                $bodyLines += "None"
            }

            $emailPayload = @{
                Subject = ("Exchange Update Package Distribution Report: {0}" -f $PackageName)
                Body    = ($bodyLines -join $nl)
                To      = "<DL_TBD>"
                'From'  = "<From_TBD>"
                Smtp    = "<SMTP_TBD>"
            }
        }

        # Build return object
        $completedAt = Get-Date
        $startedAt = $completedAt.Add($overallSw.Elapsed.Negate())

        [pscustomobject]@{
            PackageName      = $PackageName
            DistributionMode = $DistributionMode
            LogRoot          = $LogRoot
            StartedAt        = $startedAt
            CompletedAt      = $completedAt
            Duration         = $overallSw.Elapsed
            Operations       = $results
            Successes        = $successes
            Failures         = $failures
            EmailPayload     = $emailPayload
        }

        # EndRegion: Wrap-up and Reporting
    }
}
