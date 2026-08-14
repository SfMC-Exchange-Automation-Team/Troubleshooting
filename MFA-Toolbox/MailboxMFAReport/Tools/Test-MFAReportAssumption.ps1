#Requires -Version 5.1
<#
.SYNOPSIS
Checks the Exchange Online assumptions MailboxMFAReport is built on. Read-only.

.DESCRIPTION
The module's 212 unit and integration tests run entirely against stubs. Those
stubs encode assumptions about what Exchange Online actually returns -- property
names, object shapes, identifier formats, parameter types. If an assumption is
wrong, every test still passes and the module still misbehaves against a real
tenant.

This script tests those assumptions directly, against one mailbox you nominate.
It issues only Get-* calls and reads cmdlet metadata; it changes nothing.

Run this BEFORE trusting any output from Get-MailboxMFAReadiness.

Results:
  PASS    the assumption holds
  FAIL    the assumption is wrong -- the named module behaviour will not work
  WARN    partially holds, or holds but with a caveat worth reading
  UNKNOWN could not be determined here (usually: nothing in the tenant to test against)
  SKIP    the relevant cmdlet is not available in this session

.PARAMETER Identity
A single mailbox to inspect. Choose one that is representative -- ideally one
with an archive, a retention policy, and at least one hold.

.PARAMETER RetentionPolicyName
Optional. A retention policy whose tag links should be inspected. Defaults to
whatever policy is assigned to -Identity.

.PARAMETER IncludePurview
Also check Purview assumptions. Requires a Security & Compliance connection and
issues Get-RetentionCompliancePolicy, which is slow on large tenants.

.EXAMPLE
.\Test-MFAReportAssumption.ps1 -Identity user@contoso.com

.EXAMPLE
.\Test-MFAReportAssumption.ps1 -Identity user@contoso.com -IncludePurview -Verbose
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive operator tool. The coloured console report is the point; the structured results are returned separately for capture.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Identity,

    [Parameter()]
    [string]$RetentionPolicyName,

    [Parameter()]
    [switch]$IncludePurview
)

$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$Area,
        [string]$Assumption,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'UNKNOWN', 'SKIP')]
        [string]$Result,
        [string]$Detail,
        [string]$Impact
    )
    $results.Add([PSCustomObject]@{
        Area       = $Area
        Assumption = $Assumption
        Result     = $Result
        Detail     = $Detail
        Impact     = $Impact
    })
}

function Test-Property {
    param($InputObject, [string[]]$Names, [string]$Area, [string]$Impact)
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -eq $property) {
            Add-Result -Area $Area -Assumption "$name exists" -Result 'FAIL' `
                -Detail 'Property not present on the returned object.' -Impact $Impact
        }
        else {
            $value = if ($null -eq $property.Value) { '<null>' } else { ([string]$property.Value) }
            if ($value.Length -gt 60) { $value = $value.Substring(0, 60) + '...' }
            Add-Result -Area $Area -Assumption "$name exists" -Result 'PASS' `
                -Detail "= $value" -Impact ''
        }
    }
}

Write-Host "Checking MailboxMFAReport assumptions against $Identity" -ForegroundColor Cyan
Write-Host 'This script is read-only.' -ForegroundColor DarkGray
Write-Host ''

# --- 1. Cmdlet availability -------------------------------------------------
$required = @(
    'Get-Mailbox', 'Get-MailboxStatistics', 'Get-OrganizationConfig',
    'Get-RetentionPolicy', 'Get-RetentionPolicyTag'
)
$optional = @(
    'Export-MailboxDiagnosticLogs', 'Get-MailboxFolderStatistics',
    'Start-ManagedFolderAssistant', 'Enable-Mailbox', 'Set-Mailbox',
    'Get-RetentionCompliancePolicy', 'Get-MgUser'
)

