#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
Verification reads from inside the sealed archive, not from the run folder, and the distinction is
not cosmetic. The run folder stays live after packaging - Blockers.csv and Events.jsonl are
appended to and Run.json is rewritten as the run finishes - so an earlier build that checked the
folder reported three mismatches immediately after a clean package. Permanent false positives are
how real tampering gets ignored.

The separator case is the one that breaks the workflow this toolbox exists for. Compress-Archive
writes backslash separators on Windows PowerShell 5.1 and forward slashes on PowerShell 7, and the
customer collects on 5.1 while the engineer verifies on 7.
#>

BeforeAll {
    $script:ToolboxRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Logging.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Package.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Builds a bundle whose manifest uses the separator style of the host that wrote it,
    # plus one that uses the other style, so both can be verified from either host.
    $script:NewBundle = {
        param([string] $Name, [string] $ManifestPath)

        $staging = Join-Path $TestDrive "$Name-staging"
        $sub = Join-Path $staging 'Sub'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'file.txt') -Value 'content' -Encoding utf8

        $hash = (Get-FileHash -LiteralPath (Join-Path $sub 'file.txt') -Algorithm SHA256).Hash
        $manifest = @([pscustomobject]@{ Path = $ManifestPath; SizeBytes = 7; Sha256 = $hash })
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $staging 'Manifest.json') -Encoding utf8

        $zip = Join-Path $TestDrive "$Name.zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
        return $zip
    }
}

Describe 'Test-TlcBundleIntegrity' {

    It 'verifies a bundle whose manifest uses backslash separators' {
        # The shape Windows PowerShell 5.1 produces, which is what a customer runs.
        $zip = & $script:NewBundle 'backslash' 'Sub\file.txt'
        (Test-TlcBundleIntegrity -BundlePath $zip).Valid | Should -BeTrue
    }

    It 'verifies a bundle whose manifest uses forward slash separators' {
        $zip = & $script:NewBundle 'forwardslash' 'Sub/file.txt'
        (Test-TlcBundleIntegrity -BundlePath $zip).Valid | Should -BeTrue
    }

    It 'accepts a bare-array manifest as written by the customer collector' {
        # The toolbox writes a rich object with a Files collection; Invoke-TlcQuickCollect
        # writes a bare array. An engineer should not need to know which produced a bundle.
        $zip = & $script:NewBundle 'bare-array' 'Sub\file.txt'
        (Test-TlcBundleIntegrity -BundlePath $zip).FileCount | Should -Be 1
    }

    It 'detects a file altered inside the archive' {
        $zip = & $script:NewBundle 'tamper' 'Sub\file.txt'
        $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Update')
        try {
            $entry = $archive.Entries | Where-Object { $_.FullName -like '*file.txt' } | Select-Object -First 1
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            $writer.BaseStream.SetLength(0)
            $writer.Write('forged')
            $writer.Dispose()
        } finally {
            $archive.Dispose()
        }

        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeFalse
        $result.Mismatched | Should -Not -BeNullOrEmpty
    }

    It 'reports a file named in the manifest but absent from the archive' {
        $zip = & $script:NewBundle 'missing' 'Sub\not-present.txt'
        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeFalse
        $result.Missing | Should -Not -BeNullOrEmpty
    }

    It 'throws when the archive carries no manifest' {
        $staging = Join-Path $TestDrive 'nomanifest-staging'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staging 'a.txt') -Value 'x' -Encoding utf8
        $zip = Join-Path $TestDrive 'nomanifest.zip'
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip

        { Test-TlcBundleIntegrity -BundlePath $zip } | Should -Throw
    }
}

