Set-StrictMode -Version Latest

<#
    Network collector.

    Scope note: the authoritative quality measurements belong to the Network
    Assessment Tool and the Microsoft 365 connectivity test, which stay in the
    Manual lane. What this module adds is the local context those tools do not
    capture and which support otherwise has to ask for by email - adapter state,
    DNS, proxy configuration, and whether the media path is actually usable from
    this machine right now.
#>

function Import-TlcCollectorData {
    <#
    .SYNOPSIS
        Reads a .psd1 without depending on Import-PowerShellDataFile.
    .DESCRIPTION
        Import-PowerShellDataFile lives in Microsoft.PowerShell.Utility, and a module loaded
        through the manifest does not get that module in its session state the way a directly
        imported one does - so the cmdlet is missing exactly when the toolbox is run for real
        and present in every test, which imports the .psm1 directly.

        Tlc.Config.psm1, Tlc.Manual.psm1, Tlc.Scope.psm1 and Tlc.Localization.psm1 each carry
        the same helper for the same reason. The calls in THIS module were left behind when
        those were fixed, which made them latent: the data files they read are optional, so a
        failure here degrades to "could not be read" rather than throwing, and the degraded
        path looks identical to a missing file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string] $Path)

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $parseErrors)
    if ($parseErrors -and $parseErrors.Count) {
        throw "Data file could not be parsed: $Path. $($parseErrors[0].Message)"
    }

    $hashtable = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $hashtable) { throw "Data file does not contain a hashtable: $Path" }

    return $hashtable.SafeGetValue()
}

function Get-TlcNetworkIntermediation {
    <#
    .SYNOPSIS
        Detects tunnelling clients that carry Teams traffic away from the direct path.
    .DESCRIPTION
        Get-VpnConnection answers for classic dial-up-style VPN profiles and nothing
        else. The whole modern SASE/ZTNA class - Entra Global Secure Access, Zscaler,
        Netskope, Cloudflare WARP - runs as a set of services that hook the network
        stack, creating no VPN connection object at all. A machine can therefore have
        every byte of its Teams traffic tunnelled while the toolbox reports a clean,
        direct network.

        That is not a hypothetical. The machine this was written on runs Global Secure
        Access: teams.microsoft.com resolved through four CNAMEs to 6.6.0.40 - a
        synthetic address, not a Microsoft one - and the media edge to 6.6.0.103, with
        ICMP dead to both. The TCP and STUN checks in this module were measuring through
        the tunnel and had no way to say so.

        Detection is by service name because that is what is cheap and reliable.
        Measured: a targeted Get-Service against this pattern list is ~12 ms warm,
        against ~500 ms to enumerate all 320 services. Routes are deliberately not used
        as the signal - Find-NetRoute for the Teams Optimize ranges still reported the
        physical adapter on a machine that was demonstrably tunnelled, because the
        client hooks below the route table.

        Every pattern ends in a wildcard. Service names drift between product versions,
        and a wildcard that matches nothing returns quietly while a literal name that
        matches nothing raises an error.
    #>
    [CmdletBinding()]
    param([switch] $IncludeVpnProfiles)

    # Kind separates "all traffic may be redirected" from "this is a VPN the user
    # dialled". Both matter; they do not mean the same thing.
    #
    # PROVENANCE. Every short name below was taken from vendor documentation that shows the
    # service being operated on - a `net stop`, an `sc delete`, a `New-Service`, or a literal
    # HKLM\SYSTEM\CurrentControlSet\Services\<name> registry export. None was inferred from a
    # product name, a display name or an executable name, because those differ from the short
    # name often enough that guessing produces a check that can never fire. A wrong name here
    # fails SILENTLY and reports a tunnelled machine as direct, which is worse than no check.
    #
    # Deliberately NOT shipped, because no vendor documentation could be found naming a
    # Windows service - each would be a check that never fires:
    #   Citrix Secure Access  - docs name the PROCESS nsload.exe; "AlwaysOnService" is a
    #                           registry value, not a service. Needs process detection.
    #   iboss                 - only "ibsa", from a third-party forum post.
    #   Menlo Security        - no public endpoint documentation.
    #   Absolute Secure Access- only SERVER-side names are published (NmService, NmReporting
    #                           and friends). Those will never appear on a client, so shipping
    #                           them as an endpoint check would be actively misleading.
    #   SonicWall Mobile Connect - a Store/UWP app on the Windows VPN platform, so a service
    #                           probe cannot fire at all. Detect via the VPN profile instead.
    #
    # Also deliberately absent: Ivanti's `dsAccessService`. That string circulates widely, but
    # in Ivanti's own registry export the DSAccess* strings are COM interface and ProgID names
    # (IDSAccessService, PulseSecureServicePS.DSAccessPluginMonitor), not a service key.
    $catalog = @(
        @{ Product = 'Entra Global Secure Access'; Kind = 'SASE'; Services = @('GlobalSecureAccess*') }
        @{ Product = 'Zscaler';                    Kind = 'SASE'; Services = @('ZSAService*', 'ZSATunnel*', 'ZSATrayManager*') }
        @{ Product = 'Netskope';                   Kind = 'SASE'; Services = @('stAgentSvc*', 'nsltunnel*') }
        @{ Product = 'Cloudflare WARP';            Kind = 'SASE'; Services = @('CloudflareWARP*') }
        @{ Product = 'Cisco Umbrella';             Kind = 'SASE'; Services = @('Umbrella*', 'csc_umbrellaagent*') }
        @{ Product = 'Forcepoint';                 Kind = 'SASE'; Services = @('FeAgent*') }
        @{ Product = 'Palo Alto GlobalProtect';    Kind = 'VPN';  Services = @('PanGPS*') }
        @{ Product = 'Cisco Secure Client';        Kind = 'VPN';  Services = @('vpnagent*', 'acvpnagent*', 'csc_vpnagent*') }
        @{ Product = 'FortiClient';                Kind = 'VPN';  Services = @('FortiSSLVPNdaemon*', 'FA_Scheduler*') }

        # Added 2026-09-16. Sources in order below.
        #
        # help.ivanti.com registry-settings page carries the literal service key for
        # PulseSecureService plus its companion virtual-adapter manager. The name survives into
        # the current Ivanti-branded 22.x client. A newer "Ivanti Secure Access Service" DISPLAY
        # name exists; its short name is not published, and a wildcard on Ivanti* would collide
        # with unrelated Ivanti endpoint products, so it is not guessed at here.
        @{ Product = 'Ivanti Secure Access (Pulse Secure)'; Kind = 'VPN'; Services = @('PulseSecureService*', 'JnprVaMgr*') }

        # my.f5.com K8253 gives `sc stop "F5 Networks Component Installer"` and `sc stop F5FltSrv`
        # verbatim; techdocs.f5.com documents the F5MachineTunnelService parameters key.
        #
        # NOTE there is no single "Edge Client" service: the tunnel itself is user-mode
        # (f5vpn.exe). These are helpers, so presence is a signal and ABSENCE IS INCONCLUSIVE -
        # an F5 tunnel can be up with none of them matching.
        @{ Product = 'F5 BIG-IP Edge Client'; Kind = 'VPN'; Services = @('F5FltSrv*', 'F5MachineTunnelService*', 'F5 Networks Component Installer*') }

        # Check Point Remote Access Clients admin guide: "To stop the service: net stop
        # tracsrvwrapper". sk97638 maps TracSrvWrapper.exe to the Remote Access VPN blade.
        @{ Product = 'Check Point Endpoint Security VPN'; Kind = 'VPN'; Services = @('TracSrvWrapper*') }

        # Cato KB, Windows client connection flow: "Cato Client SDP service
        # (CatoNetworksVPNService)". Note it does not match the process name CatoClient.exe.
        @{ Product = 'Cato Networks';        Kind = 'SASE'; Services = @('CatoNetworksVPNService*') }

        # Broadcom techdocs for the Cloud SWG agent: "sc start wssad".
        @{ Product = 'Symantec Cloud SWG (WSS Agent)'; Kind = 'SASE'; Services = @('wssad*') }

        # SonicWall KB: "sc delete SonicWall_NetExtender". NEService is the Linux unit and the
        # Windows binary name, NOT a Windows short name, so it is not probed.
        @{ Product = 'SonicWall NetExtender'; Kind = 'VPN'; Services = @('SonicWall_NetExtender*') }

        # OpenVPN support article names the agent service for Connect v3 (ovpnagent.exe). The
        # separate community GUI uses a different name that could not be verified.
        @{ Product = 'OpenVPN Connect';      Kind = 'VPN';  Services = @('agent_ovpnconnect*') }

        # WatchGuard KB gives a literal New-Service -Name "wgsslvpnsrc" re-registration command.
        @{ Product = 'WatchGuard Mobile VPN'; Kind = 'VPN'; Services = @('wgsslvpnsrc*') }
    )

    $found = foreach ($entry in $catalog) {
        $services = @(Get-Service -Name $entry.Services -ErrorAction SilentlyContinue)
        if ($services.Count -eq 0) { continue }

        $running = @($services | Where-Object { $_.Status -eq 'Running' })
        [ordered]@{
            Product  = $entry.Product
            Kind     = $entry.Kind
            # Installed but stopped is a different fact from installed and running, and
            # the difference decides whether it is carrying traffic right now.
            Running  = ($running.Count -gt 0)
            Services = @($services | ForEach-Object { [ordered]@{ Name = $_.Name; Status = "$($_.Status)" } })
        }
    }

    $tunnels = @($found)

    # A connected point-to-point or tunnel adapter, which is what a classic VPN leaves
    # behind. Read through the .NET API rather than Get-NetAdapter: measured at 76 ms
    # against 4.0 s for the cmdlet, and this runs behind a dashboard tile.
    #
    # Only Ppp and Tunnel are treated as evidence. An earlier version also flagged any
    # unrecognised interface type, which matched an Xbox Wireless Adapter reporting type
    # 281 - a false positive that would have shipped as "VPN detected".
    $tunnelAdapters = @(
        try {
            [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object {
                    $_.OperationalStatus -eq 'Up' -and
                    ($_.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp -or
                     $_.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel)
                } | ForEach-Object {
                    [ordered]@{ Name = $_.Name; Description = $_.Description; Type = "$($_.NetworkInterfaceType)" }
                }
        } catch {
            Write-Verbose "Network interfaces could not be enumerated: $($_.Exception.Message)"
        }
    )

    # Get-VpnConnection is measured at ~1.4 s, which is most of the cost of this
    # function. It adds profile names and split-tunnel state - worth having in a bundle,
    # not worth making a window wait for - so the caller decides.
    $vpn = @()
    if ($IncludeVpnProfiles) {
        $vpn = @(Get-VpnConnection -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{
                Name             = $_.Name
                ConnectionStatus = "$($_.ConnectionStatus)"
                SplitTunneling   = $_.SplitTunneling
                ServerAddress    = $_.ServerAddress
            }
        })
    }
    $vpnConnected = @($vpn | Where-Object { $_.ConnectionStatus -eq 'Connected' })

    $active = @($tunnels | Where-Object { $_.Running })

    # The kind and the names are returned beside the English summary so the window can say
    # the same thing in the operator's language (Get-TlcNetworkPathPart). The summary itself
    # stays English: it is written into the bundle and quoted in findings.
    $summaryKind = 'Direct'
    $summaryNames = ''
    if ($active.Count -gt 0) {
        $summaryKind = 'Products'
        $summaryNames = ($active | ForEach-Object { $_.Product }) -join ', '
    } elseif ($vpnConnected.Count -gt 0) {
        $summaryKind = 'Vpn'
        $summaryNames = ($vpnConnected | ForEach-Object { $_.Name }) -join ', '
    } elseif ($tunnelAdapters.Count -gt 0) {
        $summaryKind = 'VpnAdapter'
        $summaryNames = ($tunnelAdapters | ForEach-Object { $_.Name }) -join ', '
    } elseif ($tunnels.Count -gt 0) {
        $summaryKind = 'Installed'
        $summaryNames = ($tunnels | ForEach-Object { $_.Product }) -join ', '
    }
    $summary = switch ($summaryKind) {
        'Products'   { $summaryNames }
        'Vpn'        { 'VPN: ' + $summaryNames }
        'VpnAdapter' { 'VPN adapter: ' + $summaryNames }
        'Installed'  { $summaryNames + ' (installed, not running)' }
        default      { 'Direct' }
    }

    $activeCount = $active.Count + $vpnConnected.Count + $tunnelAdapters.Count

    return [ordered]@{
        Tunnels          = $tunnels
        TunnelAdapters   = $tunnelAdapters
        VpnConnections   = $vpn
        VpnProfilesRead  = [bool]$IncludeVpnProfiles
        ActiveCount      = $activeCount
        Intermediated    = ($activeCount -gt 0)
        Summary          = $summary
        SummaryKind      = $summaryKind
        SummaryNames     = $summaryNames
        CollectedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Resolve-TlcDnsChain {
    <#
    .SYNOPSIS
        Records the full CNAME chain and final addresses for a name.
    .DESCRIPTION
        The chain is the evidence, not just the answer. teams.microsoft.com goes through
        four CNAMEs before reaching an A record, and on an intermediated machine that
        final address is synthetic - 6.6.0.40 rather than anything Microsoft owns. An
        engineer who sees only the last hop cannot tell a healthy resolution from a
        rewritten one.

        Note that Resolve-DnsName -Type A returns the CNAME records too, and only the
        last entry carries IPAddress. Reading .IPAddress off the first result yields
        nothing, which looks exactly like a resolution failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $HostName)

    try {
        $records = @(Resolve-DnsName -Name $HostName -Type A -ErrorAction Stop)
    } catch {
        return [ordered]@{
            HostName = $HostName
            Resolved = $false
            Detail   = $_.Exception.Message
            Chain    = @()
            Addresses = @()
        }
    }

    $chain = @($records | ForEach-Object {
        $hop = [ordered]@{ Name = $_.Name; Type = "$($_.Type)" }
        if ($_.PSObject.Properties['NameHost'] -and $_.NameHost) { $hop['NameHost'] = $_.NameHost }
        if ($_.PSObject.Properties['IPAddress'] -and $_.IPAddress) { $hop['IPAddress'] = $_.IPAddress }
        $hop
    })

    $addresses = @($records | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } |
                    ForEach-Object { $_.IPAddress })

    return [ordered]@{
        HostName  = $HostName
        Resolved  = ($addresses.Count -gt 0)
        Chain     = $chain
        Addresses = $addresses
        HopCount  = $chain.Count
    }
}

