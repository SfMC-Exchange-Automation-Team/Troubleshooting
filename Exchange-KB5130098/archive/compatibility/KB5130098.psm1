#Requires -Version 5.1
# Legacy import name; implementation lives in KoreanRules.psm1.
$packageRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $packageRoot 'KoreanRules.psm1') -PathType Leaf)) {
    $packageRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}
Import-Module (Join-Path $packageRoot 'KoreanRules.psm1') -Force -ErrorAction Stop
Export-ModuleMember -Function *
