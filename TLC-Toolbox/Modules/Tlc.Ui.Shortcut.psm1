Set-StrictMode -Version Latest

<#
    The Start menu entry: TLC Toolbox under its own name and icon, made on request from the
    Settings window.

    The native launcher installs the manifest-only payload into a stable per-user folder and
    creates the shortcut on that machine. The EXE embeds the toolbox icon; shortcuts are not
    prebuilt with somebody else's absolute paths. The unsigned beta still requires approved
    application policy. No Start or taskbar pin is changed automatically.

    WHY ONLY THE START MENU

    It is the one place Windows looks up an AppUserModelID (below), and pinning to the taskbar
    or to Start is a right-click away from it. A desktop shortcut was left out on purpose: a
    desktop under OneDrive folder redirection syncs to the operator's other PCs, where the
    shortcut points at a folder that is not there and opens nothing, with no error, because the
    launcher runs hidden.

    WHY THE APP ID

    The launcher gives its process an explicit AppUserModelID (Set-TlcProcessAppId). Without
    one the window belongs to powershell.exe as far as the taskbar is concerned: it groups with
    PowerShell consoles, and pinning it pins PowerShell. The entry carries the same ID, which is
    how Windows ties the running window to it: one button, this icon, and a pin that reopens
    the toolbox. Finding 341.
#>

$script:ShortcutFileName = 'TLC Toolbox.lnk'

<#
    IShellLinkW and IPropertyStore, because WScript.Shell can write a shortcut but cannot set
    the AppUserModelID on it, and without the ID the entry and the running window are two
    different apps to the taskbar.

    Compiled on first use only, when the operator asks for the entry. Measured 2026-10-05 in a
    process that had already compiled the window helpers, as the wizard has by then: 0.6 to 2.1
    seconds on Windows PowerShell 5.1 and about 0.7 on PowerShell 7. Opening the Settings window
    does not pay it, because reading an entry goes through WScript.Shell, measured at 26 to 56
    ms. C# 5, the language Windows PowerShell's compiler accepts.

    The interface methods are declared in vtable order and nowhere else matters: COM calls by
    slot, so a missing or reordered method calls the wrong function rather than failing.
    PROPVARIANT is laid out by hand for the one arm used, a wide string, and is 16 bytes on
    x86 and 24 on x64 because its payload is two pointers wide.
