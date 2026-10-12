@{
    # Static-analysis gate for Tools\ - the interactive diagnostic scripts, not the shipped product.
    #
    # A separate file rather than widening PSScriptAnalyzerSettings.psd1, because the two bodies of
    # code have genuinely different contracts and merging their rule sets would weaken the gate on
    # Modules\ to accommodate scripts that are not shipped.
    #
    # Tools\ was analysed by nothing at all until 2026-09-15. The gate scans the root *.ps1 files and
    # Modules\*.psm1 and stops there, so 67 findings had accumulated unseen - including six empty
    # catch blocks and a function shadowing the built-in Write-Log. See findings.md, 193: a folder
    # nobody lints is indistinguishable from a folder with nothing wrong in it.
    ExcludeRules = @(
        # Same reasons as the product gate. Kept in step with it deliberately: a rule deferred there
        # and enforced here would report the same construct as a defect in one folder and correct in
        # the other.
        'PSUseOutputTypeCorrectly'
        'PSProvideCommentHelp'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseUsingScopeModifierInNewRunspaces'
        'PSReviewUnusedParameter'

        # Tools\ only, and correct here rather than deferred.
        #
        # These scripts exist to print to a person watching. Write-Host is the right cmdlet for that:
        # their output is a console report, never an object for a caller to consume, and several
        # deliberately colour their verdicts. The product code has the opposite contract - it writes
        # evidence and streams - and PSAvoidUsingWriteHost stays enforced there.
        'PSAvoidUsingWriteHost'

        # Positional arguments to the scripts' own small local helpers. Defensible in a
        # single-file script where the helper is defined thirty lines above the call.
        'PSAvoidUsingPositionalParameters'
    )

    Rules = @{
        PSAvoidUsingCmdletAliases = @{
            Whitelist = @()
        }
    }
}
