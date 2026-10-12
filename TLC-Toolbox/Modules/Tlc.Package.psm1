Set-StrictMode -Version Latest

<#
    Packaging.

    A handover bundle needs to be provable. The manifest records a SHA256 for every
    file plus one for the archive, so both sides can show later exactly what was
    handed over - which matters when the evidence contains diagnostics and the
    question "was this altered" can actually come up.
#>

function Get-TlcFileHash {
    <#
    .SYNOPSIS
        SHA256 for a file, without depending on Get-FileHash.
    .DESCRIPTION
        Get-FileHash is a function exported by Microsoft.PowerShell.Utility rather than an engine
        cmdlet, so it is resolved by module autoloading and that resolution can fail. Observed on a
        real run: a PSModulePath carrying PowerShell 7 entries makes Windows PowerShell 5.1 resolve
        Utility against the wrong copy and Get-FileHash is absent, so packaging died after the
        collection had already succeeded.

        Test-TlcBundleIntegrity in this same module was already hashing with raw SHA256, which left
        the toolbox able to verify a bundle in a context where it could not create one - exactly the
        wrong way round, because creation is what happens on the customer's machine.

        Shared read, so a file something else holds open still hashes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.FileStream]::new((ConvertTo-TlcNativeFilePath -Path $Path), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
        } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Add-TlcZipFolder {
    <#
    .SYNOPSIS
        Writes one folder's files into an already-open archive.
    .DESCRIPTION
        The part of archiving that is easy to get wrong lives here so it exists once: the
        share mode that tolerates a file antivirus or OneDrive holds open, the 1980 floor
        the zip format imposes on timestamps, the 1 MB buffer, and forward-slash entry
        names on every host. New-TlcZipArchive and New-TlcSessionArchive differ only in
        how many folders they feed it and under what prefix.

        Returns the number of entries written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.Compression.ZipArchive] $Archive,
        [Parameter(Mandatory)] [string] $SourcePath,
        [string] $EntryPrefix = '',
        [string] $DestinationFull = '',
        [string[]] $ExcludedPrefix = @()
    )

    $source = (Resolve-Path -LiteralPath $SourcePath).ProviderPath.TrimEnd('\')
    $nativeSource = ConvertTo-TlcNativeFilePath -Path $source
    $nativeDestination = if ($DestinationFull) { ConvertTo-TlcNativeFilePath -Path $DestinationFull } else { '' }
    $prefix = if ($EntryPrefix) { $EntryPrefix.Trim('/') + '/' } else { '' }
    $written = 0

    foreach ($file in [System.IO.Directory]::EnumerateFiles($nativeSource, '*', [System.IO.SearchOption]::AllDirectories)) {
        # An archive written inside the folder being archived would try to contain
        # itself. Callers place it outside, but this is cheap to be certain of.
        if ($nativeDestination -and [string]::Equals($file, $nativeDestination, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

        $relative = $prefix + ($file.Substring($nativeSource.Length).TrimStart('\') -replace '\\', '/')

        # An endpoint the privacy gate refused. Its evidence does not travel; the run's
        # own records of it do, so the exclusion stays auditable.
        $skip = $false
        foreach ($excluded in $ExcludedPrefix) {
            if ($relative.StartsWith($excluded, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $entry = $Archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)

        # The zip format cannot store a date before 1980 and the setter throws
        # rather than clamping. A stray system timestamp must not fail the bundle.
        $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($file)
        if ($lastWrite.Year -lt 1980) { $lastWrite = [datetime]::new(1980, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc) }
        $entry.LastWriteTime = [System.DateTimeOffset]::new($lastWrite, [System.TimeSpan]::Zero)

        $reader = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        try {
            $writer = $entry.Open()
            try { $reader.CopyTo($writer, 1048576) } finally { $writer.Dispose() }
        } finally {
            $reader.Dispose()
        }
        $written++
    }

    return $written
}

function New-TlcSessionArchive {
    <#
    .SYNOPSIS
        Writes several of a session's collections into one archive.
    .DESCRIPTION
        A wizard session can produce several collections - a first attempt with the wrong
        window, a second after widening it, a third once the customer reproduced the fault -
        and they routinely all belong to the same support case. This is the carrier for
        sending them together.

        It is a carrier and not a substitute. By default it archives the SEALED BUNDLES:
        each run's TLC-<CorrelationId>.zip and its TLC-<CorrelationId>.bundle.json, which is
        what an engineer needs to verify what they were sent. The hash file travels beside
        the archive it describes and never inside it, for the same reason it is written
        outside the bundle in the first place - a hash kept inside the thing it describes
        proves nothing.

        Archiving the run folders instead would hand over unsealed evidence with no way to
        check it had arrived intact, and would duplicate content that is already compressed
        one folder up. -IncludeRunFolder exists for an operator who asks for the raw folders.

        A run with no sealed bundle is LEFT OUT and named in SkippedRuns. It used to fall back
        to its raw run folder, so a package the privacy gate had refused went into the carrier
        unsealed and unmasked, as if it had passed (review 2026-09-30, finding 331). Leaving a
        run out silently would be wrong too, which is why it is named: the caller says so.

        Runs keep their correlation id, which is what ties each one back to its own Run.json.
        Nothing is copied to a staging folder on the way: a 165 MB run duplicated to temp to
        be read once is time and disk spent for nothing, and it is the kind of copy that
        fails halfway on a full volume.

        Returns the archive path and what went into it, or $null if nothing did.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RunPath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [switch] $IncludeRunFolder
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $runs = @($RunPath | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($runs.Count -eq 0) { return $null }

    $bundleOf = { param($run) Join-Path (Split-Path -Parent $run) ('TLC-{0}.zip' -f (Split-Path -Leaf $run)) }
    $skipped = @(if (-not $IncludeRunFolder) {
        $runs | Where-Object { -not (Test-Path -LiteralPath (& $bundleOf $_)) } | ForEach-Object { Split-Path -Leaf $_ }
    })
    $runs = @($runs | Where-Object { $IncludeRunFolder -or (Test-Path -LiteralPath (& $bundleOf $_)) })
    if ($runs.Count -eq 0) { return $null }

    $destinationFull = [System.IO.Path]::GetFullPath($DestinationPath)
    $parent = Split-Path -Parent $destinationFull
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    if (Test-Path -LiteralPath $destinationFull) { Remove-Item -LiteralPath $destinationFull -Force }

    $written = 0
    $included = New-Object System.Collections.Generic.List[string]

    $archive = [System.IO.Compression.ZipFile]::Open((ConvertTo-TlcNativeFilePath -Path $destinationFull), [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($run in $runs) {
            $leaf = Split-Path -Leaf $run
            $runParent = Split-Path -Parent $run

            $bundle = Join-Path $runParent "TLC-$leaf.zip"
            $manifest = Join-Path $runParent "TLC-$leaf.bundle.json"
            $sealed = (-not $IncludeRunFolder) -and (Test-Path -LiteralPath $bundle)

            if ($sealed) {
                foreach ($file in @($bundle, $manifest)) {
                    if (-not (Test-Path -LiteralPath $file)) { continue }
                    $entry = $archive.CreateEntry((Split-Path -Leaf $file), [System.IO.Compression.CompressionLevel]::Optimal)
                    $nativeFile = ConvertTo-TlcNativeFilePath -Path $file
                    $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($nativeFile)
                    if ($lastWrite.Year -lt 1980) { $lastWrite = [datetime]::new(1980, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc) }
                    $entry.LastWriteTime = [System.DateTimeOffset]::new($lastWrite, [System.TimeSpan]::Zero)
                    $reader = [System.IO.FileStream]::new($nativeFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                    try {
                        $writer = $entry.Open()
                        try { $reader.CopyTo($writer, 1048576) } finally { $writer.Dispose() }
                    } finally { $reader.Dispose() }
                    $written++
                }
            } else {
                # Only reached with -IncludeRunFolder: the operator asked for the raw folder.
                $written += Add-TlcZipFolder -Archive $archive -SourcePath $run -EntryPrefix $leaf -DestinationFull $destinationFull
            }
            $included.Add($leaf)
        }
    } finally {
        $archive.Dispose()
    }

    return [pscustomobject]@{
        Path        = $destinationFull
        RunCount    = $included.Count
        FileCount   = $written
        Runs        = $included.ToArray()
        SkippedRuns = $skipped
        Bytes       = (Get-Item -LiteralPath $destinationFull).Length
    }
}

function New-TlcZipArchive {
    <#
    .SYNOPSIS
        Writes a folder to a zip archive, tolerating files other processes hold open.
    .DESCRIPTION
        Replaces Compress-Archive for two measured reasons.

        Robustness first, because it is the one that loses evidence. Compress-Archive
        opens each file without sharing, so a single file held open by antivirus, a
        backup agent or OneDrive fails the whole archive - and the failure lands after
        collection has succeeded, on data that cannot be gathered again once the logs
        have rolled. It matters most in the customer collector's failure path, where
        the bundle being written is the only record of why the run went wrong: an
        archiver that throws there leaves the user with nothing to send. Verified by
        holding a file open and archiving the folder - Compress-Archive and
        ZipFile::CreateFromDirectory both fail, this succeeds.

        The share mode is the same one used to read Teams' own open log files, so the
        toolbox treats a locked file the same way wherever it meets one.

        Speed second. On a 100 MB payload: Compress-Archive 7,310 ms,
        ZipFile::CreateFromDirectory 2,298 ms, this 2,035 ms - identical 3.9 MB
        output. Enumerating with Directory.EnumerateFiles and copying through a 1 MB
        buffer is what closes the gap; the default 80 KB buffer costs ~950 ms more.

        Entry names are written with forward slashes on every host. Compress-Archive
        writes backslashes on Windows PowerShell 5.1 and forward slashes on 7, which
        is a real problem in this toolbox's own workflow - the customer collects on
        5.1 and the engineer verifies on 7. Normalising here fixes it at the source
        rather than in the verifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [string[]] $ExcludeEndpoint = @()
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $destinationFull = [System.IO.Path]::GetFullPath($DestinationPath)

    # Entry names are normalised to forward slashes below, so the prefixes are too.
    $excludedPrefixes = @($ExcludeEndpoint | Where-Object { $_ } | ForEach-Object { "Endpoints/$_/" })

    $archive = [System.IO.Compression.ZipFile]::Open((ConvertTo-TlcNativeFilePath -Path $DestinationPath), [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $written = Add-TlcZipFolder -Archive $archive -SourcePath $SourcePath `
            -DestinationFull $destinationFull -ExcludedPrefix $excludedPrefixes
    } finally {
        $archive.Dispose()
    }

    return $written
}

function New-TlcFileManifest {
    <#
    .SYNOPSIS
        Hashes every file in the run folder.
    .DESCRIPTION
        ExcludeEndpoint drops an endpoint the privacy gate refused. The manifest is what a
        reviewer reads to know what the bundle contains, so a withheld endpoint must not
        appear here - and New-TlcBundle records the exclusion separately, because a file
        that is silently absent from a manifest is indistinguishable from one that was
        never collected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunPath,
        [string[]] $ExcludeName = @(),
        [string[]] $ExcludeEndpoint = @()
    )

    $excludedPrefixes = @($ExcludeEndpoint | Where-Object { $_ } | ForEach-Object { "Endpoints\$_\" })
    $nativeRoot = (ConvertTo-TlcNativeFilePath -Path $RunPath).TrimEnd('\')
    $entries = foreach ($path in [IO.Directory]::EnumerateFiles($nativeRoot, '*', [IO.SearchOption]::AllDirectories)) {
        $file = [IO.FileInfo]::new($path)
        $relative = $path.Substring($nativeRoot.Length).TrimStart('\')
        # The run's own files by their path at the root, not by name anywhere: collected
        # evidence can be called manifest.json too, and matched by name it was zipped unhashed
        # (review 2026-09-30, finding 331).
        if ($relative -in $ExcludeName) { continue }

        $skip = $false
        foreach ($prefix in $excludedPrefixes) {
            if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if ($skip) { continue }

        # PSCustomObject rather than a hashtable so Measure-Object and Where-Object
        # can address the fields as properties.
        [pscustomobject][ordered]@{
            Path         = $relative
            SizeBytes    = $file.Length
            Sha256       = Get-TlcFileHash -Path $file.FullName
            LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
        }
    }

    return @($entries)
}

function Assert-TlcBundleScope {
    <#
    .SYNOPSIS
        Refuses to seal evidence the privacy gate never inspected.
    .DESCRIPTION
        The gate reads one endpoint's folder (Get-TlcIdentityInventory -EndpointPath) while
        the bundle manifests and zips the whole run folder. Those were the same set of files
        only for as long as a run had one endpoint, which is true of every scenario that
        ships today and stops being true the moment a run collects from more than one
        machine.

        Nothing in the gate would notice. It would return Success having scanned one
        machine, and the bundle would be sealed, hashed and handed over carrying the other
        nine. That is the same failure as finding 98 - an input that silently stopped
        matching its premise when the thing around it grew - except the consequence here is
        disclosure rather than a wrong number on a tile.

        This does not decide what fleet mode should do about a partly-blocked run. It
        enforces the one thing every candidate policy needs: the set of endpoints in the
        bundle and the set the gate inspected have to agree. Gate them all and they agree;
        exclude the blocked ones from the archive and they agree. Only silent divergence is
        refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunPath,
        [string[]] $InspectedEndpoints
    )

    $endpointsRoot = Join-Path $RunPath 'Endpoints'
    $present = @(Get-ChildItem -LiteralPath $endpointsRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })

    if ($present.Count -eq 0) { return @() }

    $inspected = @($InspectedEndpoints | Where-Object { $_ })
    return @($present | Where-Object { $_ -notin $inspected })
}

function New-TlcBundle {
    <#
    .SYNOPSIS
        Packages the run folder into a hashed archive with a manifest.
    .DESCRIPTION
        The manifest is written before compression and is itself included in the
        archive, so the archive is self-describing. The archive hash is recorded
        outside the archive, because a hash stored inside the thing it describes
        proves nothing.

        Sealing is refused when the run holds evidence from an endpoint that was neither
        inspected nor deliberately excluded - see Assert-TlcBundleScope.

        ExcludedEndpoints carries the endpoints the privacy gate refused. Their evidence is
        left out of both the manifest and the archive, while the run's own records of them -
        the events, the blockers, the reason - travel with the bundle. That asymmetry is the
        point: a reviewer must be able to see that a machine was withheld and why. A bundle
        that simply omitted it would be indistinguishable from one where that machine was
        never collected at all.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Run,
        [System.Collections.IDictionary] $Privacy,
        [System.Collections.IDictionary] $PrivacyResult,
        [System.Collections.IDictionary] $Consent,
        [System.Collections.IDictionary[]] $EndpointResults,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $runPath = $Run.RunPath

    # Falls back to the single endpoint being packaged when the gate result predates this
    # key. That is the historical behaviour and is correct for a one-endpoint run - and the
    # check below still fires if a second endpoint folder is present, so the fallback
    # cannot be used to slip past it.
    $inspected = @($Endpoint)
    if ($PrivacyResult -and $PrivacyResult.Contains('InspectedEndpoints')) {
        $inspected = @($PrivacyResult.InspectedEndpoints)
    }

    # Per-endpoint verdicts, when the caller gated more than one machine. Every endpoint it
    # looked at counts as inspected; the refused ones are additionally excluded from what
    # gets sealed.
    $excluded = @()
    $excludedDetail = @()
    if ($EndpointResults) {
        $inspected = @($EndpointResults | ForEach-Object { [string]$_.Endpoint } | Where-Object { $_ })
        foreach ($result in $EndpointResults) {
            if (-not $result.Blocked) { continue }
            $excluded += [string]$result.Endpoint
            $excludedDetail += [pscustomobject][ordered]@{
                Endpoint = [string]$result.Endpoint
                Reasons  = @($result.Reasons)
            }
        }
    }

    $uninspected = @(Assert-TlcBundleScope -RunPath $runPath -InspectedEndpoints $inspected)
    if ($uninspected.Count -gt 0) {
        Write-TlcBlocker -Check 'Package.Scope' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
            -Detail ("The run holds evidence from $($uninspected.Count) endpoint(s) the privacy gate did not inspect: $($uninspected -join ', '). " +
                     'Sealing it would hand over evidence that was never checked for unrecognised identities.') `
            -Remediation 'Run the privacy gate against every endpoint in the run, or remove the uninspected endpoint folders before packaging.' | Out-Null
        Write-TlcEvent -Phase 'Package' -Step 'BundleScope' -Status 'Failed' -Severity 'Critical' -Endpoint $Endpoint `
            -Message "Uninspected endpoint(s) in the run: $($uninspected -join ', ')."
        throw "The bundle was not sealed: $($uninspected.Count) endpoint(s) in this run were never inspected by the privacy gate ($($uninspected -join ', '))."
    }

    # Every endpoint refused leaves nothing worth sealing. An empty bundle that reports
    # success is worse than a refusal, because it looks like a completed collection.
    if ($excluded.Count -gt 0 -and $excluded.Count -eq @($inspected).Count) {
        Write-TlcBlocker -Check 'Package.Scope' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
            -Detail "Every endpoint in this run was refused by the privacy gate ($($excluded -join ', ')), so there is no evidence left to package." `
            -Remediation 'Resolve the privacy findings for at least one endpoint, then re-run -Stage Package with the same -CorrelationId, -Scenario and -CaseNumber.' | Out-Null
        Write-TlcEvent -Phase 'Package' -Step 'BundleScope' -Status 'Failed' -Severity 'Critical' -Endpoint $Endpoint `
            -Message 'All endpoints excluded; nothing to seal.'
        throw "The bundle was not sealed: every endpoint was refused by the privacy gate ($($excluded -join ', '))."
    }

    $bundleName = "TLC-$($Run.CorrelationId).zip"
    $bundlePath = Join-Path (Split-Path -Parent $runPath) $bundleName

    $files = New-TlcFileManifest -RunPath $runPath -ExcludeName @('Manifest.json', 'Bundle.json') -ExcludeEndpoint $excluded

    $manifest = [ordered]@{
        CorrelationId  = $Run.CorrelationId
        RunId          = $Run.RunId
        Scenario       = $Run.Scenario
        CaseNumber     = $Run.CaseNumber
        CustomerName   = $Run.CustomerName
        Operator       = $Run.Operator
        CreatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        FileCount      = $files.Count
        TotalBytes     = if ($files.Count -gt 0) { ($files | Measure-Object -Property SizeBytes -Sum).Sum } else { 0 }
        Privacy        = $PrivacyResult
        Consent        = $Consent
        # What the bundle covers, stated rather than inferred from the file list. A reviewer
        # asking "is this everything?" gets an answer here instead of counting folders.
        IncludedEndpoints = @($inspected | Where-Object { $_ -notin $excluded })
        ExcludedEndpoints = @($excludedDetail)
        Files          = $files
    }

    $manifestPath = Join-Path $runPath 'Manifest.json'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    if (-not $PSCmdlet.ShouldProcess($bundlePath, 'Create evidence bundle')) { return $null }

    # Packaging is where a run meets the file system hardest: a large bundle, a long
    # path, a full disk, or a virus scanner holding a file open. Failing here after a
    # successful collection would throw away work that cannot be repeated once the
    # logs have rolled, so the failure is recorded against the run rather than
    # escaping as a raw error.
    try {
        if (Test-Path -LiteralPath $bundlePath) { Remove-Item -LiteralPath $bundlePath -Force }
        $null = New-TlcZipArchive -SourcePath $runPath -DestinationPath $bundlePath -ExcludeEndpoint $excluded
    } catch {
        Write-TlcBlocker -Check 'Package.Compress' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
            -Detail "The bundle could not be written: $($_.Exception.Message)" `
            -Remediation 'Check free space and the path length of the output root, then re-run -Stage Package with the same -CorrelationId, -Scenario and -CaseNumber.' | Out-Null
        Write-TlcEvent -Phase 'Package' -Step 'CreateBundle' -Status 'Failed' -Severity 'Critical' -Endpoint $Endpoint `
            -Message 'Archive creation failed.' -ErrorRecord $_
        Write-TlcToolLog -Message 'Packaging failed.' -Level 'ERROR' -ErrorRecord $_

        # The run folder is intact, so the evidence is not lost - only the archive.
        # Saying so is the difference between a retry and a re-collection.
        throw "The evidence bundle could not be written, but the run folder is intact at $runPath. $($_.Exception.Message)"
    }

    $bundleHash = Get-TlcFileHash -Path $bundlePath
    $bundleSize = (Get-Item -LiteralPath $bundlePath).Length

    $record = [ordered]@{
        BundlePath     = $bundlePath
        BundleName     = $bundleName
        BundleSizeBytes= $bundleSize
        BundleSha256   = $bundleHash
        ManifestPath   = $manifestPath
        FileCount      = $files.Count
        CreatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }

    # Written next to the archive, not inside it.
    $record | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path (Split-Path -Parent $runPath) "TLC-$($Run.CorrelationId).bundle.json") -Encoding utf8

    Write-TlcBlocker -Check 'Package' -Status 'Success' -Endpoint $Endpoint `
        -Detail "$bundleName, $([math]::Round($bundleSize/1MB,2)) MB, $($files.Count) file(s), SHA256 $($bundleHash.Substring(0,16))..." | Out-Null
    Write-TlcEvent -Phase 'Package' -Step 'CreateBundle' -Status 'Complete' -Endpoint $Endpoint `
        -Message "Bundle created with $($files.Count) file(s)." -EvidencePath $bundlePath

    return $record
}

function Test-TlcBundleIntegrity {
    <#
    .SYNOPSIS
        Verifies the manifest against the contents of the sealed archive.
    .DESCRIPTION
        Verification reads from the archive, not the run folder, and the distinction
        is not cosmetic. The run folder stays live after packaging - Blockers.csv and
        Events.jsonl are appended to and Run.json is rewritten as the run finishes -
        so checking the folder reports mismatches for files that were never tampered
        with, and the real signal drowns in the noise.

        The archive is the thing handed to the customer, so the archive is the thing
        that has to be provable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BundlePath
    )

    if (-not (Test-Path -LiteralPath $BundlePath)) {
        throw "Bundle not found: $BundlePath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = [System.IO.Compression.ZipFile]::OpenRead((ConvertTo-TlcNativeFilePath -Path $BundlePath))
    try {
        $manifestEntry = $archive.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq 'Manifest.json' }
        if (-not $manifestEntry) { throw "Manifest.json is not present inside $BundlePath" }

        $reader = [System.IO.StreamReader]::new($manifestEntry.Open())
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }

        # Two manifest shapes exist on purpose. The toolbox writes a rich object with
        # a Files collection; Invoke-TlcQuickCollect writes a bare array, because a
        # customer-facing file should stay as simple as it can be. An engineer
        # verifying a bundle should not have to know or care which produced it.
        #
        # The outer @() is load-bearing on Windows PowerShell 5.1: assigning from an
        # if statement there unwraps a single-element array back to a scalar, so a
        # one-file manifest would arrive as a PSCustomObject and .Count would fail.
        # PowerShell 7 preserves the array, which is why this only broke on 5.1.
        $files = @(
            if ($manifest.PSObject.Properties.Name -contains 'Files') { $manifest.Files } else { $manifest }
        )

        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $mismatches = [System.Collections.Generic.List[string]]::new()
            $missing = [System.Collections.Generic.List[string]]::new()

            # Compress-Archive writes backslash separators on Windows PowerShell 5.1
            # and forward slashes on PowerShell 7. That difference matters precisely
            # in the case this tool is built for: the customer collects on 5.1, the
            # engineer verifies on 7. Both sides are normalised before matching.
            $entryMap = @{}
            foreach ($zipEntry in $archive.Entries) {
                $key = $zipEntry.FullName -replace '\\', '/'
                $entryMap[$key] = $zipEntry
            }

            foreach ($entry in $files) {
                $normalized = $entry.Path -replace '\\', '/'
                if (-not $entryMap.ContainsKey($normalized)) {
                    $missing.Add($entry.Path)
                    continue
                }

                $stream = $entryMap[$normalized].Open()
                try {
                    $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
                } finally {
                    $stream.Dispose()
                }
                if ($hash -ne $entry.Sha256) { $mismatches.Add($entry.Path) }
            }

            # Anything in the archive the manifest does not account for.
            #
            # Checking only the manifest's own entries answers "is everything I recorded
            # still here and unchanged", which is half the question. A file ADDED to the
            # bundle afterwards passed verification silently - so a bundle could be handed
            # on carrying fabricated evidence and still report Valid. Proven: planting
            # ClientLogs/PLANTED-evidence.log into a sealed bundle returned Valid=True.
            #
            # Two names are legitimately absent from the manifest and are expected rather
            # than ignored. Manifest.json cannot contain its own hash. ToolLog.txt is
            # written after the manifest is computed and keeps being appended to, so
            # hashing it would guarantee a false mismatch - see the run-folder note above.
            $expectedUnhashed = @('Manifest.json', 'ToolLog.txt')
            $manifestPaths = @($files | ForEach-Object { $_.Path -replace '\\', '/' })

            $unexpected = [System.Collections.Generic.List[string]]::new()
            foreach ($key in $entryMap.Keys) {
                if ($manifestPaths -contains $key) { continue }
                if ($expectedUnhashed -contains $key) { continue }
                $unexpected.Add($key)
            }

            return [pscustomobject]@{
                BundlePath = $BundlePath
                FileCount  = $files.Count
                Missing    = @($missing)
                Mismatched = @($mismatches)
                Unexpected = @($unexpected)
                Valid      = ($missing.Count -eq 0 -and $mismatches.Count -eq 0 -and $unexpected.Count -eq 0)
            }
        } finally {
            $sha.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

Export-ModuleMember -Function Get-TlcFileHash, New-TlcZipArchive, New-TlcSessionArchive, New-TlcFileManifest, Assert-TlcBundleScope, New-TlcBundle, Test-TlcBundleIntegrity