foreach ($name in $required) {
    if (Get-Command $name -ErrorAction SilentlyContinue) {
        Add-Result -Area 'Cmdlets' -Assumption "$name available" -Result 'PASS' -Detail '' -Impact ''
    }
    else {
        Add-Result -Area 'Cmdlets' -Assumption "$name available" -Result 'FAIL' `
            -Detail 'Not found in this session.' -Impact 'Module preflight will refuse to run.'
    }
}
foreach ($name in $optional) {
    $state = if (Get-Command $name -ErrorAction SilentlyContinue) { 'PASS' } else { 'SKIP' }
    Add-Result -Area 'Cmdlets' -Assumption "$name available" -Result $state `
        -Detail '' -Impact $(if ($state -eq 'SKIP') { 'Related feature degrades or is unavailable.' } else { '' })
}

# --- 2. Set-Mailbox -AutoExpandingArchive parameter type --------------------
# Read from metadata, never invoked. The module calls it as a switch.
$setMailbox = Get-Command Set-Mailbox -ErrorAction SilentlyContinue
if ($setMailbox) {
    $parameter = $setMailbox.Parameters['AutoExpandingArchive']
    if ($null -eq $parameter) {
        Add-Result -Area 'Remediation' -Assumption 'Set-Mailbox has -AutoExpandingArchive' -Result 'FAIL' `
            -Detail 'Parameter not found.' -Impact 'Repair-MailboxMFAPrerequisite -EnableAutoExpandingArchive will fail.'
    }
    elseif ($parameter.ParameterType -eq [switch]) {
        Add-Result -Area 'Remediation' -Assumption '-AutoExpandingArchive is a switch' -Result 'PASS' `
            -Detail 'SwitchParameter, as the module assumes.' -Impact ''
    }
    else {
        Add-Result -Area 'Remediation' -Assumption '-AutoExpandingArchive is a switch' -Result 'FAIL' `
            -Detail "Actual type: $($parameter.ParameterType.Name)" `
            -Impact 'Repair-MFAReportAutoExpandingArchive must pass a value instead of a bare switch.'
    }
}
else {
    Add-Result -Area 'Remediation' -Assumption '-AutoExpandingArchive is a switch' -Result 'SKIP' -Detail '' -Impact ''
}

# --- 3. Mailbox object shape ------------------------------------------------
$mailbox = $null
try {
    $mailbox = Get-Mailbox -Identity $Identity -ErrorAction Stop
    Add-Result -Area 'Mailbox' -Assumption 'Get-Mailbox resolves the identity' -Result 'PASS' -Detail '' -Impact ''
}
catch {
    Add-Result -Area 'Mailbox' -Assumption 'Get-Mailbox resolves the identity' -Result 'FAIL' `
        -Detail $_.Exception.Message -Impact 'Nothing else can be checked.'
}

if ($mailbox) {
    Test-Property -InputObject $mailbox -Area 'Mailbox' -Impact 'Readiness evaluation reads this.' -Names @(
        'UserPrincipalName', 'RecipientTypeDetails', 'ArchiveState', 'AutoExpandingArchiveEnabled',
        'RetentionPolicy', 'RetentionHoldEnabled', 'LitigationHoldEnabled', 'ElcProcessingDisabled',
        'InPlaceHolds', 'RecoverableItemsQuota', 'RecoverableItemsWarningQuota'
    )

    # Optional properties: absence is tolerated by design, but worth knowing.
    foreach ($name in @('IsInactiveMailbox', 'RemoteRecipientType', 'SKUAssigned', 'DisplayName', 'Alias', 'LegacyExchangeDN')) {
        $exists = $null -ne $mailbox.PSObject.Properties[$name]
        Add-Result -Area 'Mailbox (optional)' -Assumption "$name exists" `
            -Result $(if ($exists) { 'PASS' } else { 'WARN' }) `
            -Detail $(if ($exists) { "= $($mailbox.$name)" } else { 'Absent; safe accessor returns $null.' }) `
            -Impact $(if ($exists) { '' } else { 'Related edge-case detection or Purview identity matching is weaker.' })
    }

    # --- 4. Hold identifier format -----------------------------------------
    $holds = @($mailbox.InPlaceHolds | Where-Object { $_ })
    if ($holds.Count -eq 0) {
        Add-Result -Area 'Holds' -Assumption 'Hold ids embed a 32-hex policy GUID' -Result 'UNKNOWN' `
            -Detail 'This mailbox has no InPlaceHolds entries.' `
            -Impact 'Re-run against a mailbox that is on hold to validate hold decoding.'
    }
    else {
        foreach ($hold in $holds) {
            $body = ([string]$hold).Trim() -replace '^-', '' -replace ':\d+$', '' `
                -replace '^(mbx|skp|grp|cld|UniH)', '' -replace '[{}\-]', ''
            if ($body -match '^[0-9a-fA-F]{32}$') {
                Add-Result -Area 'Holds' -Assumption "Hold id '$hold' yields a GUID" -Result 'PASS' `
                    -Detail "GUID = $($body.ToLowerInvariant())" -Impact ''
            }
            else {
                Add-Result -Area 'Holds' -Assumption "Hold id '$hold' yields a GUID" -Result 'FAIL' `
                    -Detail "Remainder after decoding: '$body'" `
                    -Impact 'Hold-to-policy naming and Confirmed Purview matching will not fire for this shape.'
            }
        }
    }

    # --- 5. TotalItemSize shape --------------------------------------------
    try {
        $stats = Get-MailboxStatistics -Identity $Identity -ErrorAction Stop
        $totalItemSize = $stats.PSObject.Properties['TotalItemSize']
        if ($null -eq $totalItemSize) {
            Add-Result -Area 'Statistics' -Assumption 'TotalItemSize exists' -Result 'FAIL' `
                -Detail '' -Impact 'Size deltas and the 10 MB small-mailbox check will not work.'
        }
        else {
            $text = [string]$totalItemSize.Value
            $hasBytes = $text -match '\(([\d,]+)\s+bytes\)'
            Add-Result -Area 'Statistics' -Assumption 'TotalItemSize renders "(N bytes)"' `
                -Result $(if ($hasBytes) { 'PASS' } else { 'WARN' }) -Detail "= $text" `
                -Impact $(if ($hasBytes) { '' } else { 'Falls back to unit parsing; verify the value is still read correctly.' })
        }
        Test-Property -InputObject $stats -Names @('ItemCount') -Area 'Statistics' -Impact 'Item deltas depend on this.'
    }
    catch {
        Add-Result -Area 'Statistics' -Assumption 'Get-MailboxStatistics succeeds' -Result 'FAIL' `
            -Detail $_.Exception.Message -Impact 'Readiness reports MailboxStatisticsFailed.'
    }
}