Describe 'New-TlcFileManifest' {

    It 'hashes every file and can exclude the ones that keep changing' {
        $folder = Join-Path $TestDrive 'manifest-src'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'keep.txt') -Value 'a' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $folder 'ToolLog.txt') -Value 'b' -Encoding utf8

        $manifest = New-TlcFileManifest -RunPath $folder -ExcludeName @('ToolLog.txt')
        @($manifest).Count | Should -Be 1
        $manifest[0].Path | Should -Be 'keep.txt'
        $manifest[0].Sha256 | Should -Not -BeNullOrEmpty
    }

    It 'excludes only the run''s own files, not collected evidence that shares their name' {
        # Review 2026-09-30, finding 331. The exclusion matched the base name anywhere in the
        # run, so a collected file called manifest.json - Teams and WebView2 folders carry
        # them - went into the zip unhashed, where verification then called the sealed bundle
        # invalid for carrying a file the manifest did not account for.
        $folder = Join-Path $TestDrive 'manifest-names'
        $nested = Join-Path $folder 'Endpoints\PC\SupportFiles\Teams'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'Manifest.json') -Value '{}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $nested 'manifest.json') -Value '{"name":"collected"}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $nested 'Bundle.json') -Value '{"name":"collected"}' -Encoding utf8

        $paths = @(New-TlcFileManifest -RunPath $folder -ExcludeName @('Manifest.json', 'Bundle.json') | ForEach-Object { $_.Path })
        $paths | Should -Contain 'Endpoints\PC\SupportFiles\Teams\manifest.json'
        $paths | Should -Contain 'Endpoints\PC\SupportFiles\Teams\Bundle.json'
        $paths | Should -Not -Contain 'Manifest.json'
    }
}


Describe 'New-TlcZipArchive' {
    <#
    Compress-Archive opens each file without sharing. One file held open by antivirus, a backup
    agent or OneDrive failed the whole archive - after collection had already succeeded, on logs
    that cannot be gathered again once they have rolled. It was worst in the customer collector's
    failure path, where the bundle is the only record of why the run went wrong.

    Verified directly: with a file held open, Compress-Archive and ZipFile::CreateFromDirectory
    both throw and this does not.
    #>

    BeforeAll {
        $script:MakeTree = {
            param([string] $Name)
            $dir = Join-Path $TestDrive $Name
            $sub = Join-Path $dir 'Sub'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'top.txt') -Value 'top' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $sub 'nested.txt') -Value 'nested' -Encoding utf8
            return $dir
        }
    }

    It 'writes every file, including nested ones' {
        $dir = & $script:MakeTree 'zip-basic'
        $zip = Join-Path $TestDrive 'zip-basic.zip'

        $count = New-TlcZipArchive -SourcePath $dir -DestinationPath $zip
        $count | Should -Be 2

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
        $names | Should -Contain 'top.txt'
        $names | Should -Contain 'Sub/nested.txt'
    }

    It 'always writes forward slashes, on either PowerShell version' {
        # Compress-Archive writes backslashes on 5.1 and forward slashes on 7. The customer
        # collects on 5.1 and the engineer verifies on 7, so the separator is normalised at the
        # point the entry is written rather than papered over afterwards.
        $dir = & $script:MakeTree 'zip-sep'
        $zip = Join-Path $TestDrive 'zip-sep.zip'
        New-TlcZipArchive -SourcePath $dir -DestinationPath $zip | Out-Null

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName }) } finally { $archive.Dispose() }
        ($names -join '|') | Should -Not -BeLike '*\*'
    }

    It 'archives a file another process is holding open' {
        $dir = & $script:MakeTree 'zip-locked'
        $held = Join-Path $dir 'top.txt'
        $zip = Join-Path $TestDrive 'zip-locked.zip'

        $holder = [System.IO.FileStream]::new($held, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            { New-TlcZipArchive -SourcePath $dir -DestinationPath $zip } | Should -Not -Throw

            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
            try { @($archive.Entries).Count | Should -Be 2 } finally { $archive.Dispose() }
        } finally {
            $holder.Dispose()
        }
    }

    It 'produces a bundle that verifies against its own manifest' {
        # The round trip is the point: an archive nothing can read back is not evidence.
        $dir = & $script:MakeTree 'zip-verify'
        $files = New-TlcFileManifest -RunPath $dir
        $files | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $dir 'Manifest.json') -Encoding utf8

        $zip = Join-Path $TestDrive 'zip-verify.zip'
        New-TlcZipArchive -SourcePath $dir -DestinationPath $zip | Out-Null

        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeTrue
        $result.Missing | Should -BeNullOrEmpty
        $result.Mismatched | Should -BeNullOrEmpty
    }

    It 'clamps a pre-1980 timestamp instead of failing the bundle' {
        # The zip format cannot store a date before 1980 and the setter throws rather than
        # clamping, so one odd system timestamp would otherwise lose the whole collection.
        $dir = & $script:MakeTree 'zip-olddate'
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $dir 'top.txt'), [datetime]'1601-01-01T00:00:00Z')

        $zip = Join-Path $TestDrive 'zip-olddate.zip'
        { New-TlcZipArchive -SourcePath $dir -DestinationPath $zip } | Should -Not -Throw
    }
}


