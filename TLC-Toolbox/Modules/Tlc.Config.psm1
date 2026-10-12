Set-StrictMode -Version Latest

$script:RequiredSections = @('StageAwareness', 'Scope', 'Collection', 'Privacy', 'Thresholds')

# Allowlists combined across overlays rather than replaced by the last one. See
# Merge-TlcLocalConfig. Finding 323.
$script:CombinedOverlayKeys = @('Privacy.KnownAccountIds', 'Privacy.KnownTenantIds')


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
function Import-TlcConfig {
    <#
    .SYNOPSIS
        Loads and validates the toolbox configuration data file.
    .DESCRIPTION
        Mirrors the EPO-Toolbox contract: a PowerShell data file, resolved relative
        to the toolbox root when a bare name is supplied, validated up front so a
        missing key fails at load rather than midway through a collection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    try {
        $config = Import-TlcDataFile -Path $ConfigPath -ErrorAction Stop
    } catch {
        throw "Configuration file could not be parsed: $ConfigPath. $($_.Exception.Message)"
    }

    $missing = $script:RequiredSections | Where-Object { -not $config.ContainsKey($_) }
    if ($missing) {
        throw "Configuration is missing required section(s): $($missing -join ', ')"
    }

    $stageOrder = $config.StageAwareness.StageOrder
    if (-not $stageOrder -or $stageOrder.Count -eq 0) {
        throw 'Configuration StageAwareness.StageOrder must list at least one stage.'
    }

    $config['ConfigPath'] = (Resolve-Path -LiteralPath $ConfigPath).Path
    return $config
}

function Merge-TlcLocalConfig {
    <#
    .SYNOPSIS
        Applies an operator's local configuration overlay on top of the shipped config.
    .DESCRIPTION
        The shipped config is a template that travels to customers, so it must never
        carry anybody's identifiers. Finding 2 records what happens when it does:
        Plan.json rides inside the handover bundle carrying EffectiveConfig.Privacy, so
        one engagement's account ids end up in the next customer's evidence.

        But Privacy.KnownAccountIds only does its job when it is filled in, and an
        engineer's own ids are the same on every case. Those two facts pull in opposite
        directions, and the resolution is a second file - TeamsLogCollection.local.psd1
        beside the shipped one - that is absent from the manifest's FileList and so
        cannot be packaged.

        It is an OVERLAY, not a replacement. A replacement would have to restate
        Collection and Thresholds in full and would then drift from the shipped file
        every time that changed, which is a slower version of the same bug. Only the
        keys present in the local file are overridden, one level into each section, so a
        local Privacy block can set KnownAccountIds without also having to repeat
        MaxScanBytesPerFile.

        Called once per overlay: the one beside the shipped config, then the per-user one
        the wizard's Declare button writes (Get-TlcUserConfigPath). The allowlists are the
        exception to "later wins": Privacy.KnownAccountIds and Privacy.KnownTenantIds are
        COMBINED across files, because each file declares accounts that are expected here
        and a later file replacing an earlier one would quietly un-declare them. Finding 323.

        Returns the config unchanged when no local file exists, which is the normal case
        on a customer machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Config,
        [Parameter(Mandatory)] [string] $LocalPath
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) { return $Config }

    try {
        $local = Import-TlcDataFile -Path $LocalPath -ErrorAction Stop
    } catch {
        throw "Local configuration overlay could not be parsed: $LocalPath. $($_.Exception.Message)"
    }

    $applied = [System.Collections.Generic.List[string]]::new()

    foreach ($section in $local.Keys) {
        $value = $local[$section]

        # A section the shipped config does not have, or a scalar, replaces outright.
        # Only hashtable-over-hashtable merges key by key.
        if (($value -is [System.Collections.IDictionary]) -and ($Config.Contains($section)) -and
            ($Config[$section] -is [System.Collections.IDictionary])) {
            foreach ($key in $value.Keys) {
                if ("$section.$key" -in $script:CombinedOverlayKeys -and $Config[$section].Contains($key)) {
                    $combined = [System.Collections.Generic.List[string]]::new()
                    foreach ($item in @(@($Config[$section][$key]) + @($value[$key]))) {
                        $text = [string]$item
                        if (-not $text) { continue }
                        if (@($combined | Where-Object { $_ -ieq $text }).Count -eq 0) { $combined.Add($text) }
                    }
                    $Config[$section][$key] = @($combined)
                } else {
                    $Config[$section][$key] = $value[$key]
                }
                $applied.Add("$section.$key")
            }
        } else {
            $Config[$section] = $value
            $applied.Add($section)
        }
    }

    # Recorded so a run can say which settings came from an unshipped file. A value that
    # differs from the shipped template and cannot be traced is the kind of thing that
    # wastes an hour when a bundle is examined later. Accumulated, because there can be two.
    $Config['LocalOverlayPath'] = @(@($Config['LocalOverlayPath']) + (Resolve-Path -LiteralPath $LocalPath).Path | Where-Object { $_ })
    $Config['LocalOverlayKeys'] = @(@(@($Config['LocalOverlayKeys']) + @($applied)) | Where-Object { $_ } | Select-Object -Unique)

    return $Config
}

