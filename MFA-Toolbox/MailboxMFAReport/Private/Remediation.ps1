#Requires -Version 5.1

<#
Tenant remediation.

Every write this module can perform now lives behind Repair-MailboxMFAPrerequisite.
The diagnostic path (Get-MailboxMFAReadiness) is read-only by construction.

v0.10 mixed these into the report run, which meant a command whose documented
purpose was reporting could create retention tags, rewrite a retention policy,
and reassign it across the population as a side effect of asking "why is MFA not
running?". It also defaulted -RetentionPolicyName to 'Default MRM Policy', so the
default path modified the tenant's built-in policy.
#>

function ConvertTo-MFAReportTagSpecification {
    <#
    .SYNOPSIS
    Validates and normalises a retention tag specification.

    .DESCRIPTION
    v0.10 accepted bare tag NAMES and hardcoded every created tag as
    All / MoveToArchive / 365 days at the call site, with no way for the caller
    to control the shape of what it was creating in their tenant.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$Specification
    )

    $validTypes = @('All', 'Inbox', 'DeletedItems', 'SentItems', 'JunkEmail', 'Drafts', 'Custom', 'Personal')
    $validActions = @('MoveToArchive', 'DeleteAndAllowRecovery', 'PermanentlyDelete', 'MarkAsPastRetentionLimit')

    foreach ($entry in @($Specification)) {
        if ($null -eq $entry) { continue }

        foreach ($required in @('Name', 'Type', 'RetentionAction', 'AgeLimitForRetention')) {
            if (-not $entry.ContainsKey($required)) {
                throw "Retention tag specification is missing required key '$required'. Supply @{ Name = '...'; Type = 'All'; RetentionAction = 'MoveToArchive'; AgeLimitForRetention = 365 }."
            }
        }

        $type = [string]$entry['Type']
        if ($validTypes -notcontains $type) {
            throw "Retention tag '$($entry['Name'])' has invalid Type '$type'. Valid values: $($validTypes -join ', ')."
        }

        $action = [string]$entry['RetentionAction']
        if ($validActions -notcontains $action) {
            throw "Retention tag '$($entry['Name'])' has invalid RetentionAction '$action'. Valid values: $($validActions -join ', ')."
        }

        $age = 0
        if (-not [int]::TryParse([string]$entry['AgeLimitForRetention'], [ref]$age) -or $age -le 0) {
            throw "Retention tag '$($entry['Name'])' has invalid AgeLimitForRetention '$($entry['AgeLimitForRetention'])'. Supply a positive whole number of days."
        }

        [PSCustomObject]@{
            Name                 = [string]$entry['Name']
            Type                 = $type
            RetentionAction      = $action
            AgeLimitForRetention = $age
        }
    }
}

function Repair-MFAReportArchive {
    <#
    .SYNOPSIS
    Provisions the archive mailbox when it is missing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to the calling cmdlet via -Cmdlet so every prompt is attributed to Repair-MailboxMFAPrerequisite.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string]$Identity,
        [Parameter(Mandatory = $true)] [object]$Mailbox,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $archiveState = [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'ArchiveState')
    if ($archiveState -in @('HostedProvisioned', 'Local')) {
        return "ArchiveAlreadyProvisioned:$archiveState"
    }

    if (-not $Cmdlet.ShouldProcess($Identity, 'Enable archive mailbox')) {
        return 'ArchiveEnableNotConfirmed'
    }

    try {
        Enable-Mailbox -Identity $Identity -Archive -ErrorAction Stop | Out-Null
        return 'EnabledArchive'
    }
    catch {
        return "ArchiveEnableFailed:$($_.Exception.Message)"
    }
}

function Repair-MFAReportAutoExpandingArchive {
    <#
    .SYNOPSIS
    Enables auto-expanding archiving.

    .DESCRIPTION
    This is a ONE-WAY change: auto-expanding archiving cannot be turned off once
    enabled. The irreversibility is stated in the ShouldProcess prompt so the
    operator sees it before confirming, which v0.10 did not do.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to the calling cmdlet via -Cmdlet so every prompt is attributed to Repair-MailboxMFAPrerequisite.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string]$Identity,
        [Parameter(Mandatory = $true)] [object]$Mailbox,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    if ((Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'AutoExpandingArchiveEnabled') -eq $true) {
        return 'AutoExpandingArchiveAlreadyEnabled'
    }

    if (-not $Cmdlet.ShouldProcess($Identity, 'Enable auto-expanding archive (IRREVERSIBLE: this cannot be disabled once enabled)')) {
        return 'AutoExpandingArchiveEnableNotConfirmed'
    }

    try {
        Set-Mailbox -Identity $Identity -AutoExpandingArchive -ErrorAction Stop
        return 'EnabledAutoExpandingArchive'
    }
    catch {
        return "AutoExpandingArchiveEnableFailed:$($_.Exception.Message)"
    }
}

