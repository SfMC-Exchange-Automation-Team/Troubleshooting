@{
    # Static-analysis gate for Tests\ - the Pester suites, not the shipped product and not the
    # interactive tools.
    #
    # A third settings file rather than reusing the Tools one, because test code legitimately
    # does things neither of the others may: it reaches into scopes to observe them, executes
    # generated strings to prove they run, and builds fixtures that exist only to be wrong.
    # Folding those allowances into the Tools rule set would weaken the gate on scripts that
    # actually ship alongside the toolbox.
    #
    # Tests\ was scanned by nothing until 2026-09-15. It held 46 findings, 11 of them real -
    # including two assignments to automatic variables ($input, $event), five empty catch
    # blocks and two computed-then-abandoned variables that misdescribed what their test
    # actually measured. See findings.md, 196 and 203: a folder nobody lints is
    # indistinguishable from a folder with nothing wrong in it.
    ExcludeRules = @(
        # Same reasons as the product and tools gates, kept in step with both deliberately.
        'PSUseOutputTypeCorrectly'
        'PSProvideCommentHelp'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseUsingScopeModifierInNewRunspaces'
        'PSReviewUnusedParameter'

        # Console output from a test harness is for the person watching it, same as Tools\.
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingPositionalParameters'

        # Tests\ only, and correct here rather than deferred.
        #
        # $global: is forced by Pester's scoping, not chosen. A mock body does not see the
        # $script: scope of the file that defined it, so a virtual clock or a recorded call
        # list shared between a mock and its assertions has nowhere else to live.
        # Tlc.Capture.Tests.ps1 carries all 35 instances and documents this at its first use.
        'PSAvoidGlobalVars'

        # A test that asserts on a value it deliberately does not consume is normal: the
        # assertion is the consumption. Flagging it produced only false positives once the
        # two genuinely vestigial assignments were removed.
        'PSUseDeclaredVarsMoreThanAssignments'
    )

    Rules = @{
        PSAvoidUsingCmdletAliases = @{
            Whitelist = @()
        }
    }
}
