<#
.SYNOPSIS
Discovery Replay utilities for importing, loading, and managing Exchange discovery results.

.DESCRIPTION
This script provides a lightweight framework for working with XML/Clixml output 
from Exchange discovery cmdlets (e.g., Get-ExchangeServer, Get-SendConnector).
It allows you to register discovery datasets by customer, automatically load 
them as Get-* functions (shims), filter them using familiar Exchange/AD-style 
parameters (Identity, Name, UserPrincipalName, etc.), and remove them when 
no longer needed.

State is tracked in two internal registries:
 - $script:CustomerRegistry   : Customer name -> dataset path and tag (EXO/OnPrem/Unspecified)
 - $script:FunctionRegistry   : Function name -> XML path, customer, and tag

Functions included:
 - Import-DiscoveryScriptResults : Register a dataset folder and optionally auto-load shims
 - Load-Customer                 : Create global Get-* shims from a dataset
 - Unload-Customer               : Remove all shims for a customer
 - Remove-DiscoveryFunctions     : Internal helper to delete a customer’s shims
 - Get-DiscoveryIndex            : List active Get-* shims, their source, and tags
 - Get-Customer                  : List registered customers and their dataset info

.PARAMETER CustomerName
Specifies the logical name for a customer dataset (e.g. "Contoso"). Used when 
importing, loading, unloading, or listing shims.

.PARAMETER Path
Specifies the folder path containing the discovery XML/Clixml files.

.PARAMETER EXO
Indicates that the dataset represents Exchange Online output.

.PARAMETER OnPrem
Indicates that the dataset represents Exchange On-Premises output.

.PARAMETER NoLoad
Optional switch for Import-DiscoveryScriptResults. When present, prevents 
automatic loading of shims after import.

.EXAMPLE
# Import and auto-load an OnPrem dataset for Contoso
Import-DiscoveryScriptResults -CustomerName Contoso -Path 'C:\Discovery\Contoso\OrgSettings' -OnPrem

.EXAMPLE
# Import a dataset but defer loading of shims
Import-DiscoveryScriptResults -CustomerName Fabrikam -Path 'C:\Discovery\Fabrikam\OrgSettings' -EXO -NoLoad

.EXAMPLE
# Load an existing customer dataset (creates Get-* functions)
Load-Customer -CustomerName Contoso -OnPrem

.EXAMPLE
# List all registered customers
Get-Customer

.EXAMPLE
# List all active discovery shims for Contoso
Get-DiscoveryIndex -CustomerName Contoso

.EXAMPLE
# Remove all shims for a customer but leave the dataset registered
Remove-DiscoveryFunctions -CustomerName Contoso

.EXAMPLE
# Fully unload a customer (remove shims)
Unload-Customer -CustomerName Contoso

.NOTES
Author   : Cullen Haafke
Requires : PowerShell 5.1+ (for compatibility with Import-Clixml and modern hashtables)
Version  : 1.0    Date     : 25 Aug 2025
           1.2    Date     : 09 Sep 2025
           - Added logic to handle dynamic filename prefixes and org name detection        

.LINK
<optional: GitHub repo or internal documentation link>
#>




# --- State ---
if (-not ($global:CustomerRegistry  -is [hashtable])) { $global:CustomerRegistry  = @{} }
if (-not ($global:FunctionRegistry -is [hashtable])) { $global:FunctionRegistry = @{} }


