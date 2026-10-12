Set-StrictMode -Version Latest

<#
    Teams Rooms collector.

    This is the one scenario that is fully scriptable end to end, so it is the
    proof case for the backbone. It follows the published guidance but tightens
    three things that would cause real problems in a customer environment:

      1. The guidance picks the newest ZIP in C:\Rigel after running the collector.
         If the collector fails, the newest ZIP is a previous collection, and the
         bundle silently contains stale evidence for the wrong incident. This
         module baselines the folder first and only accepts a genuinely new file.

      2. The guidance ends with "Remove-Item -Force C:\Rigel\*.zip", which deletes
         every bundle on the device - including one another engineer may be
         collecting right now. Only the file this run produced is removed.

      3. The guidance opens two separate remote connections (Invoke-Command, then
         New-PSSession). One session is used here for run, fetch and cleanup, so
         the device is authenticated to once and the sequence cannot straddle two
         different connections.
#>

function Get-TlcRoomsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Rooms
    )

    $rigelRoot = $Rooms.RigelRoot
    return [ordered]@{
        RigelRoot    = $rigelRoot
        ScriptLaunch = Join-Path $rigelRoot $Rooms.ScriptLaunchRelativePath
        CollectScript= $Rooms.CollectScriptName
    }
}

function Test-TlcRoomsDevice {
    <#
    .SYNOPSIS
        Confirms the target looks like a Teams Rooms device before collecting.
    .DESCRIPTION
        Runs locally or inside a remote session. Checking first turns "this is not a
        Rooms device" into a clear blocker instead of an obscure failure from the
        collector script.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Rooms,
        [System.Management.Automation.Runspaces.PSSession] $Session
    )

    $paths = Get-TlcRoomsPath -Rooms $Rooms
    $probe = {
        param($rigelRoot, $scriptLaunch)
        [pscustomobject]@{
            ComputerName       = $env:COMPUTERNAME
            RigelRootExists    = Test-Path -LiteralPath $rigelRoot
            ScriptLaunchExists = Test-Path -LiteralPath $scriptLaunch
        }
    }

    if ($Session) {
        return Invoke-Command -Session $Session -ScriptBlock $probe -ArgumentList $paths.RigelRoot, $paths.ScriptLaunch
    }
    return & $probe $paths.RigelRoot $paths.ScriptLaunch
}

function Get-TlcRoomsZipInventory {
    <#
    .SYNOPSIS
        Lists the log bundles currently sitting on the device.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RigelRoot,
        [System.Management.Automation.Runspaces.PSSession] $Session
    )

    $probe = {
        param($root)
        Get-ChildItem -Path (Join-Path $root '*.zip') -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; LastWriteTimeUtc = $_.LastWriteTimeUtc; Length = $_.Length } }
    }

    $result = if ($Session) {
        Invoke-Command -Session $Session -ScriptBlock $probe -ArgumentList $RigelRoot
    } else {
        & $probe $RigelRoot
    }
    return @($result)
}