function Get-TlcNetworkFact {
    <#
    .SYNOPSIS
        Captures local network configuration relevant to Teams.
    #>
    [CmdletBinding()]
    param()

    $adapters = foreach ($adapter in Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') {
        # An adapter that is Up can still have no IP interface (for example a
        # loopback or filter adapter). Get-NetIPConfiguration writes a non-
        # terminating error from a nested cmdlet that -ErrorAction does not
        # suppress, so it is caught explicitly - a collector that prints errors it
        # has already handled makes the whole bundle look unreliable.
        $config = $null
        try {
            $config = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction Stop 2>$null
        } catch {
            Write-Verbose "No IP configuration for interface $($adapter.ifIndex)."
        }
        [ordered]@{
            Name          = $adapter.Name
            InterfaceType = $adapter.InterfaceDescription
            # Get-NetAdapter returns LinkSpeed pre-formatted ("1 Gbps"); Speed is the
            # numeric bits-per-second. Record the string as-is rather than parsing it.
            LinkSpeed     = "$($adapter.LinkSpeed)"
            IsWireless    = ($adapter.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11')
            IPv4Address   = if ($config -and $config.IPv4Address) { @($config.IPv4Address.IPAddress) } else { @() }
            DefaultGateway= if ($config -and $config.IPv4DefaultGateway) { @($config.IPv4DefaultGateway.NextHop) } else { @() }
            DnsServers    = if ($config -and $config.DNSServer) { @($config.DNSServer | Where-Object AddressFamily -eq 2 | ForEach-Object { $_.ServerAddresses }) } else { @() }
        }
    }

    return [ordered]@{
        ComputerName   = $env:COMPUTERNAME
        DomainJoined   = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain
        Adapters       = @($adapters)
        VpnConnections = @(Get-VpnConnection -ErrorAction SilentlyContinue | ForEach-Object {
                            [ordered]@{ Name = $_.Name; ConnectionStatus = "$($_.ConnectionStatus)"; SplitTunneling = $_.SplitTunneling } })
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-TlcWifiFact {
    <#
    .SYNOPSIS
        The wireless radio's state and, when it is carrying traffic, its quality.
    .DESCRIPTION
        Named in metrics-gap-analysis.md as a gap and left unbuilt: CQD treats Wi-Fi strength as
        a dimension, so a call-quality bundle that cannot say whether the machine was on Wi-Fi at
        all is missing the first question anyone asks. A weak radio, a 2.4 GHz band, or a roam
        mid-call explains a class of "bad audio" that looks like a network fault from every other
        angle.

        TWO SOURCES, and the split is deliberate.

        Presence and link state come from Get-NetAdapter, whose PhysicalMediaType and Status are
        structured values that do not change with the display language. Radio detail comes from
        netsh, which is the only thing that reports signal, band and rates - and whose output IS
        localised. So the language-independent half is never at the mercy of the localised half:
        on a German or Japanese machine the adapter facts still land even if every netsh label
        misses.

        FOUR ANSWERS, not two, for the reason findings 217 and 221 exist. A probe that cannot
        tell must say so rather than return the reassuring answer:

          NotPresent    no 802.11 adapter exists. Definitive, and useful - it means Wi-Fi is
                        excluded as a cause rather than unexamined.
          Disconnected  a radio exists but carried nothing. Also definitive: the media went over
                        something else, and the Wi-Fi signal is irrelevant to this call.
          Connected     the radio was associated, with whatever detail could be read.
          Unknown       the adapter query failed, or netsh answered in a way this cannot parse.
                        NEVER reported as NotPresent, because "no Wi-Fi here" is exactly the
                        false clean that stops an engineer looking.

        PRIVACY. SSID and BSSID are identifiers - an SSID frequently names the customer, and a
        BSSID is an access point's MAC. Both are masked through Protect-TlcIdentifier, which is
        stable, so two bundles from the same site still correlate without the bundle restating
        the address. Flagged in metrics-gap-analysis.md before this was written; honoured here.

        Measured on the development machine 2026-09-16: one Marvell AVASTAR interface, radio
        hardware and software both on, State "disconnected" while Ethernet carried the traffic -
        which is the Disconnected answer above, and is why that state is reported rather than
        folded into "no Wi-Fi".
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $fact = [ordered]@{
        State          = 'Unknown'
        AdapterCount   = 0
        Description    = ''
        RadioStatus    = ''
        Ssid           = ''
        Bssid          = ''
        SignalPercent  = $null
        RadioType      = ''
        Band           = ''
        Channel        = ''
        ReceiveMbps    = $null
        TransmitMbps   = $null
        Detail         = ''
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    # 1. Presence and state, language-independent.
    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.PhysicalMediaType -and $_.PhysicalMediaType -match '802\.11' })
    } catch {
        $fact.Detail = "The adapter list could not be read: $($_.Exception.Message)"
        return $fact
    }

    $fact.AdapterCount = $adapters.Count
    if ($adapters.Count -eq 0) {
        $fact.State = 'NotPresent'
        $fact.Detail = 'No 802.11 adapter is present, so Wi-Fi is not a factor in this collection.'
        return $fact
    }

    $primary = $adapters[0]
    $fact.Description = [string]$primary.InterfaceDescription
    # 'Up' is what Get-NetAdapter reports for an associated wireless adapter.
    $fact.State = if ([string]$primary.Status -eq 'Up') { 'Connected' } else { 'Disconnected' }

    if ($fact.State -eq 'Disconnected') {
        $fact.Detail = 'A wireless adapter is present but was not associated, so the media did not travel over it.'
        return $fact
    }

    # 2. Radio detail, best effort, localisation-tolerant.
    if (-not (Get-Command netsh.exe -ErrorAction SilentlyContinue)) {
        $fact.Detail = 'Connected, but netsh is unavailable so no radio detail could be read.'
        return $fact
    }

    $probe = $null
    try {
        $probe = Invoke-TlcNativeCommand -FilePath 'netsh.exe' -ArgumentList @('wlan', 'show', 'interfaces')
    } catch {
        $fact.Detail = "Connected, but netsh could not be read: $($_.Exception.Message)"
        return $fact
    }

    if (-not $probe.Available -or $probe.ExitCode -ne 0) {
        $fact.Detail = "Connected, but netsh wlan returned exit $($probe.ExitCode), so no radio detail was read."
        return $fact
    }

    # Split on the FIRST colon only. A BSSID is six colon-separated octets, so splitting on
    # every colon would keep the first octet and discard the address.
    $values = @{}
    foreach ($line in @($probe.Lines)) {
        $text = [string]$line
        $index = $text.IndexOf(':')
        if ($index -lt 1) { continue }
        $key = $text.Substring(0, $index).Trim()
        if ($key) { $values[$key] = $text.Substring($index + 1).Trim() }
    }

    $read = {
        param([string[]] $Names)
        foreach ($name in $Names) {
            foreach ($key in $values.Keys) {
                if ([string]$key -eq $name) { return [string]$values[$key] }
            }
        }
        return ''
    }

    $ssid = & $read @('SSID')
    $bssid = & $read @('BSSID')
    if ($ssid) { $fact.Ssid = Protect-TlcIdentifier -Value $ssid }
    if ($bssid) { $fact.Bssid = Protect-TlcIdentifier -Value $bssid }

    $fact.RadioStatus = & $read @('Radio status')
    $fact.RadioType = & $read @('Radio type')
    $fact.Band = & $read @('Band')
    $fact.Channel = & $read @('Channel')

    $signal = & $read @('Signal')
    if ($signal -match '(\d+)') { $fact.SignalPercent = [int]$Matches[1] }

    $receive = & $read @('Receive rate (Mbps)')
    if ($receive -match '([\d\.]+)') { $fact.ReceiveMbps = [double]$Matches[1] }

    $transmit = & $read @('Transmit rate (Mbps)')
    if ($transmit -match '([\d\.]+)') { $fact.TransmitMbps = [double]$Matches[1] }

    # An associated adapter whose labels none of the above matched means netsh answered in a
    # language or a shape this does not read - which is a different thing from a weak signal,
    # and has to say so rather than report a blank as though it were measured.
    if ($null -eq $fact.SignalPercent -and -not $fact.RadioType -and -not $fact.Ssid) {
        $fact.Detail = 'Connected, but no radio detail could be parsed from netsh - it may be reporting in another language. The adapter state above is still reliable.'
    } else {
        $fact.Detail = 'Connected, with radio detail read from netsh.'
    }

    return $fact
}

function Get-TlcProxyConfiguration {
    <#
    .SYNOPSIS
        Captures both proxy stacks.
    .DESCRIPTION
        Windows has two independent proxy configurations and they disagree more
        often than people expect: WinINET is per-user and is what the Teams client
        follows, WinHTTP is machine-wide. Capturing only one produces a report that
        looks fine while traffic is taking the other path.
    #>
    [CmdletBinding()]
    param()

    $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $winhttp = 'unavailable'
    $netsh = Invoke-TlcNativeCommand -FilePath 'netsh.exe' -ArgumentList @('winhttp', 'show', 'proxy')
    if ($netsh.Available) { $winhttp = ($netsh.Lines -join [Environment]::NewLine).Trim() }
    else { Write-Verbose 'netsh winhttp unavailable.' }

    return [ordered]@{
        WinInet = [ordered]@{
            ProxyEnabled  = if ($inet -and $inet.PSObject.Properties.Name -contains 'ProxyEnable') { [bool]$inet.ProxyEnable } else { $false }
            ProxyServer   = if ($inet -and $inet.PSObject.Properties.Name -contains 'ProxyServer') { $inet.ProxyServer } else { '' }
            AutoConfigUrl = if ($inet -and $inet.PSObject.Properties.Name -contains 'AutoConfigURL') { $inet.AutoConfigURL } else { '' }
        }
        WinHttp = $winhttp
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-TlcStunReachability {
    <#
    .SYNOPSIS
        Sends a STUN binding request to a Teams transport relay.
    .DESCRIPTION
        Teams media runs over UDP 3478-3481 to Microsoft transport relays, and the
        guidance's own thresholds are all UDP measurements - but the published
        checklist has no way to answer "is UDP actually getting out of here". A STUN
        binding request is the real protocol those relays speak, so a valid binding
        response is direct proof the media path works from this machine.

        A missing response is reported as Inconclusive rather than Blocked. It could
        be a firewall, a proxy, or simply a relay declining to answer this probe, and
        asserting a customer network fault on that basis would be wrong.
    #>
    [CmdletBinding()]
    param(
        [string] $HostName = 'worldaz.tr.teams.microsoft.com',
        [int[]] $Ports = @(3478, 3479, 3480, 3481),
        [int] $TimeoutMs = 2000
    )

    # Explicit assignment rather than $x = try {...} catch {...}: the expression form
    # can leave the variable null, and under StrictMode the next property access
    # fails rather than falling through to the empty case.
    $addresses = @()
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($HostName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString })
    } catch {
        Write-Verbose "DNS resolution failed for ${HostName}: $($_.Exception.Message)"
    }

    if ($addresses.Count -eq 0) {
        # ReachableCount is part of the record's shape on every path. The caller reads it to
        # decide the MediaPath row, and under StrictMode a missing member throws - so a DNS
        # failure, the very case this lane exists to diagnose, crashed the whole network
        # collection instead of reporting. Measured on the lab endpoint with Teams names pointed at
        # 0.0.0.0 in the hosts file: "Run FAILED". Finding 305.
        return [ordered]@{
            HostName       = $HostName
            Resolved       = $false
            Results        = @()
            ReachableCount = 0
            Summary        = 'DNS resolution failed.'
        }
    }

    $target = $addresses[0]

    # All four probes are sent before any response is awaited, then a single timeout
    # window covers them together. Serially this cost four full timeouts whenever UDP
    # was blocked - which is precisely the case worth investigating, so the slowest
    # path was the one an engineer hit while waiting on a customer call. Sending
    # together is also closer to what a real client does.
    $probes = [System.Collections.Generic.List[object]]::new()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        foreach ($port in $Ports) {
            # 20-byte STUN Binding Request: type 0x0001, length 0, magic cookie, 12-byte
            # transaction id.
            $request = [byte[]]::new(20)
            $request[0] = 0x00; $request[1] = 0x01
            $request[2] = 0x00; $request[3] = 0x00
            $request[4] = 0x21; $request[5] = 0x12; $request[6] = 0xA4; $request[7] = 0x42
            $txn = [byte[]]::new(12)
            $rng.GetBytes($txn)
            [Array]::Copy($txn, 0, $request, 8, 12)

            $client = [System.Net.Sockets.UdpClient]::new()
            $sent = $false
            try {
                $null = $client.Send($request, $request.Length, $target, $port)
                $sent = $true
            } catch {
                Write-Verbose "Could not send to ${target}:${port}: $($_.Exception.Message)"
            }

            $probes.Add([pscustomobject]@{
                Port          = $port
                Client        = $client
                Transaction   = $txn
                SentAt        = (Get-Date)
                Sent          = $sent
                Status        = if ($sent) { 'Inconclusive' } else { 'SendFailed' }
                LatencyMs     = $null
                BytesReceived = 0
                Answered      = -not $sent
            })
        }
    } finally {
        $rng.Dispose()
    }

    try {
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline -and @($probes | Where-Object { -not $_.Answered }).Count -gt 0) {
            foreach ($probe in $probes) {
                if ($probe.Answered) { continue }

                # Sending to a port with nothing behind it draws an ICMP port-unreachable,
                # and Windows surfaces that as a socket reset on the next read rather than
                # as silence. It has to be caught: a relay or firewall that actively
                # rejects the probe is a normal outcome for this check, and letting it
                # escape would fail the whole network collection over an expected event.
                $response = $null
                try {
                    if ($probe.Client.Available -le 0) { continue }
                    $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                    $response = $probe.Client.Receive([ref]$remote)
                } catch {
                    Write-Verbose "Probe on port $($probe.Port) was reset: $($_.Exception.Message)"
                    $probe.Status = 'Inconclusive'
                    $probe.Answered = $true
                    continue
                }

                # The transaction id is generated per probe precisely so a reply can be
                # tied to its request. Not checking it meant any stray datagram that
                # happened to arrive on the socket could be read as proof the media path
                # works - a false "confirmed" is the one answer this check must not give.
                $matched = $response.Length -ge 20
                if ($matched) {
                    for ($i = 0; $i -lt 12; $i++) {
                        if ($response[8 + $i] -ne $probe.Transaction[$i]) { $matched = $false; break }
                    }
                }

                $isBindingResponse = ($response.Length -ge 20 -and $response[0] -eq 0x01 -and $response[1] -eq 0x01 -and $matched)

                $probe.LatencyMs = [math]::Round(((Get-Date) - $probe.SentAt).TotalMilliseconds, 0)
                $probe.BytesReceived = $response.Length
                $probe.Status = if ($isBindingResponse) { 'Reachable' } else { 'UnexpectedResponse' }
                $probe.Answered = $true
            }
            Start-Sleep -Milliseconds 25
        }
    } finally {
        foreach ($probe in $probes) { $probe.Client.Dispose() }
    }

    $results = @($probes | ForEach-Object {
        [ordered]@{
            Port          = $_.Port
            Status        = $_.Status
            LatencyMs     = $_.LatencyMs
            BytesReceived = $_.BytesReceived
        }
    })
    $reachable = @($results | Where-Object { $_.Status -eq 'Reachable' })

    # In practice only 3478 answers a bare binding request; the others are allocated
    # during a real call. Inconclusive on 3479-3481 is normal and is not evidence of
    # filtering, so the summary is written from whether ANY port answered.
    $summary = if ($reachable.Count -gt 0) {
        "UDP media path confirmed: STUN binding response on port(s) $(($reachable | ForEach-Object { $_.Port }) -join ', ')."
    } else {
        'No STUN binding response on any media port. Inconclusive: could be UDP filtering, a proxy, or relays declining this probe. Confirm with the Network Assessment Tool.'
    }

    return [ordered]@{
        HostName    = $HostName
        Resolved    = $true
        TargetIp    = $target
        Results     = $results
        ReachableCount = $reachable.Count
        Summary     = $summary
    }
}

