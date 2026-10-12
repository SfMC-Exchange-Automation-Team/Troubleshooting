Set-StrictMode -Version Latest

<#
    The display language of the wizard window.

    SCOPE

    This translates the WINDOW. Everything that lands in a bundle stays in English - see
    the header of Tlc.Settings.psm1 for why, in short: the bundle is read downstream by
    people who do not share the collecting engineer's language, and evidence nobody can
    read is worse than evidence that is merely in someone else's second language.

    HOW LOOKUP FAILS

    Get-TlcString falls back to en-US for a key the chosen table does not carry, and
    returns the key itself if en-US does not carry it either. Both are deliberate: a
    half-translated table should degrade to a readable English window rather than blanks,
    and a genuinely missing key should show as its own name so it is obvious on screen
    rather than rendering as empty space that looks like a layout bug.

    Tlc.Localization.Tests.ps1 asserts every table carries every en-US key, so the first
    fallback should never fire in a shipped build - it exists for the case where someone
    adds a string and translates it later.

    TRANSLATION PROVENANCE

    Every table other than en-US was produced by machine translation and has NOT been
    reviewed by a native speaker. They cover the window - labels, buttons, hints, the tile
    captions and values, the banners and the run's status lines - and the strings where a
    mistranslation would cost the most (consent wording, blocker detail, anything in the
    bundle) are deliberately not in scope. The tile values are diagnostic verdicts and the
    first thing a reviewer should read. Anyone shipping this to a customer-facing audience
    should get the tables reviewed first; docs\translation-review.md is generated for exactly that.
#>

function Get-TlcLanguage {
    <#
    .SYNOPSIS
        The languages that ship, discovered from Lang\ and named by Windows.
    .DESCRIPTION
        Each language is named in ITS OWN language, not in English. Someone who has opened
        this menu because the window is in a language they cannot read is looking for the
        word they recognise: "Espanol" and the Devanagari for Hindi are findable in a way
        that "Spanish" and "Hindi" are not, to the person who needs the menu most.

        DISCOVERED, NOT LISTED. The menu is whatever Lang\ holds, so adding a language is
        dropping a file in - no code change, and no second place to forget to update. The
        list used to be hardcoded here, with the native names hand-built out of char codes
        because this file carries no BOM and so cannot hold a non-ASCII literal. Windows
        already knows all 800-odd of those names; asking it removes the hand-built strings
        entirely rather than adding more of them.

        WHAT WINDOWS CAN AND CANNOT GIVE. It supplies the native name, the English name and
        the reading direction for any culture it knows. It does NOT supply translated
        application strings: a language pack localises the OS, not this toolbox, and there
        is no API anywhere that returns "Package existing logs" in Tamil. Every table in
        Lang\ is authored. That is why this function is the cheap half of supporting a new
        language and the .psd1 is the expensive half.

        A file whose name is not a culture Windows recognises is skipped rather than shown.
        Measured on both editions 2026-09-16: a well-formed but non-existent tag like
        "zz-ZZ" does NOT throw - GetCultureInfo returns a CUSTOM culture with LCID 4096, so
        an exception handler alone would let it through and put a junk entry in the menu.
        The two editions do not even agree on what to call it: PowerShell 7 reports its
        native name as "zz", Windows PowerShell 5.1 as "Unknown Language (zz)". The LCID is
        what both agree on, so the LCID is what this tests.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string] $ToolboxRoot)

    if (-not $ToolboxRoot) { $ToolboxRoot = Split-Path -Parent $PSScriptRoot }
    $langRoot = Join-Path $ToolboxRoot 'Lang'

    $files = @(Get-ChildItem -LiteralPath $langRoot -Filter '*.psd1' -File -ErrorAction SilentlyContinue)

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $tag = $file.BaseName

        $culture = $null
        try { $culture = [System.Globalization.CultureInfo]::GetCultureInfo($tag) } catch { $culture = $null }
        # 4096 is LOCALE_CUSTOM_UNSPECIFIED: the tag parsed as a language tag but names no
        # culture Windows knows. Not an error, just not a language.
        if (-not $culture -or $culture.LCID -eq 4096) { continue }

        # The neutral parent, so the menu reads "espanol" rather than "espanol (Espana)".
        # The region is added back below, but only where it disambiguates.
        $neutral = $culture
        while ($neutral.Parent -and $neutral.Parent.Name) { $neutral = $neutral.Parent }

        $native = [string]$neutral.NativeName
        $regional = [string]$culture.NativeName
        # Capitalised with the culture's OWN casing rules, which is why this is not
        # ToUpper() on the invariant culture: Turkish capitalises "i" as a dotted "I".
        # On a script with no case - Devanagari, Arabic, the CJK languages - it is a
        # no-op, so the same line is correct everywhere. Applied to both forms, because
        # the regional one is what a disambiguated entry shows and a menu reading
        # "Francais" next to "portugues (Brasil)" looks like a bug in one of them.
        if ($native) { $native = $culture.TextInfo.ToUpper($native.Substring(0, 1)) + $native.Substring(1) }
        if ($regional) { $regional = $culture.TextInfo.ToUpper($regional.Substring(0, 1)) + $regional.Substring(1) }

        $candidates.Add([pscustomobject]@{
            Tag           = $tag
            Name          = $native
            EnglishName   = [string]$neutral.EnglishName
            Neutral       = [string]$neutral.Name
            Region        = $regional
            IsRightToLeft = [bool]$culture.TextInfo.IsRightToLeft
        })
    }

    # Two tables for one language need telling apart, and only then. Portuguese shipped for
    # both Brazil and Portugal is two entries reading "Portugues" otherwise, which is a menu
    # that cannot be used for the one thing it exists to do.
    $byNeutral = @{}
    foreach ($candidate in $candidates) {
        if (-not $byNeutral.ContainsKey($candidate.Neutral)) { $byNeutral[$candidate.Neutral] = 0 }
        $byNeutral[$candidate.Neutral] = $byNeutral[$candidate.Neutral] + 1
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates) {
        $name = $candidate.Name
        if ($byNeutral[$candidate.Neutral] -gt 1 -and $candidate.Region) { $name = $candidate.Region }
        $result.Add([pscustomobject]@{
            Tag           = $candidate.Tag
            Name          = $name
            EnglishName   = $candidate.EnglishName
            IsRightToLeft = $candidate.IsRightToLeft
        })
    }

    # en-US first because it is the base every other table is overlaid on, then by tag:
    # deterministic on both editions, and it keeps variants of one language together.
    return @(
        @($result | Where-Object { $_.Tag -eq 'en-US' }) +
        @($result | Where-Object { $_.Tag -ne 'en-US' } | Sort-Object -Property Tag)
    )
}