#>
$script:ShellLinkSource = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace Tlc
{
    public static class ShellLink
    {
        [ComImport]
        [Guid("000214F9-0000-0000-C000-000000000046")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW
        {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int size, IntPtr findData, uint flags);
            void GetIDList(out IntPtr idList);
            void SetIDList(IntPtr idList);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int size);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int size);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int size);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
            void GetHotkey(out ushort hotkey);
            void SetHotkey(ushort hotkey);
            void GetShowCmd(out int showCommand);
            void SetShowCmd(int showCommand);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int size, out int iconIndex);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relativePath, uint reserved);
            void Resolve(IntPtr window, uint flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
        }

        [ComImport]
        [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            void GetCount(out uint count);
            void GetAt(uint index, out PropertyKey key);
            void GetValue(ref PropertyKey key, out PropVariant value);
            void SetValue(ref PropertyKey key, ref PropVariant value);
            void Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey
        {
            public Guid FormatId;
            public uint PropertyId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PropVariant
        {
            public ushort VarType;
            public ushort Reserved1;
            public ushort Reserved2;
            public ushort Reserved3;
            public IntPtr Value;
            public IntPtr Value2;
        }

        [ComImport]
        [Guid("00021401-0000-0000-C000-000000000046")]
        private class ShellLinkObject
        {
        }

        [DllImport("ole32.dll", PreserveSig = true)]
        private static extern int PropVariantClear(ref PropVariant value);
        [DllImport("shell32.dll", PreserveSig = true)]
        private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, out IPropertyStore store);

        private const ushort VarTypeWideString = 31;

        // PKEY_AppUserModel_ID, from propkey.h.
        private static PropertyKey AppUserModelIdKey()
        {
            PropertyKey key = new PropertyKey();
            key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            key.PropertyId = 5;
            return key;
        }

        private static void SetString(IPropertyStore store, uint id, string text)
        {
            PropertyKey key = AppUserModelIdKey();
            key.PropertyId = id;
            PropVariant value = new PropVariant();
            value.VarType = VarTypeWideString;
            value.Value = Marshal.StringToCoTaskMemUni(text);
            try { store.SetValue(ref key, ref value); }
            finally { PropVariantClear(ref value); }
        }

        public static void SetWindowLauncher(IntPtr window, string launcher, string appId)
        {
            Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
            try
            {
                SetString(store, 2, "\"" + launcher + "\"");
                SetString(store, 3, launcher + ",0");
                SetString(store, 4, "TLC Toolbox");
                SetString(store, 5, appId);
                store.Commit();
            }
            finally { Marshal.FinalReleaseComObject(store); }
        }

        public static string ReadWindowProperty(IntPtr window, uint id)
        {
            Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
            try
            {
                PropertyKey key = AppUserModelIdKey();
                key.PropertyId = id;
                PropVariant value;
                store.GetValue(ref key, out value);
                try { return value.VarType == VarTypeWideString ? Marshal.PtrToStringUni(value.Value) : null; }
                finally { PropVariantClear(ref value); }
            }
            finally { Marshal.FinalReleaseComObject(store); }
        }

        public static void Save(string path, string target, string arguments, string workingDirectory,
            string iconPath, int iconIndex, string description, int showCommand, string appUserModelId)
        {
            object instance = new ShellLinkObject();
            try
            {
                IShellLinkW link = (IShellLinkW)instance;
                link.SetPath(target);
                link.SetArguments(arguments);
                link.SetWorkingDirectory(workingDirectory);
                link.SetIconLocation(iconPath, iconIndex);
                link.SetDescription(description);
                link.SetShowCmd(showCommand);

                if (!String.IsNullOrEmpty(appUserModelId))
                {
                    IPropertyStore store = (IPropertyStore)instance;
                    PropertyKey key = AppUserModelIdKey();
                    PropVariant value = new PropVariant();
                    value.VarType = VarTypeWideString;
                    value.Value = Marshal.StringToCoTaskMemUni(appUserModelId);
                    try
                    {
                        store.SetValue(ref key, ref value);
                        store.Commit();
                    }
                    finally
                    {
                        PropVariantClear(ref value);
                    }
                }

                ((IPersistFile)instance).Save(path, true);
            }
            finally
            {
                Marshal.FinalReleaseComObject(instance);
            }
        }

        public static string ReadAppUserModelId(string path)
        {
            object instance = new ShellLinkObject();
            try
            {
                ((IPersistFile)instance).Load(path, 0);
                IPropertyStore store = (IPropertyStore)instance;
                PropertyKey key = AppUserModelIdKey();
                PropVariant value;
                store.GetValue(ref key, out value);
                try
                {
                    if (value.VarType == VarTypeWideString && value.Value != IntPtr.Zero)
                    {
                        return Marshal.PtrToStringUni(value.Value);
                    }
                    return null;
                }
                finally
                {
                    PropVariantClear(ref value);
                }
            }
            finally
            {
                Marshal.FinalReleaseComObject(instance);
            }
        }
    }
}
'@

function Get-TlcAppUserModelId {
    <#
    .SYNOPSIS
        The toolbox's taskbar identity, shared by the launcher and the Start menu entry.
    .DESCRIPTION
        Company.Product, with no version in it. Windows ties a pin to this ID, so a version
        would orphan every pin at each update.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'Microsoft.SfMC.TLCToolbox'
}

function Get-TlcShortcutPath {
    <#
    .SYNOPSIS
        Where the Start menu entry lives: the current user's Start menu Programs folder.
    .DESCRIPTION
        Per user, so it needs no elevation and changes nothing for anyone else on the machine.
        Every other function here reaches the Start menu only through this one, which is what
        lets the tests point the whole module at a temporary folder and prove they did.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $programs = [Environment]::GetFolderPath('Programs')
    if ([string]::IsNullOrWhiteSpace($programs)) { throw 'This account has no Start menu folder.' }
    return (Join-Path $programs $script:ShortcutFileName)
}