# --- 6. Organization config -------------------------------------------------
try {
    $organizationConfig = Get-OrganizationConfig -ErrorAction Stop
    foreach ($name in @('InPlaceHolds', 'AutoExpandingArchiveEnabled', 'ElcProcessingDisabled')) {
        $exists = $null -ne $organizationConfig.PSObject.Properties[$name]
        Add-Result -Area 'OrganizationConfig' -Assumption "$name exists" `
            -Result $(if ($exists) { 'PASS' } else { 'WARN' }) `
            -Detail $(if ($exists) { "= $($organizationConfig.$name)" } else { 'Absent; the related org-level check is skipped.' }) `
            -Impact $(if ($exists) { '' } else { 'Org-level gate silently does not apply.' })
    }
}
catch {
    Add-Result -Area 'OrganizationConfig' -Assumption 'Get-OrganizationConfig succeeds' -Result 'FAIL' `
        -Detail $_.Exception.Message -Impact 'Used as the connectivity probe; the module will refuse to run.'
}

# --- 7. RetentionPolicyTagLinks stringification -----------------------------
# The single highest-risk assumption: v0.10's tag comparison was broken because
# these are ADObjectId objects, not strings. The module normalises by taking the
# trailing '/' segment. If that is wrong, tag validation misreports.
$policyName = if ($RetentionPolicyName) { $RetentionPolicyName }
              elseif ($mailbox) { [string]$mailbox.RetentionPolicy }
              else { $null }

if ([string]::IsNullOrWhiteSpace($policyName)) {
    Add-Result -Area 'Retention' -Assumption 'Tag links normalise to tag names' -Result 'UNKNOWN' `
        -Detail 'No retention policy to inspect.' -Impact 'Supply -RetentionPolicyName to validate.'
}
else {
    try {
        $policy = Get-RetentionPolicy -Identity $policyName -ErrorAction Stop
        $links = @($policy.RetentionPolicyTagLinks)
        if ($links.Count -eq 0) {
            Add-Result -Area 'Retention' -Assumption 'Tag links normalise to tag names' -Result 'UNKNOWN' `
                -Detail "Policy '$policyName' has no linked tags." -Impact ''
        }
        else {
            foreach ($link in ($links | Select-Object -First 3)) {
                $raw = [string]$link
                $normalised = if ($raw -match '/') { ($raw -split '/')[-1] } else { $raw }
                $resolves = $null -ne (Get-RetentionPolicyTag -Identity $normalised -ErrorAction SilentlyContinue)
                Add-Result -Area 'Retention' -Assumption "Link normalises to a resolvable tag name" `
                    -Result $(if ($resolves) { 'PASS' } else { 'FAIL' }) `
                    -Detail "raw='$raw' -> '$normalised'" `
                    -Impact $(if ($resolves) { '' } else { 'ConvertTo-MFAReportTagLinkName is wrong for this tenant; tag validation will misreport.' })
            }
        }
    }
    catch {
        Add-Result -Area 'Retention' -Assumption "Get-RetentionPolicy '$policyName' succeeds" -Result 'FAIL' `
            -Detail $_.Exception.Message -Impact 'Retention trigger validation cannot run.'
    }
}

# --- 8. Retention tag shape -------------------------------------------------
try {
    $tag = Get-RetentionPolicyTag -ErrorAction Stop | Select-Object -First 1
    if ($tag) {
        Test-Property -InputObject $tag -Area 'Retention tag' -Impact 'Trigger validation and tag applicability read these.' `
            -Names @('Name', 'Type', 'RetentionAction', 'AgeLimitForRetention', 'RetentionEnabled')
    }
}
catch {
    Add-Result -Area 'Retention tag' -Assumption 'Get-RetentionPolicyTag succeeds' -Result 'SKIP' `
        -Detail $_.Exception.Message -Impact ''
}

# --- 9. Diagnostic log shape ------------------------------------------------
if ((Get-Command Export-MailboxDiagnosticLogs -ErrorAction SilentlyContinue) -and $mailbox) {
    try {
        $log = Export-MailboxDiagnosticLogs -Identity $Identity -ComponentName MRM -ErrorAction Stop
        $property = @('MailboxLog', 'Log', 'Result', 'DiagnosticInfo') |
            Where-Object { $log.PSObject.Properties[$_] -and $log.PSObject.Properties[$_].Value } |
            Select-Object -First 1

        if ($property) {
            $text = [string]$log.$property
            Add-Result -Area 'Diagnostics' -Assumption 'Log text is on a known property' -Result 'PASS' `
                -Detail "Property '$property', $($text.Length) chars" -Impact ''

            $found = @('ELCLastSuccessTimestamp', 'ResourceUnhealthy', 'ELCItemCount', 'WorkCycleLag',
                       'StoreMaintenanceBacklog', 'DelayHoldApplied') |
                Where-Object { $text -match [regex]::Escape($_) }

            Add-Result -Area 'Diagnostics' -Assumption 'Expected signal names appear in the log' `
                -Result $(if ($found.Count -ge 2) { 'PASS' } elseif ($found.Count -ge 1) { 'WARN' } else { 'FAIL' }) `
                -Detail "Found: $(if ($found) { $found -join ', ' } else { 'none' })" `
                -Impact $(if ($found.Count -ge 2) { '' } else { 'DiagnosticParseConfidence will be Low; classification rests on very little.' })
        }
        else {
            Add-Result -Area 'Diagnostics' -Assumption 'Log text is on a known property' -Result 'WARN' `
                -Detail "Properties: $(($log.PSObject.Properties.Name | Select-Object -First 8) -join ', ')" `
                -Impact 'Falls back to Out-String; parsing may still work but is unverified.'
        }
    }
    catch {
        Add-Result -Area 'Diagnostics' -Assumption 'Export-MailboxDiagnosticLogs succeeds' -Result 'WARN' `
            -Detail $_.Exception.Message -Impact '-IncludeAssistantDiagnostics will report CollectionFailed.'
    }
}
else {
    Add-Result -Area 'Diagnostics' -Assumption 'Export-MailboxDiagnosticLogs usable' -Result 'SKIP' -Detail '' -Impact ''
}

# --- 10. Purview policy shape -----------------------------------------------
if ($IncludePurview) {
    if (Get-Command Get-RetentionCompliancePolicy -ErrorAction SilentlyContinue) {
        try {
            $compliancePolicy = Get-RetentionCompliancePolicy -ErrorAction Stop | Select-Object -First 1
            if ($compliancePolicy) {
                Test-Property -InputObject $compliancePolicy -Area 'Purview' `
                    -Impact 'Policy matching and preservation-lock detection read these.' `
                    -Names @('Name', 'Guid', 'ExchangeLocation', 'ExchangeLocationException', 'RestrictiveRetention')

                # Guid drives the Confirmed match tier. Without it, hold-based
                # confirmation silently never fires.
                $guid = $compliancePolicy.PSObject.Properties['Guid']
                if ($guid -and ([string]$guid.Value -replace '[{}\-]', '') -match '^[0-9a-fA-F]{32}$') {
                    Add-Result -Area 'Purview' -Assumption 'Policy Guid is a usable GUID' -Result 'PASS' `
                        -Detail "= $($guid.Value)" -Impact ''
                }
                else {
                    Add-Result -Area 'Purview' -Assumption 'Policy Guid is a usable GUID' -Result 'FAIL' `
                        -Detail "Value: $(if ($guid) { $guid.Value } else { '<absent>' })" `
                        -Impact 'Confirmed Purview matching and hold-to-policy naming will never fire.'
                }
            }
            else {
                Add-Result -Area 'Purview' -Assumption 'Retention compliance policies exist' -Result 'UNKNOWN' `
                    -Detail 'Tenant returned none.' -Impact ''
            }
        }
        catch {
            Add-Result -Area 'Purview' -Assumption 'Get-RetentionCompliancePolicy succeeds' -Result 'WARN' `
                -Detail $_.Exception.Message -Impact '-IncludePurviewDetails will report a lookup failure.'
        }
    }
    else {
        Add-Result -Area 'Purview' -Assumption 'Get-RetentionCompliancePolicy available' -Result 'SKIP' `
            -Detail 'Connect-IPPSSession first.' -Impact ''
    }
}

# --- Report -----------------------------------------------------------------
Write-Host ''
$results | Format-Table Area, Assumption, Result, Detail -AutoSize -Wrap | Out-String -Width 200 | Write-Host

$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
$warned = @($results | Where-Object { $_.Result -eq 'WARN' })
$unknown = @($results | Where-Object { $_.Result -eq 'UNKNOWN' })

Write-Host ("PASS {0}   FAIL {1}   WARN {2}   UNKNOWN {3}   SKIP {4}" -f
    @($results | Where-Object { $_.Result -eq 'PASS' }).Count,
    $failed.Count, $warned.Count, $unknown.Count,
    @($results | Where-Object { $_.Result -eq 'SKIP' }).Count) -ForegroundColor Cyan

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host 'BROKEN ASSUMPTIONS - fix these before trusting module output:' -ForegroundColor Red
    foreach ($item in $failed) {
        Write-Host ("  [{0}] {1}" -f $item.Area, $item.Assumption) -ForegroundColor Red
        Write-Host ("      {0}" -f $item.Detail) -ForegroundColor DarkGray
        if ($item.Impact) { Write-Host ("      Impact: {0}" -f $item.Impact) -ForegroundColor Yellow }
    }
}
else {
    Write-Host 'No broken assumptions detected.' -ForegroundColor Green
}

if ($unknown.Count -gt 0) {
    Write-Host ''
    Write-Host 'UNVERIFIED - re-run against a mailbox that exercises these:' -ForegroundColor Yellow
    foreach ($item in $unknown) {
        Write-Host ("  [{0}] {1} - {2}" -f $item.Area, $item.Assumption, $item.Detail) -ForegroundColor DarkGray
    }
}

return $results
