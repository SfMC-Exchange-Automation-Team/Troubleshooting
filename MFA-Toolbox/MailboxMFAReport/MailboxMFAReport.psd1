@{
    RootModule        = 'MailboxMFAReport.psm1'
    ModuleVersion     = '0.13.2'
    GUID              = '59682e44-b5bb-4292-ad2d-26f1dda18b08'
    Author            = 'cuhaafke'
    Description       = 'Diagnoses Managed Folder Assistant readiness and processing blockers for Exchange Online mailboxes, with remediation kept in a separate command.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-MailboxMFAReadiness'
        'Start-MailboxMFAProcessing'
        'Repair-MailboxMFAPrerequisite'
        'Start-MailboxMFAReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('Exchange', 'ExchangeOnline', 'MRM', 'ManagedFolderAssistant', 'Retention', 'Purview')
            ReleaseNotes = @'
0.13.2 - -WhatIf reported artifacts it never wrote.

Export-Csv and Set-Content both honour -WhatIf, so a preview run writes nothing.
Export-MFAReportArtifact returned the path regardless, so Repair-MailboxMFAPrerequisite
announced "Repair report saved to <path>" and Start-MailboxMFAProcessing returned
four Artifacts entries, for files that do not exist -- on exactly the -WhatIf
preview the README tells operators to run before touching a tenant. An operator
checking their preview would have found nothing at the path they were given.

Both now confirm the file is on disk before reporting it, which also catches a
write that failed non-terminatingly (a directory that was never created, or no
permission to it). Artifacts drops entries whose file was not written, so
.Artifacts.Count is a count of files the operator can actually open. The
Export-Csv call itself is unchanged, so -WhatIf still prints what it would write.

0.13.1 - Pre-tenant sweep. Two crash bugs, one containment gap, one doc defect.

StrictMode 3.0 treats member access on an EMPTY collection as a missing-property
error. Two sites read a property straight off a filtered pipeline result:

- Purview.ps1 read .Name off the matched-policy list to find preservation-locked
  policies. An -and short-circuit meant it only evaluated once a policy was
  actually preservation-locked, so it never fired in testing -- the suite's stub
  sets RestrictiveRetention = $false. Against a tenant that HAS a locked policy
  which does not match the mailbox, this threw, and because nothing contained it
  the entire run aborted on the first mailbox with no artifacts written. It
  failed hardest on exactly the tenants the check exists to serve.
- Diagnostics.ps1 interpolated the oldest-item dates from a filtered folder list.
  A mailbox where no folder carries those dates threw into the surrounding catch,
  which reported PrimaryFolderStatsFailed -- blaming Exchange for a local bug --
  and discarded TaggedFolderDetails, the point of -IncludeFolderEvidence.

Both now read through the collection safely. Regression tests cover the empty and
non-empty cases for each.

Run-level containment: Invoke-MFAReportPopulation had no try/catch around the
per-mailbox evaluation. Evaluation handles the failures it anticipates (lookup,
licensing, statistics), but an unanticipated one escaped the loop entirely, so
Complete-MFAReportSession never ran and the checkpoint that exists to protect
long runs was bypassed. Each mailbox is now contained: the failure is recorded as
Skipped / EvaluationError and the run finishes and writes its artifacts.

Documentation: Get-MailboxMFAReadiness returns a run object
(RunId/Summary/Results/Artifacts), but its own help, Repair-MailboxMFAPrerequisite's
help, and the README all documented piping the cmdlet straight into Where-Object
and then into remediation. That silently matches nothing -- the filter sees one
wrapper, not the per-mailbox records. All three now show .Results, and the README
documents the return shape.

Also:
- The NoArchive recommendation pointed at -FixPrerequisites, a v0.10 parameter
  that no longer exists. It now names Repair-MailboxMFAPrerequisite -EnableArchive.
- Export-MailboxDiagnosticLogs is no longer issued for HoldTracking and
  SubstrateHoldTracking after the primary collection failed for a TERMINAL reason
  (RBAC, unsupported mailbox type). That was four failed round-trips per mailbox
  where two would do, spending throttling budget to learn nothing. Transient
  failures still fall through, because a throttle says nothing about whether
  those components are readable.

0.13.0 - Hold and Purview resolution: evidence in place of inference.

The mailbox's own InPlaceHolds is authoritative about which compliance policies
apply to it. Both heuristics now use it.

- Hold identifiers are decoded to the policy GUID they embed, and resolved
  against the retention compliance policies already fetched for the run. The
  report shows a policy NAME instead of an identifier the operator had to chase
  manually. An unmatched GUID stays unnamed; nothing is invented.
- Purview matching gained a Confirmed tier: a policy whose GUID appears in the
  mailbox's active InPlaceHolds is confirmed applied, regardless of what
  ExchangeLocation says. Previously such a policy landed in the unresolvable
  bucket whenever it was scoped by name to somebody else.
- Location matching now also compares DisplayName, Name, Alias, LegacyExchangeDN
  and DistinguishedName. Scoped policies commonly stringify to a display name,
  so comparing only addresses and GUIDs left most of them unresolvable.
- PurviewOverrideSignal no longer hedges what it knows: confirmed matches report
  as PurviewOverride, inferred ones remain PossiblePurviewOverride.
- Hold evaluation moved ahead of the optional deep-evidence collection so its
  GUIDs are available to the Purview matcher.

Exclusion holds ('-' prefix or ':2' suffix) are excluded from the GUID set, so
a policy that explicitly excludes the mailbox can never confirm itself.

0.12.0 - Split diagnosis from remediation, plus resilience for long runs.

Start-MailboxMFAReport combined read-only diagnosis, starting the Managed Folder
Assistant, and tenant remediation behind a single name, so a command documented
as a report could create retention tags, rewrite a retention policy, and
reassign it across the population as a side effect. It is now a stub that throws
a migration message. Three commands replace it:

  Get-MailboxMFAReadiness        read-only. Performs no tenant writes at all.
  Start-MailboxMFAProcessing     starts the assistant; optional -Monitor.
  Repair-MailboxMFAPrerequisite  every tenant write lives here.

Readiness now distinguishes Blocked (evaluated; we know why MFA will not run)
from Skipped (could not evaluate). v0.10 reported both identically, so "no
archive" and "could not read the mailbox" were indistinguishable.

Remediation safety:
- -RetentionPolicyName has NO default. v0.10 defaulted it to 'Default MRM
  Policy', so the default path modified the tenant built-in policy.
- Retention tags take a full specification (Name/Type/RetentionAction/
  AgeLimitForRetention). v0.10 accepted bare names and hardcoded every created
  tag as All/MoveToArchive/365 days at the call site.
- Each repair action is opt-in by its own switch; the cmdlet refuses to run with
  none selected.
- Enabling auto-expanding archiving now states in the prompt that it cannot be
  undone.
- Tag and policy work runs once per RUN, not once per mailbox.

Resilience for long runs:
- Transient service failures (throttling, timeouts, connection resets) are
  retried with exponential backoff and full jitter. Terminal errors are NOT
  retried, so a stale identity list does not multiply the runtime. v0.10 issued
  every call once, making a throttle response indistinguishable from a real
  fault in the report.
- Results are checkpointed to MFAReport_INPROGRESS_<runid>.csv as each mailbox
  completes, and the file is removed on success. An interrupted run keeps
  everything collected so far.
- -Parallel / -ThrottleLimit removed rather than implemented: real parallelism
  needs one Exchange Online connection per runspace, which spends the same
  throttling budget it is trying to save, breaks ShouldProcess prompting, and
  cannot be verified without a tenant. See README.

0.11.0 - Restructured from Start-MFAReport_v0.10.ps1 into a module.

Correctness fixes (v0.10 reported these incorrectly):
- Throttling was detected by matching diagnostic-log ELEMENT NAMES, so a mailbox
  reporting <ResourceUnhealthy>False</ResourceUnhealthy> classified as throttled.
  Extraction and interpretation are now separate; classification reads only
  parsed values.
- Boolean flags used unanchored -match 'true|1', which matched any timestamp
  containing a 1 and the word "Untrue". Now whole-value matched, with $null
  distinguished from false.
- 'NoEligibleItems' was concluded from movement counters that only populate
  during single-mailbox monitoring, so every multi-mailbox result asserted "no
  movement detected" about an unmeasured quantity. Movement measurement is now
  explicit and the conclusion requires it.
- Recoverable Items quota pressure summed the cumulative FolderAndSubfolderSize
  across nested folders, inflating usage by roughly the hierarchy depth.
- Purview matching treated any Exchange-scoped policy as applying to every
  mailbox. Policies that cannot be conclusively resolved are now reported as
  not-evaluated rather than silently treated as non-applicable.
- RetentionPolicyTagLinks yields ADObjectId objects, so the -notcontains
  membership test never matched and every run re-issued Set-RetentionPolicy with
  a duplicated link list.
- Start-ManagedFolderAssistant ran without -ErrorAction Stop, so a failure was
  still reported as a successful trigger.
- Retention tag metadata was packed into a colon-delimited string and split back
  apart, corrupting any tag whose name contained a colon.
- Quota values were appended to the mailbox health WARNING list, making every
  mailbox report a warning and rendering one classification and one
  recommendation constant across the whole report.
- A single-mailbox -ReportOnly run entered the monitoring loop and blocked for
  the full duration after deliberately triggering nothing.
- Holds that explicitly EXCLUDE a mailbox ('-' prefix or ':2' suffix) counted
  toward satisfying a hold requirement.

Other changes:
- Comment-based help moved onto the function; it previously sat on the file, so
  Get-Help returned nothing.
- Retention policy, tag, and Purview lookups cached per run instead of per
  mailbox.
- Partial results are salvaged to disk if a run does not complete.
- CSV export pinned to UTF8; Windows PowerShell 5.1 defaults to ASCII.
- Ensure-* renamed to approved verbs; Write-Host replaced with the information
  and verbose streams; dead Select-MFAReportRegexValues removed.
- Inert -Parallel / -ThrottleLimit parameters removed.
'@
        }
    }
}