function Get-TlcThemeOption {
    <#
    .SYNOPSIS
        The theme choices, and the string key each is displayed under.
    .DESCRIPTION
        Three, in the order they belong in a menu: follow the OS first because it is the
        default and the answer most people want, then the two overrides.

        The Id is what Settings.json stores and is never translated - a preference file read
        by a future version has to mean the same thing regardless of the language the operator
        happened to be using when they saved it. The display text comes from the string table,
        so the menu is translated even though the stored value is not.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return @(
        [pscustomobject]@{ Id = 'System'; Key = 'ThemeSystem' }
        [pscustomobject]@{ Id = 'Light';  Key = 'ThemeLight' }
        [pscustomobject]@{ Id = 'Dark';   Key = 'ThemeDark' }
    )
}

function Test-TlcThemeSupported {
    <#
    .SYNOPSIS
        Whether a theme id is one the toolbox understands.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()] [AllowNull()] [string] $Theme)

    if ([string]::IsNullOrWhiteSpace($Theme)) { return $false }
    return (@(Get-TlcThemeOption | Where-Object { $_.Id -eq $Theme }).Count -gt 0)
}

function Test-TlcLanguageSupported {
    <#
    .SYNOPSIS
        Whether a language tag has a table behind it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()] [AllowNull()] [string] $Language)

    if ([string]::IsNullOrWhiteSpace($Language)) { return $false }
    return (@(Get-TlcLanguage | Where-Object { $_.Tag -eq $Language }).Count -gt 0)
}

function Get-TlcLanguagePath {
    <#
    .SYNOPSIS
        The string table file for a language tag.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Language,
        [string] $ToolboxRoot
    )

    if (-not $ToolboxRoot) { $ToolboxRoot = Split-Path -Parent $PSScriptRoot }
    return (Join-Path (Join-Path $ToolboxRoot 'Lang') "$Language.psd1")
}