function Get-TlcRoomsPackageFact {
    <#
    .SYNOPSIS
        Reports which generation of the Teams Rooms app is installed.
    .DESCRIPTION
        The package family name changed with the new MSTeams-based client. Current
        devices carry MSTeamsRooms_8wekyb3d8bbwe; older ones carry
        Microsoft.SkypeRoomSystem_8wekyb3d8bbwe. A check written against one name reports
        "not installed" on the other generation, which reads as a broken device when it
        is simply the other build - and sends someone reimaging a room that was fine.

        Both are therefore probed and both are reported. Neither absence is treated as a
        fault here, because a device legitimately has only one of them.

        Runs locally or through a session, like every other probe in this module.
    #>
    [CmdletBinding()]
    param(
        [System.Management.Automation.Runspaces.PSSession] $Session
    )

    $probe = {
        # Documented family names. The user-facing app runs as the 'Skype' account on a
        # Rooms device, so a per-user Get-AppxPackage run by an admin would miss it -
        # -AllUsers is what makes this answerable from an admin context. It needs
        # elevation, so an access failure is reported rather than swallowed.
        $names = @(
            @{ Family = 'MSTeamsRooms_8wekyb3d8bbwe';                Generation = 'Current (MSTeams-based)' }
            @{ Family = 'Microsoft.SkypeRoomSystem_8wekyb3d8bbwe';   Generation = 'Legacy (SkypeRoomSystem)' }
        )

        $found = foreach ($entry in $names) {
            $package = $null
            $note = ''
            try {
                $package = Get-AppxPackage -AllUsers -ErrorAction Stop |
                    Where-Object { $_.PackageFamilyName -eq $entry.Family } |
                    Select-Object -First 1
            } catch {
                try {
                    $package = Get-AppxPackage -ErrorAction Stop |
                        Where-Object { $_.PackageFamilyName -eq $entry.Family } |
                        Select-Object -First 1
                    $note = 'Read without -AllUsers; an install under another account would not be visible.'
                } catch {
                    $note = $_.Exception.Message
                }
            }

            [pscustomobject]@{
                Family      = $entry.Family
                Generation  = $entry.Generation
                Installed   = [bool]$package
                Version     = if ($package) { [string]$package.Version } else { '' }
                InstallPath = if ($package) { [string]$package.InstallLocation } else { '' }
                Note        = $note
            }
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Packages     = @($found)
        }
    }

    if ($Session) { return Invoke-Command -Session $Session -ScriptBlock $probe }
    return & $probe
}

function Get-TlcRoomsProvisioningInventory {
    <#
    .SYNOPSIS
        Lists what the Rigel provisioning folder actually contains.
    .DESCRIPTION
        Microsoft documents ScriptLaunch.ps1 as the way to run CollectSrsV2Logs.ps1, and
        documents the same wrapper running other scripts, but publishes no list of what
        ships beside it. That list is worth having: it is the difference between knowing
        the device can do something and guessing.

        Enumerating rather than assuming also protects the collector itself. If a future
        image renames the collector, this inventory says so in the bundle instead of the
        run failing with a path that looks like a typo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Rooms,
        [System.Management.Automation.Runspaces.PSSession] $Session
    )

    $paths = Get-TlcRoomsPath -Rooms $Rooms
    $provisioningFolder = Split-Path -Parent $paths.ScriptLaunch

    $probe = {
        param($folder, $collectScript)

        if (-not (Test-Path -LiteralPath $folder)) {
            return [pscustomobject]@{
                Folder            = $folder
                Exists            = $false
                Scripts           = @()
                CollectorPresent  = $false
            }
        }

        $scripts = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.ps1', '.cmd', '.bat', '.exe' } |
            ForEach-Object {
                [pscustomobject]@{
                    Name             = $_.Name
                    SizeBytes        = $_.Length
                    LastWriteTimeUtc = $_.LastWriteTimeUtc
                }
            }

        [pscustomobject]@{
            Folder           = $folder
            Exists           = $true
            Scripts          = @($scripts)
            CollectorPresent = [bool](@($scripts) | Where-Object { $_.Name -eq $collectScript })
        }
    }

    if ($Session) {
        return Invoke-Command -Session $Session -ScriptBlock $probe -ArgumentList $provisioningFolder, $paths.CollectScript
    }
    return & $probe $provisioningFolder $paths.CollectScript
}

