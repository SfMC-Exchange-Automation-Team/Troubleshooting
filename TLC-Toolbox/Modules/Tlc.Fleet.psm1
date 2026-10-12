Set-StrictMode -Version Latest

<#
    Fleet mode: one correlated collection across several endpoints.

    See docs\fleet-mode-plan.md for the decisions behind this. The two that shape the code
    here are 3.2 (run the collector in the remote session rather than copying the toolbox to
    the endpoint) and 3.3 (failure is normal, not exceptional).

    What this file does NOT do is decide how a session is opened. That is injected, for two
    reasons. It is the half of step 1 that still needs a real second machine - whether a
    session can be opened to one at all, and whether the firewall allows it, are questions
    about the estate rather than about this code. And injecting it means the fan-out, the
    failure isolation and the correlation are all provable on one machine.
#>

function Get-TlcConsoleUserProfile {
    <#
    .SYNOPSIS
        The profile folder of the user signed in at this machine's console.
    .DESCRIPTION
        Runs ON the endpoint. Invoke-TlcRemoteClientLogCollection and Invoke-TlcInteractiveLaunch
        send its text across and run it inside the remote session, which has no toolbox modules,
        so it calls nothing from this module.

        A remote session runs as the remoting account. On a real estate that is an
        administrator, not the person running Teams, so reading $env:LOCALAPPDATA collected the
        administrator's (usually empty) Teams folder and reported success, and the launch
        script was written to the administrator's TEMP where the signed-in user cannot read it
        (review 2026-09-30, finding 331). Administrators can read other profiles, measured on
        the lab endpoint: a second profile's Teams log folder listed from the remoting account.

        The SID is tried first, and on the lab endpoint it matched. A loaded profile whose folder
        is named for the account is the fallback, for an account name that does not translate,
        which a machine away from its domain can hit. Anything else is returned unresolved
        rather than guessed, because collecting the wrong profile produces a bundle that
        describes somebody else.
    #>
    [CmdletBinding()]
    param(
        # The account to resolve. Defaults to the console user.
        [string] $Account
    )

    if (-not $Account) {
        try { $Account = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName } catch { $Account = '' }
    }
    if (-not $Account) { return [pscustomobject]@{ Account = ''; ProfilePath = ''; How = 'NoConsoleUser' } }

    $profiles = @()
    try { $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special=False' -ErrorAction Stop) } catch { $profiles = @() }

    $sid = ''
    try {
        $sid = ([System.Security.Principal.NTAccount]::new($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { $sid = '' }
    $how = 'Sid'
    $match = @(if ($sid) { $profiles | Where-Object { [string]$_.SID -eq $sid } })
    if ($match.Count -ne 1) {
        $leaf = @($Account -split '\\')[-1]
        $pattern = '^' + [regex]::Escape($leaf) + '(\.[^\\]+)?$'
        $how = 'LoadedProfileName'
        $match = @($profiles | Where-Object {
            $_.Loaded -and $_.LocalPath -and ((Split-Path -Path ([string]$_.LocalPath) -Leaf) -match $pattern)
        })
    }
    if ($match.Count -eq 1) {
        return [pscustomobject]@{ Account = $Account; ProfilePath = [string]$match[0].LocalPath; How = $how }
    }
    return [pscustomobject]@{ Account = $Account; ProfilePath = ''; How = 'Unresolved' }
}


function Invoke-TlcFleetCollection {
    <#
    .SYNOPSIS
        Runs one collector against several endpoints, serially, and reports each separately.
    .DESCRIPTION
        Serial on purpose. A parallel bug looks exactly like a transport bug, and debugging
        both at once is avoidable. Measured 2026-09-08 against five loopback sessions: about
        15 seconds per endpoint, so ten endpoints is around two and a half minutes. The plan
        set that as the threshold for whether parallelism is worth writing, and it is not
        crossed - so there is no runspace pool here, and the number that would justify one is
        recorded rather than guessed at.

        Failure is the expected case. With ten endpoints some will fail, so every endpoint is
        wrapped individually: one unreachable endpoint must not stop the other nine. A
        failure is recorded against the endpoint it happened to, with the stage it reached,
        in the per-endpoint shape Blockers.csv already uses - not one "some endpoints failed"
        line that names none of them.

        Status separates AllFailed from NotAttempted. Both leave an empty evidence folder and
        they are completely different situations; conflating them is the finding 91 class of
        error, where a result that is empty and a result that was never computed look alike.

        One folder per endpoint, named for the endpoint, because the privacy gate inspects
        one endpoint folder at a time. The layout is what makes per-endpoint gating possible.
    .PARAMETER Endpoint
        The endpoint names. Blank and whitespace entries are dropped rather than attempted -
        a trailing newline in a pasted list should not become a failed endpoint.
    .PARAMETER SessionFactory
        Given an endpoint name, returns an open PSSession. Injected: opening a session to a
        real endpoint is the part that needs the estate to permit it.
    .PARAMETER Collector
        Given the session, the endpoint's evidence folder and the endpoint name, gathers the
        evidence. Injected so the fan-out can be proven without a collector.
    .PARAMETER RunPath
        The run folder. Each endpoint gets a subfolder of it.
    .PARAMETER CorrelationId
        Shared by every endpoint in the run. The point of fleet mode is that the endpoints
        are one investigation, so they carry one id.
    #>
    [CmdletBinding()]
    param(
        [string[]] $Endpoint = @(),
        [Parameter(Mandatory)] [scriptblock] $SessionFactory,
        [Parameter(Mandatory)] [scriptblock] $Collector,
        [Parameter(Mandatory)] [string] $RunPath,
        [string] $CorrelationId = ([guid]::NewGuid().ToString())
    )

    $names = @($Endpoint | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

    $result = [ordered]@{
        CorrelationId = $CorrelationId
        RunPath       = $RunPath
        Attempted     = 0
        Succeeded     = @()
        Blocked       = @()
        EndpointPath  = [ordered]@{}
        Status        = 'NotAttempted'
    }

    if ($names.Count -eq 0) { return $result }

    $succeeded = [System.Collections.Generic.List[string]]::new()
    $blocked = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $names) {
        $result.Attempted++
        $session = $null

        # An endpoint name becomes a folder in the run, and one that was a path ('..\x') made a
        # folder outside it. Refused before any connection (review 2026-09-30, finding 331).
        if ($name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name.Trim().Trim('.') -eq '') {
            $blocked.Add([ordered]@{
                Endpoint = $name
                Stage    = 'Connect'
                Reason   = "'$name' is not a computer name, so it was not attempted: an endpoint name becomes a folder in the run."
            })
            continue
        }

        # Carried into the blocker so the report says where it stopped. "Could not connect"
        # and "connected, then the collector failed" send an engineer to different places.
        $stage = 'Connect'
        try {
            $session = & $SessionFactory $name
            if (-not $session) { throw "The session factory returned nothing for $name." }

            $stage = 'Collect'
            $endpointPath = Join-Path $RunPath $name
            $null = New-Item -ItemType Directory -Path $endpointPath -Force

            # $null =, because a collector that returns anything would otherwise emit it into
            # this function's output stream and the caller would get an ARRAY rather than the
            # result object - $result.Status then reads as "property cannot be found".
            #
            # Every fake collector in the tests returns nothing, so this was invisible until the
            # first real one ran: Invoke-TlcRemoteClientLogCollection returns its inventory,
            # which is useful to its own caller and pollution here.
            $null = & $Collector $session $endpointPath $name

            $result.EndpointPath[$name] = $endpointPath
            $succeeded.Add($name)
        } catch {
            $reason = $_.Exception.Message
            # Finding 316: an unresolvable name reads as a TrustedHosts problem in WinRM's text.
            if ($stage -eq 'Connect' -and (Get-Command Get-TlcRemoteConnectHint -ErrorAction SilentlyContinue)) {
                $hint = Get-TlcRemoteConnectHint -HostName $name
                if ($hint) { $reason = "$hint WinRM said: $reason" }
            }
            $blocked.Add([ordered]@{
                Endpoint = $name
                Stage    = $stage
                Reason   = $reason
            })
        } finally {
            # In finally, so a collector that throws still closes the session it was given.
            # A leaked session holds a process open on the endpoint.
            if ($session) {
                try { Remove-PSSession -Session $session -ErrorAction Stop }
                catch { Write-Verbose "The session for $name could not be closed: $($_.Exception.Message)" }
            }
        }
    }

    $result.Succeeded = @($succeeded)
    $result.Blocked = @($blocked)
    $result.Status =
        if ($succeeded.Count -eq 0) { 'AllFailed' }
        elseif ($blocked.Count -gt 0) { 'Partial' }
        else { 'Complete' }

    return $result
}

function Get-TlcFleetEndpoint {
    <#
    .SYNOPSIS
        Turns a pasted or configured endpoint list into names worth attempting.
    .DESCRIPTION
        Separate from the fan-out because the failure modes are different and both are real.
        An operator pastes a column out of a spreadsheet or a ticket: it arrives with blank
        lines, stray whitespace, duplicates and sometimes comment lines.

        Duplicates are dropped rather than collected twice. Two folders for one machine, one
        of them arbitrarily second, is worse than one - and the privacy gate would then gate
        the same endpoint twice.

        Comparison is case-insensitive because DESK-A and desk-a are the same machine, but
        the FIRST spelling is what is kept, since that is what the operator will look for in
        the report.
    #>
    [CmdletBinding()]
    param([string[]] $Endpoint = @())

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in $Endpoint) {
        if ($null -eq $raw) { continue }
        $name = $raw.Trim()
        if (-not $name) { continue }
        if ($name.StartsWith('#')) { continue }
        if ($seen.Add($name)) { $out.Add($name) }
    }

    # Returned unwrapped, and callers wrap. The unary comma fixes the empty case - PowerShell
    # unrolls an empty array to $null on return - but breaks every other one: ",@($out)"
    # survives assignment intact yet arrives at a pipeline as a single nested array, so
    # "Get-TlcFleetEndpoint ... | ForEach-Object" would iterate once over the whole list.
    # Trading a common failure for a rare one is a bad trade, so the contract is the ordinary
    # PowerShell one and Invoke-TlcFleetCollection wraps in @() like any other caller must.
    return @($out)
}

function Invoke-TlcFleetPrivacyGate {
    <#
    .SYNOPSIS
        Gates each endpoint in a fleet run separately, and reports which may be packaged.
    .DESCRIPTION
        Sequencing step 3. The decision and the mechanism were settled earlier - gate per
        endpoint, exclude the refused, package the rest - but against evidence that did not
        exist yet. Invoke-TlcFleetCollection now produces real per-endpoint folders, so this
        is the piece that joins them to Test-TlcPrivacyGate.

        ONE REFUSAL MUST NOT COST THE RUN. Ten endpoints will not all pass. Blocking the whole
        bundle because one machine had an unrecognised account throws away nine good
        collections and pushes the operator towards collecting again without the gate, which
        is the outcome the gate exists to prevent. So a refused endpoint is excluded and named,
        and the rest proceed.

        EVERY ENDPOINT IS ACCOUNTED FOR. New-TlcBundle already refuses to seal a run holding an
        endpoint that was neither inspected nor deliberately excluded, so an endpoint this
        function fails to reach must be reported as excluded rather than quietly skipped -
        otherwise the bundle refuses to seal at all and the reason is somewhere else entirely.
        An inventory that throws is therefore an exclusion with the error as its reason, not a
        gap.

        A run where every endpoint is refused is still not the same as a run that collected
        nothing. Both leave nothing packageable and they are completely different situations,
        which is the finding 91 distinction the fan-out already draws.
    .PARAMETER EndpointPath
        Endpoint name to its evidence folder, as Invoke-TlcFleetCollection returns.
    .PARAMETER Privacy
        The privacy configuration section, passed through to Test-TlcPrivacyGate unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $EndpointPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Privacy
    )

    $included = [System.Collections.Generic.List[string]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()
    $inspected = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @($EndpointPath.Keys)) {
        $path = [string]$EndpointPath[$name]
        $inspected.Add($name)

        # An endpoint whose folder is not there cannot be inspected, and an inventory of
        # nothing looks exactly like an inventory of clean evidence: no accounts, no UPNs, no
        # archives. Test-TlcPrivacyGate would pass it, and the endpoint would be listed as
        # included in the bundle manifest having never been read.
        #
        # Measured while proving this: an endpoint whose folder had been removed after
        # collection was reported Included alongside two genuinely clean ones. It is the same
        # failure the fan-out avoids by separating AllFailed from NotAttempted - absent
        # evidence and evidence that passed must not look alike.
        if (-not (Test-Path -LiteralPath $path)) {
            $excluded.Add([ordered]@{
                Endpoint = $name
                Reason   = "No evidence folder at $path, so nothing could be inspected."
            })
            continue
        }

        try {
            $inventory = Get-TlcIdentityInventory -EndpointPath $path
            $verdict = Test-TlcPrivacyGate -Privacy $Privacy -Inventory $inventory -Endpoint $name

            if ($verdict.Blocked) {
                $excluded.Add([ordered]@{
                    Endpoint = $name
                    Reason   = (@($verdict.Reasons) -join ' ')
                })
            } else {
                $included.Add($name)
            }
        } catch {
            # Excluded rather than skipped. An endpoint this function cannot inspect is one
            # New-TlcBundle would refuse to seal around, and a refusal explained here is worth
            # more than the same refusal surfacing later with no endpoint named.
            $excluded.Add([ordered]@{
                Endpoint = $name
                Reason   = "The privacy gate could not inspect this endpoint: $($_.Exception.Message)"
            })
        }
    }

    $status =
        if ($inspected.Count -eq 0) { 'NotAttempted' }
        elseif ($included.Count -eq 0) { 'AllExcluded' }
        elseif ($excluded.Count -gt 0) { 'Partial' }
        else { 'Complete' }

    return [ordered]@{
        Inspected = @($inspected)
        Included  = @($included)
        Excluded  = @($excluded)
        Status    = $status
    }
}

function Get-TlcFleetReadiness {
    <#
    .SYNOPSIS
        Whether this machine can open a session to another one, and what is missing if not.
    .DESCRIPTION
        Fleet mode's surface is gated on this rather than always offered. A box an operator can
        paste ten machine names into, which then fails on every one, is worse than no box - it
        spends their time before telling them what a check could have said immediately.

        It reports what is missing rather than only that something is. "Fleet mode is
        unavailable" sends someone to guess; "WinRM has no listener" sends them to
        Enable-PSRemoting. The distinction matters because the fix is usually somebody else's
        to make, and they need to be told what to ask for.

        Measured on the development machine 2026-09-08: the WinRM service is Running with ZERO
        listeners, and the machine is Entra-joined only - workgroup, no domain.

        THE LISTENER CHECK WAS THE WRONG DIRECTION, and this function shipped with it for two
        weeks. A listener accepts connections IN. Fleet mode makes them OUT, and never connects
        to itself. The original note recorded the validating experiment - "opening a session to
        its own name is refused" - and that is exactly the case fleet mode does not perform.

        Proved on 2026-09-22 by doing the thing the check said was impossible: with zero local
        listeners, this machine opened a session to a second endpoint, collected 39 files from
        it, and packaged both machines into one bundle in 41 seconds. Meanwhile the wizard had
        the endpoint box DISABLED, citing "WinRM has no listener configured". The feature
        worked and its own readiness check said it could not.

        What an OUTBOUND session actually needs locally: the WS-Man client stack, which the
        WinRM service standing in for, and a credential path to the target - Kerberos when
        domain joined, or TrustedHosts plus explicit credentials when not. Those are the two
        checks below.

        This still says nothing about whether a session to a PARTICULAR endpoint will succeed.
        Auth and firewall are per-endpoint and per-estate, and no local probe can answer them -
        the fan-out already treats a failed connection as a per-endpoint blocker for that
        reason. This answers only the cheaper question: is there any point offering the control
        at all.
    #>
    [CmdletBinding()]
    param([hashtable] $Probe)

    try {
        $signals = if ($Probe) { $Probe } else {
            $service = $null
            try { $service = (Get-Service -Name WinRM -ErrorAction Stop).Status } catch { $service = 'Absent' }

            $listenerCount = 0
            try { $listenerCount = @(Get-ChildItem 'WSMan:\localhost\Listener' -ErrorAction Stop).Count } catch { $listenerCount = 0 }

            $partOfDomain = $false
            try { $partOfDomain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { $partOfDomain = $false }

            # The outbound credential path for a non-domain machine.
            $trustedHosts = ''
            try { $trustedHosts = [string](Get-Item 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value } catch { $trustedHosts = '' }

            @{ WinRmStatus = [string]$service; ListenerCount = [int]$listenerCount
               PartOfDomain = $partOfDomain; TrustedHosts = $trustedHosts }
        }

        $blockers = [System.Collections.Generic.List[string]]::new()

        if ($signals['WinRmStatus'] -ne 'Running') {
            $blockers.Add('the WinRM service is not running')
        }

        # A non-domain machine reaches a non-domain endpoint only with explicit credentials,
        # and WinRM refuses those unless the target is in TrustedHosts. That IS an outbound
        # prerequisite, unlike the listener this check used to demand. Domain-joined machines
        # use Kerberos and need no entry.
        #
        # Absent from an injected probe means "not measured", so it is not treated as missing -
        # otherwise every existing caller of -Probe would flip to not-ready on a key that did
        # not exist when they were written.
        $trustedKnown = $signals.ContainsKey('TrustedHosts')
        if (-not $signals['PartOfDomain'] -and $trustedKnown -and
            [string]::IsNullOrWhiteSpace([string]$signals['TrustedHosts'])) {
            $blockers.Add('this machine is not domain joined and TrustedHosts is empty, so WinRM will refuse explicit credentials')
        }

        # Not a blocker. A workgroup or Entra-joined estate can still use explicit credentials,
        # so this is stated as context rather than treated as a refusal - the toolbox does not
        # know which credential model the estate uses, and guessing would be the confident
        # wrong answer.
        $note = if (-not $signals['PartOfDomain']) {
            'This machine is not domain joined, so endpoints will need explicit credentials.'
        } else { '' }

        return [ordered]@{
            Ready    = ($blockers.Count -eq 0)
            Blockers = @($blockers)
            Note     = $note
            Detail   = if ($blockers.Count -eq 0) {
                'Remoting is available from this machine.'
            } else {
                'Fleet mode needs remoting: ' + (($blockers -join ', ')) + '.'
            }
        }
    } catch {
        # Unknown is not ready. Offering the control because a probe failed would be the same
        # error as offering it when remoting is absent.
        return [ordered]@{
            Ready = $false; Blockers = @('remoting readiness could not be determined')
            Note = ''
            Detail = "Fleet mode readiness could not be determined: $($_.Exception.Message)"
        }
    }
}

function Invoke-TlcRemoteClientLogCollection {
    <#
    .SYNOPSIS
        Collects Teams client logs from an endpoint across an open session.
    .DESCRIPTION
        The fleet collector. It runs inside the remote session rather than copying the toolbox
        to the endpoint - option B in docs\fleet-mode-plan.md - so nothing lands on the machine
        except what is read back off it.

        The scriptblock sent across is deliberately self-contained and small. It cannot call
        into this module, because the remote session has none of it loaded, and sending the
        whole module to enumerate a folder would be a much larger thing to justify to a
        security team than a single Get-ChildItem.

        Copies are bounded. A Teams log folder can hold hundreds of megabytes of rotated
        history, and pulling all of it across a WinRM channel for ten endpoints is a different
        operation from collecting one machine - so the newest files are taken first, up to a
        stated cap, and the count actually copied is reported rather than assumed.

        Failures are left to throw. Invoke-TlcFleetCollection wraps every endpoint and records
        what stage it reached, so swallowing an error here would replace a named per-endpoint
        blocker with an endpoint that silently produced nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [Parameter(Mandatory)] [string] $Endpoint,
        [int] $MaxFiles = 40,
        # The run's window, in UTC. Without it the endpoint sent its newest files whatever the
        # window said: measured on a two-machine fleet, a 23:01-23:32 run carried a remote
        # endpoint's logs from 13:38 onwards, 36 files and 27 MB, under a Scope.json that
        # claimed half an hour. Finding 309.
        [Nullable[datetime]] $WindowStartUtc,
        [Nullable[datetime]] $WindowEndUtc
    )

    $logsPath = Join-Path $EndpointPath 'ClientLogs'
    $null = New-Item -ItemType Directory -Path $logsPath -Force

    # Enumerated remotely, so the decision about which files matter is made where the files
    # are - listing everything and filtering locally would mean copying everything first.
    #
    # The window rules are the local collector's (Select-TlcLogFileInWindow), restated because
    # the remote session has no module: the start time from the file name, else CreationTime;
    # the end from a refreshed LastWriteTime; a file still held open by its writer counts as
    # covering the present. Compared in UTC, because the file names are the ENDPOINT's local
    # time and the endpoint may be in another time zone.
    $windowed = ($null -ne $WindowStartUtc) -and ($null -ne $WindowEndUtc)
    $listing = @(Invoke-Command -Session $Session -ScriptBlock {
        param([int] $Limit, [bool] $Windowed, $StartUtc, $EndUtc, [string] $ResolverText)

        # The signed-in user's logs, not the remoting account's. See Get-TlcConsoleUserProfile,
        # whose text this is. When the remoting account IS the signed-in user its own
        # LOCALAPPDATA is read, as before; the remoting account's folder is otherwise read only
        # when nobody is signed in or the profile cannot be told, and the inventory says which.
        $relative = 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
        $source = 'RemotingAccount'
        $root = Join-Path $env:LOCALAPPDATA $relative
        $console = $null
        try { $console = & ([scriptblock]::Create($ResolverText)) } catch { $console = $null }
        if ($console -and $console.ProfilePath) {
            $source = 'ConsoleUser'
            $own = [string]::Equals(([string]$console.ProfilePath).TrimEnd('\'), ([string]$env:USERPROFILE).TrimEnd('\'),
                [System.StringComparison]::OrdinalIgnoreCase)
            if (-not $own) { $root = Join-Path (Join-Path $console.ProfilePath 'AppData\Local') $relative }
        }
        if (-not (Test-Path -LiteralPath $root)) { return [pscustomobject]@{ Source = $source; Files = @() } }

        $files = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)
        if ($Windowed) {
            $files = @(foreach ($f in $files) {
                $f.Refresh()
                $start = $f.CreationTime
                if ($f.Name -match '_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})') {
                    $parsed = [datetime]::MinValue
                    $stamp = '{0}-{1}-{2} {3}:{4}:{5}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5], $Matches[6]
                    if ([datetime]::TryParseExact($stamp, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) { $start = $parsed }
                }
                # Not $startUtc/$endUtc: PowerShell names are case-insensitive, and those overwrote the
                # $StartUtc/$EndUtc parameters, so every file was compared with itself and all 339
                # matched. Finding 309.
                $fileStartUtc = $start.ToUniversalTime()
                $fileEndUtc = $f.LastWriteTimeUtc
                if ($fileEndUtc -lt $StartUtc -and $fileStartUtc -le $EndUtc) {
                    $held = $false
                    $s = $null
                    try { $s = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'Read') } catch [System.IO.IOException] { $held = (($_.Exception.HResult -band 0xFFFF) -eq 32) } catch { $held = $false } finally { if ($s) { $s.Dispose() } }
                    if ($held) { $fileEndUtc = [datetime]::UtcNow }
                }
                if ($fileStartUtc -le $EndUtc -and $fileEndUtc -ge $StartUtc) { $f }
            })
        }

        [pscustomobject]@{
            Source = $source
            Files  = @($files |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First $Limit |
                ForEach-Object { [pscustomobject]@{ FullName = $_.FullName; Length = $_.Length; LastWriteTime = $_.LastWriteTime } })
        }
    } -ArgumentList $MaxFiles, $windowed, $WindowStartUtc, $WindowEndUtc, ${function:Get-TlcConsoleUserProfile}.ToString())

    $listing = @($listing | Where-Object { $_ -and $_.PSObject.Properties['Files'] }) | Select-Object -Last 1
    $remoteFiles = if ($listing) { @($listing.Files | Where-Object { $_ }) } else { @() }
    $logSource = if ($listing) { [string]$listing.Source } else { 'RemotingAccount' }

    $copied = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    # A session that dies mid-copy is not a locked file. Measured on the lab endpoint with the remote
    # wsmprovhost stopped after 3 files: every remaining file failed in milliseconds, the
    # endpoint was reported as collected, and the row blamed Teams for holding 27 logs open.
    # Finding 314.
    $sessionLost = $null
    $isLost = {
        param($ErrorRecord)
        if ([string]$Session.State -ne 'Opened') { return $true }
        $e = $ErrorRecord.Exception
        while ($e) {
            if ($e -is [System.Management.Automation.Remoting.PSRemotingTransportException]) { return $true }
            $e = $e.InnerException
        }
        return $false
    }
    foreach ($file in @($remoteFiles)) {
        $destination = Join-Path $logsPath (Split-Path $file.FullName -Leaf)
        try {
            Copy-Item -FromSession $Session -Path $file.FullName -Destination $logsPath -ErrorAction Stop
            $copied++
        } catch {
            $copyError = $_.Exception.Message
            if (& $isLost $_) {
                $sessionLost = $copyError
                if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
                break
            }
            # A file the client still holds open refuses Copy-Item -FromSession, and with a window
            # applied those are exactly the files that matter - the current client log, SlimCore,
            # the launcher. Measured: 5 of 12 in-window files on a live endpoint. Read them the
            # way the local collector does, with shared access, inside the session, and write the
            # bytes here. Nothing lands on the endpoint. Finding 309.
            try {
                $bytes = Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
                    param([string] $Path)
                    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                    try {
                        $buffer = [byte[]]::new($stream.Length)
                        $read = 0
                        while ($read -lt $buffer.Length) {
                            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
                            if ($n -le 0) { break }
                            $read += $n
                        }
                        , $buffer
                    } finally { $stream.Dispose() }
                } -ArgumentList $file.FullName
                [System.IO.File]::WriteAllBytes($destination, [byte[]]$bytes)
                $copied++
                continue
            } catch {
                $copyError = "$copyError; shared read also failed: $($_.Exception.Message)"
                if (& $isLost $_) {
                    $sessionLost = $copyError
                    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
                    break
                }
            }
            # THE PARTIAL FILE IS DELETED. Copy-Item -FromSession creates the destination and
            # then throws when the source cannot be read - which is the ordinary case here,
            # because the running Teams client holds its current logs open. Measured: four of
            # forty files failed, and all four landed as ZERO BYTES, including a 376 KB log.
            #
            # Left in place, that is absent evidence wearing the clothes of present evidence.
            # An engineer opens the empty log and concludes Teams wrote nothing during the
            # incident, which is a worse answer than a file that is honestly missing - and the
            # folder listing would agree with them, showing forty files while the inventory
            # said thirty-six.
            try {
                if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
            } catch {
                Write-Verbose "$Endpoint : a partial copy of $destination could not be removed: $($_.Exception.Message)"
            }
            $failed.Add((Split-Path $file.FullName -Leaf))
            Write-Verbose "$Endpoint : $($file.FullName) could not be copied: $($_.Exception.Message)"
        }
    }

    $inventory = [ordered]@{
        Endpoint       = $Endpoint
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        WindowStartUtc = if ($windowed) { ([datetime]$WindowStartUtc).ToString('o') } else { $null }
        WindowEndUtc   = if ($windowed) { ([datetime]$WindowEndUtc).ToString('o') } else { $null }
        # Whose profile the logs were read from: ConsoleUser, or RemotingAccount when nobody
        # was signed in or the profile could not be told. The name itself is not recorded.
        LogSource      = $logSource
        FilesOffered   = @($remoteFiles).Count
        FilesCopied    = $copied
        # Named, not just counted. "Four files could not be read" sends someone looking for
        # which four; naming them says whether the missing one is the log that mattered.
        FilesFailed    = @($failed)
        LogsPath       = $logsPath
        SessionLost    = [bool]$sessionLost
    }
    $inventory | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $EndpointPath 'Inventory.json') -Encoding utf8

    # Thrown after the inventory is written, so the run folder still records what did arrive,
    # and Invoke-TlcFleetCollection reports the endpoint as blocked at the Collect stage.
    if ($sessionLost) {
        throw "The remote session to $Endpoint was lost after $copied of $(@($remoteFiles).Count) log file(s) were copied: $sessionLost"
    }

    return $inventory
}

function Invoke-TlcInteractiveLaunch {
    <#
    .SYNOPSIS
        Launches something on an endpoint's interactive desktop, from a remote session.
    .DESCRIPTION
        A PSSession runs in session 0. The user's desktop - and the Teams client on it - is
        session 1. Start-Process over a session therefore launches something real that nobody
        can see and that never reaches the application. Measured on the lab endpoint: Teams in session 1,
        the PSSession in session 0.

        A scheduled task registered against the interactive user is the documented way across
        that boundary, and /IT is the part that matters: it runs only when that user is logged
        on, in their session.

        THE ACCOUNT CANNOT BE ASSUMED. The first attempt passed the bare username and failed
        with "No mapping between account names and security IDs was done", because the machine
        is Entra-joined and the interactive user is not a local account. The name is therefore
        read from the owner of the running explorer.exe, which is the process that IS the
        desktop - so it resolves whatever the account actually is rather than what the caller
        guessed. On the lab endpoint that returned CONTOSO\alice, which no amount of reasoning
        from "AzureAD\alice@contoso.com" would have produced.

        schtasks.exe rather than Register-ScheduledTask: the module cmdlet blocked indefinitely
        over a remote session and had to be killed. The executable returns an exit code and
        finishes.

        The task is deleted afterwards, always. A support tool that leaves scheduled tasks on an
        endpoint is one nobody will be allowed to run twice.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Command')]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory, ParameterSetName = 'Command')] [string] $Command,
        [Parameter(Mandatory, ParameterSetName = 'Url')] [string] $Url,
        [string] $TaskName = 'TLC-InteractiveLaunch'
    )

    # -Url exists so the join case cannot be got wrong. A raw URL passed as a command is
    # silently truncated at its first & - in a batch file that is a command separator, so
    # ...?context=...&anon=true runs "echo ...context..." and then tries to execute
    # "anon=true". Measured: the target file came back EMPTY rather than wrong, which is the
    # kind of failure that gets read as "the endpoint did not join" instead of "the tool
    # mangled the link".
    if ($PSCmdlet.ParameterSetName -eq 'Url') {
        $Command = '"' + $Url + '"'
    }

    return Invoke-Command -Session $Session -ScriptBlock {
        param([string] $Cmd, [string] $Task, [string] $ResolverText)

        # Inline, because this runs in a remote runspace with no toolbox modules loaded.
        # 5.1 turns a redirected native stderr line into a terminating error under Stop,
        # and Invoke-Command propagates the caller's preference into the session. Without
        # this the /Delete in the finally block can throw, leaving a scheduled task behind
        # on the endpoint that fires at 23:59 - the exact outcome the finally prevents.
        $ErrorActionPreference = 'Continue'

        # Win32_ComputerSystem.UserName is the domain-qualified interactive console user -
        # exactly the question being asked, from a single-instance class. The first version
        # enumerated Win32_Process for explorer.exe instead and took 179 SECONDS on the lab endpoint,
        # because Win32_Process computes properties for every process on the machine. This
        # returns the identical string, CONTOSO\alice, in 0.14s.
        $account = $null
        $system = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($system -and $system.UserName) { $account = [string]$system.UserName }

        if (-not $account) {
            # Null means nobody is logged on interactively - in which case there is no session
            # to launch into and /IT would never fire. explorer.exe's owner is consulted only
            # as a second opinion for the multi-session cases where the console user is blank.
            $explorer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($explorer) {
                $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
                if ($owner -and $owner.User) { $account = "$($owner.Domain)\$($owner.User)" }
            }
        }

        if (-not $account) {
            return [ordered]@{ Launched = $false; Detail = 'No interactive desktop is running on this endpoint, so there is no session to launch into.' }
        }

        # The script goes where the signed-in user can read it. The task runs as them, and it
        # used to be written to the remoting account's TEMP: on a real estate an administrator's
        # profile, which the user cannot read, so the task ran, failed on a path it could not
        # open, and was reported as Launched (review 2026-09-30, finding 331).
        $scriptFolder = $null
        $console = $null
        try { $console = & ([scriptblock]::Create($ResolverText)) -Account $account } catch { $console = $null }
        $ownProfile = $console -and $console.ProfilePath -and [string]::Equals(([string]$console.ProfilePath).TrimEnd('\'),
            ([string]$env:USERPROFILE).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
        if ($ownProfile -or (-not ($console -and $console.ProfilePath) -and [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -eq $account)) {
            $scriptFolder = $env:TEMP
        } elseif ($console -and $console.ProfilePath) {
            $scriptFolder = Join-Path $console.ProfilePath 'AppData\Local\Temp'
        }
        if (-not $scriptFolder -or -not (Test-Path -LiteralPath $scriptFolder)) {
            return [ordered]@{ Launched = $false; Account = $account; Detail = "$account's profile could not be found on this endpoint, so there is nowhere they could read the launch script from." }
        }

        $script = $null
        try {
            # Via a .cmd file rather than passing the command to /TR directly. schtasks parses
            # /TR's value itself and chokes on embedded quotes: a real join URL
            # (cmd /c start "" "https://...?context=...&x=y") was rejected outright with
            # "Invalid argument/option". Measured - the simple no-quote case passed and the
            # URL-shaped case failed, which would have broken at exactly the moment it mattered.
            #
            # Percent signs are doubled because this is a batch file and join URLs are full of
            # them (%22, %3a in the context blob). Undoubled, cmd expands %22Tid% as an unset
            # variable and silently rewrites the URL into something that still looks plausible.
            $script = Join-Path $scriptFolder ("$Task-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
            # "start" so the batch file returns immediately and the launched program outlives
            # it. Without this the finally block below deletes the task about two seconds after
            # /Run, and deleting a task terminates its running instance - so anything that takes
            # longer than the cleanup delay is killed mid-flight. Invisible while the proving
            # command was "cmd.exe /c exit 0", which had always finished by then; a joiner that
            # waits for a pre-join screen never ran at all and left no log to say why.
            $body = "@echo off`r`nstart `"`" " + ($Cmd -replace '%', '%%') + "`r`n"
            [System.IO.File]::WriteAllText($script, $body, (New-Object System.Text.ASCIIEncoding))

            $created = & schtasks.exe /Create /TN $Task /TR $script /SC ONCE /ST 23:59 /F /RU $account /IT 2>&1
            if ($LASTEXITCODE -ne 0) {
                return [ordered]@{ Launched = $false; Account = $account; Detail = "Task could not be created: $($created | Select-Object -First 1)" }
            }
            $null = & schtasks.exe /Run /TN $Task 2>&1
            $ranExit = $LASTEXITCODE
            if ($ranExit -ne 0) {
                return [ordered]@{ Launched = $false; Account = $account; Detail = "The task was created but would not run (exit $ranExit)." }
            }

            # /Run succeeding means the task was queued, not that the script ran. The task's
            # own last result says whether it did: 0 is the script's exit code, and anything
            # else, including "has not yet run" once the wait is over, is not a launch. Read
            # through the Task Scheduler COM API, whose values do not depend on the display
            # language the way schtasks /Query's labels do.
            $notYetRun = 267011
            $running = 267009
            $lastResult = $null
            try {
                $service = New-Object -ComObject 'Schedule.Service'
                $service.Connect()
                $deadline = (Get-Date).AddSeconds(10)
                do {
                    Start-Sleep -Milliseconds 500
                    $lastResult = [int]$service.GetFolder('\').GetTask($Task).LastTaskResult
                } while ($lastResult -eq $notYetRun -and (Get-Date) -lt $deadline)
            } catch {
                $lastResult = $null
            }

            if ($null -eq $lastResult) {
                Start-Sleep -Seconds 2
                return [ordered]@{ Launched = $true; Confirmed = $false; Account = $account
                    Detail = "Started in $account's session. Whether the script ran could not be read back from Task Scheduler." }
            }
            if ($lastResult -eq 0 -or $lastResult -eq $running) {
                return [ordered]@{ Launched = $true; Confirmed = $true; Account = $account; Detail = "Launched in $account's session." }
            }
            if ($lastResult -eq $notYetRun) {
                return [ordered]@{ Launched = $false; Confirmed = $true; Account = $account
                    Detail = "The task was queued but had not run in $account's session after 10 seconds. It runs only while they are signed in at the desktop." }
            }
            return [ordered]@{ Launched = $false; Confirmed = $true; Account = $account
                Detail = ("The launch script failed in $account's session (task result 0x{0:X8})." -f $lastResult) }
        } finally {
            # In finally: a task left behind outlives the run and would fire at 23:59, and the
            # script file would sit in the user's temp advertising what the tool did.
            & schtasks.exe /Delete /TN $Task /F 2>&1 | Out-Null
            if ($script) { Remove-Item $script -Force -ErrorAction SilentlyContinue }
        }
    } -ArgumentList $Command, $TaskName, ${function:Get-TlcConsoleUserProfile}.ToString()
}

function Get-TlcCallMarker {
    <#
    .SYNOPSIS
        A record of every attempt to detect a Teams call from client logs, and why the toolbox
        no longer tries.
    .DESCRIPTION
        THE DECISION: this toolbox does not detect calls from client logs. What follows is kept
        so the attempt is not repeated, not as a capability.

        Four vocabularies were proposed and all four were disproved by the next measurement,
        and the one behavioural detector that was supposed to be immune to vocabulary was
        disproved as well. The pattern was identical every time - a signal that looked
        convincing on the sample that produced it, and collapsed on the sample that did not.

        A detector was first written against CallStarted, MediaSession, ActiveCall,
        CallController, jitter, bitrate and packet. All plausible, none real: a call was
        captured and not one of the seven appears anywhere in either endpoint's logs.

        RegisterCall and UnregisterCall replaced them, on the strength of twelve occurrences on
        the endpoint that had just been on a call. A second capture disproved that: with a
        meeting live on one machine and the other idle, the IDLE machine showed twelve and the
        active one showed one. The full line is
        "SlimCoreModule::WindowContentProtectionProvider: RegisterCall" - window content
        protection registering an interest, not a call beginning.

        MeetingJoin and calling then replaced THOSE, on a single capture where they tracked the
        busy endpoint 3-to-1 and 20-to-1. A controlled two-endpoint call disproved both. With
        the SAME meeting joined from two machines, each showed exactly 2 of each - and reading
        the lines instead of counting them showed why:

            MeetingJoin  ->  "IsBlockAnonymousMeetingJoinEnabled: BlockAnonymousMeetingJoin
                              regkey = false"        a policy check run at launch
            calling      ->  "RendererContext: Calling CanvasDevice::Trim()"
                              the English word "calling", in a graphics call

        Neither has anything to do with a Teams call. The symmetric 2-and-2 looked far MORE
        convincing than the earlier lopsided counts, and was just as wrong. Counting a term
        across two endpoints tests only that both clients run the same code paths.

        meetup-join is not a marker either, and is the trap worth naming: it appears in the logs
        only because a join URL was launched from outside, and the line is
        "PipeClient: Sending message to server: {"cmd_line":"msteams:/l/meetup-join/..."}".
        That is the tool's own footprint being read back as evidence about the client. A call
        started from the Teams UI writes none of it.

        NOTHING IN THE VOCABULARY HAS SURVIVED CONTACT WITH A SECOND MEASUREMENT. Four attempts,
        four demotions. Do not use any term below to decide whether a call happened.

        Behaviour was no better, and it was the part claimed to be immune. SlimCore media-stack
        growth was right in the first two captures and was described as something that "cannot
        change - a call has to make the stack do something". It was then disproved twice: in the
        controlled two-endpoint call NEITHER endpoint's SlimCore logs grew while both were
        demonstrably in the meeting, and a solo Meet now with real audio hardware selected and a
        full join grew by exactly 0 bytes over 120 seconds. On build 26225 the rolling client
        logs carry no media telemetry at all.

        WHERE THE ANSWER ACTUALLY IS. Media statistics live in the diagnostic bundle
        (MSTeams Diagnostics Log*, produced by Ctrl+Alt+Shift+1), which Get-TlcSupportFileEvidence
        already harvests and which ScenarioCatalog.psd1 already classifies as Prompted rather
        than Auto - because it needs a human keystroke. Call-quality truth for a tenant lives in
        CQD and Call Analytics. Both are supported sources. Neither is a string search.

        So the answer to "did a call happen" is: read the diagnostic bundle, or ask the service.
        Do not infer it from these logs, and do not add a term to the Observed set below without
        a capture that includes a control - a call known to carry no media. The absence of that
        control is what let a two-sample agreement pass for corroboration.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        # Deliberately empty, and intended to stay that way. Every candidate has been disproved
        # by a later measurement, and shipping a "best guess so far" invites exactly the
        # reasoning that produced four wrong answers in a row.
        Observed  = @()
        # The media-stack namespace. Present in the logs whether or not a call is happening.
        Namespace = @('SlimCoreModule')
        # Searched for and found absent, or found and shown not to mean what it looked like.
        # Kept so nobody re-derives them. RegisterCall, MeetingJoin and calling in particular
        # all read exactly like call markers and none of them is one.
        Disproved = @('CallStarted', 'MediaSession', 'ActiveCall', 'CallController',
                      'jitter', 'bitrate', 'packet', 'RegisterCall', 'UnregisterCall',
                      'MeetingJoin', 'calling', 'meetup-join')
        # Retained only to locate the files, NOT as a detector. Measured at zero growth through
        # a real call with audio on this build, and scanned during a live meeting with zero
        # occurrences of jitter, packetLoss, bitrate, roundTrip, mos, codec or bandwidth.
        MediaLogPattern = '*SlimCore*'
        # WHERE THE MEDIA STATISTICS ARE NOT. Both candidates were checked during a real call
        # on 2026-09-10 and both came back empty: the web log bundle's web-media-logs.txt,
        # web-media-telemetry.txt and web-media-diagnostics-info.json are 0 bytes because they
        # belong to the WEB client and this was a desktop call, and the SlimCore rolling logs
        # carry no media vocabulary at all. See finding 154.
        #
        # What the bundle does carry is call setup and state history - calling-debug.txt, with
        # extendedCallStateHistory, stateTime and elapsedTime - which answers "where did the
        # join stall" and is not call quality. Quality lives in the ETW traces Teams support
        # collects separately, and in CQD or Call Analytics service-side.
        MediaEvidenceSource = 'NOT in any locally collected artifact. calling-debug.txt in the web log bundle carries call setup and state timings; quality metrics need ETW traces or CQD.'
    }
}

function Invoke-TlcSmbClientLogCollection {
    <#
    .SYNOPSIS
        Collects Teams client logs from an endpoint over its administrative share.
    .DESCRIPTION
        The second fleet transport, and on a workgroup estate usually the only one available.

        WinRM needs a listener configured ON the endpoint. Measured 2026-09-09: the lab endpoint is up,
        already trusted by this machine, and has SMB and RDP open - but no WinRM listener, so
        the session transport cannot reach it without somebody running Enable-PSRemoting there.
        Its administrative share answered immediately with the same account. A support tool that
        requires reconfiguring the machine being supported has a much narrower set of estates it
        can help than one that does not.

        The trade is worth stating plainly rather than hiding. This needs administrative access
        to the endpoint, which is a real requirement; what it does NOT need is any change to the
        endpoint, any service enabled, or any firewall rule added. Nothing is executed remotely
        either - files are read over the share, so there is no remote code path to justify to a
        security team at all.

        Which user's logs is a decision, not a default. A machine can hold several profiles -
        the lab endpoint has three - and Teams logs live under a specific one. Collecting the wrong
        profile produces a bundle that looks complete and describes somebody else, so the
        profile is resolved explicitly and a machine with no matching Teams client is reported
        as such rather than returning an empty success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Endpoint,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [Parameter(Mandatory)] [string] $UserName,
        [int] $MaxFiles = 40,
        # Injectable so the copy logic, the profile resolution and the no-client case can be
        # exercised without a second machine. Defaults to the endpoint's administrative share,
        # which is what every real call uses.
        [string] $ShareRoot
    )

    $share = if ($ShareRoot) { $ShareRoot } else { "\\$Endpoint\C$" }
    if (-not (Test-Path -LiteralPath $share)) {
        throw "The administrative share $share is not reachable, so logs cannot be read over SMB."
    }

    $logRoot = Join-Path (Join-Path $share "Users\$UserName") 'AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
    if (-not (Test-Path -LiteralPath $logRoot)) {
        # Not an error. A machine without the new Teams client, or a profile that has never run
        # it, is an ordinary finding - and one worth reporting rather than throwing, because the
        # caller is collecting from several machines and this one simply has nothing.
        #
        # Written to Inventory.json like every other outcome. The early return used to write
        # nothing, so the endpoint folder held no record that it had been looked at (review
        # 2026-09-30, finding 331).
        $none = [ordered]@{
            Endpoint = $Endpoint; Transport = 'Smb'; UserName = $UserName
            CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            FilesOffered = 0; FilesCopied = 0; FilesFailed = @()
            LogsPath = $null
            Detail = "No Teams log folder for $UserName on $Endpoint."
        }
        $null = New-Item -ItemType Directory -Path $EndpointPath -Force
        $none | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $EndpointPath 'Inventory.json') -Encoding utf8
        return $none
    }

    $logsPath = Join-Path $EndpointPath 'ClientLogs'
    $null = New-Item -ItemType Directory -Path $logsPath -Force

    $files = @(Get-ChildItem -LiteralPath $logRoot -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First $MaxFiles)

    $copied = 0
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $files) {
        $destination = Join-Path $logsPath $file.Name
        try {
            Copy-Item -LiteralPath $file.FullName -Destination $destination -ErrorAction Stop
            $copied++
        } catch {
            # Same rule as every other copy in this toolbox: the destination is created before
            # the copy fails, so a locked source leaves a zero-byte file that reads as an empty
            # log rather than a missing one. See findings 129 and 133.
            if (Test-Path -LiteralPath $destination) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
            $failed.Add($file.Name)
            Write-Verbose "$Endpoint : $($file.Name) could not be copied: $($_.Exception.Message)"
        }
    }

    $inventory = [ordered]@{
        Endpoint       = $Endpoint
        Transport      = 'Smb'
        UserName       = $UserName
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        FilesOffered   = $files.Count
        FilesCopied    = $copied
        FilesFailed    = @($failed)
        LogsPath       = $logsPath
        Detail         = "Collected over the administrative share on $Endpoint."
    }
    $inventory | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $EndpointPath 'Inventory.json') -Encoding utf8

    return $inventory
}

function Compare-TlcEndpoint {
    <#
    .SYNOPSIS
        What two endpoints in one run agree on, and what they do not.
    .DESCRIPTION
        Built for a specific experiment: sign one account into Teams on two machines, put both
        on the same call, and collect from both in one correlated run. The service is then held
        constant, so a difference in behaviour is attributable to the machines.

        That reasoning only holds if everything else really did match, and this is what checks
        it. An engineer comparing two endpoints will otherwise assume the client versions were
        the same because both machines are managed, and attribute a difference to hardware when
        it was a build gap. The comparison reports the matches as prominently as the
        differences, because the matches are what license the conclusion.

        It compares only what the toolbox already parses and has actually seen: client version,
        platform, log inventory and update history. Media and call-quality metrics are
        deliberately absent - measured 2026-09-09, neither machine here has ever been in a call,
        so a media comparison would be written against field names nobody has looked at. That
        is exactly the confident-wrong-answer failure this toolbox exists to avoid, and it will
        be worth building the moment one real call has been captured.

        Differences are not verdicts. A machine with fewer log files may be newer, quieter, or
        rotating faster; the tool says the numbers differ and by how much, and leaves the
        meaning to somebody who knows why the machines exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Left,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Right
    )

    $matched = [System.Collections.Generic.List[object]]::new()
    $differed = [System.Collections.Generic.List[object]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()

    $leftName = if ($Left.Contains('Endpoint')) { [string]$Left.Endpoint } else { 'left' }
    $rightName = if ($Right.Contains('Endpoint')) { [string]$Right.Endpoint } else { 'right' }

    foreach ($field in 'ClientVersion', 'Platform', 'UserName', 'FileCount', 'TotalBytes', 'OldestStart', 'NewestWrite') {
        $hasLeft = $Left.Contains($field) -and $null -ne $Left[$field]
        $hasRight = $Right.Contains($field) -and $null -ne $Right[$field]

        # A field missing on one side is neither a match nor a difference. Reporting it as
        # either would be inventing a comparison that was never made - and "these agreed" is
        # the claim the whole experiment rests on, so it has to mean what it says.
        if (-not $hasLeft -or -not $hasRight) {
            $unknown.Add($field)
            continue
        }

        $l = $Left[$field]
        $r = $Right[$field]
        $entry = [ordered]@{ Field = $field; Left = $l; Right = $r }

        if ([string]$l -eq [string]$r) {
            $matched.Add($entry)
        } else {
            # Numeric fields carry the size of the gap. "214 files versus 79" is a fact; "these
            # differ" sends the reader back to the raw evidence to work out by how much.
            if ($l -is [ValueType] -and $r -is [ValueType] -and $l -isnot [datetime]) {
                $entry['Delta'] = [double]$r - [double]$l
            }
            $differed.Add($entry)
        }
    }

    # @() around the filter. Without it, a single match returns one [ordered] hashtable rather
    # than an array, and .Count on a hashtable is its KEY count - so one matched field reported
    # "3 controlled variables matched", because the entry has three keys.
    #
    # That is not a cosmetic miscount. This number is the licence for the whole experiment: it
    # says how many of the things that must have been equal actually were. Reporting three when
    # one matched tells an engineer the client versions and platforms agreed when they were
    # never compared at all, which is precisely the confident wrong answer the comparison exists
    # to prevent.
    $controlled = @($matched | Where-Object { $_.Field -in 'ClientVersion', 'Platform', 'UserName' })

    return [ordered]@{
        Left       = $leftName
        Right      = $rightName
        Matched    = @($matched)
        Differed   = @($differed)
        NotCompared= @($unknown)
        # The claim the experiment depends on, stated rather than implied.
        Controlled = $controlled.Count
        ControlledFields = @($controlled | ForEach-Object { $_.Field })
        Summary    = "{0} field(s) matched, {1} differed, {2} could not be compared." -f `
                        $matched.Count, $differed.Count, $unknown.Count
    }
}

Export-ModuleMember -Function Invoke-TlcFleetCollection, Get-TlcFleetEndpoint, Invoke-TlcFleetPrivacyGate, Get-TlcFleetReadiness, Invoke-TlcRemoteClientLogCollection, Invoke-TlcSmbClientLogCollection, Compare-TlcEndpoint, Get-TlcCallMarker, Invoke-TlcInteractiveLaunch
