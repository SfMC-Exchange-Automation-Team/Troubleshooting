Set-StrictMode -Version Latest

<#
    Dark mode, driven by the OS rather than by a setting in this window.

    HOW, AND WHY IT IS DONE THIS WAY

    Theme.xaml is EPO's file copied verbatim, and every style in it resolves colours
    through StaticResource. StaticResource is resolved once, at parse time, and the
    brushes it produces are frozen - verified, not assumed: setting Color on one throws
    "Cannot set a property on object because it is in a read-only state". So the usual
    trick of swapping brushes at runtime is not available, and neither is rewriting the
    theme to use DynamicResource without diverging from the file this toolbox
    deliberately keeps identical to its sibling.

    What is left is to patch the palette before the parser sees it. Theme.xaml declares
    all 24 colours in a single block at the top and derives everything else from them,
    so a dark variant is that block with different values. This module writes that
    variant to a temp file and hands the path to Import-TlcXaml, which already accepts
    a -ThemePath. Theme.xaml itself is never modified.

    THE PALETTE IS NOT AN INVERSION

    Inverting a light theme produces grey-on-black mush and status colours that vibrate.
    Surfaces here step 0d1117 / 161b22 / 21262d in the way GitHub and VS Code dark do,
    text sits at 90% rather than pure white to take the glare off, and the status
    colours are lightened rather than flipped: #0F7B3D green is illegible on a dark
    surface, so it becomes #3FB950, and its tint surface becomes a dark translucent
    green instead of the pale mint that would glow.
#>

$script:DarkPalette = [ordered]@{
    # Surfaces, darkest to lightest, so the eye reads depth the same way it does in light.
    CanvasColor          = '#0D1117'
    SurfaceColor         = '#161B22'
    HoverColor           = '#21262D'

    # The banner strip. Already near-black in light mode, lifted slightly here so it
    # does not disappear into the canvas.
    HeaderColor          = '#010409'
    HeaderTextColor      = '#F0F6FC'
    HeaderMutedColor     = '#8B949E'

    BorderColor          = '#30363D'
    BorderStrongColor    = '#484F58'

    # Not pure white: #FFFFFF on a dark surface glares and smears at small sizes.
    TextPrimaryColor     = '#E6EDF3'
    TextSecondaryColor   = '#9DA7B3'

    # The accent is lightened, not kept: #2563EB against #161B22 fails contrast for the
    # button text sitting on it.
    AccentColor          = '#3B82F6'
    AccentHoverColor     = '#60A5FA'
    AccentPressedColor   = '#2563EB'

    OverlayScrimColor    = '#F00D1117'

    # Status pairs. The ink is lightened for legibility and the surface becomes a dark
    # tint rather than a pale wash, which would be the brightest thing on the window.
    PassColor            = '#3FB950'
    PassSurfaceColor     = '#12261E'
    WarningColor         = '#D29922'
    WarningSurfaceColor  = '#2B2113'
    BlockedColor         = '#F85149'
    BlockedSurfaceColor  = '#2D1517'
    NeutralColor         = '#9DA7B3'
    NeutralSurfaceColor  = '#21262D'
    UnknownColor         = '#A371F7'
    UnknownSurfaceColor  = '#231A2E'
}

function Test-TlcDarkMode {
    <#
    .SYNOPSIS
        Reports whether Windows is currently using the dark app theme.
    .DESCRIPTION
        AppsUseLightTheme is what Settings writes when the user picks "Dark" for apps.
        It is deliberately the app value and not SystemUsesLightTheme, which controls
        the taskbar and Start rather than application chrome, and which people commonly
        set differently.

        A missing key means light. The value has existed since Windows 10 1607, but a
        hardened or stripped image can lack it, and defaulting to dark on a machine
        whose theme cannot be read would be the more surprising failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string] $RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    )

    try {
        $value = Get-ItemProperty -Path $RegistryPath -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ([int]$value.AppsUseLightTheme -eq 0)
    } catch {
        Write-Verbose "The app theme could not be read, so light is assumed: $($_.Exception.Message)"
        return $false
    }
}

<#
    The native calls the windows need, compiled once per process as a single type.

    One type rather than one per feature because the compile is the expensive part: a second
    Add-Type costs about half a second on Windows PowerShell 5.1 (measured 419 to 574 ms) and
    the dark title bar already pays for this one on every start. The taskbar identity rides
    along for nothing.

    SetCurrentProcessExplicitAppUserModelID takes the ID by value and copies it. The Get
    counterpart hands back a string the caller owns, allocated with CoTaskMemAlloc, so it is
    read as a pointer and freed here rather than marshalled as a string the runtime would
    free with the wrong allocator.
#>
$script:NativeChromeMembers = @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);

