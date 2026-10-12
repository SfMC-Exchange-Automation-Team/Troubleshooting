<#
.SYNOPSIS
Builds a distributable zip of the TLC Toolbox from the manifest's FileList.

.DESCRIPTION
The toolbox needs no installer. It has no external module dependencies, requires only the Windows
PowerShell 5.1 that ships with Windows, and writes nothing to its own folder - case history and the
dark theme go to %LOCALAPPDATA% - so it runs from a read-only share as happily as from a local copy.
Sharing it is therefore a copy, not an install.

What that still needs getting right is which files, and Tlc.psd1's FileList already answers that.
This reads it rather than restating it, so the package cannot drift from the manifest the way a
hand-maintained copy list always eventually does. Tlc.FileList.Tests.ps1 guards the manifest itself
in both directions; this guards the step from manifest to zip.

Three things it does that zipping the folder by hand does not.

The gate runs first. A package is the one artefact nobody re-tests before sending, so shipping a
broken build is both easy and expensive. Use -SkipGate when iterating on the packaging itself.

A README.txt is generated, and its Unblock section appears only while the toolbox is unsigned.
Windows attaches a Mark of the Web to anything arriving by email, Teams or download, and under the
default RemoteSigned policy that is a hard block - measured, not assumed: an unsigned copy carrying
ZoneId=3 fails with "AuthorizationManager check failed" unless -ExecutionPolicy Bypass is used, which
is exactly what the .cmd launchers do. Unblocking the zip once clears every file extracted from it.
Once Tools\Set-TlcSignature.ps1 has been run with a real certificate, that instruction is wrong and
this stops emitting it.

The zip is read back and its entries compared with what was staged. Compress-Archive reports success
for archives it has silently truncated when a source file is locked, and a package missing a module
opens a window with no scenarios rather than failing - the quiet kind of broken.

.PARAMETER OutputPath
Where to write the zip. Defaults to TLC-Toolbox-<version>.zip beside the toolbox folder, deliberately
outside it so the artefact can never be picked up as an input by the next run or by the file-list test.

.PARAMETER IncludeDocs
Also package docs\. Off by default: FileList is the shipped set, and a customer double-clicking
Collect-TeamsLogs.cmd wants the README, not the findings log. Worth turning on when handing the
toolbox to another engineer.

.PARAMETER SkipGate
Do not run Invoke-TlcBuild.ps1 first. For iterating on packaging only.

.PARAMETER Force
Overwrite an existing zip at OutputPath.

.EXAMPLE
.\Tools\New-TlcPackage.ps1

.EXAMPLE
.\Tools\New-TlcPackage.ps1 -IncludeDocs -OutputPath C:\Temp\TLC.zip
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $OutputPath,
    [switch] $IncludeDocs,
    [switch] $SkipGate,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolboxRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $toolboxRoot 'Tlc.psd1'

function Write-Step {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Message)
    Write-Information $Message -InformationAction Continue
}

function Test-TlcToolboxSigned {
    <#
        Whether the shipped scripts carry a valid signature, which decides if the README
        needs to talk about Unblock at all.

        The same four folders Invoke-TlcBuild.ps1 and Set-TlcSignature.ps1 report on. .cmd
        files are absent because batch files cannot be Authenticode signed.
    #>
    param([Parameter(Mandatory)] [string] $Root)

    $signable = @(
        foreach ($folder in @($Root, (Join-Path $Root 'Modules'), (Join-Path $Root 'Config'), (Join-Path $Root 'Data'))) {
            Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
                Where-Object { @('.ps1', '.psd1', '.psm1') -contains $_.Extension }
        }
    )
    if ($signable.Count -eq 0) { return $false }

    $unsigned = @($signable | Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -ne 'Valid' })
    return ($unsigned.Count -eq 0)
}