function ConvertTo-TlcShortcutRoot {
    <#
    .SYNOPSIS
        A toolbox folder in the one spelling used for comparing two of them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-TlcShortcutCommand {
    <#
    .SYNOPSIS
        What the Start menu entry runs, for a given copy of the toolbox.
    .DESCRIPTION
        The command line Start-TlcToolbox.cmd uses, so the entry and a double-click open the
        toolbox the same way: Windows PowerShell, STA for WPF, no profile, a hidden console,
        and -NoRelaunch, which is also how the launcher knows the process is its own and so
        sets the taskbar identity. A test holds the two command lines to each other.

        Windows PowerShell by its full path, not its name: a shortcut searches no PATH, and the
        System32 copy is present on every Windows the toolbox supports.

        Show command 7, minimised and not activated, is for the console PowerShell creates
        before it can hide it; started normally, it flashes a black window first. Measured
        2026-10-05 with a WPF window launched through a shortcut both ways: with 1 and with 7
        the window opened normal, active and in the foreground, and the console stayed hidden.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )

    $root = ConvertTo-TlcShortcutRoot -Path $ToolboxRoot
    $native = Join-Path $root 'TLC-Toolbox.exe'
    if (Test-Path -LiteralPath $native -PathType Leaf) {
        return [pscustomobject]@{
            TargetPath = $native; Arguments = ''; WorkingDirectory = $root
            IconPath = $native; IconIndex = 0; Description = 'Teams Log Collection Toolbox'
            ShowCommand = 1; AppUserModelId = Get-TlcAppUserModelId
        }
    }
    return [pscustomobject]@{
        TargetPath       = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        Arguments        = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -NoRelaunch' -f (Join-Path $root 'Start-TlcToolbox.ps1')
        WorkingDirectory = $root
        IconPath         = Get-TlcIconPath -ToolboxRoot $root
        IconIndex        = 0
        Description      = 'Teams Log Collection Toolbox'
        ShowCommand      = 7
        AppUserModelId   = Get-TlcAppUserModelId
    }
}