function Import-TlcLanguageData {
    <#
    .SYNOPSIS
        Reads a .psd1 without depending on Import-PowerShellDataFile.
    .DESCRIPTION
        The fourth copy of this helper in the toolbox - see Tlc.Config.psm1, Tlc.Manual.psm1
        and Tlc.Scope.psm1, whose comments describe the same trap.

        Import-PowerShellDataFile lives in Microsoft.PowerShell.Utility, and a module loaded
        through the manifest does not get that module in its session state the way a directly
        imported one does. Module-qualifying the call makes it worse, because a qualified name
        does not trigger auto-loading on Windows PowerShell 5.1.

        Hit again on 2026-09-15 by the string tables, in exactly the way those comments
        predict: every test passed, because tests import the .psm1 directly and get Utility
        with it, while the real window opened with every label showing its own key name. The
        one difference between the two is how the module was loaded.

        The file is parsed, never run, which is the property that makes a .psd1 data rather
        than code - a language file must never be a place to hide a payload.

        SafeGetValue, which the cmdlet and this function both used, refuses any hashtable
        with more than 500 keys, on both editions: measured 2026-10-02, 500 loads and 501 does
        not. The English table reached 543 entries with the comparison and the admin center
        steps, and would have loaded as nothing - every label in every language showing its
        own key name. Finding 338. So the entries are read here, one by one, and only a plain
        string is accepted as a value: stricter than SafeGetValue, which also takes numbers,
        arrays and nested tables, none of which a string table has any use for.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Path)

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $parseErrors)
    if ($parseErrors -and $parseErrors.Count) {
        throw "String table could not be parsed: $Path. $($parseErrors[0].Message)"
    }

    $hashtable = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $hashtable) {
        throw "String table does not contain a hashtable: $Path"
    }

    $table = @{}
    foreach ($pair in $hashtable.KeyValuePairs) {
        $line = $pair.Item1.Extent.StartLineNumber
        if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "String table $Path, line ${line}: a key is not a plain name."
        }
        $value = $null
        $pipeline = $pair.Item2
        if ($pipeline -is [System.Management.Automation.Language.PipelineAst] -and $pipeline.PipelineElements.Count -eq 1 -and
            $pipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $pipeline.PipelineElements[0].Redirections.Count -eq 0) {
            $value = $pipeline.PipelineElements[0].Expression
        }
        # A double-quoted string with nothing to expand parses as a constant too; one with a
        # variable or a subexpression in it does not, and is refused like any other code.
        if ($value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "String table $Path, line ${line}: the entry for $($pair.Item1.Value) is not a plain string."
        }
        $table[$pair.Item1.Value] = $value.Value
    }
    return $table
}

function Import-TlcStringTable {
    <#
    .SYNOPSIS
        Loads one string table from disk.
    .DESCRIPTION
        Import-PowerShellDataFile is deliberately not used - see Import-TlcLanguageData, and
        the same comment in Tlc.Config.psm1, Tlc.Manual.psm1 and Tlc.Scope.psm1. Parsing the
        file as data is also what keeps a .psd1 from being a place to hide a payload: a
        language file is read, never run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Language,
        [string] $ToolboxRoot
    )

    $path = Get-TlcLanguagePath -Language $Language -ToolboxRoot $ToolboxRoot
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "String table '$Language' not found at $path; falling back to English."
        return @{}
    }

    try {
        return (Import-TlcLanguageData -Path $path)
    } catch {
        # Named, not swallowed. A table that fails to load renders every label as its own key
        # name, which on screen looks like a rendering fault rather than a failed read - and a
        # Write-Verbose nobody has enabled is indistinguishable from no diagnosis at all. This
        # exact catch hid a real parse error for an hour on 2026-09-15.
        Write-Warning "String table '$Language' at $path could not be read, so the window falls back to English: $($_.Exception.Message)"
        return @{}
    }
}

function Get-TlcStringTable {
    <#
    .SYNOPSIS
        The resolved string table for a language, with English underneath it.
    .DESCRIPTION
        Returns one hashtable: every en-US key, overlaid with whatever the chosen language
        translates. So a caller never has to handle a miss, and a partially translated
        table produces a window that is partly English rather than partly blank.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $Language = 'en-US',
        [string] $ToolboxRoot
    )

    $table = Import-TlcStringTable -Language 'en-US' -ToolboxRoot $ToolboxRoot

    if ($Language -and $Language -ne 'en-US' -and (Test-TlcLanguageSupported -Language $Language)) {
        $override = Import-TlcStringTable -Language $Language -ToolboxRoot $ToolboxRoot
        foreach ($key in $override.Keys) {
            $value = [string]$override[$key]
            # An empty value in a translation means "not translated yet", not "show nothing".
            # Skipping it leaves the English in place, which is readable; taking it would
            # blank a label and look like a rendering fault.
            if (-not [string]::IsNullOrWhiteSpace($value)) { $table[$key] = $value }
        }
    }

    return $table
}

