Set-StrictMode -Version Latest

<#
    Shared UI infrastructure.

    Mirrors Epo.Ui.psm1. XAML is loaded with XamlReader, so the markup cannot carry
    x:Class or event handler attributes - elements are named in the XAML and wired
    up from code afterwards. Get-TlcUiElement is what makes that safe: it fails
    loudly when a name used in code no longer exists in the markup, rather than
    handing back a null that surfaces later as a confusing property error.
#>

$script:UiInitialized = $false

function Initialize-TlcUi {
    <#
    .SYNOPSIS
        Loads the WPF assemblies once per session.
    #>
    [CmdletBinding()]
    param()

    if ($script:UiInitialized) { return }

    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    Add-Type -AssemblyName System.Xaml -ErrorAction Stop

    $script:UiInitialized = $true
}

function Get-TlcUiRoot {
    <#
    .SYNOPSIS
        Returns the folder holding the XAML files.
    #>
    [CmdletBinding()]
    param()
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'Ui')
}

$script:IconImage = $null

function Get-TlcIconPath {
    <#
    .SYNOPSIS
        The toolbox icon: Assets\TLC-Toolbox.ico beside the modules.
    .DESCRIPTION
        One place names the file, because three things use it: every window's title bar and
        taskbar button, the Start menu and desktop shortcuts, and the tests that hold the
        package to shipping it. Drawn by Tools\New-TlcIcon.ps1, which is its source.

        -ToolboxRoot names a copy other than this one, for a shortcut made to point at it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ToolboxRoot = (Split-Path -Parent $PSScriptRoot)
    )
    return (Join-Path $ToolboxRoot 'Assets\TLC-Toolbox.ico')
}

function Set-TlcWindowIcon {
    <#
    .SYNOPSIS
        Puts the toolbox icon on a window's title bar and taskbar button.
    .DESCRIPTION
        A WPF window with no icon of its own shows the icon of the process hosting it, which
        here is PowerShell's: every toolbox window looked like a console, and in the taskbar
        it could not be told apart from one. Finding 341.

        Loaded once, completely (OnLoad, so the file is not held open), and frozen so every
        window shares the one image. WPF picks the frame for each place from the icon's own
        sizes, so the title bar gets the 16-pixel drawing and the taskbar the 32, rather than
        one image scaled to both.

        Decoration: any failure is reported as $false and the window opens without it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Window
    )

    try {
        if ($null -eq $script:IconImage) {
            $path = Get-TlcIconPath
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Verbose "The toolbox icon is missing at $path, so the window keeps PowerShell's."
                return $false
            }
            $image = [System.Windows.Media.Imaging.BitmapFrame]::Create(([uri]$path),
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            if ($image.CanFreeze) { $image.Freeze() }
            $script:IconImage = $image
        }
        $Window.Icon = $script:IconImage
        return $true
    } catch {
        Write-Verbose "The window icon could not be set: $($_.Exception.Message)"
        return $false
    }
}

function ConvertTo-TlcXamlUri {
    <#
    .SYNOPSIS
        Renders a file path as a URI a merged resource dictionary can resolve.
    .DESCRIPTION
        Markup parsed from a string has no BaseUri, so a relative Source in a merged
        dictionary cannot be resolved. An absolute file URI is used instead.

        The result is XML-escaped because it is substituted into markup as text, not
        bound as a value. Uri.AbsoluteUri percent-encodes spaces but leaves '&' alone -
        it is a legal URI character - and a bare '&' in an attribute is malformed XML.
        A toolbox unpacked under, say, C:\R&D\ therefore failed to open at all, with
        "'%' is an unexpected token" pointing at the substituted URI rather than at the
        folder name that caused it. Ampersands are legal in Windows folder names and
        this tool is meant to be copied wherever the engagement needs it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    return [System.Security.SecurityElement]::Escape(([uri]$full).AbsoluteUri)
}

