#Requires -Version 5.1

<#
Hold evaluation.

v0.10 decoded InPlaceHolds entries but did not handle the leading '-' exclusion
prefix, so a hold that explicitly EXCLUDES the mailbox was counted as an active
hold. The ':2' suffix (explicitly excluded) was decoded for display but likewise
did not affect the satisfied/not-satisfied decision.

Hold identifier shapes are only partially documented and can change. Decoding is
therefore treated as advisory: the Scope/State labels are for operator context,
while the include/exclude determination -- which actually gates behaviour -- is
kept deliberately conservative.
#>

function Get-MFAReportHoldPolicyGuid {
    <#
    .SYNOPSIS
    Extracts the normalised policy GUID embedded in an InPlaceHolds identifier.

    .DESCRIPTION
    Hold identifiers carry the GUID of the compliance policy that placed them.
    Recovering it turns an opaque string like 'mbxa1b2...' into something that
    can be matched against the retention compliance policies already fetched for
    the run, which is what lets the report name the policy instead of printing
    an identifier the operator has to chase manually.

    Returns $null when the remainder does not look like a GUID, so a shape this
    does not understand degrades to "undecoded" rather than to a wrong answer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$HoldId
    )

    if ([string]::IsNullOrWhiteSpace($HoldId)) { return $null }

    $body = $HoldId.Trim()
    $body = $body -replace '^-', ''          # exclusion marker
    $body = $body -replace ':\d+$', ''       # explicit include/exclude suffix
    $body = $body -replace '^(mbx|skp|grp|cld|UniH)', ''
    $body = $body -replace '[{}\-]', ''

    if ($body -match '^[0-9a-fA-F]{32}$') { return $body.ToLowerInvariant() }

    return $null
}

function ConvertTo-MFAReportNormalisedGuid {
    <#
    .SYNOPSIS
    Normalises a GUID-ish value for comparison against a hold policy GUID.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }

    $text = ([string]$Value).Trim() -replace '[{}\-]', ''
    if ($text -match '^[0-9a-fA-F]{32}$') { return $text.ToLowerInvariant() }

    return $null
}

function ConvertTo-MFAReportHoldDescription {
    <#
    .SYNOPSIS
    Decodes a single InPlaceHolds identifier into a structured description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$HoldId
    )

    if ([string]::IsNullOrWhiteSpace($HoldId)) { return $null }

    $normalized = $HoldId.Trim()
    $isExclusion = $false

    # A leading '-' marks the mailbox as EXCLUDED from that policy.
    if ($normalized.StartsWith('-')) {
        $isExclusion = $true
        $normalized = $normalized.Substring(1)
    }

    $scope = switch -Regex ($normalized) {
        '^mbx'  { 'ExchangeMailboxRetentionCompliancePolicy'; break }
        '^skp'  { 'SkypeTeamsRetentionCompliancePolicy'; break }
        '^grp'  { 'Microsoft365GroupRetentionCompliancePolicy'; break }
        '^UniH' { 'UnifiedHold'; break }
        '^cld'  { 'CloudRetentionCompliancePolicy'; break }
        default { 'UnknownHoldType' }
    }

    $state = switch -Regex ($normalized) {
        ':1$' { 'ExplicitIncluded'; break }
        ':2$' { 'ExplicitExcluded'; break }
        default { 'AppliedOrUndecoded' }
    }

    if ($state -eq 'ExplicitExcluded') { $isExclusion = $true }

    return [PSCustomObject]@{
        HoldId      = $HoldId
        Scope       = $scope
        State       = $state
        IsExclusion = $isExclusion
        PolicyGuid  = Get-MFAReportHoldPolicyGuid -HoldId $HoldId
        PolicyName  = $null      # filled in by Resolve-MFAReportHoldPolicyName
        Description = "$scope/$state/$HoldId"
    }
}