function Get-TlcUserConfigPath {
    <#
    .SYNOPSIS
        Where the per-user overlay lives: TeamsLogCollection.local.psd1 in the user's
        %LOCALAPPDATA%\TLC-Toolbox, beside Settings.json and the case history.
    .DESCRIPTION
        The wizard's "Declare these accounts" button writes here. It used to write into the
        toolbox's own Config folder, which broke two promises: the README says nothing is
        written into the toolbox folder so it can run from a read-only share, where declaring
        failed and the privacy gate then refused every package; and a copy extracted into a
        shared or synced folder carried the declared account ids to everyone that folder
        reached. Measured 2026-09-29: the test user's copy was extracted inside a OneDrive share.
        Finding 323.

        Not created here. Add-TlcKnownAccountId creates the folder when it writes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)

    if (-not $Root) {
        $Root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TLC-Toolbox'
    }
    return (Join-Path $Root 'TeamsLogCollection.local.psd1')
}

function Get-TlcLocalConfigPath {
    <#
    .SYNOPSIS
        Where an operator's local overlay lives, whether or not it exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )

    return (Join-Path (Join-Path $ToolboxRoot 'Config') 'TeamsLogCollection.local.psd1')
}

function Resolve-TlcPath {
    <#
    .SYNOPSIS
        Expands %VAR% style placeholders used in the configuration file.
    .DESCRIPTION
        The config stores paths with Windows environment placeholders so one file
        works for every user. Expansion happens at use time, not load time, because
        a collection may target a different profile than the one running the tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return [System.Environment]::ExpandEnvironmentVariables($Path)
}

function Protect-TlcConfigValue {
    <#
    .SYNOPSIS
        Masks a configured identifier before it is written into evidence.
    .DESCRIPTION
        Uses the privacy module's masker when it is loaded so a value masks the same
        way here as it does in the identity inventory. Falls back to a flat marker
        rather than the raw value, because this module has to stay independently
        importable and the safe failure is to say less, not more.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $masker = Get-Command -Name 'Protect-TlcIdentifier' -ErrorAction SilentlyContinue
    if ($masker) { return (& $masker -Value $Value) }
    return 'redacted'
}

