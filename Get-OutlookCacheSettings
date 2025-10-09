<#
.SYNOPSIS
Returns Outlook Cached Mode settings from registry and (optionally) live Outlook COM, with human-readable interpretations.

.DESCRIPTION
Get-OutlookCacheSettings enumerates policy/user registry values that control Outlook Cached Exchange Mode, per-profile flags (00036601),
and—if requested—live per-store cache state via Outlook COM. It normalizes paths for readability and optionally adds “ValueMeaning”
for quick interpretation.

.PARAMETER UseOutlookCom
Also query live Outlook (COM) to report IsCachedExchange per store.

.PARAMETER IncludeMeaning
Add a ValueMeaning column with human-readable explanations.

.PARAMETER StoresFlat
Return a flat two-column list (StoreName, Cached) from COM instead of the full table.

.OUTPUTS
Table of objects with: Scope, Path, Key, Value [, ValueMeaning]
—or—flat table (StoreName, Cached) when -StoresFlat is used.

# NOTE / DISCLAIMER
# This script is provided “AS IS” with no warranties and is NOT a Microsoft-supported tool. Use at your own risk.

.NOTES
Author: Cullen Haafke
File: Get-OutlookCacheSettings.ps1

# Version History / Changelog
# | Version | Date       | Author         | Changes |
# |---------|------------|----------------|---------|
# |   0.8   | 2025-10-09 | Cullen Haafke  | Initial public header: synopsis, disclaimer, version history; function as provided. |
# |   0.9   | 2025-10-09 | Cullen Haafke  | Added path normalization in output notes, clarified parameter docs. |
# | 1.0.0   | 2025-10-09 | Cullen Haafke  | Tightened Outlook readiness and COM error handling notes in docs. |
# (Add new rows above this line as the script evolves.)

.LINK
Outlook Cached Mode policy reference (admin docs)

.EXAMPLE
# Show all discovered settings with human-readable meaning:
# Get-OutlookCacheSettings -IncludeMeaning

.EXAMPLE
# Include live per-store cache state (requires Outlook):
# Get-OutlookCacheSettings -UseOutlookCom -IncludeMeaning

.EXAMPLE
# Just the live per-store cached state (flat view):
# Get-OutlookCacheSettings -UseOutlookCom -StoresFlat
#>