function ConvertTo-TlcTeamsThemeXaml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Xaml)

    $theme = [xml]$Xaml
    $namespaces = [System.Xml.XmlNamespaceManager]::new($theme.NameTable)
    $namespaces.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $accent = $theme.SelectSingleNode('/w:ResourceDictionary/w:Color[@x:Key="AccentColor"]', $namespaces)
    $canvas = $theme.SelectSingleNode('/w:ResourceDictionary/w:Color[@x:Key="CanvasColor"]', $namespaces)
    if ($null -eq $accent -or $null -eq $canvas) { throw 'The theme is missing its accent or canvas color.' }
    $linkColor = [System.Windows.Media.ColorConverter]::ConvertFromString($accent.InnerText)
    $canvasColor = [System.Windows.Media.ColorConverter]::ConvertFromString($canvas.InnerText)
    $dark = (0.299 * $canvasColor.R + 0.587 * $canvasColor.G + 0.114 * $canvasColor.B) -lt 128
    $palette = @{
        AccentColor = $(if ($dark) { '#A6A7E8' } else { '#6264A7' })
        AccentHoverColor = '#57599B'
        AccentPressedColor = '#4B4D87'
    }
    if (-not $dark) { $palette.HoverColor = '#F0F0F7' }
    foreach ($key in $palette.Keys) {
        $color = $theme.SelectSingleNode("/w:ResourceDictionary/w:Color[@x:Key='$key']", $namespaces)
        if ($null -eq $color) { throw "The theme is missing $key." }
        $color.InnerText = $palette[$key]
    }

    # The shared theme freezes StaticResource brushes; recolor before parsing, not afterwards.
    $firstStyle = $theme.SelectSingleNode('/w:ResourceDictionary/w:Style', $namespaces)
    if ($null -eq $firstStyle) { throw 'The theme contains no control styles.' }
    foreach ($resource in @(
        @{ Key = 'LinkBrush'; Color = $linkColor.ToString() }
        @{ Key = 'ButtonAccentBrush'; Color = '#6264A7' }
    )) {
        $brush = $theme.CreateElement('SolidColorBrush', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $keyAttribute = $theme.CreateAttribute('x', 'Key', 'http://schemas.microsoft.com/winfx/2006/xaml')
        $keyAttribute.Value = $resource.Key
        $null = $brush.Attributes.Append($keyAttribute)
        $brush.SetAttribute('Color', $resource.Color)
        $null = $theme.DocumentElement.InsertBefore($brush, $firstStyle)
    }
    $background = $theme.SelectSingleNode('/w:ResourceDictionary/w:Style[@x:Key="PrimaryButton"]/w:Setter[@Property="Background"]', $namespaces)
    if ($null -eq $background) { throw 'The theme is missing its primary-button background.' }
    $background.SetAttribute('Value', '{StaticResource ButtonAccentBrush}')
    return $theme.OuterXml
}

function Import-TlcXaml {
    <#
    .SYNOPSIS
        Loads a XAML file, substituting the theme URI placeholder, and returns the root object.
    .DESCRIPTION
        The merged dictionary placeholder is replaced with the prepared theme in memory.
        Teams-purple accents and blue links are separated before StaticResource lookups
        are frozen. The shared theme file and its dark counterpart stay unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $ThemePath
    )

    Initialize-TlcUi

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "XAML file was not found: $Path"
    }

    $xaml = Get-Content -LiteralPath $Path -Raw
    $markup = [xml]$xaml

    if ($xaml -match '__THEME_URI__') {
        if ([string]::IsNullOrWhiteSpace($ThemePath)) {
            $ThemePath = Join-Path (Split-Path -Parent $Path) 'Theme.xaml'
        }
        if (-not (Test-Path -LiteralPath $ThemePath)) {
            throw "Theme file was not found: $ThemePath"
        }
        $namespaces = [System.Xml.XmlNamespaceManager]::new($markup.NameTable)
        $namespaces.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
        $dictionaries = @($markup.SelectNodes('//w:ResourceDictionary[@Source="__THEME_URI__"]', $namespaces))
        if (-not $dictionaries.Count) { throw 'The window has no theme dictionary placeholder.' }
        $theme = [xml](ConvertTo-TlcTeamsThemeXaml -Xaml (Get-Content -LiteralPath $ThemePath -Raw -ErrorAction Stop))
        foreach ($dictionary in $dictionaries) {
            $prepared = $markup.ImportNode($theme.DocumentElement, $true)
            $null = $dictionary.ParentNode.ReplaceChild($prepared, $dictionary)
        }
    }

    $reader = New-Object System.Xml.XmlNodeReader $markup
    try {
        $loaded = [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }

    # Every window the toolbox builds from markup passes through here, so this is the one
    # place that gives them all the toolbox icon. The two windows built in code set it
    # themselves.
    if ($loaded -is [System.Windows.Window]) { $null = Set-TlcWindowIcon -Window $loaded }
    return $loaded
}

function Get-TlcUiElement {
    <#
    .SYNOPSIS
        Finds named elements in a loaded window and returns them as a lookup hashtable.
    .DESCRIPTION
        Returning a hashtable rather than requiring a FindName call per control keeps
        the wiring code readable, and fails loudly when a name in the code no longer
        exists in the XAML - which is the failure that would otherwise appear much
        later as a null property access.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.FrameworkElement] $Root,
        [Parameter(Mandatory)] [string[]] $Name
    )

    $elements = @{}
    $missing = New-Object System.Collections.Generic.List[string]

    foreach ($item in $Name) {
        $element = $Root.FindName($item)
        if ($null -eq $element) { $missing.Add($item) } else { $elements[$item] = $element }
    }

    if ($missing.Count) {
        throw "The XAML does not contain element(s): $($missing -join ', ')"
    }

    return $elements
}

