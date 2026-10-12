<#
.SYNOPSIS
    Collects Microsoft Teams diagnostic logs into a single file you can send to support.

.DESCRIPTION
    Self-contained on purpose. This file has no dependency on the rest of the
    TLC-Toolbox, because the person running it is a customer with one file and a
    support case, not an engineer with a repository checkout.

    It needs no administrator rights and changes nothing on the machine - it reads
    logs Teams has already written and copies them into one ZIP.

    Compatible with Windows PowerShell 5.1, which is what ships with Windows.
    Customers will not have PowerShell 7.

.PARAMETER CaseNumber
    Your Microsoft support case number. Prompted for if not supplied.

.PARAMETER WhenHappened
    When the problem happened. Accepts a time like '14:30', a full date and time,
    or 'now'. Prompted for if not supplied.

.PARAMETER WindowMinutes
    How many minutes either side of that time to collect. Default 30.

.PARAMETER OutputFolder
    Where to write the ZIP. Defaults to your Desktop.

.PARAMETER Unattended
    Skips all prompts. Used for testing and for scripted collection.

.EXAMPLE
    .\Invoke-TlcQuickCollect.ps1

.EXAMPLE
    .\Invoke-TlcQuickCollect.ps1 -CaseNumber 1234567890123456 -WhenHappened '09:15'
