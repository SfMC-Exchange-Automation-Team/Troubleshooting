#Requires -Version 5.1

<#
Retention tag and policy handling.

Two v0.10 defects are fixed here.

1. RetentionPolicyTagLinks yields ADObjectId objects, not strings. The
   membership test `$currentLinks -notcontains $tagName` therefore never
   matched, so every run reported all tags as missing and re-issued
   Set-RetentionPolicy with a duplicated link list.

2. Tag metadata was packed positionally into 'Name:Type:Action:AgeLimit' and
   split back apart later. Retention tag names may contain a colon, so a tag
   named 'Legal:Hold Tag' produced a scope of 'Hold Tag'. Tags are now carried
   as structured objects and flattened only at export.

Policy and tag lookups are also cached per run. v0.10 re-fetched the policy and
every linked tag for each mailbox, which is pure waste when a policy is shared
across the population.
#>

function New-MFAReportRunCache {
    <#
    .SYNOPSIS
    Creates the per-run lookup cache shared across mailboxes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory cache; changes no system state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        RetentionPolicy    = @{}
        RetentionPolicyTag = @{}
        PolicyTrigger      = @{}
    }
}

function Get-MFAReportRetentionPolicyCached {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    if (-not $Cache.RetentionPolicy.ContainsKey($PolicyName)) {
        $Cache.RetentionPolicy[$PolicyName] = Get-RetentionPolicy -Identity $PolicyName -ErrorAction SilentlyContinue
    }

    return $Cache.RetentionPolicy[$PolicyName]
}

function Get-MFAReportRetentionPolicyTagCached {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TagName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    if (-not $Cache.RetentionPolicyTag.ContainsKey($TagName)) {
        try {
            $Cache.RetentionPolicyTag[$TagName] = Get-RetentionPolicyTag -Identity $TagName -ErrorAction Stop
        }
        catch {
            $Cache.RetentionPolicyTag[$TagName] = [PSCustomObject]@{
                MFAReportLookupError = $_.Exception.Message
            }
        }
    }

    return $Cache.RetentionPolicyTag[$TagName]
}