Describe 'Long support paths survive packaging' {
    It 'hashes, archives and verifies real files beyond the Windows PowerShell legacy path limit' {
        $source = Join-Path $TestDrive 'long-package'
        $null = New-Item -ItemType Directory -Path $source
        $nested = Join-Path $source (('x' * 125) + '\' + ('y' * 125))
        $file = Join-Path $nested (('z' * 70) + '.log')
        $native = '\\?\' + $file
        try {
            $null = [IO.Directory]::CreateDirectory('\\?\' + $nested)
            [IO.File]::WriteAllText($native, 'preserved long-path evidence')
            $nested.Length | Should -BeGreaterThan 260
            $file.Length | Should -BeGreaterThan 300
            $manifest = @(New-TlcFileManifest -RunPath $source)
            $manifest.Count | Should -Be 1
            $manifest[0].SizeBytes | Should -Be 28
            $manifest[0].Sha256 | Should -Be (Get-TlcFileHash -Path $file)
            $manifest[0].Path | Should -Not -Match '\\\\\?\\'
            ConvertTo-Json -InputObject $manifest -Depth 5 |
                Set-Content -LiteralPath (Join-Path $source 'Manifest.json') -Encoding utf8
            $zip = Join-Path $TestDrive 'long-package.zip'
            (New-TlcZipArchive -SourcePath $source -DestinationPath $zip) | Should -Be 2
            $verified = Test-TlcBundleIntegrity -BundlePath $zip
            $verified.Valid | Should -BeTrue
            $verified.FileCount | Should -Be 1
            $archive = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $entry = @($archive.Entries | Where-Object { $_.FullName -ne 'Manifest.json' })[0]
                $entry.FullName | Should -Not -Match '\\\\\?\\'
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $reader.ReadToEnd() | Should -BeExactly 'preserved long-path evidence' }
                finally { $reader.Dispose() }
            } finally { $archive.Dispose() }
            $carrier = New-TlcSessionArchive -RunPath @($source) -DestinationPath (Join-Path $TestDrive 'long-carrier.zip') -IncludeRunFolder
            $carrier.FileCount | Should -Be 2
        } finally {
            if ([IO.Directory]::Exists('\\?\' + $source)) { [IO.Directory]::Delete('\\?\' + $source, $true) }
        }
    }
}

Describe 'What tampering actually gets caught' {
    <#
    The bundle carries a manifest and the customer README calls it "a checksum for every file, so
    nothing can change unnoticed". That claim was stronger than the code.

    Verification walked the manifest's own entries and asked "is each still present and unchanged".
    That answers half the question. It said nothing about anything ADDED afterwards, and the
    customer README - the file stating which time window the evidence covers - was written after
    the manifest was computed and so was never hashed at all.

    Both were demonstrated on a real bundle: rewriting the window with a false one, and planting
    ClientLogs/PLANTED-evidence.log, each returned Valid=True. For evidence attached to a support
    case that is the wrong answer.
    #>

    BeforeAll {
        $script:SealBundle = {
            param([string] $Name)

            $staging = Join-Path $TestDrive "$Name-staging"
            New-Item -ItemType Directory -Path (Join-Path $staging 'ClientLogs') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $staging 'ClientLogs\collected.log') -Value 'real evidence' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $staging 'READ-ME-FIRST.txt') -Value 'Problem time window: 2026-08-27 08:00 to 09:00' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $staging 'ToolLog.txt') -Value 'tool log' -Encoding utf8

            # The customer collector's shape: bare array, ToolLog excluded, README included.
            $manifest = foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
                if ($file.Name -eq 'ToolLog.txt') { continue }
                [pscustomobject][ordered]@{
                    Path      = $file.FullName.Substring($staging.Length).TrimStart('\')
                    SizeBytes = $file.Length
                    Sha256    = Get-TlcFileHash -Path $file.FullName
                }
            }
            @($manifest) | ConvertTo-Json -Depth 5 |
                Set-Content -LiteralPath (Join-Path $staging 'Manifest.json') -Encoding utf8

            $zip = Join-Path $TestDrive "$Name.zip"
            if (Test-Path $zip) { Remove-Item $zip -Force }
            New-TlcZipArchive -SourcePath $staging -DestinationPath $zip | Out-Null
            return $zip
        }

        $script:EditEntry = {
            param([string] $Zip, [string] $Entry, [string] $Content)
            $archive = [System.IO.Compression.ZipFile]::Open($Zip, 'Update')
            try {
                $target = $archive.Entries | Where-Object { $_.FullName -eq $Entry }
                $writer = [System.IO.StreamWriter]::new($target.Open())
                $writer.BaseStream.SetLength(0)
                $writer.Write($Content)
                $writer.Dispose()
            } finally { $archive.Dispose() }
        }
    }

    It 'passes an untouched bundle' {
        # First, so none of the cases below can pass by being broken in general.
        (Test-TlcBundleIntegrity -BundlePath (& $script:SealBundle 'clean')).Valid | Should -BeTrue
    }

    It 'catches a rewritten collection window in the README' {
        # The README states the window the evidence covers. If it can be changed silently, the
        # bundle can be made to describe a period it does not contain.
        $zip = & $script:SealBundle 'readme'
        & $script:EditEntry $zip 'READ-ME-FIRST.txt' 'Problem time window: 1999-01-01 00:00 to 1999-01-01 23:59'

        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeFalse
        $result.Mismatched | Should -Contain 'READ-ME-FIRST.txt'
    }

    It 'catches a file planted into the bundle' {
        $zip = & $script:SealBundle 'planted'
        $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Update')
        try {
            $writer = [System.IO.StreamWriter]::new($archive.CreateEntry('ClientLogs/PLANTED-evidence.log').Open())
            $writer.Write('this was never collected')
            $writer.Dispose()
        } finally { $archive.Dispose() }

        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeFalse
        $result.Unexpected | Should -Contain 'ClientLogs/PLANTED-evidence.log'
    }

    It 'catches an altered collected log' {
        $zip = & $script:SealBundle 'altered'
        & $script:EditEntry $zip 'ClientLogs/collected.log' 'redacted'

        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeFalse
        $result.Mismatched | Should -Contain 'ClientLogs\collected.log'
    }

    It 'catches a removed collected log' {
        $zip = & $script:SealBundle 'removed'
        $archive = [System.IO.Compression.ZipFile]::Open($zip, 'Update')
        try { ($archive.Entries | Where-Object { $_.FullName -eq 'ClientLogs/collected.log' }).Delete() }
        finally { $archive.Dispose() }

        $result = Test-TlcBundleIntegrity -BundlePath $zip
        $result.Valid | Should -BeFalse
        $result.Missing | Should -Contain 'ClientLogs\collected.log'
    }

    It 'does not flag the two files that legitimately cannot be hashed' {
        # Manifest.json cannot contain its own hash, and ToolLog.txt keeps being written after the
        # manifest is computed. Both are expected absences, not unexplained ones - otherwise every
        # genuine bundle would fail and the check would be turned off.
        $result = Test-TlcBundleIntegrity -BundlePath (& $script:SealBundle 'expected')
        $result.Unexpected | Should -BeNullOrEmpty
    }
}