function Measure-TlcMediaPathQuality {
    <#
    .SYNOPSIS
        Round-trip time, jitter and loss over the real Teams media path.
    .DESCRIPTION
        Test-TlcStunReachability answers whether the media path works. It does not answer
        how well, and every threshold the guidance sets is a quality number: the Microsoft
        365 connectivity test calls UDP loss under 1%, latency under 100 ms and jitter
        under 30 ms healthy, and CQD marks an audio stream poor above 500 ms round trip,
        0.1% loss or 30 ms jitter.

        A burst of STUN binding requests to the one port that answers a bare request gives
        all three from the transport Teams actually uses. Jitter is the mean absolute
        difference between consecutive round trips - RFC 3550's interarrival jitter is
        defined over a stream with timestamps, which a binding exchange does not have, so
        this is the closest honest equivalent and is named for what it measures.

        Do NOT substitute ICMP. Measured on the development machine, ping to the media
        edge returns DestinationHostUnreachable, because a SASE client resolves it to a
        synthetic address with no host behind it - and Azure deprioritises ICMP in any
        case. The measurement has to run over the same UDP path as the media.

        Every probe carries its own transaction id and a reply is only counted when the id
        matches, for the same reason the reachability check does it: a stray datagram must
        not be able to manufacture a good result.
    #>
    [CmdletBinding()]
    param(
        [string] $HostName = 'worldaz.tr.teams.microsoft.com',
        [int] $Port = 3478,
        [int] $Count = 10,
        [int] $TimeoutMs = 1000,
        [int] $IntervalMs = 50
    )

    $addresses = @()
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($HostName) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.IPAddressToString })
    } catch {
        Write-Verbose "Could not resolve ${HostName}: $($_.Exception.Message)"
    }
    if ($addresses.Count -eq 0) {
        return [ordered]@{
            HostName = $HostName; Port = $Port; Resolved = $false; Measured = $false
            Summary = 'DNS resolution failed, so the media path could not be measured.'
        }
    }

    $target = $addresses[0]
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $latencies = [System.Collections.Generic.List[double]]::new()
    $sent = 0

    try {
        for ($i = 0; $i -lt $Count; $i++) {
            $request = [byte[]]::new(20)
            $request[0] = 0x00; $request[1] = 0x01
            $request[2] = 0x00; $request[3] = 0x00
            $request[4] = 0x21; $request[5] = 0x12; $request[6] = 0xA4; $request[7] = 0x42
            $txn = [byte[]]::new(12)
            $rng.GetBytes($txn)
            [Array]::Copy($txn, 0, $request, 8, 12)

            $client = [System.Net.Sockets.UdpClient]::new()
            try {
                $client.Client.ReceiveTimeout = $TimeoutMs
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $null = $client.Send($request, $request.Length, $target, $Port)
                $sent++

                $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $response = $client.Receive([ref]$remote)
                $watch.Stop()

                $matched = $true
                if ($response.Length -ge 20) {
                    for ($b = 0; $b -lt 12; $b++) {
                        if ($response[8 + $b] -ne $txn[$b]) { $matched = $false; break }
                    }
                } else { $matched = $false }

                if ($matched -and $response[0] -eq 0x01 -and $response[1] -eq 0x01) {
                    $latencies.Add($watch.Elapsed.TotalMilliseconds)
                }
            } catch {
                # A timeout is a lost probe, which is the measurement, not an error.
                Write-Verbose "Probe $i had no reply: $($_.Exception.Message)"
            } finally {
                $client.Dispose()
            }

            if ($IntervalMs -gt 0) { Start-Sleep -Milliseconds $IntervalMs }
        }
    } finally {
        $rng.Dispose()
    }

    $received = $latencies.Count
    if ($received -eq 0) {
        return [ordered]@{
            HostName = $HostName; Port = $Port; Resolved = $true; TargetIp = $target
            Measured = $false; Sent = $sent; Received = 0
            Summary = "No reply to any of $sent probes. Inconclusive rather than a fault: relays decline bare binding requests under some configurations. Confirm with the Network Assessment Tool."
        }
    }

    $ordered = @($latencies | Sort-Object)
    $jitterSamples = for ($i = 1; $i -lt $latencies.Count; $i++) {
        [math]::Abs($latencies[$i] - $latencies[$i - 1])
    }
    $jitter = if (@($jitterSamples).Count -gt 0) {
        [math]::Round((@($jitterSamples) | Measure-Object -Average).Average, 1)
    } else { 0 }

    $lossPercent = [math]::Round((($sent - $received) / [double]$sent) * 100, 1)
    $average = [math]::Round(($latencies | Measure-Object -Average).Average, 1)

    # Thresholds from the guidance's own table, so the wording matches what an engineer
    # will be asked about. Reported as observations, not verdicts - a handful of probes
    # is not a network assessment, and it says so.
    $breaches = @()
    if ($average -gt 100) { $breaches += "latency $average ms exceeds 100 ms" }
    if ($jitter -gt 30) { $breaches += "jitter $jitter ms exceeds 30 ms" }
    if ($lossPercent -gt 1) { $breaches += "loss $lossPercent% exceeds 1%" }

    $summary = if ($breaches.Count -gt 0) {
        "Media path measured: $($breaches -join ', '). Indicative only - $sent probes, not a network assessment."
    } else {
        "Media path healthy against the published thresholds: latency $average ms, jitter $jitter ms, loss $lossPercent% over $sent probes."
    }

    return [ordered]@{
        HostName    = $HostName
        Port        = $Port
        Resolved    = $true
        TargetIp    = $target
        Measured    = $true
        Sent        = $sent
        Received    = $received
        LossPercent = $lossPercent
        LatencyMinMs = [math]::Round($ordered[0], 1)
        LatencyAvgMs = $average
        LatencyMaxMs = [math]::Round($ordered[-1], 1)
        JitterMs    = $jitter
        Breaches    = $breaches
        Summary     = $summary
    }
}

