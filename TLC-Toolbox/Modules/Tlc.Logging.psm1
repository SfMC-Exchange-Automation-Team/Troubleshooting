Set-StrictMode -Version Latest

$script:Run = $null
$script:ToolLogPath = $null
$script:EnvironmentCache = $null

function ConvertTo-TlcNativeFilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $Path }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

function Write-TlcStopProgress {
    [CmdletBinding()]
    param(
        [string] $SignalPath = '',
        [Parameter(Mandatory)] [ValidateSet('Sampling', 'Logs', 'Support', 'Finalize')] [string] $Step,
        [Parameter(Mandatory)] [ValidateSet('Running', 'Complete', 'Skipped', 'Warning')] [string] $Status,
        [Parameter(Mandatory)] [string] $DetailKey
    )

    if (-not $SignalPath) { return }
    $record = [ordered]@{ Step = $Step; Status = $Status; DetailKey = $DetailKey }
    Write-Information ('TLC-STOPSTEP:' + ($record | ConvertTo-Json -Compress)) -InformationAction Continue
}

function Invoke-TlcNativeCommand {
    <#
    .SYNOPSIS
        Runs an external executable and returns its output, including anything it wrote to
        stderr, without letting stderr become a terminating error.
    .DESCRIPTION
        Windows PowerShell 5.1 wraps every stderr line from a native command in a
        NativeCommandError record whenever that stream is redirected. Both entry points set
        $ErrorActionPreference = 'Stop', and module functions inherit it - measured, not
        assumed, because module scoping makes that non-obvious. So a redirected native
        command THROWS the moment the executable writes one line to stderr, even when it
        exits 0.

        The failure mode is the dangerous kind: silent, and inverted against the cases that
        matter. dsregcmd on a healthy machine writes nothing to stderr, so every test and
        every well-configured device passes. It writes to stderr when the join state is
        broken - the exact condition the collector exists to capture. The catch block then
        recorded "dsregcmd is unavailable", a false diagnosis of a tool that is installed
        and working, and the join state was lost from the bundle.

        Measured on 5.1 (26100.9352): redirected -> throws under Stop; not redirected -> no
        throw, and $LASTEXITCODE still distinguishes 0 from 1. 2>&1 and 2>$null both throw,
        so it is the redirection itself and not the merge.

        A genuinely missing executable is still reported as unavailable, because that
        distinction is the whole point: "the tool is not there" and "the tool answered on
        stderr" are different facts about the endpoint and must not collapse into one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    $result = [ordered]@{
        Available = $false
        ExitCode  = $null
        Lines     = @()
        Output    = @()
        Errors    = @()
        Detail    = ''
    }

    # Continue only for the duration of the call. Restored in finally so a caller that
    # relies on Stop keeps it for everything after this line.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $captured = @(& $FilePath @ArgumentList 2>&1)
        $result.Available = $true
        $result.ExitCode = $LASTEXITCODE
        $result.Lines = @($captured | ForEach-Object { [string]$_ })
        $result.Output = @($captured | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        $result.Errors = @($captured | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    } catch {
        $result.Detail = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $previous
    }

    return $result
}

