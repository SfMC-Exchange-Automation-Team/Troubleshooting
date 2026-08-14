#Requires -Version 5.1

function Start-MailboxMFAReport {
    <#
    .SYNOPSIS
    Removed. Split into Get-MailboxMFAReadiness, Start-MailboxMFAProcessing, and
    Repair-MailboxMFAPrerequisite.

    .DESCRIPTION
    This command combined read-only diagnosis, starting the Managed Folder Assistant, and tenant
    remediation behind one name, so a command documented as a report could create retention tags,
    rewrite a retention policy, and reassign it across the population.

    It is retained only to give existing callers an actionable error instead of
    CommandNotFoundException. Use one of the three replacements.

    .EXAMPLE
    Get-MailboxMFAReadiness -Users user@contoso.com

    Replaces -ReportOnly.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removed command: it only throws a migration message and can change nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Deliberately swallows any v0.10 argument set so existing callers reach the migration message instead of a parameter binding error.')]
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$RemainingArguments
    )

    $message = @'
Start-MailboxMFAReport has been split into three commands so that diagnosis cannot change the tenant:

  Get-MailboxMFAReadiness         read-only readiness report (replaces -ReportOnly)
  Start-MailboxMFAProcessing      starts the Managed Folder Assistant, optionally with -Monitor
  Repair-MailboxMFAPrerequisite   archive and retention remediation (replaces -FixPrerequisites and -AutoCreateTags)

Migration:
  -ReportOnly                ->  Get-MailboxMFAReadiness
  (default report + start)   ->  Start-MailboxMFAProcessing
  -FixPrerequisites          ->  Repair-MailboxMFAPrerequisite -EnableArchive [-EnableAutoExpandingArchive]
  -AutoCreateTags            ->  Repair-MailboxMFAPrerequisite -RetentionPolicyName <name> -RetentionTag <spec> [-AssignPolicyToMailbox]
  -DurationInMinutes         ->  Start-MailboxMFAProcessing -Monitor -DurationInMinutes
  -Parallel / -ThrottleLimit ->  removed; they were validated but never implemented

-RetentionPolicyName no longer defaults to 'Default MRM Policy'. Supply it explicitly.
'@

    throw $message
}
