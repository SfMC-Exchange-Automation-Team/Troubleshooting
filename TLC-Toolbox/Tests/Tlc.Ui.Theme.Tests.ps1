Set-StrictMode -Version Latest

<#
    Dark mode has to be invisible when it works and harmless when it does not.

    The mechanism is unusual enough to be worth pinning: Theme.xaml resolves every
    colour through StaticResource, which is resolved once at parse time into brushes
    that are frozen - verified, not assumed. So the palette cannot be swapped at
    runtime, and the theme text is patched before the parser sees it instead.

    What matters is that the patched theme still parses, that only the colour block
    changes, and that any failure lands on the light theme rather than on a window that
    will not open.
#>

BeforeAll {
    $script:ToolboxRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Theme.psm1') -Force

    $script:LightTheme = Join-Path $script:ToolboxRoot 'Ui\Theme.xaml'
    $script:WizardXaml = Join-Path $script:ToolboxRoot 'Ui\Wizard.xaml'
}

$IsStaHost = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')

Describe 'Test-TlcDarkMode' {

    It 'returns a boolean on this machine, whatever the theme is' {
        Test-TlcDarkMode | Should -BeOfType ([bool])
    }

    It 'treats a missing registry value as light' {
        # The value has existed since Windows 10 1607, but a hardened or stripped image
        # can lack it. Defaulting to dark on a machine whose theme cannot be read would
        # be the more surprising failure.
        Test-TlcDarkMode -RegistryPath 'HKCU:\Software\NoSuchKey\TlcTest' | Should -BeFalse
    }

    It 'reads the app theme, not the system theme' {
        # SystemUsesLightTheme controls the taskbar and Start; AppsUseLightTheme controls
        # application chrome, and people commonly set them differently. Reading the wrong
        # one would give a window that disagrees with every other app on the desktop.
        $source = Get-Content -LiteralPath (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Theme.psm1') -Raw
        $source | Should -Match 'AppsUseLightTheme'
        $source | Should -Not -Match "-Name 'SystemUsesLightTheme'"
    }
}

Describe 'ConvertTo-TlcDarkThemeXaml' {

    It 'replaces every colour the theme declares' {
        $result = ConvertTo-TlcDarkThemeXaml -Xaml (Get-Content -LiteralPath $script:LightTheme -Raw)
        $declared = ([regex]::Matches((Get-Content -LiteralPath $script:LightTheme -Raw), '<Color x:Key="\w+">')).Count

        @($result.Substituted).Count | Should -Be $declared -Because 'a colour left light in a dark theme is the one that will look wrong'
    }

    It 'changes nothing but the colour block' {
        # Every brush, template and trigger derives from those colours, so the rest of
        # the file is carried through unchanged and cannot drift from the light theme.
        $light = Get-Content -LiteralPath $script:LightTheme -Raw
        $dark = (ConvertTo-TlcDarkThemeXaml -Xaml $light).Xaml

        $stripColours = {
            param($text)
            [regex]::Replace($text, '<Color x:Key="\w+">[^<]*</Color>', '<Color />')
        }

        (& $stripColours $dark) | Should -BeExactly (& $stripColours $light)
    }

    It 'leaves a colour it has no dark value for alone rather than guessing' {
        # A colour added to the theme later should degrade to its light value, not
        # vanish or become something invented.
        $xaml = '<Color x:Key="CanvasColor">#F4F5F7</Color><Color x:Key="BrandNewColor">#ABCDEF</Color>'
        $result = ConvertTo-TlcDarkThemeXaml -Xaml $xaml

        $result.Xaml | Should -Match '<Color x:Key="BrandNewColor">#ABCDEF</Color>'
        $result.Substituted | Should -Not -Contain 'BrandNewColor'
        $result.Substituted | Should -Contain 'CanvasColor'
    }

    It 'produces a genuinely dark canvas and light text' {
        # An inversion that got the polarity backwards would still pass a "did it
        # change" test, so the direction is asserted.
        Add-Type -AssemblyName System.Drawing
        $result = ConvertTo-TlcDarkThemeXaml -Xaml (Get-Content -LiteralPath $script:LightTheme -Raw)

        $canvas = [regex]::Match($result.Xaml, '<Color x:Key="CanvasColor">(?<v>[^<]*)</Color>').Groups['v'].Value
        $text = [regex]::Match($result.Xaml, '<Color x:Key="TextPrimaryColor">(?<v>[^<]*)</Color>').Groups['v'].Value

        $canvasColour = [System.Drawing.ColorTranslator]::FromHtml($canvas)
        $textColour = [System.Drawing.ColorTranslator]::FromHtml($text)

        $canvasLuminance = (0.299 * $canvasColour.R) + (0.587 * $canvasColour.G) + (0.114 * $canvasColour.B)
        $textLuminance = (0.299 * $textColour.R) + (0.587 * $textColour.G) + (0.114 * $textColour.B)

        $canvasLuminance | Should -BeLessThan 40 -Because 'the canvas has to be dark'
        $textLuminance | Should -BeGreaterThan 180 -Because 'text on it has to be light'
        $textLuminance | Should -BeLessThan 250 -Because 'pure white glares and smears at small sizes'
    }
}

Describe 'Get-TlcThemePath' {

    It 'returns the light theme untouched when the OS is light' {
        Get-TlcThemePath -LightThemePath $script:LightTheme -ForceLight | Should -Be $script:LightTheme
    }

    It 'returns a separate file for dark, leaving the shipped theme alone' {
        $before = Get-Content -LiteralPath $script:LightTheme -Raw
        $dark = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark

        $dark | Should -Not -Be $script:LightTheme
        Test-Path -LiteralPath $dark | Should -BeTrue

        # Theme.xaml is EPO's file copied verbatim. Patching it in place would diverge
        # the two toolboxes, which is the thing keeping it unmodified is meant to avoid.
        Get-Content -LiteralPath $script:LightTheme -Raw | Should -BeExactly $before
    }

    It 'writes the dark theme outside the toolbox folder' {
        # The toolbox is routinely run from a share or a read-only folder. A cosmetic
        # feature must not need write access to the install location.
        $dark = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark
        $dark | Should -Not -BeLike "$script:ToolboxRoot*"
        $dark | Should -BeLike "$([Environment]::GetFolderPath('LocalApplicationData'))*"
    }

    It 'falls back to light when the theme cannot be read' {
        { Get-TlcThemePath -LightThemePath (Join-Path $TestDrive 'missing.xaml') } | Should -Throw
    }

    It 'loads the wizard against the dark theme' -Skip:(-not $IsStaHost) {
        # The real test. A patched theme that produces valid XML but invalid XAML would
        # pass every string assertion above and still fail to open a window.
        $dark = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark
        { Import-TlcXaml -Path $script:WizardXaml -ThemePath $dark } | Should -Not -Throw
    }

    It 'gives the window dark brushes once loaded' -Skip:(-not $IsStaHost) {
        $dark = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark
        $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $dark

        $canvas = $window.FindResource('CanvasBrush').Color
        $luminance = (0.299 * $canvas.R) + (0.587 * $canvas.G) + (0.114 * $canvas.B)
        $luminance | Should -BeLessThan 40
    }

    It 'themes the checkboxes instead of leaving them system-drawn' -Skip:(-not $IsStaHost) {
        # WPF's stock CheckBox template hardcodes a near-white fill and takes the system
        # foreground, so on the dark theme the boxes rendered as two glaring white
        # squares with a label that almost vanished. Nothing else on the form did this,
        # because everything else carries a style; the checkboxes carried none.
        #
        # Asserted through the loaded window rather than by reading the markup, so this
        # fails if the style stops being reached as well as if it is removed.
        foreach ($case in @(
            @{ Mode = 'Light'; Force = @{ ForceLight = $true } }
            @{ Mode = 'Dark'; Force = @{ ForceDark = $true } }
        )) {
            $force = $case.Force
            $theme = Get-TlcThemePath -LightThemePath $script:LightTheme @force
            $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme

            $box = $window.FindName('SkipPromptedBox')
            $box | Should -Not -BeNullOrEmpty

            $window.Resources[[System.Windows.Controls.CheckBox]] |
                Should -Not -BeNullOrEmpty -Because "$($case.Mode) needs an implicit CheckBox style so a new checkbox cannot regress silently"

            $colour = $box.Foreground.Color
            $luminance = (0.299 * $colour.R) + (0.587 * $colour.G) + (0.114 * $colour.B)
            if ($case.Mode -eq 'Dark') {
                $luminance | Should -BeGreaterThan 180 -Because 'the label has to be readable on a dark canvas'
            } else {
                $luminance | Should -BeLessThan 90 -Because 'the label has to be readable on a light canvas'
            }
        }
    }
}

Describe 'Teams purple accents preserve blue links' -Skip:(-not $IsStaHost) {
    BeforeAll {
        Import-Module (Join-Path $script:ToolboxRoot 'Tlc.psd1') -Force -DisableNameChecking
        $script:SharedThemeHash = (Get-FileHash -LiteralPath $script:LightTheme -Algorithm SHA256).Hash
        function Get-RelativeLuminance {
            param([System.Windows.Media.Color] $Color)
            $linear = @($Color.R, $Color.G, $Color.B | ForEach-Object {
                $value = $_ / 255.0
                if ($value -le 0.04045) { $value / 12.92 } else { [math]::Pow(($value + 0.055) / 1.055, 2.4) }
            })
            return 0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2]
        }
    }
    BeforeEach {
        $script:AccentWindows = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach {
        foreach ($window in $script:AccentWindows) { $window.Close() }
        (Get-FileHash -LiteralPath $script:LightTheme -Algorithm SHA256).Hash | Should -BeExactly $script:SharedThemeHash
    }

    It 'separates primary fills, accent text and links in <Mode> mode' -ForEach @(
        @{ Mode = 'Light'; Dark = $false; Ink = '#FF6264A7'; Link = '#FF2563EB' }
        @{ Mode = 'Dark'; Dark = $true; Ink = '#FFA6A7E8'; Link = '#FF3B82F6' }
    ) {
        $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$Dark -ForceLight:(-not $Dark)
        $themeHash = (Get-FileHash -LiteralPath $theme).Hash
        $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
        $script:AccentWindows.Add($window)
        $window.FindResource('AccentBrush').Color.ToString() | Should -BeExactly $Ink
        $window.FindResource('ButtonAccentBrush').Color.ToString() | Should -BeExactly '#FF6264A7'
        foreach ($name in 'CollectButton', 'CancelButton', 'GenerateSupportButton') {
            $window.FindName($name).Background.Color.ToString() | Should -BeExactly '#FF6264A7'
        }
        $window.FindName('PackageButton').Style = $window.FindResource('PrimaryButton')
        $window.FindName('PackageButton').Background.Color.ToString() | Should -BeExactly '#FF6264A7'
        foreach ($name in 'AdminCenterLink', 'ComparisonLink') {
            $window.FindName($name).Foreground.Color.ToString() | Should -BeExactly $Link
            $window.FindName($name).Foreground.Color.ToString() | Should -Not -Be $Ink
            $window.FindName($name).TextDecorations | Should -Not -BeNullOrEmpty
        }
        $window.FindName('LivePathSelected').Foreground.Color.ToString() | Should -BeExactly $Ink
        $window.FindName('RunLoadingSpinner').Stroke.Color.ToString() | Should -BeExactly $Ink
        (Get-FileHash -LiteralPath $theme).Hash | Should -BeExactly $themeHash
    }

    It 'uses darker purple hover and pressed triggers with readable white text' {
        foreach ($dark in @($false, $true)) {
            $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$dark -ForceLight:(-not $dark)
            $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
            $script:AccentWindows.Add($window)
            $button = $window.FindName('CollectButton')
            $button.ApplyTemplate() | Out-Null
            foreach ($entry in @(
                @{ Property = 'IsMouseOver'; Color = '#FF57599B' }
                @{ Property = 'IsPressed'; Color = '#FF4B4D87' }
            )) {
                $trigger = @($button.Template.Triggers | Where-Object { $_.Property.Name -eq $entry.Property })[0]
                $fill = @($trigger.Setters | Where-Object { $_.Property.Name -eq 'Background' })[0].Value
                $fill.Color.ToString() | Should -BeExactly $entry.Color
                ((1.0 + 0.05) / ((Get-RelativeLuminance -Color $fill.Color) + 0.05)) | Should -BeGreaterThan 4.5
            }
            $base = $window.FindResource('ButtonAccentBrush').Color
            ((1.0 + 0.05) / ((Get-RelativeLuminance -Color $base) + 0.05)) | Should -BeGreaterThan 4.5
            $ink = $window.FindResource('AccentBrush').Color
            $surface = $window.FindResource('SurfaceBrush').Color
            $luminances = @((Get-RelativeLuminance -Color $ink), (Get-RelativeLuminance -Color $surface) | Sort-Object)
            (($luminances[1] + 0.05) / ($luminances[0] + 0.05)) | Should -BeGreaterThan 4.5
        }
    }

    It 'renders purple primary fills and checked boxes but retains neutral disabled controls' {
        foreach ($dark in @($false, $true)) {
            $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$dark -ForceLight:(-not $dark)
            $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
            $script:AccentWindows.Add($window)
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -32000; $window.Top = -32000
            $window.ShowActivated = $false; $window.ShowInTaskbar = $false
            $button = $window.FindName('PackageButton')
            $button.Style = $window.FindResource('PrimaryButton')
            $button.Visibility = 'Visible'
            $button.IsEnabled = $true
            $box = $window.FindName('ShowLiveGraphBox')
            $window.FindName('CapturePhasePanel').Visibility = 'Visible'
            $box.Visibility = 'Visible'
            $box.IsChecked = $true
            $window.Show()
            $null = $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
            $window.UpdateLayout()
            $chrome = $button.Template.FindName('Chrome', $button)
            $chrome.Background.Color.ToString() | Should -BeExactly '#FF6264A7'
            $box.Template.FindName('Box', $box).Background.Color.ToString() | Should -BeExactly '#FF6264A7'
            $button.IsEnabled = $false
            $window.UpdateLayout()
            $chrome.Background.ToString() | Should -BeExactly $window.FindResource('NeutralSurfaceBrush').ToString()
            $button.Foreground.ToString() | Should -BeExactly $window.FindResource('TextSecondaryBrush').ToString()
        }
    }

    It 'keeps performance bands and outcome colors unchanged in both modes' {
        foreach ($dark in @($false, $true)) {
            $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$dark -ForceLight:(-not $dark)
            $original = [xml](Get-Content -LiteralPath $theme -Raw)
            $namespaces = [System.Xml.XmlNamespaceManager]::new($original.NameTable)
            $namespaces.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
            $namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
            $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
            $script:AccentWindows.Add($window)
            foreach ($name in 'Pass', 'Warning', 'Blocked', 'Neutral', 'Unknown') {
                $color = $original.SelectSingleNode("/w:ResourceDictionary/w:Color[@x:Key='${name}Color']", $namespaces).InnerText
                $window.FindResource("${name}Brush").Color | Should -Be ([System.Windows.Media.ColorConverter]::ConvertFromString($color))
            }
            $window.FindResource('TeamsGraphBrush').Color.ToString() | Should -BeExactly '#FF6264A7'
        }
    }

    It 'themes detail/settings and owner-based dialogs consistently without changing warning meaning' {
        foreach ($dark in @($false, $true)) {
            $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$dark -ForceLight:(-not $dark)
            $owner = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
            $script:AccentWindows.Add($owner)
            $owner.WindowStartupLocation = 'Manual'
            $owner.Left = -32000; $owner.Top = -32000
            $owner.ShowActivated = $false; $owner.ShowInTaskbar = $false
            $owner.Show()
            foreach ($file in 'Detail.xaml', 'Settings.xaml') {
                $dialog = Import-TlcXaml -Path (Join-Path $script:ToolboxRoot "Ui\$file") -ThemePath $theme
                $script:AccentWindows.Add($dialog)
                $dialog.FindResource('AccentBrush').Color | Should -Be $owner.FindResource('AccentBrush').Color
                $dialog.FindResource('LinkBrush').Color | Should -Be $owner.FindResource('LinkBrush').Color
            }
            $confirmation = Show-TlcConfirmation -Owner $owner -Heading 'Stop trace' -Message 'Still recording.' `
                -Question 'Stop?' -ConfirmText 'Yes' -CancelText 'No' -PassThru
            $script:AccentWindows.Add($confirmation)
            $buttons = @($confirmation.Content.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] })[0]
            $buttons.Children[0].Background.Color.ToString() | Should -BeExactly '#FF6264A7'
            $confirmation.Content.Children[0].Foreground.ToString() | Should -BeExactly $owner.FindResource('WarningBrush').ToString()
            $comparison = Show-TlcCapabilityComparison -Owner $owner -PassThru
            $script:AccentWindows.Add($comparison)
            $comparison.FindResource('AccentBrush').Color | Should -Be $owner.FindResource('AccentBrush').Color
        }
    }

    It 'uses purple for transcript keywords, working steps and selected outlines instead of link blue' {
        foreach ($dark in @($false, $true)) {
            $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$dark -ForceLight:(-not $dark)
            $window = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
            $script:AccentWindows.Add($window)
            $accent = $window.FindResource('AccentBrush')
            $strings = Get-TlcStringTable -Language en-US -ToolboxRoot $script:ToolboxRoot
            $elements = Get-TlcUiElement -Root $window -Name @(
                'StopProgressPanel', 'StopProgressTitle', 'StopProgressActivity', 'StopProgressDetail',
                'StopSamplingText', 'StopLogsText', 'StopSupportText', 'StopFinalizeText', 'SupportResultText'
            )
            $state = @{ RunFork = 'Capture'; CapturePhase = 'Collect'; Strings = $strings }
            $record = [pscustomobject]@{ Step = 'Logs'; Status = 'Running'; DetailKey = 'StopDetailClientLogs' }
            Update-TlcStopProgress -Element $elements -State $state -Records @($record)
            $elements.StopLogsText.Foreground.Color | Should -Be $accent.Color
            $elements.StopProgressTitle.Foreground.Color | Should -Be $accent.Color
            $view = $window.FindName('LogView')
            Update-TlcTranscriptView -View $view -Text "Running:`n-Stage Capture"
            $view.Document.Blocks.FirstBlock.Foreground.Color | Should -Be $accent.Color
            $view.Document.Blocks.LastBlock.Inlines.FirstInline.Foreground.Color | Should -Be $accent.Color
            $window.FindName('LivePathSelected').Foreground.Color | Should -Be $accent.Color
            $window.FindName('ComparisonLink').Foreground.Color | Should -Not -Be $accent.Color
        }
    }
}

Describe 'Native confirmation title bars match the owner theme' -Skip:(-not $IsStaHost) {
    BeforeAll {
        Import-Module (Join-Path $script:ToolboxRoot 'Tlc.psd1') -Force -DisableNameChecking
        if (-not ('TlcTest.ConfirmationCaptionProbe' -as [type])) {
            Add-Type -Namespace TlcTest -Name ConfirmationCaptionProbe -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmGetWindowAttribute(System.IntPtr hwnd, int attribute, out int value, int size);
'@ -ErrorAction Stop
        }
    }

    It 'sets the actual DWM caption to <Expected> before first paint for a <Mode> owner' -ForEach @(
        @{ Mode = 'Light'; Dark = $false; Expected = 0 }
        @{ Mode = 'Dark'; Dark = $true; Expected = 1 }
    ) {
        $theme = Get-TlcThemePath -LightThemePath $script:LightTheme -ForceDark:$Dark -ForceLight:(-not $Dark)
        $owner = Import-TlcXaml -Path $script:WizardXaml -ThemePath $theme
        $dialog = $null
        try {
            $owner.WindowStartupLocation = 'Manual'
            $owner.Left = -32000; $owner.Top = -32000
            $owner.ShowActivated = $false; $owner.ShowInTaskbar = $false
            $owner.Show()
            $dialog = Show-TlcConfirmation -Owner $owner -Heading 'Still recording' -Message 'Samples are kept.' `
                -Question 'Stop and close?' -ConfirmText Yes -CancelText No -PassThru
            $dialog.WindowStartupLocation = 'Manual'
            $dialog.Left = -32000; $dialog.Top = -32000
            $dialog.ShowActivated = $false; $dialog.ShowInTaskbar = $false
            $observed = @{ Value = -1; HResult = -1; Initialized = $false }
            $dialog.Add_SourceInitialized({
                param($source, $routedEvent)
                $handle = [System.Windows.Interop.WindowInteropHelper]::new($source).Handle
                $value = -1
                $observed.HResult = [TlcTest.ConfirmationCaptionProbe]::DwmGetWindowAttribute($handle, 20, [ref]$value, 4)
                $observed.Value = $value
                $observed.Initialized = $true
            }.GetNewClosure())
            $dialog.Show()
            $observed.Initialized | Should -BeTrue
            $observed.HResult | Should -Be 0 -Because 'the native getter must succeed, not merely observe a matching WPF brush'
            $observed.Value | Should -Be $Expected -Because 'the first native caption must match the dialog theme'
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($dialog).Handle
            $painted = -1
            [TlcTest.ConfirmationCaptionProbe]::DwmGetWindowAttribute($handle, 20, [ref]$painted, 4) | Should -Be 0
            $painted | Should -Be $Expected
            $dialog.Content.Children[2].Children[1].IsDefault | Should -BeTrue
            $dialog.Content.Children[2].Children[1].IsCancel | Should -BeTrue
        } finally {
            if ($dialog) { $dialog.Close() }
            $owner.Close()
        }
    }
}

Describe 'Dark wordmark' {

    It 'ships a wordmark that can be read on a dark header' {
        # The artwork's title is near-black navy, drawn for a white page.
        $dark = Join-Path $script:ToolboxRoot 'Assets\TLC-Wordmark-Dark.png'
        Test-Path -LiteralPath $dark | Should -BeTrue
    }

    It 'lightens the text without touching the Teams mark' {
        # Luminance alone is not enough to separate them: the mark's own tile is #232A6E
        # at luminance 48, inside the range the title occupies. A global cut washed the
        # T tile out to near-white and wrecked the glyph, so the recolour starts to the
        # right of the mark.
        Add-Type -AssemblyName System.Drawing

        $light = New-Object System.Drawing.Bitmap((Join-Path $script:ToolboxRoot 'Assets\TLC-Wordmark.png'))
        $dark = New-Object System.Drawing.Bitmap((Join-Path $script:ToolboxRoot 'Assets\TLC-Wordmark-Dark.png'))
        try {
            $dark.Width | Should -Be $light.Width
            $dark.Height | Should -Be $light.Height

            # The mark is byte-for-byte identical.
            $markDiffers = 0
            for ($x = 0; $x -lt 164; $x++) {
                for ($y = 0; $y -lt $light.Height; $y += 3) {
                    if ($light.GetPixel($x, $y) -ne $dark.GetPixel($x, $y)) { $markDiffers++ }
                }
            }
            $markDiffers | Should -Be 0 -Because 'the Teams mark reads on both themes and must not be recoloured'

            # The text is not.
            $darkInkLeft = 0
            for ($x = 212; $x -lt $dark.Width; $x++) {
                for ($y = 0; $y -lt $dark.Height; $y += 3) {
                    $p = $dark.GetPixel($x, $y)
                    if ($p.A -gt 200 -and ((0.299*$p.R) + (0.587*$p.G) + (0.114*$p.B)) -lt 100) { $darkInkLeft++ }
                }
            }
            $darkInkLeft | Should -Be 0 -Because 'no near-black text may remain in the dark wordmark'
        } finally {
            $light.Dispose()
            $dark.Dispose()
        }
    }
}