function ConvertTo-MFAReportTagLinkName {
    <#
    .SYNOPSIS
    Normalises RetentionPolicyTagLinks entries to comparable strings.

    .DESCRIPTION
    Fixes the ADObjectId-vs-string membership bug. ADObjectId stringifies to a
    path-like value in some shapes, so the trailing segment is taken as the tag
    name.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$TagLinks
    )

    return @($TagLinks |
        Where-Object { $null -ne $_ } |
        ForEach-Object {
            $text = ([string]$_).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($text -match '/') { $text = ($text -split '/')[-1] }
            $text
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-MFAReportRetentionPolicyTrigger {
    <#
    .SYNOPSIS
    Determines whether a retention policy contains an MFA-triggering tag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyName,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredRetentionActions,

        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    $cacheKey = "$PolicyName|$($RequiredRetentionActions -join ',')"
    if ($Cache.PolicyTrigger.ContainsKey($cacheKey)) {
        return $Cache.PolicyTrigger[$cacheKey]
    }

    $result = $null
    $policy = Get-MFAReportRetentionPolicyCached -PolicyName $PolicyName -Cache $Cache

    if (-not $policy) {
        $result = [PSCustomObject]@{
            IsValid        = $false
            Message        = "Retention policy '$PolicyName' was not found."
            TriggeringTags = @()
        }
    }
    else {
        # @() at the call site: PowerShell unwraps a single-element array on
        # function return, so a policy with exactly one linked tag would yield a
        # bare string and .Count would fail under StrictMode.
        $tagNames = @(ConvertTo-MFAReportTagLinkName -TagLinks @(
            Get-MFAReportPropertyValue -InputObject $policy -Name 'RetentionPolicyTagLinks'))

        if ($tagNames.Count -eq 0) {
            $result = [PSCustomObject]@{
                IsValid        = $false
                Message        = "Retention policy '$PolicyName' has no linked retention tags."
                TriggeringTags = @()
            }
        }
        else {
            $triggeringTags = [System.Collections.Generic.List[object]]::new()
            $tagErrors = [System.Collections.Generic.List[string]]::new()

            foreach ($tagName in $tagNames) {
                $tag = Get-MFAReportRetentionPolicyTagCached -TagName $tagName -Cache $Cache

                $lookupError = Get-MFAReportPropertyValue -InputObject $tag -Name 'MFAReportLookupError'
                if ($lookupError) {
                    $tagErrors.Add("${tagName}:$lookupError")
                    continue
                }

                $retentionEnabled = Get-MFAReportPropertyValue -InputObject $tag -Name 'RetentionEnabled'
                if ($null -ne $retentionEnabled -and -not [bool]$retentionEnabled) { continue }

                $action = [string](Get-MFAReportPropertyValue -InputObject $tag -Name 'RetentionAction')
                if ($RequiredRetentionActions -contains $action) {
                    $triggeringTags.Add([PSCustomObject]@{
                        Name                 = [string](Get-MFAReportPropertyValue -InputObject $tag -Name 'Name')
                        Type                 = [string](Get-MFAReportPropertyValue -InputObject $tag -Name 'Type')
                        RetentionAction      = $action
                        AgeLimitForRetention = [string](Get-MFAReportPropertyValue -InputObject $tag -Name 'AgeLimitForRetention')
                    })
                }
            }

            if ($triggeringTags.Count -gt 0) {
                $result = [PSCustomObject]@{
                    IsValid        = $true
                    Message        = "Retention policy '$PolicyName' has MFA-triggering tag actions."
                    TriggeringTags = @($triggeringTags)
                }
            }
            else {
                $message = "Retention policy '$PolicyName' does not include an enabled tag with one of these actions: $($RequiredRetentionActions -join ', ')."
                if ($tagErrors.Count -gt 0) {
                    $message = "$message Tag lookup errors: $($tagErrors -join '; ')"
                }
                $result = [PSCustomObject]@{
                    IsValid        = $false
                    Message        = $message
                    TriggeringTags = @()
                }
            }
        }
    }

    $Cache.PolicyTrigger[$cacheKey] = $result
    return $result
}

function Get-MFAReportRetentionTagApplicability {
    <#
    .SYNOPSIS
    Explains whether the triggering tags can actually apply to this mailbox.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$TriggeringTags = @(),

        [Parameter()]
        [AllowNull()]
        [object]$TaggedFolderCount
    )

    $tags = @($TriggeringTags | Where-Object { $null -ne $_ })
    if ($tags.Count -eq 0) {
        return 'No triggering MRM tags validated.'
    }

    # Read the scope from the structured property rather than splitting a packed
    # string, so tag names containing ':' no longer corrupt the scope.
    $tagScopes = @($tags | ForEach-Object {
        $type = [string](Get-MFAReportPropertyValue -InputObject $_ -Name 'Type')
        if ([string]::IsNullOrWhiteSpace($type)) { 'Unknown' } else { $type }
    } | Sort-Object -Unique)

    $messages = [System.Collections.Generic.List[string]]::new()
    $messages.Add("TriggeringTagScopes=$($tagScopes -join ',')")

    if ($tagScopes -contains 'Personal') {
        $messages.Add('Personal tag detected; user assignment is required before MFA can act on that tag.')
    }
    if ($tagScopes -contains 'All') {
        $messages.Add('Default/all-folder tag can apply broadly unless overridden by folder, personal, or compliance policy.')
    }
    if (@($tagScopes | Where-Object { $_ -match '^(Inbox|DeletedItems|SentItems|JunkEmail|Drafts)$' }).Count -gt 0) {
        $messages.Add('Folder-specific tag detected; only matching folders are expected to process under that tag.')
    }

    if ($null -ne $TaggedFolderCount) {
        $messages.Add("FolderEvidenceTaggedFolders=$TaggedFolderCount")
        if ($TaggedFolderCount -eq 0 -and -not ($tagScopes -contains 'All')) {
            $messages.Add('No tagged folders found; folder/personal tag applicability is not proven.')
        }
    }

    return ($messages -join '|')
}

