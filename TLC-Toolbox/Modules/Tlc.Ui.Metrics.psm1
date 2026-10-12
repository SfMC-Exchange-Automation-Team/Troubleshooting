Set-StrictMode -Version Latest

<#
    Readiness and health facts for the wizard's dashboard.

    Everything here answers one question: is a run started right now going to be worth
    anything? That is not rhetorical for this tool. The whole premise is retrospective
    collection - the user is trying to capture an incident that has already cleared -
    and Teams rotates its logs. A collection that runs perfectly against a window the
    retained logs do not cover produces a healthy-looking bundle with nothing in it,
    and nothing downstream flags that.

    Cost matters because this runs while the window is opening. Measured on a real
    profile with 260 log files: enumeration 22 ms, size and timestamp stats 64 ms.
    Those are cheap enough to do inline. The Application event log query is 1.7 s,
    which is not, so Get-TlcCrashMetric is kept separate and the wizard runs it off
    the UI thread.
#>

function Get-TlcMetricStatus {
    <#
    .SYNOPSIS
        Maps a metric to one of the theme's four status names.
    .DESCRIPTION
        Pass, Warning, Blocked and Neutral are the same four states EPO uses for
        findings, and the wizard resolves them to the theme's existing brush pairs.
        Keeping the vocabulary identical is the point: a red tile here has to mean
        what a red row means there, or the colour is just decoration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warning', 'Blocked', 'Neutral')] [string] $Status
    )
    return $Status
}

function New-TlcMetricText {
    <#
    .SYNOPSIS
        One sentence of a tile's explanation: its key in the string tables, its English, and
        the values in it.
    .DESCRIPTION
        The metrics explain themselves in English, and that English goes on being what is
        compared, logged and quoted. The window says the same thing in its own language by
        looking the key up and filling in the same values (Get-TlcMetricText). So the two are
        written once, here, as one call: the English is the template filled in, and
        Tlc.Localization.Tests.ps1 requires every -English literal to be the en-US entry for
        its -Key, word for word.

        Values are kept as the text the English shows - a date already formatted, a count -
        so a translation shows the same figures. A value may also be another part, or a list
        of parts (New-TlcMetricList), for a phrase inside a sentence that is itself words.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $English,
        [AllowEmptyCollection()] [object[]] $Argument = @()
    )

    $values = @(foreach ($value in @($Argument)) {
        if ($value -is [pscustomobject] -and $value.PSObject.Properties['Text']) { $value } else { [string]$value }
    })
    $texts = @(foreach ($value in $values) { if ($value -is [string]) { $value } else { [string]$value.Text } })
    return [pscustomobject]@{
        Key  = $Key
        Args = $values
        Text = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $English, [object[]]$texts)
    }
}

function New-TlcMetricList {
    <#
    .SYNOPSIS
        Several parts that read as one value - "09:00 to 09:20, 10:00 to 10:05" - joined.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()] [object[]] $Part = @(),
        [string] $Separator = ', '
    )

    $parts = @($Part | Where-Object { $null -ne $_ })
    return [pscustomobject]@{
        Parts = $parts
        Join  = $Separator
        Text  = (@($parts | ForEach-Object { [string]$_.Text }) -join $Separator)
    }
}

function Join-TlcMetricText {
    <#
    .SYNOPSIS
        The English of several parts, as one explanation: each a sentence, joined by a space.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()] [object[]] $Part = @())

    return (@($Part | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.Text }) -join ' ')
}

function Get-TlcNetworkPathPart {
    <#
    .SYNOPSIS
        What the traffic goes through, as a part the window can translate.
    .DESCRIPTION
        Built from the kind and names Get-TlcNetworkIntermediation returns beside its English
        Summary, and reads exactly as that Summary does. Product and connection names are
        names, so a path made only of them comes back as the plain string. An object without
        a kind (an older bundle, a test double) gets its Summary back unchanged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] $Intermediation)

    if (-not $Intermediation) { return '' }
    # Read by presence, not by dotting: under strict mode a missing property throws, and an
    # object from before these fields existed is exactly the case the fallback is for.
    $read = {
        param([string] $Name)
        if ($Intermediation -is [System.Collections.IDictionary]) {
            if ($Intermediation.Contains($Name)) { return $Intermediation[$Name] }
        } elseif ($Intermediation.PSObject.Properties[$Name]) {
            return $Intermediation.$Name
        }
        return $null
    }
    $names = [string](& $read 'SummaryNames')
    switch ([string](& $read 'SummaryKind')) {
        'Products'   { return $names }
        'Vpn'        { return (New-TlcMetricText -Key 'NetworkPathVpn' -English 'VPN: {0}' -Argument @($names)) }
        'VpnAdapter' { return (New-TlcMetricText -Key 'NetworkPathVpnAdapter' -English 'VPN adapter: {0}' -Argument @($names)) }
        'Installed'  { return (New-TlcMetricText -Key 'NetworkPathInstalled' -English '{0} (installed, not running)' -Argument @($names)) }
        'Direct'     { return (New-TlcMetricText -Key 'NetworkPathDirect' -English 'Direct') }
    }
    return [string](& $read 'Summary')
}
function Get-TlcLogInventory {
    <#
    .SYNOPSIS
        Counts, sizes and time-bounds the Teams client logs currently on disk.
    .DESCRIPTION
        Bounds come from the filename rather than CreationTime, for the reason
        Get-TlcLogFileStart documents: a copy or a roaming profile rewrites
        CreationTime, and the name does not lie about when the file started.

        LastWriteTime is used for the newest edge because that is what "is Teams
        writing right now" actually means.

        RollingPattern is separate from Pattern on purpose, because volume and time
        bounds are different questions.

        Volume - how much is there to collect - covers every family the collector takes.
        The time bounds must not. Teams keeps its families on very different terms:
        MSTeams_*.log rolls at roughly 30 days and is written continuously while the
        client is alive, while MSTeamsAutoStarter_*.log is written only when Teams starts
        with Windows, so a handful of files can sit there for over a year.

        Both edges come from the rolling families, and both feed a tile:

          OldestStart -> Logs go back (retention) and Window covered (coverage)
          NewestWrite -> Teams activity

        Measured after those sparse families were added to the collector, all three were
        wrong at once:

          Retention reported "397.2 days" from one 398-day-old autostarter file, while the
          logs carrying the evidence stopped at 26. That reads as "a year-old incident is
          collectable", which is false.

          Coverage - the check that exists to stop a wasted collection - answered "Covered"
          for a window 200 days back, on the strength of the same file.

          Activity answered "Just now" for a client that had been dead nine hours, because
          a background updater had ticked ten minutes earlier. Background updaters run
          whether or not the Teams UI is alive, so they answer "is something Teams-related
          running", not "is the client live".

        Changing this parameter moves three tiles, not one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogRoot,
        [string[]] $Pattern = @('MSTeams_*.log'),
        [string[]] $RollingPattern = @('MSTeams_*.log'),
        # The main client log, whose actual spans decide coverage and how far back the logs
        # are continuous. Finding 325.
        [string] $MainPattern = 'MSTeams_*.log'
    )

    $result = [ordered]@{
        RootExists       = $false
        FileCount        = 0
        RollingFileCount = 0
        TotalBytes       = [long]0
        OldestStart      = $null
        NewestWrite      = $null
        MainSpans        = @()
    }

    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { return $result }
    $result.RootExists = $true

    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($glob in $Pattern) {
        foreach ($file in (Get-ChildItem -LiteralPath $LogRoot -File -Filter $glob -ErrorAction SilentlyContinue)) {
            $files.Add($file)
        }
    }

    if ($files.Count -eq 0) { return $result }

    $result.FileCount = $files.Count

    # Which names set the time bounds. Resolved once here rather than per file, so the
    # comparison below is a set lookup instead of a wildcard match per pattern per file.
    $rollingNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($glob in $RollingPattern) {
        foreach ($file in (Get-ChildItem -LiteralPath $LogRoot -File -Filter $glob -ErrorAction SilentlyContinue)) {
            $null = $rollingNames.Add($file.Name)
        }
    }

    $bytes = [long]0
    $oldest = $null
    $newest = $null
    $rollingCount = 0
    foreach ($file in $files) {
        $bytes += $file.Length

        # Every collected file counts toward size; only the rolling families bound the
        # window a collection can reach, or say whether the client is writing now.
        if (-not $rollingNames.Contains($file.Name)) { continue }
        $rollingCount++

        $start = Get-TlcLogFileStart -File $file
        if ($null -eq $oldest -or $start -lt $oldest) { $oldest = $start }
        if ($null -eq $newest -or $file.LastWriteTime -gt $newest) { $newest = $file.LastWriteTime }
    }

    $result.TotalBytes = $bytes
    $result.RollingFileCount = $rollingCount
    $result.OldestStart = $oldest
    $result.NewestWrite = $newest

    # What the main log actually covers. Teams keeps only its most recent seven MSTeams_*.log
    # files for a running client and the last seven of each earlier session, so OldestStart can
    # be a month back while nothing covers most of that month. Finding 325.
    $mainFiles = @($files | Where-Object { $_.Name -like $MainPattern })
    if ($mainFiles.Count -gt 0) { $result.MainSpans = @(Get-TlcLogSpan -Files $mainFiles) }
    return $result
}