function Test-TlcTeamsEndpoint {
    <#
    .SYNOPSIS
        TCP reachability for the Teams signalling and sign-in endpoints.
    #>
    [CmdletBinding()]
    param(
        [string[]] $HostNames = @('teams.microsoft.com', 'config.teams.microsoft.com', 'login.microsoftonline.com'),
        [int] $Port = 443,
        [int] $TimeoutMs = 3000
    )

    foreach ($name in $HostNames) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $started = Get-Date
            $async = $client.BeginConnect($name, $Port, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected
            [ordered]@{
                HostName  = $name
                Port      = $Port
                Connected = $ok
                LatencyMs = if ($ok) { [math]::Round(((Get-Date) - $started).TotalMilliseconds, 0) } else { $null }
            }
        } catch {
            [ordered]@{ HostName = $name; Port = $Port; Connected = $false; LatencyMs = $null }
        } finally {
            $client.Dispose()
        }
    }
}

function Get-TlcTenantCloudFact {
    <#
    .SYNOPSIS
        Which Microsoft cloud this device actually authenticates against.
    .DESCRIPTION
        The cloud was a configuration value the operator had to know and set. Almost nobody
        sets it, so every collection tested the worldwide endpoints - including the government
        tenants where that answer is wrong.

        The signal is the authority host in dsregcmd's output: the URL the device genuinely
        gets its tokens from. Only the HOST is taken. The same lines carry the tenant GUID,
        which is customer identity and has no place in a bundle - the toolbox already excludes
        identifiers from dsregcmd for exactly that reason, and a cloud name is a category, not
        an identity.

        The Teams client logs were measured as a candidate signal and rejected. On this
        commercial machine they contained teams.microsoft.com 113 times, teams.microsoft.us
        five times and teams.microsoftonline.cn once: the client ships a static table of every
        cloud's hosts, so matching log text would have reported a government cloud on a
        commercial tenant. A signal that is wrong in the direction of "this is a special
        tenant" is worse than no signal.

        GCC High and DoD share login.microsoftonline.us, so a .us authority cannot tell them
        apart. That is reported as ambiguous rather than guessed, and the ambiguity is not
        closeable from local state: Microsoft explicitly groups the two clouds for sign-in AND
        for device registration (both use the same enterpriseregistration host), so neither
        discriminates. Two further candidates were measured and rejected - the DNS resolver
        cache was empty on a machine actively running Teams, and the client's own log text
        names every cloud's hosts regardless of tenant.

        What Microsoft does publish disjointly is the Teams namespace itself:
        gov.teams.microsoft.us for GCC High against dod.teams.microsoft.us for DoD, on separate
        per-cloud endpoint pages. That is the discriminator, and it is one an engineer can
        apply from the case; it is not readable from this machine. So the message names it.

        -ClientCloud carries the client's OWN statement of its cloud, read from
        ecs_request_param.json and already collected as TacCorrelation.Cloud. It is reported
        verbatim and never mapped: this machine says "prod", and the possible values are not
        documented by Microsoft anywhere - roughly 2 GB of public documentation source was
        scanned for the schema and it does not appear. Inventing a mapping is how the event-id
        table came to ship four wrong entries. Surfaced beside the ambiguity so an engineer
        holding a real government bundle can read the two together and settle it by hand.
    #>
    [CmdletBinding()]
    param(
        [string[]] $DsregOutput,
        [string] $ClientCloud
    )

    $result = [ordered]@{
        Detected    = $false
        Instance    = ''
        Ambiguous   = $false
        Candidates  = @()
        Authority   = ''
        ClientCloud = [string]$ClientCloud
        Detail      = ''
    }

    # Filtered, not just wrapped. An unsupplied [string[]] parameter is $null, and @($null)
    # is an array of ONE element rather than an empty one - so a bare Count check never
    # fires and the function parses a list containing a single null. That is exactly how
    # this reported "no authority found" on a machine whose dsregcmd output plainly had one.
    $lines = @($DsregOutput | Where-Object { $null -ne $_ })
    if ($lines.Count -eq 0) {
        try {
            # No 2>$null. Redirecting a native command's stderr in Windows PowerShell 5.1
            # wraps its lines in ErrorRecords and can leave the success stream empty.
            $lines = @(dsregcmd /status)
        } catch {
            $result.Detail = "The device join state could not be read, so the cloud was not detected: $($_.Exception.Message)"
            return (New-Object psobject -Property $result)
        }
    }

    # Host only. The capture deliberately stops at the first slash, so the tenant GUID that
    # follows it never enters the result, the bundle or the log.
    $authorityHost = ''
    foreach ($line in $lines) {
        if ($line -notmatch '(?i)(AzureAdPrtAuthority|AccessTokenUrl|AuthCodeUrl|OnPremTgt|KerbUrl)') { continue }
        $match = [regex]::Match([string]$line, '(?i)https://([A-Za-z0-9.-]+)/')
        if ($match.Success) { $authorityHost = $match.Groups[1].Value.ToLowerInvariant(); break }
    }

    if (-not $authorityHost) {
        $result.Detail = 'No authority URL was found in the device join state, so the cloud could not be detected and worldwide endpoints are assumed.'
        return (New-Object psobject -Property $result)
    }

    $result.Authority = $authorityHost

    switch -Regex ($authorityHost) {
        'login\.partner\.microsoftonline\.cn$' {
            $result.Detected = $true
            $result.Instance = 'China'
            $result.Candidates = @('China')
            $result.Detail = "Authority $authorityHost indicates the China cloud."
        }
        'login\.microsoftonline\.us$|login\.microsoftonline\.microsoft\.scloud$|login\.microsoftonline\.eaglex\.ic\.gov$' {
            $result.Detected = $true
            # Not guessed. GCC High and DoD share this host, and picking one would be a
            # confident wrong answer in the lane most likely to be read as decisive.
            $result.Instance = 'USGovGCCHigh'
            $result.Ambiguous = $true
            $result.Candidates = @('USGovGCCHigh', 'USGovDoD')
            $result.Detail = "Authority $authorityHost is a US government cloud. GCC High and DoD share this sign-in host and the same device registration host, so neither tells them apart - GCC High endpoints were used. The two differ in their Teams namespace: gov.teams.microsoft.us for GCC High, dod.teams.microsoft.us for DoD. Pass -CloudInstance USGovDoD if this is a DoD tenant."
            # Reported, never mapped. The client's own word for its cloud is the most likely
            # thing to separate the two by hand, and it costs nothing to put it in front of
            # whoever has to decide.
            if ($result.ClientCloud) {
                $result.Detail += " The Teams client reports its cloud as '$($result.ClientCloud)'."
            }
        }
        'login\.microsoftonline\.com$|login\.microsoft\.com$|login\.windows\.net$' {
            $result.Detected = $true
            $result.Instance = 'Worldwide'
            $result.Candidates = @('Worldwide')
            # GCC is commercial: it signs in here and uses commercial endpoints, and calling
            # it "government" because of the contract is the easiest mistake to make.
            $result.Detail = "Authority $authorityHost indicates the worldwide cloud, which also covers GCC."
        }
        default {
            $result.Detail = "Authority $authorityHost is not a known cloud sign-in host, so worldwide endpoints are assumed."
        }
    }

    return (New-Object psobject -Property $result)
}