function Get-TlcEffectiveConfig {
    <#
    .SYNOPSIS
        Produces the resolved configuration recorded in Plan.json.
    .DESCRIPTION
        Command line values win over the data file. Capturing the merged result as
        evidence is what makes a run reproducible: the bundle shows the settings
        actually used, not the settings the file happened to hold afterwards.

        The privacy section is deliberately not copied through. Plan.json ships inside
        the handover bundle, and the raw section holds KnownAccountIds, KnownTenantIds,
        HomeTenantId and ConsentGrantedBy - identifiers belonging to whoever the
        engineer has configured the tool for previously. A config file is exactly the
        kind of thing that accumulates entries across customers, so copying it verbatim
        would put one organisation's identifiers into another's bundle.

        That is the disclosure the privacy gate exists to prevent, and the gate cannot
        catch it: it inspects collected evidence, not configuration. Meanwhile the
        identity inventory goes to the trouble of masking every UPN it discovers, so
        republishing the allowlist in clear in the same bundle is also simply
        inconsistent.

        What a reader actually needs from this is which rules were in force, and how
        many entries the allowlists held - both of which survive masking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [string] $OutputRoot,
        [string] $Scenario
    )

    $runRoot = if ($OutputRoot) { $OutputRoot } else { $Config.RunRoot }
    $resolvedRunRoot = Resolve-TlcPath -Path $runRoot
    # Normalised once, here, because every run path is built from it. A doubled separator -
    # "X:\\runs", which is what joining a drive root and "\runs" produces - was accepted by
    # Collect and then crashed Package: Windows PowerShell 5.1's Split-Path -Parent returns an
    # EMPTY string for "X:\\runs\<id>" (7 returns the parent), and the bundle path is built
    # from it. Found while simulating a full disk on a mounted volume. Rooted paths only, so a
    # relative root still means what it meant before. Finding 310.
    if ($resolvedRunRoot -and [System.IO.Path]::IsPathRooted($resolvedRunRoot)) {
        $resolvedRunRoot = [System.IO.Path]::GetFullPath($resolvedRunRoot)
    }
    $privacy = $Config.Privacy

    $safePrivacy = [ordered]@{
        RequireConsent        = $privacy.RequireConsent
        BlockOnUnknownAccount = $privacy.BlockOnUnknownAccount
        ScrubUpn              = $privacy.ScrubUpn
        MaxScanBytesPerFile   = $privacy.MaxScanBytesPerFile
        ConsentGrantedBy      = Protect-TlcConfigValue -Value ([string]$privacy.ConsentGrantedBy)
        HomeTenantId          = Protect-TlcConfigValue -Value ([string]$privacy.HomeTenantId)
        KnownAccountIdCount   = @($privacy.KnownAccountIds).Count
        KnownAccountIds       = @(@($privacy.KnownAccountIds) | ForEach-Object { Protect-TlcConfigValue -Value ([string]$_) })
        KnownTenantIdCount    = @($privacy.KnownTenantIds).Count
        KnownTenantIds        = @(@($privacy.KnownTenantIds) | ForEach-Object { Protect-TlcConfigValue -Value ([string]$_) })
    }

    return [ordered]@{
        CustomerName   = $Config.CustomerName
        Environment    = $Config.Environment
        ConfigPath     = $Config.ConfigPath
        RunRoot        = $resolvedRunRoot
        Scenario       = $Scenario
        StageOrder     = @($Config.StageAwareness.StageOrder)
        Collection     = $Config.Collection
        Privacy        = $safePrivacy
        Thresholds     = $Config.Thresholds
        # Which settings came from an unshipped overlay, so a value that differs from the
        # template can be traced. Counted and named, never pathed: the per-user overlay's path
        # carries the Windows user name, and Plan.json ships. Finding 323.
        LocalOverlayCount = @(@($Config['LocalOverlayPath']) | Where-Object { $_ }).Count
        LocalOverlayKeys  = @(@($Config['LocalOverlayKeys']) | Where-Object { $_ })
    }
}