[System.Runtime.InteropServices.DllImport("shell32.dll", PreserveSig = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string appId);

[System.Runtime.InteropServices.DllImport("shell32.dll", PreserveSig = true)]
public static extern int GetCurrentProcessExplicitAppUserModelID(out System.IntPtr appId);
'@

function Initialize-TlcNativeChrome {
    <#
    .SYNOPSIS
        Compiles the shared native type if this process has not, and reports whether it
        carries the member asked for.
    .DESCRIPTION
        A compiled type cannot be replaced or unloaded. A PowerShell session that imported an
        older toolbox keeps the older type, without the members added since, and re-importing
        the module does not change that. Asking by member turns that case into a plain $false
        the caller can explain, instead of a "method not found" from deep inside a call.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Member
    )

    if (-not ('Tlc.NativeChrome' -as [type])) {
        Add-Type -Namespace 'Tlc' -Name 'NativeChrome' -MemberDefinition $script:NativeChromeMembers -ErrorAction Stop
    }
    return ($null -ne ('Tlc.NativeChrome' -as [type]).GetMethod($Member))
}

function Set-TlcWindowDarkChrome {
    <#
    .SYNOPSIS
        Makes the window's title bar follow the app theme.
    .DESCRIPTION
        The caption bar is drawn by the desktop window manager, not by WPF, so a dark theme
        applied to the content leaves a white title bar sitting on top of it. There is no
        XAML for this: it is DwmSetWindowAttribute with DWMWA_USE_IMMERSIVE_DARK_MODE.

        The attribute number moved. It is 20 on Windows 11 and Windows 10 build 18985 and
        later, and was 19 on builds 17763 to 18984. Both are tried rather than reading the
        build number, because the build-to-attribute mapping is undocumented at the edges
        and a wrong guess fails the same way an unsupported call does.

        Call it before the window is shown. Applied afterwards the caption is already
        painted, and Windows does not reliably redraw it.

        Any failure is swallowed and reported as $false. A light title bar on a dark window
        is untidy; a tool that will not open is not.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Window,
        [bool] $Dark
    )

    try {
        if (-not (Initialize-TlcNativeChrome -Member 'DwmSetWindowAttribute')) {
            Write-Verbose 'The native helper in this session predates the title bar call; restart PowerShell to theme it.'
            return $false
        }

        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        if ($handle -eq [System.IntPtr]::Zero) {
            Write-Verbose 'The window has no handle yet, so the title bar cannot be themed.'
            return $false
        }

        $value = if ($Dark) { 1 } else { 0 }

        # 20 first: it is the current attribute, so the older number is only reached on an
        # OS that genuinely needs it rather than being tried on every call.
        foreach ($attribute in 20, 19) {
            $result = [Tlc.NativeChrome]::DwmSetWindowAttribute($handle, $attribute, [ref] $value, 4)
            if ($result -eq 0) { return $true }
        }

        Write-Verbose 'The desktop window manager refused both dark-mode attributes.'
        return $false
    } catch {
        Write-Verbose "The title bar could not be themed: $($_.Exception.Message)"
        return $false
    }
}

function Set-TlcProcessAppId {
    <#
    .SYNOPSIS
        Gives this process its own taskbar identity, so its windows stop grouping with PowerShell.
    .DESCRIPTION
        Windows groups taskbar buttons by AppUserModelID. A process that never sets one is
        identified by its executable, and the toolbox's executable is powershell.exe: its
        window shared a button with every PowerShell console, and pinning it pinned
        PowerShell. With an explicit ID the window gets a button of its own, drawn from its
        own icon, and a Start menu shortcut carrying the same ID (Install-TlcShortcut) is
        what Windows then ties it to for pinning and relaunch. Finding 341.

        It has to happen before the first window is shown: the taskbar reads the ID when a
        button is created and does not re-read it for windows already open. The launcher
        calls it straight after importing the module.

        The ID is at most 128 characters with no spaces, which is the documented limit; a
        longer one is refused by Windows with E_INVALIDARG, and is refused here first.

        Decoration: any failure is reported as $false and the toolbox opens grouped with
        PowerShell, exactly as it did before this existed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidatePattern('^\S{1,128}$')] [string] $AppId
    )

    try {
        if (-not (Initialize-TlcNativeChrome -Member 'SetCurrentProcessExplicitAppUserModelID')) {
            Write-Verbose 'The native helper in this session predates the taskbar identity; restart PowerShell to set it.'
            return $false
        }
        $result = [Tlc.NativeChrome]::SetCurrentProcessExplicitAppUserModelID($AppId)
        if ($result -ne 0) {
            Write-Verbose ('Windows refused the taskbar identity: 0x{0:X8}' -f $result)
            return $false
        }
        return $true
    } catch {
        Write-Verbose "The taskbar identity could not be set: $($_.Exception.Message)"
        return $false
    }
}

function Get-TlcProcessAppId {
    <#
    .SYNOPSIS
        The taskbar identity this process has set, or an empty string when it has none.
    .DESCRIPTION
        Windows answers with an error rather than an empty value when no explicit ID was set,
        and that is the normal state of any PowerShell process the launcher did not start, so
        it is reported as empty rather than as a failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        if (-not (Initialize-TlcNativeChrome -Member 'GetCurrentProcessExplicitAppUserModelID')) { return '' }
        $pointer = [System.IntPtr]::Zero
        $result = [Tlc.NativeChrome]::GetCurrentProcessExplicitAppUserModelID([ref] $pointer)
        if ($result -ne 0 -or $pointer -eq [System.IntPtr]::Zero) { return '' }
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
        } finally {
            [System.Runtime.InteropServices.Marshal]::FreeCoTaskMem($pointer)
        }
    } catch {
        Write-Verbose "The taskbar identity could not be read: $($_.Exception.Message)"
        return ''
    }
}