#>
[CmdletBinding()]
param(
    [string] $CaseNumber,
    [string] $WhenHappened,
    [int] $WindowMinutes = 30,
    [string] $OutputFolder,
    [switch] $Unattended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ConstrainedLanguage check before anything else - see TLC-Toolbox.ps1 and finding 152. A
# WDAC or AppLocker managed machine cannot run this toolbox, and without this it fails while
# naming a healthy config file as the cause. Property reads and string comparison only, so the
# check survives the mode it reports on.
$languageMode = 'unknown'
try { $languageMode = "$($ExecutionContext.SessionState.LanguageMode)" } catch { Write-Verbose 'Language mode unavailable; continuing.' }
if ($languageMode -ne 'FullLanguage' -and $languageMode -ne 'unknown') {
    Write-Warning "TLC-Toolbox cannot run in $languageMode mode. This machine restricts PowerShell, usually through WDAC or AppLocker. Nothing has been collected and nothing has been changed."
    Write-Warning 'Options: run from a machine or account not covered by that policy, use the Teams admin center remote log collection instead, or ask the customer to permit this script under their policy.'
    throw "PowerShell is in $languageMode; TLC-Toolbox requires FullLanguage."
}

$script:TeamsLogRoot = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
$script:TeamsStateRoot = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'
$script:LogPatterns = @('MSTeams_*.log', 'MSTeamsNM_SlimCore_*.log', 'MSTeamsBackgroundEcs_*.log')
$script:StateFiles = @('app_settings.json', 'previous_session_data.json', 'crash_reports_cache.json')
$script:MaxBundleBytes = 512MB
$script:ToolLog = $null

function Write-Step {
    param([string] $Message, [string] $Colour = 'Gray')
    Write-Information "  $Message" -InformationAction Continue
    Write-CollectorLog -Message $Message
}

function Get-EnvironmentFact {
    <#
        The facts worth having when this is run on someone else's machine and
        something goes wrong. Culture is included deliberately: the time entered
        below is parsed using the current culture, so a machine on a non-en-US
        locale can read the same input differently.
    #>
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { Write-Verbose 'CIM unavailable.' }
    $teams = $null
    try { $teams = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSTeams' } | Select-Object -First 1 } catch { Write-Verbose 'Get-AppxPackage unavailable.' }

    # "It will not run on my machine" is the most likely thing to go wrong with a script
    # a customer has been emailed, so the setting that causes it is recorded. Get-
    # ExecutionPolicy lives in Microsoft.PowerShell.Security and that module can fail to
    # load, so the environment variable - which powershell.exe sets from -ExecutionPolicy
    # and which needs no module - is the fallback.
    $policy = ''
    try { $policy = (Get-ExecutionPolicy).ToString() } catch { Write-Verbose 'Get-ExecutionPolicy is unavailable.' }
    if (-not $policy) { $policy = $env:PSExecutionPolicyPreference }
    if (-not $policy) { $policy = 'unavailable' }

    # Constrained language mode is a normal setting in a locked-down enterprise and it
    # removes most of what this script does. Without it recorded, a failure there looks
    # like an ordinary bug.
    $languageMode = 'unknown'
    try { $languageMode = $ExecutionContext.SessionState.LanguageMode.ToString() } catch { Write-Verbose 'Language mode unavailable.' }

    return [ordered]@{
        CapturedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName    = $env:COMPUTERNAME
        User            = "$env:USERDOMAIN\$env:USERNAME"
        PsVersion       = $PSVersionTable.PSVersion.ToString()
        PsEdition       = if ($PSVersionTable.Contains('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' }
        ExecutionPolicy = $policy
        LanguageMode    = $languageMode
        Culture         = (Get-Culture).Name
        UiCulture       = (Get-UICulture).Name
        TimeZoneId      = [System.TimeZoneInfo]::Local.Id
        UtcOffsetHours  = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours
        OsCaption       = if ($os) { $os.Caption } else { $null }
        OsBuild         = if ($os) { $os.BuildNumber } else { $null }
        TeamsVersion    = if ($teams) { $teams.Version } else { $null }
        TeamsLogRoot    = $script:TeamsLogRoot
        TeamsLogRootExists = (Test-Path -LiteralPath $script:TeamsLogRoot)
    }
}

function Start-CollectorLog {
    param([string] $Path)
    $script:ToolLog = $Path
    $facts = Get-EnvironmentFact
    $header = @('===== Teams log collection - tool log =====')
    foreach ($key in $facts.Keys) { $header += ('{0,-20}{1}' -f $key, $facts[$key]) }
    $header += '==========================================='
    $header += ''
    Set-Content -LiteralPath $Path -Value $header -Encoding UTF8
}

function Write-CollectorLog {
    <#
        Never throws. A missing log line is a nuisance; a collection that dies
        because logging failed is a defect.
    #>
    param(
        [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO',
        $ErrorRecord
    )

    if (-not $script:ToolLog) { return }
    try {
        $lines = @("$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)) [$Level] $Message")
        if ($ErrorRecord) {
            $lines += "            Exception : $($ErrorRecord.Exception.GetType().FullName)"
            $lines += "            Message   : $($ErrorRecord.Exception.Message)"
            if ($ErrorRecord.InvocationInfo) {
                $lines += "            At        : line $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
                $lines += "            Line      : $($ErrorRecord.InvocationInfo.Line.Trim())"
            }
            if ($ErrorRecord.ScriptStackTrace) {
                foreach ($frame in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) { $lines += "            Stack     : $frame" }
            }
        }
        Add-Content -LiteralPath $script:ToolLog -Value $lines -Encoding UTF8
    } catch {
        Write-Verbose 'Could not append to the tool log.'
    }
}

function Open-SharedRead {
    <#
        Teams keeps its current log open, and that is usually the log holding the
        evidence. A default open fails against it, so read/write sharing is
        requested explicitly.
    #>
    param([string] $Path)
    return New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
}

function Copy-OpenFile {
    param([string] $Path, [string] $Destination)
    $source = Open-SharedRead -Path $Path
    try {
        $target = [System.IO.File]::Create($Destination)
        try { $source.CopyTo($target) } finally { $target.Dispose() }
    } finally { $source.Dispose() }
}

function Get-Sha256 {
    <#
        Hashes a file without Get-FileHash.

        Get-FileHash is a function exported by Microsoft.PowerShell.Utility, not an engine
        cmdlet, so it has to be resolved through module autoloading - and that resolution can
        fail. Observed on a real run: launching this script from a context whose PSModulePath
        carries PowerShell 7 entries makes Windows PowerShell 5.1 resolve Utility against the
        wrong copy, and Get-FileHash simply is not there. The collection had already succeeded;
        it fell over at the manifest step.

        That is the same trap as Import-PowerShellDataFile and Get-ExecutionPolicy before it. A
        script that runs on someone else's machine should not assume a module-provided command is
        present. SHA256 from the framework needs nothing loaded.

        Shared read, so a file another process is holding open still hashes - the same reason
        Open-SharedRead exists.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = Open-SharedRead -Path $Path
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function New-ZipArchive {
    <#
        Compress-Archive opens each file without sharing, so one file held open by
        antivirus, a backup agent or OneDrive fails the whole archive. That is
        unacceptable in the failure path below, where the bundle being written is the
        only record of why the collection went wrong - an archiver that throws there
        leaves the user with nothing to send and nothing to explain why.

        This reuses Open-SharedRead, so the collector treats a locked file the same way
        whether it is copying it or packaging it. It is also faster (2.0 s against 7.3 s
        on a 100 MB payload) and writes forward-slash entry names on every host, where
        Compress-Archive writes backslashes on Windows PowerShell 5.1 and forward
        slashes on 7 - a difference that matters here because the customer runs 5.1 and
        the engineer verifies on 7.
    #>
    param([string] $SourcePath, [string] $DestinationPath)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $source = (Resolve-Path -LiteralPath $SourcePath).ProviderPath.TrimEnd('\')
    $archive = [System.IO.Compression.ZipFile]::Open($DestinationPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($source, '*', [System.IO.SearchOption]::AllDirectories)) {
            $relative = $file.Substring($source.Length).TrimStart('\') -replace '\\', '/'
            $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)

            # The zip format cannot store a date before 1980 and the setter throws
            # rather than clamping.
            $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($file)
            if ($lastWrite.Year -lt 1980) { $lastWrite = [datetime]::new(1980, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc) }
            $entry.LastWriteTime = [System.DateTimeOffset]::new($lastWrite, [System.TimeSpan]::Zero)

            $reader = Open-SharedRead -Path $file
            try {
                $writer = $entry.Open()
                try { $reader.CopyTo($writer, 1048576) } finally { $writer.Dispose() }
            } finally { $reader.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Get-LogFileStart {
    param([System.IO.FileInfo] $File)
    if ($File.Name -match '_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})') {
        try {
            return New-Object datetime ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]),
                                       ([int]$Matches[4]), ([int]$Matches[5]), ([int]$Matches[6])
        } catch {
            Write-Verbose "Falling back to CreationTime for $($File.Name)."
        }
    }
    return $File.CreationTime
}

function Resolve-WhenHappened {
    <#
        Accepts what a person would actually type. An unparseable answer falls back
        to now rather than failing, because a bundle from roughly the right time is
        far more useful than no bundle at all.

        Two things here are not decoration.

        A bare time is resolved against today. Somebody reporting at 00:30 that Teams
        broke at 22:15 means last night, but plain parsing gives tonight's 22:15 -
        twenty-two hours in the future - and the collector then produces a perfectly
        healthy-looking bundle covering no logs at all. Nothing downstream catches it,
        because an empty window is not an error. A report is always about something
        that has already happened, so a time in the future means the previous day.

        Relative phrases are accepted because the prompt asks "when did it happen" and
        "20 minutes ago" is a normal answer to that question. It used to fall through
        to the warning and silently collect the wrong window.
    #>
    param([string] $Value)

    $now = Get-Date
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^\s*now\s*$') { return $now }

    if ($Value -match '^\s*(?:(\d+)|an?)\s*(minute|min|hour|hr|day)s?\s*ago\s*$') {
        $count = if ($Matches.ContainsKey(1)) { [int]$Matches[1] } else { 1 }
        $unit = $Matches[2]
        if ($unit -eq 'minute' -or $unit -eq 'min') { return $now.AddMinutes(-$count) }
        if ($unit -eq 'hour' -or $unit -eq 'hr') { return $now.AddHours(-$count) }
        return $now.AddDays(-$count)
    }

    $text = $Value
    $shiftDays = 0
    if ($text -match '^\s*yesterday\b\s*(.*)$') {
        $shiftDays = -1
        $text = $Matches[1]
        if ([string]::IsNullOrWhiteSpace($text)) { return $now.AddDays(-1) }
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [ref]$parsed)) {
        $parsed = $parsed.AddDays($shiftDays)
        if ($parsed -gt $now) { $parsed = $parsed.AddDays(-1) }
        return $parsed
    }

    Write-Warning "Could not understand '$Value'. Using the current time instead."
    return $now
}

# ---------------------------------------------------------------------------

Write-Information '' -InformationAction Continue
Write-Information '  Microsoft Teams log collection' -InformationAction Continue
Write-Information '  ------------------------------' -InformationAction Continue
Write-Information '  This copies logs Teams has already written into one ZIP file.' -InformationAction Continue
Write-Information '  It does not change anything on your computer and does not need admin rights.' -InformationAction Continue
Write-Information '' -InformationAction Continue

if (-not (Test-Path -LiteralPath $script:TeamsLogRoot)) {
    Write-Information '  Could not find Teams logs on this computer.' -InformationAction Continue
    Write-Information "  Looked in: $script:TeamsLogRoot" -InformationAction Continue
    Write-Information '  Please make sure you are signed in to the new Teams app as the affected user.' -InformationAction Continue
    # Nothing collected is a failure to anything that runs this unattended, so the exit code
    # says so - when this is the top-level script. A calling script keeps its return value,
    # the same rule as TLC-Toolbox.ps1 (finding 290; review 2026-09-30).
    if (-not $MyInvocation.ScriptName) { exit 1 }
    return
}

if (-not $Unattended) {
    if (-not $CaseNumber) { $CaseNumber = Read-Host '  Support case number (press Enter to skip)' }
    if (-not $WhenHappened) { $WhenHappened = Read-Host "  When did it happen? (e.g. 14:30, or press Enter for now)" }
}

$impact = Resolve-WhenHappened -Value $WhenHappened
$windowStart = $impact.AddMinutes(-[Math]::Abs($WindowMinutes))
$windowEnd = $impact.AddMinutes([Math]::Abs($WindowMinutes))
$correlationId = [guid]::NewGuid().ToString()

if (-not $OutputFolder) {
    $OutputFolder = [Environment]::GetFolderPath('Desktop')
    if (-not $OutputFolder) { $OutputFolder = $env:USERPROFILE }
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) "TlcQuick-$correlationId"
$logDestination = Join-Path $staging 'ClientLogs'
$stateDestination = Join-Path $staging 'ClientState'
$null = New-Item -ItemType Directory -Path $logDestination -Force
$null = New-Item -ItemType Directory -Path $stateDestination -Force

# Opened before any collection, so a failure at any point still leaves a log with
# the environment in it for whoever has to debug this remotely.
Start-CollectorLog -Path (Join-Path $staging 'ToolLog.txt')
Write-CollectorLog -Message "Collection started. Case='$CaseNumber' Impact='$($impact.ToString('o'))' Window=$WindowMinutes min"

Write-Information '' -InformationAction Continue
Write-Information "  Collecting for: $($windowStart.ToString('yyyy-MM-dd HH:mm')) to $($windowEnd.ToString('HH:mm'))" -InformationAction Continue
Write-Information '' -InformationAction Continue

try {

# --- Teams client logs -----------------------------------------------------

Write-Step 'Copying Teams logs...'
$candidates = @()
foreach ($pattern in $script:LogPatterns) {
    $candidates += @(Get-ChildItem -LiteralPath $script:TeamsLogRoot -Filter $pattern -File -ErrorAction SilentlyContinue)
}

$selected = @()
foreach ($file in $candidates) {
    $start = Get-LogFileStart -File $file
    # Re-read from the file itself: the directory entry's LastWriteTime lags for a file a
    # writer holds open, which Teams always does for the log it is writing, so the log with
    # the evidence could be dropped from a recent window. A file still held open covers the
    # present. The main collector learned both in finding 299 (review 2026-09-30).
    $file.Refresh()
    $end = $file.LastWriteTime
    $held = $false
    try {
        $probe = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $probe.Dispose()
    } catch [System.IO.IOException] {
        $held = $true
    } catch {
        Write-Verbose "Could not test whether $($file.Name) is held open: $($_.Exception.Message)"
    }
    if ($held) { $end = Get-Date }
    # Overlap, not containment: a rolling log that began before the window and was
    # still being written during it is exactly the file that holds the evidence.
    if ($start -le $windowEnd -and $end -ge $windowStart) {
        $selected += $file
    }
}

$copied = 0
$used = [int64]0
$failed = @()
foreach ($file in ($selected | Sort-Object LastWriteTime)) {
    if (($used + $file.Length) -gt $script:MaxBundleBytes) { continue }
    try {
        Copy-OpenFile -Path $file.FullName -Destination (Join-Path $logDestination $file.Name)
        $used += $file.Length
        $copied++
    } catch {
        $failed += $file.Name
    }
}
if ($copied -gt 0) {
    Write-Step "$copied log file(s) copied." 'Green'
} else {
    # An empty window is not an error anywhere downstream, so without saying it here a
    # bundle containing no evidence looks exactly like a successful collection - to the
    # user sending it and to the engineer opening it.
    Write-Step 'No Teams logs cover that time - please check the time you entered.' 'Yellow'
    Write-CollectorLog -Level 'WARN' -Message ("No log file overlapped the window {0} to {1} (local). {2} candidate file(s) were considered." -f `
        $windowStart.ToString('yyyy-MM-dd HH:mm'), $windowEnd.ToString('yyyy-MM-dd HH:mm'), @($candidates).Count)
}

# --- Client state ----------------------------------------------------------

Write-Step 'Copying Teams settings...'
$stateCopied = 0
foreach ($name in $script:StateFiles) {
    $source = Join-Path $script:TeamsStateRoot $name
    if (Test-Path -LiteralPath $source) {
        try {
            Copy-Item -LiteralPath $source -Destination $stateDestination -Force
            $stateCopied++
        } catch {
            Write-Verbose "Could not copy $name."
        }
    }
}
Write-Step "$stateCopied settings file(s) copied." 'Green'

# --- System and app information -------------------------------------------

Write-Step 'Recording system information...'
$teams = $null
try {
    $teams = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSTeams' } | Select-Object -First 1
} catch {
    Write-Verbose 'Get-AppxPackage unavailable.'
}
$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue } catch { Write-Verbose 'CIM unavailable.' }

$info = New-Object psobject -Property ([ordered]@{
    CorrelationId  = $correlationId
    CaseNumber     = $CaseNumber
    CollectedBy    = "$env:USERDOMAIN\$env:USERNAME"
    ComputerName   = $env:COMPUTERNAME
    CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    ImpactLocal    = $impact.ToString('o')
    ImpactUtc      = $impact.ToUniversalTime().ToString('o')
    WindowStartUtc = $windowStart.ToUniversalTime().ToString('o')
    WindowEndUtc   = $windowEnd.ToUniversalTime().ToString('o')
    TimeZoneId     = [System.TimeZoneInfo]::Local.Id
    UtcOffsetHours = [System.TimeZoneInfo]::Local.GetUtcOffset($impact).TotalHours
    TeamsVersion   = if ($teams) { $teams.Version } else { $null }
    OsCaption      = if ($os) { $os.Caption } else { $null }
    OsBuild        = if ($os) { $os.BuildNumber } else { $null }
    LogFilesCopied = $copied
    LogFilesFailed = $failed
    StateFilesCopied = $stateCopied
})
$info | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $staging 'CollectionInfo.json') -Encoding UTF8

# --- Windows event log -----------------------------------------------------

Write-Step 'Checking Windows event log for crashes...'
$events = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Application'
        Id        = @(1000, 1001)
        StartTime = $windowStart
        EndTime   = $windowEnd
    } -ErrorAction Stop | ForEach-Object {
        New-Object psobject -Property ([ordered]@{
            Id             = $_.Id
            ProviderName   = $_.ProviderName
            TimeCreatedUtc = $_.TimeCreated.ToUniversalTime().ToString('o')
            Message        = $_.Message
        })
    })
} catch {
    # "No events were found" is the normal, healthy case and must not look like a
    # failure to the person running this.
    Write-Verbose 'No matching application events in the window.'
}
# An empty array piped into ConvertTo-Json emits nothing, so Set-Content receives
# no input and the file is silently never created - while READ-ME-FIRST.txt still
# promises it. A missing file in a customer deliverable reads as a broken tool, so
# the empty case is written explicitly.
$eventsJson = if (@($events).Count -gt 0) { @($events) | ConvertTo-Json -Depth 5 } else { '[]' }
Set-Content -LiteralPath (Join-Path $staging 'EventLog.json') -Value $eventsJson -Encoding UTF8
Write-Step "$(@($events).Count) crash event(s) found in the time window." 'Green'

# --- Optional support files ------------------------------------------------

$supportCopied = 0
$supportSkipped = @()
if (-not $Unattended) {
    Write-Information '' -InformationAction Continue
    Write-Information '  OPTIONAL - extra Teams logs' -InformationAction Continue
    Write-Information '  Teams can produce additional logs, but only you can trigger it:' -InformationAction Continue
    Write-Information '    1. Switch to Teams and press Ctrl + Alt + Shift + 1' -InformationAction Continue
    Write-Information '    2. Wait for the "Downloading web logs" message to disappear' -InformationAction Continue
    Write-Information '' -InformationAction Continue
    Write-Information '  Windows may ask for camera or microphone permission while Teams does this.' -InformationAction Continue
    Write-Information '  That is Teams collecting audio and video diagnostics. You can allow or deny;' -InformationAction Continue
    Write-Information '  denying only means the media logs are less complete.' -InformationAction Continue
    Write-Information '' -InformationAction Continue
    $answer = Read-Host '  Press Enter when done, or type S to skip'

    if ($answer -notmatch '^\s*[sS]') {
        # The real Downloads folder, not the default location. Known Folder Move
        # redirects it - commonly into OneDrive - in exactly the kind of managed
        # enterprise this tool is aimed at, and Teams writes its web logs to wherever
        # the shell says Downloads is. Assuming %USERPROFILE%\Downloads would have
        # looked in an empty folder and reported finding nothing, with the user having
        # correctly done what was asked.
        $downloads = Join-Path $env:USERPROFILE 'Downloads'
        try {
            $shellFolders = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
            $downloadsGuid = '{374DE290-123F-4565-9164-39C4925E467B}'
            $configured = (Get-ItemProperty -Path $shellFolders -Name $downloadsGuid -ErrorAction Stop).$downloadsGuid
            if ($configured) {
                $expanded = [Environment]::ExpandEnvironmentVariables($configured)
                if (Test-Path -LiteralPath $expanded) { $downloads = $expanded }
            }
        } catch {
            Write-Verbose 'Downloads folder not redirected, or the shell folder key is unreadable.'
        }
        Write-CollectorLog -Message "Looking for support logs in $downloads"

        $supportDestination = Join-Path $staging 'SupportFiles'
        $null = New-Item -ItemType Directory -Path $supportDestination -Force
        $cutoff = (Get-Date).AddMinutes(-20)

        foreach ($pattern in @('*Weblogs*', 'MSTeams Support Logs*', 'MSTeams Diagnostics Log*')) {
            $items = @(Get-ChildItem -LiteralPath $downloads -Filter $pattern -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -ge $cutoff })
            foreach ($item in $items) {
                # Measured before copying, because Ctrl+Alt+Shift+1 does not produce a
                # file. On a real machine it produced a FOLDER of 570 files totalling
                # 486 MB - media stack ETW traces, SkypeRT, a model cache - against a
                # bundle budget of 512 MB. Copied blind, one keystroke's output would
                # have consumed the entire budget and produced a bundle too large to
                # attach to a support case, after the user had done exactly as asked.
                $itemBytes = if ($item.PSIsContainer) {
                    $measured = Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum
                    [int64]$measured.Sum
                } else {
                    [int64]$item.Length
                }

                if (($used + $itemBytes) -gt $script:MaxBundleBytes) {
                    $supportSkipped += $item.Name
                    Write-CollectorLog -Level 'WARN' -Message ("Support item '{0}' skipped: {1:N0} MB would exceed the {2:N0} MB bundle budget." -f `
                        $item.Name, ($itemBytes / 1MB), ($script:MaxBundleBytes / 1MB))
                    continue
                }

                try {
                    Copy-Item -LiteralPath $item.FullName -Destination $supportDestination -Recurse -Force
                    $used += $itemBytes
                    $supportCopied++
                } catch {
                    Write-Verbose "Could not copy $($item.Name)."
                }
            }
        }

        if ($supportSkipped.Count -gt 0) {
            # Named rather than silently dropped: the user pressed the keystroke and is
            # entitled to know their output did not travel, and why.
            Write-Step "$($supportSkipped.Count) extra log item(s) were too large for one bundle and were left out." 'Yellow'
            Write-Information '  Teams diagnostic logs can run to hundreds of megabytes. Tell the engineer' -InformationAction Continue
            Write-Information '  if they need them - they can be sent separately.' -InformationAction Continue
        }

        if ($supportCopied -gt 0) {
            Write-Step "$supportCopied extra log item(s) collected." 'Green'
        } elseif ($supportSkipped.Count -eq 0) {
            # The user pressed Enter having been told to do something, so reporting a
            # cheerful zero would be telling them their action worked when it did not.
            Write-Step 'No extra Teams logs were found - continuing without them.' 'Yellow'
            Write-Information "  (looked in $downloads for files from the last 20 minutes)" -InformationAction Continue
            Write-CollectorLog -Level 'WARN' -Message "No support logs matched in $downloads within the last 20 minutes."
        }
    }
}

# --- Package ---------------------------------------------------------------

Write-Information '' -InformationAction Continue
Write-Step 'Creating the file to send...'

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
$namePart = if ($CaseNumber) { ($CaseNumber -replace '[^0-9A-Za-z\-]', '') } else { 'NoCase' }
$bundleName = "TeamsLogs-$namePart-$stamp.zip"
$bundlePath = Join-Path $OutputFolder $bundleName

$readme = @"
Microsoft Teams log collection
==============================

Case number : $CaseNumber
Collected   : $((Get-Date).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) ($([System.TimeZoneInfo]::Local.Id))
Reference   : $correlationId

Problem time window
  Local : $($windowStart.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) to $($windowEnd.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
  UTC   : $($windowStart.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) to $($windowEnd.ToUniversalTime().ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))

What is in this file
  ClientLogs\    Teams application logs covering the time window
  ClientState\   Teams settings and session information
  EventLog.json  Windows application crash events in the time window
  CollectionInfo.json  Computer, Teams version and time zone details
  Manifest.json  A checksum for every collected file, so nothing can be
                 changed, removed or added to this bundle unnoticed
  ToolLog.txt    A record of what this tool did, for troubleshooting the tool
$(if ($supportCopied -gt 0) { "  SupportFiles\  Additional logs produced by Teams`n" })
$(if ($copied -eq 0) { @"
WARNING - no Teams logs matched this time window
  Nothing in this bundle covers $($windowStart.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) to $($windowEnd.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)).
  The time entered was probably not the time of the problem. Please run the
  collection again with the correct time, before the logs roll over.

"@ })
Note for the support engineer
  Timestamps inside the Teams log files are UTC values, even though each line
  ends with a local time offset. Compare them against the UTC window above.

Nothing was changed on this computer. These are copies of logs Teams had
already written.
"@
Set-Content -LiteralPath (Join-Path $staging 'READ-ME-FIRST.txt') -Value $readme -Encoding UTF8

$manifest = foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
    # ToolLog.txt is excluded: it keeps being written after this point, so hashing
    # it here would guarantee a mismatch later. It is the tool's own log rather
    # than collected evidence, so it ships in the ZIP but not in the manifest.
    #
    # READ-ME-FIRST.txt is written just above this, deliberately. It used to be
    # written afterwards and so was never hashed - which meant the one file stating
    # the collection window could be rewritten and the bundle still verified clean.
    # Proven: replacing the window with a false one left Valid=True. It is evidence
    # about the evidence, so it is covered like everything else.
    #
    # By its path at the root, not by name anywhere: a collected file of the same name is
    # evidence and is hashed like the rest (review 2026-09-30, finding 331).
    $relativePath = $file.FullName.Substring($staging.Length).TrimStart('\')
    if ($relativePath -eq 'ToolLog.txt') { continue }
    New-Object psobject -Property ([ordered]@{
        Path      = $relativePath
        SizeBytes = $file.Length
        Sha256    = Get-Sha256 -Path $file.FullName
    })
}
$manifestJson = if (@($manifest).Count -gt 0) { @($manifest) | ConvertTo-Json -Depth 5 } else { '[]' }
Set-Content -LiteralPath (Join-Path $staging 'Manifest.json') -Value $manifestJson -Encoding UTF8

Write-CollectorLog -Message "Packaging $(@($manifest).Count) file(s) into $bundleName"

if (Test-Path -LiteralPath $bundlePath) { Remove-Item -LiteralPath $bundlePath -Force }
New-ZipArchive -SourcePath $staging -DestinationPath $bundlePath
Remove-Item -LiteralPath $staging -Recurse -Force

$bundleSize = (Get-Item -LiteralPath $bundlePath).Length

Write-Information '' -InformationAction Continue
Write-Information '  Done.' -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information "  File to send : $bundlePath" -InformationAction Continue
Write-Information "  Size         : $([math]::Round($bundleSize / 1MB, 1)) MB" -InformationAction Continue
Write-Information "  Reference    : $correlationId" -InformationAction Continue
Write-Information '' -InformationAction Continue

# "Attach this to your support case" is wrong advice above roughly 25 MB, which is
# where most Exchange and Outlook tenants cap an attachment. A real collection that
# included Teams' own diagnostic output came to 103 MB - 99.6% of it the optional
# extra logs, against 0.2 MB of actual Teams client logs. Telling somebody to attach
# that means they find out it will not send only after trying, and the usual next
# step is to give up rather than to ask.
$emailLimitBytes = 25MB
if ($bundleSize -gt $emailLimitBytes) {
    Write-Information '  This file is probably too large to attach to an email.' -InformationAction Continue
    Write-Information '  Upload it to OneDrive or SharePoint and send the engineer a link instead,' -InformationAction Continue
    Write-Information '  or ask them how they would like to receive it.' -InformationAction Continue
    Write-CollectorLog -Level 'WARN' -Message ("Bundle is {0:N1} MB, above the {1:N0} MB attachment guidance." -f `
        ($bundleSize / 1MB), ($emailLimitBytes / 1MB))
} else {
    Write-Information '  Next step: attach this file to your support case.' -InformationAction Continue
}
if (-not $CaseNumber) {
    Write-Information '  You did not enter a case number - please quote the reference above.' -InformationAction Continue
}
Write-Information '' -InformationAction Continue

return $bundlePath

} catch {
    # A failed collection is exactly the one somebody needs to debug, so it still
    # has to produce a file the user can send. Anything already gathered goes in
    # alongside the log rather than being discarded.
    Write-CollectorLog -Message 'Collection failed.' -Level 'ERROR' -ErrorRecord $_

    $failurePath = Join-Path $OutputFolder "TeamsLogs-FAILED-$((Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)).zip"
    $wrote = $false
    try {
        if (Test-Path -LiteralPath $staging) {
            Set-Content -LiteralPath (Join-Path $staging 'READ-ME-FIRST.txt') -Encoding UTF8 -Value @"
Microsoft Teams log collection - FAILED
=======================================

This collection did not finish. The error is recorded in ToolLog.txt, together
with details of this computer.

Please send this file to the engineer who asked you to run the collection. It
still contains whatever was gathered before the problem occurred.

Case number : $CaseNumber
Reference   : $correlationId
"@
            if (Test-Path -LiteralPath $failurePath) { Remove-Item -LiteralPath $failurePath -Force }
            New-ZipArchive -SourcePath $staging -DestinationPath $failurePath
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            $wrote = $true
        }
    } catch {
        Write-Verbose "Could not build the failure bundle: $($_.Exception.Message)"
    }

    Write-Information '' -InformationAction Continue
    Write-Information '  Something went wrong.' -InformationAction Continue
    Write-Information "  $($_.Exception.Message)" -InformationAction Continue
    Write-Information '' -InformationAction Continue
    if ($wrote) {
        Write-Information '  A diagnostic file was still created. Please send it to the engineer' -InformationAction Continue
        Write-Information '  who asked you to run this:' -InformationAction Continue
        Write-Information "    $failurePath" -InformationAction Continue
    } else {
        Write-Information '  No diagnostic file could be created. Please copy the text above' -InformationAction Continue
        Write-Information '  and send it to the engineer who asked you to run this.' -InformationAction Continue
        # The files already gathered are still in the staging folder, and nothing else says so.
        # Named rather than deleted: it may be all the evidence there is (review 2026-09-30).
        if (Test-Path -LiteralPath $staging) {
            Write-Information '  What was gathered before the problem is still in this folder, which' -InformationAction Continue
            Write-Information '  the engineer may ask you to zip and send. Delete it when it is no longer needed:' -InformationAction Continue
            Write-Information "    $staging" -InformationAction Continue
        }
    }
    Write-Information '' -InformationAction Continue

    # A failed collection is a failure to anything running this unattended (review 2026-09-30).
    if (-not $MyInvocation.ScriptName) { exit 1 }
    return $null
}

