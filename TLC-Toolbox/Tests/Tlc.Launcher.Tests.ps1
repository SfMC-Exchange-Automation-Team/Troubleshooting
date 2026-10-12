#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Root 'Tlc.psd1') -Force -DisableNameChecking
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
}

Describe 'Normal Windows launcher identity' {
    It 'recognizes the main wizard rather than reporting a startup error dialog as ready' {
        $assembly = [Reflection.Assembly]::LoadFrom((Join-Path $script:Root 'TLC-Toolbox.exe'))
        $method = $assembly.GetType('TlcLauncher').GetMethod('HasWizardTitle', [Reflection.BindingFlags]'NonPublic, Static')
        $method | Should -Not -BeNullOrEmpty
        $window = Import-TlcXaml -Path (Join-Path $script:Root 'Ui\Wizard.xaml')
        $method.Invoke($null, @($window.Title + '  0.1.59')) | Should -BeTrue
        $method.Invoke($null, @('TLC Toolbox')) | Should -BeFalse
        $method.Invoke($null, @('TLC Toolbox could not start')) | Should -BeFalse
        $method.Invoke($null, @('')) | Should -BeFalse
    }

    It 'ships a WinExe with the toolbox icon and version, rather than a renamed console script' {
        $path = Join-Path $script:Root 'TLC-Toolbox.exe'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($path)
        [Text.Encoding]::ASCII.GetString($bytes, 0, 2) | Should -BeExactly 'MZ'
        $pe = [BitConverter]::ToInt32($bytes, 0x3c)
        [BitConverter]::ToUInt16($bytes, $pe + 24 + 68) | Should -Be 2 -Because 'subsystem2 is Windows GUI, not a console'
        [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductName | Should -BeExactly 'TLC Toolbox'
        [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion | Should -BeExactly '0.1.59.0'
        $icon = [Drawing.Icon]::ExtractAssociatedIcon($path)
        $expected = [Drawing.Icon]::new((Join-Path $script:Root 'Assets\TLC-Toolbox.ico'), $icon.Width, $icon.Height)
        $actualBitmap = $icon.ToBitmap()
        $expectedBitmap = $expected.ToBitmap()
        try {
            $actualPixels = [Collections.Generic.List[int]]::new()
            $expectedPixels = [Collections.Generic.List[int]]::new()
            for ($y = 0; $y -lt $icon.Height; $y++) {
                for ($x = 0; $x -lt $icon.Width; $x++) {
                    $actualPixels.Add($actualBitmap.GetPixel($x, $y).ToArgb())
                    $expectedPixels.Add($expectedBitmap.GetPixel($x, $y).ToArgb())
                }
            }
            ($actualPixels -join ',') | Should -BeExactly ($expectedPixels -join ',')
        } finally {
            $actualBitmap.Dispose(); $expectedBitmap.Dispose()
            $expected.Dispose(); $icon.Dispose()
        }
    }

    It 'sets actual window pin/relaunch properties to the EXE with its matching stable app ID' {
        $window = Import-TlcXaml -Path (Join-Path $script:Root 'Ui\Wizard.xaml')
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -32000; $window.Top = -32000
        $window.ShowActivated = $false; $window.ShowInTaskbar = $false
        try {
            $window.Show()
            Set-TlcWindowLauncherIdentity -Window $window -ToolboxRoot $script:Root
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            [Tlc.ShellLink]::ReadWindowProperty($handle, 2) | Should -BeExactly ('"' + (Join-Path $script:Root 'TLC-Toolbox.exe') + '"')
            [Tlc.ShellLink]::ReadWindowProperty($handle, 3) | Should -BeExactly ((Join-Path $script:Root 'TLC-Toolbox.exe') + ',0')
            [Tlc.ShellLink]::ReadWindowProperty($handle, 4) | Should -BeExactly 'TLC Toolbox'
            [Tlc.ShellLink]::ReadWindowProperty($handle, 5) | Should -BeExactly 'Microsoft.SfMC.TLCToolbox'
        } finally { $window.Close() }
    }
}

Describe 'Verified per-user installation' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source = Join-Path $fixture 'download'
        $installed = Join-Path $fixture 'Programs\TLC-Toolbox'
        $link = Join-Path $fixture 'Start menu\TLC Toolbox.lnk'
        $null = New-Item -ItemType Directory -Path $source -Force
        Copy-Item -LiteralPath (Join-Path $script:Root 'TLC-Toolbox.exe') -Destination $source
        Set-Content -LiteralPath (Join-Path $source 'Start-TlcToolbox.ps1') -Value '# isolated test payload' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $source 'Tlc.psd1') -Value @"
@{ GUID = 'c4e9a17b-5d2f-4a86-9f31-7b0c8e5d24af'; ModuleVersion = '0.1.59'; FileList = @('Tlc.psd1','Start-TlcToolbox.ps1','TLC-Toolbox.exe') }
"@ -Encoding ascii
        Mock Get-TlcShortcutPath -ModuleName Tlc.Ui.Shortcut { $link }
        Mock Get-CimInstance -ModuleName Tlc.Ui.Shortcut { @() }
    }

    It 'installs verified declared files and creates an EXE shortcut without a source-folder dependency' {
        Set-Content -LiteralPath (Join-Path $source 'private.local.psd1') -Value '# must not copy' -Encoding ascii
        $result = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        $result.InstallRoot | Should -BeExactly $installed
        $result.Shortcut | Should -BeExactly $link
        Test-Path -LiteralPath (Join-Path $installed 'private.local.psd1') | Should -BeFalse
        (Get-TlcShortcutState -ToolboxRoot $installed).State | Should -BeExactly 'Here'
        [Tlc.ShellLink]::ReadAppUserModelId($link) | Should -BeExactly 'Microsoft.SfMC.TLCToolbox'
        foreach ($name in 'Tlc.psd1', 'Start-TlcToolbox.ps1', 'TLC-Toolbox.exe') {
            (Get-TlcFileHash -Path (Join-Path $source $name)) | Should -BeExactly (Get-TlcFileHash -Path (Join-Path $installed $name))
        }
        $shell = New-Object -ComObject WScript.Shell
        try {
            $entry = $shell.CreateShortcut($link)
            $entry.TargetPath | Should -BeExactly (Join-Path $installed 'TLC-Toolbox.exe')
            $entry.IconLocation | Should -BeExactly ((Join-Path $installed 'TLC-Toolbox.exe') + ',0')
            $entry.Arguments | Should -BeExactly ''
        } finally { $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    It 'does not overwrite a foreign destination' {
        $null = New-Item -ItemType Directory -Path $installed -Force
        Set-Content -LiteralPath (Join-Path $installed 'unrelated.txt') -Value 'retain' -Encoding ascii
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*other than TLC*'
        Get-Content -LiteralPath (Join-Path $installed 'unrelated.txt') | Should -BeExactly 'retain'
    }

    It 'rejects missing payload entries before creating an installation' {
        Remove-Item -LiteralPath (Join-Path $source 'TLC-Toolbox.exe')
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*incomplete*'
        Test-Path -LiteralPath $installed | Should -BeFalse
    }

    It 'refuses update while an installed toolbox process is still active' {
        $null = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        Mock Get-CimInstance -ModuleName Tlc.Ui.Shortcut {
            [pscustomobject]@{ ProcessId = -1; ExecutablePath = (Join-Path $installed 'TLC-Toolbox.exe'); CommandLine = '' }
        }
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*current run finishes*'
        Test-Path -LiteralPath (Join-Path $installed 'TLC-Toolbox.exe') | Should -BeTrue
    }

    It 'updates the stable path while retaining the old installation and user-added files in a backup' {
        $null = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        Set-Content -LiteralPath (Join-Path $installed 'user-added.txt') -Value 'retain' -Encoding ascii
        $result = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        $result.BackupPath | Should -Not -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path $result.BackupPath 'user-added.txt') | Should -BeExactly 'retain'
        $result.InstallRoot | Should -BeExactly $installed
        (Get-TlcShortcutState -ToolboxRoot $installed).State | Should -BeExactly 'Here'
    }

    It 'refuses a downgrade' {
        $null = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        $manifest = Join-Path $source 'Tlc.psd1'
        (Get-Content -LiteralPath $manifest -Raw).Replace("'0.1.59'", "'0.1.58'") | Set-Content -LiteralPath $manifest -Encoding ascii
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*not been downgraded*'
        (Import-PowerShellDataFile -LiteralPath (Join-Path $installed 'Tlc.psd1')).ModuleVersion | Should -BeExactly '0.1.59'
    }

    It 'rejects a manifest attempting to copy outside its source folder' {
        $manifest = Join-Path $source 'Tlc.psd1'
        (Get-Content -LiteralPath $manifest -Raw).Replace("'TLC-Toolbox.exe')", "'TLC-Toolbox.exe','..\outside.txt')") | Set-Content -LiteralPath $manifest -Encoding ascii
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*Unsafe installation payload path*'
        Test-Path -LiteralPath $installed | Should -BeFalse
    }

    It 'recognizes an active PowerShell host even if its installed script path uses different casing' {
        $null = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        Mock Get-CimInstance -ModuleName Tlc.Ui.Shortcut {
            [pscustomobject]@{ ProcessId = -1; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = ('-File "' + $installed.ToLowerInvariant() + '\Start-TlcToolbox.ps1"') }
        }
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*current run finishes*'
    }

    It 'restores the old program and shortcut when the post-copy shortcut write fails' {
        $null = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        $hash = Get-TlcFileHash -Path $link
        Set-Content -LiteralPath (Join-Path $installed 'user-added.txt') -Value 'retain' -Encoding ascii
        Mock Install-TlcShortcut -ModuleName Tlc.Ui.Shortcut { throw 'simulated shortcut write failure' }
        { Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed } | Should -Throw '*simulated shortcut write failure*'
        Get-Content -LiteralPath (Join-Path $installed 'user-added.txt') | Should -BeExactly 'retain'
        Get-TlcFileHash -Path $link | Should -BeExactly $hash
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $installed) -Filter 'TLC-Toolbox.installing-*').Count | Should -Be 0
    }

    It 'repairs a shortcut in place using the same installation result shape' {
        $null = Install-TlcApplication -ToolboxRoot $source -InstallRoot $installed
        $result = Install-TlcApplication -ToolboxRoot $installed -InstallRoot $installed
        $result.InstallRoot | Should -BeExactly $installed
        $result.Shortcut | Should -BeExactly $link
        $result.BackupPath | Should -BeExactly ''
    }
}