function global:Import-DiscoveryScriptResults {
    <#
      Register a folder of discovery XMLs for a customer.
      Tag with -EXO or -OnPrem (optional). If omitted, tag = 'Unspecified'.
      By default, automatically loads the customer (creates Get-* shims).
      Use -NoLoad to skip auto-loading.
    #>
    [CmdletBinding(DefaultParameterSetName='Unspecified')]
    param(
        [Parameter(Mandatory)] [string]$CustomerName,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$Path,
        [string]$Year,
        [Parameter(ParameterSetName='EXO')]    [switch]$EXO,
        [Parameter(ParameterSetName='OnPrem')] [switch]$OnPrem,
        

        # Opt-out: prevents the automatic Load-Customer step
        [switch]$NoLoad
    )

    $resolvedPath = (Resolve-Path $Path).Path
    $resolvedFilename = Split-Path $resolvedPath -Leaf
    $tag = if ($EXO) { 'EXO' } elseif ($OnPrem) { 'OnPrem' } else { 'Unspecified' }

    $script:CustomerRegistry[$CustomerName] = @{
        Path = $resolvedPath
        Name = $resolvedFilename
        Tag  = $tag
        Year = $Year
    }

    Write-Host "Imported $CustomerName [$tag] from $resolvedfilename"

    if (-not $NoLoad) {
        try {
            # If you specified -EXO/-OnPrem on import, honor that on load too
            Load-Customer -CustomerName $CustomerName -EXO:$EXO -OnPrem:$OnPrem
        }
        catch {
            Write-Warning ("Auto-load failed for {0}: {1}" -f $CustomerName, $_.Exception.Message)
            Write-Warning "Customer is registered; run Load-Customer manually when ready."
        }
    } else {
        Write-Host "Skipped auto-load for $CustomerName (NoLoad). Use: Load-Customer -CustomerName '$CustomerName' $(if($tag -ne 'Unspecified'){"-$tag"})"
    }
}

function Convert-ToOrgToken {
    <#
      Normalizes an organization identifier for filename prefix matching.
      - Keeps hyphens and dots (e.g., contoso-banking, contoso.onmicrosoft.com)
      - Trims whitespace
      - Splits only on obvious container/address separators: \ / @ , whitespace
      - Returns $null for empty inputs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputString
    )

    if ([string]::IsNullOrWhiteSpace($InputString)) { return $null }

    # Take the first segment on common separators used in DNs/addresses
    $first = ($InputString -split '[\\/@,\s]')[0]
    return $first.Trim()
}


<# ONLY NEEDED FOR UNLOAD-CUSTOMER - Which may eventually be removed.
    When a customer dataset is loaded with Load-Customer, discovery functions (shims) 
    are created in the global function scope (e.g., Get-ExchangeServer, Get-SiteMailbox).
    These are backed by the customer's exported XML files and are tracked in the 
    $script:FunctionRegistry hashtable.

    Remove-DiscoveryFunctions cleans up those functions by:
      - Enumerating all entries in $script:FunctionRegistry for the given customer
      - Removing each Get-* shim from the global function scope
      - Removing the corresponding entries from $script:FunctionRegistry

    The customer record in $script:CustomerRegistry is NOT removed; only the functions. #>
function Remove-DiscoveryFunctions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CustomerName)

    $items = $script:FunctionRegistry.GetEnumerator() |
             Where-Object { $_.Value.Customer -eq $CustomerName } |
             ForEach-Object { $_ }   # materialize

    foreach ($kv in $items) {
        $fn = $kv.Key

        # Remove any alias with the same name
        if (Get-Alias -Name $fn -ErrorAction SilentlyContinue) {
            Remove-Item -Path ("alias:\{0}" -f $fn) -Force -ErrorAction SilentlyContinue
        }

        # Remove the function (both generic and explicit global path just in case)
        foreach ($path in @("function:\$fn","function:\global:\$fn")) {
            if (Test-Path $path) { Remove-Item -Path $path -Force -ErrorAction SilentlyContinue }
        }

        # Drop from the registry
        $null = $script:FunctionRegistry.Remove($fn)
    }
}


