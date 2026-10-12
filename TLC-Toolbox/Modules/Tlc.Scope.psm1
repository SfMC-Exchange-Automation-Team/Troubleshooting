Set-StrictMode -Version Latest

<#
    Scenario catalog. One entry per row of the published Log Collection Matrix.

    Lanes describe what the toolbox can actually do, which is the honest part of
    the design:
      Auto     - collected with no human action
      Prompted - the tool instructs, waits, then verifies and harvests
      Manual   - cannot be collected locally; emitted as a checklist stub
#>
$script:ScenarioCatalog = $null

function Get-TlcDataPath {
    <#
    .SYNOPSIS
        Resolves a file under the toolbox Data folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Name)
    return (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') $Name)
}
function Get-TlcScenarioCatalog {
    <#
    .SYNOPSIS
        Returns the scenario catalog, loading it from Data\ on first use.
    .DESCRIPTION
        Cached because the catalog is read on every scope resolution and the file
        does not change within a run.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:ScenarioCatalog) {
        $path = Get-TlcDataPath -Name 'ScenarioCatalog.psd1'
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Scenario catalog was not found: $path"
        }
        $script:ScenarioCatalog = @((Import-TlcDataFile -Path $path).Scenarios)
    }

    return $script:ScenarioCatalog
}


function Import-TlcDataFile {
    <#
    .SYNOPSIS
        Reads a PowerShell data file without depending on Import-PowerShellDataFile.
    .DESCRIPTION
        Import-PowerShellDataFile lives in Microsoft.PowerShell.Utility, and a module
        loaded through the manifest does not get that module in its session state the
        way a directly-imported one does. Qualifying the call makes it worse, because a
        module-qualified name does not trigger auto-loading in Windows PowerShell 5.1 -
        so the wizard failed at startup while every test, which imports module files
        directly, kept passing.

        Parsing the file and calling SafeGetValue on the hashtable is what the built-in
        cmdlet does anyway, and it has no module dependency at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Data file was not found: $Path"
    }

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $parseErrors)
    if ($parseErrors -and $parseErrors.Count) {
        throw "Data file could not be parsed: $Path. $($parseErrors[0].Message)"
    }

    $hashtable = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $hashtable) {
        throw "Data file does not contain a hashtable: $Path"
    }

    return $hashtable.SafeGetValue()
}
function Resolve-TlcScenario {
    <#
    .SYNOPSIS
        Resolves a scenario id to its catalog entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Scenario
    )

    $match = Get-TlcScenarioCatalog | Where-Object { $_.Id -eq $Scenario }
    if (-not $match) {
        $valid = (Get-TlcScenarioCatalog | ForEach-Object { $_.Id }) -join ', '
        throw "Unknown scenario '$Scenario'. Valid scenarios: $valid"
    }
    return $match
}