function Sync-TlcUiPaint {
    <#
    .SYNOPSIS
        Lets the window repaint during a long synchronous operation.
    .DESCRIPTION
        Lets pending layout and render work finish before the caller reads or acts on
        the result. Pumping the dispatcher at Background priority runs everything queued
        at Layout priority and above, without introducing a second thread.

        It was written when a collection ran on the UI thread and the window greyed out
        for its duration. The run is a child process now, so that is no longer why it is
        here - what it is used for is ordering: swapping a panel and then measuring or
        scrolling to it needs the layout pass in between, or the measurement is of the
        old arrangement.
    #>
    [CmdletBinding()]
    param()

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $callback = [System.Windows.Threading.DispatcherOperationCallback] {
        param($state)
        $state.Continue = $false
        return $null
    }
    $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $callback, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Set-TlcUiBanner {
    <#
    .SYNOPSIS
        Points an Image at the shipped TLC banner.
    .DESCRIPTION
        Mirrors Set-EpoUiLogo, including the reasoning. The markup is parsed from a
        string by XamlReader, which leaves the tree with no BaseUri, so a relative
        Source in the XAML resolves against the process directory and silently comes
        back empty. The path is built here instead.

        Read with CacheOption OnLoad so the handle closes immediately. The default
        streams the file on demand and keeps the asset locked for the life of the
        window, which is how a toolbox running from a share ends up unable to be
        updated while anyone has it open.

        A missing asset leaves the Image empty and says so through the return value.
        A decoration must not be able to stop the window it decorates from opening.

        The default names the wordmark because both callers pass a file explicitly and a
        default is only ever reached by a mistake - so it should land on something the
        window actually uses. It used to name TLC-Banner-clear.png, which was neither
        loaded by anything nor, after the artwork was replaced, present on disk.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.Image] $Image,
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [string] $FileName = 'TLC-Wordmark.png'
    )

    Initialize-TlcUi

    $path = Join-Path (Join-Path $ToolboxRoot 'Assets') $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Verbose "The banner was not found, so the window opens without it: $path"
        return $false
    }

    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = New-Object System.Uri($path)
        $bitmap.EndInit()
        $bitmap.Freeze()
        $Image.Source = $bitmap
        return $true
    } catch {
        Write-Verbose "The banner could not be loaded, so the window opens without it: $($_.Exception.Message)"
        return $false
    }
}


function Set-TlcWindowChromeFromSurface {
    <#
    .SYNOPSIS
        Wires a window's title bar to follow the colour it is actually painting with, and
        returns whether that colour is dark.
    .DESCRIPTION
        WPF does not paint the caption - the desktop window manager does - so a window that
        sets its Background and stops there gets the system's light bar regardless of its own
        theme. Three windows in this toolbox are built or themed in code and each needs the
        same two steps; the session log picker had them, the capability comparison had
        neither, and the settings window was written later without them.

        IT LIVES HERE, NOT IN Tlc.Ui.Theme.psm1

        That was the first home and it broke eleven tests. Modules in this toolbox call across
        to their siblings without importing them, which works because the manifest loads them
        all into one session state - but Tlc.Ui.SessionLogs.Tests.ps1 imports Tlc.Ui.psm1
        directly, and from there a function defined in Tlc.Ui.Theme.psm1 is not resolvable.

        The old code got away with it by accident: its only call to Set-TlcWindowDarkChrome sat
        INSIDE the SourceInitialized handler, which never fires in a test because the window is
        never shown. Hoisting the shared part to construction time made the dependency real for
        the first time. Tlc.Ui.psm1 owns two of the three callers and the third already depends
        on this module, so this is the home that needs no new edge. See findings.md, 204.

        The DWM call itself stays inside SourceInitialized - the attribute needs a window
        handle, and applied after the window is shown the caption is already painted and
        Windows does not reliably redraw it.

        Darkness is MEASURED from the brush the window paints with, not read back from the
        system setting. Those two can now disagree: the operator can force Light or Dark in
        Settings, and a dialog whose chrome follows Windows while its content follows the
        preference is the same defect one layer down.

        Rec. 601 luma, the usual weighting for perceived brightness. The surfaces in play are
        #FFFFFF and #161B22, so nothing sits near the midpoint threshold.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] $Window,
        $Surface
    )

    $dark = $false
    try {
        if ($Surface -and $Surface.Color) {
            $luma = (0.299 * $Surface.Color.R) + (0.587 * $Surface.Color.G) + (0.114 * $Surface.Color.B)
            $dark = $luma -lt 128
        }
    } catch {
        Write-Verbose 'The surface brush could not be measured, so light chrome is assumed.'
    }

    $Window.Add_SourceInitialized({
        $null = Set-TlcWindowDarkChrome -Window $Window -Dark $dark
    }.GetNewClosure())

    return $dark
}