Describe 'Assert-TlcBundleScope' {
    <#
        The gate reads one endpoint's folder; the bundle seals the whole run. Those were the
        same files only while a run had one endpoint. Fleet mode makes them differ, and
        nothing in the gate would notice - it would return Success having inspected one
        machine while the archive carried the rest.

        These pin the boundary rather than the happy path, because the happy path is what
        the code already did.
    #>

    It 'passes a single-endpoint run, which is every scenario that ships today' {
        $run = Join-Path $TestDrive 'single'
        $path = Join-Path (Join-Path $run 'Endpoints') 'DESK-A'
        New-Item -ItemType Directory -Path $path -Force | Out-Null

        $uninspected = Assert-TlcBundleScope -RunPath $run -InspectedEndpoints @('DESK-A')
        $uninspected | Should -BeNullOrEmpty
    }

    It 'names an endpoint whose evidence would ship without ever being inspected' {
        # The disclosure case. Two machines collected, one gated.
        $run = Join-Path $TestDrive 'fleet'
        foreach ($endpoint in 'DESK-A', 'DESK-B') {
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $run 'Endpoints') $endpoint) -Force | Out-Null
        }

        $uninspected = @(Assert-TlcBundleScope -RunPath $run -InspectedEndpoints @('DESK-A'))
        $uninspected | Should -Be @('DESK-B')
    }

    It 'is satisfied once every endpoint has been inspected' {
        # Proves the guard does not simply forbid multi-endpoint runs. Gate them all and it
        # passes, which is what fleet mode will do.
        $run = Join-Path $TestDrive 'fleet-gated'
        foreach ($endpoint in 'DESK-A', 'DESK-B') {
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $run 'Endpoints') $endpoint) -Force | Out-Null
        }

        $uninspected = Assert-TlcBundleScope -RunPath $run -InspectedEndpoints @('DESK-A', 'DESK-B')
        $uninspected | Should -BeNullOrEmpty
    }

    It 'treats a run with no endpoint folders as nothing to check rather than a failure' {
        # -Stage Package before -Stage Collect. There is a blocker for that case already;
        # this must not pre-empt it with a confusing one about scope.
        $run = Join-Path $TestDrive 'empty'
        New-Item -ItemType Directory -Path $run -Force | Out-Null

        $uninspected = Assert-TlcBundleScope -RunPath $run -InspectedEndpoints @('DESK-A')
        $uninspected | Should -BeNullOrEmpty
    }
}