function Resolve-MFAReportHoldPolicyName {
    <#
    .SYNOPSIS
    Names each hold by matching its embedded GUID against known policies.

    .DESCRIPTION
    Pure function over holds already decoded and policies already fetched, so it
    costs no extra service calls. Holds whose GUID matches nothing keep a null
    PolicyName and their original description; the report never invents a name.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Holds,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Policies
    )

    $byGuid = @{}
    foreach ($policy in @($Policies)) {
        if ($null -eq $policy) { continue }
        foreach ($property in @('Guid', 'ExchangeObjectId', 'Identity')) {
            $guid = ConvertTo-MFAReportNormalisedGuid -Value (Get-MFAReportPropertyValue -InputObject $policy -Name $property)
            if ($guid -and -not $byGuid.ContainsKey($guid)) {
                $byGuid[$guid] = [string](Get-MFAReportPropertyValue -InputObject $policy -Name 'Name')
            }
        }
    }

    foreach ($hold in @($Holds)) {
        if ($null -eq $hold) { continue }

        if ($hold.PolicyGuid -and $byGuid.ContainsKey($hold.PolicyGuid)) {
            $hold.PolicyName = $byGuid[$hold.PolicyGuid]
            $hold.Description = "$($hold.Scope)/$($hold.State)/$($hold.PolicyName)/$($hold.HoldId)"
        }

        $hold
    }
}

function Test-MFAReportHoldRequirement {
    <#
    .SYNOPSIS
    Evaluates whether the configured hold requirement is satisfied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Mailbox,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'Any', 'LitigationHold', 'MailboxOrOrgWideHold', 'LitigationHoldOrOrgWideHold')]
        [string]$RequiredHold,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$OrganizationWideHoldIds = @()
    )

    $rawMailboxHolds = @(Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'InPlaceHolds')

    $mailboxHolds = @($rawMailboxHolds |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { ConvertTo-MFAReportHoldDescription -HoldId ([string]$_) } |
        Where-Object { $null -ne $_ })

    $organizationHolds = @($OrganizationWideHoldIds |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { ConvertTo-MFAReportHoldDescription -HoldId ([string]$_) } |
        Where-Object { $null -ne $_ })

    # Only holds that actually APPLY to this mailbox can satisfy a requirement.
    $activeMailboxHolds = @($mailboxHolds | Where-Object { -not $_.IsExclusion })
    $activeOrganizationHolds = @($organizationHolds | Where-Object { -not $_.IsExclusion })
    $excludedHolds = @($mailboxHolds + $organizationHolds | Where-Object { $_.IsExclusion })

    $litigationHoldEnabled = (Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'LitigationHoldEnabled') -eq $true

    $holdSources = @()
    if ($litigationHoldEnabled) {
        $holdSources += 'LitigationHold'
    }
    if ($activeMailboxHolds.Count -gt 0) {
        $holdSources += "MailboxInPlaceHold:$(($activeMailboxHolds.Description) -join ',')"
    }
    if ($activeOrganizationHolds.Count -gt 0) {
        $holdSources += "OrganizationWideHold:$(($activeOrganizationHolds.Description) -join ',')"
    }

    $isSatisfied = switch ($RequiredHold) {
        'None' { $true }
        'Any' { $holdSources.Count -gt 0 }
        'LitigationHold' { $litigationHoldEnabled }
        'MailboxOrOrgWideHold' { ($activeMailboxHolds.Count -gt 0) -or ($activeOrganizationHolds.Count -gt 0) }
        'LitigationHoldOrOrgWideHold' { $litigationHoldEnabled -or ($activeOrganizationHolds.Count -gt 0) }
    }

    return [PSCustomObject]@{
        IsSatisfied             = $isSatisfied
        RequiredHold            = $RequiredHold
        HoldSources             = $holdSources
        LitigationHoldEnabled   = $litigationHoldEnabled
        MailboxInPlaceHolds     = $activeMailboxHolds
        OrganizationWideHolds   = $activeOrganizationHolds
        ExcludedHolds           = $excludedHolds
    }
}