function Get-TlcCloudEndpoint {
    <#
    .SYNOPSIS
        The Teams host names for a given cloud instance.
    .DESCRIPTION
        The toolbox tested the worldwide names on every machine. That is right for almost every
        customer and wrong for the ones who most need a correct answer: on a GCC High or DoD
        tenant those hosts are not the ones the client uses, so a reachability check against
        them reports a problem that is not there, or health that is not real. Either way the
        bundle is confidently wrong about the network, which is the lane most likely to be read
        as decisive.

        Host names only. Microsoft publishes IP ranges through endpoints.office.com and they
        change; addresses baked into a tool go stale silently and are then worse than no list.
        Names are stable, and resolving them is what the checks do anyway.

        An unrecognised instance returns the worldwide set and reports that through Matched,
        rather than returning nothing: a network lane that collects nothing because a cloud
        name was misspelt is a worse outcome than one that tests the common endpoints.
    #>
    [CmdletBinding()]
    param(
        [string] $Instance,
        [string] $DataPath
    )

    if (-not $DataPath) {
        $DataPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'CloudEndpoints.psd1'
    }
    if (-not (Test-Path -LiteralPath $DataPath)) { return $null }

    try {
        $table = Import-TlcCollectorData -Path $DataPath
    } catch {
        Write-Verbose "Cloud endpoint list could not be read: $($_.Exception.Message)"
        return $null
    }

    $clouds = @($table.Clouds)
    if ($clouds.Count -eq 0) { return $null }

    $wanted = if ($Instance) { $Instance.Trim() } else { [string]$table.Default }
    $match = $null
    foreach ($cloud in $clouds) {
        $names = @([string]$cloud.Instance) + @($cloud.Aliases)
        foreach ($name in $names) {
            if ($name -and $name.Equals($wanted, [System.StringComparison]::OrdinalIgnoreCase)) { $match = $cloud; break }
        }
        if ($match) { break }
    }

    $matched = $null -ne $match
    if (-not $match) {
        $match = @($clouds | Where-Object { [string]$_.Instance -eq [string]$table.Default })[0]
        if (-not $match) { $match = $clouds[0] }
    }

    # RelayPorts is returned because the relay-skip row names them. It was carried in the data
    # file and never returned, so on every cloud without a relay name the skip branch threw
    # under StrictMode and ended the network lane (review 2026-09-30, finding 331).
    $relayPorts = @()
    if ($match -is [System.Collections.IDictionary] -and $match.Contains('RelayPorts')) {
        $relayPorts = @($match['RelayPorts'] | ForEach-Object { [int]$_ })
    }

    return [pscustomobject]@{
        Instance   = [string]$match.Instance
        Requested  = $wanted
        Matched    = $matched
        Teams      = [string]$match.Teams
        Config     = [string]$match.Config
        Login      = [string]$match.Login
        MediaRelay = [string]$match.MediaRelay
        RelayPorts = $relayPorts
    }
}

function Get-TlcQosPolicyFact {
    <#
    .SYNOPSIS
        Whether this machine marks Teams media with DSCP, and whether the marking matches what
        Microsoft documents.
    .DESCRIPTION
        The network lane measures the media PATH - STUN reachability, latency, loss. It never
        asked whether the endpoint marks its media at all, and unmarked media is a documented
        cause of exactly the symptom the CallQuality scenario exists for: routers cannot
        prioritise what is not marked, so audio arrives late, jittery or "robotic".

        Microsoft publishes the expected values, and they are not negotiable - "DSCP markings
        can't be changed", only the port ranges can be adjusted:

            audio      50000-50019   DSCP 46   EF
            video      50020-50039   DSCP 34   AF41
            sharing    50040-50059   DSCP 18   AF21
            signaling  50070-50089   DSCP 40   CS5

        Policies reach a machine three ways - New-NetQosPolicy locally, Group Policy
        "Policy-based QoS", or the Intune NetworkQoSPolicy CSP - and all three land in the same
        place, so reading the effective policy covers all three without caring which was used.

        ABSENT IS THE NORMAL ANSWER and is reported as a fact rather than a fault. Most machines
        have no QoS policy; that only matters when call quality is the complaint, which is why
        this is a fact in the bundle and not a blocker. Reporting it as a problem on every
        healthy desktop would train people to ignore it.

        The cmdlet is checked for rather than assumed: NetQos ships with Windows but is absent
        from some Server Core and container images, and a missing cmdlet is a different fact
        from a missing policy.

        Source: learn.microsoft.com/en-us/microsoftteams/qos-in-teams and qos-in-teams-clients
    #>
    [CmdletBinding()]
    param()

    # The documented expectation, kept next to the check so the two cannot drift apart.
    $expected = @(
        [ordered]@{ Media = 'Audio';     StartPort = 50000; EndPort = 50019; Dscp = 46 }
        [ordered]@{ Media = 'Video';     StartPort = 50020; EndPort = 50039; Dscp = 34 }
        [ordered]@{ Media = 'Sharing';   StartPort = 50040; EndPort = 50059; Dscp = 18 }
        [ordered]@{ Media = 'Signaling'; StartPort = 50070; EndPort = 50089; Dscp = 40 }
    )

    $result = [ordered]@{
        CmdletAvailable = $false
        PolicyCount     = 0
        TeamsPolicies   = @()
        Expected        = $expected
        Matched         = @()
        Missing         = @()
        Mismatched      = @()
        Detail          = ''
    }

    if (-not (Get-Command -Name 'Get-NetQosPolicy' -ErrorAction SilentlyContinue)) {
        $result.Detail = 'The NetQos module is not present, so QoS policy could not be read. This is not the same as having no policy.'
        return (New-Object psobject -Property $result)
    }
    $result.CmdletAvailable = $true

    $policies = @()
    try {
        $policies = @(Get-NetQosPolicy -ErrorAction Stop)
    } catch {
        $result.Detail = "QoS policy could not be read: $($_.Exception.Message)"
        return (New-Object psobject -Property $result)
    }
    $result.PolicyCount = $policies.Count

    # Matched on the executable rather than the policy name. Names are free text and an
    # administrator may call the audio policy anything at all; AppPathNameMatchCondition is
    # what actually decides whether Teams traffic gets marked.
    $teams = @($policies | Where-Object {
        "$($_.AppPathNameMatchCondition)" -match '^(ms-teams|Teams)\.exe$'
    })
    $result.TeamsPolicies = @($teams | ForEach-Object {
        [ordered]@{
            Name      = [string]$_.Name
            App       = [string]$_.AppPathNameMatchCondition
            Dscp      = $_.DSCPAction
            StartPort = $_.IPSrcPortStartMatchCondition
            EndPort   = $_.IPSrcPortEndMatchCondition
            Protocol  = [string]$_.IPProtocolMatchCondition
        }
    })

    # Start port, end port and protocol all decide what gets marked. Matching on the start port
    # alone called an audio policy covering only port 50000, or one scoped to TCP while Teams
    # media runs over UDP, "correctly marked" (review 2026-09-30, finding 331). A policy with
    # no protocol condition, UDP, or both covers the media.
    foreach ($want in $expected) {
        $hit = @($teams | Where-Object { $_.IPSrcPortStartMatchCondition -eq $want.StartPort })
        if ($hit.Count -eq 0) {
            $result.Missing = @($result.Missing) + @($want.Media)
            continue
        }
        $policy = $hit[0]
        $problems = @()
        if ($policy.DSCPAction -ne $want.Dscp) {
            $problems += "marked $($policy.DSCPAction), documented $($want.Dscp)"
        }
        if ($policy.IPSrcPortEndMatchCondition -ne $want.EndPort) {
            $problems += "ports $($policy.IPSrcPortStartMatchCondition)-$($policy.IPSrcPortEndMatchCondition), documented $($want.StartPort)-$($want.EndPort)"
        }
        if ("$($policy.IPProtocolMatchCondition)" -eq 'TCP') {
            $problems += 'TCP only, so UDP media is not marked'
        }
        if ($problems.Count -gt 0) {
            $result.Mismatched = @($result.Mismatched) + @("$($want.Media): $($problems -join '; ')")
        } else {
            $result.Matched = @($result.Matched) + @($want.Media)
        }
    }

    $result.Detail = if ($teams.Count -eq 0) {
        'No QoS policy marks Teams media on this machine. Media is sent unmarked, so network equipment cannot prioritise it - a documented cause of jitter and choppy audio. Normal on an unmanaged endpoint; significant when the complaint is call quality.'
    } elseif (@($result.Missing).Count -eq 0 -and @($result.Mismatched).Count -eq 0) {
        "All four documented Teams QoS policies are present and correctly marked."
    } else {
        $parts = @()
        if (@($result.Missing).Count -gt 0) { $parts += "Missing: $(@($result.Missing) -join ', ')." }
        if (@($result.Mismatched).Count -gt 0) { $parts += "Mismatched: $(@($result.Mismatched) -join '; ')." }
        "Teams QoS is partially configured. $($parts -join ' ')"
    }

    return (New-Object psobject -Property $result)
}