function Show-TlcConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [Parameter(Mandatory)] [string] $Heading,
        [Parameter(Mandatory)] [string] $Message,
        [Parameter(Mandatory)] [string] $Question,
        [Parameter(Mandatory)] [string] $ConfirmText,
        [Parameter(Mandatory)] [string] $CancelText,
        [switch] $PassThru
    )

    $window = New-Object System.Windows.Window
    $window.Title = "TLC Toolbox - $Heading"
    $window.Owner = $Owner
    $window.Resources = $Owner.Resources
    $window.WindowStartupLocation = 'CenterOwner'
    $window.ShowInTaskbar = $false
    $window.SizeToContent = 'Height'
    $window.Width = 560
    $window.MinWidth = 420
    $window.MaxHeight = 600
    $window.Background = $Owner.FindResource('CanvasBrush')
    $window.FontFamily = $Owner.FindResource('UiFont')
    $window.FontSize = 13
    $null = Set-TlcWindowIcon -Window $window
    $null = Set-TlcWindowChromeFromSurface -Window $window -Surface $window.Background

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
    foreach ($height in 'Auto', '*', 'Auto') {
        $null = $grid.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
        $grid.RowDefinitions[$grid.RowDefinitions.Count - 1].Height = [System.Windows.GridLengthConverter]::new().ConvertFromString($height)
    }
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Name = 'ConfirmationHeading'
    $title.Text = $Heading
    $title.Style = $Owner.FindResource('SectionText')
    $title.Foreground = $Owner.FindResource('WarningBrush')
    $title.TextWrapping = 'Wrap'
    $null = $grid.Children.Add($title)

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $scroll.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($scroll, 1)
    $body = New-Object System.Windows.Controls.StackPanel
    $messageText = New-Object System.Windows.Controls.TextBlock
    $messageText.Name = 'ConfirmationMessage'
    $messageText.Text = $Message
    $messageText.Style = $Owner.FindResource('BodyText')
    $messageText.TextWrapping = 'Wrap'
    $null = $body.Children.Add($messageText)
    $questionText = New-Object System.Windows.Controls.TextBlock
    $questionText.Text = $Question
    $questionText.Style = $Owner.FindResource('BodyText')
    $questionText.FontWeight = 'SemiBold'
    $questionText.TextWrapping = 'Wrap'
    $questionText.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $null = $body.Children.Add($questionText)
    $scroll.Content = $body
    $null = $grid.Children.Add($scroll)

    $buttons = New-Object System.Windows.Controls.WrapPanel
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = [System.Windows.Thickness]::new(0, 18, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($buttons, 2)
    $confirm = New-Object System.Windows.Controls.Button
    $confirm.Name = 'ConfirmationYes'
    $confirm.Content = $ConfirmText
    $confirm.Style = $Owner.FindResource('PrimaryButton')
    $confirm.MinWidth = 90
    $confirm.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $confirm.Add_Click({ $window.DialogResult = $true }.GetNewClosure())
    $null = $buttons.Children.Add($confirm)
    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Name = 'ConfirmationNo'
    $cancel.Content = $CancelText
    $cancel.Style = $Owner.FindResource('SecondaryButton')
    $cancel.MinWidth = 90
    $cancel.IsCancel = $true
    $cancel.IsDefault = $true
    $cancel.Add_Click({ $window.DialogResult = $false }.GetNewClosure())
    $null = $buttons.Children.Add($cancel)
    $null = $grid.Children.Add($buttons)
    $window.Content = $grid
    $window.Add_ContentRendered({ $null = $cancel.Focus() }.GetNewClosure())
    if ($PassThru) { return $window }
    return ($window.ShowDialog() -eq $true)
}

