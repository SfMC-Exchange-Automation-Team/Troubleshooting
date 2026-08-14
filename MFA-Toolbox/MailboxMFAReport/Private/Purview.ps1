#Requires -Version 5.1

<#
Purview retention policy context.

v0.10's matcher contained this clause:

    -or ([string]$policy.Applications -match 'Exchange')

which made every Exchange-scoped policy match every mailbox, defeating the
location filter above it and driving PossiblePurviewOverride for the whole
tenant. It was simultaneously too broad (that clause) and too narrow: scoped
policies expose ExchangeLocation entries whose string form is a display name,
so comparing them against UPN / SMTP / GUID rarely matches.

The rewrite reports three buckets instead of a boolean. A policy scoped to
recipients we cannot conclusively resolve is reported as NOT EVALUATED rather
than silently counted as "does not apply" -- the operator needs to know the
coverage gap exists.
#>

function Get-MFAReportPurviewPolicyMatch {
    <#
    .SYNOPSIS
    Classifies each policy as matched, excluded, or not conclusively evaluable.

    .DESCRIPTION
    Pure function over already-fetched policy objects, so it is testable without
    a Purview connection.

    .PARAMETER MailboxHoldGuids
    Policy GUIDs recovered from the mailbox's own InPlaceHolds. This is the
    strongest signal available and is checked first: Exchange is stating that the
    policy is applied to this mailbox, so no location-string inference is needed.
    Callers must pass only ACTIVE holds; exclusion entries must be filtered out
    beforehand.

    .PARAMETER IdentityValues
    Every form the mailbox might appear as in ExchangeLocation. Scoped policies
    frequently stringify to a DISPLAY NAME rather than an address, so passing
    only UPN/SMTP/GUID leaves most scoped policies unresolvable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Policies,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$IdentityValues,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$MailboxHoldGuids = @()
    )

    $matched = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()
    $notEvaluated = [System.Collections.Generic.List[object]]::new()

    $identities = @($IdentityValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $holdGuids = @($MailboxHoldGuids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($policy in @($Policies)) {
        if ($null -eq $policy) { continue }

        $locations = @(Get-MFAReportPropertyValue -InputObject $policy -Name 'ExchangeLocation' |
            ForEach-Object { [string]$_ } | Where-Object { $_ })
        $exceptions = @(Get-MFAReportPropertyValue -InputObject $policy -Name 'ExchangeLocationException' |
            ForEach-Object { [string]$_ } | Where-Object { $_ })

        $policyGuids = @(
            foreach ($property in @('Guid', 'ExchangeObjectId', 'Identity')) {
                ConvertTo-MFAReportNormalisedGuid -Value (Get-MFAReportPropertyValue -InputObject $policy -Name $property)
            }
        ) | Where-Object { $_ }

        $heldByMailbox = @($policyGuids | Where-Object { $holdGuids -contains $_ }).Count -gt 0
        $isExcluded = @($identities | Where-Object { $exceptions -contains $_ }).Count -gt 0
        $isOrgWide = $locations -contains 'All'
        $isExplicit = @($identities | Where-Object { $locations -contains $_ }).Count -gt 0

        $entry = [PSCustomObject]@{
            Name               = Get-MFAReportPropertyValue -InputObject $policy -Name 'Name'
            Mode               = Get-MFAReportPropertyValue -InputObject $policy -Name 'Mode'
            Enabled            = Get-MFAReportPropertyValue -InputObject $policy -Name 'Enabled'
            DistributionStatus = Get-MFAReportPropertyValue -InputObject $policy -Name 'DistributionStatus'
            MatchReason        = $null
            MatchConfidence    = $null
        }

        if ($heldByMailbox) {
            # Exchange itself reports this policy against the mailbox, so this
            # is evidence rather than inference and outranks the location rules.
            $entry.MatchReason = 'MailboxInPlaceHoldReference'
            $entry.MatchConfidence = 'Confirmed'
            $matched.Add($entry)
        }
        elseif ($isExcluded) {
            $entry.MatchReason = 'ExplicitlyExcluded'
            $entry.MatchConfidence = 'High'
            $excluded.Add($entry)
        }
        elseif ($isOrgWide) {
            $entry.MatchReason = 'OrganizationWide'
            $entry.MatchConfidence = 'High'
            $matched.Add($entry)
        }
        elseif ($isExplicit) {
            $entry.MatchReason = 'ExplicitRecipientMatch'
            $entry.MatchConfidence = 'High'
            $matched.Add($entry)
        }
        else {
            # Scoped to recipients that did not match any identity value we hold.
            # ExchangeLocation often stringifies to a display name, so absence of
            # a match is NOT proof the policy does not apply.
            $entry.MatchReason = 'ScopedToRecipientsNotResolvable'
            $entry.MatchConfidence = 'Unknown'
            $notEvaluated.Add($entry)
        }
    }

    return [PSCustomObject]@{
        Matched      = @($matched)
        Excluded     = @($excluded)
        NotEvaluated = @($notEvaluated)
    }
}

function Test-MFAReportPreservationLock {
    <#
    .SYNOPSIS
    Detects a preservation lock on a retention compliance policy.

    .DESCRIPTION
    RestrictiveRetention is the documented property. The remaining names are
    defensive fallbacks for shapes seen across cmdlet versions; they are checked
    but should not be presented to an operator as authoritative.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Policy
    )

    foreach ($name in @('RestrictiveRetention', 'PreservationLockEnabled', 'IsPreservationLocked', 'LockState')) {
        $value = Get-MFAReportPropertyValue -InputObject $Policy -Name $name
        if ($null -eq $value) { continue }
        if ([string]$value -match '^(True|Enabled|Locked)$') { return $true }
    }

    return $false
}

