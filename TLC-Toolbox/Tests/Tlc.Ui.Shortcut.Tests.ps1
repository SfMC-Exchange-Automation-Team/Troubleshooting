#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
The toolbox's own icon, its taskbar identity, and the Start menu entry that shares both. Finding 341.

Every test that writes a shortcut writes it under TestDrive. Get-TlcShortcutPath is the only way the
module reaches the Start menu, so it is mocked for every test that could write, each of those tests
asserts the mock is the path that was used, and the last test in the file checks the real Start menu
is as it was found. A harness that quietly wrote to the real Start menu would otherwise pass every
assertion while doing the one thing it must not - and the first draft of the smoke script for this
did exactly that, for its own diagnostic line, until the line was read rather than trusted.
#>

BeforeAll {
    $script:ToolboxRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Localization.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Config.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Scope.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Theme.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Metrics.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Shortcut.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Wizard.psm1') -Force
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $script:ThisHost = (Get-Process -Id $PID).Path
    $script:ThemePath = Join-Path $script:ToolboxRoot 'Ui\Theme.xaml'
    $script:English = Get-TlcStringTable -Language 'en-US' -ToolboxRoot $script:ToolboxRoot

    # The real entry, recorded before anything here runs, for the test that closes the file.
    $script:RealEntry = Join-Path ([Environment]::GetFolderPath('Programs')) 'TLC Toolbox.lnk'
    $script:RealEntryBefore = if (Test-Path -LiteralPath $script:RealEntry) { (Get-Item -LiteralPath $script:RealEntry).LastWriteTimeUtc } else { $null }

    # A second copy of the toolbox, as far as a shortcut can tell: a folder with the launcher in it.
    $script:OtherCopy = Join-Path $TestDrive 'TLC-Toolbox-0.1.29'
    $null = New-Item -ItemType Directory -Path $script:OtherCopy -Force
    Set-Content -LiteralPath (Join-Path $script:OtherCopy 'Start-TlcToolbox.ps1') -Value '# stand-in' -Encoding ascii

    $script:NewLink = {
        param([string] $Path, [string] $Target, [string] $Arguments = '')
        $shell = New-Object -ComObject 'WScript.Shell'
        try {
            $link = $shell.CreateShortcut($Path)
            $link.TargetPath = $Target
            $link.Arguments = $Arguments
            $link.Save()
        } finally {
            $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
    $script:ReadLink = {
        param([string] $Path)
        $shell = New-Object -ComObject 'WScript.Shell'
        try {
            $link = $shell.CreateShortcut($Path)
            [pscustomobject]@{
                TargetPath = $link.TargetPath; Arguments = $link.Arguments; WorkingDirectory = $link.WorkingDirectory
                IconLocation = $link.IconLocation; Description = $link.Description; WindowStyle = $link.WindowStyle
            }
        } finally {
            $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

Describe 'The toolbox icon' {

    It 'ships every size drawn, small to large' {
        # Eight frames, each drawn at its own size by Tools\New-TlcIcon.ps1 rather than one image
        # scaled, which is what keeps the 16-pixel title bar icon legible.
        $path = Get-TlcIconPath
        $path | Should -Be (Join-Path $script:ToolboxRoot 'Assets\TLC-Toolbox.ico')
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue

        $stream = [System.IO.File]::OpenRead($path)
        try {
            $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder($stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            @($decoder.Frames | ForEach-Object { $_.PixelWidth } | Sort-Object) -join ',' | Should -Be '16,20,24,32,40,48,64,256'
            @($decoder.Frames | Where-Object { $_.PixelWidth -ne $_.PixelHeight }).Count | Should -Be 0
        } finally {
            $stream.Dispose()
        }

        (Import-PowerShellDataFile -LiteralPath (Join-Path $script:ToolboxRoot 'Tlc.psd1')).FileList | Should -Contain 'Assets\TLC-Toolbox.ico'
    }

    It 'names the icon of another copy when asked for one' {
        Get-TlcIconPath -ToolboxRoot $script:OtherCopy | Should -Be (Join-Path $script:OtherCopy 'Assets\TLC-Toolbox.ico')
    }

    It 'puts it on every window built from markup' {
        # Import-TlcXaml is the one door every XAML window comes through, so one call there
        # covers the wizard, the detail window and Settings.
        foreach ($file in 'Wizard.xaml', 'Detail.xaml', 'Settings.xaml') {
            $window = Import-TlcXaml -Path (Join-Path $script:ToolboxRoot "Ui\$file") -ThemePath $script:ThemePath
            $window.Icon | Should -Not -BeNullOrEmpty -Because "$file is a window, and without an icon it shows PowerShell's"
            $window.Icon.Decoder.Frames.Count | Should -Be 8 -Because 'the whole icon is handed over, so Windows picks the frame for each place'
        }
    }

    It 'puts it on the two windows built in code' {
        (Show-TlcCapabilityComparison -PassThru).Icon | Should -Not -BeNullOrEmpty

        $run = Join-Path $TestDrive 'run-for-picker'
        $null = New-Item -ItemType Directory -Path $run -Force
        (Show-TlcSessionLogPicker -RunPath @($run) -PassThru).Window.Icon | Should -Not -BeNullOrEmpty
    }

    It 'opens a window without one rather than failing, when the file is missing' {
        InModuleScope Tlc.Ui { $script:IconImage = $null }
        Mock -ModuleName Tlc.Ui Get-TlcIconPath { Join-Path $TestDrive 'no-such.ico' }
        try {
            $window = $null
            { $script:Loaded = Import-TlcXaml -Path (Join-Path $script:ToolboxRoot 'Ui\Settings.xaml') -ThemePath $script:ThemePath } | Should -Not -Throw
            $script:Loaded.Icon | Should -BeNullOrEmpty
            Set-TlcWindowIcon -Window (New-Object System.Windows.Window) | Should -BeFalse
            Should -Invoke Get-TlcIconPath -ModuleName Tlc.Ui -Times 1
        } finally {
            InModuleScope Tlc.Ui { $script:IconImage = $null }
        }
    }
}

Describe 'The taskbar identity' {

    It 'is set and read back through the manifest, in a process of its own' {
        <#
            A child process, because the ID belongs to the process and cannot be unset: setting
            it in the test host would regroup every window the rest of the suite opens. Through
            the manifest, because that is how the launcher reaches these functions, and a
            function missing from FunctionsToExport works in every test that imports module
            files directly and fails only in the product.
        #>
        $probe = Join-Path $TestDrive 'appid-probe.ps1'
        Set-Content -LiteralPath $probe -Encoding ascii -Value @'
param([string] $Manifest)
$ErrorActionPreference = 'Stop'
Import-Module $Manifest -Force
$before = Get-TlcProcessAppId
$set = Set-TlcProcessAppId -AppId (Get-TlcAppUserModelId)
$after = Get-TlcProcessAppId
"before=[$before] set=[$set] after=[$after]"
'@
        $output = & $script:ThisHost -NoProfile -ExecutionPolicy Bypass -File $probe -Manifest (Join-Path $script:ToolboxRoot 'Tlc.psd1') 2>&1 | Out-String
        $output | Should -Match 'before=\[\] set=\[True\] after=\[Microsoft\.SfMC\.TLCToolbox\]'
    }

    It 'refuses an ID that Windows would refuse, before asking Windows' {
        { Set-TlcProcessAppId -AppId 'has a space' } | Should -Throw
        { Set-TlcProcessAppId -AppId ('x' * 129) } | Should -Throw
    }

    It 'carries no version, so a pin survives an update' {
        Get-TlcAppUserModelId | Should -Not -Match '\d'
    }

    It 'shares the one native compile the title bar already pays for' {
        # A second Add-Type costs 0.4 to 0.6 seconds on Windows PowerShell 5.1, at every start.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Theme.psm1'), [ref]$null, [ref]$null)
        $compiles = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' }, $true))
        $compiles.Count | Should -Be 1
        $compiles[0].Extent.Text | Should -Match 'NativeChromeMembers'
    }

    It 'is set by the launcher after the import, before the window, and only in its own process' {
        <#
            Before the window because the taskbar reads the ID when a button is created and never
            again. Only with -NoRelaunch because that is how the .cmd, the Start menu entry and the
            STA relaunch start it; without it the process is the operator's console or the ISE.
        #>
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ToolboxRoot 'Start-TlcToolbox.ps1'), [ref]$null, [ref]$null)
        $find = { param([string] $Name) @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }.GetNewClosure(), $true)) }
        # Wrapped again at the call: a scriptblock's single result comes back as the bare node,
        # and .Count on that throws under the gate's strict mode.
        $set = @(& $find 'Set-TlcProcessAppId')
        $show = @(& $find 'Show-TlcWizard')
        $import = @(& $find 'Import-Module' | Where-Object { $_.Extent.Text -match '\$manifest' -and $_.Extent.Text -match 'ErrorAction Stop' })

        $set.Count | Should -Be 1
        $show.Count | Should -Be 1
        $import.Count | Should -Be 2 -Because 'installation imports the module too, without opening the wizard'
        $set[0].Extent.Text | Should -Match 'Get-TlcAppUserModelId'
        $set[0].Extent.StartOffset | Should -BeGreaterThan $import[-1].Extent.StartOffset
        $set[0].Extent.StartOffset | Should -BeLessThan $show[0].Extent.StartOffset

        $guard = $set[0].Parent
        while ($guard -and $guard -isnot [System.Management.Automation.Language.IfStatementAst]) { $guard = $guard.Parent }
        $guard | Should -Not -BeNullOrEmpty -Because 'an operator''s own console is not the toolbox''s to re-badge'
        $guard.Clauses[0].Item1.Extent.Text | Should -Be '$NoRelaunch'
    }
}

Describe 'The Start menu entry' {

    BeforeEach {
        $script:Entry = Join-Path $TestDrive ("start-{0}\TLC Toolbox.lnk" -f [guid]::NewGuid().ToString('N'))
        Mock -ModuleName Tlc.Ui.Shortcut Get-TlcShortcutPath { $script:Entry }
    }

    It 'reads None when there is no entry' {
        (Get-TlcShortcutState -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'None'
        Should -Invoke Get-TlcShortcutPath -ModuleName Tlc.Ui.Shortcut -Times 1
    }

    It 'adds an entry that opens this copy with the launcher''s own command line, the icon and the ID' {
        $state = Install-TlcShortcut -ToolboxRoot $script:ToolboxRoot
        $state.State | Should -Be 'Here'
        $state.Path | Should -Be $script:Entry -Because 'the entry has to land where the mock says, not in the real Start menu'
        Test-Path -LiteralPath $script:Entry | Should -BeTrue

        $link = & $script:ReadLink $script:Entry
        $link.TargetPath | Should -Be (Join-Path $script:ToolboxRoot 'TLC-Toolbox.exe')
        $link.WorkingDirectory | Should -Be $script:ToolboxRoot
        $link.IconLocation | Should -Be ((Join-Path $script:ToolboxRoot 'TLC-Toolbox.exe') + ',0')
        $link.WindowStyle | Should -Be 1 -Because 'the WinExe launcher has no console to hide'
        $link.Description | Should -Not -BeNullOrEmpty

        $link.Arguments | Should -BeExactly ''

        Get-TlcShortcutAppId -Path $script:Entry | Should -BeExactly (Get-TlcAppUserModelId) -Because 'without it the entry and the running window are two apps to the taskbar'
        Should -Invoke Get-TlcShortcutPath -ModuleName Tlc.Ui.Shortcut
    }

    It 'reads an entry that opens another copy as Elsewhere, and adding again points it here' {
        $null = Install-TlcShortcut -ToolboxRoot $script:OtherCopy
        $state = Get-TlcShortcutState -ToolboxRoot $script:ToolboxRoot
        $state.State | Should -Be 'Elsewhere'
        $state.Opens | Should -Be $script:OtherCopy

        (Install-TlcShortcut -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'Here'
        (& $script:ReadLink $script:Entry).WorkingDirectory | Should -Be $script:ToolboxRoot
    }

    It 'counts a shortcut made by hand to the .cmd as a toolbox entry' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:Entry) -Force
        & $script:NewLink $script:Entry (Join-Path $script:ToolboxRoot 'Start-TlcToolbox.cmd')
        (Get-TlcShortcutState -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'Here'
    }

    It 'leaves a file of the same name alone when it is not a toolbox entry' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:Entry) -Force
        $notepad = Join-Path ([Environment]::SystemDirectory) 'notepad.exe'
        & $script:NewLink $script:Entry $notepad

        (Get-TlcShortcutState -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'Foreign'
        { Install-TlcShortcut -ToolboxRoot $script:ToolboxRoot } | Should -Throw '*different shortcut*'
        (Uninstall-TlcShortcut -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'Foreign'
        (& $script:ReadLink $script:Entry).TargetPath | Should -Be $notepad -Because 'neither adding nor removing may touch somebody else''s shortcut'
    }

    It 'removes the entry, whichever copy it opens' {
        $null = Install-TlcShortcut -ToolboxRoot $script:ToolboxRoot
        (Uninstall-TlcShortcut -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'None'
        Test-Path -LiteralPath $script:Entry | Should -BeFalse

        $null = Install-TlcShortcut -ToolboxRoot $script:OtherCopy
        (Uninstall-TlcShortcut -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'None'
        Test-Path -LiteralPath $script:Entry | Should -BeFalse
    }

    It 'refuses to make an entry for a folder with no toolbox in it' {
        $empty = Join-Path $TestDrive 'not-a-toolbox'
        $null = New-Item -ItemType Directory -Path $empty -Force
        { Install-TlcShortcut -ToolboxRoot $empty } | Should -Throw '*no toolbox*'
        Test-Path -LiteralPath $script:Entry | Should -BeFalse
    }
}

Describe 'The Start menu row in the Settings window' {
    <#
        Through the real window: Show-TlcSettingsWindow -PassThru builds it and wires its handlers
        without showing it, and the button is pressed by raising its Click event, so what runs is
        the handler the operator's click runs, closure and all.
    #>

    BeforeEach {
        $script:Entry = Join-Path $TestDrive ("start-{0}\TLC Toolbox.lnk" -f [guid]::NewGuid().ToString('N'))
        Mock -ModuleName Tlc.Ui.Shortcut Get-TlcShortcutPath { $script:Entry }
        $script:Open = {
            param([string] $Language = 'en-US')
            Show-TlcSettingsWindow -Owner (New-Object System.Windows.Window) -ToolboxRoot $script:ToolboxRoot -ThemePath $script:ThemePath -Current $Language -PassThru
        }
        $script:Press = {
            param($Button)
            $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
    }

    It 'offers Add, then Remove, then Add, each drawn from the entry on disk' {
        $shown = & $script:Open
        $shown.Element.ShortcutButtonText.Text | Should -Be $script:English['ShortcutAddButton']
        $shown.Element.ShortcutHint.Text | Should -Be $script:English['ShortcutHintNone']
        $shown.Element.SettingsShortcutLabel.Text | Should -Be $script:English['SettingsShortcutLabel']

        & $script:Press $shown.Element.ShortcutButton
        Test-Path -LiteralPath $script:Entry | Should -BeTrue
        $shown.Element.ShortcutButtonText.Text | Should -Be $script:English['ShortcutRemoveButton']
        $shown.Element.ShortcutHint.Text | Should -Be $script:English['ShortcutHintHere']

        & $script:Press $shown.Element.ShortcutButton
        Test-Path -LiteralPath $script:Entry | Should -BeFalse
        $shown.Element.ShortcutButtonText.Text | Should -Be $script:English['ShortcutAddButton']
        Should -Invoke Get-TlcShortcutPath -ModuleName Tlc.Ui.Shortcut
    }

    It 'names the other copy, and offers to point the entry here' {
        $null = Install-TlcShortcut -ToolboxRoot $script:OtherCopy
        $shown = & $script:Open
        $shown.Element.ShortcutButtonText.Text | Should -Be $script:English['ShortcutAddButton']
        $shown.Element.ShortcutHint.Text | Should -Be ($script:English['ShortcutHintElsewhere'] -f $script:OtherCopy)

        & $script:Press $shown.Element.ShortcutButton
        (Get-TlcShortcutState -ToolboxRoot $script:ToolboxRoot).State | Should -Be 'Here'
        $shown.Element.ShortcutButtonText.Text | Should -Be $script:English['ShortcutRemoveButton']
    }

    It 'shows a failure in the hint, and the button as the entry really is' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:Entry) -Force
        & $script:NewLink $script:Entry (Join-Path ([Environment]::SystemDirectory) 'notepad.exe')
        $shown = & $script:Open

        & $script:Press $shown.Element.ShortcutButton
        $prefix = ($script:English['ShortcutFailed'] -split '\{0\}')[0]
        $shown.Element.ShortcutHint.Text | Should -BeLike "$prefix*different shortcut*"
        $shown.Element.ShortcutButtonText.Text | Should -Be $script:English['ShortcutAddButton']
    }

    It 'fits the row in the window in every language' {
        <#
            Laid out for real, in every shipped language: shown off screen, unactivated, and left
            to the dispatcher, the way the wizard's own layout tests do it. Measure and Arrange on
            a window that was never shown size nothing, and every column read 0 - a first draft of
            this test failed on exactly that, which is the layout not happening, not the layout
            being wrong.

            The label column is shared with Language and Appearance, so a long label in either grid
            widens both, and the button and its hint must keep a usable width beside it. The button
            label wraps rather than widening the button past a window that cannot be resized.

            "Shown in full" is measured, not assumed, in two steps. The block's right edge must
            fall inside the window's content: a block that does not wrap and is wider than its
            cell is still arranged at its full width and merely clipped, so its own size says
            nothing - the mutation that stopped the hint wrapping passed this test until the edge
            was checked. Then a detached copy of the text, in the same font at the block's own
            width, must need no more height than the block has.
        #>
        $cut = {
            param([System.Windows.Controls.TextBlock] $Block, $Content)
            $right = $Block.TranslatePoint((New-Object System.Windows.Point($Block.ActualWidth, 0)), $Content).X
            if ($right -gt $Content.ActualWidth + 0.5) { return $true }
            $copy = New-Object System.Windows.Controls.TextBlock
            foreach ($property in 'Text', 'FontFamily', 'FontSize', 'FontWeight', 'FontStyle', 'FontStretch', 'Padding', 'LineHeight', 'Language', 'TextWrapping') {
                $copy.$property = $Block.$property
            }
            $width = if ($Block.TextWrapping -eq [System.Windows.TextWrapping]::NoWrap) { [double]::PositiveInfinity } else { $Block.ActualWidth + 0.5 }
            $copy.Measure((New-Object System.Windows.Size($width, [double]::PositiveInfinity)))
            ($copy.DesiredSize.Width -gt $Block.ActualWidth + 0.5) -or ($copy.DesiredSize.Height -gt $Block.ActualHeight + 0.5)
        }

        $languages = @(Get-TlcLanguage)
        $languages.Count | Should -BeGreaterThan 1 -Because 'the loop below carries the only assertions'
        $tooTight = [System.Collections.Generic.List[string]]::new()
        foreach ($language in $languages) {
            $shown = & $script:Open $language.Tag
            $window = $shown.Window
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -32000; $window.Top = -32000
            $window.ShowActivated = $false
            $window.Show()
            try {
                $null = $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::ContextIdle)
                $window.UpdateLayout()

                $button = $shown.Element.ShortcutButton
                $field = $button.Parent.ColumnDefinitions[1].ActualWidth
                $labelColumn = $button.Parent.ColumnDefinitions[0].ActualWidth
                $languageColumn = $shown.Element.SettingsLanguageLabel.Parent.ColumnDefinitions[0].ActualWidth

                if ($field -lt 220) { $tooTight.Add("$($language.Tag): $field px left for the button") }
                if ($button.ActualWidth -gt $field + 0.5) { $tooTight.Add("$($language.Tag): button $($button.ActualWidth) px in $field") }
                if ([Math]::Abs($labelColumn - $languageColumn) -gt 0.5) { $tooTight.Add("$($language.Tag): label columns $labelColumn and $languageColumn do not line up") }
                foreach ($name in 'SettingsShortcutLabel', 'ShortcutButtonText', 'ShortcutHint') {
                    $block = $shown.Element[$name]
                    if ([string]::IsNullOrWhiteSpace($block.Text) -or $block.Text -match '^(Settings)?Shortcut\w+$') { $tooTight.Add("$($language.Tag): $name shows no text of its own") }
                    elseif (& $cut $block $window.Content) { $tooTight.Add("$($language.Tag): $name is cut off") }
                }
            } finally {
                $window.Close()
            }
        }
        $tooTight -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'This file' {

    It 'left the real Start menu as it found it' {
        $now = if (Test-Path -LiteralPath $script:RealEntry) { (Get-Item -LiteralPath $script:RealEntry).LastWriteTimeUtc } else { $null }
        $now | Should -Be $script:RealEntryBefore -Because 'every write above was meant for TestDrive'
    }
}
