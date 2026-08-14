#Requires -Version 5.1

<#
Filesystem and statistics helpers.
#>

function Initialize-MFAReportOutputDirectory {
    <#
    .SYNOPSIS
    Creates the output directory if it does not exist.

    .DESCRIPTION
    Renamed from v0.10's Ensure-MFAReportOutputDirectory; Ensure is not an
    approved PowerShell verb.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) { return }

    if ($PSCmdlet.ShouldProcess($Path, 'Create output directory')) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-MFAReportMailbox {
    <#
    .SYNOPSIS
    Retrieves a mailbox, retrying transient service failures.

    .DESCRIPTION
    The per-mailbox lookup is the single most-issued call in a large run and so
    the most likely to be throttled. v0.10 called Get-Mailbox once and reported
    any failure as MailboxLookupFailed, which made a throttled call
    indistinguishable from a mailbox that does not exist.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'SoftDeletedMailbox is read inside the Invoke-MFAReportRetry scriptblock via dynamic scoping, which the analyzer does not follow. Covered by the soft-deleted integration test.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter()]
        [switch]$SoftDeletedMailbox,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 2
    )

    Invoke-MFAReportRetry -Operation "Get-Mailbox '$Identity'" -InitialDelaySeconds $RetryDelaySeconds -ScriptBlock {
        if ($SoftDeletedMailbox) {
            Get-Mailbox -Identity $Identity -SoftDeletedMailbox -ErrorAction Stop
        }
        else {
            Get-Mailbox -Identity $Identity -ErrorAction Stop
        }
    }
}

function Get-MFAReportMailboxStatistics {
    <#
    .SYNOPSIS
    Retrieves mailbox statistics, converting failure into a result rather than
    a terminating error.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Archive is read inside the Invoke-MFAReportRetry scriptblock via dynamic scoping, which the analyzer does not follow.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter()]
        [switch]$Archive,

        [Parameter()]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 2
    )

    try {
        $stats = Invoke-MFAReportRetry -Operation "Get-MailboxStatistics '$Identity'" `
            -InitialDelaySeconds $RetryDelaySeconds -ScriptBlock {
                if ($Archive) {
                    Get-MailboxStatistics -Identity $Identity -Archive -ErrorAction Stop
                }
                else {
                    Get-MailboxStatistics -Identity $Identity -ErrorAction Stop
                }
            }

        return [PSCustomObject]@{
            Success      = $true
            Statistics   = $stats
            ErrorMessage = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Success      = $false
            Statistics   = $null
            ErrorMessage = $_.Exception.Message
        }
    }
}

function Get-MFAReportTotalItemSizeBytes {
    <#
    .SYNOPSIS
    Extracts a byte count from a mailbox statistics TotalItemSize value.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Statistics
    )

    if ($null -eq $Statistics) { return $null }

    $totalItemSize = Get-MFAReportPropertyValue -InputObject $Statistics -Name 'TotalItemSize'
    if ($null -eq $totalItemSize) { return $null }

    # TotalItemSize is a ByteQuantifiedSize wrapper in EXO and a plain string in
    # some shapes; handle both without assuming .Value exists.
    $inner = Get-MFAReportPropertyValue -InputObject $totalItemSize -Name 'Value'
    $text = if ($null -ne $inner) { [string]$inner } else { [string]$totalItemSize }

    return Convert-MFAReportSizeToBytes -SizeString $text
}

function Export-MFAReportArtifact {
    <#
    .SYNOPSIS
    Writes a CSV artifact with an explicit encoding.

    .DESCRIPTION
    Windows PowerShell 5.1 defaults Export-Csv to ASCII, which mangles non-ASCII
    display names. v0.10 relied on that default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $records = @($InputObject | Where-Object { $null -ne $_ })
    if ($records.Count -eq 0) { return $null }

    $records | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8

    # Export-Csv honours -WhatIf, so a preview run writes nothing. The call is
    # left in place because the "What if:" line it prints is worth seeing; what
    # changes is the RESULT. Returning $Path regardless made callers announce
    # "report saved to <path>" and count an artifact for a file that does not
    # exist -- on exactly the preview step the README tells operators to run
    # first. Test-Path also catches a write that failed non-terminatingly: a
    # directory that was never created, or no permission to it.
    if ($WhatIfPreference -or -not (Test-Path -LiteralPath $Path)) { return $null }

    return $Path
}