function Get-TlcEnvironmentFact {
    <#
    .SYNOPSIS
        Captures the host facts needed to debug a run that happened somewhere else.
    .DESCRIPTION
        This is the list of things worth asking for first when a customer reports
        that the tool misbehaved, so it is gathered up front rather than requested
        over email afterwards.

        Culture is in here deliberately. The customer collector accepts a
        locally-formatted time ("14:30", or a date), and date parsing follows the
        current culture - so a machine running a non-en-US locale can interpret the
        same input differently. Without the culture recorded, that class of bug is
        effectively undiagnosable from a distance.
    #>
    [CmdletBinding()]
    param([switch] $Refresh)

    # Only the two expensive lookups are cached. Get-AppxPackage and the CIM query
    # together cost well over a second and describe the machine, which does not change
    # during a run - but the rest of this record must be rebuilt every call.
    #
    # Caching the whole record was a bug: CapturedAtUtc froze at the first call, so a
    # second run in the same session would stamp its log header with the first run's
    # time. ApartmentState is per-thread and the process execution policy can be
    # changed mid-session, so both have to be read where they are reported. A stale
    # fact in a debugging log is worse than a slow one.
    if ($Refresh) { $script:EnvironmentCache = $null }

    if ($null -eq $script:EnvironmentCache) {
        $os = $null
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { Write-Verbose 'CIM unavailable.' }

        $teams = $null
        try {
            $teams = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'MSTeams' } | Select-Object -First 1
        } catch { Write-Verbose 'Get-AppxPackage unavailable.' }

        $script:EnvironmentCache = [ordered]@{
            OsCaption    = if ($os) { $os.Caption } else { $null }
            OsBuild      = if ($os) { $os.BuildNumber } else { $null }
            TeamsVersion = if ($teams) { $teams.Version } else { $null }
        }
    }

    $elevated = $false
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $elevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { Write-Verbose 'Could not determine elevation.' }

    # Get-ExecutionPolicy lives in Microsoft.PowerShell.Security, and that module can
    # fail to load - on this machine a type-data conflict ("AuditToString is already
    # present") makes it unavailable, so the cmdlet throws CommandNotFoundException.
    # It happened in exactly the way the GUI runs a stage, which is the same trap as
    # Import-PowerShellDataFile: a cmdlet from a core module is not guaranteed to be
    # there.
    #
    # Losing this field is worse than losing most: it is the one that diagnoses "the
    # script will not run on my machine". PSExecutionPolicyPreference is set by
    # powershell.exe from -ExecutionPolicy and needs no module at all.
    $policy = ''
    try { $policy = (Get-ExecutionPolicy -Scope Process).ToString() } catch { Write-Verbose 'Get-ExecutionPolicy is unavailable.' }
    if (-not $policy) { $policy = $env:PSExecutionPolicyPreference }
    if (-not $policy) { $policy = 'unavailable' }

    # Constrained language mode silently removes most of what this toolbox does, and it
    # is a normal setting in a locked-down enterprise. Without it recorded, a run that
    # fails there looks like an ordinary bug.
    $languageMode = 'unknown'
    try { $languageMode = $ExecutionContext.SessionState.LanguageMode.ToString() } catch { Write-Verbose 'Language mode unavailable.' }

    # WHICH BUILD OF THE TOOLBOX PRODUCED THIS. Every other version here is about the
    # machine - Windows, PowerShell, Teams - and the one thing a reader cannot recover from
    # the evidence is which build of this tool wrote it.
    #
    # Cost a full cycle on 2026-09-22: a fix was reported as not working, and the operator
    # was holding a window launched twelve minutes before the fix existed. Neither of us
    # could tell from anything on screen or in the log, so the fix was defended instead of
    # the build being checked.
    #
    # Read from the manifest beside this module. A failure leaves it unknown rather than
    # stopping the log from opening - a tool log that refuses to start because it cannot
    # find a version number is worse than one with a blank field.
    $toolboxVersion = 'unknown'
    try {
        $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Tlc.psd1'
        if (Test-Path -LiteralPath $manifestPath) {
            $parsed = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($manifestPath, [ref] $null, [ref] $parsed)
            if (-not ($parsed -and $parsed.Count)) {
                $table = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
                if ($table) { $toolboxVersion = [string]$table.SafeGetValue().ModuleVersion }
            }
        }
    } catch { Write-Verbose 'The toolbox version could not be read for the log header.' }

    $script:EnvironmentFacts = [ordered]@{
        CapturedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
        ToolboxVersion    = $toolboxVersion
        ComputerName      = $env:COMPUTERNAME
        User              = "$env:USERDOMAIN\$env:USERNAME"
        Elevated          = $elevated
        PsVersion         = $PSVersionTable.PSVersion.ToString()
        PsEdition         = $PSVersionTable.PSEdition
        ExecutionPolicy   = $policy
        LanguageMode      = $languageMode
        ApartmentState    = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
        Culture           = (Get-Culture).Name
        UiCulture         = (Get-UICulture).Name
        TimeZoneId        = [System.TimeZoneInfo]::Local.Id
        UtcOffsetHours    = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours
        OsCaption         = $script:EnvironmentCache.OsCaption
        OsBuild           = $script:EnvironmentCache.OsBuild
        TeamsVersion      = $script:EnvironmentCache.TeamsVersion
        Is64BitProcess    = [Environment]::Is64BitProcess
    }

    return $script:EnvironmentFacts
}