function Get-TlcRoomsBundleInventory {
    <#
    .SYNOPSIS
        Lists the entries inside a retrieved SRSv2 bundle without extracting it.
    .DESCRIPTION
        Microsoft documents how to produce the SRSv2 ZIP but never what is inside it.
        Every published description of its internals traces back to community write-ups,
        so the toolbox does not claim to know the layout - it reads the one in hand and
        records what was actually there.

        That turns the long-standing "validate on real hardware" blocker into something
        a single real run answers by itself: collect once, and the bundle inventory in
        the evidence is the documentation nobody has published.

        Reads the central directory only. Extracting a room's log bundle to inspect it
        would double the disk footprint on a machine that may be short of space, and the
        entry list is the whole question.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BundlePath,
        [int] $MaxEntries = 500
    )

    if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
        return [pscustomobject]@{
            BundlePath = $BundlePath
            Readable   = $false
            Reason     = 'Bundle not found.'
            EntryCount = 0
            Entries    = @()
            TopLevel   = @()
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
    } catch {
        # A truncated archive is exactly what the size-settle wait exists to prevent, so
        # saying so here names the cause rather than leaving a corrupt file in a bundle.
        return [pscustomobject]@{
            BundlePath = $BundlePath
            Readable   = $false
            Reason     = "Archive could not be opened: $($_.Exception.Message)"
            EntryCount = 0
            Entries    = @()
            TopLevel   = @()
        }
    }

    try {
        $all = @($archive.Entries)
        $entries = @($all | Select-Object -First $MaxEntries | ForEach-Object {
            [pscustomobject]@{
                Path             = $_.FullName
                SizeBytes        = $_.Length
                CompressedBytes  = $_.CompressedLength
                LastWriteTimeUtc = $_.LastWriteTime.UtcDateTime.ToString('o')
            }
        })

        # The shape of the tree is what a reader wants first, before 400 file names.
        $topLevel = @($all | ForEach-Object {
            $parts = $_.FullName -split '[\\/]'
            if ($parts.Count -gt 1) { $parts[0] } else { '(root)' }
        } | Group-Object | Sort-Object Count -Descending | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; EntryCount = $_.Count }
        })

        return [pscustomobject]@{
            BundlePath = $BundlePath
            Readable   = $true
            Reason     = ''
            EntryCount = $all.Count
            Truncated  = $all.Count -gt $MaxEntries
            Entries    = $entries
            TopLevel   = $topLevel
        }
    } finally {
        if ($archive) { $archive.Dispose() }
    }
}

