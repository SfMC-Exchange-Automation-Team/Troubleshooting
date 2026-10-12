Set-StrictMode -Version Latest

<#
    Manual lane.

    Evidence the toolbox cannot collect is written into the bundle as an explicit,
    unfinished checklist. The point is that a gap should be visible: a support
    engineer opening the bundle can tell the difference between "there was no
    Entra evidence" and "nobody collected the Entra evidence".
#>

$script:ManualCatalog = $null

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

function Get-TlcManualCatalog {
    <#
    .SYNOPSIS
        Returns the portal-evidence catalog, loading it from Data\ on first use.
    .DESCRIPTION
        Portal names, paths and the fields support asks for change on Microsoft's
        schedule rather than the customer's, so they are reference data in Data\
        rather than configuration or code.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:ManualCatalog) {
        $path = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'ManualEvidence.psd1'
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Manual evidence catalog was not found: $path"
        }
        $script:ManualCatalog = (Import-TlcDataFile -Path $path).Evidence
    }

    return $script:ManualCatalog
}
function New-TlcManualChecklist {
    <#
    .SYNOPSIS
        Writes ManualChecklist.md for the scenario's manual lane.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $Items,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Scope,
        [Parameter(Mandatory)] [string] $RunPath,
        [string] $CaseNumber
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Manual evidence checklist')
    $lines.Add('')
    $lines.Add("Scenario: **$($Scope.ScenarioName)**")
    if ($CaseNumber) { $lines.Add("Case: **$CaseNumber**") }

    # Branching on the data rather than on Scope.WindowMode keeps this module free of a
    # dependency on Tlc.Scope, which its own test file does not import. A live trace sets
    # all three window fields to $null, and touching a member of $null throws under
    # Set-StrictMode -Version Latest in both editions.
    if ($null -eq $Scope.WindowStart -or $null -eq $Scope.WindowEnd) {
        $lines.Add('Repro window: **live trace** - no retrospective window. The times this run covered are in Capture.json (StartedUtc, EndedUtc).')
    } else {
        $lines.Add("Repro window (UTC): **$($Scope.WindowStart.UtcTime)** to **$($Scope.WindowEnd.UtcTime)**")
        $lines.Add("Repro window (local, $($Scope.ImpactTime.TimeZoneId)): **$($Scope.WindowStart.LocalTime)** to **$($Scope.WindowEnd.LocalTime)**")
    }
    $lines.Add('')
    $lines.Add('The toolbox cannot collect the items below. Each one is an open gap until filled in.')
    $lines.Add('')

    foreach ($item in $Items) {
        $catalog = Get-TlcManualCatalog
        $entry = $catalog[$item]
        if (-not $entry) {
            $lines.Add("## [ ] $item")
            $lines.Add('')
            $lines.Add('No catalog entry. Record what was collected and where it is stored.')
            $lines.Add('')
            continue
        }

        $lines.Add("## [ ] $($entry.Title)")
        $lines.Add('')
        if ($entry.Link) { $lines.Add("- Portal: $($entry.Link)") }
        $lines.Add("- Where: $($entry.Path)")
        if ($entry.ContainsKey('Note')) { $lines.Add("- Note: $($entry.Note)") }
        $lines.Add('- Required detail:')
        foreach ($field in $entry.Fields) {
            $lines.Add("  - [ ] $field")
        }
        $lines.Add('- [ ] Export attached to this bundle')
        $lines.Add('')
    }

    $path = Join-Path $RunPath 'ManualChecklist.md'
    Set-Content -LiteralPath $path -Value ($lines -join [Environment]::NewLine) -Encoding utf8
    return $path
}

Export-ModuleMember -Function Get-TlcManualCatalog, New-TlcManualChecklist