function Start-TlcToolLog {
    <#
    .SYNOPSIS
        Opens the tool's own log for this run.
    .DESCRIPTION
        Distinct from Events.jsonl. Events.jsonl records what the collection found;
        this records what the TOOL did, including its own failures, so a run that
        goes wrong at a customer site can be debugged from the file they send back.

        Plain text on purpose - it is read by a human under time pressure, and it
        has to survive being pasted into an email.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Context = 'TLC-Toolbox'
    )

    $script:ToolLogPath = $Path
    $facts = Get-TlcEnvironmentFact

    $header = [System.Collections.Generic.List[string]]::new()
    $header.Add("===== $Context tool log =====")
    foreach ($key in $facts.Keys) { $header.Add(('{0,-18}{1}' -f $key, $facts[$key])) }
    $header.Add('=============================')
    $header.Add('')

    Set-Content -LiteralPath $Path -Value $header -Encoding utf8
    return $Path
}

function Write-TlcToolLog {
    <#
    .SYNOPSIS
        Appends a line to the tool log. Never throws.
    .DESCRIPTION
        Logging must not be able to break the thing it is observing, so every
        failure here is swallowed. A missing log line is a nuisance; a collection
        that aborts because logging failed is a defect.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO',
        $ErrorRecord
    )

    if (-not $script:ToolLogPath) { return }

    try {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("$stamp [$Level] $Message")

        if ($ErrorRecord) {
            $lines.Add("            Exception : $($ErrorRecord.Exception.GetType().FullName)")
            $lines.Add("            Message   : $($ErrorRecord.Exception.Message)")
            if ($ErrorRecord.InvocationInfo) {
                $lines.Add("            At        : $($ErrorRecord.InvocationInfo.ScriptName):$($ErrorRecord.InvocationInfo.ScriptLineNumber)")
                $lines.Add("            Line      : $($ErrorRecord.InvocationInfo.Line.Trim())")
            }
            if ($ErrorRecord.ScriptStackTrace) {
                foreach ($frame in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
                    $lines.Add("            Stack     : $frame")
                }
            }
        }

        Add-Content -LiteralPath $script:ToolLogPath -Value $lines -Encoding utf8
    } catch {
        # Deliberately non-fatal. See the description above.
        Write-Verbose "Could not append to the tool log: $($_.Exception.Message)"
    }
}

function Get-TlcToolLogPath {
    [CmdletBinding()]
    param()
    return $script:ToolLogPath
}

function Test-TlcDiskFullError {
    <#
    .SYNOPSIS
        True when an exception, or anything inside it, is Windows reporting a full disk.
    .DESCRIPTION
        ERROR_DISK_FULL (0x70) and ERROR_HANDLE_DISK_FULL (0x27), carried in the low word of an
        IOException's HResult. Inner exceptions are walked because a cmdlet usually wraps the
        IOException in its own. Finding 310.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Exception)

    $cause = $Exception
    while ($cause) {
        if ($cause -is [System.IO.IOException] -and (($cause.HResult -band 0xFFFF) -in 0x70, 0x27)) { return $true }
        $cause = $cause.InnerException
    }
    return $false
}

