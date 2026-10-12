Set-StrictMode -Version Latest

<#
    Remembers case numbers and affected users between runs.

    An engineer collecting for the same incident twice in a day should not have to
    retype a sixteen-digit case number, and mistyping one silently mislabels the
    evidence rather than failing.

    WHERE THIS WRITES, AND WHY IT MATTERS

    A case number and an affected user are customer data. They are kept in the running
    user's own profile - %LOCALAPPDATA%\TLC-Toolbox - not in the toolbox folder, for
    two reasons that both bite in practice:

      - The toolbox is routinely run from a share or a OneDrive folder. Writing history
        beside the scripts would put one customer's case numbers where the next
        engineer, or another customer, can read them.
      - LOCALAPPDATA does not roam, so the history does not follow the profile onto
        another machine.

    It is deliberately NOT written into a run folder or anywhere the packager can see.
    The bundle is handed to a customer, and a list of other customers' case numbers is
    exactly the kind of thing that must never travel with it.

    The file is plain JSON. There is no attempt to encrypt it: it sits in the user's own
    profile, protected by the same ACL as everything else there, and pretending
    otherwise would be security theatre. What the tool does offer is a visible way to
    remove an entry or clear the lot, because the honest answer to "where did my case
    numbers go" has to be "here, and here is the button that deletes them".
#>

function Get-TlcHistoryPath {
    <#
    .SYNOPSIS
        Resolves the case history file, creating its folder on demand.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Root)

    if (-not $Root) {
        $Root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'TLC-Toolbox'
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        $null = New-Item -ItemType Directory -Path $Root -Force
    }

    return (Join-Path $Root 'CaseHistory.json')
}

function Get-TlcCaseHistory {
    <#
    .SYNOPSIS
        Reads remembered cases, most recently used first.
    .DESCRIPTION
        A corrupt or hand-edited file returns an empty list rather than throwing. This
        is a convenience feature; it must never be the reason the wizard fails to open.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string] $Path)

    if (-not $Path) { $Path = Get-TlcHistoryPath }
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

        # ConvertFrom-Json on Windows PowerShell 5.1 emits a JSON array as a single
        # object[] down the pipeline rather than as separate objects, so @(...) wraps
        # the array instead of unrolling it and the result is one element whose members
        # are the real entries. Every entry then failed the CaseNumber property check
        # and the whole history read back as empty - a file that was written correctly
        # and could never be loaded. Unrolling explicitly works on both hosts.
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $entries = if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
            @($parsed | ForEach-Object { $_ })
        } else {
            @($parsed)
        }
    } catch {
        Write-Verbose "Case history could not be read, so it is treated as empty: $($_.Exception.Message)"
        return @()
    }

    $clean = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        if (-not $entry) { continue }
        if (-not $entry.PSObject.Properties['CaseNumber']) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$entry.CaseNumber)) { continue }

        $user = if ($entry.PSObject.Properties['AffectedUser']) { [string]$entry.AffectedUser } else { '' }
        $used = if ($entry.PSObject.Properties['LastUsedUtc']) { [string]$entry.LastUsedUtc } else { '' }

        $clean.Add([pscustomobject]@{
            CaseNumber   = ([string]$entry.CaseNumber).Trim()
            AffectedUser = $user.Trim()
            LastUsedUtc  = $used
        })
    }

    return @($clean | Sort-Object -Property LastUsedUtc -Descending)
}