function Show-TlcCapabilityComparison {
    <#
    .SYNOPSIS
        Opens a window explaining what this toolbox collects that remote collection does not,
        and the reverse.
    .DESCRIPTION
        The optional Recommendation is the wizard's current collection-routing card. It is
        detached from the main window and hosted here above the capability comparison, then
        detached again on close so it can be reopened without duplicating its live state.

        Built in code rather than from a second XAML file. Wizard.xaml is resolved through
        Get-TlcUiRoot and listed in the manifest FileList; a second markup file would have to
        be added to both, and would be one more thing a consumer can copy the modules without.
        The window is a few dozen elements, so the markup buys nothing.

        Resources are taken from the owner window, which is what makes the comparison follow
        the toolbox into dark mode. Without it the window renders in default WPF colours and
        looks like a different application - and the dark theme is a setting a reader has
        already chosen once.

        -Strings is the wizard's resolved string table, and the window is said in its
        language: the headings from their keys, every row from the parts the comparison is
        built of. Without it the window is English, which is what a caller outside the wizard
        - a test, a script - gets. File and product names are the same in every language.
    #>
    [CmdletBinding()]
    param(
        [System.Windows.Window] $Owner,
        [hashtable] $Strings,
        [System.Windows.FrameworkElement] $Recommendation,
        [switch] $PassThru
    )

    if ($Recommendation -and $Recommendation.Parent) {
        throw 'The collection recommendation is already attached to another window.'
    }
    $comparison = Get-TlcCapabilityComparison

    # A heading: its entry in the table, or the English beside the key without one. The
    # English here is held to the en-US entry by Tlc.Localization.Tests.ps1.
    $say = {
        param([string] $Key, [string] $English)
        if ($Strings -and $Strings.ContainsKey($Key)) { return (Get-TlcString -Table $Strings -Key $Key) }
        return $English
    }
    # A row value: a part said in the table's language, or its English; a plain string is a
    # file name and is shown as it is.
    $part = {
        param($Value)
        if ($null -eq $Value) { return '' }
        if ($Value -is [string]) { return $Value }
        if ($Strings) { return (Get-TlcMetricText -Part $Value -Table $Strings) }
        return [string]$Value.Text
    }

    $brush = {
        param([string] $Key, [string] $Fallback)
        if ($Owner -and $Owner.Resources -and $Owner.Resources.Contains($Key)) { return $Owner.Resources[$Key] }
        return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Fallback)))
    }

    $textPrimary = & $brush 'TextPrimaryBrush' '#201F1E'
    $textSecondary = & $brush 'TextSecondaryBrush' '#605E5C'
    $surface = & $brush 'SurfaceBrush' '#FFFFFF'
    $border = & $brush 'BorderBrush' '#E1DFDD'
    $accent = & $brush 'AccentBrush' '#6264A7'

    $window = New-Object System.Windows.Window
    $window.Title = 'TLC Toolbox - ' + (& $say 'CompareWindowTitle' 'what each tool collects')
    $null = Set-TlcWindowIcon -Window $window
    $window.Width = 940
    $window.Height = 720
    $window.Background = $surface
    if ($Owner) {
        $window.Owner = $Owner
        $window.Resources = $Owner.Resources
        $window.WindowStartupLocation = 'CenterOwner'
    } else {
        $window.WindowStartupLocation = 'CenterScreen'
    }

    # The caption bar is drawn by the desktop window manager, not by WPF, so a dark background
    # on the content leaves a white title bar sitting on top of it. This window set its
    # Background and stopped there, which is why it was the one dialog still opening with a
    # white bar over dark content - it looked like a different application.
    #
    # Measured from the surface this window actually paints with rather than from the system
    # setting, because the two can now disagree: the operator can force Light or Dark in
    # Settings, and chrome that follows Windows while the content follows the preference is
    # the same defect one layer down.
    $null = Set-TlcWindowChromeFromSurface -Window $window -Surface $surface

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.Padding = (New-Object System.Windows.Thickness 24)
    $stack = New-Object System.Windows.Controls.StackPanel
    $scroll.Content = $stack
    $window.Content = $scroll

    if ($Recommendation) {
        $null = $stack.Children.Add($Recommendation)
        $window.Add_Closed({
            $null = $stack.Children.Remove($Recommendation)
        }.GetNewClosure())
    }

    $addText = {
        param([string] $Text, [double] $Size, [string] $Weight, $Colour, [double] $TopMargin)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.FontSize = $Size
        $tb.FontWeight = $Weight
        $tb.Foreground = $Colour
        $tb.TextWrapping = 'Wrap'
        $tb.Margin = New-Object System.Windows.Thickness 0, $TopMargin, 0, 6
        $null = $stack.Children.Add($tb)
    }

    & $addText (& $say 'CompareHeading' 'What each tool actually collects') 20 'SemiBold' $textPrimary 0
    & $addText (& $part $comparison.Basis) 12 'Normal' $textSecondary 2

    # Two-column rows. A WPF Grid per row rather than one tall Grid: the sections have
    # different column counts, and a row that owns its own layout can be added or removed
    # without renumbering everything below it.
    $addRow = {
        param([string] $Left, [string] $Right, $LeftColour, $RightColour, [bool] $Bold)
        $grid = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = New-Object System.Windows.GridLength 300
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = New-Object System.Windows.GridLength 1, 'Star'
        $null = $grid.ColumnDefinitions.Add($c1)
        $null = $grid.ColumnDefinitions.Add($c2)

        $l = New-Object System.Windows.Controls.TextBlock
        $l.Text = $Left; $l.TextWrapping = 'Wrap'; $l.Foreground = $LeftColour
        $l.FontWeight = $(if ($Bold) { 'SemiBold' } else { 'Normal' })
        $l.Margin = New-Object System.Windows.Thickness 0, 3, 12, 3
        [System.Windows.Controls.Grid]::SetColumn($l, 0)
        $null = $grid.Children.Add($l)

        $r = New-Object System.Windows.Controls.TextBlock
        $r.Text = $Right; $r.TextWrapping = 'Wrap'; $r.Foreground = $RightColour
        $r.Margin = New-Object System.Windows.Thickness 0, 3, 0, 3
        [System.Windows.Controls.Grid]::SetColumn($r, 1)
        $null = $grid.Children.Add($r)

        $null = $stack.Children.Add($grid)
    }

    $addRule = {
        $line = New-Object System.Windows.Controls.Border
        $line.BorderBrush = $border
        $line.BorderThickness = New-Object System.Windows.Thickness 0, 1, 0, 0
        $line.Margin = New-Object System.Windows.Thickness 0, 4, 0, 4
        $null = $stack.Children.Add($line)
    }

    & $addText (& $say 'CompareSharedHeading' 'Both collect this') 15 'SemiBold' $accent 18
    & $addRow (& $say 'CompareFactColumn' 'Fact') (& $say 'CompareSidesColumn' 'Remote bundle  /  This toolbox') $textSecondary $textSecondary $true
    & $addRule
    foreach ($row in $comparison.Shared) {
        & $addRow (& $part $row.Fact) ("$(& $part $row.Remote)`n$(& $part $row.Toolbox)") $textPrimary $textSecondary $false
    }

    & $addText (& $say 'CompareToolboxOnlyHeading' 'Only this toolbox collects it') 15 'SemiBold' $accent 20
    & $addRule
    foreach ($row in $comparison.ToolboxOnly) {
        & $addRow (& $part $row.Capability) (& $part $row.Detail) $textPrimary $textSecondary $false
    }

    & $addText (& $say 'CompareRemoteOnlyHeading' 'Only remote collection provides it') 15 'SemiBold' $accent 20
    & $addRule
    foreach ($row in $comparison.RemoteOnly) {
        & $addRow (& $part $row.Capability) (& $part $row.Detail) $textPrimary $textSecondary $false
    }

    & $addText (& $say 'CompareConclusion' 'Neither tool is a superset of the other. They collect almost entirely different artifacts: remote collection captures the Teams web application talking to the service, and this toolbox captures the native client and the machine underneath it.') 12 'Normal' $textSecondary 20

    if ($PassThru) { return $window }
    $null = $window.ShowDialog()
    return $null
}


