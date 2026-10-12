Set-StrictMode -Version Latest

<#
    Cloud Video Interop (CVI) and conference-room support.

    Everything here exists because of one architectural fact, and it is worth stating
    before any of the code: the CVI partner's gateway joins the meeting as a BOT.
    Microsoft's telemetry begins and ends at that bot's leg. The SIP/H.323 leg between
    the room codec and the partner cloud is invisible to every Microsoft surface there
    is. No collector in this file, or any file, can produce packet loss between a codec
    and Webex.

    So this module does not try to diagnose the interop path. It does the two things a
    Windows toolbox genuinely can:

      1. Produce the evidence Microsoft's own troubleshooting guidance asks for. That
         guidance is a single A/B test - put a native Teams client on the same network
         segment as the failing codec, and if Teams is healthy there, the customer
         network is exonerated and the case belongs to the partner. That is ordinary
         desktop and network collection pointed at the room VLAN, which this toolbox
         already does. What was missing was labelling the bundle as the comparison leg
         so the person reading it knows what question it answers.

      2. Make three vendors' logs line up. There is no end-to-end correlation id - none
         is documented, and three different identifiers share confusingly similar names
         across the Microsoft, Webex and Control Hub namespaces. What exists instead is
         a join key, so the correlation header records the identifiers each vendor can
         actually search on and says plainly which ones were not supplied.
#>

function New-TlcCorrelationHeader {
    <#
    .SYNOPSIS
        Builds the identifier header that lets Microsoft and partner logs be joined.
    .DESCRIPTION
        A CVI case is worked by at least two support organisations that share no
        identifier. Microsoft support searches on the meeting and the organizer; Cisco
        TAC searches on the codec and its own tracking ids; the customer knows the room.
        Handing each of them only the identifiers from their own namespace is what turns
        a two-day case into a two-week one.

        Every field is optional on purpose. An operator standing in a meeting room will
        not have all of them, and refusing to write the header until they do would mean
        no header at all. Missing fields are listed explicitly in Unsupplied rather than
        left blank, because a blank line in a handover document reads as "not
        applicable" when it actually means "nobody has looked yet".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $CorrelationId,
        [Parameter(Mandatory)] [string] $Endpoint,
        [datetime] $WindowStart,
        [datetime] $WindowEnd,
        [string] $CaseNumber,
        [string] $OrganizerUpn,
        [string] $MeetingId,
        [string] $VideoTeleconferenceId,
        [string] $RoomResourceAccount,
        [string] $CodecAddress,
        [string] $CviPartner,
        [string] $TeamsVersion
    )

    $fields = [ordered]@{
        CorrelationId         = $CorrelationId
        CaseNumber            = $CaseNumber
        CollectedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        Endpoint              = $Endpoint
        Operator              = "$env:USERDOMAIN\$env:USERNAME"
        TeamsVersion          = $TeamsVersion
        WindowStartUtc        = if ($PSBoundParameters.ContainsKey('WindowStart')) { $WindowStart.ToUniversalTime().ToString('o') } else { '' }
        WindowEndUtc          = if ($PSBoundParameters.ContainsKey('WindowEnd')) { $WindowEnd.ToUniversalTime().ToString('o') } else { '' }
        OrganizerUpn          = $OrganizerUpn
        MeetingId             = $MeetingId
        VideoTeleconferenceId = $VideoTeleconferenceId
        RoomResourceAccount   = $RoomResourceAccount
        CodecAddress          = $CodecAddress
        CviPartner            = if ($CviPartner) { $CviPartner } else { 'Unknown' }
    }

    # Only the fields a partner or Microsoft would actually search on. CorrelationId and
    # Operator are always present, so listing them as "unsupplied" would be noise.
    $joinKeys = @('CaseNumber', 'OrganizerUpn', 'MeetingId', 'VideoTeleconferenceId',
                  'RoomResourceAccount', 'CodecAddress')
    $unsupplied = @($joinKeys | Where-Object { [string]::IsNullOrWhiteSpace([string]$fields[$_]) })

    $fields['Unsupplied'] = $unsupplied

    # The Pexip caveat is load-bearing rather than trivia. Microsoft's release notes list
    # CVI telemetry into CQD as available for Cisco and Poly but TBD for Pexip, so empty
    # VTC dimensions mean "no data is emitted" on one partner and "this was not a CVI
    # leg" on another. Reading absence as evidence without knowing the partner is the
    # easiest way to blame the wrong vendor, so the warning travels with the bundle.
    $fields['TelemetryCaveat'] = switch -Regex ($fields.CviPartner) {
        'Pexip'        { 'Pexip does not emit CVI telemetry into CQD. Absent VTC dimensions in CQD prove nothing here.'; break }
        'Cisco|Poly'   { 'This partner emits CVI telemetry into CQD, so absent VTC dimensions are themselves a signal.'; break }
        default        { 'Partner not identified, so absent VTC dimensions in CQD cannot be interpreted either way.'; break }
    }

    return [pscustomobject]$fields
}