function Save-TlcCaseHistory {
    <#
    .SYNOPSIS
        Writes the history file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Entry,
        [string] $Path
    )

    if (-not $Path) { $Path = Get-TlcHistoryPath }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write case history')) { return }

    try {
        # An empty array converts to "" rather than "[]" on Windows PowerShell 5.1, and
        # a file containing "" is then read back as a single empty entry. Writing the
        # literal brackets keeps a cleared history readable as a cleared history.
        $json = if (@($Entry).Count -eq 0) { '[]' } else { @($Entry) | ConvertTo-Json -Depth 3 }

        # Written beside the file and swapped in, not rewritten in place. A second wizard
        # reading it mid-write got half a file, read that as an empty history, and its next
        # save wrote the emptiness back (review 2026-09-30, finding 331). A swap that cannot
        # be made falls back to the direct write this always did.
        $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            # With a BOM, as Set-Content -Encoding UTF8 wrote it on Windows PowerShell 5.1:
            # Get-Content there reads a BOM-less file through the ANSI codepage.
            [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($true)))
            # [NullString]::Value, not $null, for the backup name: PowerShell hands $null to a .NET
            # string parameter as an empty string, and Replace then fails on "The path is empty".
            $swapped = $false
            for ($attempt = 0; $attempt -lt 5 -and -not $swapped; $attempt++) {
                try {
                    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) } else { [System.IO.File]::Move($temp, $Path) }
                    $swapped = $true
                } catch {
                    Start-Sleep -Milliseconds 50
                }
            }
            if (-not $swapped) { [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true))) }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Verbose "Case history could not be written: $($_.Exception.Message)"
    }
}

function Add-TlcCaseHistoryEntry {
    <#
    .SYNOPSIS
        Records a case number, moving an existing one back to the top.
    .DESCRIPTION
        Matching is case-insensitive and ignores surrounding whitespace, so the same
        case pasted twice with a trailing space does not become two entries.

        The list is capped. This is a convenience, not an archive, and an unbounded file
        of customer case numbers accumulating in a profile is a liability rather than a
        feature.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $CaseNumber,
        [AllowEmptyString()] [string] $AffectedUser = '',
        [string] $Path,
        [int] $Maximum = 15
    )

    if ([string]::IsNullOrWhiteSpace($CaseNumber)) { return @(Get-TlcCaseHistory -Path $Path) }

    $case = $CaseNumber.Trim()
    $user = $AffectedUser.Trim()

    $history = @(Get-TlcCaseHistory -Path $Path)
    $existing = @($history | Where-Object { $_.CaseNumber -ne $case })

    # Re-running an old case without retyping the user must not erase the user that was
    # recorded with it. Picking a remembered case is exactly when the box is blank, so
    # treating blank as "clear it" would delete the association on the first reuse - and
    # then quietly label the next bundle with no affected user at all.
    if (-not $user) {
        $previous = @($history | Where-Object { $_.CaseNumber -eq $case })
        if ($previous.Count -gt 0) { $user = [string]$previous[0].AffectedUser }
    }

    $entries = @(
        [pscustomobject]@{
            CaseNumber   = $case
            AffectedUser = $user
            LastUsedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        }
    ) + $existing

    if ($entries.Count -gt $Maximum) { $entries = @($entries[0..($Maximum - 1)]) }

    if ($PSCmdlet.ShouldProcess($case, 'Remember case number')) {
        Save-TlcCaseHistory -Entry $entries -Path $Path
    }
    return @($entries)
}

function Remove-TlcCaseHistoryEntry {
    <#
    .SYNOPSIS
        Forgets one case number, or all of them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [AllowEmptyString()] [string] $CaseNumber,
        [switch] $All,
        [string] $Path
    )

    if ($All) {
        if ($PSCmdlet.ShouldProcess('all remembered cases', 'Forget')) {
            Save-TlcCaseHistory -Entry @() -Path $Path
        }
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($CaseNumber)) { return @(Get-TlcCaseHistory -Path $Path) }

    $case = $CaseNumber.Trim()
    $remaining = @(Get-TlcCaseHistory -Path $Path | Where-Object { $_.CaseNumber -ne $case })

    if ($PSCmdlet.ShouldProcess($case, 'Forget case number')) {
        Save-TlcCaseHistory -Entry $remaining -Path $Path
    }
    return @($remaining)
}

Export-ModuleMember -Function Get-TlcHistoryPath, Get-TlcCaseHistory, Save-TlcCaseHistory,
    Add-TlcCaseHistoryEntry, Remove-TlcCaseHistoryEntry
