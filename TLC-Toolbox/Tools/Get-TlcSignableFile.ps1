#requires -Version 5.1
<#
    .SYNOPSIS
        The set of shipped files that can carry an Authenticode signature.

    .DESCRIPTION
        This lives in its own file because two callers need the same answer: Invoke-TlcBuild.ps1,
        which reports how much of the product is unsigned, and Tools\Set-TlcSignature.ps1, which
        does the signing. They previously each carried their own copy of a folder scan, which is
        three definitions of "shipped" counting the manifest - and definitions that are written
        down more than once drift.

        The set is read from the manifest's FileList. The manifest is already the single
        declaration of what ships, and Tlc.FileList.Tests.ps1 guards it against disk in both
        directions, so a file cannot be added to Modules\ and quietly miss being signed.

        Scanning folders was wrong in the other direction: it walked the toolbox root, so it
        adopted Invoke-TlcBuild.ps1 and PSScriptAnalyzerSettings.psd1 - both of which the
        manifest guard names as explicitly not shipped, with reasons - and it picked up any
        scratch .ps1 left in the root. A signable count that moves because someone deleted a
        throwaway script is a count that was never measuring the product.

        The .cmd launchers are absent because batch files cannot be Authenticode signed at all.
        That is worth stating rather than leaving as an apparent oversight, because
        Collect-TeamsLogs.cmd is the file the customer double-clicks - the signature that matters
        for it is the one on the .ps1 it invokes.

        Extensions are filtered explicitly rather than with -Include: Get-ChildItem silently
        ignores -Include when it is paired with -LiteralPath on Windows PowerShell 5.1 and honours
        it on PowerShell 7. A tool that decides what gets signed must not select different files
        depending on which host ran it.

    .PARAMETER Root
        The toolbox root - the folder holding Tlc.psd1.
#>
[CmdletBinding()]
param()

function Get-TlcSignableFile {
    param([Parameter(Mandatory)] [string] $Root)

    $wanted = @('.ps1', '.psd1', '.psm1')
    $manifestPath = Join-Path $Root 'Tlc.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "No manifest at $manifestPath, so there is nothing that states what ships. The signable set cannot be determined without it."
    }

    $declared = @((Import-PowerShellDataFile -LiteralPath $manifestPath).FileList)

    $files = foreach ($relative in $declared) {
        if ($wanted -notcontains [System.IO.Path]::GetExtension($relative)) { continue }
        Get-Item -LiteralPath (Join-Path $Root $relative) -ErrorAction SilentlyContinue
    }

    return @(@($files) | Sort-Object FullName)
}