function Get-TlcTlsCertificateFact {
    <#
    .SYNOPSIS
        Who issued the certificate an endpoint actually presents.
    .DESCRIPTION
        The strongest available local signal for TLS break-and-inspect, and one the proxy
        settings the toolbox already collects cannot give: a proxy can be configured and
        not inspecting, or inspecting with nothing in the proxy settings to show for it.
        The certificate is what the machine was actually handed.

        A Microsoft issuer means the session reached Microsoft intact. An issuer naming a
        proxy vendor - or the customer's own CA - means something terminated the session
        in the middle and re-signed it, which Microsoft documents as a cause of Teams
        update and media failures on the Optimize-category endpoints.

        The callback deliberately accepts every chain. This is measuring what was
        presented, not deciding whether to trust it, and refusing an intercepted
        certificate would throw away the one observation worth making. Nothing is sent
        over the connection beyond the handshake.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostName,
        [int] $Port = 443,
        [int] $TimeoutMs = 5000
    )

    $client = $null
    $stream = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected)) {
            return [ordered]@{ HostName = $HostName; Port = $Port; Handshake = $false; Detail = 'Could not connect.' }
        }
        $client.EndConnect($async)

        # The connect above had a timeout and the handshake did not, so a middlebox that
        # accepts TCP and then says nothing held the network lane, and the dashboard gather,
        # indefinitely (review 2026-09-30, finding 331). The synchronous handshake reads
        # through the socket, so the socket's own timeouts bound it on both editions.
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs

        $accept = [System.Net.Security.RemoteCertificateValidationCallback] { param($a, $b, $c, $d) $true }
        $stream = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $accept)
        $stream.AuthenticateAsClient($HostName)

        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($stream.RemoteCertificate)

        # The leaf issuer is the wrong thing to judge on, and judging on it was the first
        # attempt: teams.microsoft.com is issued by "O=Microsoft Corporation" but
        # login.microsoftonline.com is issued by DigiCert, so "is it Microsoft-issued"
        # reported inspection on a perfectly healthy endpoint.
        #
        # The chain ROOT is the signal. Every Teams endpoint measured chains to DigiCert
        # Global Root G2, a public root. An inspecting proxy has to substitute its own
        # root - that is the whole mechanism - so a root outside the public set is the
        # observation worth making.
        $rootSubject = $null
        $rootThumbprint = $null
        $chain = $null
        try {
            $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
            # Only the root's name is wanted, not a trust decision, so revocation is not
            # checked: an online CRL or OCSP fetch on a network that blackholes it can take
            # longer than the whole probe. Anything still fetched is bounded by the timeout.
            $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chain.ChainPolicy.UrlRetrievalTimeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
            $null = $chain.Build($certificate)
            if ($chain.ChainElements.Count -gt 0) {
                $root = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
                $rootSubject = $root.Subject
                $rootThumbprint = $root.Thumbprint
            }
        } catch {
            Write-Verbose "Could not build the chain for $HostName : $($_.Exception.Message)"
        } finally {
            if ($chain) { $chain.Dispose() }
        }

        # Organisations, not full subjects: root CAs are renamed and re-issued far less
        # often than the intermediates beneath them, so this ages slowly. It is still a
        # heuristic, which is why the root is recorded either way - a reader can judge a
        # name this list has never heard of.
        $publicRoots = @(
            'DigiCert', 'Baltimore', 'Microsoft', 'Entrust', 'GlobalSign',
            'Sectigo', 'COMODO', 'USERTrust', 'Internet Security Research Group',
            'Amazon', 'Google Trust Services', 'VeriSign', 'thawte', 'GeoTrust'
        )
        $publiclyRooted = $false
        if ($rootSubject) {
            foreach ($known in $publicRoots) {
                if ($rootSubject -like "*$known*") { $publiclyRooted = $true; break }
            }
        }

        return [ordered]@{
            HostName        = $HostName
            Port            = $Port
            Handshake       = $true
            Issuer          = $certificate.Issuer
            Subject         = $certificate.Subject
            Thumbprint      = $certificate.Thumbprint
            NotAfterUtc     = $certificate.NotAfter.ToUniversalTime().ToString('o')
            ChainRoot       = $rootSubject
            ChainRootThumbprint = $rootThumbprint
            PubliclyRooted  = $publiclyRooted
            TlsProtocol     = "$($stream.SslProtocol)"
        }
    } catch {
        return [ordered]@{
            HostName = $HostName; Port = $Port; Handshake = $false
            Detail = $_.Exception.Message
        }
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Get-TlcLocalBlockFact {
    <#
    .SYNOPSIS
        The causes of a Teams network failure that live on this machine and can be named.
    .DESCRIPTION
        Found by simulating the faults, finding 305. With outbound UDP 3478-3481 blocked by a
        local firewall rule the media row said "could be UDP filtering, a proxy, or relays
        declining this probe" - accurate, and useless, because the cause was a rule on this
        machine that the toolbox could simply read. The same for a hosts-file entry pointing
        Teams at 0.0.0.0. Remote causes stay inconclusive; local ones are named.

        Read-only. Firewall rules come from the ACTIVE store, so Group Policy and MDM rules are
        included - those are the ones nobody on the machine remembers adding.
    #>
    [CmdletBinding()]
    param(
        [string] $HostsPath = (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'),
        [switch] $SkipFirewall
    )

    # Names Teams depends on. Suffix match, so a single entry for any subdomain is caught.
    # windows.net only by exact name: the whole suffix covers Azure storage, whose hosts-file
    # entries for private endpoints are ordinary and correct. The two sign-in names were
    # missed until a simulated sign-in block overrode five names and the row named three.
    $suffixes = @('microsoft.com', 'microsoftonline.com', 'teams.cloud.microsoft', 'cloud.microsoft', 'office.com',
                  'office.net', 'office365.com', 'skype.com', 'lync.com', 'live.com', 'msftauth.net', 'msauth.net', 'azureedge.net',
                  'login.windows.net', 'enterpriseregistration.windows.net')
    $hostsEntries = @()
    if (Test-Path -LiteralPath $HostsPath) {
        $hostsEntries = @(foreach ($line in Get-Content -LiteralPath $HostsPath -ErrorAction SilentlyContinue) {
            $text = ($line -replace '#.*$', '').Trim()
            if (-not $text) { continue }
            $parts = @($text -split '\s+')
            if ($parts.Count -lt 2) { continue }
            foreach ($name in $parts[1..($parts.Count - 1)]) {
                $lower = $name.ToLowerInvariant()
                if (@($suffixes | Where-Object { $lower -eq $_ -or $lower.EndsWith(".$_") }).Count -gt 0) {
                    [ordered]@{ Name = $lower; Address = $parts[0] }
                }
            }
        })
    }

    $firewall = @()
    $firewallRead = $false
    if (-not $SkipFirewall -and (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
        try {
            $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Outbound -Action Block -Enabled True -ErrorAction Stop)
            $firewallRead = $true
            $firewall = @(foreach ($rule in $rules) {
                # A rule scoped to named remote addresses blocks those addresses, not Teams.
                # Measured on a managed machine: "Malicious IP Block" covers every port and
                # protocol but only twelve threat-intelligence addresses, and the first version
                # of this reported it as blocking Teams media and TCP 443.
                $addresses = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
                $remoteAddress = @($addresses.RemoteAddress | ForEach-Object { [string]$_ })
                if ($remoteAddress.Count -gt 0 -and @($remoteAddress | Where-Object { $_ -ne 'Any' }).Count -gt 0) { continue }

                $ports = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                $app = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                $protocol = [string]$ports.Protocol
                $remote = @($ports.RemotePort | ForEach-Object { [string]$_ })
                $program = [string]$app.Program

                $coversPort = {
                    param([int] $Port)
                    foreach ($spec in $remote) {
                        if ($spec -eq 'Any') { return $true }
                        if ($spec -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $true }
                        if ($spec -match '^\d+$' -and [int]$spec -eq $Port) { return $true }
                    }
                    return $false
                }
                $allPrograms = (-not $program) -or $program -eq 'Any'
                $teamsProgram = $program -match '(?i)ms-teams\.exe|msedgewebview2\.exe|\\MSTeams_'

                $affects = @(
                    if ($allPrograms -and $protocol -in 'UDP', 'Any' -and (& $coversPort 3478)) { 'media UDP 3478-3481' }
                    if ($allPrograms -and $protocol -in 'TCP', 'Any' -and (& $coversPort 443)) { 'TCP 443' }
                    if ($teamsProgram) { "the Teams program ($program)" }
                )
                if ($affects.Count -gt 0) {
                    [ordered]@{
                        DisplayName = [string]$rule.DisplayName
                        Source      = [string]$rule.PolicyStoreSourceType
                        Protocol    = $protocol
                        RemotePort  = ($remote -join ',')
                        Program     = $program
                        Affects     = @($affects)
                    }
                }
            })
        } catch {
            Write-Verbose "Firewall rules could not be read: $($_.Exception.Message)"
        }
    }

    return [ordered]@{
        HostsOverrides = @($hostsEntries)
        FirewallRead   = $firewallRead
        FirewallBlocks = @($firewall)
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Test-TlcProxyReachability {
    <#
    .SYNOPSIS
        Whether the WinINET proxy Teams follows is accepting connections.
    .DESCRIPTION
        The toolbox's own probes connect directly, so with a dead proxy configured every one of
        them passed while Teams - which follows WinINET - could reach nothing. Measured on
        the lab endpoint with the proxy set to 127.0.0.1:9: every network row read Success. Finding 305.

        Only a static proxy is tested. A PAC file decides per URL and cannot be evaluated
        honestly from here, so it is recorded and left to the engineer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Proxy,
        [int] $TimeoutMs = 3000
    )

    $inet = $Proxy.WinInet
    if (-not $inet -or -not $inet.ProxyEnabled -or -not $inet.ProxyServer) {
        return [ordered]@{ Tested = $false; Reason = 'No static WinINET proxy is enabled.'; Servers = @() }
    }

    # "host:port", or per-scheme "http=host:port;https=host:port". https is what Teams uses.
    $entries = @(([string]$inet.ProxyServer) -split ';' | Where-Object { $_.Trim() })
    $preferred = @($entries | Where-Object { $_ -match '^\s*https=' })
    if ($preferred.Count -eq 0) { $preferred = @($entries | Where-Object { $_ -notmatch '=' }) }
    if ($preferred.Count -eq 0) { $preferred = $entries }

    $servers = @(foreach ($entry in ($preferred | Select-Object -Unique)) {
        $value = ($entry -replace '^\s*\w+=', '').Trim() -replace '^\w+://', ''
        $proxyHost = $value; $port = 80
        if ($value -match '^(.+):(\d+)$') { $proxyHost = $Matches[1]; $port = [int]$Matches[2] }
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $async = $client.BeginConnect($proxyHost, $port, $null, $null)
            $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected
        } catch { $ok = $false } finally { $client.Dispose() }
        [ordered]@{ Host = $proxyHost; Port = $port; Accepting = [bool]$ok }
    })

    return [ordered]@{ Tested = $true; Reason = ''; Servers = @($servers) }
}

function Write-TlcNetworkCauseRow {
    <#
    .SYNOPSIS
        Names the causes of a Teams network failure that live on this machine.
    .DESCRIPTION
        Found by simulating the faults on a real machine, finding 305. A hosts-file override, a
        local firewall block and a dead WinINET proxy each left every existing network row
        reading as it did on a healthy machine, or as "inconclusive". The facts come from
        Get-TlcLocalBlockFact and Test-TlcProxyReachability; this decides what to say.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $LocalBlocks,
        [System.Collections.IDictionary] $ProxyReach,
        [System.Collections.IDictionary] $Proxy,
        # The hosts-file row alone, for the scenarios that run no network lane. Firewall and
        # proxy rows need facts those scenarios do not gather. Finding 307.
        [switch] $HostsOnly,
        [string] $Endpoint = $env:COMPUTERNAME
    )
    $localBlocks = $LocalBlocks; $proxyReach = $ProxyReach; $proxy = $Proxy
    $overrides = @($localBlocks.HostsOverrides)
    if ($overrides.Count -gt 0) {
        Write-TlcBlocker -Check 'Network.HostsFile' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail ("The hosts file overrides $($overrides.Count) Microsoft name(s): " + (($overrides | ForEach-Object { "$($_.Name) -> $($_.Address)" }) -join '; ') + '. These bypass DNS entirely.') `
            -Remediation "Remove the entries from $env:SystemRoot\System32\drivers\etc\hosts unless they were put there deliberately, then run ipconfig /flushdns." | Out-Null
    }
    if ($HostsOnly) { return }

    $blocks = @($localBlocks.FirewallBlocks)
    if ($blocks.Count -gt 0) {
        Write-TlcBlocker -Check 'Network.LocalFirewall' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail ("$($blocks.Count) enabled outbound firewall rule(s) on this machine block Teams traffic: " +
                     (($blocks | ForEach-Object { "'$($_.DisplayName)' ($($_.Source)) blocks $(@($_.Affects) -join ', ')" }) -join '; ') + '.') `
            -Remediation 'A GroupPolicy or MDM source means the rule is managed centrally; raise it with whoever owns that policy. A Local source can be removed here.' | Out-Null
    } elseif (-not $localBlocks.FirewallRead) {
        Write-TlcBlocker -Check 'Network.LocalFirewall' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail 'The local firewall rules could not be read, so a block on this machine cannot be ruled out.' | Out-Null
    }

    if ($proxyReach.Tested) {
        $dead = @($proxyReach.Servers | Where-Object { -not $_.Accepting })
        $named = ($proxyReach.Servers | ForEach-Object { "$($_.Host):$($_.Port)" }) -join ', '
        if ($dead.Count -gt 0) {
            Write-TlcBlocker -Check 'Network.Proxy' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                -Detail "Teams follows the WinINET proxy $named, and it is not accepting connections. The reachability checks above connect directly, so they can pass while Teams reaches nothing." `
                -Remediation 'Correct or remove the proxy in Settings > Network & internet > Proxy, or in the policy that sets it.' | Out-Null
        } else {
            Write-TlcBlocker -Check 'Network.Proxy' -Status 'Success' -Endpoint $Endpoint `
                -Detail "Teams follows the WinINET proxy $named, which is accepting connections. The checks above connected directly, not through it." | Out-Null
        }
    } elseif ($proxy.WinInet.AutoConfigUrl) {
        Write-TlcBlocker -Check 'Network.Proxy' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail "Teams follows a proxy auto-config script ($($proxy.WinInet.AutoConfigUrl)). It decides per URL, so it was recorded rather than tested." | Out-Null
    }
}

function Invoke-TlcNetworkCollection {
    <#
    .SYNOPSIS
        Auto lane for the network scenario.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string] $Endpoint = $env:COMPUTERNAME,
        [string] $Scenario = '',
        [string] $CloudInstance = '',

        # The client state root, handed straight to Get-TlcTacCorrelation below. It is a
        # parameter rather than a local because that function's -StateRoot is mandatory,
        # and a mandatory parameter left off does not fail - it prompts. Under Pester a
        # prompt is not a failing test, it is a process that waits forever with nothing
        # written and nothing to point at, which is exactly how the UI suite came to hang.
        # Empty is allowed and means the client's own cloud is not read, the same as on a
        # machine where Teams has never run.
        [string] $StateRoot = ''
    )

    $facts = Get-TlcNetworkFact
    $proxy = Get-TlcProxyConfiguration
    $proxyReach = Test-TlcProxyReachability -Proxy $proxy
    $localBlocks = Get-TlcLocalBlockFact
    $intermediation = Get-TlcNetworkIntermediation -IncludeVpnProfiles
    $wifi = Get-TlcWifiFact

    # Which cloud's host names to test. Detected from the device's own sign-in authority when
    # the caller has not said, because the cloud was a setting almost nobody set - so every
    # collection tested worldwide endpoints, including on the government tenants where that
    # answer is wrong. An explicit -CloudInstance always wins: the operator may know something
    # the device does not, and a DoD tenant cannot be told from GCC High by its authority.
    $cloudFact = $null
    $instance = $CloudInstance
    if (-not $instance) {
        # The client's own word for its cloud, already collected as TacCorrelation.Cloud.
        # Read here rather than re-derived, so the network lane and the inventory cannot
        # disagree about what the client said.
        $clientCloud = ''
        try {
            if (Get-Command -Name 'Get-TlcTacCorrelation' -ErrorAction SilentlyContinue) {
                $correlation = Get-TlcTacCorrelation -StateRoot $StateRoot
                if ($correlation -and $correlation.PSObject.Properties.Name -contains 'Cloud') {
                    $clientCloud = [string]$correlation.Cloud
                }
            }
        } catch {
            Write-Verbose "The client's cloud could not be read: $($_.Exception.Message)"
        }

        $cloudFact = Get-TlcTenantCloudFact -ClientCloud $clientCloud
        if ($cloudFact.Detected) { $instance = $cloudFact.Instance }
    }
    $cloud = Get-TlcCloudEndpoint -Instance $instance

    # The two names that matter most: the one the client signs in against and the one
    # the media path is negotiated through. Both are recorded as full chains, because
    # the hops are where interception shows up.
    #
    # The relay chain is only resolved when the cloud has a published relay NAME. Microsoft
    # publishes one for the worldwide cloud only; government and China relay reachability is
    # published as IP subnets plus UDP 3478-3481, with no host name at all. Resolving an empty
    # or invented name there would produce a DNS failure that says nothing about the network.
    $dnsChains = @(
        if ($cloud) {
            Resolve-TlcDnsChain -HostName $cloud.Teams
            if ($cloud.MediaRelay) { Resolve-TlcDnsChain -HostName $cloud.MediaRelay }
        } else {
            Resolve-TlcDnsChain -HostName 'teams.microsoft.com'
            Resolve-TlcDnsChain -HostName 'worldaz.tr.teams.microsoft.com'
        }
    )

    # The published names of the cloud being tested. Test-TlcTeamsEndpoint and the two media
    # probes carry worldwide defaults, and calling them bare tested commercial hosts on every
    # cloud, so a government tenant's reachability rows described endpoints its client never
    # uses (review 2026-09-30, finding 331).
    $tcp = if ($cloud) {
        @(Test-TlcTeamsEndpoint -HostNames @(@($cloud.Teams, $cloud.Config, $cloud.Login) | Where-Object { $_ }))
    } else {
        @(Test-TlcTeamsEndpoint)
    }

    # Same reason. The STUN probe needs a host to aim at, and on a cloud where Microsoft
    # publishes none, "not tested, and here is why" is worth more than a failure against a
    # name that was never real.
    #
    # The skipped probes still return a record. Every row below reads .Summary and the entry
    # point reads .ReachableCount, and a $null here threw under StrictMode. ReachableCount is
    # null rather than 0 so Summary.csv shows "not tested" as blank, not as "none answered".
    $relaySkipped = [bool]($cloud -and -not $cloud.MediaRelay)
    if ($relaySkipped) {
        $ports = @($cloud.RelayPorts)
        $portRange = if ($ports.Count -gt 0) { "UDP $($ports[0])-$($ports[-1])" } else { 'UDP 3478-3481' }
        $notTested = "Microsoft publishes no media relay host name for the $($cloud.Instance) cloud, so"
        Write-TlcBlocker -Check 'Network.MediaRelay' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail "$notTested relay reachability was not tested by name." `
            -Remediation "Test $portRange against the published Optimize IP ranges for this cloud instead." | Out-Null
        $stun = [ordered]@{
            HostName = ''; Tested = $false; Resolved = $false; Results = @(); ReachableCount = $null
            Summary = "Media relay reachability was not tested: $notTested there is no host to probe."
        }
        $quality = [ordered]@{
            HostName = ''; Port = $null; Resolved = $false; Measured = $false
            Summary = "Media path quality was not measured: $notTested there is no relay to measure against."
        }
    } elseif ($cloud) {
        $stunArguments = @{ HostName = $cloud.MediaRelay }
        if (@($cloud.RelayPorts).Count -gt 0) { $stunArguments['Ports'] = [int[]]@($cloud.RelayPorts) }
        $stun = Test-TlcStunReachability @stunArguments
        $quality = Measure-TlcMediaPathQuality -HostName $cloud.MediaRelay
    } else {
        $stun = Test-TlcStunReachability
        $quality = Measure-TlcMediaPathQuality
    }

    # Whether the machine marks its media, as distinct from whether the path works. The rest
    # of this lane measures the path; unmarked media is a documented cause of poor quality on
    # a path that measures perfectly.
    $qos = Get-TlcQosPolicyFact

    # Only for endpoints that answered. A handshake against something unreachable adds a
    # timeout per endpoint and tells nobody anything.
    $tls = @(
        foreach ($endpointResult in ($tcp | Where-Object { $_.Connected })) {
            Get-TlcTlsCertificateFact -HostName $endpointResult.HostName -Port $endpointResult.Port
        }
    )

    $record = [ordered]@{
        Endpoint       = $Endpoint
        NetworkFacts   = $facts
        Cloud          = $cloud
        CloudDetection = $cloudFact
        Proxy          = $proxy
        ProxyReachability = $proxyReach
        LocalBlocks    = $localBlocks
        Intermediation = $intermediation
        Wifi           = $wifi
        DnsChains      = $dnsChains
        TlsCertificates = $tls
        TcpEndpoints   = $tcp
        MediaPath      = $stun
        MediaQuality   = $quality
        QosPolicy      = $qos
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $path = Export-TlcEvidence -Name 'Network.json' -InputObject $record -Endpoint $Endpoint

    $failedTcp = @($tcp | Where-Object { -not $_.Connected })
    if ($failedTcp.Count -gt 0) {
        Write-TlcBlocker -Check 'Network.Tcp' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$($failedTcp.Count) endpoint(s) unreachable: $(($failedTcp | ForEach-Object { $_.HostName }) -join ', ')" `
            -Remediation 'Check proxy, firewall and DNS for the Teams endpoints.' | Out-Null
    } else {
        Write-TlcBlocker -Check 'Network.Tcp' -Status 'Success' -Endpoint $Endpoint `
            -Detail "$($tcp.Count) endpoint(s) reachable on 443." | Out-Null
    }

    if ($relaySkipped) {
        Write-TlcBlocker -Check 'Network.MediaPath' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail $stun.Summary `
            -Remediation 'Run the Teams Network Assessment Tool for an authoritative UDP measurement.' | Out-Null
    } else {
        $mediaStatus = if ($stun -and $stun.ReachableCount -gt 0) { 'Success' } else { 'Warning' }
        Write-TlcBlocker -Check 'Network.MediaPath' -Status $mediaStatus -Severity 'Warning' -Endpoint $Endpoint `
            -Detail $stun.Summary `
            -Remediation 'Run the Teams Network Assessment Tool for an authoritative UDP measurement.' | Out-Null
    }

    # The causes on this machine, named. Rows only when there is something to say or the
    # answer is worth stating: a clean hosts file is not news, a proxy that answers is.
    Write-TlcNetworkCauseRow -LocalBlocks $localBlocks -ProxyReach $proxyReach -Proxy $proxy -Endpoint $Endpoint

    # Success covers both "correctly marked" and "no policy at all". Those are different
    # facts but neither is a fault: most endpoints are unmanaged and have no QoS policy, and
    # raising a warning on every healthy desktop is how a check gets ignored. The detail
    # carries the meaning, and Severity stays Information so it never reads as urgent.
    #
    # EXCEPT when the complaint IS call quality. Measured on a real CallQuality run: the row
    # read "Success - No QoS policy marks Teams media on this machine", and an engineer
    # scanning the status column skips it. The detail already said "significant when the
    # complaint is call quality" and the status contradicted it. On the scenarios where
    # unmarked media is a documented cause of the reported symptom, absent marking is worth a
    # Warning; everywhere else it is background.
    #
    # Warning also covers the two cases a human should always look at: a policy present but
    # marked with undocumented values, and a missing cmdlet so the question went unanswered.
    $qosMattersHere = $Scenario -in @('CallQuality', 'MeetingJoin', 'CviRoomSegment')
    $qosStatus = if (-not $qos.CmdletAvailable) { 'Warning' }
                 elseif (@($qos.Mismatched).Count -gt 0) { 'Warning' }
                 elseif ($qosMattersHere -and @($qos.TeamsPolicies).Count -eq 0) { 'Warning' }
                 else { 'Success' }
    Write-TlcBlocker -Check 'Network.QosMarking' -Status $qosStatus -Severity 'Information' -Endpoint $Endpoint `
        -Detail $qos.Detail `
        -Remediation 'If call quality is the complaint, see learn.microsoft.com/en-us/microsoftteams/qos-in-teams-clients for the documented policies (audio 50000-50019 DSCP 46, video 50020-50039 DSCP 34, sharing 50040-50059 DSCP 18, signaling 50070-50089 DSCP 40).' | Out-Null

    # Reported as a Warning rather than a Success when something is in the path, but it
    # is context, not a fault: plenty of healthy estates tunnel all their traffic. What
    # it warns about is reading the checks above as direct measurements when they are
    # not - the TCP and STUN results were taken through whatever this names.
    if ($intermediation.Intermediated) {
        Write-TlcBlocker -Check 'Network.Intermediation' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail "Traffic is carried through $($intermediation.Summary). The reachability and media-path results above were measured through it, not directly." `
            -Remediation 'Not a fault in itself. Compare against a machine off this path before treating a network result as a customer network problem.' | Out-Null
    } else {
        Write-TlcBlocker -Check 'Network.Intermediation' -Status 'Success' -Endpoint $Endpoint `
            -Detail 'No tunnelling client or connected VPN was detected, so the checks above measured the direct path.' | Out-Null
    }

    $inspected = @($tls | Where-Object { $_.Handshake -and -not $_.PubliclyRooted })
    $verified = @($tls | Where-Object { $_.Handshake -and $_.PubliclyRooted })
    if ($inspected.Count -gt 0) {
        Write-TlcBlocker -Check 'Network.TlsInspection' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$($inspected.Count) endpoint(s) presented a certificate chaining to a root outside the public set, which is what break-and-inspect looks like: $(($inspected | ForEach-Object { "$($_.HostName) <- $($_.ChainRoot)" }) -join '; ')" `
            -Remediation 'Microsoft documents TLS inspection on Optimize-category endpoints as a cause of Teams update and media failures. Confirm the root named above is the corporate proxy CA, then exempt the Teams endpoints from inspection and retest.' | Out-Null
    } elseif ($verified.Count -gt 0) {
        Write-TlcBlocker -Check 'Network.TlsInspection' -Status 'Success' -Endpoint $Endpoint `
            -Detail "$($verified.Count) endpoint(s) chained to a public root, so nothing is terminating TLS in the middle on those paths." | Out-Null
    }

    # Quality, as distinct from reachability above. Warning only on a threshold the
    # guidance actually publishes, and the detail says how few probes it is built on -
    # ten datagrams is an indication, not a network assessment, and reporting it as
    # though it were would send someone to the wrong place with confidence.
    if ($quality.Measured) {
        $qualityStatus = if (@($quality.Breaches).Count -gt 0) { 'Warning' } else { 'Success' }
        Write-TlcBlocker -Check 'Network.MediaQuality' -Status $qualityStatus -Severity 'Warning' -Endpoint $Endpoint `
            -Detail $quality.Summary `
            -Remediation 'Thresholds are the published ones: loss under 1%, latency under 100 ms, jitter under 30 ms. Confirm with the Network Assessment Tool or the Microsoft 365 connectivity test before acting on this alone.' | Out-Null
    } else {
        Write-TlcBlocker -Check 'Network.MediaQuality' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail $quality.Summary | Out-Null
    }

    Write-TlcEvent -Phase 'Collect' -Step 'Network' -Status 'Complete' -Endpoint $Endpoint `
        -Message $stun.Summary -EvidencePath $path

    return $record
}

Export-ModuleMember -Function Get-TlcTenantCloudFact, Get-TlcCloudEndpoint, Get-TlcQosPolicyFact, Get-TlcNetworkFact, Get-TlcProxyConfiguration, Test-TlcStunReachability,
    Test-TlcTeamsEndpoint, Get-TlcNetworkIntermediation, Resolve-TlcDnsChain, Get-TlcWifiFact,
    Get-TlcTlsCertificateFact, Measure-TlcMediaPathQuality, Invoke-TlcNetworkCollection, Get-TlcLocalBlockFact, Test-TlcProxyReachability, Write-TlcNetworkCauseRow

