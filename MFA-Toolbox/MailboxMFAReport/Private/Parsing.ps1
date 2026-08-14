#Requires -Version 5.1

<#
Primitive parsing helpers.

Design rule for this file: every function returns $null when it cannot determine
an answer, and never guesses. Callers must distinguish "known false" from
"unknown" -- conflating the two is what produced the false-positive
classifications in v0.10.
#>

function Get-MFAReportPropertyValue {
    <#
    .SYNOPSIS
    Safely reads a property that may not exist on an Exchange Online object.

    .DESCRIPTION
    Exchange Online object shapes vary by cmdlet version and tenant. Under
    Set-StrictMode, dereferencing an absent property throws. This accessor makes
    every optional property read strict-safe and returns $null when absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }

    return $property.Value
}

function ConvertTo-MFAReportBoolean {
    <#
    .SYNOPSIS
    Parses a diagnostic-log flag into $true, $false, or $null (undetermined).

    .DESCRIPTION
    v0.10 tested these values with -match 'true|1', an unanchored substring
    match. That returns $true for '01/01/2024' (contains '1') and for 'Untrue'
    (contains 'true'). This function anchors the match so only a whole-value
    match counts, and returns $null rather than $false when the value is absent
    or unrecognised.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $trimmed = $Value.Trim()
    if ($trimmed -match '^(true|1|yes|enabled)$') { return $true }
    if ($trimmed -match '^(false|0|no|disabled)$') { return $false }

    return $null
}

function ConvertTo-MFAReportTimeSpan {
    <#
    .SYNOPSIS
    Parses a duration-shaped diagnostic value, or returns $null.

    .DESCRIPTION
    Deliberately does not guess units for a bare number. A lag reported as '5'
    could be seconds, minutes, or work cycles; reporting it as undetermined and
    surfacing the raw value is more useful than inventing a unit.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $trimmed = $Value.Trim()

    # [TimeSpan]::TryParse('5') succeeds and yields FIVE DAYS. A WorkCycleLag
    # reported as a bare number would therefore read as a multi-day lag and
    # classify a healthy mailbox as throttled. Require a colon so only genuinely
    # duration-shaped values are parsed.
    if ($trimmed -notmatch ':') { return $null }

    $parsed = [TimeSpan]::Zero
    if ([TimeSpan]::TryParse($trimmed, [ref]$parsed)) { return $parsed }

    return $null
}

function ConvertTo-MFAReportCount {
    <#
    .SYNOPSIS
    Parses a whole-number diagnostic value, or returns $null.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parsed = [long]0
    if ([long]::TryParse(($Value.Trim() -replace ',', ''), [ref]$parsed)) { return $parsed }

    return $null
}

function Convert-MFAReportSizeToBytes {
    <#
    .SYNOPSIS
    Converts an Exchange size string to bytes, or returns $null when unknown.

    .DESCRIPTION
    Exchange renders sizes as '1.234 GB (1,325,400,064 bytes)'. This reads the
    parenthesised byte count when present and falls back to a unit-suffixed
    value otherwise.

    Unlike v0.10 this returns the FIRST match rather than the sum of all
    matches. Summing was what allowed Get-MailboxFolderStatistics output to be
    double-counted, because FolderAndSubfolderSize is cumulative and appears
    once per folder in the nested hierarchy.

    'Unlimited' returns $null (undetermined), not 0, so an unlimited quota is
    never mistaken for a zero-byte quota.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SizeString
    )

    if ([string]::IsNullOrWhiteSpace($SizeString)) { return $null }

    $trimmed = $SizeString.Trim()
    if ($trimmed -match '^unlimited$') { return $null }

    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    $byteMatch = [regex]::Match($trimmed, '\(([\d,]+)\s+bytes\)', $ignoreCase)
    if ($byteMatch.Success) {
        return [long]($byteMatch.Groups[1].Value -replace ',', '')
    }

    $unitMatch = [regex]::Match($trimmed, '^([\d,]+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)$', $ignoreCase)
    if ($unitMatch.Success) {
        $value = [double]($unitMatch.Groups[1].Value -replace ',', '')
        $multiplier = switch ($unitMatch.Groups[2].Value.ToUpperInvariant()) {
            'B'  { 1L }
            'KB' { 1024L }
            'MB' { 1024L * 1024 }
            'GB' { 1024L * 1024 * 1024 }
            'TB' { 1024L * 1024 * 1024 * 1024 }
        }
        return [long]($value * $multiplier)
    }

    return $null
}

function ConvertTo-MFAReportText {
    <#
    .SYNOPSIS
    Flattens an Export-MailboxDiagnosticLogs result into searchable text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return '' }

    foreach ($propertyName in @('MailboxLog', 'Log', 'Result', 'DiagnosticInfo')) {
        $value = Get-MFAReportPropertyValue -InputObject $InputObject -Name $propertyName
        if ($value) { return [string]$value }
    }

    return ($InputObject | Out-String)
}

function Select-MFAReportRegexValue {
    <#
    .SYNOPSIS
    Returns the first capture group matched by any of the supplied patterns.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    foreach ($pattern in $Patterns) {
        $match = [regex]::Match($Text, $pattern, $ignoreCase)
        if ($match.Success -and $match.Groups.Count -gt 1) {
            $value = $match.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
    }

    return $null
}

function Select-MFAReportRegexFlag {
    <#
    .SYNOPSIS
    Extracts a named flag's raw value from diagnostic text.

    .DESCRIPTION
    Renamed from v0.10's Test-MFAReportRegexFlag. The Test- verb implies a
    boolean return; this returns the raw string value so the caller can decide
    how to interpret it (see ConvertTo-MFAReportBoolean).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return Select-MFAReportRegexValue -Text $Text -Patterns @(
        "<$Name>\s*([^<]+)\s*</$Name>"
        "\b$Name\s*[:=]\s*([^;\r\n<]+)"
        """$Name""\s*:\s*""?([^"",}\r\n]+)""?"
    )
}