function Invoke-TlcRoomsLogCollection {
    <#
    .SYNOPSIS
        Runs CollectSrsV2Logs on a Teams Rooms device and retrieves the bundle.
    .PARAMETER TargetDevice
        Device FQDN for a remote collection. Omit to collect from this machine.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Rooms,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string] $TargetDevice,
        [pscredential] $Credential
    )

    $endpoint = if ($TargetDevice) { $TargetDevice } else { $env:COMPUTERNAME }
    $paths = Get-TlcRoomsPath -Rooms $Rooms
    $session = $null

    try {
        if ($TargetDevice) {
            try {
                $sessionArgs = @{ ComputerName = $TargetDevice; ErrorAction = 'Stop' }
                if ($Credential) { $sessionArgs['Credential'] = $Credential }
                $session = New-PSSession @sessionArgs
            } catch {
                $hint = Get-TlcRemoteConnectHint -HostName $TargetDevice
                $reason = if ($hint) { "$hint WinRM said: $($_.Exception.Message)" } else { $_.Exception.Message }
                Write-TlcBlocker -Check 'Rooms.Connect' -Status 'Blocked' -Severity 'Critical' -Endpoint $endpoint `
                    -Detail "Could not open a remote session to ${TargetDevice}: $reason" `
                    -Remediation $(if ($hint) { 'Correct the device name; do not change TrustedHosts for this.' } else { 'Confirm WinRM connectivity and that the account can reach the device.' }) | Out-Null
                Write-TlcEvent -Phase 'Collect' -Step 'Rooms.Connect' -Status 'Failed' -Severity 'Critical' -Endpoint $endpoint `
                    -Message 'Remote session could not be established.' -ErrorRecord $_
                return $null
            }
        }

        $device = Test-TlcRoomsDevice -Rooms $Rooms -Session $session
        if (-not $device.ScriptLaunchExists) {
            # Careful with the wording here. "Not a Teams Rooms device" is what this used
            # to say, and it is wrong for the case that is now common: Teams Rooms on
            # ANDROID. A Cisco Room Bar, Room Kit EQ, Neat Bar or Poly X-series running
            # native MTR genuinely is a Teams Rooms device - it simply has no Rigel tree,
            # no PowerShell and no WinRM, because it is not Windows. Telling an engineer
            # their healthy room is "not a Teams Rooms device" sends them investigating a
            # provisioning fault that does not exist.
            Write-TlcBlocker -Check 'Rooms.Device' -Status 'Blocked' -Severity 'Critical' -Endpoint $endpoint `
                -Detail ("Collector not found at $($paths.ScriptLaunch). This is not a Teams Rooms on Windows device. " +
                         'Teams Rooms on Android - Cisco, Neat, Poly and Yealink bars and boards - is still a Teams Rooms ' +
                         'device but has no Rigel tree, so it cannot be collected this way.') `
                -Remediation ('For Teams Rooms on Android, collect through the Teams Rooms Pro Management portal ' +
                              '(Rooms > device > Actions > Log Collection). For a Cisco device in Webex/RoomOS mode, logs come from ' +
                              'Control Hub or the device web interface. Otherwise target a Teams Rooms on Windows device, or correct ' +
                              'Rooms.RigelRoot in configuration.') | Out-Null
            Write-TlcEvent -Phase 'Collect' -Step 'Rooms.Device' -Status 'Failed' -Severity 'Critical' -Endpoint $endpoint `
                -Message 'Rigel collector not present; not a Teams Rooms on Windows device.'
            return $null
        }

        # Baseline before running, so a failed collection cannot pass off an older
        # bundle as this incident's evidence.
        $before = Get-TlcRoomsZipInventory -RigelRoot $paths.RigelRoot -Session $session
        $knownNames = @($before | ForEach-Object { $_.Name })

        # Device facts are gathered before the collector runs, so they are still recorded
        # when the collection itself fails. A bundle that says "the collector failed and
        # here is what the device had" is far more use than one that only says the first
        # half, and this is the cheap half.
        $packages = $null
        $provisioning = $null
        try {
            $packages = Get-TlcRoomsPackageFact -Session $session
            $provisioning = Get-TlcRoomsProvisioningInventory -Rooms $Rooms -Session $session
        } catch {
            Write-TlcEvent -Phase 'Collect' -Step 'Rooms.DeviceFacts' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                -Message "Device facts could not be read: $($_.Exception.Message)"
        }

        if (-not $PSCmdlet.ShouldProcess($endpoint, 'Run CollectSrsV2Logs')) { return $null }

        Write-TlcEvent -Phase 'Collect' -Step 'Rooms.Invoke' -Status 'Started' -Endpoint $endpoint `
            -Message "Running $($paths.CollectScript); $($knownNames.Count) existing bundle(s) on device."

        $runner = {
            param($scriptLaunch, $collectScript)
            # Inline rather than through Invoke-TlcNativeCommand: this scriptblock may run in
            # a remote runspace where the toolbox modules are not loaded. 5.1 turns redirected
            # native stderr into a terminating error under Stop, and the Rooms collect script
            # writes progress to stderr, so without this the run dies on a healthy device.
            $ErrorActionPreference = 'Continue'
            $output = & powershell.exe -ExecutionPolicy Bypass -File $scriptLaunch $collectScript 2>&1
            [pscustomobject]@{ Output = ($output | Out-String); ExitCode = $LASTEXITCODE }
        }

        $started = Get-Date
        $invocation = if ($session) {
            Invoke-Command -Session $session -ScriptBlock $runner -ArgumentList $paths.ScriptLaunch, $paths.CollectScript
        } else {
            & $runner $paths.ScriptLaunch $paths.CollectScript
        }

        # The collector writes asynchronously, so poll for a bundle that was not
        # present at baseline rather than trusting the command to have finished.
        #
        # A zip is listed by the directory the moment it is created, which is before
        # it has been written. Copying then yields a truncated archive - and a corrupt
        # bundle is worse than no bundle, because it still looks like evidence and the
        # damage is only discovered when somebody tries to open it, by which time the
        # room has usually been handed back. So the size has to settle before the file
        # is treated as finished.
        $deadline = $started.AddMinutes($Rooms.CollectTimeoutMinutes)

        # If the collector reported failure, it is given a short grace period to create
        # a file anyway - it runs asynchronously, so a non-zero exit does not prove it
        # produced nothing - and then the wait is abandoned. Sitting out the full
        # timeout when the collector has already said it failed and has written nothing
        # only delays a diagnosis that is available now, and an engineer standing in a
        # meeting room is paying for that minute.
        $graceDeadline = $started.AddSeconds(15)
        $abandoned = $false

        $newZip = $null
        $previousSize = -1L
        $stableReads = 0

        while ((Get-Date) -lt $deadline) {
            $after = Get-TlcRoomsZipInventory -RigelRoot $paths.RigelRoot -Session $session
            $candidates = @($after | Where-Object { $_.Name -notin $knownNames })

            if ($candidates.Count -eq 0) {
                if ($invocation.ExitCode -and (Get-Date) -ge $graceDeadline) { $abandoned = $true; break }
                Start-Sleep -Seconds 5
                continue
            }

            $candidate = $candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1

            if ($candidate.Length -gt 0 -and $candidate.Length -eq $previousSize) {
                $stableReads++
                if ($stableReads -ge 2) { $newZip = $candidate; break }
            } else {
                # Still growing, or still empty. Start counting again.
                $stableReads = 0
            }

            $previousSize = $candidate.Length
            Start-Sleep -Seconds 2
        }

        if (-not $newZip) {
            $detail = if ($previousSize -ge 0) {
                "A bundle appeared in $($paths.RigelRoot) but was still being written after $($Rooms.CollectTimeoutMinutes) minute(s)."
            } elseif ($abandoned) {
                "The collector reported failure and wrote no bundle to $($paths.RigelRoot)."
            } else {
                "No new log bundle appeared in $($paths.RigelRoot) within $($Rooms.CollectTimeoutMinutes) minute(s)."
            }

            # The collector's own exit code is the first thing worth knowing when no
            # bundle appears, and it was being captured and discarded. A non-zero code
            # says the failure is the collector's, not the wait's.
            if ($invocation.ExitCode) { $detail += " The collector exited with code $($invocation.ExitCode)." }

            Write-TlcBlocker -Check 'Rooms.Collect' -Status 'Blocked' -Severity 'Critical' -Endpoint $endpoint `
                -Detail $detail `
                -Remediation 'Run the collector on the device in Admin mode from an elevated prompt and confirm it completes.' | Out-Null
            Write-TlcEvent -Phase 'Collect' -Step 'Rooms.Collect' -Status 'Failed' -Severity 'Critical' -Endpoint $endpoint `
                -Message 'Collector produced no new bundle.' -EvidencePath $null
            return [ordered]@{
                Endpoint          = $endpoint
                Collected         = $false
                BundleName        = $null
                BundleSizeBytes   = 0
                LocalPath         = $null
                DevicePath        = $null
                PreExistingBundles= $knownNames.Count
                RemovedFromDevice = $false
                CollectorOutput   = $invocation.Output
                CollectorExitCode = $invocation.ExitCode
                CollectedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
                Packages          = $packages
                Provisioning      = $provisioning
                BundleInventory   = $null
            }
        }

        $destination = Join-Path $EndpointPath 'Rooms'
        $null = New-Item -ItemType Directory -Path $destination -Force
        $localZip = Join-Path $destination $newZip.Name

        # Wrapped, because a locked source throws rather than returning. The device is still
        # writing when the settle heuristic is fooled by a starved writer - documented, and
        # observed under load as "the process cannot access the file because it is being used
        # by another process". Unhandled, that propagates out of the collector and fails the
        # whole run with a file-sharing message; as a blocker it is one endpoint reporting
        # that its bundle could not be copied, which is what the rest of the toolbox expects.
        $copyError = $null
        try {
            if ($session) {
                Copy-Item -Path $newZip.FullName -Destination $localZip -FromSession $session -Force -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $newZip.FullName -Destination $localZip -Force -ErrorAction Stop
            }
        } catch {
            $copyError = $_.Exception.Message
        }

        $copiedSize = if (Test-Path -LiteralPath $localZip) { (Get-Item -LiteralPath $localZip).Length } else { 0 }
        if ($copyError -or $copiedSize -le 0) {
            # The partial file is removed. Copy-Item creates the destination before it fails,
            # so a failed copy otherwise leaves a zero-byte zip sitting in the evidence folder
            # looking like a collected bundle - the same shape as finding 129, where four
            # empty logs stood in for files that had never arrived.
            if (Test-Path -LiteralPath $localZip) {
                Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
            }

            $detail = if ($copyError) {
                "Bundle $($newZip.Name) could not be copied back: $copyError"
            } else {
                "Bundle $($newZip.Name) did not copy back correctly."
            }
            Write-TlcBlocker -Check 'Rooms.Copy' -Status 'Blocked' -Severity 'Critical' -Endpoint $endpoint `
                -Detail $detail `
                -Remediation "The bundle was left on the device at $($newZip.FullName). Copy it by hand once nothing is writing to it, or re-run the collection." | Out-Null
            return $null
        }

        # Only the file this run created is removed. The guidance's wildcard delete
        # would take other engineers' bundles with it.
        $removed = $false
        if ($Rooms.RemoveCollectedZipFromDevice) {
            $cleanup = {
                param($path)
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                -not (Test-Path -LiteralPath $path)
            }
            $removed = if ($session) {
                Invoke-Command -Session $session -ScriptBlock $cleanup -ArgumentList $newZip.FullName
            } else {
                & $cleanup $newZip.FullName
            }
        }

        $result = [ordered]@{
            Endpoint          = $endpoint
            Collected         = $true
            BundleName        = $newZip.Name
            BundleSizeBytes   = $copiedSize
            LocalPath         = $localZip
            DevicePath        = $newZip.FullName
            PreExistingBundles= $knownNames.Count
            RemovedFromDevice = [bool]$removed
            CollectorOutput   = $invocation.Output
            CollectorExitCode = $invocation.ExitCode
            CollectedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
            # What the device actually had, recorded while the session is still open.
            # Microsoft publishes neither the bundle's internal layout nor the contents of
            # the provisioning folder, so the only way either gets documented is a real
            # run writing down what it found.
            Packages          = $packages
            Provisioning      = $provisioning
            BundleInventory   = Get-TlcRoomsBundleInventory -BundlePath $localZip
        }

        Write-TlcBlocker -Check 'Rooms.Collect' -Status 'Success' -Endpoint $endpoint `
            -Detail "$($newZip.Name), $([math]::Round($copiedSize/1KB,1)) KB retrieved." | Out-Null
        Write-TlcEvent -Phase 'Collect' -Step 'Rooms.Collect' -Status 'Complete' -Endpoint $endpoint `
            -Message "Retrieved $($newZip.Name)." -EvidencePath $localZip

        return $result
    } finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function Get-TlcRoomsPath, Test-TlcRoomsDevice, Get-TlcRoomsZipInventory, Invoke-TlcRoomsLogCollection,
    Get-TlcRoomsPackageFact, Get-TlcRoomsProvisioningInventory, Get-TlcRoomsBundleInventory