function global:Get-DiscoveryOrgName {
    <#
      Tries to get the org name from an *OrganizationConfig* XML in the dataset.
      Prefers CliXML property (.Name / .Identity / .OrganizationId). Falls back to raw XML nodes
      or the filename token before "-OrganizationConfig".
      Returns the org token WITHOUT stripping hyphens or dots (e.g., 'contoso-banking').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    # Pick the most recent OrganizationConfig file if multiple exist
    $orgFile = Get-ChildItem -Path $Path -File -Filter *OrganizationConfig*.xml -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1

    if (-not $orgFile) {
        Write-Verbose "No *OrganizationConfig*.xml found under: $Path"
        return $null
    }
    Write-Verbose ("Using OrganizationConfig file: {0}" -f $orgFile.FullName)

    # 1) Try CliXML
    try {
        $obj = Import-Clixml -Path $orgFile.FullName -ErrorAction Stop | Select-Object -First 1
        foreach ($prop in 'Name','Identity','OrganizationId') {
            $val = $obj.$prop
            if ($null -ne $val) {
                $tok = Convert-ToOrgToken -InputString ($val.ToString())
                if ($tok) {
                    Write-Verbose ("Found org token via CliXML property '{0}': {1}" -f $prop, $tok)
                    return $tok
                }
            }
        }
    } catch {
        Write-Verbose ("CliXML import failed; will try raw XML. Error: {0}" -f $_.Exception.Message)
    }

    # 2) Try raw XML nodes
    try {
        [xml]$raw = Get-Content -Path $orgFile.FullName -Raw -ErrorAction Stop
        $nodes = $raw.SelectNodes('//*[local-name()="Name" or local-name()="Identity" or local-name()="OrganizationId"]')
        foreach ($n in $nodes) {
            $tok = Convert-ToOrgToken -InputString $n.InnerText
            if ($tok) {
                Write-Verbose ("Found org token via raw XML node '{0}': {1}" -f $n.Name, $tok)
                return $tok
            }
        }
    } catch {
        Write-Verbose ("Raw XML parse failed; will try filename. Error: {0}" -f $_.Exception.Message)
    }

    # 3) Fallback: parse filename before "-OrganizationConfig"
    $m = [regex]::Match($orgFile.BaseName, '^(?<org>.+?)-OrganizationConfig$', 'IgnoreCase')
    if ($m.Success) {
        $tok = (Convert-ToOrgToken -InputString $m.Groups['org'].Value)
        if ($tok) {
            Write-Verbose ("Found org token via filename: {0}" -f $tok)
            return $tok
        }
    }

    Write-Verbose "No org token could be derived."
    return $null
}