function Repair-MFAReportRetentionTag {
    <#
    .SYNOPSIS
    Creates a retention tag if it does not already exist.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to the calling cmdlet via -Cmdlet so every prompt is attributed to Repair-MailboxMFAPrerequisite.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [object]$TagSpecification,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $name = [string]$TagSpecification.Name

    if (Get-RetentionPolicyTag -Identity $name -ErrorAction SilentlyContinue) {
        return "RetentionTagExists:$name"
    }

    $description = "$name ($($TagSpecification.Type) / $($TagSpecification.RetentionAction) / $($TagSpecification.AgeLimitForRetention) days)"
    if (-not $Cmdlet.ShouldProcess("retention tag '$name'", "Create retention policy tag $description")) {
        return "RetentionTagCreateNotConfirmed:$name"
    }

    try {
        New-RetentionPolicyTag -Name $name -Type $TagSpecification.Type `
            -AgeLimitForRetention $TagSpecification.AgeLimitForRetention `
            -RetentionAction $TagSpecification.RetentionAction -ErrorAction Stop | Out-Null
        return "CreatedRetentionTag:$name"
    }
    catch {
        return "RetentionTagCreateFailed:${name}:$($_.Exception.Message)"
    }
}

function Repair-MFAReportRetentionPolicy {
    <#
    .SYNOPSIS
    Creates or updates a retention policy and links the required tags.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to the calling cmdlet via -Cmdlet so every prompt is attributed to Repair-MailboxMFAPrerequisite.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)] [string]$PolicyName,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]]$TagNames,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $actions = [System.Collections.Generic.List[string]]::new()
    $policy = Get-RetentionPolicy -Identity $PolicyName -ErrorAction SilentlyContinue

    if (-not $policy) {
        if (-not $Cmdlet.ShouldProcess("retention policy '$PolicyName'", 'Create retention policy')) {
            $actions.Add("RetentionPolicyCreateNotConfirmed:$PolicyName")
            return @($actions)
        }
        try {
            New-RetentionPolicy -Name $PolicyName -RetentionPolicyTagLinks $TagNames -ErrorAction Stop | Out-Null
            $actions.Add("CreatedRetentionPolicy:$PolicyName")
            $policy = Get-RetentionPolicy -Identity $PolicyName -ErrorAction Stop
        }
        catch {
            $actions.Add("RetentionPolicyCreateFailed:${PolicyName}:$($_.Exception.Message)")
            return @($actions)
        }
    }

    if (@($TagNames).Count -eq 0) {
        $actions.Add("RetentionPolicyTagLinksUnchanged:$PolicyName")
        return @($actions)
    }

    # @() at the call site: PowerShell unwraps a single-element array on function
    # return, and ADObjectId links must be normalised to strings before the
    # membership test -- the comparison v0.10 got wrong.
    $currentLinks = @(ConvertTo-MFAReportTagLinkName -TagLinks @(
        Get-MFAReportPropertyValue -InputObject $policy -Name 'RetentionPolicyTagLinks'))
    $missing = @($TagNames | Where-Object { $currentLinks -notcontains $_ })

    if ($missing.Count -eq 0) {
        $actions.Add("RetentionPolicyTagsAlreadyLinked:$PolicyName")
        return @($actions)
    }

    if (-not $Cmdlet.ShouldProcess("retention policy '$PolicyName'", "Add missing tags: $($missing -join ', ')")) {
        $actions.Add("RetentionPolicyTagUpdateNotConfirmed:$($missing -join ',')")
        return @($actions)
    }

    try {
        Set-RetentionPolicy -Identity $PolicyName -RetentionPolicyTagLinks @($currentLinks + $missing | Sort-Object -Unique) -ErrorAction Stop
        $actions.Add("UpdatedRetentionPolicyTags:$($missing -join ',')")
    }
    catch {
        $actions.Add("RetentionPolicyTagUpdateFailed:$($_.Exception.Message)")
    }

    return @($actions)
}

function Repair-MFAReportMailboxPolicyAssignment {
    <#
    .SYNOPSIS
    Assigns a retention policy to a mailbox.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to the calling cmdlet via -Cmdlet so every prompt is attributed to Repair-MailboxMFAPrerequisite.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string]$Identity,
        [Parameter(Mandatory = $true)] [object]$Mailbox,
        [Parameter(Mandatory = $true)] [string]$PolicyName,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $assigned = [string](Get-MFAReportPropertyValue -InputObject $Mailbox -Name 'RetentionPolicy')
    if ($assigned -eq $PolicyName) {
        return "RetentionPolicyAlreadyAssigned:$PolicyName"
    }

    $what = if ([string]::IsNullOrWhiteSpace($assigned)) {
        "Assign retention policy '$PolicyName'"
    }
    else {
        "Replace retention policy '$assigned' with '$PolicyName'"
    }

    if (-not $Cmdlet.ShouldProcess("mailbox '$Identity'", $what)) {
        return "RetentionPolicyAssignNotConfirmed:$PolicyName"
    }

    try {
        Set-Mailbox -Identity $Identity -RetentionPolicy $PolicyName -ErrorAction Stop
        return "AssignedRetentionPolicy:$PolicyName"
    }
    catch {
        return "RetentionPolicyAssignFailed:$($_.Exception.Message)"
    }
}
