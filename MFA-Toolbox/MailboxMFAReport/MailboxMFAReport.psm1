#Requires -Version 5.1

<#
Module loader.

StrictMode is enabled deliberately. Exchange Online object shapes vary by cmdlet
version and tenant, and v0.10 dereferenced properties on objects that were
frequently $null (for example $folderEvidence.Summary when -IncludeFolderEvidence
was not supplied). Those reads returned $null silently, which is exactly how the
"conclusion drawn from data that was never collected" class of defect survived.

Under StrictMode they would have thrown, so every optional read now goes through
Get-MFAReportPropertyValue instead.
#>

Set-StrictMode -Version 3.0

$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$publicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to import $($file.FullName): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @($publicFiles | ForEach-Object { $_.BaseName })