function Read-TlcShortcutRoot {
    <#
    .SYNOPSIS
        Which toolbox folder a shortcut opens, and whether it is a toolbox shortcut at all.
    .DESCRIPTION
        A toolbox shortcut runs Start-TlcToolbox.ps1, as the entry made here does, or targets
        Start-TlcToolbox.cmd, as one an operator made by hand would. Anything else of the same
        name is somebody else's, and an unreadable file is treated the same way: nothing here
        overwrites or deletes a file it cannot show is its own.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $shell = $null
    try {
        $shell = New-Object -ComObject 'WScript.Shell'
        $link = $shell.CreateShortcut($Path)
        $arguments = [string]$link.Arguments
        $target = [string]$link.TargetPath

        $file = ''
        $named = [regex]::Match($arguments, '(?i)-File\s+(?:"(?<quoted>[^"]+)"|(?<bare>\S+))')
        if ($named.Success) {
            $file = if ($named.Groups['quoted'].Success) { $named.Groups['quoted'].Value } else { $named.Groups['bare'].Value }
        }
        $opens = ''
        if ($file -match '(?i)(^|\\)Start-TlcToolbox\.ps1$') { $opens = $file }
        elseif ($target -match '(?i)(^|\\)Start-TlcToolbox\.cmd$') { $opens = $target }
        elseif ($target -match '(?i)(^|\\)TLC-Toolbox\.exe$') { $opens = $target }
        if (-not $opens) { return [pscustomobject]@{ Ours = $false; Root = '' } }

        $parent = Split-Path -Parent $opens
        $root = if ($parent) { ConvertTo-TlcShortcutRoot -Path $parent } else { '' }
        return [pscustomobject]@{ Ours = $true; Root = $root }
    } catch {
        Write-Verbose "The shortcut at $Path could not be read: $($_.Exception.Message)"
        return [pscustomobject]@{ Ours = $false; Root = '' }
    } finally {
        if ($null -ne $shell) { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Get-TlcShortcutState {
    <#
    .SYNOPSIS
        Whether the Start menu entry exists, and which copy of the toolbox it opens.
    .DESCRIPTION
        One of four states:

          None       no entry.
          Here       an entry that opens the copy at -ToolboxRoot.
          Elsewhere  an entry that opens another copy. The usual case after an update: it
                     still opens the folder it was made from, which may since have gone.
          Foreign    a file of the same name that is not a toolbox entry, which nothing here
                     will overwrite or remove.

        Opens is the folder the entry opens, for Here and Elsewhere.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )

    $path = Get-TlcShortcutPath
    $state = 'None'
    $opens = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $read = Read-TlcShortcutRoot -Path $path
        if (-not $read.Ours) {
            $state = 'Foreign'
        } else {
            $opens = $read.Root
            $here = ConvertTo-TlcShortcutRoot -Path $ToolboxRoot
            $state = if ([string]::Equals($read.Root, $here, [System.StringComparison]::OrdinalIgnoreCase)) { 'Here' } else { 'Elsewhere' }
        }
    }
    return [pscustomobject]@{ State = $state; Path = $path; Opens = $opens }
}

function Initialize-TlcShellLink {
    <#
    .SYNOPSIS
        Compiles the shortcut writer if this process has not.
    #>
    [CmdletBinding()]
    param()

    if (-not ('Tlc.ShellLink' -as [type])) {
        Add-Type -TypeDefinition $script:ShellLinkSource -Language CSharp -ErrorAction Stop
    }
}

function Get-TlcShortcutAppId {
    <#
    .SYNOPSIS
        The AppUserModelID a shortcut carries, or an empty string when it carries none.
    .DESCRIPTION
        WScript.Shell cannot read this property, which is the property the whole entry exists
        to carry, so it is read back through the same property store that wrote it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    Initialize-TlcShellLink
    return [string][Tlc.ShellLink]::ReadAppUserModelId($Path)
}

function Install-TlcShortcut {
    <#
    .SYNOPSIS
        Adds TLC Toolbox to the Start menu, opening the copy at -ToolboxRoot, or points the
        existing entry at that copy.
    .DESCRIPTION
        A file of the same name that is not a toolbox entry is left alone and reported: it is
        somebody else's, and the name is not this toolbox's to take.

        Returns the state read back from disk afterwards, not the state intended, so a write
        that did not land cannot be reported as one that did.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )

    $command = Get-TlcShortcutCommand -ToolboxRoot $ToolboxRoot
    if (-not (Test-Path -LiteralPath (Join-Path $command.WorkingDirectory 'Start-TlcToolbox.ps1') -PathType Leaf)) {
        throw "There is no toolbox at $($command.WorkingDirectory) for a Start menu entry to open."
    }

    $before = Get-TlcShortcutState -ToolboxRoot $ToolboxRoot
    if ($before.State -eq 'Foreign') {
        throw "A different shortcut called TLC Toolbox is already in the Start menu, at $($before.Path). It has been left as it is."
    }

    $folder = Split-Path -Parent $before.Path
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop
    }

    Initialize-TlcShellLink
    [Tlc.ShellLink]::Save($before.Path, $command.TargetPath, $command.Arguments, $command.WorkingDirectory,
        $command.IconPath, $command.IconIndex, $command.Description, $command.ShowCommand, $command.AppUserModelId)

    return Get-TlcShortcutState -ToolboxRoot $ToolboxRoot
}

function Set-TlcWindowLauncherIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Window,
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )
    $launcher = Join-Path $ToolboxRoot 'TLC-Toolbox.exe'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { return }
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
    if ($handle -eq [IntPtr]::Zero) { throw 'The taskbar launcher identity needs an initialized window handle.' }
    Initialize-TlcShellLink
    [Tlc.ShellLink]::SetWindowLauncher($handle, $launcher, (Get-TlcAppUserModelId))
}