function Get-TlcString {
    <#
    .SYNOPSIS
        One string from a resolved table, formatted with any arguments given.
    .DESCRIPTION
        Returns the key itself when there is no entry anywhere, so a missing string shows up
        on screen as "PathChooserCaption" rather than as empty space. Blank space reads as a
        layout bug and gets investigated as one; a key name says exactly what is wrong and
        where to fix it.

        With -Argument the entry is a composite format string ("{0} remembered on this
        machine."), filled in the current culture the way PowerShell's -f operator does, so a
        number reads the same in every language and only the words around it change. A
        translation whose placeholders do not parse is shown unformatted rather than thrown:
        Tlc.Localization.Tests.ps1 holds every table to the English placeholders, and a
        window that stops on a translator's typo would be the worse failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [hashtable] $Table,
        [Parameter(Mandatory)] [string] $Key,
        [AllowEmptyCollection()] [AllowNull()] [object[]] $Argument
    )

    $value = $Key
    if ($Table.ContainsKey($Key)) {
        $entry = [string]$Table[$Key]
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $value = $entry }
    }
    if ($PSBoundParameters.ContainsKey('Argument') -and $null -ne $Argument) {
        try {
            return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $value, $Argument)
        } catch [System.FormatException] {
            Write-Verbose "The entry for $Key does not match its arguments: $value"
        }
    }
    return $value
}

<#
    THE TILE VALUES, translated at the window and nowhere else.

    The metric functions return English, and keep doing so: their values are compared, logged
    and quoted by code that must not change with the display language. So the window
    translates a value as it draws it, by recognising which of a closed set of phrases it is.

    Exact phrases map to a key. Phrases with a number in them are matched by pattern, and the
    number is carried across as the text the metric wrote, so "1,234" stays "1,234" whatever
    the language. Anything not recognised is shown as it came: a client version, a network
    product name such as SASE, an AppX status. Those are data, and the same in every language.

    Tlc.Localization.Tests.ps1 reads every value Tlc.Ui.Metrics.psm1 and the wizard can produce
    and requires each to be recognised here, and requires the English entry for each key to
    reproduce the metric's own wording exactly.
#>
$script:TileValueKey = @{
    'Not found'          = 'TileNotFound'
    'Orphaned'           = 'TileOrphaned'
    'No log folder'      = 'TileNoLogFolder'
    'None'               = 'TileNone'
    'No logs'            = 'TileNoLogs'
    'Never'              = 'TileNever'
    'Just now'           = 'TileJustNow'
    'In the future'      = 'TileInFuture'
    'Ends in the future' = 'TileEndsInFuture'
    'Covered'            = 'TileCovered'
    'Older than logs'    = 'TileOlderThanLogs'
    'In a log gap'       = 'TileInLogGap'
    'Partly covered'     = 'TilePartlyCovered'
    'Unavailable'        = 'TileUnavailable'
    'Inspected'          = 'TileInspected'
    'Direct'             = 'TileDirect'
    'Unknown'            = 'TileUnknown'
    'Today'              = 'TileToday'
    'Yesterday'          = 'TileYesterday'
    'None found'         = 'TileNoneFound'
    '1 person'           = 'TileOnePerson'
    '1 id to declare'    = 'TileOneIdToDeclare'
    'Pick a job'         = 'TilePickAJob'
    'Live trace'         = 'TileLiveTrace'
    'Tunnelled'          = 'TileTunnelled'
}

# Ordered: the first pattern that matches wins, so "5 min ago" must be tried before "5 min".
$script:TileValuePattern = @(
    @{ Pattern = '^(\S+) files, (\S+) MB$'; Key = 'TileFilesSize' }
    @{ Pattern = '^(\S+) min ago$';         Key = 'TileMinutesAgo' }
    @{ Pattern = '^(\S+) hours ago$';       Key = 'TileHoursAgo' }
    @{ Pattern = '^(\S+) days ago$';        Key = 'TileDaysAgo' }
    @{ Pattern = '^(\S+) min$';             Key = 'TileMinutes' }
    @{ Pattern = '^(\S+) hours$';           Key = 'TileHours' }
    @{ Pattern = '^(\S+) days$';            Key = 'TileDays' }
    @{ Pattern = '^(\S+) in (\S+) h$';      Key = 'TileCountInHours' }
    @{ Pattern = '^(\S+) people$';          Key = 'TilePeople' }
    @{ Pattern = '^(\S+) ids to declare$';  Key = 'TileIdsToDeclare' }
    # "1 person, 2 tenants": the head is itself a tile phrase, translated first.
    @{ Pattern = '^(.+), (\S+) tenants$';   Key = 'TileWithTenants'; Nested = $true }
)