function Get-TlcRemoteConnectHint {
    <#
    .SYNOPSIS
        A plain reason to put before WinRM's own message when a remote session will not open.
    .DESCRIPTION
        A name that does not resolve makes WinRM answer with its TrustedHosts and HTTPS text,
        which sends an operator off to loosen TrustedHosts for what is a typo. Measured
        2026-09-28 with -TargetDevice tlc-no-such-host. Returns $null when the name resolves,
        so WinRM's message stands on its own for every other failure. Finding 316.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $HostName)

    try {
        $null = [System.Net.Dns]::GetHostAddresses($HostName)
        return $null
    } catch {
        return "The name $HostName does not resolve in DNS, so this is a name or network problem, not a WinRM setting. Check the spelling, or use the fully qualified name."
    }
}

function Test-TlcFolderName {
    <#
        Whether a value taken from input can be used as ONE folder name: no path separators or
        other characters Windows refuses in a name, not '.' or '..', and not blank. Run ids and
        endpoint names are joined into paths, and a value that was a path escaped the run folder
        (review 2026-09-30, finding 331).
    #>
    param([AllowEmptyString()] [string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128) { return $false }
    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    if ($Name.Trim().Trim('.') -eq '') { return $false }
    return $true
}

function Initialize-TlcRun {
    <#
    .SYNOPSIS
        Creates the run folder and establishes run identity.
    .DESCRIPTION
        Follows the EPO evidence layout: one folder per CorrelationId holding
        Run.json, Plan.json, Blockers.csv, Events.jsonl and Summary.csv, with
        per-endpoint detail underneath. CorrelationId is what ties a bundle to a
        support case, so it is generated once here and reused everywhere.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunRoot,
        [Parameter(Mandatory)] [string] $Scenario,
        [string] $CorrelationId,
        [string] $CaseNumber,
        [string] $CustomerName,
        [switch] $ValidationOnly
    )

    if (-not $CorrelationId) { $CorrelationId = [guid]::NewGuid().ToString() }

    # A run id becomes a folder name, so it is held to one. '..\..\somewhere' used to put the
    # run folder outside the output root, where Package later zips it and a re-run with the same
    # id deletes and rewrites it (review 2026-09-30, finding 331).
    if (-not (Test-TlcFolderName -Name $CorrelationId)) {
        throw "-CorrelationId '$CorrelationId' cannot be used as a folder name. Use a run id such as a GUID, with no path separators and not '.' or '..'."
    }

    $runPath = Join-Path $RunRoot $CorrelationId
    $null = New-Item -ItemType Directory -Path $runPath -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $runPath 'Endpoints') -Force

    # Opened before anything else can fail, so a run that dies early still leaves a
    # log with the environment in it.
    $null = Start-TlcToolLog -Path (Join-Path $runPath 'ToolLog.txt') -Context 'TLC-Toolbox'

    $script:Run = [ordered]@{
        CorrelationId  = $CorrelationId
        RunId          = [guid]::NewGuid().ToString()
        Scenario       = $Scenario
        CaseNumber     = $CaseNumber
        CustomerName   = $CustomerName
        Operator       = "$env:USERDOMAIN\$env:USERNAME"
        OperatorMachine= $env:COMPUTERNAME
        StartTimeUtc   = (Get-Date).ToUniversalTime().ToString('o')
        EndTimeUtc     = $null
        ValidationOnly = [bool]$ValidationOnly
        RunPath        = $runPath
        Status         = 'Running'
    }

    Write-TlcEvent -Phase 'Initialize' -Step 'CreateRunFolder' -Status 'Complete' -Message "Run folder created at $runPath"
    Write-TlcToolLog -Message "Run $CorrelationId started. Scenario=$Scenario Case=$CaseNumber ValidationOnly=$([bool]$ValidationOnly)"
    return $script:Run
}

function Get-TlcRun {
    [CmdletBinding()]
    param()
    if (-not $script:Run) { throw 'No active run. Call Initialize-TlcRun first.' }
    return $script:Run
}