function Format-TlcCorrelationHeader {
    <#
    .SYNOPSIS
        Renders the correlation header as text a person can paste into a ticket.
    .DESCRIPTION
        The JSON is for tooling. This is for the support case: it gets pasted into a
        Cisco TAC ticket and a Microsoft case, which is the whole reason the header
        exists. A JSON blob in a ticket body gets skimmed and ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Header
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Teams / CVI correlation header')
    $lines.Add('=============================')
    $lines.Add('')
    $lines.Add('Give this block to Microsoft support and to the CVI partner. No single')
    $lines.Add('identifier crosses the interop boundary, so each side needs the whole set to')
    $lines.Add('find the same call in its own logs.')
    $lines.Add('')

    $labels = [ordered]@{
        CaseNumber            = 'Support case'
        CorrelationId         = 'Collection id'
        CollectedAtUtc        = 'Collected (UTC)'
        WindowStartUtc        = 'Window start (UTC)'
        WindowEndUtc          = 'Window end (UTC)'
        Endpoint              = 'Collected from'
        TeamsVersion          = 'Teams version'
        OrganizerUpn          = 'Meeting organizer'
        MeetingId             = 'Meeting id'
        VideoTeleconferenceId = 'VTC conference id'
        RoomResourceAccount   = 'Room resource account'
        CodecAddress          = 'Codec address'
        CviPartner            = 'CVI partner'
    }

    foreach ($key in $labels.Keys) {
        $value = [string]$Header.$key
        if ([string]::IsNullOrWhiteSpace($value)) { $value = '(not supplied)' }
        $lines.Add(('{0,-22} : {1}' -f $labels[$key], $value))
    }

    $lines.Add('')
    if (@($Header.Unsupplied).Count) {
        $lines.Add('Not supplied, and worth filling in before the ticket goes out:')
        foreach ($field in $Header.Unsupplied) { $lines.Add("  - $field") }
        $lines.Add('')
    }

    $lines.Add('CQD note: ' + $Header.TelemetryCaveat)
    $lines.Add('')
    $lines.Add('Reminder: Microsoft telemetry covers the partner bot leg only. Packet loss')
    $lines.Add('between the codec and the partner cloud is not visible to any Microsoft')
    $lines.Add('surface, and has to come from the partner.')

    return ($lines -join [Environment]::NewLine)
}

function Get-TlcCviPolicyFact {
    <#
    .SYNOPSIS
        Reads the tenant's CVI and Teams Rooms video-teleconferencing policy.
    .DESCRIPTION
        Answers "why does this organizer's invite carry no CVI coordinates?", which is a
        configuration question rather than a media one and is therefore answerable from
        here. An invite with no VTC block never had a chance to work, and finding that
        out first avoids a media investigation into a meeting that was never CVI-enabled.

        The MicrosoftTeams module is not a dependency of this toolbox and will usually be
        absent on a customer endpoint, so an absent module or an unconnected session is
        reported as a fact rather than thrown. Every other collector here degrades the
        same way: what could not be gathered is visible in the bundle instead of missing
        without explanation.

        NOT CALLED BY A COLLECTION any more (finding 296). A customer run never has the Teams
        admin session this needs, so the tenant policy is a manual checklist item instead.
        This remains for Tools\Connect-TlcTeams.ps1, an interactive development tool.
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        ModuleAvailable = $false
        Connected       = $false
        Reason          = ''
        Providers       = @()
        Policies        = @()
        RoomPolicies    = @()
    }

    $module = Get-Module -ListAvailable -Name 'MicrosoftTeams' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $module) {
        $result.Reason = 'The MicrosoftTeams module is not installed, so tenant policy could not be read. Install-Module MicrosoftTeams, then Connect-MicrosoftTeams.'
        return [pscustomobject]$result
    }

    $result.ModuleAvailable = $true
    $result['ModuleVersion'] = [string]$module.Version

    # Probe with the cheapest cmdlet rather than Get-CsTenant, which is slow, and treat
    # any failure as "not connected". Distinguishing an expired token from a missing role
    # is not worth a second round trip when the remediation is the same either way.
    $providers = $null
    try {
        $providers = @(Get-CsVideoInteropServiceProvider -ErrorAction Stop)
        $result.Connected = $true
    } catch {
        $result.Reason = "The MicrosoftTeams module is installed but tenant policy could not be read: $($_.Exception.Message) Run Connect-MicrosoftTeams first."
        return [pscustomobject]$result
    }

    $result.Providers = @($providers | ForEach-Object {
        [pscustomobject][ordered]@{
            Name        = [string]$_.Identity
            TenantKey   = [string]$_.TenantKey
            Enabled     = $_.Enabled
            InstructionUri = [string]$_.InstructionUri
        }
    })

    foreach ($entry in @(
        @{ Key = 'Policies';     Cmdlet = 'Get-CsTeamsVideoInteropServicePolicy' }
        @{ Key = 'RoomPolicies'; Cmdlet = 'Get-CsTeamsRoomVideoTeleConferencingPolicy' }
    )) {
        try {
            $result[$entry.Key] = @(& $entry.Cmdlet -ErrorAction Stop | ForEach-Object {
                [pscustomobject][ordered]@{
                    Identity             = [string]$_.Identity
                    Enabled              = if ($_.PSObject.Properties.Name -contains 'Enabled') { $_.Enabled } else { $null }
                    SupportedProvider    = if ($_.PSObject.Properties.Name -contains 'SupportedProvider') { [string]$_.SupportedProvider } else { '' }
                    # Microsoft notes that on a CVI tenant AreaCode may match the CVI
                    # TenantKey, which makes a mismatch here worth looking at directly.
                    AreaCode             = if ($_.PSObject.Properties.Name -contains 'AreaCode') { [string]$_.AreaCode } else { '' }
                    ReceiveExternalCalls = if ($_.PSObject.Properties.Name -contains 'ReceiveExternalCalls') { [string]$_.ReceiveExternalCalls } else { '' }
                    ReceiveInternalCalls = if ($_.PSObject.Properties.Name -contains 'ReceiveInternalCalls') { [string]$_.ReceiveInternalCalls } else { '' }
                }
            })
        } catch {
            # A cmdlet missing from an older module build is not a failed collection.
            $result[$entry.Key] = @()
        }
    }

    return [pscustomobject]$result
}