function Get-MFAReportPurviewSignals {
    <#
    .SYNOPSIS
    Collects Purview retention policy context for one mailbox.

    .PARAMETER Policies
    Pre-fetched retention compliance policies. Get-RetentionCompliancePolicy
    -DistributionDetail is one of the most expensive calls in the compliance
    shell; v0.10 issued it once PER MAILBOX. Callers now fetch once per run and
    pass the result in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter()]
        [AllowNull()]
        [object]$Mailbox,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Policies,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$AppPolicies,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$MailboxHoldGuids = @(),

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CollectionError
    )

    # Scoped policies frequently expose ExchangeLocation as a DISPLAY NAME, so
    # comparing only addresses and GUIDs leaves most of them unresolvable.
    $identityValues = @(
        $Identity
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'UserPrincipalName')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'PrimarySmtpAddress')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'ExternalDirectoryObjectId')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'ExchangeGuid')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'DisplayName')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'Name')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'Alias')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'LegacyExchangeDN')
        [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'DistinguishedName')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique

    $summary = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($CollectionError)) {
        $summary.Add("PurviewRetentionPolicyLookupFailed:$CollectionError")
        return [PSCustomObject]@{
            Summary                     = ($summary -join '|')
            MatchedPolicies             = @()
            NotEvaluatedPolicies        = @()
            PreservationLockedPolicies  = @()
            HasPreservationLockOverride = $false
            IsConclusive                = $false
        }
    }

    $match = Get-MFAReportPurviewPolicyMatch -Policies $Policies -IdentityValues $identityValues `
        -MailboxHoldGuids $MailboxHoldGuids

    # Projected into a plain array first. Reading .Name straight off $match.Matched
    # throws under Set-StrictMode -Version 3.0 whenever nothing matched, because
    # member access on an EMPTY collection is a missing-property error -- and the
    # -and short-circuit meant that only ever happened once a policy was actually
    # preservation-locked, i.e. on the tenants this check exists for.
    $matchedNames = @($match.Matched |
        ForEach-Object { [string](Get-MFAReportPropertyValue -InputObject $_ -Name 'Name') })

    $preservationLocked = @($Policies | Where-Object {
        $policyName = [string](Get-MFAReportPropertyValue -InputObject $_ -Name 'Name')
        (Test-MFAReportPreservationLock -Policy $_) -and
        ($matchedNames -contains $policyName)
    } | ForEach-Object { [string](Get-MFAReportPropertyValue -InputObject $_ -Name 'Name') })

    $summary.Add("PurviewRetentionPoliciesMatched=$($match.Matched.Count)")
    $summary.Add("PurviewRetentionPoliciesNotEvaluated=$($match.NotEvaluated.Count)")
    $summary.Add("PurviewRetentionPoliciesExcluded=$($match.Excluded.Count)")

    if ($null -ne $AppPolicies) {
        $summary.Add("AppRetentionCompliancePolicies=$(@($AppPolicies).Count)")
    }

    return [PSCustomObject]@{
        Summary                     = ($summary -join '|')
        MatchedPolicies             = $match.Matched
        NotEvaluatedPolicies        = $match.NotEvaluated
        PreservationLockedPolicies  = @($preservationLocked | Sort-Object -Unique)
        HasPreservationLockOverride = (@($preservationLocked).Count -gt 0)
        IsConclusive                = ($match.NotEvaluated.Count -eq 0)
    }
}

function Get-MFAReportPurviewOverrideSignal {
    <#
    .SYNOPSIS
    Summarises whether Purview may be overriding MRM for this mailbox.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$IsComplianceTagHoldApplied,

        [Parameter()]
        [int]$MatchedPolicyCount = 0,

        [Parameter()]
        [int]$ConfirmedPolicyCount = 0,

        [Parameter()]
        [int]$NotEvaluatedPolicyCount = 0,

        [Parameter()]
        [switch]$HasPreservationLock,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RetentionTagApplicability
    )

    if ($HasPreservationLock) {
        return 'PurviewOverride:PreservationLockedPolicyApplies'
    }

    # A confirmed match came from the mailbox's own InPlaceHolds, so hedging it
    # as "possible" would understate what is known.
    if ($ConfirmedPolicyCount -gt 0) {
        return "PurviewOverride:$ConfirmedPolicyCount Purview policies are confirmed applied to this mailbox; validate precedence before changing MRM."
    }

    if ($IsComplianceTagHoldApplied -eq $true) {
        return 'PossiblePurviewOverride:ComplianceTagHoldApplied'
    }

    if ($MatchedPolicyCount -gt 0) {
        return "PossiblePurviewOverride:$MatchedPolicyCount Purview policies apply; validate precedence before changing MRM."
    }

    if ($NotEvaluatedPolicyCount -gt 0) {
        return "Inconclusive:$NotEvaluatedPolicyCount Purview policies are scoped to recipients that could not be resolved from this run."
    }

    if ($RetentionTagApplicability -match 'not proven|Personal tag detected') {
        return 'MRMApplicabilityUnproven'
    }

    return 'NoOverrideSignalFromCollectedChecks'
}