function Write-TlcEvent {
    <#
    .SYNOPSIS
        Appends a structured event to Events.jsonl.
    .DESCRIPTION
        JSON Lines because it survives partial runs: a crashed or cancelled
        collection still leaves every event written up to that point readable,
        which a single JSON document would not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [string] $Step,
        [ValidateSet('Started', 'Complete', 'Warning', 'Failed', 'Skipped')]
        [string] $Status = 'Complete',
        [ValidateSet('Information', 'Warning', 'Critical')]
        [string] $Severity = 'Information',
        [string] $Endpoint = $env:COMPUTERNAME,
        [string] $Message,
        [string] $EvidencePath,
        [int] $DurationMs = 0,
        $ErrorRecord
    )

    if (-not $script:Run) { return }

    $record = [ordered]@{
        CorrelationId = $script:Run.CorrelationId
        RunId         = $script:Run.RunId
        Scenario      = $script:Run.Scenario
        Endpoint      = $Endpoint
        Phase         = $Phase
        Step          = $Step
        Status        = $Status
        Severity      = $Severity
        TimestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
        DurationMs    = $DurationMs
        Message       = $Message
        EvidencePath  = $EvidencePath
        ErrorRecord   = if ($ErrorRecord) { "$ErrorRecord" } else { $null }
    }

    $line = $record | ConvertTo-Json -Depth 6 -Compress
    Add-Content -LiteralPath (Join-Path $script:Run.RunPath 'Events.jsonl') -Value $line -Encoding utf8
}

function Write-TlcBlocker {
    <#
    .SYNOPSIS
        Records a condition that stopped or degraded collection.
    .DESCRIPTION
        Blockers.csv is the file a support engineer reads first, so it stays flat
        and CSV rather than nested JSON. A Critical blocker with BlockOnCritical
        set is what halts the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Warning', 'Blocked')]
        [string] $Status,
        [ValidateSet('Information', 'Warning', 'Critical')]
        [string] $Severity = 'Information',
        [string] $Endpoint = $env:COMPUTERNAME,
        [string] $Detail,
        [string] $Remediation
    )

    if (-not $script:Run) { throw 'No active run. Call Initialize-TlcRun first.' }

    $row = [pscustomobject][ordered]@{
        CorrelationId = $script:Run.CorrelationId
        Endpoint      = $Endpoint
        Check         = $Check
        Status        = $Status
        Severity      = $Severity
        Blocked       = ($Status -eq 'Blocked')
        Detail        = $Detail
        Remediation   = $Remediation
        TimestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    $path = Join-Path $script:Run.RunPath 'Blockers.csv'

    # A later stage on the same run folder re-runs the scope phase, which re-raises every
    # manual item and the affected-user note. Measured on the live call test: after Package,
    # each of them appeared twice in the file an engineer reads first, which reads as two
    # separate problems. A row identical in every fact to one already recorded adds nothing,
    # so it is not appended again. A changed status or detail is a new fact and still is.
    if (Test-Path -LiteralPath $path) {
        $existing = @(Import-Csv -LiteralPath $path -Encoding utf8 | Where-Object {
            $_.Endpoint -eq [string]$Endpoint -and $_.Check -eq $Check -and $_.Status -eq $Status -and
            $_.Severity -eq $Severity -and $_.Detail -eq [string]$Detail -and $_.Remediation -eq [string]$Remediation
        })
        if ($existing.Count -gt 0) { return $row }
    }

    $row | Export-Csv -LiteralPath $path -NoTypeInformation -Append -Encoding utf8
    return $row
}

