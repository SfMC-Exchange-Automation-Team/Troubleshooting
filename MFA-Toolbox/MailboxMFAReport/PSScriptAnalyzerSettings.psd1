# PSScriptAnalyzer settings for MailboxMFAReport.
#
# Run with:
#   Invoke-ScriptAnalyzer -Path .\MailboxMFAReport -Recurse -Settings .\MailboxMFAReport\PSScriptAnalyzerSettings.psd1

@{
    ExcludeRules = @(
        # These fire on PRIVATE helpers whose plural nouns are accurate:
        # Get-MFAReportDiagnosticSignals returns a set of signals,
        # Convert-MFAReportSizeToBytes converts to a count of bytes.
        # The single exported command, Start-MailboxMFAReport, is singular.
        'PSUseSingularNouns'
    )
}
