Set-StrictMode -Version Latest

<#
    Web and VDI collectors.

    Both are small on purpose. The Web scenario is almost entirely Prompted - a HAR
    and a WebRTC dump are browser actions - so the Auto lane's job is to record
    which browser and version produced them, which is the context most often
    missing when a trace arrives.

    The VDI scenario adds the environment facts that decide whether media was
    optimised or fell back, which is usually the actual question.
#>

function Get-TlcBrowserInventory {
    <#
    .SYNOPSIS
        Records installed browsers and the default handler.
    #>
    [CmdletBinding()]
    param()

    $browsers = @(
        @{ Name = 'Microsoft Edge'; Keys = @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}',
            'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}') }
        @{ Name = 'Google Chrome'; Keys = @(
            'HKLM:\SOFTWARE\WOW6432Node\Google\Update\Clients\{8A69D345-D564-463c-AFF1-A69D9E530F96}',
            'HKLM:\SOFTWARE\Google\Update\Clients\{8A69D345-D564-463c-AFF1-A69D9E530F96}') }
        @{ Name = 'WebView2 Runtime'; Keys = @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
            'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') }
    )

    $installed = foreach ($browser in $browsers) {
        $version = $null
        foreach ($key in $browser.Keys) {
            $value = Get-ItemProperty -Path $key -Name pv -ErrorAction SilentlyContinue
            if ($value) { $version = $value.pv; break }
        }
        [ordered]@{
            Name      = $browser.Name
            Installed = [bool]$version
            Version   = $version
        }
    }

    $defaultBrowser = $null
    $assoc = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue
    if ($assoc -and $assoc.PSObject.Properties.Name -contains 'ProgId') { $defaultBrowser = $assoc.ProgId }

    return [ordered]@{
        Browsers       = @($installed)
        DefaultHttpsHandler = $defaultBrowser
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-TlcWebCollection {
    <#
    .SYNOPSIS
        Auto lane for the web scenario, plus the browser-side prompts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [switch] $SkipPrompted,
        # The capture stage asks for the browser capture before sampling starts, so its
        # closing pass must not ask a second time. The folder is still returned.
        [switch] $NoCapturePrompt,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $inventory = Get-TlcBrowserInventory
    $path = Export-TlcEvidence -Name 'BrowserInventory.json' -InputObject $inventory -Endpoint $Endpoint

    $installed = @($inventory.Browsers | Where-Object { $_.Installed })
    Write-TlcBlocker -Check 'Web.BrowserInventory' -Status 'Success' -Endpoint $Endpoint `
        -Detail "$($installed.Count) browser component(s): $(($installed | ForEach-Object { "$($_.Name) $($_.Version)" }) -join '; ')" | Out-Null
    Write-TlcEvent -Phase 'Collect' -Step 'Web.BrowserInventory' -Status 'Complete' -Endpoint $Endpoint -EvidencePath $path

    $dropFolder = if ($NoCapturePrompt) {
        $folder = Join-Path $EndpointPath 'WebCapture'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $folder
    } else {
        Request-TlcBrowserCapture -EndpointPath $EndpointPath -SkipPrompted:$SkipPrompted -IncludeWebRtc -Endpoint $Endpoint
    }

    return [ordered]@{
        Endpoint       = $Endpoint
        BrowserInventory = $inventory
        CaptureFolder  = $dropFolder
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Request-TlcBrowserCapture {
    <#
    .SYNOPSIS
        The browser-side Prompted lane: asks for a HAR and console export and gives them a
        folder to land in.
    .DESCRIPTION
        Shared by the web scenario and by Files, whose catalog entry also promises a HAR -
        uploads, downloads and file previews are SharePoint and OneDrive requests, and the
        HAR is what shows which one failed and with what status. Files was never asked for
        one: the desktop pipeline ran only the support-file prompt, so a lane the catalog
        and the scenario matrix both listed was offered to nobody. Found on the live call
        test, finding 302.

        -IncludeWebRtc adds the webrtc-internals step, which only means something for media.
        Returns the drop folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [switch] $SkipPrompted,
        [switch] $IncludeWebRtc,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $dropFolder = Join-Path $EndpointPath 'WebCapture'
    $null = New-Item -ItemType Directory -Path $dropFolder -Force
    $what = if ($IncludeWebRtc) { 'HAR, console and WebRTC' } else { 'HAR and console' }

    if ($SkipPrompted) {
        Write-TlcBlocker -Check 'Web.Capture' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$what capture skipped (-SkipPrompted)." `
            -Remediation 'Re-run interactively with the affected user.' | Out-Null
        return $dropFolder
    }

    Write-Information '' -InformationAction Continue
    Write-Information '  ACTION REQUIRED - browser capture' -InformationAction Continue
    # Worded after running the prompt as an operator would, finding 307. The first version
    # said "Open DevTools (F12)" for the Files scenario too, which runs in the desktop app where
    # F12 opens nothing; put the webrtc-internals step after "reproduce", when the page has to be
    # open before the call starts; and said "Export the HAR" without saying which, when the
    # export with sensitive data carries sign-in tokens the privacy gate then refuses.
    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add('Use Teams on the web (teams.microsoft.com) in Edge or Chrome for this capture - that is where F12 opens DevTools.')
    $steps.Add('Sign in FIRST, so the trace does not capture sign-in credentials.')
    if ($IncludeWebRtc) {
        $steps.Add('For media issues, BEFORE the call starts open edge://webrtc-internals/ (or chrome://) in another tab and leave it open.')
    }
    # Edge labels the checkbox "Keep log"; Chrome says "Preserve log". Found by driving the prompt
    # in a real Edge 155, where the name the prompt used did not exist. Finding 312.
    $steps.Add('Press F12, open the Network tab (recording is on by default) and tick "Keep log" (Chrome calls it "Preserve log").')
    $steps.Add('Reproduce the issue once.')
    # Sanitized strips the Cookie and Authorization headers only. A real sanitized Teams HAR still
    # held access, ID and refresh tokens in response bodies; Package now removes those before the
    # privacy gate, and says so. Finding 312.
    $steps.Add('Network tab: Export HAR (sanitized), the default button. It removes cookies and auth headers; the toolbox removes the sign-in tokens left in response bodies when it packages. Delete your own copy afterwards.')
    $steps.Add('Console tab: right-click any message, "Save as...".')
    if ($IncludeWebRtc) {
        $steps.Add('webrtc-internals: "Create a WebRTC-Internals dump" at the top of the page, then download it.')
    }
    $steps.Add("Save everything into: $dropFolder")
    for ($i = 0; $i -lt $steps.Count; $i++) {
        Write-Information "  $($i + 1). $($steps[$i])" -InformationAction Continue
    }
    Write-Information '' -InformationAction Continue
    Write-TlcBlocker -Check 'Web.Capture' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
        -Detail "Awaiting operator-supplied $what files in $dropFolder." `
        -Remediation 'Place the exported files in the WebCapture folder, then re-run -Stage Validate with the same -CorrelationId, -Scenario and -CaseNumber; it lists what it finds there.' | Out-Null
    return $dropFolder
}

function Get-TlcWebLogNetworkState {
    <#
    .SYNOPSIS
        Teams' own record of going offline and back online, read from a harvested web-logs zip.
    .DESCRIPTION
        Found by blocking Teams' programs for 60 s mid-capture, finding 307. The native client log
        recorded nothing, and every toolbox probe passed because it runs in powershell.exe. The
        web logs had the answer to the second: Core/diagnostics-logs.txt carries
        "NetworkStateProvider: Set network state to Offline. Signal: Trouter" 17 s after the block
        and "... to Online" 10 s after it lifted. This reads those lines and nothing else.

        Only entries are read, never extracted, and only the Core log: the per-user logs carry
        the same transitions for each signed-in account and would count every outage twice.
        Times are the log's own UTC stamps.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ZipPath,
        [Parameter(Mandatory)] [datetime] $WindowStartUtc,
        [Parameter(Mandatory)] [datetime] $WindowEndUtc
    )

    $result = [ordered]@{ Read = $false; Transitions = @(); Offline = @(); Detail = '' }
    $pattern = [regex]'^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s+\w+\s+NetworkStateProvider: Set network state to (Offline|Online)\. Signal: (\w+)'

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entry = @($archive.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq 'Core/diagnostics-logs.txt' }) | Select-Object -First 1
        if (-not $entry) { $result.Detail = 'The web logs carry no Core/diagnostics-logs.txt.'; return $result }
        $reader = [System.IO.StreamReader]::new($entry.Open())
        $transitions = [System.Collections.Generic.List[object]]::new()
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                $m = $pattern.Match($line)
                if (-not $m.Success) { continue }
                $transitions.Add([pscustomobject]@{
                    TimeUtc = [datetime]::Parse($m.Groups[1].Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
                    State   = $m.Groups[2].Value
                    Signal  = $m.Groups[3].Value
                })
            }
        } finally { $reader.Dispose() }
        $result.Read = $true

        # The log is newest-first in places; order by time before pairing.
        $ordered = @($transitions | Sort-Object TimeUtc)
        $result.Transitions = @($ordered | Where-Object { $_.TimeUtc -ge $WindowStartUtc.AddMinutes(-30) -and $_.TimeUtc -le $WindowEndUtc.AddMinutes(5) } |
            ForEach-Object { [ordered]@{ TimeUtc = $_.TimeUtc.ToString('o'); State = $_.State; Signal = $_.Signal } })

        # Pair each Offline with the next Online. An offline stretch still open when the log ends
        # runs to the end of the window.
        $spans = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            if ($ordered[$i].State -ne 'Offline') { continue }
            if ($i -gt 0 -and $ordered[$i - 1].State -eq 'Offline') { continue }
            $next = @($ordered | Select-Object -Skip ($i + 1) | Where-Object { $_.State -eq 'Online' } | Select-Object -First 1)
            $end = if ($next.Count -gt 0) { $next[0].TimeUtc } else { $null }
            $spanEnd = if ($end) { $end } else { $WindowEndUtc }
            if ($ordered[$i].TimeUtc -le $WindowEndUtc -and $spanEnd -ge $WindowStartUtc) {
                $spans.Add([ordered]@{
                    FromUtc = $ordered[$i].TimeUtc.ToString('o')
                    ToUtc   = if ($end) { $end.ToString('o') } else { $null }
                    Seconds = if ($end) { [math]::Round(($end - $ordered[$i].TimeUtc).TotalSeconds) } else { $null }
                    Signal  = $ordered[$i].Signal
                })
            }
        }
        $result.Offline = @($spans)
    } catch {
        $result.Detail = "The web logs could not be read: $($_.Exception.Message)"
    } finally {
        if ($archive) { $archive.Dispose() }
    }
    return $result
}

function Invoke-TlcWebLogTrigger {
    <#
    .SYNOPSIS
        Triggers Teams' own web log collection (Ctrl + Alt + Shift + 1) without a human at the
        keyboard, and waits for the bundle to land.
    .DESCRIPTION
        This was previously documented as impossible - "Ctrl + Alt + Shift + 1 has no API, so
        the only honest automation is to ask". The first half is still true; the second was
        wrong, and it was wrong because of two measurement errors rather than a real barrier.

        WHAT ACTUALLY BLOCKED IT. A naive SetForegroundWindow from a background process is
        refused by Windows, which produced the conclusion that the keystroke could not be
        delivered. Attaching this thread's input queue to the current foreground thread first
        lifts that restriction - the documented technique - after which SendInput reaches Teams
        exactly like a real keyboard. Proved by a control that had nothing to do with
        diagnostics: sending Ctrl+2 and Ctrl+3 navigated the client and changed its window
        title. The input path was verified before the payload was trusted.

        THE OTHER TWO ERRORS, both in the observation rather than the action:

        - The artifact is not called what the earlier search looked for. It lands as
          PROD-WebLogs-<ISO8601>.zip, roughly 5.5 MB, which is why the toolbox's own
          Collection.WebLogPatterns already matches 'Prod-Weblogs*'. A search for
          "MSTeams Diagnostics Log*" finds nothing and reads as "the trigger did not fire".
        - It is not instant. Measured twice on build 26225: 57 seconds from keystroke to file.
          An earlier attempt waited 45 and concluded failure roughly ten seconds early.

        SAFETY. Synthetic input goes wherever the focus actually is, so this refuses to send
        anything unless the foreground window is verifiably Teams after the activation attempt.
        Sending a modifier combination into whatever the user happens to have open instead is a
        far worse outcome than not collecting a log.

        WHAT IS IN IT, AND WHY THE PRIVACY GATE MATTERS. The bundle carries a folder per
        signed-in account, not just the one being investigated - measured, two accounts on this
        machine, one of them unrelated to the case. That is the concrete form of the premise
        Privacy.BlockOnUnknownAccount exists for, and it is the reason this returns a fact for
        the gate to judge rather than quietly adding the bundle to the evidence.

        It also carries web-media-logs.txt, web-media-telemetry.txt and
        web-media-diagnostics-info.json - the media statistics that are absent from the rolling
        client logs entirely. They are zero bytes when no media has flowed, which matches the
        SlimCore measurement in finding 144 rather than contradicting it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [int] $TimeoutSeconds = 300,
        [switch] $TriggerOnly,
        [string] $DownloadPath,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $result = [ordered]@{
        Triggered      = $false
        Reason         = ''
        BundlePath     = ''
        BundleBytes    = 0
        WaitSeconds    = 0
        Accounts       = @()
        KnownBefore    = @()
        SupportLogPath = ''
        SupportLogBytes = 0
        Detail         = ''
    }

    # FIRST, and before anything that is not a cmdlet. A locked-down endpoint runs PowerShell
    # in ConstrainedLanguage, where Add-Type is refused outright ("Definition of new types is
    # not supported in this language mode") and any static call on a non-core type throws.
    # Measured: without this guard the whole function threw, even under -WhatIf, so the lane
    # meant to help a customer would instead have failed their run. Every check below is a
    # cmdlet or a core-type operation so that this path itself survives the same mode.
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        $result.Reason = 'LanguageModeBlocked'
        $result.Detail = "PowerShell is in $($ExecutionContext.SessionState.LanguageMode), which forbids the P/Invoke type this needs. Use the prompted lane and ask the user to press Ctrl + Alt + Shift + 1."
        return (New-Object psobject -Property $result)
    }
    if ($Endpoint -ne $env:COMPUTERNAME) {
        $result.Reason = 'DifferentEndpoint'
        $result.Detail = 'Automatic support generation only targets Teams on this computer. No shortcut was sent to a different endpoint.'
        return (New-Object psobject -Property $result)
    }

    # The real Downloads folder, which is not always under the profile. Known Folder id for
    # Downloads; the toolbox documents the same lookup for the prompted lane.
    if (-not $DownloadPath) {
        $shell = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
        $raw = if ($shell) { $shell.'{374DE290-123F-4565-9164-39C4925E467B}' } else { $null }
        $DownloadPath = if ($raw) { [Environment]::ExpandEnvironmentVariables([string]$raw) } else { Join-Path $env:USERPROFILE 'Downloads' }
    }
    if (-not (Test-Path -LiteralPath $DownloadPath)) {
        $result.Reason = 'NoDownloadFolder'
        $result.Detail = "The download folder $DownloadPath does not exist, so a bundle could not be detected even if one were produced."
        return (New-Object psobject -Property $result)
    }

    $teams = @(Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle }) | Select-Object -First 1
    if (-not $teams) {
        $result.Reason = 'NoInteractiveTeams'
        $result.Detail = 'Teams is not running with a window, so there is nothing to send the shortcut to.'
        return (New-Object psobject -Property $result)
    }

    # Session 0 has no desktop to inject into. A run started from a remote session or a service
    # lands here, and would otherwise generate input nobody can receive.
    if ((Get-Process -Id $PID).SessionId -ne $teams.SessionId) {
        $result.Reason = 'DifferentSession'
        $result.Detail = "This process is in session $((Get-Process -Id $PID).SessionId) and Teams is in session $($teams.SessionId). Synthetic input cannot cross that boundary."
        return (New-Object psobject -Property $result)
    }

    if (-not $PSCmdlet.ShouldProcess($teams.MainWindowTitle, 'Send Ctrl+Alt+Shift+1 to Teams')) {
        $result.Reason = 'WhatIf'
        $result.Detail = 'Skipped by -WhatIf.'
        return (New-Object psobject -Property $result)
    }

    try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class TlcInput {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit, Size=40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] p, int size);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);

    public static bool Focus(IntPtr target) {
        IntPtr fg = GetForegroundWindow();
        if (fg == target) return true;
        uint pid; uint fgThread = GetWindowThreadProcessId(fg, out pid);
        uint ourThread = GetCurrentThreadId();
        bool attached = false;
        try {
            if (fgThread != ourThread) attached = AttachThreadInput(fgThread, ourThread, true);
            ShowWindow(target, 9); BringWindowToTop(target); SetForegroundWindow(target);
        } finally { if (attached) AttachThreadInput(fgThread, ourThread, false); }
        System.Threading.Thread.Sleep(400);
        return GetForegroundWindow() == target;
    }
    static INPUT K(ushort vk, bool up) {
        INPUT i = new INPUT(); i.type = 1; i.ki.wVk = vk;
        i.ki.wScan = (ushort)MapVirtualKey(vk, 0); i.ki.dwFlags = up ? (uint)2 : 0; return i;
    }
    public static int LastSendError = 0;
    public static bool FocusLost = false;
    public static bool ModifiersBusy = false;
    static uint Send(INPUT[] keys) {
        uint accepted = SendInput((uint)keys.Length, keys, Marshal.SizeOf(typeof(INPUT)));
        int error = Marshal.GetLastWin32Error();
        if (accepted != keys.Length && LastSendError == 0) LastSendError = error;
        return accepted;
    }
    public static uint DiagnosticsCombo(IntPtr target) {
        LastSendError = 0; FocusLost = false; ModifiersBusy = false;
        foreach (int key in new int[] { 0x11, 0x12, 0x10 }) {
            if ((GetAsyncKeyState(key) & 0x8000) != 0) { ModifiersBusy = true; return 0; }
        }
        if (GetForegroundWindow() != target) { FocusLost = true; return 0; }
        uint accepted = 0;
        try {
            uint modifiers = Send(new INPUT[] { K(0x11,false), K(0x12,false), K(0x10,false) });
            accepted += modifiers;
            if (modifiers != 3) return accepted;
            // Keep modifiers down while the client processes the diagnostic key event.
            System.Threading.Thread.Sleep(80);
            if (GetForegroundWindow() != target) { FocusLost = true; return accepted; }
            accepted += Send(new INPUT[] { K(0x31,false) });
            System.Threading.Thread.Sleep(80);
            accepted += Send(new INPUT[] { K(0x31,true) });
        } finally {
            accepted += Send(new INPUT[] { K(0x10,true), K(0x12,true), K(0x11,true) });
        }
        return accepted;
    }
}
'@ -ErrorAction Stop
    } catch {
        # Compilation itself can be refused - by language mode (already handled above), by an
        # AppLocker or WDAC rule covering the C# compiler, or by a security product that
        # dislikes a P/Invoke shim being built at runtime. Reported as a fact so the caller
        # falls back to asking, rather than as an exception that fails the run.
        $result.Reason = 'TypeLoadBlocked'
        $result.Detail = "The P/Invoke helper could not be compiled on this machine: $($_.Exception.Message). Use the prompted lane instead."
        return (New-Object psobject -Property $result)
    }

    $before = @(Get-ChildItem -LiteralPath $DownloadPath -Filter '*WebLogs*' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })

    # The keystroke produces TWO artifacts, not one, and this function watched for only the
    # smaller of them for its whole life. Microsoft documents both: "MS Teams Support Log
    # Files, which contain media and signaling logs in addition to platform logs" and
    # "Weblogs, which contain application event logs".
    #
    # The weblogs arrive as PROD-WebLogs-<ISO>.zip at about 5.5 MB. The support logs arrive as
    # a FOLDER named "MSTeams Support Logs <timestamp>" at about 585 MB - measured, five
    # triggers in one afternoon put 2.74 GB into a user's Downloads while this function
    # reported "5.5 MB" each time. Finding 51 had already recorded that this keystroke
    # produces a folder rather than a file and that a size budget ignored it; that lesson was
    # available and was repeated anyway.
    #
    # Reported, not collected. The media and signaling logs inside are encrypted - measured at
    # 17-38% printable - so there is nothing to parse, and 585 MB has no business entering a
    # bundle by accident. The caller is told what was produced so it can be cleaned up or
    # deliberately included.
    $supportBefore = @(Get-ChildItem -LiteralPath $DownloadPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'MSTeams Support Logs*' } | ForEach-Object { $_.Name })

    if (-not [TlcInput]::Focus($teams.MainWindowHandle)) {
        # Deliberately no keystroke. It would land in whatever is actually focused.
        $result.Reason = 'ForegroundRefused'
        $result.Detail = 'Teams could not be brought to the foreground, so the shortcut was NOT sent - it would have gone to whatever window has focus instead. A locked session, a UAC prompt on the secure desktop, or a higher-integrity window in front will all do this.'
        return (New-Object psobject -Property $result)
    }

    Start-Sleep -Milliseconds 100
    if ([TlcInput]::GetForegroundWindow() -ne $teams.MainWindowHandle) {
        $result.Reason = 'ForegroundRefused'
        $result.Detail = 'Teams lost foreground focus before the shortcut; no input was sent.'
        return (New-Object psobject -Property $result)
    }
    $sent = [TlcInput]::DiagnosticsCombo($teams.MainWindowHandle)
    $sendError = [TlcInput]::LastSendError
    if ([TlcInput]::FocusLost -or [TlcInput]::ModifiersBusy) {
        $result.Reason = if ([TlcInput]::FocusLost) { 'ForegroundRefused' } else { 'ModifiersBusy' }
        $result.Detail = 'The diagnostic shortcut was not sent: Teams lost focus or modifier keys were already held. Release the keys and retry, or use the manual shortcut.'
        return (New-Object psobject -Property $result)
    }
    if ($sent -lt 8) {
        $result.Reason = 'InputRejected'
        $hint = if ($sendError -eq 5) {
            'Win32 error 5 (access denied) means something refused the injection outright - UIPI against a higher-integrity window, or an endpoint security product filtering synthetic input.'
        } else {
            "Win32 error $sendError."
        }
        $result.Detail = "Only $sent of 8 key events were accepted. $hint"
        return (New-Object psobject -Property $result)
    }

    if ($TriggerOnly) {
        $result.Triggered = $true
        $result.Reason = 'ShortcutSent'
        $result.Detail = 'Shortcut sent to Teams. Waiting for the support files to finish writing.'
        return (New-Object psobject -Property $result)
    }

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $new = @(Get-ChildItem -LiteralPath $DownloadPath -Filter '*WebLogs*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $before })
        if ($new.Count -gt 0) {
            $bundle = $new | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $result.Triggered = $true
            $result.Reason = 'Collected'
            $result.BundlePath = $bundle.FullName
            $result.BundleBytes = $bundle.Length
            $result.WaitSeconds = [int]((Get-Date) - $started).TotalSeconds
            $result.Accounts = @(Get-TlcWebLogAccount -Path $bundle.FullName)

            # The support-log folder is slower than the zip, so it is looked for here rather
            # than raced for. Absent is a legitimate answer - the browser client produces no
            # support logs at all.
            $supportFolder = @(Get-ChildItem -LiteralPath $DownloadPath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'MSTeams Support Logs*' -and $_.Name -notin $supportBefore } |
                Sort-Object LastWriteTime -Descending) | Select-Object -First 1
            if ($supportFolder) {
                $result.SupportLogPath = $supportFolder.FullName
                $result.SupportLogBytes = (Get-ChildItem -LiteralPath $supportFolder.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum
            }

            $result.Detail = "Collected $($bundle.Name) after $($result.WaitSeconds)s; $(@($result.Accounts).Count) account folder(s) inside." +
                $(if ($result.SupportLogPath) {
                    " The same keystroke also wrote $([math]::Round($result.SupportLogBytes/1MB)) MB of encrypted media and signaling logs to $(Split-Path $result.SupportLogPath -Leaf); that folder is NOT collected and is left for the operator to send or delete."
                } else { '' })
            return (New-Object psobject -Property $result)
        }
    }

    $result.WaitSeconds = $TimeoutSeconds
    $result.Reason = 'NoBundle'
    # The file list from before the keystroke travels back with the failure, and that is the
    # point of this branch. A bundle that lands after the timeout is still THIS run's, but the
    # harvester deliberately ignores anything it did not watch appear - so that it never
    # attaches a stale bundle from a previous incident to the current case. Without the list,
    # a late bundle is indistinguishable from a stale one and either gets dropped or gets
    # attached to the wrong case later.
    #
    # 300s rather than 180s because 180 was not enough. Measured: 57, 59 and 59 seconds idle,
    # and 158 seconds during a live call on the machine this was written on. Twenty-two
    # seconds of margin on a developer's own laptop is not margin.
    $result.KnownBefore = @($before)
    $result.Detail = "The shortcut was delivered but no bundle appeared in $DownloadPath within $TimeoutSeconds seconds. Measured latency is about 57s idle and 158s during a call, so a slower or busier machine is the first thing to check. KnownBefore lists what was already there, so a bundle that lands later can still be told apart from a stale one."
    return (New-Object psobject -Property $result)
}

function Get-TlcWebLogAccount {
    <#
    .SYNOPSIS
        The signed-in accounts a Teams web log bundle carries diagnostics for.
    .DESCRIPTION
        Read without extracting the archive. The bundle lays out one folder per account -
        "User (Primary; <object id>)" and "User (<object id>)" - which is the multi-account
        exposure Privacy.BlockOnUnknownAccount exists to catch, in the one artifact where it is
        stated explicitly rather than inferred.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $ids = foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '^User \((?:Primary;\s*)?([0-9a-fA-F-]{36})\)') { $Matches[1] }
        }
        return @($ids | Sort-Object -Unique)
    } catch {
        Write-Verbose "Could not read $Path : $($_.Exception.Message)"
        return @()
    } finally {
        if ($archive) { $archive.Dispose() }
    }
}

function Get-TlcVdiEnvironment {
    <#
    .SYNOPSIS
        Identifies the VDI platform and Teams media optimisation state.
    .DESCRIPTION
        Whether media was optimised or fell back to the endpoint is usually the
        whole question in a VDI call-quality case. SlimCore presence is the
        strongest local signal, so it is reported as a fact rather than inferred
        from the platform.
    #>
    [CmdletBinding()]
    param()

    # Reuses the cached package list when the full module is loaded. Enumerating every
    # installed package costs over a second, and the desktop collector has almost
    # always already paid for it by the time a VDI check runs. The fallback keeps this
    # module importable on its own, which is how the tests load it.
    $slimcore = if (Get-Command -Name 'Get-TlcAppxPackage' -ErrorAction SilentlyContinue) {
        (Get-TlcAppxPackage).SlimCore
    } else {
        Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Microsoft.Teams.SlimCore*' } | Select-Object -First 1
    }

    # The documented signals, the same ones Get-TlcPlatform reads (finding 317). These were
    # HKLM:\SOFTWARE\Citrix and HKLM:\SOFTWARE\VMware, Inc., which exist on any machine with the
    # Citrix Workspace CLIENT or VMware Tools installed - an endpoint, not a virtual desktop.
    $platforms = [ordered]@{
        Citrix = (Test-Path 'HKLM:\SOFTWARE\Citrix\WebSocketService') -or (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Citrix\WebSocketService')
        VMwareHorizon = (Test-Path 'HKLM:\SOFTWARE\VMware, Inc.\VMware VDM') -or (Test-Path 'HKLM:\SOFTWARE\Omnissa\Horizon')
        AzureVirtualDesktop = (Test-Path 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent') -or ($null -ne (Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue))
    }

    $detected = @($platforms.Keys | Where-Object { $platforms[$_] })

    # Whether this is a remote session, read from a LIVE source.
    #
    # This read $env:SESSIONNAME until 2026-09-17, and that variable cannot answer the
    # question. An environment block is a snapshot taken when the process is created and it is
    # never updated afterwards. Measured on this machine minutes after an RDP disconnect:
    #
    #   $env:SESSIONNAME        RDP-Tcp#0     (stale)
    #   $env:CLIENTNAME         LAB-PC        (stale - names a machine no longer attached)
    #   WTS WinStationName      Console       (live, and correct)
    #   SessionId vs Glass      2 vs 2        (live, and correct: not remote)
    #
    # So Get-TlcVdiEnvironment reported IsRemoteSession = True and LooksLikeVdi = True on a
    # console session, while Get-TlcPlatform in Tlc.Ui.Metrics reported Physical from the same
    # process in the same second. Two functions, one question, opposite answers.
    #
    # Note what would NOT have fixed it: refreshing. A freshly spawned child process inherits
    # the same stale block, so re-reading the variable on a timer, behind a button, or in a new
    # process returns the identical wrong answer for ever. The source had to change, not the
    # frequency.
    #
    # The comparison below is Microsoft's documented method, and is the one Get-TlcPlatform
    # already uses, so the two now agree by construction: a session whose id differs from the
    # console ("glass") session is remote.
    # https://learn.microsoft.com/en-us/windows/win32/termserv/detecting-the-terminal-services-environment
    #
    # THREE answers, not two. If either id cannot be read the honest value is $null - "not
    # known" - because $false would assert a console session on no evidence, and LooksLikeVdi
    # is what decides whether the VDI advisory is raised at all.
    $sessionId = $null
    $glassSessionId = $null
    try { $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId } catch { $sessionId = $null }
    try {
        $glassSessionId = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' `
            -Name 'GlassSessionId' -ErrorAction Stop).GlassSessionId
    } catch { $glassSessionId = $null }

    # Session 0 is not a user session at all: it is where remote PowerShell, WinRM and services
    # run. It differs from the console session, so it read as "remote", and a WinRM collection
    # on a physical lab endpoint reported Vdi.Environment Success with no platform. Measured
    # 2026-09-28, finding 317. From session 0 the user's session cannot be seen, so: not known.
    $isRemoteSession = if ($sessionId -eq 0) {
        $null
    } elseif ($null -ne $sessionId -and $null -ne $glassSessionId) {
        ($sessionId -ne $glassSessionId)
    } else {
        $null
    }

    return [ordered]@{
        # Recorded as PROVENANCE, and named so that nothing mistakes them for current state.
        # "This collection ran inside an RDP session opened from LAB-PC" is worth knowing when
        # reading a bundle later; it just is not an answer to "is this session remote now".
        SessionNameAtStart = $env:SESSIONNAME
        ClientNameAtStart  = $env:CLIENTNAME
        SessionId          = $sessionId
        GlassSessionId     = $glassSessionId
        IsRemoteSession    = $isRemoteSession
        PlatformsDetected  = $detected
        # -eq $true deliberately: $null is "not known", and PowerShell would otherwise treat it
        # as false here, turning an unknown into a confident "not VDI".
        LooksLikeVdi       = ($detected.Count -gt 0 -or $isRemoteSession -eq $true)
        SlimCoreInstalled  = [bool]$slimcore
        SlimCoreVersion    = if ($slimcore) { $slimcore.Version } else { $null }
        CollectedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-TlcVdiCollection {
    <#
    .SYNOPSIS
        Auto lane additions for the VDI scenario.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $vdi = Get-TlcVdiEnvironment
    $path = Export-TlcEvidence -Name 'VdiEnvironment.json' -InputObject $vdi -Endpoint $Endpoint

    if (@($vdi.PlatformsDetected).Count -gt 0) {
        Write-TlcBlocker -Check 'Vdi.Environment' -Status 'Success' -Endpoint $Endpoint `
            -Detail "Platform(s): $($vdi.PlatformsDetected -join ', '); SlimCore installed: $($vdi.SlimCoreInstalled)." | Out-Null
    } elseif ($vdi.IsRemoteSession -eq $true) {
        # A remote session with no VDI agent is plain Remote Desktop. It used to be reported as
        # Success with an empty platform list (finding 317).
        Write-TlcBlocker -Check 'Vdi.Environment' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail 'Remote Desktop session, but no Azure Virtual Desktop, Windows 365, Citrix or Horizon agent was found, so Teams media optimisation is not available here: calls are processed on the remote machine.' `
            -Remediation 'If this should be a virtual desktop, confirm its VDI agent is installed. Otherwise judge call quality as that of the remote machine, not of the device in front of the user.' | Out-Null
    } else {
        # The session description says which source it came from, because they can disagree -
        # see the note in Get-TlcVdiEnvironment. Naming the live answer first and the
        # process-start snapshot second means a reader who sees "RDP-Tcp#0" in a bundle from a
        # console machine knows immediately which one to believe.
        $sessionDescription = if ($vdi.Contains('SessionId') -and $vdi.SessionId -eq 0) {
            'non-interactive (session 0: remote PowerShell or a service), which cannot see the user''s session'
        } elseif ($null -eq $vdi.IsRemoteSession) {
            'could not be determined'
        } else {
            'local (console)'
        }

        # A process started without SESSIONNAME (a scheduled task, some launchers) printed
        # "started as ''". Measured 2026-09-28. Finding 316.
        $startedAs = if ($vdi.SessionNameAtStart) { "started as '$($vdi.SessionNameAtStart)'" } else { 'no session name was set at start' }
        Write-TlcBlocker -Check 'Vdi.Environment' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "No VDI platform detected and the session is $sessionDescription ($startedAs). This may not be a VDI endpoint." `
            -Remediation 'Confirm the collection is running inside the affected VDI session.' | Out-Null
    }

    if (-not $vdi.SlimCoreInstalled) {
        Write-TlcBlocker -Check 'Vdi.SlimCore' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail 'SlimCore MSIX not present; media logs are unavailable for legacy WebRTC optimisation.' `
            -Remediation 'For legacy WebRTC optimisation, request media logs from the VDI provider.' | Out-Null
    }

    # Documented VDI behaviour: log size is capped by default, so a bundle collected
    # without Extended Logging may be truncated at exactly the point of interest.
    Write-TlcBlocker -Check 'Vdi.ExtendedLogging' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
        -Detail 'VDI clients limit log size by default. Extended Logging state cannot be read programmatically.' `
        -Remediation 'Turn on Extended Logging in Teams Privacy settings, reproduce, then collect.' | Out-Null

    Write-TlcEvent -Phase 'Collect' -Step 'Vdi.Environment' -Status 'Complete' -Endpoint $Endpoint -EvidencePath $path
    return $vdi
}

Export-ModuleMember -Function Invoke-TlcWebLogTrigger, Get-TlcWebLogAccount, Get-TlcWebLogNetworkState, Get-TlcBrowserInventory, Invoke-TlcWebCollection, Request-TlcBrowserCapture, Get-TlcVdiEnvironment, Invoke-TlcVdiCollection