Describe 'New-TlcBundle refuses to seal what was never inspected' {
    <#
        Driven through Initialize-TlcRun rather than a hand-built run record, so the run
        structure, the blocker writer and the events log are the real ones. A hand-built
        hashtable would have passed while the actual caller was broken - the exact trap
        recorded in the findings.
    #>

    BeforeEach {
        $script:ScopeRunRoot = Join-Path $TestDrive "scope-$([guid]::NewGuid())"
        $null = Initialize-TlcRun -RunRoot $script:ScopeRunRoot -Scenario 'DesktopLaunchCrash' -CaseNumber 'T-SCOPE'
        $script:ScopeRun = Get-TlcRun

        # Two machines collected. Only the first will be declared inspected.
        foreach ($endpoint in 'DESK-A', 'DESK-B') {
            $path = Join-Path (Join-Path $script:ScopeRun.RunPath 'Endpoints') $endpoint
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $path 'evidence.txt') -Value "logs from $endpoint"
        }

        $script:ScopePrivacy = [ordered]@{
            Status = 'Success'; Blocked = $false; Reasons = @()
            InspectedEndpoints = @('DESK-A')
        }
    }

    It 'throws, naming the endpoint that was never inspected' {
        { New-TlcBundle -Run $script:ScopeRun -PrivacyResult $script:ScopePrivacy -Endpoint 'DESK-A' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*DESK-B*'
    }

    It 'leaves no archive behind when it refuses' {
        # A half-written bundle is worse than none, because it looks like evidence.
        try { New-TlcBundle -Run $script:ScopeRun -PrivacyResult $script:ScopePrivacy -Endpoint 'DESK-A' -Confirm:$false } catch { Write-Verbose "Packaging refused as expected: $($_.Exception.Message)" }

        $bundle = Join-Path (Split-Path -Parent $script:ScopeRun.RunPath) "TLC-$($script:ScopeRun.CorrelationId).zip"
        Test-Path -LiteralPath $bundle | Should -BeFalse
    }

    It 'records a Critical blocker rather than only throwing' {
        # The throw stops the operator; the blocker is what a reviewer reads afterwards.
        try { New-TlcBundle -Run $script:ScopeRun -PrivacyResult $script:ScopePrivacy -Endpoint 'DESK-A' -Confirm:$false } catch { Write-Verbose "Packaging refused as expected: $($_.Exception.Message)" }

        $blockers = Import-Csv -LiteralPath (Join-Path $script:ScopeRun.RunPath 'Blockers.csv')
        @($blockers | Where-Object { $_.Check -eq 'Package.Scope' }).Count |
            Should -BeGreaterThan 0
    }

    It 'seals normally once every endpoint has been inspected' {
        # The other direction: the guard must not simply forbid multi-endpoint runs.
        $script:ScopePrivacy.InspectedEndpoints = @('DESK-A', 'DESK-B')

        $bundle = New-TlcBundle -Run $script:ScopeRun -PrivacyResult $script:ScopePrivacy -Endpoint 'DESK-A' -Confirm:$false
        $bundle | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $bundle.BundlePath | Should -BeTrue
    }
}

