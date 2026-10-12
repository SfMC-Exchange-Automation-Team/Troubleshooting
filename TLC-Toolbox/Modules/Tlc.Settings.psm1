Set-StrictMode -Version Latest

<#
    Operator preferences that outlive a session: today, the display language.

    WHERE THIS WRITES

    %LOCALAPPDATA%\TLC-Toolbox\Settings.json, beside CaseHistory.json and for the same
    reasons set out at the top of Tlc.History.psm1: the toolbox is routinely run from a
    share or a OneDrive folder, so writing preferences beside the scripts would apply one
    engineer's choices to the next one, and LOCALAPPDATA does not roam.

    It is deliberately NOT written into a run folder or anywhere the packager can reach.

    WHAT IS AND IS NOT TRANSLATED

    The language setting governs the WINDOW only. Everything that lands in a bundle -
    Blockers.csv, Scope.json, the manual checklist, the consent record, the tool log and
    the console transcript - stays in English regardless.

    That is a deliberate decision rather than an unfinished one. A bundle is handed to
    Microsoft support and read by whoever picks up the case, who does not necessarily
    share the language of the engineer who collected it. Blockers.csv in Hindi reaching a
    US escalation engineer is worse than no blocker file at all, because it looks like
    evidence and cannot be acted on. The consent record has the same problem with more
    consequence attached: it is the artefact that says who authorised the collection.

    So the operator picks the language they drive the tool in, and the evidence speaks one
    language everyone downstream can read.
#>

function Get-TlcSettingsPath {
    <#
    .SYNOPSIS
        Resolves the settings file, creating its folder on demand.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)

    if (-not $Root) {
        $Root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TLC-Toolbox'
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        $null = New-Item -ItemType Directory -Path $Root -Force
    }

    return (Join-Path $Root 'Settings.json')
}

function Get-TlcSettings {
    <#
    .SYNOPSIS
        Reads operator preferences, falling back to defaults.
    .DESCRIPTION
        A missing, corrupt or hand-edited file returns the defaults rather than throwing.
        This decides which language a window opens in; it must never be the reason the
        window fails to open at all.
    #>
    # PSUseSingularNouns, suppressed on the function rather than excluded in the settings file,
    # because the rule is worth keeping everywhere else. "Settings" is the name of the artifact
    # - one Settings.json, holding the whole set - not a plural of "Setting". Get-TlcSetting
    # would imply it returns one, which is the opposite of what it does, and the same shape as
    # the built-in Get-ItemProperty returning a property bag.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Settings is the name of the artifact, not a plural of Setting.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $Path)

    $settings = @{ Language = 'en-US'; Theme = 'System' }

    if (-not $Path) { $Path = Get-TlcSettingsPath }
    if (-not (Test-Path -LiteralPath $Path)) { return $settings }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # Read through the property list rather than by member access: a hand-edited file
        # missing the key would throw under Set-StrictMode, which is exactly the "never the
        # reason the window fails to open" case.
        $language = $raw.PSObject.Properties | Where-Object { $_.Name -eq 'Language' } | Select-Object -First 1
        if ($language -and (Test-TlcLanguageSupported -Language ([string]$language.Value))) {
            $settings.Language = [string]$language.Value
        }

        $theme = $raw.PSObject.Properties | Where-Object { $_.Name -eq 'Theme' } | Select-Object -First 1
        if ($theme -and (Test-TlcThemeSupported -Theme ([string]$theme.Value))) {
            $settings.Theme = [string]$theme.Value
        }
    } catch {
        Write-Verbose "Settings unreadable at $Path; using defaults. $($_.Exception.Message)"
    }

    return $settings
}

function Set-TlcSettings {
    <#
    .SYNOPSIS
        Writes operator preferences.
    .DESCRIPTION
        Validates against the values that actually exist. Writing an unsupported one would
        produce a window that silently falls back, which reads as the setting having been
        ignored.

        Both settings are optional, and anything not passed keeps its current value rather
        than reverting to its default - otherwise saving a language would silently reset the
        theme, which is the kind of loss nobody attributes to the right cause.
    #>
    # PSUseSingularNouns, suppressed on the function rather than excluded in the settings file,
    # because the rule is worth keeping everywhere else. "Settings" is the name of the artifact
    # - one Settings.json, holding the whole set - not a plural of "Setting". Get-TlcSetting
    # would imply it returns one, which is the opposite of what it does, and the same shape as
    # the built-in Get-ItemProperty returning a property bag.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Settings is the name of the artifact, not a plural of Setting.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Language,
        [string] $Theme,
        [string] $Path
    )

    if (-not $Path) { $Path = Get-TlcSettingsPath }

    # Read first, so an unspecified setting is preserved rather than defaulted.
    $current = Get-TlcSettings -Path $Path

    if ($PSBoundParameters.ContainsKey('Language')) {
        if (-not (Test-TlcLanguageSupported -Language $Language)) {
            throw "Unsupported language '$Language'. Available: $((Get-TlcLanguage | ForEach-Object { $_.Tag }) -join ', ')"
        }
        $current.Language = $Language
    }

    if ($PSBoundParameters.ContainsKey('Theme')) {
        if (-not (Test-TlcThemeSupported -Theme $Theme)) {
            throw "Unsupported theme '$Theme'. Available: $((Get-TlcThemeOption | ForEach-Object { $_.Id }) -join ', ')"
        }
        $current.Theme = $Theme
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Save settings')) {
        $body = [ordered]@{
            Language     = $current.Language
            Theme        = $current.Theme
            UpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        # UTF8Encoding($false) rather than -Encoding utf8: on Windows PowerShell 5.1 the
        # latter writes a BOM, and a BOM ahead of the opening brace makes ConvertFrom-Json
        # fail on the file this module just wrote.
        #
        # Written beside the file and swapped in, not rewritten in place. A wizard opening
        # while another saved could read half a file, fall back to the defaults, and then
        # save those defaults over the real choice (review 2026-09-30, finding 331). A swap
        # that cannot be made falls back to the direct write this always did.
        $json = $body | ConvertTo-Json -Depth 4
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($temp, $json, $encoding)
            # [NullString]::Value, not $null, for the backup name: PowerShell hands $null to a .NET
            # string parameter as an empty string, and Replace then fails on "The path is empty".
            $swapped = $false
            for ($attempt = 0; $attempt -lt 5 -and -not $swapped; $attempt++) {
                try {
                    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) } else { [System.IO.File]::Move($temp, $Path) }
                    $swapped = $true
                } catch {
                    Start-Sleep -Milliseconds 50
                }
            }
            if (-not $swapped) { [System.IO.File]::WriteAllText($Path, $json, $encoding) }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    }

    return $Path
}

Export-ModuleMember -Function Get-TlcSettingsPath, Get-TlcSettings, Set-TlcSettings