function Test-TlcRunRequest {
    <#
    .SYNOPSIS
        The reasons a run would be refused before it starts, as a list rather than a throw.
    .DESCRIPTION
        This exists so the wizard can ask the question the entry point is about to ask,
        without paying for the answer.

        Measured 2026-09-08: starting a collection with no case number took 8.1 to 17.4
        seconds to come back and say so. None of that time was spent discovering anything -
        it was a process spawn and a module load, and the answer was knowable from the form
        before any of it. That is the whole reason this is a separate function.

        It returns problems instead of throwing because the two callers need different
        things from the same rules. The entry point wants to stop, and does. The wizard wants
        to put a message beside the field and leave the window usable.

        ONE definition, two callers. A pre-flight check that carries its own copy of the
        rules is worse than no pre-flight check at all: it will eventually pass something the
        entry point then refuses, and the operator learns that the fast validation lies. This
        is the finding 114 shape - two statements of the same rule drift - and the guard for
        it asserts the entry point holds no copy of these conditions.

        Each problem names the Field so a caller with a form can point at the control
        responsible, rather than printing a sentence and leaving the operator to find it.

        Message is the English the command line prints, phrased for its switches. Key names
        the same problem in the string tables, phrased for the window and its controls, and
        Argument holds the values that wording fills in. The window says Key in the
        operator's language; nothing here depends on the display language.
    .PARAMETER Config
        The merged configuration. Required because the case number rule is not universal -
        it is Scope.RequireCaseNumber, and a deployment that does not set it should not be
        told a case number is missing.
    #>
    [CmdletBinding()]
    param(
        [string] $Scenario,
        [string] $CaseNumber,
        [switch] $ValidationOnly,
        $Config
    )

    $problems = [System.Collections.Generic.List[object]]::new()

    if ([string]::IsNullOrWhiteSpace($Scenario)) {
        $problems.Add([ordered]@{
            Field    = 'Scenario'
            Message  = 'No scenario supplied. Pass -Scenario, set Scope.DefaultScenario, or use -ListScenarios.'
            Key      = 'ProblemScenarioMissing'
            Argument = @()
        })
    } else {
        # Resolution is part of the question. An unknown scenario is refused before a run
        # folder is created, so the wizard should be able to learn that just as early.
        try { $null = Resolve-TlcScenario -Scenario $Scenario }
        catch {
            $problems.Add([ordered]@{
                Field    = 'Scenario'
                Message  = $_.Exception.Message
                Key      = 'ProblemScenarioUnknown'
                Argument = @($Scenario)
            })
        }
    }

    # Read defensively: a config missing the Scope section entirely must produce "no rule"
    # rather than throwing inside a validator, which would turn a missing setting into a
    # crash in the one place that exists to prevent crashes.
    $requireCase = $false
    try {
        if ($Config -and $Config.Scope -and $Config.Scope.Contains('RequireCaseNumber')) {
            $requireCase = [bool]$Config.Scope.RequireCaseNumber
        }
    } catch { $requireCase = $false }

    if ($requireCase -and [string]::IsNullOrWhiteSpace($CaseNumber) -and -not $ValidationOnly) {
        $problems.Add([ordered]@{
            Field    = 'CaseNumber'
            Message  = 'A case number is required by configuration (Scope.RequireCaseNumber). Pass -CaseNumber, or use -ValidationOnly.'
            Key      = 'ProblemCaseNumber'
            Argument = @()
        })
    }

    return @($problems)
}

function ConvertTo-TlcUtc {
    <#
    .SYNOPSIS
        Converts an operator-supplied impact time to UTC, preserving the offset.
    .DESCRIPTION
        The input here is a time a human typed, so it is local by definition and the
        conversion is the ordinary one. Both representations and the offset in force
        are recorded because every later stage matches evidence against this window,
        and an offset that has to be inferred later is an offset that gets inferred
        wrongly.

        Do not read this as a statement about what is inside the log files. A Teams
        log line looks like 2026-08-22T05:32:43.031132-05:00, and the value is UTC
        while the suffix is the machine's local offset - the two do not describe each
        other. Verified again 2026-08-22: that line came from a file whose
        CreationTimeUtc is 05:32:43 and whose local CreationTime is 00:32:43, so the
        value matches UTC and the suffix is decoration. See ConvertFrom-TlcLogTimestamp,
        which is the only place log line timestamps should be parsed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [datetime] $LocalTime
    )

    # A datetime carries a Kind, and a caller can hand this one that is already UTC -
    # -ImpactTime (Get-Date).ToUniversalTime() is a natural thing for an engineer to
    # write, especially since the output reference tells them to compare everything
    # against UTC. ToUniversalTime() on a value already marked Utc is a no-op, so both
    # fields below came out identical and the whole window sat an offset away from the
    # instant that was meant. Scope.json then recorded local and UTC as the same
    # string, which at a non-zero offset cannot be true of any real moment.
    #
    # Kind is normalised rather than rejected: the caller named an instant, and the
    # instant is preserved. Unspecified is left alone, because ToUniversalTime treats
    # it as local, which is what a bare '2026-08-21 14:00' from the command line means.
    $local = if ($LocalTime.Kind -eq [System.DateTimeKind]::Utc) { $LocalTime.ToLocalTime() } else { $LocalTime }

    $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($local)

    return [ordered]@{
        LocalTime     = $local.ToString('o')
        UtcTime       = $local.ToUniversalTime().ToString('o')
        UtcOffsetHours= $offset.TotalHours
        TimeZoneId    = [System.TimeZoneInfo]::Local.Id
    }
}