function ConvertTo-TlcDarkThemeXaml {
    <#
    .SYNOPSIS
        Rewrites a theme's colour block with the dark palette.
    .DESCRIPTION
        Only the <Color x:Key="..."> declarations are touched. Everything else in the
        file - every brush, template and trigger - derives from those, so the rest of
        the theme is carried through byte for byte and cannot drift from the light one.

        A key in the file that this module has no dark value for is left alone rather
        than guessed at, and reported through -Verbose. That way a colour added to the
        theme later degrades to its light value instead of vanishing.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [string] $Xaml,
        [System.Collections.IDictionary] $Palette
    )

    if (-not $Palette) { $Palette = $script:DarkPalette }

    # Counted with a local list rather than a script-scoped variable incremented inside
    # the evaluator: a MatchEvaluator scriptblock does not reliably share scope with its
    # caller, and a counter that silently stays zero would make the caller fall back to
    # the light theme having already produced a perfectly good dark one.
    $substituted = [System.Collections.Generic.List[string]]::new()

    $result = [regex]::Replace(
        $Xaml,
        '<Color x:Key="(?<key>\w+)">(?<value>[^<]*)</Color>',
        {
            param($match)
            $key = $match.Groups['key'].Value
            if ($Palette.Contains($key)) {
                $substituted.Add($key)
                return "<Color x:Key=""$key"">$($Palette[$key])</Color>"
            }
            Write-Verbose "No dark value for $key, so its light value is kept."
            return $match.Value
        })

    return [pscustomobject]@{
        Xaml        = $result
        Substituted = @($substituted)
    }
}

function Get-TlcThemePath {
    <#
    .SYNOPSIS
        Returns the theme file the wizard should load.
    .DESCRIPTION
        The light theme is returned as-is. For dark, a patched copy is written beside
        the user's other local state and that path returned instead.

        Written to LOCALAPPDATA rather than beside the toolbox: the toolbox is routinely
        run from a share or a read-only folder, and a feature that cannot fail should
        not be the thing that needs write access to the install location.

        Any failure falls back to the light theme. A window in the wrong colours is a
        cosmetic problem; a window that will not open is not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $LightThemePath,
        [switch] $ForceDark,
        [switch] $ForceLight
    )

    if (-not (Test-Path -LiteralPath $LightThemePath)) {
        throw "Theme file was not found: $LightThemePath"
    }

    $dark = if ($ForceDark) { $true } elseif ($ForceLight) { $false } else { Test-TlcDarkMode }
    if (-not $dark) { return $LightThemePath }

    try {
        $xaml = Get-Content -LiteralPath $LightThemePath -Raw -ErrorAction Stop
        $converted = ConvertTo-TlcDarkThemeXaml -Xaml $xaml

        if (@($converted.Substituted).Count -eq 0) {
            Write-Verbose 'No colours were substituted, so the light theme is used unchanged.'
            return $LightThemePath
        }

        $folder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TLC-Toolbox'
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }

        # Regenerated every launch rather than cached. It is a few milliseconds, and a
        # stale copy left behind by an older build is a bug that would only show up as
        # colours that do not match the current theme.
        #
        # Written beside the file and swapped in, not rewritten in place: two wizards opening
        # together could otherwise load each other's half-written copy and fail to parse it
        # (review 2026-09-30, finding 331). A swap that cannot be made falls back to the
        # direct write this always did.
        $darkPath = Join-Path $folder 'Theme.Dark.xaml'
        $temp = "$darkPath.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($temp, $converted.Xaml, (New-Object System.Text.UTF8Encoding($true)))
            # [NullString]::Value, not $null, for the backup name: PowerShell hands $null to a .NET
            # string parameter as an empty string, and Replace then fails on "The path is empty".
            $swapped = $false
            for ($attempt = 0; $attempt -lt 5 -and -not $swapped; $attempt++) {
                try {
                    if (Test-Path -LiteralPath $darkPath) { [System.IO.File]::Replace($temp, $darkPath, [System.Management.Automation.Language.NullString]::Value) } else { [System.IO.File]::Move($temp, $darkPath) }
                    $swapped = $true
                } catch {
                    Start-Sleep -Milliseconds 50
                }
            }
            if (-not $swapped) { [System.IO.File]::WriteAllText($darkPath, $converted.Xaml, (New-Object System.Text.UTF8Encoding($true))) }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }

        return $darkPath
    } catch {
        Write-Verbose "The dark theme could not be prepared, so the light theme is used: $($_.Exception.Message)"
        return $LightThemePath
    }
}

Export-ModuleMember -Function Test-TlcDarkMode, ConvertTo-TlcDarkThemeXaml, Get-TlcThemePath, Set-TlcWindowDarkChrome, Set-TlcProcessAppId, Get-TlcProcessAppId