function New-TlcReadmeText {
    param(
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [bool] $Signed
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("TLC Toolbox $Version")
    $lines.Add('Teams Log Collection Toolbox')
    $lines.Add('')
    $lines.Add('WHAT THIS IS')
    $lines.Add('    Collects Microsoft Teams logs for a specific window of time, following the')
    $lines.Add('    published Log Collection Guidelines. Teams keeps its logs on disk, so an issue')
    $lines.Add('    that has already cleared can still be collected after the fact.')
    $lines.Add('')

    if (-not $Signed) {
        # Deliberately first, and deliberately before "extract". Unblocking the zip clears
        # every file inside it; unblocking after extraction means doing it file by file.
        $lines.Add('BEFORE YOU EXTRACT  -  please do this first')
        $lines.Add('    Right-click this .zip, choose Properties, tick Unblock, then OK.')
        $lines.Add('')
        $lines.Add('    Windows marks anything that arrives by email, Teams or download. Unblocking')
        $lines.Add('    the .zip once clears every file inside it. Without it Windows blocks the')
        $lines.Add('    scripts, because this build is not code signed.')
        $lines.Add('')
    }

    $lines.Add('TO RUN')
    $lines.Add('    Extract the whole folder and keep it together, then double-click:')
    $lines.Add('')
    $lines.Add('        Start-TlcToolbox.cmd     the guided window - start here')
    $lines.Add('        Collect-TeamsLogs.cmd    collect straight away, no window')
    $lines.Add('')
    $lines.Add('    To open it from the Start menu next time, with its own icon: Settings (the gear,')
    $lines.Add('    bottom left), then Add to Start menu. The entry opens the folder it was added')
    $lines.Add('    from, so add it once the toolbox is extracted where it will stay. It can be')
    $lines.Add('    pinned to the taskbar from the Start menu.')
    $lines.Add('')
    $lines.Add('REQUIREMENTS')
    $lines.Add('    Windows PowerShell 5.1, included with Windows 10 and 11. Nothing to install,')
    $lines.Add('    no admin rights needed, and nothing is written into this folder - so it can be')
    $lines.Add('    run from a read-only share.')
    $lines.Add('')
    $lines.Add('WHERE THINGS GO')
    $lines.Add('    Collected evidence   %SystemDrive%\TLC-Toolbox\Runs   (the window can change this)')
    $lines.Add('    Your own settings    %LOCALAPPDATA%\TLC-Toolbox')
    $lines.Add('')
    $lines.Add('    Remembered case numbers are stored per user under %LOCALAPPDATA%. The wizard''s')
    $lines.Add('    Forget button clears them. Accounts you declare from the Signed in tile are saved')
    $lines.Add('    there too, in TeamsLogCollection.local.psd1 - never in this folder.')
    $lines.Add('')
    $lines.Add('BEFORE SHARING WHAT IT COLLECTS')
    $lines.Add('    Use Package in the window. It runs a privacy check over the evidence and seals')
    $lines.Add('    the bundle with a hash, so both sides can prove later what was handed over.')

    return ($lines -join "`r`n") + "`r`n"
}

# --- What ships -------------------------------------------------------------------------

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
$version = [string]$manifest.ModuleVersion
$declared = @($manifest.FileList)

if ($declared.Count -eq 0) {
    throw "Tlc.psd1 declares no FileList, so there is nothing to package. This should have been caught by Tlc.FileList.Tests.ps1."
}

$missing = @($declared | Where-Object { -not (Test-Path -LiteralPath (Join-Path $toolboxRoot $_)) })
if ($missing.Count -gt 0) {
    throw "The manifest names $($missing.Count) file(s) that do not exist, so the package would be incomplete: $($missing -join ', ')"
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $toolboxRoot) "TLC-Toolbox-$version.zip"
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

# Containment has to respect the directory boundary. A bare StartsWith compares the
# sibling FILE name against the folder name, and the default output path is
# <parent>\TLC-Toolbox-<version>.zip beside a folder called <parent>\TLC-Toolbox - so
# "TLC-Toolbox-0.1.0.zip" starts with "TLC-Toolbox" and the script rejected its own
# default every time. Appending the separator asks the question actually meant: is this
# path INSIDE that directory.
$toolboxRootWithSeparator = $toolboxRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
    [System.IO.Path]::DirectorySeparatorChar
if ($OutputPath.StartsWith($toolboxRootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputPath is inside the toolbox folder ($OutputPath). Write it elsewhere, or the next package would treat this one as an input."
}

if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) {
    throw "$OutputPath already exists. Use -Force to replace it."
}

Write-Step ''
Write-Step "TLC Toolbox $version"
Write-Step "  Declared in the manifest : $($declared.Count) file(s)"

# --- Gate -------------------------------------------------------------------------------

if ($SkipGate) {
    Write-Warning 'The build gate was skipped. This package has not been tested.'
} else {
    Write-Step '  Running the build gate...'
    # A child process, because Invoke-TlcBuild.ps1 ends in `exit`. -NonInteractive so a test that
    # prompts fails instead of waiting on a console nobody is watching (finding 331).
    & powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $toolboxRoot 'Invoke-TlcBuild.ps1') |
        Out-String -Stream | Where-Object { $_ -match 'Tests Passed|Analysis findings|Signing:' } | ForEach-Object { Write-Step "    $_" }

    if ($LASTEXITCODE -ne 0) {
        throw "The build gate failed (exit $LASTEXITCODE). Fix it before packaging, or use -SkipGate if you are iterating on packaging itself."
    }
}