function Get-TlcRemoteLogCollectionFact {
    <#
    .SYNOPSIS
        Reads whether the tenant already has a TAC remote log collection request pending
        for this user, and whether the feature is even available to them.
    .DESCRIPTION
        Answers "has someone already asked for this?" before an engineer spends a run
        duplicating it. A TAC request takes up to 8 hours to produce a downloadable bundle
        and expires after 3 days, so a request raised this morning by the customer's own
        admin is evidence already in flight - and the local collection may still be worth
        doing, but for different reasons rather than by accident.

        READ ONLY, DELIBERATELY. This never calls New-CsTeamsRemoteLogCollectionDevice.
        Raising a TAC request collects logs from a user's device with no prompt and no
        consent record - Microsoft documents that no message is shown to the user - which
        is the opposite of how this toolbox handles consent everywhere else. An engineer
        can raise one in TAC where the action is attributable to them; the toolbox will not
        do it silently on their behalf.

        Degrades exactly like Get-TlcCviPolicyFact: the MicrosoftTeams module is not a
        dependency and is usually absent on a customer endpoint, so an absent module, an
        unconnected session or a missing admin role is reported as a fact in the bundle
        rather than thrown.

        The UserId comes from the client's own ECS request parameters, which is the same
        identifier TAC keys a request on - see TacCorrelation in Inventory.json.

        NOT CALLED BY A COLLECTION any more (finding 296). A customer run never has the Teams
        admin session this needs, so "is a request already pending" is now the first step of
        the TacRemoteClientLogs manual checklist item. This remains for
        Tools\Connect-TlcTeams.ps1, an interactive development tool.
    #>
    [CmdletBinding()]
    param(
        [string] $UserId
    )

    $result = [ordered]@{
        ModuleAvailable  = $false
        Connected        = $false
        Reason           = ''
        UserIdQueried    = [string]$UserId
        PendingRequests  = @()
        ConfigurationRead = $false
        Configuration    = $null
    }

    $module = Get-Module -ListAvailable -Name 'MicrosoftTeams' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        $result.Reason = 'The MicrosoftTeams module is not installed, so a pending TAC log request could not be checked. Install-Module MicrosoftTeams, then Connect-MicrosoftTeams.'
        return [pscustomobject]$result
    }

    $result.ModuleAvailable = $true
    $result['ModuleVersion'] = [string]$module.Version

    # The configuration object is read-only in PowerShell - there is no New-/Set-/Remove-
    # counterpart - so it doubles as the cheapest possible connection probe.
    try {
        $configuration = Get-CsTeamsRemoteLogCollectionConfiguration -ErrorAction Stop
        $result.Connected = $true
        $result.ConfigurationRead = $true
        $result.Configuration = [pscustomobject][ordered]@{
            Identity      = [string]$configuration.Identity
            RetentionDays = if ($configuration.PSObject.Properties.Name -contains 'RetentionDays') { $configuration.RetentionDays } else { $null }
        }
    } catch {
        $result.Reason = "The MicrosoftTeams module is installed but the tenant could not be read: $($_.Exception.Message) Run Connect-MicrosoftTeams with a Teams Administrator or Teams Communications Support role."
        return [pscustomobject]$result
    }

    if (-not $UserId) {
        $result.Reason = 'Connected, but no UserId was available to query. TAC keys a log request on the Entra user id; see TacCorrelation in Inventory.json.'
        return [pscustomobject]$result
    }

    try {
        $devices = @(Get-CsTeamsRemoteLogCollectionDevice -Identity $UserId -ErrorAction Stop)
        $result.PendingRequests = @($devices | ForEach-Object {
            [pscustomobject][ordered]@{
                DeviceId    = if ($_.PSObject.Properties.Name -contains 'DeviceId') { [string]$_.DeviceId } else { '' }
                Platform    = if ($_.PSObject.Properties.Name -contains 'Platform') { [string]$_.Platform } else { '' }
                RequestedAt = if ($_.PSObject.Properties.Name -contains 'RequestedTime') { [string]$_.RequestedTime } else { '' }
                Status      = if ($_.PSObject.Properties.Name -contains 'Status') { [string]$_.Status } else { '' }
            }
        })
    } catch {
        # A user with no request raised is not an error, but the cmdlet may report it as
        # one. Recorded as a reason rather than an empty list with no explanation, because
        # "nothing pending" and "could not check" lead to different decisions.
        $result.Reason = "Connected, but the request list for $UserId could not be read: $($_.Exception.Message)"
    }

    return [pscustomobject]$result
}

