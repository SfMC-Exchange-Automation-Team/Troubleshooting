# 10/27/2025 BETA BUILD - Author: Cullen Haafke

function Get-DotNetInventory {
<#
.SYNOPSIS
  Dynamic inventory of all installed .NETs (Framework 1.x–4.x, .NET/.NET Core runtimes & SDKs) — PowerShell 5.1-safe.

.DESCRIPTION
  - Recurses .NET Framework NDP registry (native & WOW6432Node). No hardcoded version tables.
  - Enumerates .NET/.NET Core runtimes & SDKs via dotnet CLI; falls back to filesystem if CLI absent or returns no data.
  - Optionally includes:
      * InstalledVersions registry: HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions (sharedfx, hostfxr, host, sdks)
      * ARP (Programs & Features) entries (MSI/MSIX bundles), x64 + WOW6432Node
  - Best-effort InstallDate: InstallDate value -> registry LastWriteTime -> newest file timestamp in related folder.

.PARAMETER LatestPerProduct
  Return only the highest Version per (Type, Product, Architecture) bucket.

.PARAMETER IncludeLanguagePacks
  Include .NET Framework language pack entries (LCID subkeys like 1033). Default: off.

.PARAMETER IncludeInstalledVersions
  Include HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions data. Default: on.

.PARAMETER IncludeARP
  Include Programs & Features (ARP) entries for Microsoft .NET. Default: on.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$LatestPerProduct,
        [switch]$IncludeLanguagePacks,
        [bool]$IncludeInstalledVersions = $true,
        [bool]$IncludeARP = $true
    )

    # ---------------------------
    # Helpers (PS 5.1-compatible)
    # ---------------------------

    function Convert-ToSemVer {
        param([string]$v)
        try { return [version]$v } catch { return $null }
    }

    function Coalesce {
        param($A, $B)
        if ($A -is [string]) { if ([string]::IsNullOrWhiteSpace($A)) { return $B } else { return $A } }
        if ($null -ne $A) { return $A } else { return $B }
    }

    function Get-BestEffortInstallDate {
        param([string]$RegPath, [string]$FallbackDir)
        try {
            if ($RegPath) {
                $key = Get-Item -LiteralPath $RegPath -ErrorAction Stop
                $raw = $key.GetValue('InstallDate')
                if ($null -ne $raw) {
                    $s = [string]$raw
                    if ($s -match '^\d{8}$') { return [datetime]::ParseExact($s,'yyyyMMdd',$null) }
                    try {
                        $ft = [int64]$raw
                        if ($ft -gt 0) { return [datetime]::FromFileTimeUtc($ft) }
                    } catch {}
                }
                if ($key.LastWriteTime) { return $key.LastWriteTime }
            }
        } catch {}
        try {
            if ($FallbackDir -and (Test-Path -LiteralPath $FallbackDir)) {
                $files = Get-ChildItem -LiteralPath $FallbackDir -File -Recurse -ErrorAction SilentlyContinue
                if ($files) { return ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime }
            }
        } catch {}
        return $null
    }

    function Parse-ArpArchitecture {
        param([string]$DisplayName, [string]$Hive)
        $archFromName = $null
        if ($DisplayName -match '\((x64|x86|arm64)\)') { $archFromName = $Matches[1] }
        if ($archFromName) { return $archFromName }
        if ($Hive -like '*WOW6432Node*') { return 'x86' } else { return 'x64' }
    }

    function New-Row {
        param(
            [string]$Type, [string]$Family, [string]$Product, [string]$Version,
            [string]$Architecture, [string]$Source, [string]$Location,
            [nullable[datetime]]$InstallDate, [Nullable[int64]]$Release,
            [Nullable[int]]$SP, [Nullable[int]]$Install,
            [bool]$IsLanguagePack, [bool]$IsWow6432
        )
        $semver = Convert-ToSemVer $Version
        [pscustomobject]@{
            Type           = $Type
            Family         = $Family
            Product        = $Product
            Version        = $Version
            VersionObj     = $semver
            Architecture   = $Architecture
            Source         = $Source
            Location       = $Location
            InstallDate    = $InstallDate
            Release        = $Release
            SP             = $SP
            Install        = $Install
            IsLanguagePack = $IsLanguagePack
            IsWow6432      = $IsWow6432
        }
    }

    # Convenience: resolve ProgramFiles(x86) safely once
    $pf86 = $null
    if (Test-Path -LiteralPath 'Env:\ProgramFiles(x86)') {
        try { $pf86 = (Get-Item -LiteralPath 'Env:\ProgramFiles(x86)').Value } catch {}
    }

    $rows = New-Object System.Collections.Generic.List[object]

    # ---------------------------------
    # .NET Framework (registry, both)
    # ---------------------------------
    $frameworkRoots = @(
        'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\NET Framework Setup\NDP'
    )

    foreach ($root in $frameworkRoots) {
        Write-Verbose ("Scanning .NET Framework registry root: {0}" -f $root)
        if (-not (Test-Path -LiteralPath $root)) { Write-Verbose ("Root not found: {0}" -f $root); continue }

        $keys = Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.PSChildName -notmatch '^(SDF|CDF)$' -and
                    ( $IncludeLanguagePacks -or ($_.PSChildName -notmatch '^\d{4}$') )
                }

        $includedCount = 0
        foreach ($k in $keys) {
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }

            $hasRelease = ($null -ne $p.Release)
            $hasInstall = ($null -ne $p.Install -and [int]$p.Install -eq 1)
            $hasVersion = ($null -ne $p.Version)

            $isV4Full    = ($k.PSPath -match '\\NDP\\v4\\Full($|\\)')
            $isLegacyVer = ($k.PSPath -match '\\NDP\\v[12]\.' -or $k.PSPath -match '\\NDP\\v3\.[05]')

            if (-not ($hasInstall -or $hasRelease -or ($hasVersion -and ($isV4Full -or $isLegacyVer)))) { continue }

            $isLang = ($k.PSChildName -match '^\d{4}$')
            $arch   = if ($root -like '*WOW6432Node*') { 'x86' } else { 'x64' }
            $family = if ($k.PSPath -match '\\NDP\\v4') { 'Framework v4.x' } else { 'Framework v1–3.5' }

            $product = if ($k.Parent -and $k.Parent.PSChildName -match '^v\d') {
                ($k.Parent.PSChildName.Trim() + '\' + $k.PSChildName.Trim()).Trim('\')
            } else { $k.PSChildName }

            if ($family -eq 'Framework v4.x') {
                $fwDir = @(
                    Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
                    Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
                ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            } else {
                $fwDir = @(
                    Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v2.0.50727'
                    Join-Path $env:WINDIR 'Microsoft.NET\Framework\v2.0.50727'
                ) | Where-Object { Test-Path $_ } | Select-Object -First 1
            }

            $date = Get-BestEffortInstallDate -RegPath $k.PSPath -FallbackDir $fwDir
            $row = New-Row -Type 'Framework' -Family $family -Product $product `
                -Version ($p.Version -as [string]) -Architecture $arch -Source 'Registry' `
                -Location $k.PSPath -InstallDate $date -Release $p.Release -SP $p.SP -Install $p.Install `
                -IsLanguagePack:$isLang -IsWow6432:($root -like '*WOW6432Node*')

            $rows.Add($row) | Out-Null
            $includedCount++
        }
        Write-Verbose ("Framework root scanned: {0} | Keys included: {1}" -f $root, $includedCount)
    }

    # ----------------------------------------------------
    # .NET / .NET Core (runtimes & SDKs via CLI / FS)
    # ----------------------------------------------------
    $runtimeCount = 0
    $sdkCount     = 0

    function Invoke-FallbackDotNetFSScan {
        Write-Verbose "dotnet CLI not available or returned no data; using filesystem discovery."

        # Build shared roots list safely
        $sharedRoots = @()
        if ($env:ProgramFiles) { $sharedRoots += (Join-Path $env:ProgramFiles 'dotnet\shared') }
        if ($pf86)            { $sharedRoots += (Join-Path $pf86            'dotnet\shared') }
        $sharedRoots = $sharedRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

        foreach ($shared in $sharedRoots) {
            $arch = if ($shared -like '*Program Files (x86)*') { 'x86' } else { 'x64' }
            Get-ChildItem -LiteralPath $shared -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $productDir = $_
                Get-ChildItem -LiteralPath $productDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $row = New-Row -Type 'Runtime' -Family '.NET' -Product $productDir.Name `
                        -Version $_.Name -Architecture $arch -Source 'FileSystem' -Location $_.FullName `
                        -InstallDate (Get-BestEffortInstallDate -RegPath $null -FallbackDir $_.FullName) `
                        -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                    $rows.Add($row) | Out-Null
                    $runtimeCount++
                }
            }
        }

        # Build sdk roots list safely
        $sdkRoots = @()
        if ($env:ProgramFiles) { $sdkRoots += (Join-Path $env:ProgramFiles 'dotnet\sdk') }
        if ($pf86)            { $sdkRoots += (Join-Path $pf86            'dotnet\sdk') }
        $sdkRoots = $sdkRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

        foreach ($sdk in $sdkRoots) {
            $arch = if ($sdk -like '*Program Files (x86)*') { 'x86' } else { 'x64' }
            Get-ChildItem -LiteralPath $sdk -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $row = New-Row -Type 'SDK' -Family '.NET' -Product 'SDK' `
                    -Version $_.Name -Architecture $arch -Source 'FileSystem' -Location $_.FullName `
                    -InstallDate (Get-BestEffortInstallDate -RegPath $null -FallbackDir $_.FullName) `
                    -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                $rows.Add($row) | Out-Null
                $sdkCount++
            }
        }
    }

    function Invoke-DotNetCLIScan {
        param([Parameter(Mandatory)][string]$CliPath)

        Write-Verbose "Attempting to use dotnet CLI to list runtimes and SDKs... ($CliPath)"
        try {
            & $CliPath --list-runtimes 2>$null | ForEach-Object {
                if ($_ -match '^(?<prod>[^ ]+)\s+(?<ver>[^ ]+)\s+\[(?<path>[^\]]+)\]') {
                    $prod = $Matches.prod; $ver = $Matches.ver; $loc = $Matches.path
                    $arch = if ($loc -match 'Program Files \(x86\)') { 'x86' } else { 'x64' }
                    $row = New-Row -Type 'Runtime' -Family '.NET' -Product $prod `
                        -Version $ver -Architecture $arch -Source 'DotNetCLI' -Location $loc `
                        -InstallDate (Get-BestEffortInstallDate -RegPath $null -FallbackDir $loc) `
                        -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                    $rows.Add($row) | Out-Null
                    $runtimeCount++
                }
            }
        } catch {}

        try {
            & $CliPath --list-sdks 2>$null | ForEach-Object {
                if ($_ -match '^(?<ver>[^ ]+)\s+\[(?<path>[^\]]+)\]') {
                    $ver = $Matches.ver; $loc = $Matches.path
                    $arch = if ($loc -match 'Program Files \(x86\)') { 'x86' } else { 'x64' }
                    $row = New-Row -Type 'SDK' -Family '.NET' -Product 'SDK' `
                        -Version $ver -Architecture $arch -Source 'DotNetCLI' -Location $loc `
                        -InstallDate (Get-BestEffortInstallDate -RegPath $null -FallbackDir $loc) `
                        -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                    $rows.Add($row) | Out-Null
                    $sdkCount++
                }
            }
        } catch {}
    }

    # Resolve CLI candidates: PATH + explicit x86
    $cliCandidates = New-Object System.Collections.Generic.List[string]
    $primaryCli = $null
    try { $primaryCli = (Get-Command dotnet -ErrorAction Stop).Source } catch {}
    if ($primaryCli) { $cliCandidates.Add($primaryCli) | Out-Null }

    if ($pf86) {
        $dotnetX86 = Join-Path $pf86 'dotnet\dotnet.exe'
        if (Test-Path -LiteralPath $dotnetX86 -PathType Leaf) {
            Write-Verbose "Found 32-bit dotnet CLI at: $dotnetX86"
            if (-not ($cliCandidates -contains $dotnetX86)) { $cliCandidates.Add($dotnetX86) | Out-Null }
        }
    }

    if ($cliCandidates.Count -gt 0) {
        foreach ($cli in $cliCandidates) { Invoke-DotNetCLIScan -CliPath $cli }
        if ($runtimeCount -eq 0 -and $sdkCount -eq 0) {
            Write-Verbose "dotnet CLI executed but returned no runtimes or SDKs. Falling back to filesystem."
            Invoke-FallbackDotNetFSScan
        }
    } else {
        Invoke-FallbackDotNetFSScan
    }

    Write-Verbose ("dotnet runtimes parsed: {0}" -f $runtimeCount)
    Write-Verbose ("dotnet SDKs parsed:     {0}" -f $sdkCount)

    # ---------------------------------------------
    # InstalledVersions registry (optional)
    # ---------------------------------------------
    if ($IncludeInstalledVersions) {
        $ivRoot = 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions'
        if (Test-Path -LiteralPath $ivRoot) {
            Write-Verbose ("Scanning InstalledVersions: {0}" -f $ivRoot)
            $ivCount = 0
            $arches = Get-ChildItem -LiteralPath $ivRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^(x86|x64|arm64)$' }
            foreach ($a in $arches) {
                $arch = $a.PSChildName

                # Top-level host version (if present)
                try {
                    $top = Get-ItemProperty -LiteralPath $a.PSPath -ErrorAction SilentlyContinue
                    if ($top -and $top.Version) {
                        $locTop = $top.InstallLocation
                        $row = New-Row -Type 'Installed' -Family '.NET' -Product 'host' `
                            -Version ($top.Version -as [string]) -Architecture $arch -Source 'InstalledVersions' `
                            -Location (Coalesce $locTop $a.PSPath) `
                            -InstallDate (Get-BestEffortInstallDate -RegPath $a.PSPath -FallbackDir $locTop) `
                            -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                        $rows.Add($row) | Out-Null
                        $ivCount++
                    }
                } catch {}

                # Buckets: sharedfx, hostfxr, host, sdks
                $buckets = Get-ChildItem -LiteralPath $a.PSPath -ErrorAction SilentlyContinue |
                           Where-Object { $_.PSIsContainer -and $_.PSChildName -in @('sharedfx','hostfxr','host','sdks') }

                foreach ($b in $buckets) {
                    if ($b.PSChildName -eq 'sdks') {
                        Get-ChildItem -LiteralPath $b.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                            $ver = $_.PSChildName
                            $pp  = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                            $loc = $pp.InstallLocation
                            $row = New-Row -Type 'Installed' -Family '.NET' -Product 'SDK' `
                                -Version $ver -Architecture $arch -Source 'InstalledVersions' `
                                -Location (Coalesce $loc $_.PSPath) `
                                -InstallDate (Get-BestEffortInstallDate -RegPath $_.PSPath -FallbackDir $loc) `
                                -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                            $rows.Add($row) | Out-Null
                            $ivCount++
                        }
                    } else {
                        # sharedfx/hostfxr/host: ProductName\<version>
                        Get-ChildItem -LiteralPath $b.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                            $prodNameNode = $_
                            Get-ChildItem -LiteralPath $prodNameNode.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                                $ver = $_.PSChildName
                                $pp  = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                                $loc = Coalesce $pp.Path $pp.InstallLocation
                                $row = New-Row -Type 'Installed' -Family '.NET' -Product $prodNameNode.PSChildName `
                                    -Version $ver -Architecture $arch -Source 'InstalledVersions' `
                                    -Location (Coalesce $loc $_.PSPath) `
                                    -InstallDate (Get-BestEffortInstallDate -RegPath $_.PSPath -FallbackDir $loc) `
                                    -Release $null -SP $null -Install $null -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                                $rows.Add($row) | Out-Null
                                $ivCount++
                            }
                        }
                    }
                }
            }
            Write-Verbose ("InstalledVersions rows: {0}" -f $ivCount)
        } else {
            Write-Verbose ("InstalledVersions root not found: {0}" -f $ivRoot)
        }
    }

    # ---------------------------------------------
    # ARP (Programs & Features) (optional)
    # ---------------------------------------------
    if ($IncludeARP) {
        $arpRoots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        $arpCount = 0
        foreach ($arp in $arpRoots) {
            if (-not (Test-Path -LiteralPath $arp)) { continue }
            Get-ChildItem -LiteralPath $arp -ErrorAction SilentlyContinue | ForEach-Object {
                try { $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } catch { return }
                $dn = $p.DisplayName
                if (-not $dn) { return }
                if ($dn -notmatch '(^|\s)\.NET(\s|$)|Microsoft\.NET') { return }

                $ver  = [string]$p.DisplayVersion
                $arch = Parse-ArpArchitecture -DisplayName $dn -Hive $arp

                $idate = $null
                if ($p.InstallDate) {
                    $s = [string]$p.InstallDate
                    try { if ($s -match '^\d{8}$') { $idate = [datetime]::ParseExact($s,'yyyyMMdd',$null) } } catch {}
                }

                $row = New-Row -Type 'ARP' -Family '.NET' -Product $dn `
                    -Version $ver -Architecture $arch -Source 'ARP' -Location $_.PSPath `
                    -InstallDate $idate -Release $null -SP $null -Install $null `
                    -IsLanguagePack:$false -IsWow6432:($arch -eq 'x86')
                $rows.Add($row) | Out-Null
                $arpCount++
            }
        }
        Write-Verbose ("ARP rows: {0}" -f $arpCount)
    }

    # --------------
    # Final shaping
    # --------------
    if (-not $rows.Count) { return @() }

    # De-duplicate (Type+Product+Arch+Version+Location)
    $rows = $rows | Sort-Object Type, Product, Architecture, Version, Location -Descending -Unique

    if ($LatestPerProduct) {
        $rows = $rows | Group-Object Type, Product, Architecture | ForEach-Object {
            $_.Group | Sort-Object @{e='VersionObj';Descending=$true}, @{e='Version';Descending=$true} | Select-Object -First 1
        }
    } else {
        $order = @{ Framework = 0; Installed = 1; Runtime = 2; SDK = 3; ARP = 4 }
        $rows = $rows | Sort-Object @{e={ $order[$_.Type] }}, Product, Architecture, @{e='VersionObj';Descending=$true}, @{e='Version';Descending=$true}
    }

    Write-Verbose ("Final rows: Framework={0}, Installed={1}, Runtimes={2}, SDKs={3}, ARP={4}" -f `
        ($rows | Where-Object { $_.Type -eq 'Framework' }).Count, `
        ($rows | Where-Object { $_.Type -eq 'Installed' }).Count, `
        ($rows | Where-Object { $_.Type -eq 'Runtime' }).Count, `
        ($rows | Where-Object { $_.Type -eq 'SDK' }).Count, `
        ($rows | Where-Object { $_.Type -eq 'ARP' }).Count)

    # -------------------------
    # Default output (refined)
    # -------------------------
    $rows | Select-Object Type, Product, Version, Architecture, Source, InstallDate
    # Optional (for human viewing): | Format-Table -AutoSize
}
