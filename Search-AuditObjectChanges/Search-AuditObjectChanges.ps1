<#
.SYNOPSIS
Find object-related changes in Microsoft 365 Unified Audit Log with smart RecordType inference,
stable output columns, and mailbox-focused defaults.

.DESCRIPTION
Search-UnifiedAuditEvent queries Search-UnifiedAuditLog with targeted, high-signal filters to
answer “who changed WHAT, and WHEN?” across common object types (mailboxes, distribution lists,
Entra ID groups). It infers the correct RecordType(s) from your inputs and can run multiple
server-side passes (fast path) or a single broad call (minimal call count).

Key behavior:
- Defaults to a 24-hour UTC window (now − 1 day → now).
- Stable columns: LocalTimeZoneId (e.g., "Central Standard Time (CDT)"), WhenLocal, WhenUtc, Workload, RecordType, Operation, Actor, Object, Subjects, ClientIP, [Member], [Modified].
- Mailbox selector returns both item ops (deletes/moves) and, by default, a lean set of mailbox admin ops (e.g., Set-Mailbox, permissions). Broaden via -AdminOpsMode.
- Supports server-side actor filter (-UserIds), client-side contains (-ActorLike), and ops narrowing (-Operations).
- PS 5.1-compatible (no PowerShell 7-only syntax).

DISCLAIMER
This function is a community convenience script and is NOT an official Microsoft-supported tool.
It is provided “as is” with no warranties. Test in non-production first and review output before acting.

PREREQUISITES
- Exchange Online PowerShell (Search-UnifiedAuditLog, Get-Mailbox, Get-DistributionGroup).
- Appropriate audit licensing/retention and permissions.

PARAMETERS
    -Mailbox <String>
        Mailbox identity. With no -Operations/-RecordType, searches ExchangeItem (item-level deletes)
        AND a lean set of ExchangeAdmin mailbox ops (see -AdminOpsMode).

    -SubjectLike <String>
        Optional subject/path contains filter for item-level results (Mailbox set only).

    -DistributionGroup <String>
        Distribution Group identity (SMTP/Name/Alias/DisplayName/LegacyDN). Searches ExchangeAdmin.

    -GroupId <String>
        Entra ID (M365) Group GUID. Searches AzureActiveDirectory.

    -Operations <String[]>
        Explicit ops (e.g., 'Set-Mailbox','SoftDelete'). If mixed across RecordTypes, the function
        splits into focused passes automatically (default strategy).

    -RecordType <String>
        Force a specific record type (e.g., ExchangeAdmin, ExchangeItem, AzureActiveDirectory).
        Skips inference.

    -UserIds <String[]>
        Server-side actor filter (UPN list). Highly recommended for “what did X do?” scenarios.

    -ResultSize <Int>
        Paging size for Search-UnifiedAuditLog (e.g., 5000).

    -StartDate, -EndDate <DateTime>
        UTC window. Defaults to now−1 day .. now (UTC) when not provided.

    -StartDateLocalTz, -EndDateLocalTz <DateTime>
        Local window inputs (converted to UTC using -LocalTimeZoneId). Do not combine with UTC variants.

    -LocalTimeZoneId <String>
        Windows TZ ID used for conversions and presentation (default: current host TZ).
        Output shows “<Id> (<abbrev>)”, e.g., “Central Standard Time (CDT)”.

    -LocalTimeAbbrev <String>
        Optional override for the abbreviation presented alongside -LocalTimeZoneId.

    -ActorLike <String>
        Client-side “contains” filter on actor UPN. Use -UserIds whenever possible for server-side filtering.

    -AdminOpsMode <Lean|Broad|All>
        Used only when -Mailbox is specified and -Operations is not.
        Lean (default): Set-Mailbox + common mailbox/recipient permission ops (fast).
        Broad: adds CAS, autoreply, calendar, regional config, folder-perm ops.
        All: no operations filter for ExchangeAdmin (heaviest; pair with -UserIds and tight time).

    -ExtraOperations <String[]>
        Extra admin ops to include when -Mailbox and no -Operations (except AdminOpsMode=All).

    -RecordTypeStrategy <InferMultiPass|AllTypesSingleCall>
        InferMultiPass (default): targeted calls per inferred RecordType (fast).
        AllTypesSingleCall: one broad call without RecordType (minimal API calls; potentially slower).

    -ExpandIfEmpty
        If no results, automatically re-run with StartDate extended back an additional 3 days.

    -ReturnRaw
        Return the raw Search-UnifiedAuditLog records (no shaping).