function Install-TlcApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [string] $InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\TLC-Toolbox')
    )

    $source = ConvertTo-TlcShortcutRoot -Path $ToolboxRoot
    $destination = ConvertTo-TlcShortcutRoot -Path $InstallRoot
    if ($destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The installation folder cannot be inside the source payload.'
    }
    $manifestPath = Join-Path $source 'Tlc.psd1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($manifestPath, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw 'The source toolbox manifest could not be parsed.' }
    $manifest = $ast.Find({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $false).SafeGetValue()
    if ([string]$manifest.GUID -ne 'c4e9a17b-5d2f-4a86-9f31-7b0c8e5d24af') { throw 'The source is not the TLC Toolbox application.' }
    $files = @($manifest.FileList)
    foreach ($required in 'TLC-Toolbox.exe', 'Start-TlcToolbox.ps1', 'Tlc.psd1') {
        if ($files -notcontains $required) { throw "The payload does not declare $required." }
    }
    foreach ($relative in $files) {
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|[\\/])\.{1,2}([\\/]|$)|:|\.local\.psd1$') { throw "Unsafe installation payload path: $relative" }
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "The source payload is incomplete: $relative" }
    }
    $shortcutBefore = Get-TlcShortcutState -ToolboxRoot $destination
    if ($shortcutBefore.State -eq 'Foreign') {
        throw 'A different application owns the TLC Toolbox Start menu name; it has not been overwritten.'
    }
    if ([string]::Equals($source, $destination, [StringComparison]::OrdinalIgnoreCase)) {
        $shortcut = Install-TlcShortcut -ToolboxRoot $destination
        return [pscustomobject]@{ InstallRoot = $destination; Version = $manifest.ModuleVersion; Shortcut = $shortcut.Path; BackupPath = '' }
    }
    if (Test-Path -LiteralPath $destination) {
        $installedManifest = Join-Path $destination 'Tlc.psd1'
        if (-not (Test-Path -LiteralPath $installedManifest -PathType Leaf)) { throw 'The installation folder contains something other than TLC Toolbox.' }
        $installedAst = [Management.Automation.Language.Parser]::ParseFile($installedManifest, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw 'The existing installation manifest is unreadable.' }
        $existing = $installedAst.Find({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $false).SafeGetValue()
        if ([string]$existing.GUID -ne [string]$manifest.GUID) { throw 'The installation folder belongs to a different application.' }
        if ([version]$existing.ModuleVersion -gt [version]$manifest.ModuleVersion) { throw 'A newer TLC Toolbox is already installed; it has not been downgraded.' }
        $active = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='TLC-Toolbox.exe'" `
            -Property ProcessId, CommandLine, ExecutablePath -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and (
                ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) -or
                ($_.CommandLine -and $_.CommandLine.IndexOf($destination + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0)
            ) })
        if ($active.Count) { throw 'Close the installed toolbox after its current run finishes, then install the update. No running process was stopped.' }
    }
    $parent = Split-Path -Parent $destination
    $staging = Join-Path $parent ('TLC-Toolbox.installing-' + [guid]::NewGuid().ToString('N'))
    $backup = ''
    $replaced = $false
    $shortcutBytes = if (Test-Path -LiteralPath $shortcutBefore.Path -PathType Leaf) { [IO.File]::ReadAllBytes($shortcutBefore.Path) } else { $null }
    $null = New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop
    try {
        foreach ($relative in $files) {
            $target = Join-Path $staging $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force -ErrorAction Stop
            Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $target -ErrorAction Stop
            if ((Get-TlcFileHash -Path $target) -ne (Get-TlcFileHash -Path (Join-Path $source $relative))) {
                throw "The installed payload failed verification: $relative"
            }
        }
        if (Test-Path -LiteralPath $destination) {
            $backup = Join-Path $parent ('TLC-Toolbox.previous-' + [guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
        }
        Move-Item -LiteralPath $staging -Destination $destination -ErrorAction Stop
        $replaced = $true
        $shortcut = Install-TlcShortcut -ToolboxRoot $destination
        return [pscustomobject]@{ InstallRoot = $destination; Version = $manifest.ModuleVersion; Shortcut = $shortcut.Path; BackupPath = $backup }
    } catch {
        if ($replaced) { Move-Item -LiteralPath $destination -Destination $staging -ErrorAction Stop }
        if ($backup -and (Test-Path -LiteralPath $backup)) { Move-Item -LiteralPath $backup -Destination $destination -ErrorAction Stop }
        if ($null -ne $shortcutBytes) {
            [IO.File]::WriteAllBytes($shortcutBefore.Path, $shortcutBytes)
        } elseif ((Get-TlcShortcutState -ToolboxRoot $destination).State -in @('Here', 'Elsewhere')) {
            Remove-Item -LiteralPath $shortcutBefore.Path -Force -ErrorAction Stop
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop }
    }
}

function Uninstall-TlcShortcut {
    <#
    .SYNOPSIS
        Removes the Start menu entry, whichever copy of the toolbox it opens.
    .DESCRIPTION
        There is one entry, and removing it is what the button says. A file of the same name
        that is not a toolbox entry is not touched. A pin made from the entry belongs to the
        operator and stays where they put it.

        Returns the state read back from disk afterwards.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )

    $before = Get-TlcShortcutState -ToolboxRoot $ToolboxRoot
    if ($before.State -eq 'Here' -or $before.State -eq 'Elsewhere') {
        Remove-Item -LiteralPath $before.Path -Force -ErrorAction Stop
    }
    return Get-TlcShortcutState -ToolboxRoot $ToolboxRoot
}