function global:Load-Customer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$CustomerName,
        [switch]$EXO,
        [switch]$OnPrem
    )

    if (-not $script:CustomerRegistry.ContainsKey($CustomerName)) {
        throw "Customer $CustomerName not registered. Run Import-DiscoveryScriptResults first."
    }

    $entry = $script:CustomerRegistry[$CustomerName]
    $tag = if ($EXO) { 'EXO' } elseif ($OnPrem) { 'OnPrem' } else { $entry.Tag }

    if ($entry.Tag -ne 'Unspecified' -and $tag -ne $entry.Tag) {
        throw "$CustomerName is tagged as $($entry.Tag), not $tag."
    }

    $path = $entry.Path
    if (-not (Test-Path $path -PathType Container)) {
        throw "Dataset path not found: $path"
    }

    # Detect org name from OrganizationConfig if available
    $orgName = Get-DiscoveryOrgName -Path $path

    # Gather XML files
    $xmlFiles = Get-ChildItem -Path $path -Filter *.xml -File -ErrorAction Stop
    if ($xmlFiles.Count -eq 0) {
        Write-Warning "No XML files found in $path"
        return
    }

    # Dynamic prefix detection from first file
    $firstFile = $xmlFiles | Select-Object -First 1
    $dynamicPrefix = $null
    if ($firstFile.BaseName -match '-') {
        $dynamicPrefix = ($firstFile.BaseName -split '[-_.]')[0]
    }

    # Build regex for stripping prefixes
    $prefixes = @('Exchange','Get')
    if ($dynamicPrefix) { $prefixes += [regex]::Escape($dynamicPrefix) }
    if ($orgName) { $prefixes += [regex]::Escape($orgName) }
    $prefixRegex = '^(?i:(?:' + ($prefixes -join '|') + '))-'

    foreach ($file in $xmlFiles) {
        # Derive clean noun using dynamic prefix
        $base    = $file.BaseName -replace $prefixRegex, ''
        $primary = ($base -split '[-_.]')[0]
        $noun    = ($primary -replace '[^A-Za-z0-9]', '')
        if ([string]::IsNullOrWhiteSpace($noun)) { continue }

        $funcName = "Get-$noun"
        $filePath = $file.FullName
        $fnPath   = "function:global:$funcName"

        $wrapper = {
            param(
                [Parameter(Position=0)] [string]$Name,
                [string]$Identity,
                [string]$DisplayName,
                [string]$DistinguishedName,
                [string]$Guid,
                [string]$Server,
                [string]$Database,
                [string]$Policy,
                [string]$Alias,
                [string]$SamAccountName,
                [string]$UserPrincipalName,
                [string]$ExternalDirectoryObjectId,
                [string]$PrimarySmtpAddress,
                [string]$WindowsEmailAddress,
                [string]$LegacyExchangeDN,
                [string]$RecipientType,
                [string]$RecipientTypeDetails,
                [string]$OrganizationalUnit,
                [string]$CustomAttribute1,
                [string]$CustomAttribute2,
                [string]$CustomAttribute3,
                [string]$CustomAttribute4,
                [string]$CustomAttribute5,
                [string]$CustomAttribute6,
                [string]$CustomAttribute7,
                [string]$CustomAttribute8,
                [string]$CustomAttribute9,
                [string]$CustomAttribute10,
                [string]$CustomAttribute11,
                [string]$CustomAttribute12,
                [string]$CustomAttribute13,
                [string]$CustomAttribute14,
                [string]$CustomAttribute15,
                [string]$City,
                [string]$StateOrProvince,
                [string]$CountryOrRegion,
                [string]$Department,
                [string]$Company,
                [string]$Office,
                [string]$Title,
                [string]$FirstName,
                [string]$LastName,
                [string]$Initials,
                [string]$Id,
                [string]$AddressBookPolicy,
                [string]$RetentionPolicy,
                [string]$OwaMailboxPolicy,
                [string]$MobileDeviceMailboxPolicy,
                [string]$ThrottlingPolicy,
                [string]$SharingPolicy,
                [string]$RoleGroup,
                [string]$Role,
                [string]$ArchiveGuid,
                [string]$ArchiveDatabase,
                [string]$ObjectCategory,
                [string]$ObjectClass,
                [string]$WhenCreated,
                [string]$WhenChanged,
                [string]$ProhibitSendQuota,
                [string]$IssueWarningQuota,
                [string]$ProhibitSendReceiveQuota,
                [string]$LitigationHoldEnabled,
                [string]$LitigationHoldDuration,
                [string]$EmailAddresses,
                [int]$First,
                [int]$Skip,
                [string]$SortBy,
                [string]$ArchiveStatus,
                [string]$ArchiveName,
                [string]$AuditEnabled,
                [string]$AuditLogAgeLimit,
                [string]$BypassModerationFromSendersOrMembers,
                [string]$CalendarLoggingQuota,
                [string]$CalendarRepairDisabled,
                [string]$DeliverToMailboxAndForward,
                [string]$ForwardingAddress,
                [string]$ForwardingSmtpAddress,
                [string]$HiddenFromAddressListsEnabled,
                [string]$IsMailboxEnabled,
                [string]$MailboxProvisioningConstraint,
                [string]$MailboxRegion,
                [string]$MailboxMoveStatus,
                [string]$MailboxMoveTargetDatabase,
                [string]$MailboxMoveFlags,
                [string]$MailboxPlan,
                [string]$MailboxSize,
                [string]$MaxSendSize,
                [string]$MaxReceiveSize,
                [string]$ModerationEnabled,
                [string]$ModeratedBy,
                [string]$MessageCopyForSentAsEnabled,
                [string]$MessageCopyForSendOnBehalfEnabled,
                [string]$MicrosoftOnlineServicesID,
                [string]$ObjectId,
                [string]$OfficePhone,
                [string]$Phone,
                [string]$PostalCode,
                [string]$RecipientLimits,
                [string]$RejectMessagesFrom,
                [string]$RejectMessagesFromDLMembers,
                [string]$RequireSenderAuthenticationEnabled,
                [string]$ResourceCapacity,
                [string]$ResourceCustom,
                [string]$ResourceDelegates,
                [string]$ResourceType,
                [string]$RetentionComment,
                [string]$RetentionUrl,
                [string]$RulesQuota,
                [string]$SecondaryAddress,
                [string]$SendModerationNotifications,
                [string]$SimpleDisplayName,
                [string]$SingleItemRecoveryEnabled,
                [string]$StsRefreshTokensValidFrom,
                [string]$UMEnabled,
                [string]$UserPhoto,
                [string]$WhenMailboxCreated,
                [string]$WindowsLiveID,
                [string]$ArchiveQuota,
                [string]$ArchiveWarningQuota,
                [string]$ExchangeGuid,
                [string]$ImmutableId,
                [string]$IsDirSynced
            )

            function Invoke-Import {
                param([string]$Path)
                try { Import-Clixml -Path $Path -ErrorAction Stop }
                catch { Get-Content -Path $Path -Raw }
            }

            $data = Invoke-Import -Path $filePath
            if ($data -is [xml]) {
                if ($PSBoundParameters.Keys.Count -gt 0) {
                    throw "Filtering (-Name/-Identity/etc.) and pagination (-First/-Skip/-SortBy) aren’t available for raw XML files. Pipe to Select-Xml or re-export as CliXML."
                }
                return $data
            }

            $items = @($data)
            if ($items.Count -eq 0) { return $items }

            $propNames = $items[0].PSObject.Properties.Name
            $propSet   = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($p in $propNames) { [void]$propSet.Add($p) }

            $aliasMap = @{
                UPN         = 'UserPrincipalName'
                EDOID       = 'ExternalDirectoryObjectId'
                SMTP        = 'PrimarySmtpAddress'
                WindowsSMTP = 'WindowsEmailAddress'
                DN          = 'DistinguishedName'
                RT          = 'RecipientType'
                RTD         = 'RecipientTypeDetails'
                ABP         = 'AddressBookPolicy'
                OWA         = 'OwaMailboxPolicy'
                MDMP        = 'MobileDeviceMailboxPolicy'
                THROTTLE    = 'ThrottlingPolicy'
                EMail       = 'PrimarySmtpAddress'
            }

            $nonFilter = @('First','Skip','SortBy')

            foreach ($paramName in $PSBoundParameters.Keys) {
                if ($nonFilter -contains $paramName) { continue }
                $value = $PSBoundParameters[$paramName]
                if ($null -eq $value -or ($value -is [string] -and $value.Length -eq 0)) { continue }

                $prop = if ($aliasMap.ContainsKey($paramName)) { $aliasMap[$paramName] } else { $paramName }

                if (-not $propSet.Contains($prop)) {
                    $sample = ($propNames | Sort-Object | Select-Object -First 25) -join ', '
                    throw "You passed -$paramName but the objects don’t have a '$prop' property. Available properties include: $sample"
                }

                $items = $items | Where-Object {
                    $v = $_.$prop
                    if ($null -eq $v) { return $false }
                    if ($v -is [System.Array]) {
                        foreach ($el in $v) {
                            if ( ($el -is [string] -and $el -like $value) -or
                                 (-not ($el -is [string]) -and ($el.ToString() -like $value)) ) { return $true }
                        }
                        return $false
                    }
                    elseif ($v -is [string]) { return ($v -like $value) }
                    else { return ($v.ToString() -like $value) }
                }
            }

            if ($PSBoundParameters.ContainsKey('SortBy')) {
                if (-not $propSet.Contains($SortBy)) {
                    $sample = ($propNames | Sort-Object | Select-Object -First 25) -join ', '
                    throw "You passed -SortBy '$SortBy' but that property doesn’t exist. Available properties include: $sample"
                }
                $items = $items | Sort-Object -Property $SortBy
            }

            if ($PSBoundParameters.ContainsKey('Skip')  -and $Skip  -gt 0) { $items = $items | Select-Object -Skip  $Skip  }
            if ($PSBoundParameters.ContainsKey('First') -and $First -gt 0) { $items = $items | Select-Object -First $First }

            return $items
        }.GetNewClosure()

        if (Test-Path $fnPath) { Remove-Item $fnPath -ErrorAction SilentlyContinue }
        Set-Item $fnPath -Value $wrapper

        $script:FunctionRegistry[$funcName] = @{
            Path     = $filePath
            Customer = $CustomerName
            Tag      = $tag
            Year     = $script:CustomerRegistry[$CustomerName].Year
        }
    }

    Write-Host "Loaded   $CustomerName [$tag]" -NoNewline
    Write-Host ": $($xmlFiles.Count) functions created" `
        $(if($orgName){"(org prefix: $orgName)"}else{""})
}



function Get-DiscoveryIndex {
    [CmdletBinding()]
    param(
        [string]$CustomerName
    )
    if ($CustomerName) {
        $script:FunctionRegistry.GetEnumerator() |
            Where-Object { $_.Value.Customer -eq $CustomerName } |
            Sort-Object Key |
            ForEach-Object {
                [pscustomobject]@{
                    Function = $_.Key
                    Path     = $_.Value.Path
                    Customer = $_.Value.Customer
                    Tag      = $_.Value.Tag
                    Year     = $_.Value.Year
                }
            }
    } else {
        $script:FunctionRegistry.GetEnumerator() |
            Sort-Object Key |
            ForEach-Object {
                [pscustomobject]@{
                    Function = $_.Key
                    Path     = $_.Value.Path
                    Customer = $_.Value.Customer
                    Tag      = $_.Value.Tag
                    Year     = $_.Value.Year
                }
            }
    }
}

function global:Unload-Customer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CustomerName
    )

    $summary = Remove-DiscoveryFunctions -CustomerName $CustomerName

    if ($summary.KeysCleared -eq 0) {
        Write-Host "No shims found for '$CustomerName' to unload." -ForegroundColor Yellow
    } else {
        Write-Host ("Unloaded {0}: removed {1} functions ({2} already missing)" -f `
            $summary.Customer, $summary.Removed, $summary.Missing) -ForegroundColor Green
    }
}

function Get-Customer {
    <#
      Lists customers that have been imported with Import-DiscoveryScriptResults.
      Shows the name, dataset path, and tag (EXO / OnPrem / Unspecified).
    #>
    [CmdletBinding()]
    param(
        [string]$CustomerName
    )

    if ($script:CustomerRegistry.Count -eq 0) {
        Write-Warning "No customers registered. Use Import-DiscoveryScriptResults first."
        return
    }

    $results = @()

    foreach ($entry in $script:CustomerRegistry.GetEnumerator()) {
        if ($CustomerName -and $entry.Key -ne $CustomerName) { continue }

        $results += [pscustomobject]@{
            CustomerName = $entry.Key
            Path         = $entry.Value.Path
            Tag          = $entry.Value.Tag
            Year         = $entry.Value.Year
        }
    }

    if ($results.Count -eq 0 -and $CustomerName) {
        Write-Warning "Customer '$CustomerName' is not registered."
    }

    $results | Sort-Object CustomerName
}