function Invoke-TlcCviCollection {
    <#
    .SYNOPSIS
        Collects the CVI-specific evidence and writes the correlation header.
    .DESCRIPTION
        Deliberately thin. The heavy lifting for a room-segment comparison is the
        ordinary desktop and network collection, which the Collect stage already runs
        for this scenario - this adds only what is specific to interop, and records the
        boundary so the bundle cannot be mistaken for something that covers the SIP leg.

        NO TENANT READ. This used to call Get-TlcCviPolicyFact, which needs a Teams admin
        session on the endpoint. A customer run never has one, and the Teams module will
        not authenticate from a non-interactive host at all (measured 2026-09-09), so every
        real run wrote a "could not be read" warning and nothing else. The tenant policy is
        now a manual checklist item, CviTenantPolicy, with the three read-only commands for
        the tenant admin to run. Owner decision 2026-09-24; finding 296.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [Parameter(Mandatory)] [string] $Endpoint,
        [Parameter(Mandatory)] $Header
    )

    $headerText = Format-TlcCorrelationHeader -Header $Header
    $textPath = Join-Path $EndpointPath 'CorrelationHeader.txt'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($textPath, $headerText, $utf8NoBom)

    Write-TlcEvent -Phase 'Collect' -Step 'Cvi.CorrelationHeader' -Status 'Complete' -Endpoint $Endpoint `
                   -Message "Correlation header written; $(@($Header.Unsupplied).Count) field(s) not supplied." `
                   -EvidencePath $textPath

    if (@($Header.Unsupplied).Count) {
        # A warning rather than a blocker. The bundle is still worth having without a
        # codec address; it is just harder for the partner to find their side of it.
        Write-TlcBlocker -Check 'Cvi.CorrelationHeader' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                         -Detail ("Correlation fields not supplied: {0}." -f (@($Header.Unsupplied) -join ', ')) `
                         -Remediation 'Re-run with the missing values, or complete CorrelationHeader.txt by hand before sending the bundle to the partner.' | Out-Null
    }

    # Stated in the evidence, not just in the docs. Whoever opens this bundle in three
    # weeks needs to know what it cannot answer without having read anything else.
    $boundary = [ordered]@{
        MicrosoftTelemetryCovers = 'The CVI partner bot leg, which is a Teams participant like any other.'
        NotCovered               = 'The SIP/H.323 leg between the room codec and the partner cloud. No Microsoft API or CQD dimension exposes it.'
        PartnerEvidenceNeeded    = 'Codec log bundle with extended logging, and partner-portal media graphs for the call.'
        MicrosoftGuidance        = 'A native Teams client on the same network segment as the codec is the documented test. Healthy here means the case belongs with the partner.'
        TenantPolicy             = 'Not read from the endpoint. See the CviTenantPolicy item in ManualChecklist.md for the read-only commands the tenant admin runs.'
    }

    return [pscustomobject][ordered]@{
        Endpoint          = $Endpoint
        CorrelationHeader = $Header
        HeaderTextPath    = $textPath
        Boundary          = [pscustomobject]$boundary
    }
}

Export-ModuleMember -Function Get-TlcRemoteLogCollectionFact, New-TlcCorrelationHeader, Format-TlcCorrelationHeader,
    Get-TlcCviPolicyFact, Invoke-TlcCviCollection