function Update-TlcShortcutSetting {
    <#
    .SYNOPSIS
        Draws the Settings window's Start menu row from what is on disk. With -Toggle, first
        adds or removes the entry.
    .DESCRIPTION
        One function for both because they are one decision. The button offers whichever
        action applies to the entry as it is now, and after acting the row is drawn again from
        disk rather than from what was meant to happen, so a write that failed is never shown
        as done. The failure itself replaces the hint, in the window's language around the
        system's own message.

        Elsewhere offers Add, not Remove: the operator is in this copy, and adding the entry
        again points it here instead of leaving it on an older one.

        Returns the state now shown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $ButtonText,
        [Parameter(Mandatory)] $Hint,
        [Parameter(Mandatory)] [hashtable] $Strings,
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [switch] $Toggle
    )

    $failure = ''
    try {
        if ($Toggle) {
            $waiting = $false
            try {
                # The first write compiles the shortcut writer: up to two seconds on 5.1.
                [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
                $waiting = $true
            } catch {
                Write-Verbose "No wait cursor: $($_.Exception.Message)"
            }
            try {
                $before = Get-TlcShortcutState -ToolboxRoot $ToolboxRoot
                if ($before.State -eq 'Here') {
                    $null = Uninstall-TlcShortcut -ToolboxRoot $ToolboxRoot
                } else {
                    $null = Install-TlcShortcut -ToolboxRoot $ToolboxRoot
                }
            } finally {
                if ($waiting) { [System.Windows.Input.Mouse]::OverrideCursor = $null }
            }
        }
    } catch {
        $failure = $_.Exception.Message
    }

    $state = 'None'
    $opens = ''
    try {
        $now = Get-TlcShortcutState -ToolboxRoot $ToolboxRoot
        $state = $now.State
        $opens = $now.Opens
    } catch {
        if (-not $failure) { $failure = $_.Exception.Message }
    }

    $ButtonText.Text = if ($state -eq 'Here') {
        Get-TlcString -Table $Strings -Key 'ShortcutRemoveButton'
    } else {
        Get-TlcString -Table $Strings -Key 'ShortcutAddButton'
    }

    $Hint.Text = if ($failure) {
        Get-TlcString -Table $Strings -Key 'ShortcutFailed' -Argument @($failure)
    } elseif ($state -eq 'Here') {
        Get-TlcString -Table $Strings -Key 'ShortcutHintHere'
    } elseif ($state -eq 'Elsewhere') {
        Get-TlcString -Table $Strings -Key 'ShortcutHintElsewhere' -Argument @($opens)
    } else {
        Get-TlcString -Table $Strings -Key 'ShortcutHintNone'
    }

    return $state
}

Export-ModuleMember -Function Get-TlcAppUserModelId, Get-TlcShortcutPath, Get-TlcShortcutCommand, Get-TlcShortcutState,
    Install-TlcApplication, Set-TlcWindowLauncherIdentity,
    Get-TlcShortcutAppId, Install-TlcShortcut, Uninstall-TlcShortcut, Update-TlcShortcutSetting