function New-TlcScopeRecord {
    <#
    .SYNOPSIS
        Builds the scope record that anchors every later stage.
    .DESCRIPTION
        Everything collected afterwards is filtered against this window, so it is
        captured once and treated as immutable for the run.

        -WindowMode Live is the live-trace fork, and it records NO window at all.
        A live trace has no retrospective span to filter against: it starts when the
        operator presses the button and ends when they press Stop, and the times it
        actually covered are measured by the capture session itself and written to
        Capture.json as StartedUtc/EndedUtc.

        Measured 2026-10-02 on capture run 8ba960dd: Scope.json claimed a window of
        12:45 to 13:45 on a trace that ran for a few seconds. Nothing in the capture
        path reads those fields, so no collection was wrong - but the bundle carried
        an hour-wide window that no evidence in it came from, and a reader has no way
        to tell a recorded fact from a leftover default. Wrong evidence in a bundle
        outlives everyone who could correct it, so the fields are left empty rather
        than filled with a plausible number.

        The three window fields are always PRESENT and set to $null, never omitted.
        Set-StrictMode -Version Latest throws on a missing property in both editions
        (measured), so an absent key would turn every reader into a crash instead of
        a branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Scenario,
        [Parameter(Mandatory)] [datetime] $ImpactTime,
        [int] $WindowBeforeMinutes = 30,
        [int] $WindowAfterMinutes = 30,
        [string] $AffectedUser,
        [string] $CaseNumber,
        [string] $ClientType,
        [string] $Description,
        [ValidateSet('Retrospective', 'Live')] [string] $WindowMode = 'Retrospective'
    )

    $entry = Resolve-TlcScenario -Scenario $Scenario
    $live = $WindowMode -eq 'Live'
    $start = $ImpactTime.AddMinutes(-1 * [Math]::Abs($WindowBeforeMinutes))
    $end = $ImpactTime.AddMinutes([Math]::Abs($WindowAfterMinutes))

    return [ordered]@{
        Scenario        = $entry.Id
        ScenarioName    = $entry.Name
        Component       = $entry.Component
        AffectedUser    = $AffectedUser
        CaseNumber      = $CaseNumber
        ClientType      = $ClientType
        Description     = $Description
        WindowMode      = $WindowMode
        WindowNote      = if ($live) {
                              'Live trace. The times this run covered are measured by the capture session and recorded in Capture.json as StartedUtc and EndedUtc; there is no retrospective window.'
                          } else {
                              'Selects which already-written logs to take. Nothing is recorded while the window elapses.'
                          }
        ImpactTime      = if ($live) { $null } else { ConvertTo-TlcUtc -LocalTime $ImpactTime }
        WindowStart     = if ($live) { $null } else { ConvertTo-TlcUtc -LocalTime $start }
        WindowEnd       = if ($live) { $null } else { ConvertTo-TlcUtc -LocalTime $end }
        Lanes           = [ordered]@{
            Auto     = @($entry.Auto)
            Prompted = @($entry.Prompted)
            Manual   = @($entry.Manual)
        }
        CapturedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

Export-ModuleMember -Function Get-TlcDataPath, Get-TlcScenarioCatalog, Resolve-TlcScenario, ConvertTo-TlcUtc, New-TlcScopeRecord, Test-TlcRunRequest