$signed = Test-TlcToolboxSigned -Root $toolboxRoot

# --- Stage ------------------------------------------------------------------------------

if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Create package')) { return }

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("TLC-Toolbox-$version-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $staging

try {
    foreach ($relative in $declared) {
        $destination = Join-Path $staging $relative
        $folder = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
        Copy-Item -LiteralPath (Join-Path $toolboxRoot $relative) -Destination $destination -Force
    }

    if ($IncludeDocs) {
        Copy-Item -LiteralPath (Join-Path $toolboxRoot 'docs') -Destination (Join-Path $staging 'docs') -Recurse -Force
        Write-Step "  Documentation            : included"
    }

    $readmePath = Join-Path $staging 'README.txt'
    Set-Content -LiteralPath $readmePath -Value (New-TlcReadmeText -Version $version -Signed $signed) -Encoding ASCII -NoNewline

    $staged = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
    Write-Step "  Staged                   : $($staged.Count) file(s)"

    # --- Zip ----------------------------------------------------------------------------

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -CompressionLevel Optimal

    # --- Verify -------------------------------------------------------------------------
    #
    # By content, not only by name. A truncated entry keeps its name, so a names-only check
    # passed the very archive Compress-Archive is known to produce when a source is locked
    # (review 2026-09-30, finding 331). Each staged file's length and SHA256 are compared with
    # the entry read back out of the zip.

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $differ = [System.Collections.Generic.List[string]]::new()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $archive = [System.IO.Compression.ZipFile]::OpenRead($OutputPath)
    try {
        $entryMap = @{}
        foreach ($zipEntry in $archive.Entries) {
            if ($zipEntry.Name) { $entryMap[($zipEntry.FullName -replace '/', '\')] = $zipEntry }
        }
        $entries = @($entryMap.Keys)
        foreach ($file in $staged) {
            $relative = $file.FullName.Substring($staging.Length + 1)
            $zipEntry = $entryMap[$relative]
            if (-not $zipEntry) { continue }
            if ($zipEntry.Length -ne $file.Length) {
                $differ.Add("$relative ($($zipEntry.Length) bytes in the archive, $($file.Length) staged)")
                continue
            }
            $stream = $zipEntry.Open()
            try { $inArchive = [System.BitConverter]::ToString($sha.ComputeHash($stream)) } finally { $stream.Dispose() }
            $onDisk = [System.BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($file.FullName)))
            if ($inArchive -ne $onDisk) { $differ.Add("$relative (content differs)") }
        }
    } finally {
        $archive.Dispose()
        $sha.Dispose()
    }

    $expected = @($staged | ForEach-Object { $_.FullName.Substring($staging.Length + 1) })
    $absent = @($expected | Where-Object { $entries -notcontains $_ })
    if ($absent.Count -gt 0) {
        throw "The archive is missing $($absent.Count) staged file(s), so it is incomplete: $($absent -join ', ')"
    }
    if ($differ.Count -gt 0) {
        throw "The archive holds $($differ.Count) file(s) that differ from what was staged: $($differ -join ', ')"
    }

    foreach ($required in 'Tlc.psd1', 'Start-TlcToolbox.cmd', 'Collect-TeamsLogs.cmd', 'README.txt') {
        if ($entries -notcontains $required) { throw "The archive does not contain $required." }
    }

    $size = (Get-Item -LiteralPath $OutputPath).Length
    Write-Step "  Verified in the archive  : $($entries.Count) file(s)"
    Write-Step ''
    Write-Step ("Package: {0} ({1:N0} KB)" -f $OutputPath, ($size / 1KB))

    if (-not $signed) {
        Write-Step ''
        Write-Warning 'This build is unsigned, so the recipient must right-click the .zip, choose Properties and tick Unblock BEFORE extracting. README.txt in the package says so. Sign with Tools\Set-TlcSignature.ps1 to remove that step.'
    }

    return Get-Item -LiteralPath $OutputPath
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