function Get-TlcClientMetric {
    <#
    .SYNOPSIS
        Is there a Teams client to collect from at all, and can it actually run.
    .DESCRIPTION
        PRESENT AND USABLE ARE DIFFERENT QUESTIONS, and until 2026-09-17 only the first
        was asked here. The tile returned Pass and a version number whenever the package
        was registered, so a package Windows will refuse to activate - Tampered, Disabled,
        DependencyIssue - showed green with its version beside it.

        The collector already knew. Tlc.Collect.Desktop raises
        ClientInventory.PackageHealth at Critical/Blocked for exactly these states, and the
        whole point of this dashboard is that it answers before the run rather than after
        it. The tile was reporting health it had not measured, on a condition that BLOCKS.

        No extra work is done for it. Status and InstallLocation are already on the object
        this is handed; they were simply not read.
    #>
    [CmdletBinding()]
    param([hashtable] $Package)

    if (-not $Package) { $Package = Get-TlcAppxPackage }

    $teams = if ($Package.ContainsKey('Teams')) { $Package.Teams } else { $null }
    if (-not $teams) {
        $parts = @(New-TlcMetricText -Key 'DetailClientNotFound' -English 'The MSTeams package is not registered for this user, so a desktop collection would gather nothing. Run in the affected user session.')
        return [ordered]@{
            Status = 'Blocked'
            Value  = 'Not found'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    # 'Ok' is the only status Windows will activate from. Anything else is reported as
    # itself rather than translated, because the word is the diagnostic: DependencyIssue
    # points at a missing framework package rather than at Teams, and Tampered is usually
    # set by an EDR product.
    $packageStatus = [string]$teams.Status
    if ($packageStatus -and $packageStatus -ne 'Ok') {
        $parts = @(New-TlcMetricText -Key 'DetailClientBadStatus' -English 'MSTeams {0} is registered but reports status ''{1}'', so Windows will block it at activation. Repair or re-register the package before treating this as a Teams fault.' -Argument @($teams.Version, $packageStatus))
        return [ordered]@{
            Status = 'Blocked'
            Value  = $packageStatus
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    # A registration whose files are gone. The version still reads back, which is what
    # made this worth checking separately - the package answers every question except
    # whether it is still on disk.
    $installLocation = [string]$teams.InstallLocation
    if ($installLocation -and -not (Test-Path -LiteralPath $installLocation)) {
        $parts = @(New-TlcMetricText -Key 'DetailClientOrphaned' -English 'The package is registered as {0} but its install location is missing: {1}. The registration is orphaned; re-register the package for this user.' -Argument @($teams.Version, $installLocation))
        return [ordered]@{
            Status = 'Blocked'
            Value  = 'Orphaned'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    $parts = @(New-TlcMetricText -Key 'DetailClientOk' -English 'MSTeams {0} is installed for this user, reports status Ok, and its install location is present.' -Argument @($teams.Version))
    return [ordered]@{
        Status = 'Pass'
        Value  = [string]$teams.Version
        Detail = Join-TlcMetricText $parts; DetailParts = $parts
    }
}

function Get-TlcLogVolumeMetric {
    <#
    .SYNOPSIS
        How much log data exists to collect.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Inventory)

    if (-not $Inventory.RootExists) {
        $parts = @(New-TlcMetricText -Key 'DetailLogsNoFolder' -English 'The Teams log folder does not exist for this user.')
        return [ordered]@{
            Status = 'Blocked'; Value = 'No log folder'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    if ($Inventory.FileCount -eq 0) {
        $parts = @(New-TlcMetricText -Key 'DetailLogsEmpty' -English 'The Teams log folder exists but holds no client logs.')
        return [ordered]@{
            Status = 'Blocked'; Value = 'None'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    $mb = [Math]::Round($Inventory.TotalBytes / 1MB, 1)
    $parts = @(New-TlcMetricText -Key 'DetailLogsCount' -English '{0} client log file(s) totalling {1} MB.' -Argument @($Inventory.FileCount, $mb))
    return [ordered]@{
        Status = 'Pass'
        Value  = "$($Inventory.FileCount) files, $mb MB"
        Detail = Join-TlcMetricText $parts; DetailParts = $parts
    }
}

function Get-TlcRetentionMetric {
    <#
    .SYNOPSIS
        How far back the retained logs reach.
    .DESCRIPTION
        The single most important number on the dashboard. If retention is shorter
        than the age of the incident, the run cannot succeed no matter how well it
        executes, and this is the only place that says so before the user commits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Inventory,
        [datetime] $Now = (Get-Date)
    )

    if (-not $Inventory.OldestStart) {
        $parts = @(New-TlcMetricText -Key 'DetailRetentionNone' -English 'Nothing retained.')
        return [ordered]@{ Status = 'Blocked'; Value = 'No logs'; Detail = Join-TlcMetricText $parts; DetailParts = $parts }
    }

    # How far back the MAIN log is continuous, when the spans are known. The oldest file was
    # the number shown here, and it misled: Teams keeps seven MSTeams_*.log files per running
    # client, so "31.9 days" sat above a main log that covered the last 22 minutes. Measured on
    # the lab endpoint, 2026-09-29. Finding 325.
    $spans = @(if ($Inventory.Contains('MainSpans')) { @($Inventory['MainSpans']) | Where-Object { $_ } })
    if ($spans.Count -gt 0) {
        $latest = @($spans | Sort-Object End)[-1]
        $live = ($Now - $latest.End).TotalMinutes -le 30
        $reach = if ($live) { $Now - $latest.Start } else { $latest.End - $latest.Start }
        $value = if ($reach.TotalMinutes -lt 90) { '{0:N0} min' -f $reach.TotalMinutes }
                 elseif ($reach.TotalHours -lt 48) { '{0:N1} hours' -f $reach.TotalHours }
                 else { '{0:N1} days' -f $reach.TotalDays }
        $parts = @(
            if ($live) {
                New-TlcMetricText -Key 'DetailRetentionLive' -English 'The main Teams log is continuous back to {0}.' -Argument @($latest.Start.ToString('yyyy-MM-dd HH:mm'))
            } else {
                New-TlcMetricText -Key 'DetailRetentionIdle' -English 'Teams is not writing its main log now. Its last session''s log runs from {0} to {1}.' -Argument @($latest.Start.ToString('yyyy-MM-dd HH:mm'), $latest.End.ToString('HH:mm'))
            }
            New-TlcMetricText -Key 'DetailRetentionRotation' -English 'Teams keeps only its most recent seven MSTeams_*.log files for a running client, and the last seven of each earlier session, so anything older survives only in fragments; the oldest starts {0}. The Window tile says whether the time you pick is covered.' -Argument @($Inventory.OldestStart.ToString('yyyy-MM-dd HH:mm'))
        )
        return [ordered]@{
            Status = if ($reach.TotalHours -lt 24) { 'Warning' } else { 'Pass' }
            Value  = $value
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    $span = $Now - $Inventory.OldestStart
    $days = [Math]::Round($span.TotalDays, 1)

    # Under a day of retention is the case this tool exists to warn about: an issue
    # reported the next morning is already unrecoverable.
    $status = if ($span.TotalHours -lt 24) { 'Warning' } else { 'Pass' }

    $value = if ($span.TotalHours -lt 24) {
        "{0:N1} hours" -f $span.TotalHours
    } else {
        "$days days"
    }

    $parts = @(New-TlcMetricText -Key 'DetailRetentionOldest' -English 'Oldest retained log starts {0}.' -Argument @($Inventory.OldestStart.ToString('yyyy-MM-dd HH:mm')))
    return [ordered]@{
        Status = $status
        Value  = $value
        Detail = Join-TlcMetricText $parts; DetailParts = $parts
    }
}

function Get-TlcActivityMetric {
    <#
    .SYNOPSIS
        Health. Is Teams actually writing logs right now.
    .DESCRIPTION
        A log folder that has not been touched in hours means Teams is not running,
        or is running and not logging. Either way the client state captured by a run
        started now will not reflect a live client.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Inventory,
        [datetime] $Now = (Get-Date)
    )

    if (-not $Inventory.NewestWrite) {
        $parts = @(New-TlcMetricText -Key 'DetailActivityNever' -English 'No log has ever been written here.')
        return [ordered]@{ Status = 'Blocked'; Value = 'Never'; Detail = Join-TlcMetricText $parts; DetailParts = $parts }
    }

    $age = $Now - $Inventory.NewestWrite
    $status = if ($age.TotalMinutes -le 30) { 'Pass' } elseif ($age.TotalHours -le 6) { 'Warning' } else { 'Blocked' }

    $value = if ($age.TotalMinutes -lt 1) { 'Just now' }
        elseif ($age.TotalMinutes -lt 60) { '{0:N0} min ago' -f $age.TotalMinutes }
        elseif ($age.TotalHours -lt 48) { '{0:N1} hours ago' -f $age.TotalHours }
        else { '{0:N0} days ago' -f $age.TotalDays }

    $parts = @(New-TlcMetricText -Key 'DetailActivityNewest' -English 'Most recent log write {0}.' -Argument @($Inventory.NewestWrite.ToString('yyyy-MM-dd HH:mm')))
    return [ordered]@{
        Status = $status
        Value  = $value
        Detail = Join-TlcMetricText $parts; DetailParts = $parts
    }
}

function Get-TlcCoverageMetric {
    <#
    .SYNOPSIS
        Does the selected impact window fall inside the retained logs.
    .DESCRIPTION
        The live one. It re-evaluates as the form changes, and it is the check that
        stops a wasted collection: everything else on the dashboard can be green
        while the window the user has actually typed sits outside what is on disk.

        WindowStart and WindowEnd are LOCAL, matching the filename timestamps they
        are compared against. Passing UTC here would silently mis-report by the size
        of the offset - the same trap Select-TlcLogFileInWindow documents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Inventory,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [datetime] $Now = (Get-Date)
    )

    if (-not $Inventory.OldestStart) {
        $parts = @(New-TlcMetricText -Key 'DetailCoverageNoLogs' -English 'Nothing retained to cover it.')
        return [ordered]@{ Status = 'Blocked'; Value = 'No logs'; Detail = Join-TlcMetricText $parts; DetailParts = $parts }
    }

    if ($WindowStart -gt $Now) {
        $parts = @(New-TlcMetricText -Key 'DetailCoverageFuture' -English 'The window starts later than now, so no log can exist for it yet.')
        return [ordered]@{
            Status = 'Warning'; Value = 'In the future'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    # A window that ENDS in the future, having started in the past. This is the default: the
    # form seeds the impact time with now, so a stock run asks for now-30 to now+30 and half
    # of it cannot exist yet.
    #
    # It used to report "Covered - retained logs span the whole selected window", which is
    # false and reassuring in the same breath. Nothing in the toolbox waits for the rest of the
    # window to happen: every collector filters files that are already on disk, so the minutes
    # after now contribute nothing. Measured with after=0 against after=30 on the same machine:
    # identical client logs both times.
    #
    # Warning rather than Blocked, because the past half is usually the half that matters and
    # the run is still worth making.
    if ($WindowEnd -gt $Now) {
        $ahead = [int][math]::Round(($WindowEnd - $Now).TotalMinutes)
        $parts = @(New-TlcMetricText -Key 'DetailCoverageEndsAhead' -English 'The window runs {0} minute(s) past now. Collection reads logs that already exist and does not wait, so that part contributes nothing. Collect again afterwards to cover it, or set the impact time to when the fault actually happened.' -Argument @($ahead))
        return [ordered]@{
            Status = 'Warning'; Value = 'Ends in the future'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    # The window against what the main log actually covers, when the spans are known. Against
    # the oldest file alone this answered "Covered" for a window whose main log Teams had deleted
    # hours before, because an older session's last files were still on disk. Finding 325.
    $spans = @(if ($Inventory.Contains('MainSpans')) { @($Inventory['MainSpans']) | Where-Object { $_ } })
    if ($spans.Count -gt 0) {
        $gaps = @(Get-TlcSpanGap -Spans $spans -WindowStart $WindowStart -WindowEnd $WindowEnd)
        $windowMinutes = ($WindowEnd - $WindowStart).TotalMinutes
        $missingMinutes = (@($gaps | ForEach-Object { ($_.End - $_.Start).TotalMinutes }) | Measure-Object -Sum).Sum
        $ranges = New-TlcMetricList -Part @($gaps | Select-Object -First 3 | ForEach-Object {
            New-TlcMetricText -Key 'DetailCoverageRange' -English '{0} to {1}' -Argument @($_.Start.ToString('HH:mm'), $_.End.ToString('HH:mm'))
        })
        $why = New-TlcMetricText -Key 'DetailCoverageWhy' -English 'Teams keeps only its most recent seven MSTeams_*.log files for a running client, so the earlier part of a long session is deleted as it logs, and a restart leaves a short gap.'
        if ($gaps.Count -eq 0) {
            $parts = @(New-TlcMetricText -Key 'DetailCoverageMainSpans' -English 'The main Teams log spans the whole selected window: {0} to {1} on {2}. Existing logs are selected from that span - nothing is recorded while you wait.' -Argument @($WindowStart.ToString('HH:mm'), $WindowEnd.ToString('HH:mm'), $WindowStart.ToString('yyyy-MM-dd')))
            return [ordered]@{
                Status = 'Pass'; Value = 'Covered'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }
        $earliest = @($spans | Sort-Object Start)[0].Start
        if ($WindowEnd -lt $earliest) {
            $parts = @(New-TlcMetricText -Key 'DetailCoverageBeforeMain' -English 'The window ends before the oldest retained main log ({0}).' -Argument @($earliest.ToString('yyyy-MM-dd HH:mm')))
            return [ordered]@{
                Status = 'Blocked'; Value = 'Older than logs'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }
        if ($missingMinutes -ge ($windowMinutes - 1)) {
            $parts = @(
                New-TlcMetricText -Key 'DetailCoverageGap' -English 'The main Teams log has nothing from {0} on {1}.' -Argument @($ranges, $WindowStart.ToString('yyyy-MM-dd'))
                $why
                New-TlcMetricText -Key 'DetailCoverageGapRest' -English 'The other logs are still collected, but the client log for this time is gone.'
            )
            return [ordered]@{
                Status = 'Blocked'; Value = 'In a log gap'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }
        $parts = @(
            New-TlcMetricText -Key 'DetailCoveragePartial' -English 'The main Teams log is missing {0} of the window''s {1} minutes: {2}.' -Argument @([int][math]::Round($missingMinutes), [int][math]::Round($windowMinutes), $ranges)
            $why
        )
        return [ordered]@{
            Status = 'Warning'; Value = 'Partly covered'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    if ($WindowEnd -lt $Inventory.OldestStart) {
        $parts = @(New-TlcMetricText -Key 'DetailCoverageBeforeOldest' -English 'The window ends before the oldest retained log ({0}).' -Argument @($Inventory.OldestStart.ToString('yyyy-MM-dd HH:mm')))
        return [ordered]@{
            Status = 'Blocked'; Value = 'Older than logs'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    if ($WindowStart -lt $Inventory.OldestStart) {
        $parts = @(New-TlcMetricText -Key 'DetailCoverageStartMissing' -English 'Logs only reach back to {0}, so the start of the window is missing.' -Argument @($Inventory.OldestStart.ToString('yyyy-MM-dd HH:mm')))
        return [ordered]@{
            Status = 'Warning'; Value = 'Partly covered'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    $parts = @(New-TlcMetricText -Key 'DetailCoverageRetained' -English 'Retained logs span the whole selected window: {0} to {1} on {2}. Existing logs are selected from that span - nothing is recorded while you wait.' -Argument @($WindowStart.ToString('HH:mm'), $WindowEnd.ToString('HH:mm'), $WindowStart.ToString('yyyy-MM-dd')))
    return [ordered]@{
        Status = 'Pass'; Value = 'Covered'
        # The resolved range, not just a verdict.
        #
        # "30 before, 30 after" is a relative expression and reads to a lot of people as a
        # DURATION - as though the tool records for that long. It does not: collection reads
        # logs Teams has already written and the window only selects which of them to take.
        # Naming the two absolute times makes it read as the selection it is, and costs a
        # tile detail nobody was using for anything else.
        Detail = Join-TlcMetricText $parts; DetailParts = $parts
    }
}

function Get-TlcCrashMetric {
    <#
    .SYNOPSIS
        Health. Teams application crashes recorded in the last day.
    .DESCRIPTION
        Event IDs 1000 and 1001 are the application-crash and Windows Error Reporting
        entries the collection already gathers, so this is the same evidence surfaced
        early. A non-zero count corroborates a crash scenario before anything is run.

        Measured at ~1.7 s on a normal Application log, which is why the wizard calls
        this off the UI thread rather than during window construction.
    #>
    [CmdletBinding()]
    param(
        [int] $Hours = 24,
        [string] $Match = 'teams',
        # The WebView2 renderer crash fact, from Get-TlcWebViewCrashFact. Optional so the
        # metric still answers without it, but the caller is expected to supply it.
        $WebView
    )

    # New Teams is a WebView2 application, and a renderer crash - the window going blank,
    # or the app reloading itself - does NOT reliably reach the Application event log.
    # This tile reads the Application log. So the count below could be a true zero while
    # Crashpad held a stack of reports, and the tile would say "None" to an engineer
    # investigating a crash. A false clean is the worst shape a metric can take, and this
    # one was documented in Get-TlcWebViewCrashFact's own help before it was surfaced.
    $webViewCount = 0
    if ($WebView -and $WebView.PSObject.Properties['TotalCount']) {
        $webViewCount = [int]$WebView.TotalCount
    }

    $webViewNote = if ($webViewCount -gt 0) {
        New-TlcMetricText -Key 'DetailCrashWebView' -English '{0} WebView2 renderer crash report(s) are also present, which the Application log does not record.' -Argument @($webViewCount)
    } else { $null }

    try {
        $since = (Get-Date).AddHours(-$Hours)
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            Id        = 1000, 1001
            StartTime = $since
        } -ErrorAction Stop | Where-Object { $_.Message -and $_.Message -match $Match })

        $count = $events.Count
        $total = $count + $webViewCount
        $status = if ($total -eq 0) { 'Pass' } elseif ($total -le 2) { 'Warning' } else { 'Blocked' }

        $parts = @(@(
            New-TlcMetricText -Key 'DetailCrashCount' -English '{0} Teams-related crash event(s) in the Application log over the last {1} hours.' -Argument @($count, $Hours)
            $webViewNote
        ) | Where-Object { $_ })
        return [ordered]@{
            Status = $status
            Value  = if ($total -eq 0) { 'None' } elseif ($webViewCount -gt 0) { "$total in $Hours h" } else { "$count in $Hours h" }
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    } catch {
        # No matching events at all makes Get-WinEvent throw rather than return
        # nothing, so an empty log and a broken query look identical unless the
        # error is checked. Treat "none found" as the good news it is. By error id as well
        # as by text: the message is localized (review 2026-09-30).
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match 'No events were found') {
            $status = if ($webViewCount -eq 0) { 'Pass' } elseif ($webViewCount -le 2) { 'Warning' } else { 'Blocked' }
            $parts = @(@(
                New-TlcMetricText -Key 'DetailCrashNone' -English 'No crash events in the last {0} hours.' -Argument @($Hours)
                $webViewNote
            ) | Where-Object { $_ })
            return [ordered]@{
                Status = $status
                Value  = if ($webViewCount -eq 0) { 'None' } else { "$webViewCount in $Hours h" }
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }

        $parts = @(New-TlcMetricText -Key 'DetailCrashUnreadable' -English 'The Application log could not be read: {0}' -Argument @($_.Exception.Message))
        return [ordered]@{
            Status = 'Neutral'; Value = 'Unavailable'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }
}

function Get-TlcNetworkPathMetric {
    <#
    .SYNOPSIS
        Whether Teams traffic leaves this machine directly or through something.
    .DESCRIPTION
        Amber when something is in the path, and deliberately so, but it is not calling
        the tunnel a fault - plenty of healthy estates carry every byte through one.
        What it flags is that the network evidence in the bundle was measured through an
        intermediary: the TCP and STUN results describe the path to the tunnel's exit,
        not the path to Microsoft. Green here means those results can be read at face
        value. Grey means the question could not be answered, which is not the same as
        "nothing in the way".

        Takes the fast form of the detection - services and adapters, ~90 ms - because
        reading VPN profiles costs 1.4 s and adds only profile names. The bundle gets
        the full version.

        TLS INSPECTION IS PART OF THE SAME QUESTION, and leaving it out made "Direct"
        a false clean. Intermediation is detected from tunnelling SERVICES on this
        machine, so break-and-inspect performed at a firewall - with no client installed
        here at all - was invisible to it: the tile read Direct, in green, while every
        TLS session was being terminated and re-signed in the middle. Microsoft documents
        that as a cause of Teams update and media failures, so a tile saying the evidence
        can be read at face value was actively wrong. The certificate chain answers it in
        ~870 ms, which is inside the budget this tile already has.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Intermediation,
        # The TLS certificate fact for a Teams host, from Get-TlcTlsCertificateFact.
        # Optional: without it the tile reports intermediation alone, as it used to.
        $Tls
    )

    # A chain that does not end at a public root is what break-and-inspect looks like.
    # Only trusted when the handshake actually completed - a failed handshake leaves
    # PubliclyRooted false for a reason that has nothing to do with interception.
    $inspected = $false
    if ($Tls -and $Tls.Handshake -eq $true -and $Tls.PubliclyRooted -eq $false) {
        $inspected = $true
    }
    $inspectionNote = if ($inspected) {
        New-TlcMetricText -Key 'DetailNetworkInspected' -English 'The TLS chain for {0} ends at ''{1}'' rather than a public root, which is what break-and-inspect looks like - Microsoft documents it as a cause of Teams update and media failures.' -Argument @($Tls.HostName, $Tls.ChainRoot)
    } else { $null }

    try {
        if (-not $Intermediation) { $Intermediation = Get-TlcNetworkIntermediation }

        if (-not $Intermediation.Intermediated) {
            # Nothing tunnelling, but the session is still being opened and re-signed by
            # something. Not Direct, whatever the service list says.
            if ($inspected) {
                $parts = @(
                    New-TlcMetricText -Key 'DetailNetworkNotUntouched' -English 'No tunnelling client or connected VPN was found, but the traffic is not reaching Microsoft untouched.'
                    $inspectionNote
                )
                return [ordered]@{
                    Status = 'Warning'
                    Value  = 'Inspected'
                    Detail = Join-TlcMetricText $parts; DetailParts = $parts
                }
            }

            $idle = @($Intermediation.Tunnels | Where-Object { -not $_.Running })
            $parts = @(if ($idle.Count -gt 0) {
                New-TlcMetricText -Key 'DetailNetworkIdle' -English '{0}. Installed but not running, so traffic is going out directly.' -Argument @(Get-TlcNetworkPathPart -Intermediation $Intermediation)
            } else {
                New-TlcMetricText -Key 'DetailNetworkDirect' -English 'No tunnelling client or connected VPN was found, so the network checks measure the direct path.'
            })
            return [ordered]@{ Status = 'Pass'; Value = 'Direct'; Detail = Join-TlcMetricText $parts; DetailParts = $parts }
        }

        # The tile says WHAT KIND is in the path; the product name lives in the detail behind
        # the click. It used to carry $Intermediation.Summary, which is the product name, and
        # that has two problems on a 3x3 grid roughly 273px wide: "Entra Global Secure Access"
        # is 26 characters, and an estate running two intermediaries produces a comma-joined
        # list that is longer still.
        #
        # Kind rather than a flat "VPN", because the catalogue already separates the two and
        # the reason is written beside it: SASE means all traffic may be redirected, a VPN is
        # one the user dialled. Calling Zscaler a VPN would throw away a distinction this code
        # deliberately makes. Mixed estates are named as such rather than picking a winner.
        $kinds = @(@($Intermediation.Tunnels | Where-Object { $_.Running } |
            ForEach-Object { [string]$_.Kind }) | Sort-Object -Unique)
        $value = if ($kinds.Count -eq 1) {
            $kinds[0]
        } elseif ($kinds.Count -gt 1) {
            $kinds -join ' + '
        } else {
            # Intermediated with no running tunnel of a known kind - a tunnel ADAPTER was seen
            # rather than a catalogued service. "Tunnelled" is the honest answer: something is
            # in the path and this cannot say which product.
            'Tunnelled'
        }

        $parts = @(@(
            New-TlcMetricText -Key 'DetailNetworkCarried' -English 'Teams traffic is carried through {0}. Not a fault in itself, but the reachability and media-path results in this bundle were measured through it rather than directly - compare against a machine off this path before calling a network result a customer problem.' -Argument @(Get-TlcNetworkPathPart -Intermediation $Intermediation)
            $inspectionNote
        ) | Where-Object { $_ })
        return [ordered]@{
            Status = 'Warning'
            Value  = $value
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    } catch {
        $parts = @(New-TlcMetricText -Key 'DetailNetworkUnreadable' -English 'The network path could not be determined: {0}' -Argument @($_.Exception.Message))
        return [ordered]@{
            Status = 'Neutral'; Value = 'Unavailable'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }
}

function Get-TlcUpdateMetric {
    <#
    .SYNOPSIS
        How long the client has been on its current build.
    .DESCRIPTION
        "Did this start after an update?" is the first question asked about any regression,
        and the dashboard could not answer it. A build that landed yesterday against a
        problem reported today is the single most useful coincidence in Teams triage.

        Amber has a specific meaning here, and it is not "an update is bad". It is that the
        update lands inside the window being collected - so the logs span two different
        clients and a behaviour change across them is expected rather than suspicious.
        That is worth flagging before the run, not discovered afterwards in the excerpt.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $History,
        [datetime] $WindowStart,
        [datetime] $WindowEnd
    )

    try {
        if (-not $History) {
            $parts = @(New-TlcMetricText -Key 'DetailUpdateNone' -English 'The update history could not be read.')
            return [ordered]@{
                Status = 'Neutral'; Value = 'Unavailable'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }

        if (-not $History.LastUpdateLocal) {
            # No recorded transition is not the same as no information: the staging date
            # still says when this build arrived.
            if ($History.StagedAtLocal) {
                $staged = [datetime]::Parse($History.StagedAtLocal, [cultureinfo]::InvariantCulture)
                $days = [math]::Round(((Get-Date) - $staged).TotalDays, 0)
                $parts = @(New-TlcMetricText -Key 'DetailUpdateStaged' -English 'Build {0} was staged {1}. No version change is recorded in the launcher logs, so this client has not updated within their retention.' -Argument @($History.CurrentVersion, $staged.ToString('yyyy-MM-dd HH:mm')))
                return [ordered]@{
                    Status = 'Pass'
                    Value  = "$days days ago"
                    Detail = Join-TlcMetricText $parts; DetailParts = $parts
                }
            }
            $parts = @(New-TlcMetricText -Key 'DetailUpdateUnknown' -English 'No version change is recorded in the {0} launcher log(s) on disk, and the install location could not be read.' -Argument @($History.Scanned))
            return [ordered]@{
                Status = 'Neutral'; Value = 'Unknown'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }

        $when = [datetime]::Parse($History.LastUpdateLocal, [cultureinfo]::InvariantCulture)
        $days = [math]::Round(((Get-Date) - $when).TotalDays, 0)
        $value = if ($days -le 0) { 'Today' } elseif ($days -eq 1) { 'Yesterday' } else { "$days days ago" }

        $updated = New-TlcMetricText -Key 'DetailUpdateWhen' -English 'Updated {0} from {1} to {2}.' -Argument @($when.ToString('yyyy-MM-dd HH:mm'), $History.PreviousVersion, $History.CurrentVersion)

        if ($PSBoundParameters.ContainsKey('WindowStart') -and $PSBoundParameters.ContainsKey('WindowEnd') -and
            $when -ge $WindowStart -and $when -le $WindowEnd) {
            $parts = @(
                $updated
                New-TlcMetricText -Key 'DetailUpdateInWindow' -English 'That is inside the window being collected, so the logs span two different client builds - expect behaviour to change partway through, and say so when handing the bundle over.'
            )
            return [ordered]@{
                Status = 'Warning'
                Value  = $value
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }

        $parts = @($updated)
        return [ordered]@{ Status = 'Pass'; Value = $value; Detail = Join-TlcMetricText $parts; DetailParts = $parts }
    } catch {
        $parts = @(New-TlcMetricText -Key 'DetailUpdateUnreadable' -English 'The update history could not be read: {0}' -Argument @($_.Exception.Message))
        return [ordered]@{
            Status = 'Neutral'; Value = 'Unavailable'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }
}

function Get-TlcBrokerAccount {
    <#
    .SYNOPSIS
        Resolves Teams account object ids to the person and tenant behind them.
    .DESCRIPTION
        app_settings.json -> active_users lists one entry per signed-in *tenant identity*,
        not per person. A single user who is a guest in a second tenant has two entries
        with two different object ids, and nothing in that file says they are the same
        human being. The dashboard reported "2 accounts" on a machine with one user signed
        in, which is factually true and practically wrong - and the privacy gate would
        have blocked packaging over it.

        The Windows token broker holds the missing half. Each .tbacct blob under
        Microsoft.AAD.BrokerPlugin is UTF-16 JSON carrying Name, OID, TenantId, UserName
        and DisplayName, so an object id can be resolved to a UPN and a tenant. That is
        what turns "2 accounts" into "1 person, 2 tenants".

        Measured at ~125 ms warm across 53 blobs on a real machine, so it is cheap enough
        for the dashboard's background pass.

        Returns a map keyed by object id. Empty when the broker store is unreadable, which
        the caller must treat as "cannot resolve" rather than "no accounts".
    #>
    [CmdletBinding()]
    param(
        [string] $BrokerRoot = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts')
    )

    $map = @{}
    if (-not (Test-Path -LiteralPath $BrokerRoot)) { return $map }

    foreach ($file in (Get-ChildItem -LiteralPath $BrokerRoot -File -Filter '*.tbacct' -ErrorAction SilentlyContinue)) {
        try {
            # UTF-16, and only a handful of fields are wanted, so this reads the bytes and
            # regexes rather than parsing the whole document - the blobs carry profile
            # pictures and token material that is of no interest here.
            $text = [System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($file.FullName))

            $oid = [regex]::Match($text, '"Name":"OID","Value":"([^"]+)"')
            if (-not $oid.Success) { continue }
            $key = $oid.Groups[1].Value
            if ($map.ContainsKey($key)) { continue }

            $upn = [regex]::Match($text, '"Name":"UserName","Value":"([^"]+)"')
            $tenant = [regex]::Match($text, '"Name":"TenantId","Value":"([^"]+)"')
            $display = [regex]::Match($text, '"Name":"DisplayName","Value":"([^"]+)"')

            $map[$key] = [ordered]@{
                Upn         = if ($upn.Success) { $upn.Groups[1].Value } else { '' }
                TenantId    = if ($tenant.Success) { $tenant.Groups[1].Value } else { '' }
                DisplayName = if ($display.Success) { $display.Groups[1].Value } else { '' }
            }
        } catch {
            Write-Verbose "Could not read $($file.Name): $($_.Exception.Message)"
        }
    }

    return $map
}

function Get-TlcPlatform {
    <#
    .SYNOPSIS
        Whether Teams is running inside a virtualised desktop session, and on which stack.
    .DESCRIPTION
        This matters for three documented reasons, and each of them changes what a local
        collection is worth.

        The media logs are not here. Microsoft's client/server log-location table for
        VDI 2.0 puts skylib on both sides but media-stack only "On the client" - the user's
        physical endpoint. A collection run inside the session gets the server-side skylib
        and misses media-stack entirely, so a call-quality case collected here is missing
        the evidence it is about.
        https://learn.microsoft.com/en-us/microsoftteams/vdi-2-troubleshooting

        The logs are smaller. "To preserve disk space, the size of logs files for Microsoft
        Teams Virtual Desktop (VDI) clients is limited by default. If an issue is
        encountered on a VDI client, turn Extended Logging on in Teams Privacy settings
        before reproducing the issue and collecting logs."
        https://learn.microsoft.com/en-us/microsoftteams/log-files

        The admin center is not an option. Remote client log collection is documented
        "supported for Windows (non-VDI) and Mac Applications only", which is why
        Get-TlcToolChoice takes this as an input rather than recommending a route that
        would silently never produce a bundle.
        https://learn.microsoft.com/en-us/microsoftteams/teams-client-diagnostic-logging

        BEING A VM IS NOT BEING A VIRTUAL DESKTOP. A Hyper-V guest on someone's desk with a
        console session is a VM and is not VDI; treating the two as the same would put a
        warning about missing media logs in front of every developer running a test VM.
        Win32_ComputerSystem.HypervisorPresent is documented as "a hypervisor is present",
        which is also true on a physical machine running the Hyper-V role or with
        Virtualization-Based Security enabled - so it is recorded as evidence and never used
        to decide. Nothing Microsoft documents equates a VM with a virtualised desktop.

        Signals are ordered by how well Microsoft documents them, and the one that wins is
        reported, because the banner has to say what it found rather than assert a stack.
        Anything resting on community knowledge rather than Microsoft documentation is
        marked Confidence = 'Community', so the caller can decline to make a claim on it.

        $Probe exists so every branch is testable on a machine that is none of these. This
        one is not virtualised, so without injection only the negative case could ever run.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Probe
    )

    try {
        $signals = if ($Probe) { $Probe } else { Get-TlcPlatformSignal }

        $evidence = [System.Collections.Generic.List[string]]::new()
        foreach ($key in 'HypervisorPresent', 'Model', 'Manufacturer') {
            if ($signals.ContainsKey($key) -and $null -ne $signals[$key] -and '' -ne [string]$signals[$key]) {
                $evidence.Add("$key = $($signals[$key])")
            }
        }

        # 1. Teams' own VDI connection file. Microsoft explicitly sanctions querying this
        #    from scripts, and it is the only signal written by Teams itself rather than
        #    inferred from the platform underneath it.
        if ($signals['VdiConnectionInfo']) {
            $info = $signals['VdiConnectionInfo']

            # Teams writes only the fields that apply: under WebRTC optimisation only
            # vdiConnectedState is populated. Reading a missing property threw under
            # StrictMode, and the catch below turned a documented VDI session into
            # "Unknown" with the advisory suppressed (review 2026-09-30, finding 331).
            $field = {
                param([string] $Name)
                if ($info -is [System.Collections.IDictionary]) { return [string]$info[$Name] }
                $property = $info.PSObject.Properties[$Name]
                if ($property) { return [string]$property.Value }
                return ''
            }
            $vendor = & $field 'rdClientProductName'
            $stack = & $field 'connectedStack'

            $platform = switch -Wildcard ($vendor) {
                '*Citrix*'          { 'Citrix';        break }
                '*Remote Desktop*'  { 'AvdOrCloudPc';  break }
                '*Omnissa*'         { 'Horizon';       break }
                '*Horizon*'         { 'Horizon';       break }
                default             { 'VirtualDesktop' }
            }
            $evidence.Add('Teams vdi_connection_info.json is present')
            if ($vendor) { $evidence.Add("rdClientProductName = $vendor") }
            if ($stack)  { $evidence.Add("connectedStack = $stack") }

            # connectedStack: "remote" = optimised, "local" = not optimised. Only meaningful
            # when the file says so - Microsoft documents that under WebRTC optimisation only
            # vdiConnectedState is populated, and with no optimisation the file is not updated
            # at all, so absence is not evidence of "not optimised".
            $optimised = if ($stack -eq 'remote') { $true } elseif ($stack -eq 'local') { $false } else { $null }

            return New-TlcPlatformResult -Platform $platform -IsVirtualDesktop $true `
                -Confidence 'Documented' -Optimised $optimised -Evidence $evidence
        }

        # 2. AVD and Windows 365 share the agent stack. Microsoft documents no way to tell
        #    them apart, so this does not pretend to - "AVD or Windows 365" is the honest
        #    label and the one the banner shows.
        if ($signals['RdInfraAgent'] -or $signals['RdAgentBootLoader']) {
            if ($signals['RdInfraAgent'])      { $evidence.Add('HKLM:\SOFTWARE\Microsoft\RDInfraAgent exists') }
            if ($signals['RdAgentBootLoader']) { $evidence.Add('RDAgentBootLoader service is installed') }
            return New-TlcPlatformResult -Platform 'AvdOrCloudPc' -IsVirtualDesktop $true `
                -Confidence 'Documented' -Evidence $evidence
        }

        # 3. Citrix, VDA side. Microsoft documents this key as part of the Teams-on-Citrix
        #    requirements, so it is a documented signal rather than a guess at Citrix's own
        #    layout.
        if ($signals['CitrixWebSocketService']) {
            $evidence.Add('Citrix WebSocketService registry key exists (VDA side)')
            return New-TlcPlatformResult -Platform 'Citrix' -IsVirtualDesktop $true `
                -Confidence 'Documented' -Evidence $evidence
        }

        # 4. Horizon. Microsoft documents endpoint-side Omnissa artefacts only and nothing
        #    for detecting a Horizon session from inside the VM, so this is marked Community
        #    and the caller decides whether to make a claim on it.
        if ($signals['HorizonAgent']) {
            $evidence.Add('VMware/Omnissa Horizon agent registry key exists (not Microsoft-documented)')
            return New-TlcPlatformResult -Platform 'Horizon' -IsVirtualDesktop $true `
                -Confidence 'Community' -Evidence $evidence
        }

        # 5. A remote session that is none of the above - plain RDP or Terminal Services.
        #    Compared against GlassSessionId, which is Microsoft's own recommended method:
        #    GetSystemMetrics(SM_REMOTESESSION) has a documented false negative on sessions
        #    using RemoteFX vGPU, where it reports a remote session as local.
        #    https://learn.microsoft.com/en-us/windows/win32/termserv/detecting-the-terminal-services-environment
        $sessionId = $signals['SessionId']
        $glassId = $signals['GlassSessionId']
        if ($null -ne $sessionId -and $null -ne $glassId -and $sessionId -ne $glassId) {
            $evidence.Add("session $sessionId is not the console session ($glassId)")
            return New-TlcPlatformResult -Platform 'RemoteDesktop' -IsVirtualDesktop $true `
                -Confidence 'Documented' -Evidence $evidence
        }

        return New-TlcPlatformResult -Platform 'Physical' -IsVirtualDesktop $false `
            -Confidence 'Documented' -Evidence $evidence
    } catch {
        # A platform that cannot be determined must not stop the window or, worse, produce a
        # confident "physical" that suppresses the advisory. Neutral says "not known".
        return [ordered]@{
            Status = 'Neutral'; Value = 'Unknown'; Platform = 'Unknown'
            IsVirtualDesktop = $false; Confidence = 'Unknown'; Optimised = $null
            Evidence = @()
            Detail = "The desktop platform could not be determined: $($_.Exception.Message)"
        }
    }
}

function New-TlcPlatformResult {
    <#
        Shapes one platform verdict. Split out so every branch above returns the same keys -
        a caller reading .IsVirtualDesktop off a hashtable that happens not to have it would
        throw under StrictMode, inside a banner refresh that swallows errors quietly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] [bool] $IsVirtualDesktop,
        [Parameter(Mandatory)] [string] $Confidence,
        [object] $Optimised,
        $Evidence
    )

    $label = switch ($Platform) {
        'AvdOrCloudPc'   { 'Azure Virtual Desktop or Windows 365' }
        'Citrix'         { 'Citrix' }
        'Horizon'        { 'VMware or Omnissa Horizon' }
        'RemoteDesktop'  { 'a remote desktop session' }
        'VirtualDesktop' { 'a virtual desktop' }
        'Physical'       { 'this machine' }
        default          { $Platform }
    }

    $detail = if (-not $IsVirtualDesktop) {
        'No virtual desktop session was detected, so the logs for this client are on this machine.'
    } else {
        "Teams is running in $label."
    }

    return [ordered]@{
        Status           = if ($IsVirtualDesktop) { 'Warning' } else { 'Pass' }
        Value            = if ($IsVirtualDesktop) { $label } else { 'Physical' }
        Platform         = $Platform
        IsVirtualDesktop = $IsVirtualDesktop
        Confidence       = $Confidence
        Optimised        = $Optimised
        Evidence         = @($Evidence)
        Detail           = $detail
    }
}

function Get-TlcPlatformSignal {
    <#
        The raw readings Get-TlcPlatform decides on, separated from the deciding so the
        rules can be tested on a machine that is none of these.

        Every read is individually guarded. A missing registry hive, a denied service query
        or an unparseable JSON file must each degrade to "signal absent" rather than taking
        the whole probe - and a probe that throws would leave the caller with no platform at
        all, which is worse than one weak signal missing.
    #>
    [CmdletBinding()]
    param()

    $signal = @{}

    $signal['RdInfraAgent'] = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction SilentlyContinue

    $signal['RdAgentBootLoader'] = $null -ne (Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue)

    $signal['CitrixWebSocketService'] =
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Citrix\WebSocketService' -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Citrix\WebSocketService' -ErrorAction SilentlyContinue)

    # Community signal, not Microsoft-documented. Kept because a Horizon session is real even
    # though Microsoft does not say how to spot one from inside; the verdict it produces is
    # marked Community so the caller can decline to claim it.
    $signal['HorizonAgent'] =
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM' -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Omnissa\Horizon' -ErrorAction SilentlyContinue)

    try {
        $signal['SessionId'] = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    } catch { $signal['SessionId'] = $null }

    try {
        $glass = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
            -Name 'GlassSessionId' -ErrorAction Stop
        $signal['GlassSessionId'] = [int]$glass.GlassSessionId
    } catch { $signal['GlassSessionId'] = $null }

    # Hardware identity is deliberately NOT read here. Win32_ComputerSystem costs about a
    # second - measured, and the largest single cost in this probe - and none of it decides
    # anything: HypervisorPresent, Model and Manufacturer are evidence only.
    #
    # Worse than useless, on this machine it is actively misleading. A physical Surface Book 2
    # reports HypervisorPresent = True, because the property is documented as "a hypervisor is
    # present" and that is also true with Virtualization-Based Security enabled. Displaying it
    # beside a VDI verdict invites exactly the wrong conclusion, so it is left null and a test
    # injects it to prove the rules never read it.
    $signal['HypervisorPresent'] = $null
    $signal['Model'] = $null
    $signal['Manufacturer'] = $null

    # Teams' own file. Documented location, and Microsoft states admins may script against it.
    # https://learn.microsoft.com/en-us/microsoftteams/vdi-2
    $signal['VdiConnectionInfo'] = $null
    try {
        $tfw = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\tfw\vdi_connection_info.json'
        if (Test-Path -LiteralPath $tfw) {
            $signal['VdiConnectionInfo'] = Get-Content -LiteralPath $tfw -Raw | ConvertFrom-Json
        }
    } catch { $signal['VdiConnectionInfo'] = $null }

    return $signal
}

function Get-TlcPlatformAdvisoryText {
    <#
    .SYNOPSIS
        What a virtual desktop changes about collecting here, in the order it matters.
    .DESCRIPTION
        Every sentence traces to a Microsoft document. The tool's standing rule is that it
        does not state what Microsoft has not, and this advisory is the easiest place in the
        window to break it - the community writes a great deal about Teams on VDI that
        Microsoft has never published.

        Three documented facts, and only the ones that change what the operator should do:

        1. Media logs are on the endpoint. The VDI 2.0 log-location table lists media-stack
           only "On the client", so a collection inside the session gets the server-side
           skylib and none of the media stack. That decides whether this collection can
           answer a call-quality question at all.
           https://learn.microsoft.com/en-us/microsoftteams/vdi-2-troubleshooting

        2. Logs are capped by default on VDI clients, and Extended Logging has to be turned
           on BEFORE the repro. That is actionable only in advance, which is why it belongs
           on a pre-collection banner rather than in a report afterwards.
           https://learn.microsoft.com/en-us/microsoftteams/log-files

        3. Non-persistent profiles. Microsoft documents that FSLogix deletes the contents of
           AppData\Local\Packages\*\LocalCache at sign-out "regardless of any redirections.xml
           configuration", and separately that Teams logs live under that path. Microsoft
           never writes the sentence "Teams logs are destroyed at logoff", so this is phrased
           as the conditional it is rather than as a finding about this machine - the toolbox
           does not know whether FSLogix is in use here.
           https://learn.microsoft.com/en-us/fslogix/concepts-container-types

        The optimisation state is only mentioned when Teams itself reported it. Microsoft
        documents that the file is not updated at all when no optimisation is available, so
        a missing value means "not stated" and not "not optimised".
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Platform,
        # A resolved string table, to say it in the window's language. Without one the text is
        # the English below, and with en-US it is the same English to the character -
        # Tlc.Localization.Tests.ps1 holds the two together.
        [hashtable] $Strings
    )

    $say = {
        param([string] $Key, [string] $English, [object[]] $Argument)
        $template = if ($Strings -and $Strings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Strings[$Key])) { [string]$Strings[$Key] } else { $English }
        if ($Argument) {
            try { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $template, $Argument) }
            catch [System.FormatException] { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $English, $Argument) }
        }
        return $template
    }

    $where = if ($Platform -and $Platform.Value) { [string]$Platform.Value } else { & $say 'AdvisoryVdiSomewhere' 'a virtual desktop' }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((& $say 'AdvisoryVdiMediaLogs' "Teams is running in {0}, so the media logs are written on the physical endpoint rather than in this session - a collection here gets the session's skylib logs and none of the media stack." @($where)))
    $parts.Add((& $say 'AdvisoryVdiLogCap' 'Log size is capped by default on VDI clients; turn Extended Logging on in Teams privacy settings before reproducing the issue.'))
    $parts.Add((& $say 'AdvisoryVdiProfile' 'If the profile is non-persistent, the log folder is one FSLogix deletes at sign-out, so collect before the user signs off.'))

    if ($Platform -and $Platform.Confidence -eq 'Community') {
        # The signal that produced this verdict is not one Microsoft publishes, so the
        # advisory says so rather than presenting a guess in the same voice as a fact.
        $parts.Add((& $say 'AdvisoryVdiCommunity' 'This platform was identified from a vendor signal Microsoft does not document, so confirm it before relying on it.'))
    }

    return ($parts -join ' ')
}

function Get-TlcToolChoice {
    <#
    .SYNOPSIS
        Whether this toolbox is the right instrument for the case, or the Teams admin
        centre would do the job with less disruption.
    .DESCRIPTION
        Every other tile reports a measurement. This reports a conclusion drawn from
        several of them, which is why it is presented as a banner above the dashboard
        rather than as another tile among its own inputs.

        The question it answers comes before readiness: an engineer can have a perfectly
        collectable machine and still be at the wrong console. TAC's remote client log
        collection is silent, needs nobody at the keyboard, and retains for 30 days - so
        when it can do the job, it usually should.

        Whether TAC is even a route for the scenario is not decided here. The scenario
        catalog already declares it: a scenario whose Manual lane lists TacRemoteClientLogs
        has a TAC path, and one that does not, does not. Reading it from the catalog rather
        than from a list maintained here means a new scenario cannot silently acquire a
        recommendation nobody wrote.

        Everything below that is a documented TAC limitation checked against measured local
        state. The rules are ordered, first match wins, and each carries the reason so the
        banner can say why rather than just what.

        It returns nothing when the dashboard has not finished measuring, or when the
        signals disagree. A recommendation is only worth making when it is clear, and a
        confident steer on weak evidence is the failure this project cares most about.
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Scenario,
        [hashtable] $SignIn,
        [hashtable] $Client,
        [hashtable] $Retention,
        [hashtable] $Platform,
        # Fleet readiness, from Get-TlcFleetReadiness. Optional, and deliberately weak
        # evidence - see the note on the admin-center branch below.
        [hashtable] $FleetReadiness
    )

    if (-not $Scenario) { return $null }

    $manual = @($Scenario.Manual)
    $tacIsARoute = $manual -contains 'TacRemoteClientLogs'

    if (-not $tacIsARoute) {
        return [ordered]@{
            Choice = 'Toolbox'
            Value  = 'Collect here'
            Detail = "The admin center's remote client log collection is not a route for $($Scenario.Name). Its bundle is the client's own logs; this scenario needs evidence it does not gather."
            ValueKey    = 'ToolChoiceCollectHere'
            DetailParts = @(@{ Key = 'ToolChoiceNotARoute'; Args = @([string]$Scenario.Name) })
        }
    }

    # From here the scenario does have a TAC path, so the question is whether anything
    # about this machine stops TAC working.

    # First among the machine-state rules, because it is the only flat one. The others are
    # judgements about whether TAC would work well; this is Microsoft documenting that it is
    # not supported at all - "This feature is currently supported for Windows (non-VDI) and
    # Mac Applications only." Recommending it here would send an engineer to a console that
    # will never produce a bundle, and the request would simply expire.
    # https://learn.microsoft.com/en-us/microsoftteams/teams-client-diagnostic-logging
    #
    # Only on a verdict Microsoft's own documentation supports. A Horizon session is detected
    # from a community signal, and steering someone away from a working route on a signal
    # Microsoft has never published is a worse error than not mentioning it.
    if ($Platform -and $Platform.IsVirtualDesktop -and $Platform.Confidence -eq 'Documented') {
        return [ordered]@{
            Choice = 'Toolbox'
            Value  = 'Collect here'
            Detail = "The admin center's remote client log collection is documented as supported for Windows (non-VDI) only, and this is $($Platform.Value). A request would not reach this client."
            ValueKey    = 'ToolChoiceCollectHere'
            DetailParts = @(@{ Key = 'ToolChoiceVirtualDesktop'; Args = @([string]$Platform.Value) })
        }
    }

    if ($Client -and $Client.Status -eq 'Blocked') {
        return [ordered]@{
            Choice = 'Toolbox'
            Value  = 'Collect here'
            Detail = 'The admin center needs the Teams client running to check in and collect. This machine cannot offer it one, so a request would sit unfulfilled until it expired.'
            ValueKey    = 'ToolChoiceCollectHere'
            DetailParts = @(@{ Key = 'ToolChoiceClientBlocked' })
        }
    }

    if ($SignIn -and $SignIn.Status -eq 'Blocked') {
        return [ordered]@{
            Choice = 'Toolbox'
            Value  = 'Collect here'
            Detail = "The admin center's device list is built from signed-in client telemetry, so a client that cannot sign in is unlikely to appear in it at all."
            ValueKey    = 'ToolChoiceCollectHere'
            DetailParts = @(@{ Key = 'ToolChoiceSignInBlocked' })
        }
    }

    # TAC has no time-window parameter and takes up to 8 hours, so it collects whatever is
    # on disk when it eventually runs. On a client that rotates quickly the evidence can be
    # gone by then. Two days is the threshold: it leaves room for the documented delay plus
    # the rest of a working day.
    if ($Retention -and $Retention.Status -eq 'Warning') {
        return [ordered]@{
            Choice = 'Toolbox'
            Value  = 'Collect here'
            Detail = 'The admin center takes up to 8 hours and has no time-window parameter, so it collects whatever is on disk when it runs. This client is rotating its logs faster than that, so the evidence may not survive the wait.'
            ValueKey    = 'ToolChoiceCollectHere'
            DetailParts = @(@{ Key = 'ToolChoiceRetention' })
        }
    }

    # Nothing is said for the admin center until sign-in, client and retention have all been
    # measured. The banner is refreshed on every scenario change, including those before the
    # first background check lands, and with no metrics every rule above was skipped and this
    # fell through to recommending the admin center on no evidence at all. A tile the check
    # could not measure is Neutral, which is the same unknown (review 2026-09-30, finding 331).
    foreach ($measured in @($SignIn, $Client, $Retention)) {
        if (-not $measured -or [string]$measured['Status'] -notin @('Pass', 'Warning', 'Blocked')) { return $null }
    }

    # "Most of this", not "this".
    #
    # The banner used to claim the admin center could do the job outright, and the Feature
    # comparison behind it says otherwise on every run: the remote route returns the client's
    # own diagnostic bundle and nothing else, while a collection here also takes Windows event
    # logs, the network path, registry policy and the identity inventory - several of which
    # the admin center is documented as explicitly NOT collecting.
    #
    # So the honest claim is that it covers the client logs, which is usually the evidence
    # that matters, and not that it covers everything. An operator who takes "can do this"
    # literally, collects remotely and then finds the event logs missing has been told
    # something untrue by the tool that was supposed to be advising them.
    # "Nobody at the machine" USED TO BE TAC'S ALONE. Fleet mode was proven end to end on
    # 2026-09-22 - a correlated run against a real second endpoint in 41 seconds, packaged
    # into one bundle carrying both machines - so the toolbox now has a remote route too,
    # and it returns everything a local collection does rather than client logs only.
    #
    # The recommendation is NOT reversed, and the reasons matter. TAC needs no WinRM, no
    # credentials for the endpoint and no network path to it, retains for 30 days, and
    # reaches machines an engineer cannot. Fleet mode needs all of those things.
    #
    # THE EVIDENCE FOR MENTIONING IT IS DELIBERATELY WEAK, and the wording matches. Fleet
    # readiness answers "is there any point offering the control at all" - its own help says
    # it "says nothing about whether a session to a PARTICULAR endpoint will succeed",
    # because auth and firewall are per-endpoint and no local probe can settle them. So this
    # says the route EXISTS, never that it will work. Claiming reachability from a local
    # listener check would be the confident-steer-on-weak-evidence failure this whole banner
    # is written to avoid.
    $fleetNote = ''
    $parts = @(@{ Key = 'ToolChoiceAdminCenterDetail'; Args = @([string]$Scenario.Name) })
    if ($FleetReadiness -and $FleetReadiness['Ready']) {
        $fleetNote = ' This machine can also drive a remote collection itself - see "Also collect from" below - which takes minutes rather than hours and returns the full evidence set, though it needs WinRM and credentials for the target, which the admin center does not.'
        $parts += @{ Key = 'ToolChoiceFleetNote' }
    }

    # ValueKey and DetailParts carry the same words as Value and Detail as keys into the string
    # tables, so the window can show the banner in its own language while Value and Detail,
    # which the dismissal signature is made of, stay English and do not change with it.
    # Tlc.Localization.Tests.ps1 requires the English entries to rebuild Detail exactly.
    return [ordered]@{
        Choice = 'AdminCenter'
        Value  = 'The admin center can do most of this'
        Detail = "Nothing here needs local context, and $($Scenario.Name) has a remote client log route. Collecting there is silent and needs nobody at the machine, though it takes up to 8 hours and returns client logs only - event logs, network path and policy still need a collection here.$fleetNote"
        ValueKey    = 'ToolChoiceAdminCenter'
        DetailParts = $parts
    }
}

function Get-TlcAdminCenterProcedure {
    <#
    .SYNOPSIS
        How to actually collect logs from the Teams admin center.
    .DESCRIPTION
        The recommendation banner has told operators to go to the admin center since it was
        written, and never said how to do it once there. Reported 2026-09-22: "how to collect
        logs from admin center is missing". The steps existed only in
        docs\admin-center-comparison.md, which does not ship in a customer package and is not
        where somebody standing at a red tile is looking.

        Every line is from Microsoft's documented procedure rather than from memory of the
        portal, because the portal's wording moves and a half-remembered menu path is worse
        than none - it sends someone hunting for a button that was renamed.
        https://learn.microsoft.com/en-us/microsoftteams/teams-client-diagnostic-logging

        The preconditions are here rather than in a separate note. Three of them silently
        produce no bundle at all - VDI, a client that is not running, and mixed commercial
        plus government accounts - and each costs up to 8 hours before the silence is
        noticeable.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    # Each line is a part (New-TlcMetricText), so the window can say it in the operator's
    # language while .Text keeps the English. The portal's own names - its menus, tabs and
    # buttons - the role names, the cmdlets and the address are passed in rather than written
    # into the sentence: they are what the operator has to find on a screen or type, and no
    # translation may change them. Finding 338.
    return [ordered]@{
        Steps = @(
            New-TlcMetricText -Key 'AdminStepSignIn' -English 'Sign in to the Teams admin center at {0}' -Argument @('https://admin.teams.microsoft.com')
            New-TlcMetricText -Key 'AdminStepUsers' -English 'Go to {0}, then {1}, and open the affected user.' -Argument @('Users', 'Manage users')
            New-TlcMetricText -Key 'AdminStepTab' -English 'Open the {0} tab.' -Argument @('Client health')
            New-TlcMetricText -Key 'AdminStepRequest' -English 'Choose {0}. The user is not prompted and sees nothing.' -Argument @('Request client logs')
            New-TlcMetricText -Key 'AdminStepWait' -English 'Wait. Microsoft documents up to 8 hours before the bundle can be downloaded, and the request expires after 3 days.'
            New-TlcMetricText -Key 'AdminStepDownload' -English 'Return to the same {0} tab and choose {1} to download it.' -Argument @('Client health', 'View client logs')
        )
        Roles = New-TlcMetricText -Key 'AdminRoles' -English '{0}, {1}, {2}, or {3}.' -Argument @('Global Administrator', 'Teams Administrator', 'Teams Communications Support Engineer', 'Teams Communications Support Specialist')
        Preconditions = @(
            New-TlcMetricText -Key 'AdminNeedsRunning' -English 'The Teams client must be RUNNING on the machine. A client that cannot start never checks in, and the request simply expires.'
            New-TlcMetricText -Key 'AdminNeedsPlatform' -English 'Windows non-VDI and Mac only. VDI is explicitly excluded, as are web, mobile and Linux.'
            New-TlcMetricText -Key 'AdminNeedsOneCloud' -English 'A client signed in to both commercial and government accounts is ineligible - the feature is unavailable for it.'
        )
        NotCollected = New-TlcMetricText -Key 'AdminNotCollected' -English 'Windows event logs, {0} traces, screenshots and heap dumps are documented as explicitly not collected. There is no time-window parameter either: it takes whatever is on disk when it runs.' -Argument @('procmon')
        Retention = New-TlcMetricText -Key 'AdminRetention' -English 'Bundles are retained for 30 days in Microsoft storage.'
        PowerShell = New-TlcMetricText -Key 'AdminPowerShell' -English 'The same store is reachable from PowerShell: {0} is the {1} button, {2} is the {3} page, and {4} is {5}.' -Argument @('New-CsTeamsRemoteLogCollectionDevice', 'Request', 'Get-', 'View', 'Remove-', 'Delete')
        Reference = 'https://learn.microsoft.com/en-us/microsoftteams/teams-client-diagnostic-logging'
    }
}
function Get-TlcCapabilityComparison {
    <#
    .SYNOPSIS
        What this toolbox and the admin center's remote collection each actually gather.
    .DESCRIPTION
        The banner tells an engineer which console to be at. This is the reasoning behind
        that verdict, in the form a reader can check.

        EVERY ROW WAS READ OUT OF A BUNDLE, not out of documentation. Two comparisons were
        written before this one from Microsoft Learn and from the toolbox's own source, and
        both concluded the two tools largely overlapped. Comparing two real artifacts -
        a remote-class bundle captured on 2026-09-10 and a toolbox bundle from a Collect run
        the same afternoon - showed they barely overlap at all. Capability lists are written
        by whoever is describing the thing; bundles show what actually arrives.

        The unverified row is left in deliberately. Microsoft documents the admin center
        collecting desktop shell and SlimCore logs, and the captured artifact contains
        neither. Rather than resolve that by picking whichever answer suits, it is shown as
        unverified, because a table that quietly drops its inconvenient row is the reason
        the first two versions were wrong.
    #>
    [CmdletBinding()]
    param()

    # Each value is a part (New-TlcMetricText), so the window can say it in the operator's
    # language while .Text keeps the English. File, product and tool names are passed in
    # rather than written into the sentence, so no translation can change what the reader has
    # to look for in a bundle; a value that is nothing but file names stays a plain string.
    # Finding 338.
    return [ordered]@{
        Basis = New-TlcMetricText -Key 'CompareBasis' -English 'Measured {0} by comparing a captured remote-class bundle (74 entries, 5.5 MB) against a toolbox bundle from a real Collect run (33 files). Rows marked documented were not observed in an artifact.' -Argument @('2026-09-10')

        Shared = @(
            [ordered]@{
                Fact    = (New-TlcMetricText -Key 'CompareConfigFact' -English 'Client configuration')
                Remote  = (New-TlcMetricText -Key 'CompareConfigRemote' -English '{0}, 3.4 MB - the web client tree' -Argument @('settings.json'))
                Toolbox = (New-TlcMetricText -Key 'CompareConfigToolbox' -English '{0}, {1} - the desktop client state' -Argument @('app_settings.json', 'cmd_settings.json'))
            }
            [ordered]@{
                Fact    = (New-TlcMetricText -Key 'CompareFlightFact' -English 'Flight ring, tenant, licence')
                Remote  = 'platform-service-info.json'
                Toolbox = 'ecs_request_param.json, tma_request_param.json'
            }
            [ordered]@{
                Fact    = (New-TlcMetricText -Key 'CompareIdentityFact' -English 'Signed-in account identity')
                Remote  = (New-TlcMetricText -Key 'CompareIdentityRemote' -English 'One folder per account')
                Toolbox = (New-TlcMetricText -Key 'CompareIdentityToolbox' -English '{0}, plus the privacy inventory' -Argument @('TacCorrelation'))
            }
            [ordered]@{
                Fact    = (New-TlcMetricText -Key 'CompareSignallingFact' -English 'Call signalling')
                Remote  = (New-TlcMetricText -Key 'CompareSignallingRemote' -English '{0} ({1} state)' -Argument @('calling-debug.txt', 'Trouter'))
                Toolbox = (New-TlcMetricText -Key 'CompareSignallingToolbox' -English '{0} logs - a different layer of the same story' -Argument @('SlimCore'))
            }
            [ordered]@{
                Fact    = (New-TlcMetricText -Key 'CompareMediaFact' -English 'Media statistics')
                Remote  = (New-TlcMetricText -Key 'CompareMediaRemote' -English '{0} - measured 0 bytes with no call' -Argument @('web-media-*'))
                Toolbox = (New-TlcMetricText -Key 'CompareMediaToolbox' -English 'None - 0 bytes through a real call')
            }
        )

        ToolboxOnly = @(
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareNativeLogsName' -English 'Native desktop client logs'); Detail = (New-TlcMetricText -Key 'CompareNativeLogsDetail' -English '{0}. 7 files here against 0 in the remote bundle' -Argument @('MSTeams_*.log')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareMediaStackName' -English 'Media-stack logs'); Detail = (New-TlcMetricText -Key 'CompareMediaStackDetail' -English '{0}. Present locally, absent from the captured remote bundle' -Argument @('SlimCore')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareUpdateLogsName' -English 'Update and launcher logs'); Detail = (New-TlcMetricText -Key 'CompareUpdateLogsDetail' -English 'A client that failed to update explains itself here and nowhere else') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareEventLogsName' -English 'Windows event logs'); Detail = (New-TlcMetricText -Key 'CompareEventLogsDetail' -English 'Six channels. The admin center documents these as explicitly not collected') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareInventoryName' -English 'Machine inventory'); Detail = (New-TlcMetricText -Key 'CompareInventoryDetail' -English 'OS build, hardware, boot time, time zone and offset, {0}, package health, cache footprint' -Argument @('WebView2')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareJoinName' -English 'Device join state'); Detail = (New-TlcMetricText -Key 'CompareJoinDetail' -English '{0}, domain and workplace join - nothing equivalent remotely' -Argument @('Entra')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareVdiName' -English 'VDI detection'); Detail = (New-TlcMetricText -Key 'CompareVdiDetail' -English 'Platform and {0} state. The admin center is documented as unsupported on VDI' -Argument @('SlimCore')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareNetworkName' -English 'The whole network path'); Detail = (New-TlcMetricText -Key 'CompareNetworkDetail' -English 'DNS chain, TLS interception, {0} and {1} proxy, UDP and STUN reachability. The remote bundle says nothing about the network' -Argument @('WinINET', 'WinHTTP')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareUpdateHistoryName' -English 'Update history'); Detail = (New-TlcMetricText -Key 'CompareUpdateHistoryDetail' -English 'Which build, and when it changed') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareRendererName' -English 'Renderer crash records'); Detail = (New-TlcMetricText -Key 'CompareRendererDetail' -English '{0} crash counts and times' -Argument @('WebView2')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareScopingName' -English 'Repro-window scoping'); Detail = (New-TlcMetricText -Key 'CompareScopingDetail' -English 'The remote path has no time-window parameter and takes whatever is on disk when it runs') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareChronologyName' -English 'Merged chronology'); Detail = (New-TlcMetricText -Key 'CompareChronologyDetail' -English 'One time-ordered stream across every log family') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareExitReasonName' -English 'Crash and exit reason'); Detail = 'uae.json, previous_session_data.json' }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareFailuresName' -English 'What was attempted and failed'); Detail = (New-TlcMetricText -Key 'CompareFailuresDetail' -English 'Blockers and events. The remote bundle states what it gathered, never what it could not') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareConsentName' -English 'Consent record and privacy gate'); Detail = (New-TlcMetricText -Key 'CompareConsentDetail' -English 'Consent recorded with the bundle, identifiers masked unless raw is asked for, packaging refused on an unrecognised account') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareTamperName' -English 'Tamper-evident bundle'); Detail = (New-TlcMetricText -Key 'CompareTamperDetail' -English '{0} per file, verifiable after handover' -Argument @('SHA256')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareRoomsName' -English '{0} and {1} correlation' -Argument @('Teams Rooms', 'CVI')); Detail = (New-TlcMetricText -Key 'CompareRoomsDetail' -English 'A header both Microsoft and the partner can key on') }
        )

        RemoteOnly = @(
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareUnattendedName' -English 'Nobody has to be at the machine'); Detail = (New-TlcMetricText -Key 'CompareUnattendedDetail' -English 'Structural. Everything this toolbox does needs a signed-in session') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareNoScriptName' -English 'No script execution on the endpoint'); Detail = (New-TlcMetricText -Key 'CompareNoScriptDetail' -English 'On a {0} or {1} estate this toolbox cannot run at all' -Argument @('WDAC', 'AppLocker')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareWebLogsName' -English 'The web application own logs'); Detail = (New-TlcMetricText -Key 'CompareWebLogsDetail' -English '{0}, 39 MB. Absent from the toolbox bundle entirely' -Argument @('diagnostics-logs.txt')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareDataLayerName' -English 'Central data layer'); Detail = (New-TlcMetricText -Key 'CompareDataLayerDetail' -English '{0} files. 10 in the remote bundle against 0 locally' -Argument @('cdl-worker')) }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareSyncName' -English 'Around thirty sync subsystems'); Detail = (New-TlcMetricText -Key 'CompareSyncDetail' -English 'Messaging, calendar, people, presence, policies, files, call history. 31 files against 0. Where a missing chat or a stale calendar is answered') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareStorageName' -English 'Local storage usage'); Detail = 'local-storage-usage.json' }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareEveryAccountName' -English 'Every signed-in account'); Detail = (New-TlcMetricText -Key 'CompareEveryAccountDetail' -English 'By construction. A strength for coverage, and the exposure the privacy gate exists for') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareFleetName' -English 'Fleet scale and 28-day trends'); Detail = (New-TlcMetricText -Key 'CompareFleetDetail' -English 'Documented. A local bundle can never say whether the estate shares the problem') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareMacName' -English '{0}, and 30-day cloud retention' -Argument @('macOS')); Detail = (New-TlcMetricText -Key 'CompareDocumented' -English 'Documented') }
            [ordered]@{ Capability = (New-TlcMetricText -Key 'CompareShellName' -English 'Desktop shell and {0} logs' -Argument @('SlimCore')); Detail = (New-TlcMetricText -Key 'CompareShellDetail' -English 'DOCUMENTED BUT NOT OBSERVED in the captured artifact. Unverified') }
        )
    }
}
function Get-TlcSignInMetric {
    <#
    .SYNOPSIS
        Whether the privacy gate will let this bundle be packaged.
    .DESCRIPTION
        The gate blocks packaging when an account appears in the evidence that is not in
        Privacy.KnownAccountIds, and BlockOnUnknownAccount defaults to true. Today an
        operator discovers that after collecting - the run completes, the bundle is
        written, and Package then refuses. On a customer call that is the worst possible
        moment to learn it.

        The accounts are readable before the run from the same file the gate uses after
        it: app_settings.json -> active_users, one object id per signed-in account. Phase 0
        finding 11 established that this is the reliable multi-account signal, and that
        Teams' rolling logs carry no UPNs or tenant ids at all.

        Green means the account check will pass, and deliberately not that packaging will
        succeed. The gate also requires consent and refuses bearer tokens found in the
        evidence, neither of which can be known before the evidence exists. Claiming more
        than that would be the confident-wrong-answer failure this dashboard is meant to
        avoid.

        Ids are counted and masked, never shown. This runs on every launch, and a tile
        that displayed a raw object id would put one on screen behind whatever the
        operator is sharing.
    #>
    [CmdletBinding()]
    param(
        [string] $StateRoot,
        [hashtable] $Privacy
    )

    try {
        if (-not $StateRoot) {
            $parts = @(New-TlcMetricText -Key 'DetailSignInNoState' -English 'No client state folder is configured.')
            return [ordered]@{ Status = 'Neutral'; Value = 'Unavailable'; Detail = Join-TlcMetricText $parts; DetailParts = $parts }
        }

        $resolved = $StateRoot
        $resolver = Get-Command -Name 'Resolve-TlcPath' -ErrorAction SilentlyContinue
        if ($resolver) { $resolved = & $resolver -Path $StateRoot }

        $settings = Join-Path $resolved 'app_settings.json'
        if (-not (Test-Path -LiteralPath $settings)) {
            $parts = @(New-TlcMetricText -Key 'DetailSignInNoSettings' -English 'app_settings.json was not found under {0}, so the signed-in accounts could not be read.' -Argument @($resolved))
            return [ordered]@{
                Status = 'Neutral'; Value = 'Unavailable'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }

        $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        $accounts = @()
        if ($json.PSObject.Properties.Name -contains 'active_users') {
            $accounts = @($json.active_users | ForEach-Object { [string]$_.id } | Where-Object { $_ })
        }

        if ($accounts.Count -eq 0) {
            $parts = @(New-TlcMetricText -Key 'DetailSignInNone' -English 'No signed-in account is recorded in app_settings.json. That is unusual on a working client and may mean the file has not been written yet.')
            return [ordered]@{
                Status = 'Neutral'; Value = 'None found'
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
            }
        }

        $known = @()
        $blockOnUnknown = $true
        if ($Privacy) {
            if ($Privacy.ContainsKey('KnownAccountIds')) { $known = @($Privacy.KnownAccountIds) }
            if ($Privacy.ContainsKey('BlockOnUnknownAccount')) { $blockOnUnknown = [bool]$Privacy.BlockOnUnknownAccount }
        }

        # Resolve the object ids to people. active_users holds one entry per signed-in
        # tenant identity, so a user who is a guest somewhere else appears twice with two
        # different ids and nothing in that file connects them. Counting entries reported
        # "2 accounts" for one person and would have blocked packaging over it.
        $broker = Get-TlcBrokerAccount
        $resolved = @($accounts | ForEach-Object {
            $entry = [ordered]@{ Id = $_; Upn = ''; TenantId = ''; DisplayName = '' }
            if ($broker.ContainsKey($_)) {
                $entry.Upn = $broker[$_].Upn
                $entry.TenantId = $broker[$_].TenantId
                $entry.DisplayName = $broker[$_].DisplayName
            }
            [pscustomobject]$entry
        })

        # Distinct people, by UPN. An id the broker cannot resolve counts as its own
        # person rather than being folded in - an unresolvable id is exactly the case
        # where assuming it belongs to the current user would be dangerous.
        $people = @($resolved | ForEach-Object { if ($_.Upn) { $_.Upn.ToLowerInvariant() } else { "id:$($_.Id)" } } |
                    Select-Object -Unique)
        $tenants = @($resolved | Where-Object { $_.TenantId } | ForEach-Object { $_.TenantId } | Select-Object -Unique)

        $unknown = @($accounts | Where-Object { $_ -notin $known })

        # A per-identity breakdown, because "2 tenants" on its own is a number an operator
        # cannot act on or verify. Reported 2026-09-21: the window said one person across
        # two tenants and showed nothing whatever about either, which reads as an alert
        # about a machine the operator can see is working.
        #
        # THE TENANT IS NAMED BY THE UPN DOMAIN, not by its guid. The domain is what an
        # engineer recognises - "microsoft.com", "contoso.onmicrosoft.com" - and it says
        # which directory the identity belongs to without putting the account name on
        # screen. The tenant guid stays masked beside it so two tenants sharing a domain
        # are still distinguishable.
        $masker = Get-Command -Name 'Protect-TlcIdentifier' -ErrorAction SilentlyContinue
        $maskOne = {
            param([string] $Value)
            if (-not $Value) { return '' }
            if ($masker) { return [string](& $masker -Value $Value) }
            # Not the literal '***'. A fallback that renders every id identically makes the
            # remediation - declare THESE ids - impossible to follow, which is exactly the
            # defect this replaced.
            if ($Value.Length -le 12) { return $Value }
            return $Value.Substring(0, 8) + '...' + $Value.Substring($Value.Length - 4)
        }

        $identities = @($resolved | ForEach-Object {
            $domain = if ($_.Upn -match '@(.+)$') { $Matches[1] } else { '' }
            [ordered]@{
                Id       = & $maskOne $_.Id
                Tenant   = if ($domain) { $domain } else { 'unresolved' }
                Resolved = [bool]$domain
                TenantId = & $maskOne $_.TenantId
                Declared = ($_.Id -in $known)
            }
        })

        # The value describes people, not entries, because that is the question an
        # operator is actually asking when they glance at it.
        $value = if ($people.Count -eq 1) { '1 person' } else { "$($people.Count) people" }
        if ($tenants.Count -gt 1) { $value += ", $($tenants.Count) tenants" }

        $shape = if ($tenants.Count -gt 1) {
            New-TlcMetricText -Key 'DetailSignInShapeTenants' -English '{0} signed-in identity(ies) resolving to {1} distinct person(s) across {2} tenants. One person signed in to more than one tenant produces one entry per tenant, which is normal.' -Argument @($accounts.Count, $people.Count, $tenants.Count)
        } else {
            New-TlcMetricText -Key 'DetailSignInShape' -English '{0} signed-in identity(ies) resolving to {1} distinct person(s).' -Argument @($accounts.Count, $people.Count)
        }

        if ($unknown.Count -eq 0) {
            $parts = @(
                $shape
                New-TlcMetricText -Key 'DetailSignInAllDeclared' -English 'All ids are listed in Privacy.KnownAccountIds, so the account check will not block packaging. Consent and token checks still apply and cannot be judged before the evidence exists.'
            )
            return [ordered]@{
                Status = 'Pass'
                Value  = $value
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
                Identities = $identities
                People = $people.Count
                Tenants = $tenants.Count
                UndeclaredCount = 0
            }
        }

        $masked = @($unknown | ForEach-Object { & $maskOne $_ })

        # LEAD WITH THE ACTION, and say plainly that this is configuration rather than
        # fault. The previous wording opened with "N identities resolving to N people...
        # which is normal" and then turned the tile red, so it simultaneously told the
        # operator the situation was normal and that something was wrong. Both were true
        # of different things - the machine is fine, the toolbox has not been told whose
        # machine it is - and saying so in that order is what makes it actionable.
        $parts = @(
            New-TlcMetricText -Key 'DetailSignInNothingWrong' -English 'Nothing is wrong with Teams or with this machine. The toolbox has simply not been told which accounts are expected here, and the privacy gate refuses to package evidence for an account it does not recognise.'
            New-TlcMetricText -Key 'DetailSignInUndeclared' -English '{0} of {1} id(s) need declaring in Privacy.KnownAccountIds: {2}.' -Argument @($unknown.Count, $accounts.Count, ($masked -join ', '))
            $shape
            if ($people.Count -eq 1 -and $tenants.Count -gt 1) {
                New-TlcMetricText -Key 'DetailSignInOnePerson' -English 'All of them resolve to the same person, so this is one user signed in to {0} tenants rather than a shared machine.' -Argument @($tenants.Count)
            } elseif ($people.Count -gt 1) {
                New-TlcMetricText -Key 'DetailSignInManyPeople' -English 'These resolve to {0} different people, so check who else is signed in before collecting - a bundle would carry evidence for all of them.' -Argument @($people.Count)
            }
            New-TlcMetricText -Key 'DetailSignInAllIdentities' -English 'New Teams writes diagnostics for every signed-in identity regardless of tenant, so the evidence will span all of them.'
        )

        if ($blockOnUnknown) {
            $parts += New-TlcMetricText -Key 'DetailSignInWillRefuse' -English 'Packaging will refuse this bundle until they are declared.'
            return [ordered]@{
                Status = 'Blocked'
                # Name the blocking condition rather than the healthy fact behind it. The
                # tile read "1 person, 2 tenants" in red, which describes a normal machine
                # and gives no hint that the fix is a config entry.
                Value  = if ($unknown.Count -eq 1) { '1 id to declare' } else { "$($unknown.Count) ids to declare" }
                Detail = Join-TlcMetricText $parts; DetailParts = $parts
                Identities = $identities
                People = $people.Count
                Tenants = $tenants.Count
                UndeclaredCount = $unknown.Count
            }
        }

        $parts += New-TlcMetricText -Key 'DetailSignInReportedOnly' -English 'BlockOnUnknownAccount is false, so this is reported rather than blocked.'
        return [ordered]@{
            Status = 'Warning'
            Value  = $value
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
            Identities = $identities
            People = $people.Count
            Tenants = $tenants.Count
            UndeclaredCount = $unknown.Count
        }
    } catch {
        $parts = @(New-TlcMetricText -Key 'DetailSignInUnreadable' -English 'The signed-in accounts could not be read: {0}' -Argument @($_.Exception.Message))
        return [ordered]@{
            Status = 'Neutral'; Value = 'Unavailable'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }
}

Export-ModuleMember -Function Get-TlcCapabilityComparison, Get-TlcAdminCenterProcedure, Get-TlcMetricStatus, New-TlcMetricText, New-TlcMetricList, Join-TlcMetricText, Get-TlcNetworkPathPart, Get-TlcLogInventory, Get-TlcClientMetric,
    Get-TlcLogVolumeMetric, Get-TlcRetentionMetric, Get-TlcActivityMetric,
    Get-TlcCoverageMetric, Get-TlcCrashMetric, Get-TlcNetworkPathMetric, Get-TlcUpdateMetric,
    Get-TlcSignInMetric, Get-TlcBrokerAccount, Get-TlcToolChoice,
    Get-TlcPlatform, Get-TlcPlatformSignal, Get-TlcPlatformAdvisoryText