function Show-TlcSessionLogPicker {
    <#
    .SYNOPSIS
        Lets the operator choose which of this session's collections to package, and
        optionally zip them together.
    .DESCRIPTION
        A wizard window can produce several collections - a first attempt with the wrong
        window, a second after widening it, a third once the user reproduced the fault. Until
        2026-09-11 they all landed in ONE run folder, because the correlation id was captured
        after the first run and reused: files overwritten, blockers accumulated. Each Collect
        now gets its own folder, which means a session genuinely has several sets of evidence
        and somebody has to say which of them matter.

        That somebody is the operator, not this function. The three runs are not
        interchangeable - one may cover the wrong hour, one may be the repro - and nothing in
        the evidence itself distinguishes "the collection that caught it" from "the two before
        I got the window right". So this lists what exists, with the facts needed to tell them
        apart, and selects nothing on the operator's behalf beyond a sensible default.

        Each row carries its own window, scenario and size, because the window is exactly what
        differed between the runs that prompted this.

        Returns the selected run paths and whether to zip, or $null if cancelled. Shows the
        picker for any number of runs; deciding that one collection is not worth asking about
        belongs to the caller, which knows whether it is mid-wizard or replaying a folder. The
        wizard's Package button makes that call. Returning $null for a single run instead would
        leave a caller unable to tell "nothing to choose" from "the operator cancelled", and a
        silent no-op is a worse failure than a redundant dialog.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RunPath,
        [System.Windows.Window] $Owner,
        [string] $Warning,
        [switch] $PassThru
    )

    $runs = @($RunPath | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($runs.Count -eq 0) { return $null }

    # Facts that distinguish one run from another, read from the run itself rather than
    # inferred from the folder name.
    $rows = foreach ($path in $runs) {
        $scenario = ''; $window = ''; $case = ''; $when = ''; $started = [datetime]::MinValue
        try {
            $run = Get-Content -LiteralPath (Join-Path $path 'Run.json') -Raw -ErrorAction Stop | ConvertFrom-Json
            $scenario = [string]$run.Scenario
            $case = [string]$run.CaseNumber
            if ($run.StartTimeUtc) {
                $started = ([datetime]$run.StartTimeUtc).ToLocalTime()
                # Runs from earlier days look identical to today's when only the clock time is
                # shown, and a session left open overnight produces exactly that.
                $when = if ($started.Date -eq (Get-Date).Date) { $started.ToString('HH:mm:ss') }
                        else { $started.ToString('ddd d MMM HH:mm:ss') }
            }
        } catch { Write-Verbose "Run.json unreadable in $path" }
        try {
            $scope = Get-Content -LiteralPath (Join-Path $path 'Scope.json') -Raw -ErrorAction Stop | ConvertFrom-Json
            # A live trace records no window, so the column would otherwise read blank -
            # which in a picker means "unreadable", not "deliberately empty". Naming the
            # fork is what tells the operator which of their runs was which.
            if ($null -eq $scope.WindowStart -or $null -eq $scope.WindowEnd) {
                $window = 'Live trace'
            } else {
                $start = ([datetime]$scope.WindowStart.UtcTime).ToLocalTime()
                $end = ([datetime]$scope.WindowEnd.UtcTime).ToLocalTime()
                $window = '{0} to {1}' -f $start.ToString('HH:mm'), $end.ToString('HH:mm')
            }
        } catch { Write-Verbose "Scope.json unreadable in $path" }

        $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue)
        # Measure-Object returns nothing at all for an empty set, so .Sum throws under
        # StrictMode - and an empty run folder is precisely the case this picker exists for.
        $bytes = 0L
        if ($files.Count -gt 0) { $bytes = [int64](($files | Measure-Object Length -Sum).Sum) }
        [pscustomobject]@{
            Path      = $path
            Started   = $started
            Collected = $when
            Scenario  = $scenario
            Case      = $case
            Window    = $window
            FileCount = $files.Count
            Bytes     = $bytes
        }
    }
    # Newest first: the run most likely to hold the repro is the one just finished.
    $rows = @($rows | Sort-Object Started -Descending)

    $brush = {
        param([string] $Key, [string] $Fallback)
        if ($Owner -and $Owner.Resources -and $Owner.Resources.Contains($Key)) { return $Owner.Resources[$Key] }
        return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Fallback)))
    }
    $textPrimary = & $brush 'TextPrimaryBrush' '#201F1E'
    $textSecondary = & $brush 'TextSecondaryBrush' '#605E5C'
    $surface = & $brush 'SurfaceBrush' '#FFFFFF'

    $window = New-Object System.Windows.Window
    $window.Title = 'Package session logs'
    $null = Set-TlcWindowIcon -Window $window
    $window.Width = 760
    # Tall enough for the rows there actually are, capped so a session with a dozen
    # collections scrolls instead of running off the screen. A fixed height leaves two runs
    # floating above a field of empty white.
    $window.Height = [math]::Min(620, 210 + ($rows.Count * 46) + $(if ($Warning) { 46 } else { 0 }))
    $window.MinHeight = 260
    $window.Background = $surface
    $window.ResizeMode = 'CanResize'
    if ($Owner) {
        # Resources first, and ownership separately. Setting Owner throws if the owner has
        # never been shown, and when that assignment is chained with the resource copy the
        # throw takes the theme with it - the dialog then renders in stock WPF chrome, or
        # not at all. Ownership only decides centring and z-order; the resources decide
        # whether the window is legible.
        $window.Resources = $Owner.Resources
        $window.WindowStartupLocation = 'CenterOwner'
        try {
            $window.Owner = $Owner
        } catch {
            Write-Verbose "The owner could not be attached, so the dialog is centred on screen: $($_.Exception.Message)"
            $window.WindowStartupLocation = 'CenterScreen'
        }
    } else {
        $window.WindowStartupLocation = 'CenterScreen'
    }

    # Re-resolved now that the owner's resources are in place. The brushes above were taken
    # before the copy, so on a themed dialog they are the light fallbacks.
    $textPrimary = & $brush 'TextPrimaryBrush' '#201F1E'
    $textSecondary = & $brush 'TextSecondaryBrush' '#605E5C'
    $surface = & $brush 'SurfaceBrush' '#FFFFFF'
    $window.Background = $surface

    # The caption bar is drawn by the desktop window manager, not by WPF, so a dark theme on
    # the content leaves a white title bar sitting on top of it. The helper measures the
    # surface and hooks SourceInitialized, which is the only point where the handle exists
    # and the caption has not yet been painted.
    #
    # Shared with the capability comparison rather than copied: this window had the block and
    # that one did not, which is precisely how one dialog ended up with a white bar in dark
    # mode while its sibling was correct.
    #
    # The return value is KEPT. $dark is surfaced in the -PassThru object the tests assert on,
    # and assigning this to $null removed the only thing that set it - so eleven tests failed
    # with "the variable '$dark' cannot be retrieved" from a refactor that was meant to be
    # behaviour-preserving.
    $dark = Set-TlcWindowChromeFromSurface -Window $window -Surface $surface

    $outer = New-Object System.Windows.Controls.Grid
    $outer.Margin = New-Object System.Windows.Thickness 20
    foreach ($h in @('Auto', 'Auto', 'Auto', '*', 'Auto')) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = if ($h -eq '*') { New-Object System.Windows.GridLength 1, 'Star' } else { New-Object System.Windows.GridLength 0, 'Auto' }
        $null = $outer.RowDefinitions.Add($rd)
    }
    $window.Content = $outer

    $heading = New-Object System.Windows.Controls.TextBlock
    $heading.Text = "This window has collected $($rows.Count) time(s). Choose which to package."
    $heading.FontSize = 15
    $heading.FontWeight = 'SemiBold'
    $heading.Foreground = $textPrimary
    $heading.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetRow($heading, 0)
    $null = $outer.Children.Add($heading)

    # Said before the choice, not after it. The privacy gate refuses a bundle when consent is
    # missing, and until now the operator picked three runs, watched three packages start and
    # got three refusals - having already spent the time. A caveat that arrives after the
    # decision is not a caveat, it is a post-mortem.
    $warningBlock = New-Object System.Windows.Controls.TextBlock
    $warningBlock.TextWrapping = 'Wrap'
    $warningBlock.Margin = New-Object System.Windows.Thickness 0, 10, 0, 0
    $warningBlock.Foreground = & $brush 'WarningBrush' '#A16207'
    if ($Warning) {
        $warningBlock.Text = $Warning
    } else {
        $warningBlock.Visibility = 'Collapsed'
    }
    [System.Windows.Controls.Grid]::SetRow($warningBlock, 1)
    $null = $outer.Children.Add($warningBlock)

    $allBox = New-Object System.Windows.Controls.CheckBox
    $allBox.Content = 'All session logs'
    $allBox.FontWeight = 'SemiBold'
    $allBox.Foreground = $textPrimary
    $allBox.Margin = New-Object System.Windows.Thickness 0, 12, 0, 8
    $allBox.IsChecked = $true
    [System.Windows.Controls.Grid]::SetRow($allBox, 2)
    $null = $outer.Children.Add($allBox)

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    [System.Windows.Controls.Grid]::SetRow($scroll, 3)
    $list = New-Object System.Windows.Controls.StackPanel
    $scroll.Content = $list
    $null = $outer.Children.Add($scroll)

    $boxes = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.IsChecked = $true
        $cb.Margin = New-Object System.Windows.Thickness 16, 4, 0, 4
        $cb.Tag = $row.Path

        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        # Timestamp first, with no prefix. Every row was collected, so the word carried no
        # information and pushed the one field that distinguishes the rows - and that they
        # are ordered by - away from the left edge where the eye scans.
        $title.Text = '{0}  -  {1}' -f $(if ($row.Collected) { $row.Collected } else { 'time unknown' }), $(if ($row.Scenario) { $row.Scenario } else { 'unknown scenario' })
        $title.Foreground = $textPrimary
        $null = $stack.Children.Add($title)

        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = 'window {0}   {1} file(s)   {2:N1} MB   case {3}' -f `
            $(if ($row.Window) { $row.Window } else { 'unknown' }), $row.FileCount, ($row.Bytes / 1MB), $(if ($row.Case) { $row.Case } else { 'none' })
        $sub.Foreground = $textSecondary
        $sub.FontSize = 11
        $null = $stack.Children.Add($sub)

        $cb.Content = $stack

        # A screen reader derives a checkbox's name from its content, and this content is a
        # panel of TextBlocks rather than a string - so these rows announced as unlabelled
        # checkboxes while the All and Zip boxes, whose content is plain text, announced
        # correctly. Measured through UI Automation: four boxes exposed, two with empty names.
        #
        # The name says the same thing the two lines say, because the operator choosing by
        # ear is making exactly the decision the operator choosing by eye is making.
        [System.Windows.Automation.AutomationProperties]::SetName($cb, ('{0}. {1}' -f $title.Text, $sub.Text))

        $null = $list.Children.Add($cb)
        $boxes.Add($cb)
    }

    # The All box drives the rows; a row being unticked unticks All without clearing the rest.
    # Checked/Unchecked rather than Click, so the link holds when IsChecked is set in code
    # (a Click handler is silent then, which makes the behaviour untestable and the state
    # divergent the moment anything but a mouse touches the box).
    # Guarded against re-entry, or setting All from a row handler re-runs the row handlers.
    $syncing = [ref]$false
    $syncAll = {
        if ($syncing.Value) { return }
        $syncing.Value = $true
        try { foreach ($b in $boxes) { $b.IsChecked = $allBox.IsChecked } } finally { $syncing.Value = $false }
    }.GetNewClosure()
    $allBox.Add_Checked($syncAll)
    $allBox.Add_Unchecked($syncAll)

    $syncRow = {
        if ($syncing.Value) { return }
        $syncing.Value = $true
        try {
            $checked = @($boxes | Where-Object { $_.IsChecked })
            $allBox.IsChecked = ($checked.Count -eq $boxes.Count)
        } finally { $syncing.Value = $false }
    }.GetNewClosure()
    foreach ($cb in $boxes) {
        $cb.Add_Checked($syncRow)
        $cb.Add_Unchecked($syncRow)
    }

    $footer = New-Object System.Windows.Controls.StackPanel
    $footer.Orientation = 'Horizontal'
    $footer.HorizontalAlignment = 'Right'
    $footer.Margin = New-Object System.Windows.Thickness 0, 14, 0, 0
    [System.Windows.Controls.Grid]::SetRow($footer, 4)

    $zipBox = New-Object System.Windows.Controls.CheckBox
    $zipBox.Content = 'Zip the selected runs into one file'
    $zipBox.IsChecked = $true
    $zipBox.Foreground = $textPrimary
    $zipBox.VerticalAlignment = 'Center'
    $zipBox.Margin = New-Object System.Windows.Thickness 0, 0, 20, 0
    $null = $footer.Children.Add($zipBox)

    $result = [ordered]@{ Confirmed = $false; RunPath = @(); Zip = $false }

    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = 'Cancel'
    $cancel.MinWidth = 90
    $cancel.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    if ($Owner -and $Owner.Resources.Contains('SecondaryButton')) { $cancel.Style = $Owner.Resources['SecondaryButton'] }
    $cancel.Add_Click({ $window.Close() }.GetNewClosure())
    $null = $footer.Children.Add($cancel)

    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = 'Package'
    $ok.MinWidth = 110
    if ($Owner -and $Owner.Resources.Contains('PrimaryButton')) { $ok.Style = $Owner.Resources['PrimaryButton'] }
    $ok.Add_Click({
        $result.RunPath = @($boxes | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
        $result.Zip = [bool]$zipBox.IsChecked
        $result.Confirmed = ($result.RunPath.Count -gt 0)
        $window.Close()
    }.GetNewClosure())
    $null = $footer.Children.Add($ok)
    $null = $outer.Children.Add($footer)

    if ($PassThru) { return (New-Object psobject -Property @{ Window = $window; Boxes = $boxes; AllBox = $allBox; ZipBox = $zipBox; Rows = $rows; WarningBlock = $warningBlock; Dark = $dark }) }

    $null = $window.ShowDialog()
    if (-not $result.Confirmed) { return $null }
    return (New-Object psobject -Property $result)
}

Export-ModuleMember -Function Show-TlcConfirmation, Show-TlcSessionLogPicker, Show-TlcCapabilityComparison, Initialize-TlcUi, Get-TlcUiRoot, Get-TlcIconPath, Set-TlcWindowIcon, ConvertTo-TlcXamlUri, Import-TlcXaml,
    Get-TlcUiElement, Sync-TlcUiPaint, Set-TlcUiBanner, Set-TlcWindowChromeFromSurface
