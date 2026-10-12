Set-StrictMode -Version Latest

# The identity scan reads account folder names out of client archives without extracting
# them, so this module owns the dependency rather than assuming a caller loaded it.
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

<#
    Privacy gate.

    Microsoft documents that a Teams client with multiple signed-in accounts emits
    diagnostics for all of them, regardless of tenant or cloud. On a customer
    endpoint that means a collection can sweep in identities from unrelated
    organisations, which is a disclosure problem in both directions.

    Grounding note, verified 2026-08-21: the rolling client logs this toolbox
    collects carry no UPNs and no tenant GUIDs - scanning three real MSTeams_*.log
    files returned zero matches for tenantId, orgid, a known tenant GUID, or any
    email address. The dependable signal is app_settings.json -> active_users,
    which lists one object id per signed-in account. The gate is therefore built on
    account ids that are actually present, not on tenant ids that are not.

    Support files and weblogs from the Prompted lane are a different matter: those
    are produced by the client itself and are documented to span accounts. Weblogs
    arrive as an archive, flagged by presence with only its entry names read; support
    files arrive as a folder whose file names carry account ids, which the name scan in
    Get-TlcIdentityInventory judges like any other (finding 331).
#>

$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:UpnPattern = '[A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# Compiled once and reused. The inventory scans several megabytes of log text, and
# the interpreted engine re-parsing these patterns per file was a measurable part of
# the packaging time. Compiled costs more to build and far less to run, which is the
# right trade when the same pattern meets megabytes of input.
$script:GuidRegex = [regex]::new($script:GuidPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)
$script:UpnRegex = [regex]::new($script:UpnPattern, [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Anchored form of the same pattern, used to validate a candidate that has already
# been located. See Find-TlcUpn for why the search is not done with UpnRegex.
$script:UpnAnchoredRegex = [regex]::new('^' + $script:UpnPattern + '$',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

$script:UpnLocalChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._%+'-"
$script:UpnDomainChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-'

# An account object id as Teams writes it into NAMES rather than contents: the web log
# archive's "User (Primary; <id>)" folders, and the MRI 8:orgid:<id> in the Support Logs
# folder's file names, where the colon is written #3A. Measured in a real Support Logs folder:
# CS_logs\CS_8#3Aorgid#3A<id>.conf and sc-tfw\skylib-users\user_orgid#3A<id>-0-<n>.blog.
# Review 2026-09-30, finding 331.
$script:NameAccountRegex = [regex]::new(
    '(?:^|[\\/])User \((?:Primary;\s*)?(' + $script:GuidPattern + ')\)|orgid(?::|#3A|%3A)(' + $script:GuidPattern + ')',
    [System.Text.RegularExpressions.RegexOptions]::Compiled -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# A JWT: three base64url segments, the first of which starts with the encoding of {"
# so every one of them begins 'eyJ'. Anchored on that literal so the engine can
# prefilter, for the reason set out in Find-TlcUpn.
$script:JwtRegex = [regex]::new('eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# A refresh token as JSON ("refresh_token":"1.AR...", escaped when the body is JSON inside a
# HAR string) or as form data (refresh_token=1.AR...). The redaction marker is excluded: it is long
# enough to look like a value, and the first run flagged its own redaction. Finding 312.
$script:RefreshRegex = [regex]::new('refresh_token\\?"\s*:\s*\\?"(?!REDACTED-BY-TLC)[^"\\]{20,}|refresh_token=(?!REDACTED-BY-TLC)[^&\s"\\]{20,}',
    [System.Text.RegularExpressions.RegexOptions]::Compiled)

# Extensions read as text by the identity scan. '.har' is here because the Web lane
# explicitly instructs the operator to export one into the bundle, and a HAR is JSON
# under a different name - it was being skipped entirely while being the single
# richest source of identity in any bundle this toolbox produces.
$script:ScannableExtensions = @('.log', '.json', '.txt', '.csv', '.md', '.har', '.xml', '.har.json')

function Find-TlcUpn {
    <#
    .SYNOPSIS
        Returns the distinct UPN-shaped strings in a block of text.
    .DESCRIPTION
        Measured on a real 9.8 MB collection, running UpnRegex over the text took
        4,986 ms and returned zero matches, while the GUID pattern over the same
        text took 1,329 ms. The difference is that the UPN pattern has no leading
        literal for the engine to prefilter on: it begins with a character class,
        so at every one of ten million positions the engine consumes a run of word
        characters before discovering there is no '@' after it. Teams logs are made
        almost entirely of long alphanumeric runs, which is the worst possible input
        for that shape.

        Anchoring the search on the '@' inverts the cost. String.IndexOf is
        vectorised, so finding the candidates is close to a memory scan, and the
        expensive pattern is then applied only to the handful of substrings that
        actually surround an '@'. Same results, 259 ms instead of 4,986 ms.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $found = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return $found }

    $length = $Text.Length
    # [char], not '@'. The string overload is a culture-sensitive search, and on PowerShell 7
    # that went through ICU: measured 3,625 ms against 133 ms over 41 MB of Teams logs holding
    # no '@' at all. Same answer, since '@' has no culture-sensitive equivalents. Finding 304.
    $at = $Text.IndexOf([char]'@')

    while ($at -ge 0) {
        # Widen left over local-part characters and right over domain characters,
        # then let the anchored pattern decide whether what we grabbed is a UPN.
        $start = $at
        while ($start -gt 0 -and $script:UpnLocalChars.IndexOf($Text[$start - 1]) -ge 0) { $start-- }

        $end = $at + 1
        while ($end -lt $length -and $script:UpnDomainChars.IndexOf($Text[$end]) -ge 0) { $end++ }

        if ($start -lt $at -and $end -gt ($at + 1)) {
            # A UPN at the end of a sentence picks up the full stop; the anchored
            # pattern would reject the whole candidate rather than the stray char.
            $candidate = $Text.Substring($start, $end - $start).TrimEnd('.', '-')
            if ($script:UpnAnchoredRegex.IsMatch($candidate)) { $found.Add($candidate) }
        }

        $next = [Math]::Max($end, $at + 1)
        if ($next -ge $length) { break }
        $at = $Text.IndexOf([char]'@', $next)
    }

    return $found
}

# The per-file text scan used by Get-TlcIdentityInventory, as a self-contained scriptblock so
# a runspace pool worker can run it with nothing from this module loaded. Everything it needs
# arrives as a parameter; the compiled Regex objects are shared across workers, which is safe
# because a Regex is immutable and its matching methods are thread-safe.
#
# The UPN search is Find-TlcUpn's algorithm restated inline for that reason. A test runs both
# over the same text and requires the same answer, so the two cannot drift.
$script:TextScanner = {
    param(
        [string[]] $Paths,
        [int] $MaxBytes,
        [regex] $GuidRegex,
        [regex] $UpnAnchored,
        [regex] $JwtRegex,
        [regex] $RefreshRegex,
        [string] $LocalChars,
        [string] $DomainChars
    )

    $upns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $guids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $credential = [System.Collections.Generic.List[string]]::new()
    $unreadable = [System.Collections.Generic.List[string]]::new()
    $partial = [System.Collections.Generic.List[string]]::new()
    $scanned = 0

    foreach ($path in $Paths) {
        # A file that cannot be opened is RECORDED, not skipped. Skipping it made the gate pass a
        # bundle it had not read: measured with a token-bearing file held under an exclusive lock
        # during the scan and released before the zip, the gate said Warning and the token would
        # have shipped. Finding 306.
        try {
            $stream = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        } catch {
            $unreadable.Add([System.IO.Path]::GetFileName($path))
            continue
        }

        # Streamed in chunks, whole file by default. The first version read at most 8 MB of each
        # file into memory and said nothing about the rest, and HAR exports - the likeliest place
        # for a token - are routinely larger. The limit existed to bound memory, and chunking
        # bounds memory without a limit. Finding 308.
        #
        # Chunks overlap, so a match that straddles a boundary is found in the next chunk: the
        # overlap is far longer than any address, id or token prefix the patterns need.
        #
        # The StreamReader decodes by byte-order mark (UTF-16 either way, UTF-8 with or without)
        # and carries a character split across a chunk boundary into the next read, which a
        # per-chunk GetString would corrupt. Finding 304 is why the mark matters.
        $scanned++
        $capped = $MaxBytes -gt 0
        if ($capped -and $stream.Length -gt $MaxBytes) { $partial.Add([System.IO.Path]::GetFileName($path)) }
        # A cap is counted in characters read, which equals bytes for the ASCII that logs are.
        $chunkChars = 4194304
        $remaining = if ($capped) { [int64]$MaxBytes } else { [int64]::MaxValue }
        $overlap = 65536
        $charBuffer = [char[]]::new($chunkChars)
        $tail = ''
        $tokenFound = $false
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 65536)
        try {
            while ($true) {
                $want = [int][Math]::Min([int64]$chunkChars, $remaining)
                if ($want -le 0) { break }
                $n = $reader.ReadBlock($charBuffer, 0, $want)
                $remaining -= $n
                if ($n -le 0) { break }
                $text = if ($tail.Length -gt 0) { $tail + [string]::new($charBuffer, 0, $n) } else { [string]::new($charBuffer, 0, $n) }

                # Addresses: anchored on '@', see Find-TlcUpn for why.
                $textLength = $text.Length
                $at = $text.IndexOf([char]'@')
                while ($at -ge 0) {
                    $start = $at
                    while ($start -gt 0 -and $LocalChars.IndexOf($text[$start - 1]) -ge 0) { $start-- }
                    $end = $at + 1
                    while ($end -lt $textLength -and $DomainChars.IndexOf($text[$end]) -ge 0) { $end++ }
                    if ($start -lt $at -and $end -gt ($at + 1)) {
                        $candidate = $text.Substring($start, $end - $start).TrimEnd('.', '-')
                        if ($UpnAnchored.IsMatch($candidate)) { $null = $upns.Add($candidate) }
                    }
                    $next = [Math]::Max($end, $at + 1)
                    if ($next -ge $textLength) { break }
                    $at = $text.IndexOf([char]'@', $next)
                }

                # Bearer tokens. A HAR captures request headers, so it carries live tokens as well
                # as identities, and a token is access to an account rather than information about
                # it. The file is named rather than the token recorded, for the obvious reason.
                #
                # Every JWT starts 'eyJ', so candidates are found with an ordinal search and the
                # pattern is tried only there: the regex alone took 9-25 s over 41 MB of logs on
                # PowerShell 7 with not one 'eyJ' in them, the ordinal search 72 ms.
                if (-not $tokenFound) {
                    $j = $text.IndexOf('eyJ', [StringComparison]::Ordinal)
                    while ($j -ge 0) {
                        $m = $JwtRegex.Match($text, $j)
                        if ($m.Success -and $m.Index -eq $j) { $credential.Add([System.IO.Path]::GetFileName($path)); $tokenFound = $true; break }
                        $j = $text.IndexOf('eyJ', $j + 3, [StringComparison]::Ordinal)
                    }
                }

                # Refresh tokens. Not JWT-shaped - an Entra refresh token is an opaque "1.ARoA..." -
                # so the check above cannot see one, and it is the longest-lived credential a HAR
                # carries. Measured on a real, SANITIZED Teams HAR (finding 312): the token endpoint's
                # response kept access_token, id_token AND refresh_token in its body, and the request
                # body kept refresh_token=... as form data. Both shapes, escaped or not.
                if (-not $tokenFound -and $text.IndexOf('refresh_token', [StringComparison]::Ordinal) -ge 0 -and $RefreshRegex.IsMatch($text)) {
                    $credential.Add([System.IO.Path]::GetFileName($path)); $tokenFound = $true
                }
                # Walked with Match/NextMatch so only the distinct values are kept.
                $match = $GuidRegex.Match($text)
                while ($match.Success) {
                    $null = $guids.Add($match.Value)
                    $match = $match.NextMatch()
                }

                $tail = if ($text.Length -gt $overlap) { $text.Substring($text.Length - $overlap) } else { $text }
                if ($n -lt $want) { break }
            }
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    }

    [pscustomobject]@{
        Scanned         = $scanned
        Upns            = @($upns)
        Guids           = @($guids)
        CredentialFiles = @($credential)
        UnreadableFiles = @($unreadable)
        PartialFiles    = @($partial)
    }
}

function Protect-TlcIdentifier {
    <#
    .SYNOPSIS
        Masks an identifier for display and for the evidence record.
    .DESCRIPTION
        The bundle should prove which distinct identities were present without
        republishing them in a new file. Masking keeps it correlatable - the same
        input always yields the same mask - while not restating the address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    if ($Value -match '^([^@]+)@(.+)$') {
        $local = $Matches[1]
        $domain = $Matches[2]
        $head = if ($local.Length -ge 2) { $local.Substring(0, 2) } else { $local }
        return "$head***@$domain"
    }

    if ($Value.Length -gt 8) {
        return "$($Value.Substring(0,8))...$($Value.Substring($Value.Length-4))"
    }
    return '***'
}

function Get-TlcCurrentUserUpn {
    <#
    .SYNOPSIS
        The UPN of the account running the toolbox, or an empty string if it cannot be read.
    .DESCRIPTION
        Used to seed the affected-user field, because in most collections the person at the
        keyboard IS the affected user - and a field that starts empty is a field that gets
        left empty, which costs the bundle its subject.

        WHY whoami AND NOT SOMETHING IN-PROCESS

        Measured on this machine, 2026-09-15:

            whoami /upn                                  alice@contoso.com
            WindowsIdentity.GetCurrent().Name            CONTOSO\alice   (not a UPN)
            UserPrincipal.Current.UserPrincipalName      threw - Unable to cast GroupPrincipal
                                                         to UserPrincipal

        The AccountManagement failure is not exotic; it happens whenever the current principal
        resolves to something the library does not expect, and it costs an exception on the UI
        thread for a convenience feature. whoami is a Windows component, answers in a few
        milliseconds, and gives the value in the form the field wants.

        Routed through Invoke-TlcNativeCommand like every other native call in this toolbox.
        On a machine with no work account whoami exits non-zero and writes
        "Unable to get user claims information" to stderr - which under Windows PowerShell 5.1
        would throw if the stream were redirected directly.

        Returns '' rather than a guess. A wrong default here is worse than no default: it
        would put the operator's identity on a bundle about somebody else, silently.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $result = Invoke-TlcNativeCommand -FilePath 'whoami.exe' -ArgumentList @('/upn')
        if (-not $result.Available -or $result.ExitCode -ne 0) { return '' }

        $candidate = @($result.Output | Where-Object { $_ -and $_.Trim() }) | Select-Object -First 1
        $candidate = [string]$candidate
        $candidate = $candidate.Trim()

        # Shape-checked, not trusted. whoami prints its error text to stdout on some builds,
        # and "ERROR: Unable to get user claims information." is a string that would otherwise
        # sail into the affected-user field and then into the bundle.
        if ($candidate -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return $candidate }
        return ''
    } catch {
        Write-Verbose "The current user's UPN could not be read: $($_.Exception.Message)"
        return ''
    }
}

function Get-TlcActiveAccount {
    <#
    .SYNOPSIS
        Reads signed-in accounts from collected client state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath
    )

    $settings = Join-Path $EndpointPath 'ClientState\app_settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return @() }

    try {
        $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
    } catch {
        Write-Verbose "app_settings.json could not be parsed: $($_.Exception.Message)"
        return @()
    }

    if (-not ($json.PSObject.Properties.Name -contains 'active_users')) { return @() }

    return @($json.active_users | ForEach-Object {
        [ordered]@{
            Id        = $_.id
            MaskedId  = Protect-TlcIdentifier -Value ([string]$_.id)
            CloudType = if ($_.PSObject.Properties.Name -contains 'cloudType') { $_.cloudType } else { $null }
            State     = if ($_.PSObject.Properties.Name -contains 'state') { $_.state } else { $null }
        }
    })
}

function Get-TlcIdentityInventory {
    <#
    .SYNOPSIS
        Inventories identities present in the collected evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        # 0 (the default) scans every file whole. A positive value caps each file, and the gate
        # then names every file it read only in part. Finding 308.
        [int] $MaxScanBytesPerFile = 0,
        # Workers for the text scan. 1 forces the serial path, which is the same code.
        [int] $ThrottleLimit = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount))
    )

    $accounts = Get-TlcActiveAccount -EndpointPath $EndpointPath

    # Every account id seen so far, so one found again by name or inside an archive is not
    # listed twice.
    $accountList = [System.Collections.Generic.List[object]]::new()
    $accountIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($account in @($accounts)) {
        $accountList.Add($account)
        if ($account.Id) { $null = $accountIds.Add([string]$account.Id) }
    }
    $rootItem = Get-Item -LiteralPath $EndpointPath -ErrorAction SilentlyContinue
    $rootPath = if ($rootItem) { $rootItem.FullName.TrimEnd('\') } else { $EndpointPath.TrimEnd('\') }
    $upns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $guids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archives = [System.Collections.Generic.List[string]]::new()
    $credentialFiles = [System.Collections.Generic.List[string]]::new()
    $textFiles = [System.Collections.Generic.List[string]]::new()
    $unreadableFiles = [System.Collections.Generic.List[string]]::new()
    $partialFiles = [System.Collections.Generic.List[string]]::new()
    $textBytes = [int64]0
    $scanned = 0

    $nativeRoot = ConvertTo-TlcNativeFilePath -Path $rootPath
    $files = if ($rootItem) {
        [IO.Directory]::EnumerateFiles($nativeRoot, '*', [IO.SearchOption]::AllDirectories) |
            ForEach-Object { [IO.FileInfo]::new($_) }
    } else { @() }
    foreach ($file in $files) {
        # Names first, for every file whatever its type. The zip's entry names and
        # Manifest.json carry every path, and only contents used to be scanned, so an account
        # id or an address in a NAME reached both unjudged (review 2026-09-30, finding 331).
        # The source says which top-level folder, never the path, which holds the id itself.
        $relative = $file.FullName.Substring($nativeRoot.Length).TrimStart('\')
        $segments = @($relative -split '\\')
        $where = if ($segments.Count -gt 1 -and -not $script:NameAccountRegex.IsMatch($segments[0]) -and $segments[0] -notmatch '@') { $segments[0] } else { '.' }
        foreach ($match in $script:NameAccountRegex.Matches($relative)) {
            $id = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            if ($accountIds.Add($id)) {
                $accountList.Add([ordered]@{
                    Id       = $id
                    MaskedId = Protect-TlcIdentifier -Value $id
                    Source   = "name:$where"
                })
            }
        }
        foreach ($upn in (Find-TlcUpn -Text $relative)) { $null = $upns.Add($upn) }
        if ($file.Extension -in '.zip', '.cab', '.7z') {
            # Recorded as a risk, and now also READ where it can be.
            #
            # This branch used to skip archives entirely, on the stated grounds that
            # "media and signaling content is encrypted and only Microsoft Support can
            # read it". That is true of the encrypted support bundle. It is NOT true of
            # the web log archive the toolbox now triggers itself: measured 2026-09-10
            # from a capture taken during a live meeting, calling-debug.txt inside it is
            # 100% printable JSON carrying a Members block, ipv4, mac and the tenant's
            # PSTN and emergency-services policy. An archive that was assumed unreadable
            # was carrying the other participants of a real call past the gate.
            #
            # The account folders are enumerated without extracting anything, so the ids
            # inside can be judged against KnownAccountIds like any other. Anything that
            # genuinely is encrypted simply yields nothing and is still flagged below.
            $archives.Add($file.Name)

            # Read here rather than through Get-TlcWebLogAccount. That function exists and
            # does the same job, but reaching for it made this a soft dependency: the first
            # version guarded with Get-Command and silently inventoried nothing whenever
            # Tlc.Collect.Web was not loaded. The entry point does load it, so the gap only
            # showed up in a test - and a privacy control that quietly does nothing when a
            # neighbour is missing is the worst possible thing to leave conditional.
            #
            # Only entry names are read; the archive is never extracted. Anything genuinely
            # encrypted yields no matches and is still flagged as a risk below.
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                try {
                    foreach ($entry in $zip.Entries) {
                        foreach ($match in $script:NameAccountRegex.Matches($entry.FullName)) {
                            $id = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
                            if (-not $accountIds.Add($id)) { continue }
                            $accountList.Add([ordered]@{
                                Id       = $id
                                MaskedId = Protect-TlcIdentifier -Value ([string]$id)
                                Source   = "archive:$($file.Name)"
                            })
                        }
                    }
                } finally { $zip.Dispose() }
            } catch {
                Write-Verbose "Archive $($file.Name) could not be read for account folders: $($_.Exception.Message)"
            }
            continue
        }
        if ($file.Extension -notin $script:ScannableExtensions) { continue }
        $textFiles.Add($file.FullName)
        $textBytes += if ($MaxScanBytesPerFile -gt 0) { [Math]::Min($file.Length, [int64]$MaxScanBytesPerFile) } else { $file.Length }
    }

    # Said before the scan, because on a bundle carrying a Teams support folder it is the
    # longest silent stretch of packaging - half a minute or more - and silence that long
    # reads as a hang. Finding 304.
    if ($textFiles.Count -gt 0) {
        Write-Information ("      Scanning {0} file(s), {1:N0} MB, for accounts and tokens..." -f $textFiles.Count, ($textBytes / 1MB)) -InformationAction Continue
    }

    # The text scan, serial or across a runspace pool. Both run the SAME scriptblock, so the
    # two paths cannot drift - the parallel one only splits the file list.
    #
    # Parallel because it was the slow step of packaging by an order of magnitude. Measured
    # 2026-09-25 on a 650 MB endpoint carrying a Teams support bundle (491 text files): 67 s on
    # Windows PowerShell 5.1 and 307 s on PowerShell 7 for the whole scan, against about 58 s
    # for the manifest and the zip together. The files are independent, so they split cleanly.
    #
    # A pool that cannot be created falls back to one worker rather than failing the gate.
    # Measured by forcing the refusal: same files, same identities. Not reachable through
    # Constrained Language Mode, which the entry point refuses before any of this (finding 152);
    # an earlier version of this comment said otherwise. Finding 304.
    $scanArgs = @{
        MaxBytes    = $MaxScanBytesPerFile
        GuidRegex   = $script:GuidRegex
        UpnAnchored = $script:UpnAnchoredRegex
        JwtRegex    = $script:JwtRegex
        RefreshRegex = $script:RefreshRegex
        LocalChars  = $script:UpnLocalChars
        DomainChars = $script:UpnDomainChars
    }
    $workers = [Math]::Max(1, [Math]::Min($ThrottleLimit, $textFiles.Count))
    $results = [System.Collections.Generic.List[object]]::new()

    $ranParallel = $false
    if ($workers -gt 1) {
        $pool = $null
        $jobs = [System.Collections.Generic.List[object]]::new()
        try {
            $pool = [runspacefactory]::CreateRunspacePool(1, $workers)
            $pool.Open()
            for ($w = 0; $w -lt $workers; $w++) {
                # Round-robin rather than contiguous blocks: files arrive grouped by folder,
                # and one folder of large logs would otherwise land on a single worker.
                $chunk = [System.Collections.Generic.List[string]]::new()
                for ($i = $w; $i -lt $textFiles.Count; $i += $workers) { $chunk.Add($textFiles[$i]) }
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                $null = $ps.AddScript($script:TextScanner.ToString()).AddParameter('Paths', $chunk.ToArray())
                foreach ($key in $scanArgs.Keys) { $null = $ps.AddParameter($key, $scanArgs[$key]) }
                $jobs.Add([pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() })
            }
            foreach ($job in $jobs) {
                foreach ($item in $job.PowerShell.EndInvoke($job.Handle)) { $results.Add($item) }
                if ($job.PowerShell.HadErrors) { throw "A scan worker failed: $($job.PowerShell.Streams.Error | Select-Object -First 1)" }
            }
            $ranParallel = $true
        } catch {
            Write-Verbose "Parallel identity scan unavailable, scanning serially: $($_.Exception.Message)"
            $results.Clear()
        } finally {
            foreach ($job in $jobs) { $job.PowerShell.Dispose() }
            if ($pool) { $pool.Dispose() }
        }
    }
    if (-not $ranParallel) {
        $results.Add((& $script:TextScanner -Paths $textFiles.ToArray() @scanArgs))
    }

    foreach ($result in $results) {
        $scanned += $result.Scanned
        foreach ($upn in $result.Upns) { $null = $upns.Add($upn) }
        foreach ($guid in $result.Guids) { $null = $guids.Add($guid) }
        foreach ($name in $result.CredentialFiles) { $null = $credentialFiles.Add($name) }
        foreach ($name in $result.UnreadableFiles) { $unreadableFiles.Add($name) }
        foreach ($name in $result.PartialFiles) { $partialFiles.Add($name) }
    }

    return [ordered]@{
        Accounts          = @($accountList)
        AccountCount      = $accountList.Count
        MultipleAccounts  = ($accountList.Count -gt 1)
        FilesScanned      = $scanned
        DistinctUpnCount  = $upns.Count
        MaskedUpns        = @($upns | ForEach-Object { Protect-TlcIdentifier -Value $_ })
        DistinctGuidCount = $guids.Count
        Guids             = @($guids)
        ClientArchives    = @($archives)
        CredentialFiles   = @($credentialFiles)
        UnreadableFiles   = @($unreadableFiles)
        PartiallyScanned  = @($partialFiles)
        MaxScanBytesPerFile = $MaxScanBytesPerFile
        CollectedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Protect-TlcHarCredential {
    <#
    .SYNOPSIS
        Removes sign-in credentials from HAR files under an endpoint folder, in place, and says
        what it removed.
    .DESCRIPTION
        "Export HAR (sanitized)" strips the Cookie, Set-Cookie and Authorization headers and
        nothing else. Measured on a real sanitized HAR of Teams on the web (finding 312): the
        token endpoint's response body still held access_token, id_token and refresh_token, the
        request body held refresh_token=..., and two SharePoint responses held access tokens. The
        privacy gate refused it, correctly, and there was no export setting that could produce a
        HAR it would accept - so the web capture lane could not complete for any real HAR.

        So the credentials are taken out before the gate reads the file. Only credential VALUES
        are replaced: every JWT-shaped string, and the value of every refresh_token in JSON or
        form data. The replacement contains no quote or backslash, so a HAR stays valid JSON,
        and the request that carried the token is still there with its timing and status - which
        is what support reads a HAR for.

        In place, deliberately. The whole point is that the token must not survive anywhere in
        the bundle; a redacted copy beside the original would leave the original to be sealed.
        The operator's own export, outside the run folder, is untouched.

        The gate still scans afterwards and still blocks on anything left, so this can only
        reduce what ships, never widen it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $hars = @([IO.Directory]::EnumerateFiles((ConvertTo-TlcNativeFilePath -Path $EndpointPath), '*', [IO.SearchOption]::AllDirectories) |
        ForEach-Object { [IO.FileInfo]::new($_) } |
        Where-Object { $_.Name -match '\.har(\.json)?$' })
    foreach ($har in $hars) {
        $text = [System.IO.File]::ReadAllText($har.FullName)
        $jwtCount = $script:JwtRegex.Matches($text).Count
        $refreshCount = $script:RefreshRegex.Matches($text).Count
        if ($jwtCount -eq 0 -and $refreshCount -eq 0) { continue }

        $redacted = $script:JwtRegex.Replace($text, 'REDACTED-BY-TLC-TOOLBOX')
        $redacted = $script:RefreshRegex.Replace($redacted, {
            param($m)
            # Keep the key and its punctuation; replace only the value.
            $value = $m.Value
            if ($value -match '^(refresh_token\\?"\s*:\s*\\?")') { return $Matches[1] + 'REDACTED-BY-TLC-TOOLBOX' }
            return 'refresh_token=REDACTED-BY-TLC-TOOLBOX'
        })

        if ($PSCmdlet.ShouldProcess($har.FullName, 'Remove sign-in credentials')) {
            [System.IO.File]::WriteAllText($har.FullName, $redacted, [System.Text.UTF8Encoding]::new($false))
        }
        $results.Add([pscustomobject][ordered]@{
            File          = $har.Name
            JwtCount      = $jwtCount
            RefreshCount  = $refreshCount
        })
    }
    return $results.ToArray()
}

# The address-masking walk, compiled. Restated in PowerShell it took 25 s on Windows PowerShell 5.1
# and over ten minutes on PowerShell 7 for a 37 MB HAR, because 7 pays heavily per method call and
# the walk makes millions of them (finding 313, same cause as finding 304). The algorithm is
# Find-TlcUpn's and the mask is Protect-TlcIdentifier's; a test holds all three to the same answers.
if (-not ('Tlc.AddressMasker' -as [type])) {
    Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.Text; using System.Text.RegularExpressions;
namespace Tlc {
    public static class AddressMasker {
        public static string Mask(string text, string localChars, string domainChars, Regex anchored, HashSet<string> keep, ref int maskedCount, ref int keptCount) {
            var masked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var kept = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var sb = new StringBuilder(text.Length);
            int copied = 0, length = text.Length, at = text.IndexOf('@');
            while (at >= 0) {
                int start = at;
                while (start > copied && localChars.IndexOf(text[start - 1]) >= 0) start--;
                int end = at + 1;
                while (end < length && domainChars.IndexOf(text[end]) >= 0) end++;
                if (start < at && end > at + 1) {
                    string candidate = text.Substring(start, end - start).TrimEnd('.', '-');
                    if (anchored.IsMatch(candidate)) {
                        if (keep.Contains(candidate)) { kept.Add(candidate); }
                        else {
                            int sep = candidate.IndexOf('@');
                            string local = candidate.Substring(0, sep);
                            string head = local.Length >= 2 ? local.Substring(0, 2) : local;
                            sb.Append(text, copied, start - copied).Append(head).Append("***").Append(candidate, sep, candidate.Length - sep);
                            copied = start + candidate.Length;
                            masked.Add(candidate);
                        }
                    }
                }
                int next = Math.Max(end, at + 1);
                if (next >= length) break;
                at = text.IndexOf('@', next);
            }
            maskedCount = masked.Count; keptCount = kept.Count;
            if (masked.Count == 0) return text;
            sb.Append(text, copied, length - copied);
            return sb.ToString();
        }
    }
}
"@
}

function Protect-TlcHarAddress {
    <#
    .SYNOPSIS
        Masks email addresses in HAR files under an endpoint folder, in place, keeping the ones
        support needs.
    .DESCRIPTION
        A real HAR of one OneDrive listing in Teams carried 7,397 distinct addresses - everyone
        the files were shared with (finding 312). None is needed to read a network trace, and
        none of those people consented to anything. Privacy.ScrubUpn, reserved for this and never
        implemented, now does it for HAR files, and is on by default. Client logs are not touched.

        Each address becomes the same mask used everywhere else in the bundle (Protect-TlcIdentifier:
        "ja***@contoso.com"), so the domain survives - which is the part a trace question turns
        on - and the person does not. Addresses in $Keep (the affected user and the signed-in
        operator) are left as they are, because support needs to find them.

        One compiled pass over the text, anchored on '@' like Find-TlcUpn: per-address String.Replace over a
        37 MB file for 7,397 addresses would be hundreds of billions of character comparisons.
        The mask holds no quote or backslash, so the HAR stays valid JSON.

        Not caught, and stated: a URL-encoded address (name%40contoso.com). Neither this nor the
        gate's scan sees that form.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string[]] $Keep = @()
    )

    $keepSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $Keep) { if ($k) { $null = $keepSet.Add($k.Trim()) } }
    $results = [System.Collections.Generic.List[object]]::new()

    $hars = @([IO.Directory]::EnumerateFiles((ConvertTo-TlcNativeFilePath -Path $EndpointPath), '*', [IO.SearchOption]::AllDirectories) |
        ForEach-Object { [IO.FileInfo]::new($_) } |
        Where-Object { $_.Name -match '\.har(\.json)?$' })
    foreach ($har in $hars) {
        $text = [System.IO.File]::ReadAllText($har.FullName)
        $maskedCount = 0; $keptCount = 0
        $result = [Tlc.AddressMasker]::Mask($text, $script:UpnLocalChars, $script:UpnDomainChars, $script:UpnAnchoredRegex, $keepSet, [ref]$maskedCount, [ref]$keptCount)
        if ($maskedCount -eq 0) { continue }

        if ($PSCmdlet.ShouldProcess($har.FullName, 'Mask email addresses')) {
            [System.IO.File]::WriteAllText($har.FullName, $result, [System.Text.UTF8Encoding]::new($false))
        }
        $results.Add([pscustomobject][ordered]@{
            File        = $har.Name
            MaskedCount = $maskedCount
            KeptCount   = $keptCount
        })
    }
    return $results.ToArray()
}

function Get-TlcPackageRefusalText {
    <#
    .SYNOPSIS
        What a refused Package says to do, once, for the gate, the entry point and the window.
    .DESCRIPTION
        English is what the gate writes into Fixes and Blockers.csv and what the entry point
        prints: it names switches, because it is read at a prompt and in a bundle. Key names
        the same instruction in the string tables, worded for the window, where the operator
        has buttons instead of switches.

        The window recognises a line of the run's output by its English and says the entry
        for its Key in the operator's language (ConvertTo-TlcWindowTranscript). That only
        works while there is one copy of each English line, which is why the gate and
        TLC-Toolbox.ps1 take theirs from here rather than writing their own. Finding 338.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $declare = 'Declare the account ids that belong to this collection (the Signed in tile''s Declare these accounts, or Privacy.KnownAccountIds). Do not declare an account that belongs to someone else: sign it out of Teams and collect again, or remove the files that name it from the run folder; IdentityInventory.json says where each was found.'
    return [ordered]@{
        Declare       = [ordered]@{ Key = ''; English = $declare }
        FixCredential = [ordered]@{ Key = 'PackageFixCredential'; English = 'Credentials in a HAR are removed automatically before this check, so what is left is in another file or a shape the redaction does not know. Remove the named file(s) from the run folder. Re-exporting the HAR as sanitized does not help: sanitizing strips headers only, and the tokens are in response bodies. Finding 312.' }
        FixUnreadable = [ordered]@{ Key = 'PackageFixUnreadable'; English = 'Close whatever holds the named file(s) open, or remove them from the run folder.' }
        FixAccounts   = [ordered]@{ Key = 'PackageFixAccounts'; English = $declare + ' Recording consent does not clear this.' }
        FixConsent    = [ordered]@{ Key = 'PackageFixConsent'; English = 'Record who authorised this collection: tick your account or type a name beside Consent granted by, or pass -ConsentGrantedBy.' }
        FixFleet      = [ordered]@{ Key = 'PackageFixFleet'; English = 'Re-run the collection for this endpoint once it is reachable, or collect on that machine directly.' }
        Excluded      = [ordered]@{ Key = 'PackageExcluded'; English = 'EXCLUDED from the bundle.' }
        AllRefused    = [ordered]@{ Key = 'PackageAllRefused'; English = 'BLOCKED: every endpoint was refused, so the bundle was not packaged.' }
        Closing       = [ordered]@{ Key = 'PackageFixClosing'; English = 'Fix what is listed above, then press Package again, or re-run -Stage Package with the same -CorrelationId, -Scenario and -CaseNumber.' }
        Again         = [ordered]@{ Key = ''; English = 'Then press Package again, or re-run -Stage Package with the same -CorrelationId, -Scenario and -CaseNumber.' }

        # The reasons, as templates: {0}, {1} are the counts, ids and file names the gate fills
        # in, and the window reads back out of the line to say the same reason in its language.
        ReasonUnknownAccounts = [ordered]@{ Key = 'PackageReasonUnknownAccounts'; English = '{0} signed-in account(s) not in Privacy.KnownAccountIds: {1}' }
        ReasonManyAccounts    = [ordered]@{ Key = 'PackageReasonManyAccounts'; English = '{0} accounts are signed in; client diagnostics span all of them.' }
        ReasonArchives        = [ordered]@{ Key = 'PackageReasonArchives'; English = '{0} client-produced archive(s) included; contents span every signed-in account.' }
        ReasonAddresses       = [ordered]@{ Key = 'PackageReasonAddresses'; English = '{0} distinct address(es) found in text evidence.' }
        ReasonCredentials     = [ordered]@{ Key = 'PackageReasonCredentials'; English = 'Bearer token(s) found in {0} file(s): {1}.' }
        ReasonUnreadable      = [ordered]@{ Key = 'PackageReasonUnreadable'; English = '{0} file(s) could not be read by the privacy scan, so their contents are unknown: {1}.' }
        ReasonPartial         = [ordered]@{ Key = 'PackageReasonPartial'; English = '{0} file(s) are larger than the {1} MB scan limit and were only read in part: {2}.' }
        ReasonConsent         = [ordered]@{ Key = 'PackageReasonConsent'; English = 'Consent is required but Privacy.ConsentGrantedBy is empty.' }
        ReasonFleetFailed     = [ordered]@{ Key = 'PackageReasonFleetFailed'; English = 'The fleet collection for {0} failed, so its folder is partial and is withheld; see the Fleet row in Blockers.csv.' }
    }
}
function Format-TlcRefusalText {
    <#
    .SYNOPSIS
        One refusal line from its template in Get-TlcPackageRefusalText, filled in.
    .DESCRIPTION
        Invariant culture, so a count or a size reads the same on every machine: the window
        reads the values back out of the line, and Blockers.csv is compared across machines.

        The values are given one by one, or as one array. Both mean the same here: Windows
        PowerShell 5.1 hands a lone array to a remaining-arguments parameter as a single value
        where PowerShell 7 unrolls it, and a list is always joined into one string before it
        is given, so a lone array is only ever the values themselves.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)] [System.Collections.IDictionary] $Entry,
        [Parameter(Position = 1, ValueFromRemainingArguments)] [object[]] $Value
    )
    # A typed list, because an unbound parameter is $null on 5.1 and @() of it is not reliably
    # an empty array there under strict mode.
    $values = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $Value) { foreach ($item in $Value) { $values.Add($item) } }
    if ($values.Count -eq 1 -and $values[0] -is [System.Collections.IList]) {
        $inner = $values[0]
        $values = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $inner) { $values.Add($item) }
    }
    return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, [string]$Entry.English, $values.ToArray())
}
function Test-TlcPrivacyGate {
    <#
    .SYNOPSIS
        Decides whether the bundle is safe to package and hand over.
    .DESCRIPTION
        Blocked is deliberately the default outcome for an unrecognised account.
        Handing a customer a bundle containing another organisation's identities is
        not recoverable once it has left, so the failure mode is chosen to be an
        inconvenient stop rather than a silent disclosure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Privacy,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Inventory,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    # Every setting is read through here rather than off $Privacy directly. The shipped
    # configuration declares all of them, so a missing key never fired in normal use - but
    # under StrictMode a config assembled in code throws on the first absent one, and the
    # caller sees "the privacy gate could not inspect this endpoint" for every endpoint at
    # once. A gate whose failure mode is refusing everything for a reason unrelated to privacy
    # is worse than one that treats an unstated setting as unstated.
    #
    # The defaults are the safe direction: no known accounts and no known tenants means
    # nothing is recognised, and BlockOnUnknownAccount and RequireConsent default to true, so
    # a config that forgot to say produces a stop rather than a silent disclosure.
    $setting = {
        param([string] $Key, $Default)
        if ($Privacy.Contains($Key) -and $null -ne $Privacy[$Key]) { return $Privacy[$Key] }
        return $Default
    }

    $known = @(& $setting 'KnownAccountIds' @())
    $unknown = @($Inventory.Accounts | Where-Object { $_.Id -and ($_.Id -notin $known) })

    # Deliberately no attempt to infer tenants from arbitrary GUIDs. Teams evidence
    # is full of GUIDs - correlation ids, session ids, experiment ids - and guessing
    # which are tenants would produce confident nonsense. Only an explicitly
    # configured tenant id is reported, and only when it actually appears.
    $knownTenants = @(& $setting 'KnownTenantIds' @())
    $homeTenant = & $setting 'HomeTenantId' ''
    if ($homeTenant) {
        $knownTenants = @($knownTenants) + $homeTenant
    }
    $tenantsSeen = @($Inventory.Guids | Where-Object { $knownTenants -contains $_ })

    $blocked = $false
    $say = Get-TlcPackageRefusalText
    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($unknown.Count -gt 0) {
        $masked = ($unknown | ForEach-Object { $_.MaskedId }) -join ', '
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonUnknownAccounts -Value @($unknown.Count, $masked)))
        if (& $setting 'BlockOnUnknownAccount' $true) { $blocked = $true }
    }

    if ($Inventory.MultipleAccounts) {
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonManyAccounts -Value @($Inventory.AccountCount)))
    }

    if ($Inventory.ClientArchives.Count -gt 0) {
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonArchives -Value @($Inventory.ClientArchives.Count)))
    }

    if ($Inventory.DistinctUpnCount -gt 0) {
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonAddresses -Value @($Inventory.DistinctUpnCount)))
    }

    # Contains() first, and nulls filtered: @($null).Count is 1, not 0, so reading a key
    # that is not there would have made every older inventory shape look as though it
    # carried a credential. Inventories are produced by more than one path here - the
    # collector, the quick collector, and test fixtures - so a new key cannot assume it
    # is present everywhere.
    $credentialFiles = @()
    if ($Inventory.Contains('CredentialFiles')) {
        $credentialFiles = @($Inventory.CredentialFiles | Where-Object { $_ })
    }

    # Blocks unconditionally, and is not governed by BlockOnUnknownAccount. That switch
    # is about whose identities are in the bundle; this is about a live credential being
    # in it. A token is not information about an account, it is access to one, and it
    # keeps working for its remaining lifetime regardless of who ends up holding the
    # file. There is no configuration under which shipping one is intended.
    if ($credentialFiles.Count -gt 0) {
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonCredentials -Value @($credentialFiles.Count, ($credentialFiles -join ', '))))
        $blocked = $true
    }

    # A file the scan could not open is a file the gate knows nothing about, so it blocks.
    # Passing it was a silent disclosure path: a lock that is released between the scan and
    # the zip puts an unread file in the bundle. Finding 306. Contains() first, for the same
    # reason as CredentialFiles above.
    $unreadable = @()
    if ($Inventory.Contains('UnreadableFiles')) { $unreadable = @($Inventory.UnreadableFiles | Where-Object { $_ }) }
    if ($unreadable.Count -gt 0) {
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonUnreadable -Value @($unreadable.Count, ($unreadable -join ', '))))
        $blocked = $true
    }

    # Read only in part, which is a design limit rather than a failure: stated so that no
    # reader takes a clean verdict as covering the whole of a large file.
    $partial = @()
    if ($Inventory.Contains('PartiallyScanned')) { $partial = @($Inventory.PartiallyScanned | Where-Object { $_ }) }
    if ($partial.Count -gt 0) {
        $capMb = if ($Inventory.Contains('MaxScanBytesPerFile') -and $Inventory.MaxScanBytesPerFile) { [math]::Round($Inventory.MaxScanBytesPerFile / 1MB) } else { '?' }
        $reasons.Add((Format-TlcRefusalText -Entry $say.ReasonPartial -Value @($partial.Count, $capMb, ($partial -join ', '))))
    }

    $requireConsent = & $setting 'RequireConsent' $true
    $consentGrantedBy = & $setting 'ConsentGrantedBy' ''
    $consentMissing = ($requireConsent -and -not $consentGrantedBy)
    if ($consentMissing) {
        $reasons.Add($say.ReasonConsent.English)
        $blocked = $true
    }

    $status = if ($blocked) { 'Blocked' } elseif ($reasons.Count -gt 0) { 'Warning' } else { 'Success' }
    $severity = if ($blocked) { 'Critical' } elseif ($reasons.Count -gt 0) { 'Warning' } else { 'Information' }
    $detail = if ($reasons.Count -gt 0) { $reasons -join ' ' } else { 'No unrecognised identities found.' }

    <#
        ONE FIX PER CAUSE, AND ONLY FOR THE CAUSES PRESENT.

        This was one sentence for every case that was not a credential or an unreadable file:
        "declare the account ids, give consent for this run, or remove the affected evidence".
        Read as three alternatives, it told an operator blocked by an undeclared account that
        consent would clear it, and it does not: the account check above takes no notice of
        consent. Measured 2026-10-01 on the 0.1.23 package - Package with -ConsentGrantedBy and an
        undeclared account was refused, as it should be, with a remediation saying otherwise.
        It was also written on a clean verdict, so a passing gate's row told the operator to
        declare accounts, and only the first of several blocking causes ever got its fix.
        Finding 336.
    #>
    $fixes = [System.Collections.Generic.List[string]]::new()
    if ($credentialFiles.Count -gt 0) {
        $fixes.Add($say.FixCredential.English)
    }
    if ($unreadable.Count -gt 0) {
        $fixes.Add($say.FixUnreadable.English)
    }
    $accountsBlock = ($unknown.Count -gt 0 -and (& $setting 'BlockOnUnknownAccount' $true))
    if ($accountsBlock) {
        $fixes.Add($say.FixAccounts.English)
    }
    if ($consentMissing) {
        # Consent is given per run, never set in a configuration file: a standing value
        # asserts consent nobody gave (privacy-and-consent.md). Review 2026-09-30.
        $fixes.Add($say.FixConsent.English)
    }

    $remediation = if ($blocked) {
        (@($fixes) + $say.Again.English) -join ' '
    } elseif ($unknown.Count -gt 0) {
        # Reported rather than blocked, because BlockOnUnknownAccount is off: say what that
        # means for the bundle, and how to stop it being said.
        'Not blocking, because BlockOnUnknownAccount is false: the bundle carries evidence for these accounts. ' + $say.Declare.English
    } else {
        ''
    }

    Write-TlcBlocker -Check 'Privacy.Gate' -Status $status -Severity $severity -Endpoint $Endpoint `
        -Detail $detail -Remediation $remediation | Out-Null

    return [ordered]@{
        Status          = $status
        Blocked         = $blocked
        Reasons         = @($reasons)
        # What to do about each blocking cause, without the closing "then package again", so a
        # caller printing them under the reasons does not say that twice.
        Fixes           = @($fixes)
        Remediation     = $remediation
        UnknownAccounts = @($unknown | ForEach-Object { $_.MaskedId })
        # Masked like UnknownAccounts beside it. This went into Manifest.json raw - the last
        # raw tenant id in a default bundle, found by searching the sealed archive after the
        # other routes were closed. Finding 296.
        KnownTenantsSeen= @($tenantsSeen | Where-Object { $_ } | ForEach-Object { Protect-TlcIdentifier -Value ([string]$_) })
        CredentialFiles = @($credentialFiles)
        # The machine this verdict is about. InspectedEndpoints is the same fact expressed
        # as the scope the verdict covers - both derive from $Endpoint here, so they cannot
        # disagree. New-TlcBundle reads Endpoint when merging several verdicts, and
        # InspectedEndpoints when given a single one.
        Endpoint        = $Endpoint
        InspectedEndpoints = @($Endpoint)
        EvaluatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function New-TlcConsentRecord {
    <#
    .SYNOPSIS
        Records who authorised the collection, what it covered, and which machine.
    .DESCRIPTION
        Endpoint is recorded because consent is per machine, not per run. One record at the
        run root would assert that a single named person authorised collection from every
        machine in it - true for a one-desktop case, and a serious overreach across a fleet
        where the grantor may have no authority over half the estate.

        Writing one record per endpoint keeps the claim exactly as wide as the evidence it
        covers, and means an endpoint excluded from the bundle takes its consent record with
        it rather than leaving an assertion behind about evidence that is not there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Privacy,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Scope,
        [string] $CustomerName,
        [string] $CaseNumber,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    # Read from the $Privacy parameter, which is what it is for. This previously referenced
    # $requireConsent and $consentGrantedBy directly - the LOCALS OF Test-TlcPrivacyGate, a
    # different function - and $Privacy was a mandatory parameter that was never read.
    #
    # PowerShell's dynamic scoping is why it survived: a function can see its caller's
    # variables, so whenever this was called from somewhere those names happened to exist it
    # worked, and every test that exercised the gate first did exactly that. From the entry
    # point they do not exist, and under Set-StrictMode the reference throws - so -Stage
    # Package failed with "The variable '$requireConsent' cannot be retrieved because it has
    # not been set" and produced no bundle at all. Found by running the stage, not by reading.
    #
    # Same accessor and same safe defaults as the gate: an unstated RequireConsent means
    # consent IS required, so a config that forgot to say produces a stop rather than a
    # record asserting consent nobody gave.
    $setting = {
        param([string] $Key, $Default)
        if ($Privacy.Contains($Key) -and $null -ne $Privacy[$Key]) { return $Privacy[$Key] }
        return $Default
    }

    $requireConsent = & $setting 'RequireConsent' $true
    $consentGrantedBy = & $setting 'ConsentGrantedBy' ''

    # The consent record states what evidence was authorised, so the window has to be the
    # one the evidence actually came from. A live trace has none: it is bounded by when the
    # operator started and stopped it, which the capture session measures and writes to
    # Capture.json. Empty strings with the mode named beside them, rather than a window
    # nothing was collected against - a consent record is read years later by people with
    # no other way to check it.
    $live = ($null -eq $Scope.WindowStart -or $null -eq $Scope.WindowEnd)

    return [ordered]@{
        Endpoint        = $Endpoint
        ConsentRequired = [bool]$requireConsent
        ConsentGrantedBy= $consentGrantedBy
        CustomerName    = $CustomerName
        CaseNumber      = $CaseNumber
        Scenario        = $Scope.ScenarioName
        WindowMode      = if ($live) { 'Live' } else { 'Retrospective' }
        WindowStartUtc  = if ($live) { '' } else { $Scope.WindowStart.UtcTime }
        WindowEndUtc    = if ($live) { '' } else { $Scope.WindowEnd.UtcTime }
        Operator        = "$env:USERDOMAIN\$env:USERNAME"
        RecordedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function ConvertTo-TlcShareableIdentityInventory {
    <#
    .SYNOPSIS
        The copy of an identity inventory that is written into a bundle.
    .DESCRIPTION
        MASKED BY DEFAULT, raw behind -IncludeRawIdentifiers. Owner decision 2026-09-24,
        finding 296.

        The gate needs raw account ids to compare against Privacy.KnownAccountIds, and it
        works from the in-memory inventory - so it keeps them. What it WROTE, to
        IdentityInventory.json, used to be that same object: every account id raw beside its
        mask, and every GUID found anywhere in the text evidence, raw, in a list. That put the
        customer's account and tenant identifiers into the bundle while the privacy page said
        identifiers were masked.

        Counts, masks, sources and flags are kept, so the record still shows what the gate saw
        and why it decided as it did. Only the raw values are removed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] $Inventory,
        [switch] $IncludeRawIdentifiers
    )

    $copy = [ordered]@{}
    foreach ($key in $Inventory.Keys) { $copy[$key] = $Inventory[$key] }

    if (-not $IncludeRawIdentifiers) {
        $copy['Accounts'] = @(@($Inventory['Accounts']) | ForEach-Object {
            $account = [ordered]@{}
            foreach ($k in $_.Keys) { if ($k -ne 'Id') { $account[$k] = $_[$k] } }
            $account
        })
        $masked = [System.Collections.Generic.List[string]]::new()
        foreach ($guid in @($Inventory['Guids'])) {
            if (-not $guid) { continue }
            # Fails closed: an id the mask cannot be applied to is dropped, not kept raw.
            try { $masked.Add((Protect-TlcIdentifier -Value ([string]$guid))) } catch {
                Write-Verbose "A GUID could not be masked and was omitted: $($_.Exception.Message)"
            }
        }
        $copy['Guids'] = @($masked)
    }
    $copy['RawIdentifiersIncluded'] = [bool]$IncludeRawIdentifiers
    return $copy
}

Export-ModuleMember -Function Get-TlcPackageRefusalText, Format-TlcRefusalText, Protect-TlcIdentifier, Protect-TlcHarCredential, Protect-TlcHarAddress, Find-TlcUpn, Get-TlcActiveAccount, Get-TlcIdentityInventory,
    ConvertTo-TlcShareableIdentityInventory,
    Get-TlcCurrentUserUpn, Test-TlcPrivacyGate, New-TlcConsentRecord
