#Requires -Version 5.1
# Legacy import name; implementation lives in KoreanRules.psm1.
Import-Module (Join-Path $PSScriptRoot 'KoreanRules.psm1') -Force -ErrorAction Stop
Export-ModuleMember -Function *