Describe 'Per-endpoint gating excludes rather than refusing the whole run' {
    <#
        The policy: one machine failing the gate costs that machine, not the collection.
        Across a fleet an unrecognised account is close to certain, and refusing ten
        machines over one laptop is the pressure that gets the gate switched off.

        Driven through Initialize-TlcRun so the run structure and blocker writer are real.
    #>

    BeforeEach {
        $script:FleetRoot = Join-Path $TestDrive "fleet-$([guid]::NewGuid())"
        $null = Initialize-TlcRun -RunRoot $script:FleetRoot -Scenario 'DesktopLaunchCrash' -CaseNumber 'T-FLEET'
        $script:FleetRun = Get-TlcRun

        foreach ($endpoint in 'DESK-GOOD', 'DESK-BAD') {
            $path = Join-Path (Join-Path $script:FleetRun.RunPath 'Endpoints') $endpoint
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $path 'evidence.txt') -Value "logs from $endpoint"
        }

        $script:FleetResults = @(
            [ordered]@{ Endpoint = 'DESK-GOOD'; Blocked = $false; Reasons = @() }
            [ordered]@{ Endpoint = 'DESK-BAD'; Blocked = $true; Reasons = @('bearer token found in har.json') }
        )
    }

    It 'still produces a bundle when one endpoint is refused' {
        $bundle = New-TlcBundle -Run $script:FleetRun -EndpointResults $script:FleetResults `
                                -Endpoint 'DESK-GOOD' -Confirm:$false
        $bundle | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $bundle.BundlePath | Should -BeTrue
    }

    It 'keeps the refused endpoint out of the archive entirely' {
        # The assertion that matters. Everything else is bookkeeping; this is the
        # disclosure.
        $bundle = New-TlcBundle -Run $script:FleetRun -EndpointResults $script:FleetResults `
                                -Endpoint 'DESK-GOOD' -Confirm:$false

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($bundle.BundlePath)
        try {
            @($archive.Entries | Where-Object { $_.FullName -match 'DESK-BAD' }).Count |
                Should -Be 0 -Because 'the refused endpoint must not travel'
            @($archive.Entries | Where-Object { $_.FullName -match 'DESK-GOOD' }).Count |
                Should -BeGreaterThan 0 -Because 'the endpoint that passed still has to be in there'
        } finally {
            $archive.Dispose()
        }
    }

    It 'keeps the refused endpoint out of the manifest file list' {
        $null = New-TlcBundle -Run $script:FleetRun -EndpointResults $script:FleetResults `
                                -Endpoint 'DESK-GOOD' -Confirm:$false
        $manifest = Get-Content -LiteralPath (Join-Path $script:FleetRun.RunPath 'Manifest.json') -Raw | ConvertFrom-Json

        @($manifest.Files | Where-Object { $_.Path -match 'DESK-BAD' }).Count | Should -Be 0
    }

    It 'names the withheld endpoint and why, so the omission is auditable' {
        # A silently absent endpoint is indistinguishable from one never collected. The
        # exclusion has to be stated for the bundle to remain defensible.
        $null = New-TlcBundle -Run $script:FleetRun -EndpointResults $script:FleetResults `
                              -Endpoint 'DESK-GOOD' -Confirm:$false
        $manifest = Get-Content -LiteralPath (Join-Path $script:FleetRun.RunPath 'Manifest.json') -Raw | ConvertFrom-Json

        @($manifest.ExcludedEndpoints).Count | Should -Be 1
        $manifest.ExcludedEndpoints[0].Endpoint | Should -Be 'DESK-BAD'
        $manifest.ExcludedEndpoints[0].Reasons -join ' ' | Should -Match 'bearer token'
        $manifest.IncludedEndpoints | Should -Be @('DESK-GOOD')
    }

    It 'refuses outright when every endpoint is excluded' {
        # An empty bundle reporting success is worse than a refusal: it looks like a
        # completed collection.
        $allBad = @(
            [ordered]@{ Endpoint = 'DESK-GOOD'; Blocked = $true; Reasons = @('token') }
            [ordered]@{ Endpoint = 'DESK-BAD'; Blocked = $true; Reasons = @('token') }
        )

        { New-TlcBundle -Run $script:FleetRun -EndpointResults $allBad -Endpoint 'DESK-GOOD' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*every endpoint*'
    }

    It 'writes no archive when every endpoint is excluded' {
        $allBad = @(
            [ordered]@{ Endpoint = 'DESK-GOOD'; Blocked = $true; Reasons = @('token') }
            [ordered]@{ Endpoint = 'DESK-BAD'; Blocked = $true; Reasons = @('token') }
        )

        try { New-TlcBundle -Run $script:FleetRun -EndpointResults $allBad -Endpoint 'DESK-GOOD' -Confirm:$false } catch { Write-Verbose "Packaging refused as expected: $($_.Exception.Message)" }

        $bundle = Join-Path (Split-Path -Parent $script:FleetRun.RunPath) "TLC-$($script:FleetRun.CorrelationId).zip"
        Test-Path -LiteralPath $bundle | Should -BeFalse
    }
}
