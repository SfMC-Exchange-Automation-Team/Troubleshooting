@{
    # Baseline static-analysis gate for TLC Toolbox code.
    #
    # Adopted from the EPO Toolbox gate, since the two are siblings and a shared
    # standard is worth more than a bespoke one. Rules are deferred with a tracked
    # reason rather than permanently disabled. Do not add to this list without one.
    ExcludeRules = @(
        # Deferred: OutputType attributes add no value until the stage contract stabilises.
        'PSUseOutputTypeCorrectly'

        # Deferred: comment-based help exists on the exported surface but not yet on
        # every internal helper.
        'PSProvideCommentHelp'

        # Evaluated and deliberately left off, matching the EPO decision and for the
        # same reason: the rule keys off the verb alone, and this codebase uses
        # New-/Start-/Stop- for things that change nothing outside the process -
        # object constructors (New-TlcScopeRecord, New-TlcConsentRecord), a manifest
        # builder (New-TlcFileManifest) and the tool log lifecycle (Start-TlcToolLog).
        # New- is the approved verb for a constructor; renaming to satisfy the rule
        # would make the code worse.
        #
        # The functions that genuinely reach a durable write outside the run folder
        # already declare SupportsShouldProcess: New-TlcBundle and
        # Invoke-TlcRoomsLogCollection, which is the one that touches a remote device.
        'PSUseShouldProcessForStateChangingFunctions'

        # False positives: Start-Process and the child-process launch in the UI pass
        # state explicitly through -ArgumentList, which is correct for Windows
        # PowerShell 5.1.
        'PSUseUsingScopeModifierInNewRunspaces'

        # Deferred: several parameters are part of the stage contract and are
        # intentionally accepted-but-unused by stages that do not need them yet.
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSAvoidUsingCmdletAliases = @{
            Whitelist = @()
        }
    }
}