function global:Get-OutlookCacheSettings {
    [CmdletBinding()]
    param(
        [switch]$UseOutlookCom,
        [switch]$IncludeMeaning,
        # Optional: outputs only per-store cached state (flat two-column view)
        [switch]$StoresFlat
    )

    #-------------------------
    # Helpers
    #-------------------------
    function Get-RegValue {
        param($Root,$Path,$Name)
        try {
            $keyPath = Join-Path $Root $Path
            (Get-ItemProperty -LiteralPath $keyPath -Name $Name -ErrorAction Stop).$Name
        } catch { $null }
    }

    function Normalize-SoftwarePath {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
        # Extract from the first occurrence of "Software\" (case-insensitive).
        $n = $Path -replace '^(?:.*?\\)?(Software\\.*)$','$1'
        # Normalize leading SOFTWARE\ to Software\
        $n = $n -replace '^SOFTWARE','Software'
        return $n
    }

    function New-Row {
        param(
            [string]$Scope, [string]$Path, [string]$Key,
            [object]$Value, [string]$ValueMeaning = $null
        )
        $p = Normalize-SoftwarePath $Path
        $row = [ordered]@{
            Scope = $Scope
            Path  = $p
            Key   = $Key
            Value = $Value
        }
        if ($IncludeMeaning) {
            if ($Value -ne 'Not Found' -and $ValueMeaning) {
                $row['ValueMeaning'] = $ValueMeaning
            } else {
                $row['ValueMeaning'] = ''
            }
        }
        [pscustomobject]$row
    }

    function Interpret-00036601 {
        param([byte[]]$Bytes)
        if ($Bytes -and $Bytes.Count -ge 1 -and (($Bytes[0] -band 0x80) -ne 0)) {
            'Cached Mode: Enabled (per-profile)'
        } else {
            'Cached Mode: Disabled (per-profile)'
        }
    }
    function Interpret-CacheOthersMail { param($Val)
        if     ($Val -eq $null) { 'Not configured' }
        elseif ($Val -eq 0)     { 'Shared mail folders NOT cached (only non-mail folders)' }
        elseif ($Val -eq 1)     { 'Shared mail folders cached (default when enabled)' }
        else                    { "Unrecognized value: $Val" }
    }
    function Interpret-SyncWindow { param($Months,$Days)
        if ($Days -and $Days -gt 0) {
            if     ($Days -eq 3)  { 'Sync window: 3 days' }
            elseif ($Days -eq 7)  { 'Sync window: 1 week' }
            elseif ($Days -eq 14) { 'Sync window: 2 weeks' }
            else { "Sync window (days): $Days" }
        } elseif ($Months -ne $null) {
            switch ($Months) {
                0  { 'Sync window: All mail' }
                1  { 'Sync window: 1 month' }
                3  { 'Sync window: 3 months' }
                6  { 'Sync window: 6 months' }
                12 { 'Sync window: 12 months' }
                24 { 'Sync window: 24 months' }
                36 { 'Sync window: 3 years' }
                60 { 'Sync window: 5 years' }
                default { "Sync window (months): $Months" }
            }
        } else { 'Not configured' }
    }
    function Interpret-NoOST { param($Val)
        if     ($Val -eq $null) { 'Not configured' }
        elseif ($Val -eq 0)     { 'OST allowed; users can enable Cached Mode' }
        elseif ($Val -eq 1)     { 'OST set up by default; users cannot enable offline store (legacy semantics)' }
        elseif ($Val -eq 2)     { 'Disallow OST creation; Cached/Offline disabled' }
        elseif ($Val -eq 3)     { 'No OST in Online Mode; Cached Mode may still create OST' }
        else                    { "Unrecognized NoOST: $Val" }
    }
    function Bytes-ToHex { param([byte[]]$Bytes)
        if ($null -eq $Bytes) { return $null }
        ($Bytes | ForEach-Object { $_.ToString('X2') }) -join ' '
    }

    # Lightweight readiness wait (avoids touching Stores.Count too early)
    function Wait-OutlookReady {
        param(
            [Parameter(Mandatory=$true)] $Namespace,
            [int]$TimeoutSeconds = 30
        )
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            try {
                $null = $Namespace.CurrentUser
                try { $null = $Namespace.DefaultStore } catch { }
                return $true
            } catch {
                Start-Sleep -Milliseconds 500
            }
        } while ((Get-Date) -lt $deadline)
        return $false
    }

    #-------------------------
    # Detect Outlook (classic) version; prefer HKCU 16.0, fall back as needed.
    #-------------------------
    $rootCU = 'Registry::HKEY_CURRENT_USER'
    $rootLM = 'Registry::HKEY_LOCAL_MACHINE'
    $detectedVer = $null; $detectedSrc = $null

    foreach ($v in '16.0','15.0','14.0') {
        if (Test-Path (Join-Path $rootCU "Software\Microsoft\Office\$v\Outlook")) {
            $detectedVer = $v; $detectedSrc = "HKCU:Office\$v"; break
        } elseif (Test-Path (Join-Path $rootLM "SOFTWARE\Microsoft\Office\$v\Common\InstallRoot")) {
            $detectedVer = $v; $detectedSrc = "HKLM:Office\$v"; break
        }
    }
    if (-not $detectedVer) {
        $ctr = Get-RegValue $rootLM 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'ProductVersion'
        if ($ctr -and ($ctr -like '16.*')) { $detectedVer = '16.0'; $detectedSrc = 'ClickToRun' }
    }
    if (-not $detectedVer -and $UseOutlookCom) {
        try {
            try { $olApp = [Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application') }
            catch { $olApp = New-Object -ComObject Outlook.Application -ErrorAction Stop }
            $verStr = $olApp.Version
            if ($verStr) { $detectedVer = ($verStr -split '\.')[0..1] -join '.'; $detectedSrc = 'COM' }
        } catch {}
    }
    if (-not $detectedVer) { $detectedVer = '16.0'; $detectedSrc = 'Default' }

    #-------------------------
    # Collect rows (detected version only)
    #-------------------------
    $rows = New-Object System.Collections.Generic.List[object]

    # 1) Policy/User toggles
    $cachedModePaths = @(
        "Software\Policies\Microsoft\Office\$detectedVer\Outlook\Cached Mode",
        "Software\Microsoft\Office\$detectedVer\Outlook\Cached Mode"
    )

    foreach ($path in $cachedModePaths) {
        # Enable
        $val = Get-RegValue $rootCU $path 'Enable'
        if ($val -ne $null) {
            $meaning = if ($val -eq 1) { 'Policy: Use Cached Exchange Mode for new and existing profiles' }
                       elseif ($val -eq 0) { 'Policy: Disable Cached Exchange Mode for new and existing profiles' }
                       else { "Policy value (Enable) = $val" }
            $rows.Add( (New-Row -Scope 'HKCU' -Path $path -Key 'Enable' -Value $val -ValueMeaning $meaning) )
        } else {
            $rows.Add( (New-Row -Scope 'HKCU' -Path $path -Key 'Enable' -Value 'Not Found') )
        }

        # CacheOthersMail
        $co = Get-RegValue $rootCU $path 'CacheOthersMail'
        if ($co -ne $null) {
            $rows.Add( (New-Row -Scope 'HKCU' -Path $path -Key 'CacheOthersMail' -Value $co -ValueMeaning (Interpret-CacheOthersMail $co)) )
        } else {
            $rows.Add( (New-Row -Scope 'HKCU' -Path $path -Key 'CacheOthersMail' -Value 'Not Found') )
        }

        # SyncWindow
        $months = Get-RegValue $rootCU $path 'SyncWindowSetting'
        $days   = Get-RegValue $rootCU $path 'SyncWindowSettingDays'
        if (($months -ne $null) -or ($days -ne $null)) {
            $valOut = if ($days -ne $null) { $days } else { $months }
            $rows.Add( (New-Row -Scope 'HKCU' -Path $path -Key 'SyncWindow' -Value $valOut -ValueMeaning (Interpret-SyncWindow $months $days)) )
        } else {
            $rows.Add( (New-Row -Scope 'HKCU' -Path $path -Key 'SyncWindow' -Value 'Not Found') )
        }
    }

    # OST policy (NoOST)
    foreach ($tuple in @(
        @{Scope='HKLM'; Root=$rootLM; Path="SOFTWARE\Policies\Microsoft\Office\$detectedVer\Outlook\OST"},
        @{Scope='HKCU'; Root=$rootCU; Path="Software\Policies\Microsoft\Office\$detectedVer\Outlook\OST"},
        @{Scope='HKCU'; Root=$rootCU; Path="Software\Microsoft\Office\$detectedVer\Outlook\OST"}
    )) {
        $noost = Get-RegValue $tuple.Root $tuple.Path 'NoOST'
        if ($noost -ne $null) {
            $rows.Add( (New-Row -Scope $tuple.Scope -Path $tuple.Path -Key 'NoOST' -Value $noost -ValueMeaning (Interpret-NoOST $noost)) )
        } else {
            $rows.Add( (New-Row -Scope $tuple.Scope -Path $tuple.Path -Key 'NoOST' -Value 'Not Found') )
        }
    }

    # 2) Per-profile 00036601 (modern then legacy)
    $profileSearchRoots = @(
        "Software\Microsoft\Office\$detectedVer\Outlook\Profiles",
        'Software\Microsoft\Windows NT\CurrentVersion\Windows Messaging Subsystem\Profiles'
    )
    $foundProfileFlag = $false
    foreach ($rel in $profileSearchRoots) {
        $abs = Join-Path $rootCU $rel
        if (Test-Path $abs) {
            $profKeys = Get-ChildItem -Path $abs -ErrorAction SilentlyContinue
            foreach ($pk in $profKeys) {
                $subkeys = Get-ChildItem -Path $pk.PSPath -Recurse -ErrorAction SilentlyContinue
                foreach ($sk in $subkeys) {
                    try {
                        $bin = (Get-ItemProperty -LiteralPath $sk.PSPath -Name '00036601' -ErrorAction Stop).'00036601'
                        if ($bin) {
                            $foundProfileFlag = $true
                            $rows.Add( (New-Row -Scope 'HKCU' -Path ($sk.PSPath.Replace('Registry::','')) -Key '00036601' -Value (Bytes-ToHex $bin) -ValueMeaning (Interpret-00036601 $bin)) )
                        }
                    } catch {}
                }
            }
            if ($foundProfileFlag) { break }
        }
    }
    if (-not $foundProfileFlag) {
        $rows.Add( (New-Row -Scope 'HKCU' -Path "Software\Microsoft\Office\$detectedVer\Outlook\Profiles (or legacy MAPI path)" -Key '00036601' -Value 'Not Found') )
    }

    # 3) Optional: Outlook COM (live per-store cached state)
    if ($UseOutlookCom -or $StoresFlat) {
        $storeList = New-Object System.Collections.Generic.List[object]
        $addedAny  = $false

        try {
            $olApp = $null
            try { $olApp = [Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application') } catch { }
            if (-not $olApp) { $olApp = New-Object -ComObject Outlook.Application -ErrorAction Stop }

            $ns = $olApp.GetNamespace('MAPI')

            # If Outlook is background-only (e.g., "New Mail Alerts"), force Inbox to display to fully init MAPI
            try {
                $exp = $olApp.ActiveExplorer()
                if (-not $exp) {
                    try { $ns.GetDefaultFolder(6).Display() | Out-Null } catch {}
                    Start-Sleep -Milliseconds 800
                }
            } catch {}

            if (-not $ns.LoggedOn) {
                try { $ns.Logon($null,$null,$false,$false) } catch {}
            }

            if (-not (Wait-OutlookReady -Namespace $ns -TimeoutSeconds 30)) {
                throw "Outlook session not ready"
            }

            foreach ($store in @($ns.Stores)) {
                # Gather basics with per-property try/catch
                $dn = '<Unknown Store>'; $isData = $false; $isCached = $null

                try { $dn = $store.DisplayName } catch { }
                try { $isData = $store.IsDataFileStore } catch { $isData = $false }

                # Skip SharePoint/OneDrive and data-file stores
                if ($dn -match '(?i)OneDrive|SharePoint') { continue }
                if ($isData) { continue }

                try { $isCached = $store.IsCachedExchange } catch { $isCached = $null }

                $val = if ($isCached -eq $true) { 'True' } elseif ($isCached -eq $false) { 'False' } else { 'Unknown' }
                $meaning = if ($isCached -eq $true) { 'Outlook COM: Cached Mode (store)' }
                           elseif ($isCached -eq $false) { 'Outlook COM: Online / not cached (store)' }
                           else { $null }

                # Add to the main table
                $rows.Add( (New-Row -Scope 'OutlookCOM' -Path ("Outlook.Application\{0}" -f $dn) -Key 'IsCachedExchange' -Value $val -ValueMeaning $meaning) )
                # Add to flat list
                $storeList.Add( [pscustomobject]@{ StoreName = $dn; Cached = $val } )

                $addedAny = $true
            }

            if (-not $addedAny) {
                if (-not $StoresFlat) {
                    $rows.Add( (New-Row -Scope 'OutlookCOM' -Path 'Outlook.Application' -Key 'IsCachedExchange' -Value 'Not Found') )
                }
            }
        } catch {
            if (-not $StoresFlat) {
                $rows.Add( (New-Row -Scope 'OutlookCOM' -Path 'Outlook.Application' -Key 'IsCachedExchange' -Value 'Not Found') )
            } else {
                Write-Warning "Unable to enumerate Outlook stores via COM."
            }
        }

        if ($StoresFlat) {
            return $storeList | Sort-Object StoreName | Format-Table -AutoSize
        }
    }

    return $rows | Sort-Object Scope, Path, Key, value, ValueMeaning
}