function ConvertTo-TlcDataLiteral {
    <#
        One value as PowerShell data-file text, so a rewritten overlay reads back as it was:
        strings single-quoted with apostrophes doubled, booleans and $null as themselves,
        numbers in invariant form, and lists and sections recursively. The overlay writer used
        to quote every value and drop anything nested (review 2026-09-30, finding 331).
    #>
    param($Value, [int] $Depth = 0)

    $pad = '    ' * ($Depth + 1)
    $close = '    ' * $Depth
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { return "`$$($Value.ToString().ToLowerInvariant())" }
    if ($Value -is [string] -or $Value -is [char]) { return "'" + ([string]$Value).Replace("'", "''") + "'" }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([System.IFormattable]$Value).ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('@{')
        foreach ($key in $Value.Keys) {
            $name = [string]$key
            if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $name = "'" + $name.Replace("'", "''") + "'" }
            $lines.Add("$pad$name = $(ConvertTo-TlcDataLiteral -Value $Value[$key] -Depth ($Depth + 1))")
        }
        $lines.Add("$close}")
        return ($lines -join [Environment]::NewLine)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($item in $Value) { "$pad$(ConvertTo-TlcDataLiteral -Value $item -Depth ($Depth + 1))" })
        if ($items.Count -eq 0) { return '@()' }
        return (@('@(') + $items + @("$close)")) -join [Environment]::NewLine
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Add-TlcKnownAccountId {
    <#
    .SYNOPSIS
        Adds account object ids to Privacy.KnownAccountIds in the local overlay.
    .DESCRIPTION
        The privacy gate refuses to package evidence for an account it does not recognise,
        and a fresh machine recognises none - the overlay holding them is deliberately
        excluded from every package, so it cannot travel. That is correct, and it means
        every new machine starts blocked with a Notepad task standing between the operator
        and a bundle they have already collected.

        This is that task, done by the tool. It is invoked from a button the operator
        presses, never automatically: writing somebody's account ids onto a machine is a
        disclosure decision and belongs to them, not to a default.

        IT REWRITES THE FILE FROM PARSED DATA, so hand-written comments in an existing
        overlay do not survive. That is why an existing file is COPIED TO A .bak FIRST,
        with a timestamp - the operation is then recoverable, which is the honest way to
        ship something lossy rather than pretending it is not.

        Existing keys are preserved. An overlay holding KnownTenantIds and HomeTenantId
        keeps both; only KnownAccountIds is touched, and only by union, so pressing the
        button twice adds nothing the second time.

        Written WITHOUT a BOM when the content is ASCII, the ordinary all-guid case, and WITH
        one when a preserved value is not: the file is read by Import-PowerShellDataFile on
        both editions, and a BOM-less UTF-8 file with accented characters is the one shape
        Windows PowerShell 5.1 reads through the ANSI codepage. Every existing value is written
        back in its own type (finding 331), and a rewrite that does not read back is replaced
        by the backup rather than left in place.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] [string] $LocalPath,
        # AllowEmptyString as well as AllowEmptyCollection: a caller assembling ids from a
        # file or a parsed document can legitimately hand over an array with a blank in it,
        # and a parameter-binding failure there would be a worse answer than filtering it.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $AccountId
    )

    $result = [ordered]@{
        Path = $LocalPath; Added = @(); AlreadyPresent = @(); BackupPath = ''; Written = $false
    }

    # Only well-formed guids. The ids come from app_settings.json, but this writes a file the
    # privacy gate trusts, so a malformed entry would silently widen what the gate accepts.
    $candidates = @($AccountId | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } |
                    Where-Object { $_ -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' })
    if ($candidates.Count -eq 0) { return $result }

    $existing = [ordered]@{}
    if (Test-Path -LiteralPath $LocalPath) {
        try {
            $loaded = Import-TlcDataFile -Path $LocalPath
            foreach ($key in $loaded.Keys) { $existing[$key] = $loaded[$key] }
        } catch {
            throw "The existing overlay at $LocalPath could not be read, so it was not changed: $($_.Exception.Message)"
        }
    }

    $privacy = [ordered]@{}
    if ($existing.Contains('Privacy') -and $existing['Privacy'] -is [System.Collections.IDictionary]) {
        foreach ($key in $existing['Privacy'].Keys) { $privacy[$key] = $existing['Privacy'][$key] }
    }

    $known = @(@($privacy['KnownAccountIds']) | Where-Object { $_ })
    foreach ($id in $candidates) {
        if ($known -contains $id) { $result.AlreadyPresent += $id } else { $known += $id; $result.Added += $id }
    }
    if (@($result.Added).Count -eq 0) { return $result }

    if (-not $PSCmdlet.ShouldProcess($LocalPath, "Add $(@($result.Added).Count) account id(s) to Privacy.KnownAccountIds")) {
        return $result
    }

    $privacy['KnownAccountIds'] = @($known)
    $existing['Privacy'] = $privacy

    # The per-user folder may not exist yet on a machine that has never saved a setting.
    $parent = Split-Path -Parent $LocalPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $LocalPath) {
        # Never an existing name. Stamped to the second, two presses of the button inside one
        # second wrote the second backup over the first, and the first was the only copy of
        # the hand-written original (review 2026-09-30, finding 331).
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $backup = "$LocalPath.$stamp.bak"
        $suffix = 1
        while (Test-Path -LiteralPath $backup) { $backup = "$LocalPath.$stamp-$suffix.bak"; $suffix++ }
        # A failed copy leaves a partial file behind, which here would be a truncated
        # overlay sitting next to the real one looking like a usable backup. Removing it on
        # failure is what makes "the previous file was copied to..." true or absent, never
        # half true.
        try {
            Copy-Item -LiteralPath $LocalPath -Destination $backup -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            throw "The overlay could not be backed up, so it was not changed: $($_.Exception.Message)"
        }
        $result.BackupPath = $backup
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# LOCAL OVERLAY - this machine only, never packaged.')
    $lines.Add('#')
    $lines.Add('# It holds identifiers, so it lives outside the files the toolbox ships: here in')
    $lines.Add('# %LOCALAPPDATA%\TLC-Toolbox, where the Declare these accounts button writes, or beside')
    $lines.Add('# the shipped config as Config\TeamsLogCollection.local.psd1, which FileList excludes.')
    $lines.Add("# Last written by the toolbox on $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)).")
    # Every key, whatever its shape, through one literal writer - see ConvertTo-TlcDataLiteral.
    $lines.Add((ConvertTo-TlcDataLiteral -Value $existing))
    $text = ($lines -join [Environment]::NewLine) + [Environment]::NewLine

    # A BOM only when something needs one. Windows PowerShell 5.1 reads a BOM-less file
    # through the ANSI codepage, so a preserved value with an accented character would come
    # back altered; an all-ASCII file, the ordinary all-guid case, stays BOM-less.
    $needsBom = $text -match '[^\x00-\x7F]'

    try {
        [System.IO.File]::WriteAllText($LocalPath, $text, (New-Object System.Text.UTF8Encoding($needsBom)))

        # Read it back. Compress-Archive taught this project that a write reporting success is
        # not a write that produced a readable file, and this one feeds the privacy gate.
        $check = Import-TlcDataFile -Path $LocalPath
        foreach ($id in $result.Added) {
            if (@($check.Privacy.KnownAccountIds) -notcontains $id) {
                throw "The overlay was written but does not contain $id when read back."
            }
        }
    } catch {
        # A rewrite that cannot be read back is put back as it was. Left in place it stops every
        # later run loading its configuration, which is worse than the declaration not landing.
        if ($result.BackupPath -and (Test-Path -LiteralPath $result.BackupPath)) {
            Copy-Item -LiteralPath $result.BackupPath -Destination $LocalPath -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $LocalPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    $result.Written = $true
    return $result
}

Export-ModuleMember -Function Import-TlcDataFile, Import-TlcConfig, Resolve-TlcPath, Get-TlcEffectiveConfig, Protect-TlcConfigValue, Merge-TlcLocalConfig, Get-TlcLocalConfigPath, Get-TlcUserConfigPath, Add-TlcKnownAccountId