INPUTS
None. (All input via parameters.)

OUTPUTS
[PSCustomObject] with stable columns:
LocalTimeZoneId, WhenLocal, WhenUtc, Workload, RecordType, Operation, Actor, Object, Subjects, ClientIP, [Member], [Modified]

EXAMPLES
1) Distribution group membership/config changes (past 24h):
    Search-UnifiedAuditEvent -DistributionGroup 'notgolfers@contoso.com'

2) Mailbox deletes + common mailbox admin ops (fast defaults):
    Search-UnifiedAuditEvent -Mailbox 'wsobchak' -StartDateLocalTz (Get-Date).AddHours(-12) -EndDateLocalTz (Get-Date)

3) Wider mailbox admin coverage without specifying ops:
    Search-UnifiedAuditEvent -Mailbox 'wsobchak' -AdminOpsMode Broad

4) Max admin coverage for a specific actor:
    Search-UnifiedAuditEvent -Mailbox 'wsobchak' -AdminOpsMode All -UserIds 'ch.adm@contoso.com' -StartDate (Get-Date).AddHours(-6).ToUniversalTime() -EndDate (Get-Date).ToUniversalTime()

5) Single broad call (minimize API calls):
    Search-UnifiedAuditEvent -Mailbox 'shared@contoso.com' -RecordTypeStrategy AllTypesSingleCall -ResultSize 5000

6) CSV export with a fixed column order:
    Search-UnifiedAuditEvent -Mailbox 'wsobchak' |
      Select LocalTimeZoneId,WhenLocal,WhenUtc,Workload,RecordType,Operation,Actor,Object,Subjects,ClientIP,Member,Modified |
      Export-Csv .\audit.csv -NoTypeInformation

NOTES
- Defaults to now−1 day → now (UTC).
- LocalTimeZoneId shows the ID plus its current-abbrev, e.g., “Central Standard Time (CDT)”.
- For best performance in large tenants, always prefer -UserIds and tight time windows.
- PS 5.1 compatible. If a future enhancement requires PS 7+, the function will call it out.

VERSION HISTORY
  0.9  — Initial release (Alpha)

#>