function Get-TlcTileText {
    <#
    .SYNOPSIS
        A dashboard tile's value in the window's language.
    .DESCRIPTION
        See the note above $script:TileValueKey. Returns the text unchanged when it is not a
        phrase the dashboard writes, because then it is data.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Text,
        [Parameter(Mandatory)] [hashtable] $Table
    )

    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    if ($script:TileValueKey.ContainsKey($Text)) { return (Get-TlcString -Table $Table -Key $script:TileValueKey[$Text]) }

    foreach ($rule in $script:TileValuePattern) {
        $match = [regex]::Match($Text, $rule.Pattern)
        if (-not $match.Success) { continue }
        $arguments = @(for ($group = 1; $group -lt $match.Groups.Count; $group++) { $match.Groups[$group].Value })
        if ($rule.ContainsKey('Nested')) { $arguments[0] = Get-TlcTileText -Text $arguments[0] -Table $Table }
        return (Get-TlcString -Table $Table -Key $rule.Key -Argument $arguments)
    }
    return $Text
}

function Get-TlcScenarioDisplayName {
    <#
    .SYNOPSIS
        A scenario's name in the window's language.
    .DESCRIPTION
        Display only. The run, the equivalent command and the bundle carry the scenario's Id,
        and everything recorded about it uses its English name from the catalog; this is what
        the scenario list and the summaries on screen say.

        Falls back to the catalog's own name rather than to the key, unlike Get-TlcString: a
        scenario added to the catalog before its translations exist should read in English, not
        as "ScenarioNameSomething". Tlc.Localization.Tests.ps1 requires every catalog scenario to
        have an English entry equal to its name, so the fallback is for a table that lags.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Scenario,
        [Parameter(Mandatory)] [hashtable] $Table
    )

    $key = 'ScenarioName' + [string]$Scenario.Id
    if ($Table.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$Table[$key])) { return [string]$Table[$key] }
    return [string]$Scenario.Name
}

function Get-TlcMetricText {
    <#
    .SYNOPSIS
        One part of a tile's explanation (New-TlcMetricText) in the window's language.
    .DESCRIPTION
        The part's key is looked up and its values filled in; a value that is itself a part,
        or a list of parts, is said in the same language first. A key the table does not have
        reads in the part's own English rather than as the key's name: an explanation is the
        one place a raw key would be worse than English.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] $Part,
        [Parameter(Mandatory)] [hashtable] $Table
    )

    if ($null -eq $Part) { return '' }
    if ($Part -is [string]) { return $Part }
    if ($Part.PSObject.Properties['Parts']) {
        return (@($Part.Parts | ForEach-Object { Get-TlcMetricText -Part $_ -Table $Table }) -join [string]$Part.Join)
    }
    if (-not $Part.PSObject.Properties['Key'] -or -not $Table.ContainsKey([string]$Part.Key)) { return [string]$Part.Text }
    $values = @(foreach ($value in @($Part.Args)) { Get-TlcMetricText -Part $value -Table $Table })
    return (Get-TlcString -Table $Table -Key ([string]$Part.Key) -Argument $values)
}

function Get-TlcMetricDetail {
    <#
    .SYNOPSIS
        A tile's explanation - its tooltip, and the summary of its detail window - in the
        window's language.
    .DESCRIPTION
        Built from the parts the metric carries, sentence by sentence. A metric with no parts
        - one made somewhere that does not say how to translate it - shows its English Detail.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] $Metric,
        [Parameter(Mandatory)] [hashtable] $Table
    )

    if ($null -eq $Metric) { return '' }
    if ($Metric.Contains('DetailParts') -and @($Metric['DetailParts']).Count -gt 0) {
        return (@($Metric['DetailParts'] | Where-Object { $null -ne $_ } | ForEach-Object { Get-TlcMetricText -Part $_ -Table $Table }) -join ' ')
    }
    return [string]$Metric['Detail']
}

Export-ModuleMember -Function Get-TlcLanguage, Test-TlcLanguageSupported, Get-TlcLanguagePath,
    Get-TlcThemeOption, Test-TlcThemeSupported,
    Import-TlcLanguageData, Import-TlcStringTable, Get-TlcStringTable, Get-TlcString, Get-TlcTileText, Get-TlcScenarioDisplayName,
    Get-TlcMetricText, Get-TlcMetricDetail