function Export-TlcEvidence {
    <#
    .SYNOPSIS
        Writes an evidence object into the run folder and returns its path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $InputObject,
        [string] $Endpoint
    )

    if (-not $script:Run) { throw 'No active run. Call Initialize-TlcRun first.' }

    # Same rule as the run id: an endpoint name is a folder under Endpoints, never a path.
    if ($Endpoint -and -not (Test-TlcFolderName -Name $Endpoint)) {
        throw "The endpoint name '$Endpoint' cannot be used as a folder name. Use the computer name, with no path separators and not '.' or '..'."
    }

    $targetDir = if ($Endpoint) {
        $dir = Join-Path (Join-Path $script:Run.RunPath 'Endpoints') $Endpoint
        $null = New-Item -ItemType Directory -Path $dir -Force
        $dir
    } else {
        $script:Run.RunPath
    }

    $path = Join-Path $targetDir $Name
    # An empty collection piped to ConvertTo-Json produces no output at all, so no file was
    # written - while Collect.json still named it as EventLogPath. A window with zero events
    # left a dangling path that read exactly like a lane that never ran. Written as [] so
    # "nothing found" is on disk; every other input serialises exactly as before.
    if ($InputObject -is [System.Collections.ICollection] -and $InputObject -isnot [System.Collections.IDictionary] -and $InputObject.Count -eq 0) {
        Set-Content -LiteralPath $path -Value '[]' -Encoding utf8
        return $path
    }
    $InputObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Write-TlcStartupFailure {
    <#
    .SYNOPSIS
        Records a failure that happened before a run folder existed.
    .DESCRIPTION
        The tool log lives inside the run folder, so anything that fails before
        Initialize-TlcRun - an unreadable configuration, an output root that cannot
        be created, a scenario that does not resolve - has nowhere to write.

        Those are the failures most likely to happen on a machine nobody can reach,
        because they are the ones caused by that machine's configuration. Writing to
        the temp folder gives the operator something to send instead of a screenshot
        of a red console.

        Returns the path, or an empty string if even this could not be written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ErrorRecord,
        [string] $Context = 'TLC-Toolbox startup'
    )

    try {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) `
                          ("TLC-startup-failure-$((Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)).log")
        Start-TlcToolLog -Path $path -Context $Context | Out-Null
        Write-TlcToolLog -Message 'Failed before a run folder could be created.' -Level 'ERROR' -ErrorRecord $ErrorRecord
        return $path
    } catch {
        Write-Verbose "Could not write a startup failure log: $($_.Exception.Message)"
        return ''
    }
}

function Complete-TlcRun {
    <#
    .SYNOPSIS
        Finalizes Run.json and writes the run summary.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Complete', 'Blocked', 'Failed', 'ValidationOnly')]
        [string] $Status = 'Complete',
        $ErrorRecord
    )

    if (-not $script:Run) { throw 'No active run. Call Initialize-TlcRun first.' }

    $script:Run.EndTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
    $script:Run.Status = $Status

    if ($ErrorRecord) {
        # Recorded in Run.json as well as the log, so the failure is visible to
        # anything that reads the run programmatically.
        $script:Run['Error'] = [ordered]@{
            Type    = $ErrorRecord.Exception.GetType().FullName
            Message = $ErrorRecord.Exception.Message
            Script  = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.ScriptName } else { $null }
            Line    = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.ScriptLineNumber } else { $null }
            Stack   = $ErrorRecord.ScriptStackTrace
        }
    }

    $runFile = Join-Path $script:Run.RunPath 'Run.json'
    $script:Run | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $runFile -Encoding utf8

    Write-TlcEvent -Phase 'Complete' -Step 'FinalizeRun' -Status 'Complete' -Message "Run finished with status $Status" -EvidencePath $runFile
    Write-TlcToolLog -Message "Run finished with status $Status." -Level $(if ($Status -eq 'Failed') { 'ERROR' } else { 'INFO' })
    return $script:Run
}

Export-ModuleMember -Function ConvertTo-TlcNativeFilePath, Write-TlcStopProgress, Invoke-TlcNativeCommand, Test-TlcDiskFullError, Get-TlcRemoteConnectHint, Initialize-TlcRun, Get-TlcRun, Write-TlcEvent, Write-TlcBlocker, Export-TlcEvidence, Complete-TlcRun,
    Get-TlcEnvironmentFact, Start-TlcToolLog, Write-TlcToolLog, Get-TlcToolLogPath, Write-TlcStartupFailure