function Search-UnifiedAuditEvent {
    [CmdletBinding(DefaultParameterSetName='Generic', SupportsShouldProcess=$false)]
    param(
        # ----- Mutually exclusive object selectors -----
        [Parameter(ParameterSetName='Mailbox')]
        [string]$Mailbox,

        [Parameter(ParameterSetName='Mailbox')]
        [string]$SubjectLike,

        [Parameter(ParameterSetName='DL')]
        [string]$DistributionGroup,

        [Parameter(ParameterSetName='AADGroup')]
        [string]$GroupId,   # Entra ID (M365 Group) GUID

        # ----- Server-side filters (usable with any set) -----
        [string[]]$Operations,
        [ValidateSet('AzureActiveDirectory','ExchangeAdmin','ExchangeItem','SharePoint','OneDrive','MicrosoftTeams','SecurityComplianceCenter','DataCenterSecurityCmdlet','PowerBIDefault','CRM','Sway','Yammer')]
        [string]$RecordType,
        [string[]]$UserIds,   # actor filter (server-side)
        [int]$ResultSize,     # page size control (e.g., 5000)

        # ----- Time window (nullable; defaults computed inside) -----
        [datetime]$StartDate,        # UTC preferred by UAL
        [datetime]$EndDate,          # UTC preferred by UAL
        [datetime]$StartDateLocalTz, # if provided, do NOT also pass StartDate
        [datetime]$EndDateLocalTz,   # if provided, do NOT also pass EndDate

        # ----- Local time output settings -----
        [string]$LocalTimeZoneId = ([System.TimeZoneInfo]::Local.Id),
        [string]$LocalTimeAbbrev,  # optional override (e.g., 'CST')

        # ----- Optional client-side actor contains -----
        [string]$ActorLike,

        # ----- Mailbox admin coverage knobs (used when -Mailbox AND no -Operations) -----
        [ValidateSet('Lean','Broad','All')]
        [string]$AdminOpsMode = 'Lean',
        [string[]]$ExtraOperations,

        # ----- Strategy: multi-pass (fast) vs single call (broad) when multiple RecordTypes inferred -----
        [ValidateSet('InferMultiPass','AllTypesSingleCall')]
        [string]$RecordTypeStrategy = 'InferMultiPass',

        # ----- Behavior -----
        [switch]$ExpandIfEmpty,
        [switch]$ReturnRaw
    )

    # ---------- helpers ----------
    function _Get-ActorUPN { param([object]$j)
        try { if ($j.UserId) { return $j.UserId } } catch { Write-Verbose "Error in _Get-ActorUPN(UserId): $($_.Exception.Message)" }
        try {
            if ($j.InitiatedBy -and $j.InitiatedBy.User -and $j.InitiatedBy.User.UserPrincipalName) {
                return $j.InitiatedBy.User.UserPrincipalName
            }
        } catch { Write-Verbose "Error in _Get-ActorUPN(InitiatedBy): $($_.Exception.Message)" }
        try { if ($j.Actor) { return $j.Actor } } catch { Write-Verbose "Error in _Get-ActorUPN(Actor): $($_.Exception.Message)" }
        try { if ($j.ActorUPN) { return $j.ActorUPN } } catch { Write-Verbose "Error in _Get-ActorUPN(ActorUPN): $($_.Exception.Message)" }
        try { if ($j.LoggedOnUser) { return $j.LoggedOnUser } } catch { Write-Verbose "Error in _Get-ActorUPN(LoggedOnUser): $($_.Exception.Message)" }
        return $null
    }

    function _Collect-TargetStrings { param([object]$j)
        $bag = New-Object 'System.Collections.Generic.List[string]'
        try {
            if ($j.ObjectId) { [void]$bag.Add([string]$j.ObjectId) }
            if ($j.ModifiedProperties) {
                foreach ($mp in $j.ModifiedProperties) {
                    if ($mp.Name)     { [void]$bag.Add([string]$mp.Name) }
                    if ($mp.NewValue) { [void]$bag.Add([string]$mp.NewValue) }
                    if ($mp.OldValue) { [void]$bag.Add([string]$mp.OldValue) }
                }
            }
            if ($j.Parameters) {
                foreach ($pa in $j.Parameters) {
                    if ($pa.Name)  { [void]$bag.Add([string]$pa.Name) }
                    if ($pa.Value) { [void]$bag.Add([string]$pa.Value) }
                }
            }
        } catch { Write-Verbose "Error in _Collect-TargetStrings(core): $($_.Exception.Message)" }
        try {
            if ($j.TargetResources) {
                foreach ($tr in $j.TargetResources) {
                    if ($tr.Id)                { [void]$bag.Add([string]$tr.Id) }
                    if ($tr.DisplayName)       { [void]$bag.Add([string]$tr.DisplayName) }
                    if ($tr.UserPrincipalName) { [void]$bag.Add([string]$tr.UserPrincipalName) }
                    if ($tr.Type)              { [void]$bag.Add([string]$tr.Type) }
                    if ($tr.ModifiedProperties) {
                        foreach ($mp in $tr.ModifiedProperties) {
                            if ($mp.DisplayName) { [void]$bag.Add([string]$mp.DisplayName) }
                            if ($mp.NewValue)    { [void]$bag.Add([string]$mp.NewValue) }
                            if ($mp.OldValue)    { [void]$bag.Add([string]$mp.OldValue) }
                        }
                    }
                }
            }
        } catch { Write-Verbose "Error in _Collect-TargetStrings(TargetResources): $($_.Exception.Message)" }
        try {
            if ($j.MailboxOwnerUPN) { [void]$bag.Add([string]$j.MailboxOwnerUPN) }
            if ($j.Folder -and $j.Folder.Path) { [void]$bag.Add([string]$j.Folder.Path) }
            if ($j.AffectedItems) {
                foreach ($ai in $j.AffectedItems) {
                    if ($ai.Subject) { [void]$bag.Add([string]$ai.Subject) }
                    if ($ai.Id)      { [void]$bag.Add([string]$ai.Id) }
                }
            }
        } catch { Write-Verbose "Error in _Collect-TargetStrings(ExchangeItem): $($_.Exception.Message)" }
        return $bag | Where-Object { $_ -and $_.Trim() }
    }

    function _Resolve-DLNeedles { param([string]$Identity)
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        if ($Identity) { [void]$set.Add(([string]$Identity).ToLower()) }
        try {
            $r = Get-DistributionGroup -Identity $Identity -ErrorAction Stop
            foreach ($p in @($r.DisplayName,$r.Name,$r.Alias,$r.PrimarySmtpAddress,$r.LegacyExchangeDN)) {
                if ($p) { [void]$set.Add(([string]$p).ToLower()) }
            }
        } catch { Write-Verbose "Error in _Resolve-DLNeedles(Get-DistributionGroup): $($_.Exception.Message)" }
        return $set
    }

    function _Resolve-MailboxNeedles { param([string]$Identity)
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        if ($Identity) { [void]$set.Add(([string]$Identity).ToLower()) }
        try {
            $mbx = Get-Mailbox -Identity $Identity -ErrorAction Stop
            foreach ($p in @(
                $mbx.PrimarySmtpAddress,$mbx.UserPrincipalName,$mbx.Alias,$mbx.LegacyExchangeDN,
                $mbx.ExternalDirectoryObjectId,$mbx.DisplayName,$mbx.Name
            )) {
                if ($p) { [void]$set.Add(([string]$p).ToLower()) }
            }
        } catch { Write-Verbose "Error in _Resolve-MailboxNeedles(Get-Mailbox): $($_.Exception.Message)" }
        return $set
    }

    function _ToUtc([datetime]$local, [string]$tzId) {
        try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzId); (New-Object System.DateTimeOffset($local, $tz.GetUtcOffset($local))).UtcDateTime }
        catch { Write-Verbose "Error in _ToUtc: $($_.Exception.Message)"; $local.ToUniversalTime() }
    }
    function _LocalFromUtc([datetime]$utc, [string]$tzId) {
        try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzId); [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz) }
        catch { Write-Verbose "Error in _LocalFromUtc: $($_.Exception.Message)"; $utc }
    }
    function _GetTzAbbrev { param([datetime]$utcSample, [string]$tzId, [string]$override)
        if ($override) { return $override }
        try {
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($tzId)
            $localSample = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcSample, $tz)
            $isDst = $tz.IsDaylightSavingTime($localSample)
            switch ($tz.Id) {
                'Pacific Standard Time'  { if ($isDst) { return 'PDT' } else { return 'PST' } }
                'Mountain Standard Time' { if ($isDst) { return 'MDT' } else { return 'MST' } }
                'Central Standard Time'  { if ($isDst) { return 'CDT' } else { return 'CST' } }
                'Eastern Standard Time'  { if ($isDst) { return 'EDT' } else { return 'EST' } }
                default {
                    $name = $tz.StandardName
                    if ($isDst -and $tz.DaylightName) { $name = $tz.DaylightName }
                    (($name -split '\s+') | ForEach-Object { $_.Substring(0,1) }) -join ''
                }
            }
        } catch { Write-Verbose "Error in _GetTzAbbrev: $($_.Exception.Message)"; 'LT' }
    }

    # ---------- op catalogs ----------
    $OpsMap = @{
        ExchangeAdmin = @(
            'New-DistributionGroup','Set-DistributionGroup','Add-DistributionGroupMember','Remove-DistributionGroupMember','Update-DistributionGroupMember',
            'Set-Mailbox','Add-MailboxPermission','Remove-MailboxPermission','Add-RecipientPermission','Remove-RecipientPermission',
            'Add-ADPermission','Remove-ADPermission','New-Mailbox','Enable-Mailbox','Disable-Mailbox','Set-User',
            'Set-TransportRule','Set-TransportConfig','Add-MailboxFolderPermission','Set-MailboxFolderPermission','Remove-MailboxFolderPermission',
            'Set-CASMailbox','Set-MailboxAutoReplyConfiguration','Set-MailboxCalendarConfiguration','Set-MailboxRegionalConfiguration'
        )
        ExchangeItem  = @('MoveToDeletedItems','SoftDelete','HardDelete','RecordDelete','UpdateInboxRules','SendOnBehalf')
        AzureActiveDirectory = @('Add member to group.','Update group.','Update user.','Add owner to group.')
    }

    $DefaultMailboxItemOps = @('MoveToDeletedItems','SoftDelete','HardDelete','RecordDelete')
    $ImplicitMailboxAdminOpsLean = @('Set-Mailbox','Add-MailboxPermission','Remove-MailboxPermission','Add-RecipientPermission','Remove-RecipientPermission')
    $ImplicitMailboxAdminOpsBroad = @(
        'Set-Mailbox','Set-CASMailbox','Set-MailboxAutoReplyConfiguration','Set-MailboxCalendarConfiguration','Set-MailboxRegionalConfiguration',
        'Add-MailboxPermission','Remove-MailboxPermission','Add-RecipientPermission','Remove-RecipientPermission',
        'Add-ADPermission','Remove-ADPermission','Add-MailboxFolderPermission','Set-MailboxFolderPermission','Remove-MailboxFolderPermission',
        'Enable-Mailbox','Disable-Mailbox','Set-User'
    )

    function _OpsFor($rt, $ops) {
        if (-not $ops) { return $null }
        $known = $OpsMap[$rt]
        if (-not $known) { return $ops }
        $subset = @()
        foreach ($o in $ops) { if ($known -contains $o) { $subset += $o } }
        if ($subset.Count -gt 0) { return $subset } else { return @() }
    }

    # ---------- validation ----------
    if ($StartDate -and $StartDateLocalTz) { throw "Specify either StartDate (UTC) or StartDateLocalTz (local), not both." }
    if ($EndDate   -and $EndDateLocalTz)   { throw "Specify either EndDate (UTC) or EndDateLocalTz (local), not both." }

    # Compute defaults if not supplied  (DEFAULT: now - 1 day)
    if (-not $StartDate -and -not $StartDateLocalTz) { $StartDate = [datetime]::UtcNow.AddDays(-1) }
    if (-not $EndDate   -and -not $EndDateLocalTz)   { $EndDate   = [datetime]::UtcNow }

    # Normalize to UTC
    if ($StartDateLocalTz) { $StartDate = _ToUtc $StartDateLocalTz $LocalTimeZoneId }
    if ($EndDateLocalTz)   { $EndDate   = _ToUtc $EndDateLocalTz   $LocalTimeZoneId }

    if ($StartDate -gt $EndDate) { throw "StartDate ($StartDate) must be earlier than or equal to EndDate ($EndDate)." }

    # ---------- infer candidates + needles ----------
    $NeedleSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $candidates = New-Object 'System.Collections.Generic.HashSet[string]'

    if ($PSCmdlet.ParameterSetName -eq 'DL' -and $DistributionGroup) {
        $dlSet = _Resolve-DLNeedles -Identity $DistributionGroup
        foreach ($n in $dlSet) { [void]$NeedleSet.Add($n) }
        [void]$candidates.Add('ExchangeAdmin')
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'AADGroup' -and $GroupId) {
        [void]$NeedleSet.Add(([string]$GroupId).ToLower())
        [void]$candidates.Add('AzureActiveDirectory')
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Mailbox' -and $Mailbox) {
        $mbxSet = _Resolve-MailboxNeedles -Identity $Mailbox
        foreach ($n in $mbxSet) { [void]$NeedleSet.Add($n) }
        if ($SubjectLike) { [void]$NeedleSet.Add(([string]$SubjectLike).ToLower()) }
        [void]$candidates.Add('ExchangeItem')
        if (-not $Operations -and -not $RecordType) { [void]$candidates.Add('ExchangeAdmin') }
    }

    if ($Operations) {
        foreach ($o in $Operations) {
            if ($OpsMap.ExchangeAdmin -contains $o) { [void]$candidates.Add('ExchangeAdmin') }
            elseif ($OpsMap.ExchangeItem -contains $o) { [void]$candidates.Add('ExchangeItem') }
            elseif ($OpsMap.AzureActiveDirectory -contains $o) { [void]$candidates.Add('AzureActiveDirectory') }
        }
    }

    if ($RecordType) {
        $candidates.Clear(); [void]$candidates.Add($RecordType)
    }
    if ($candidates.Count -eq 0) {
        [void]$candidates.Add('')  # empty => no RecordType filter (service returns all)
    }

    function _OpsForMailboxAdminDefault([string]$mode) {
        if ($mode -eq 'All') { return $null }    # no filter
        elseif ($mode -eq 'Broad') { return $ImplicitMailboxAdminOpsBroad }
        else { return $ImplicitMailboxAdminOpsLean }
    }

    # ---------- single Search-UnifiedAuditLog runner ----------
    function _RunPass {
        param(
            [datetime]$S, [datetime]$E,
            [string]$RT,
            [string[]]$OpsForThisPass
        )

        $sessionId = [guid]::NewGuid().Guid
        $baseParams = @{
            StartDate      = $S
            EndDate        = $E
            SessionId      = $sessionId
            SessionCommand = 'ReturnLargeSet'
        }
        if ($RT) { $baseParams['RecordType'] = $RT }
        if ($OpsForThisPass -and $OpsForThisPass.Count -gt 0) { $baseParams['Operations'] = $OpsForThisPass }
        if ($UserIds) { $baseParams['UserIds'] = $UserIds }
        if ($ResultSize) { $baseParams['ResultSize'] = $ResultSize }

        $raw = $null
        try { $raw = Search-UnifiedAuditLog @baseParams } catch { Write-Verbose "Error calling Search-UnifiedAuditLog: $($_.Exception.Message)"; return @() }
        if (-not $raw) { return @() }

        $out = @()
        foreach ($rec in $raw) {
            $j = $null
            try { $j = $rec.AuditData | ConvertFrom-Json -ErrorAction Stop } catch { Write-Verbose "Error parsing AuditData JSON: $($_.Exception.Message)"; continue }

            # Optional client-side actor filter
            if ($ActorLike) {
                $actorUpn = _Get-ActorUPN -j $j
                if (-not ($actorUpn -and ($actorUpn -like ("*" + $ActorLike + "*")))) { continue }
            }

            # Object match (needles)
            $matched = $true
            if ($NeedleSet.Count -gt 0) {
                $matched = $false
                $hayRaw = $null
                try { $hayRaw = _Collect-TargetStrings -j $j } catch { Write-Verbose "Error collecting target strings: $($_.Exception.Message)"; $hayRaw = @() }
                if ($hayRaw -and $hayRaw.Count -gt 0) {
                    $hay = @()
                    foreach ($h in $hayRaw) { if ($h) { $hay += $h.ToLower() } }
                    foreach ($n in $NeedleSet) {
                        foreach ($h in $hay) {
                            if ($h -and $h.Contains($n)) { $matched = $true; break }
                        }
                        if ($matched) { break }
                    }
                }
            }
            if (-not $matched) { continue }

            if ($ReturnRaw) { $out += $rec; continue }

            # Object label
            $objLabel = $null
            try {
                if ($j.ModifiedProperties) {
                    $objLabel = ($j.ModifiedProperties | Where-Object { $_.Name -eq 'Identity' } | Select-Object -ExpandProperty NewValue -ErrorAction Ignore)
                }
                if (-not $objLabel -and $j.TargetResources) {
                    $objLabel = $j.TargetResources[0].DisplayName
                    if (-not $objLabel -and $j.TargetResources[0].UserPrincipalName) { $objLabel = $j.TargetResources[0].UserPrincipalName }
                    if (-not $objLabel -and $j.TargetResources[0].Id) { $objLabel = $j.TargetResources[0].Id }
                }
                if (-not $objLabel -and $j.ObjectId) { $objLabel = $j.ObjectId }
                if (-not $objLabel -and $j.MailboxOwnerUPN) { $objLabel = $j.MailboxOwnerUPN }
            } catch { Write-Verbose "Error deriving Object label: $($_.Exception.Message)" }

            # Local time bits (stable columns)
            $tzAbbrev    = _GetTzAbbrev -utcSample $rec.CreationDate -tzId $LocalTimeZoneId -override $LocalTimeAbbrev
            $localDt     = _LocalFromUtc -utc $rec.CreationDate -tzId $LocalTimeZoneId
            $tzDecorated = ("{0} ({1})" -f $LocalTimeZoneId, $tzAbbrev)

            # Build row (stable schema)
            $row = [PSCustomObject]@{
                LocalTimeZoneId = $tzDecorated
                WhenLocal       = $localDt
                WhenUtc         = $rec.CreationDate
                Workload        = $rec.Workload
                RecordType      = $rec.RecordType
                Operation       = $rec.Operations
                Actor           = (_Get-ActorUPN -j $j)
                Object          = $objLabel
                Subjects        = $null
                ClientIP        = $null
            }

            # Subjects (ExchangeItem)
            try {
                if ($j.AffectedItems) {
                    $row.Subjects = ($j.AffectedItems | ForEach-Object { $_.Subject } | Where-Object { $_ }) -join ' | '
                }
            } catch { Write-Verbose "Error extracting Subjects: $($_.Exception.Message)" }

            # Client IP
            try {
                if ($j.ClientIP) { $row.ClientIP = $j.ClientIP }
                elseif ($j.IPAddress) { $row.ClientIP = $j.IPAddress }
            } catch { Write-Verbose "Error extracting ClientIP: $($_.Exception.Message)" }

            # Member (DL ops)
            try {
                if ($j.Parameters) {
                    $member = ($j.Parameters | Where-Object { $_.Name -eq 'Member' } | Select-Object -ExpandProperty Value -ErrorAction Ignore)
                    if ($member) { Add-Member -InputObject $row -NotePropertyName Member -NotePropertyValue $member }
                }
            } catch { Write-Verbose "Error extracting Member: $($_.Exception.Message)" }

            # Modified (old -> new) for admin/config ops
            try {
                if ($j.ModifiedProperties) {
                    $mods = $j.ModifiedProperties | ForEach-Object { "$($_.Name): $($_.OldValue) -> $($_.NewValue)" }
                    if ($mods) { Add-Member -InputObject $row -NotePropertyName Modified -NotePropertyValue ($mods -join '; ') }
                }
            } catch { Write-Verbose "Error extracting ModifiedProperties: $($_.Exception.Message)" }

            $out += $row
        }

        if ($out) { return ($out | Sort-Object WhenUtc) } else { return @() }
    }

    # ---------- decide passes ----------
    function _OpsForMailboxAdminDefault([string]$mode) {
        if ($mode -eq 'All') { return $null }    # no filter
        elseif ($mode -eq 'Broad') { return $ImplicitMailboxAdminOpsBroad }
        else { return $ImplicitMailboxAdminOpsLean }
    }

    $passes = @()

    if ($RecordTypeStrategy -eq 'AllTypesSingleCall') {
        # Single call, no RecordType filter; choose ops union smartly
        $opsUnion = $null
        if ($Operations) {
            $opsUnion = $Operations
        } elseif ($PSCmdlet.ParameterSetName -eq 'Mailbox' -and $Mailbox) {
            $adminOps = _OpsForMailboxAdminDefault $AdminOpsMode
            if ($AdminOpsMode -ne 'All' -and $ExtraOperations) {
                $adminOps = @($adminOps + $ExtraOperations) | Select-Object -Unique
            }
            if ($AdminOpsMode -eq 'All') {
                # Items filtered; admins wide open (null means no filter)
                $opsUnion = $DefaultMailboxItemOps
            } else {
                $opsUnion = @($DefaultMailboxItemOps + $adminOps) | Select-Object -Unique
            }
        } else {
            $opsUnion = $null  # no op filter
        }
        $passes += ([pscustomobject]@{ RT = ''; Ops = $opsUnion })
    }
    else {
        # Infer multi-pass (default, better perf)
        if ($candidates.Count -gt 0) {
            foreach ($rt in $candidates) {
                $opsSubset = _OpsFor $rt $Operations

                if (-not $Operations -and $PSCmdlet.ParameterSetName -eq 'Mailbox' -and $Mailbox) {
                    if ($rt -eq 'ExchangeItem') {
                        $opsSubset = $DefaultMailboxItemOps
                    }
                    elseif ($rt -eq 'ExchangeAdmin') {
                        $opsSubset = _OpsForMailboxAdminDefault $AdminOpsMode
                        if ($AdminOpsMode -ne 'All' -and $ExtraOperations) {
                            $opsSubset = @($opsSubset + $ExtraOperations) | Select-Object -Unique
                        }
                    }
                } elseif ($Operations -and $rt -eq 'ExchangeAdmin' -and $ExtraOperations) {
                    $opsSubset = @($opsSubset + $ExtraOperations) | Select-Object -Unique
                }

                if ($Operations -and $rt -and ($opsSubset -is [array]) -and $opsSubset.Count -eq 0) { continue } # skip mismatched RT
                $passes += ([pscustomobject]@{ RT = $rt; Ops = $opsSubset })
            }
        } else {
            # No candidates inferred (fallback)
            $passes += ([pscustomobject]@{ RT = ''; Ops = $null })
        }
    }

    # ---------- run passes (initial) ----------
    $all = @()
    foreach ($p in $passes) {
        $res = _RunPass -S $StartDate -E $EndDate -RT $p.RT -OpsForThisPass $p.Ops
        if ($res) { $all += $res }
    }

    # ---------- optional retry with expanded window ----------
    if (-not $all -and $ExpandIfEmpty) {
        $retryStart = $StartDate.AddDays(-3)
        foreach ($p in $passes) {
            $res = _RunPass -S $retryStart -E $EndDate -RT $p.RT -OpsForThisPass $p.Ops
            if ($res) { $all += $res }
        }
    }

    $all | Sort-Object WhenUtc
}
