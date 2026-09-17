<#
.SYNOPSIS
Answers, read-only, the four questions about a tenant that Get-ExoQueue.ps1 currently assumes.

.DESCRIPTION
Get-ExoQueue was built and tested offline against stubs. Four of its behaviours rest on assumptions
about the live service that no offline test can settle, and all four fail QUIETLY - they produce a
plausible number rather than an error. This script settles them with seven queries and writes nothing
anywhere.

    1. Time basis. Get-ExoQueue feeds a received value from one page back in as the next page's
       EndDate. That round-trip only holds if the clock the service READS its parameters in is the
       same clock it WRITES its output in. If they differ by the machine's UTC offset, every page
       after the first silently queries the wrong window. -TimeBasis exists to correct it and
       defaults to Local; this tells you whether that default is right here.

    2. Received property name. The script reads the received time by trying the candidate list in
       $script:ExoQueueReceivedNames - 'Received', 'ReceivedTime', 'Received Time', 'ReceivedUtc'.
       A name outside that list means no timestamp is read at all: every message is reported undated,
       ordering degrades to arrival order, and the run warns instead of failing.

    3. Filter composition. -JournalOnly and -JournalExclude set -RecipientAddress, while paging sets
       -StartingRecipientAddress. If the service drops one when both are present, a journal-filtered
       run silently returns the wrong population from page 2 onward.

    4. ResultSize cap. The documented service default is 1000 and -ResultSize defaults to 5000. A
       role capped at 1000 makes every page look short, which is indistinguishable from an exhausted
       queue without the extra probe query the script now spends. Knowing the answer up front tells
       you whether ResultSizeCapped on a real run is news or expected.

READ-ONLY. Every call is a Get-. Nothing is written: no files, no registry, no exports, no transcript.
It will not connect for you either - if the session is not already connected it stops and says so,
because connecting is a decision, not a side effect. Seven queries against the documented limit of
100 per rolling 5 minutes, paced one second apart.

.PARAMETER LookbackHours
How far back to look for sample messages. Larger windows find data in a quiet tenant; the service
permits at most 10 days. Default 24.

.PARAMETER ShowAddresses
Print real addresses and message IDs instead of stable masked tokens. Off by default so the output
can be pasted into a ticket or a chat window without redacting it by hand. The verdicts do not
depend on it - masking is consistent, so the same address is the same token everywhere.

.EXAMPLE
.\Test-ExoQueueTenantAssumption.ps1

Runs all four probes over the past 24 hours with addresses masked.

.EXAMPLE
.\Test-ExoQueueTenantAssumption.ps1 -LookbackHours 72 -ShowAddresses

Widens the search for sample data in a quiet tenant and prints real addresses.

.OUTPUTS
One [pscustomobject] carrying all four answers, or nothing at all if the probe could not start (no
session, no cmdlet, or no messages in the window). The console output is the readable version; this
is the one to capture, and ActionsNeeded is the field worth reading first.

    ReceivedNameKnown  Q2. False means the received time cannot be read at all.
    TimeBasisResult    Q1. RoundTrips | Shifted | Inconclusive | Skipped
    FilterComposition  Q3. Composes | ExclusiveCursor | NotFiltered | DroppedWhenPaging | Skipped
    PageSizeResult     Q4. Uncapped | CappedAt1000 | ProbablyCapped | Inconclusive
    ActionsNeeded      One string per change to make before trusting a real run; empty is the pass.

.NOTES
Run this BEFORE trusting the first real Get-ExoQueue run, then confirm against the script itself:

    Get-ExoQueue -AgeMinutes 60 -ResultSize 2000 -Quiet -PassThru -WhatIf

That is also read-only: -WhatIf suppresses the output folder and the trend-log append, and the run
still queries and still reports EffectivePageSize, ResultSizeCapped, Truncated and TimeBasis on the
returned object.

Author: written 2026-08-14 alongside Get-ExoQueue.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 240)]
    [int]$LookbackHours = 24,

    [switch]$ShowAddresses
)

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkCyan
}

function Write-Verdict {
    param([string]$Label, [string]$Text, [ValidateSet('Good', 'Bad', 'Unknown')][string]$State)
    $colour = switch ($State) { 'Good' { 'Green' } 'Bad' { 'Red' } default { 'Yellow' } }
    Write-Host ('{0,-16}' -f ($Label + ':')) -NoNewline
    Write-Host $Text -ForegroundColor $colour
}

function Protect-Value {
    param([string]$Value, [bool]$Reveal)

    if ($Reveal -or [string]::IsNullOrWhiteSpace($Value)) { return $Value }

    # Stable, not random: the same address has to mask to the same token or the comparisons below
    # become unreadable. MD5 is a labelling device here, not a security control.
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))
    $md5.Dispose()
    $token = -join ($bytes[0..1] | ForEach-Object { $_.ToString('x2') })

    if ($Value -match '^(.)[^@]*@(.+)$') { return '{0}***@{1}' -f $Matches[1], $token }
    return '***{0}' -f $token
}

function Get-RowValue {
    # Set-StrictMode 3.0 turns a plain $row.PSObject.Properties['X'].Value into a terminating error
    # the moment a row is missing X, which would abort the whole probe over one odd row.
    param($Row, [string]$Name)

    $member = $Row.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    $member.Value
}

function Test-ExoQueueTenantAssumption {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$LookbackHours,
        [bool]$Reveal
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
    }

    process {
        $requests = 0

        Write-Head 'Preflight'

        # Deliberately not Connect-ExchangeOnline. A probe that connects on your behalf has made a
        # decision for you, and this one is supposed to observe rather than change anything.
        $connection = $null
        if (Get-Command -Name 'Get-ConnectionInformation' -ErrorAction SilentlyContinue) {
            $connection = @(Get-ConnectionInformation -ErrorAction SilentlyContinue) |
                Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
        }
        if ($null -eq $connection) {
            Write-Verdict 'Session' 'Not connected. Run Connect-ExchangeOnline yourself, then re-run this.' 'Bad'
            return
        }
        if (-not (Get-Command -Name 'Get-MessageTraceV2' -ErrorAction SilentlyContinue)) {
            Write-Verdict 'Cmdlet' 'Get-MessageTraceV2 is absent. ExchangeOnlineManagement 3.9.x or later is required.' 'Bad'
            return
        }
        Write-Verdict 'Session' ('Connected as {0} to {1}' -f `
            (Protect-Value -Value $connection.UserPrincipalName -Reveal $Reveal), $connection.Organization) 'Good'
        Write-Verdict 'Machine' ('UTC offset {0}' -f [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now)) 'Good'

        # ---------------------------------------------------------------------------------------
        Write-Head ('Sample: the past {0} hours' -f $LookbackHours)

        # The end is padded 14 hours into the future and the start is the full lookback. If the
        # service reads these parameters in a different clock than this machine keeps, the whole
        # window shifts by the offset - the padding is what keeps data inside it either way, since
        # no real offset exceeds 14 hours. That the padding is NEEDED is what probe 1 measures.
        $start = [datetime]::SpecifyKind([datetime]::Now.AddHours(-$LookbackHours), 'Unspecified')
        $end   = [datetime]::SpecifyKind([datetime]::Now.AddHours(14), 'Unspecified')

        $sample = @(Get-MessageTraceV2 -StartDate $start -EndDate $end -ResultSize 50)
        $requests++

        if ($sample.Count -eq 0) {
            Write-Verdict 'Sample' 'No messages in the window. Nothing here can be answered - re-run with a larger -LookbackHours.' 'Unknown'
            return
        }
        Write-Verdict 'Sample' ('{0} rows returned' -f $sample.Count) 'Good'

        # ---------------------------------------------------------------------------------------
        Write-Head 'Question 2: what is the received property actually called?'

        $candidates = @('Received', 'ReceivedTime', 'Received Time', 'ReceivedUtc')
        $row        = $sample[0]
        $names      = @($row.PSObject.Properties | ForEach-Object { $_.Name })

        Write-Host ('Properties returned: {0}' -f ($names -join ', '))

        $dateNames = @()
        foreach ($property in $row.PSObject.Properties) {
            if ($property.Value -is [datetime]) {
                $dateNames += $property.Name
                Write-Host ('  {0,-22} {1:o}  Kind={2}' -f $property.Name, $property.Value, $property.Value.Kind)
            }
        }

        $matched = @($dateNames | Where-Object { $candidates -contains $_ })
        if ($matched.Count -gt 0) {
            Write-Verdict 'Verdict' ('Recognised: {0}. No change needed.' -f ($matched -join ', ')) 'Good'
        }
        elseif ($dateNames.Count -gt 0) {
            Write-Verdict 'Verdict' ("None of {0} is present. Add '{1}' to `$script:ExoQueueReceivedNames in Get-ExoQueue.ps1." -f `
                ($candidates -join ', '), $dateNames[0]) 'Bad'
        }
        else {
            Write-Verdict 'Verdict' 'No DateTime-typed property at all. Read the property list above before running Get-ExoQueue.' 'Bad'
        }

        # ---------------------------------------------------------------------------------------
        Write-Head 'Question 1: does an output timestamp work as an input parameter?'

        # Indexed only after a count check: an out-of-bounds index is a terminating error under
        # StrictMode 3.0, not the $null that 2.0 returned.
        $receivedName = $null
        if ($matched.Count -gt 0)        { $receivedName = $matched[0] }
        elseif ($dateNames.Count -gt 0)  { $receivedName = $dateNames[0] }

        $basisVerdict = 'Inconclusive'
        if ($null -eq $receivedName) {
            $basisVerdict = 'Skipped'
            Write-Verdict 'Verdict' 'Skipped: no timestamp to feed back.' 'Unknown'
        }
        else {
            $anchor   = Get-RowValue -Row $row -Name $receivedName
            $anchorId = [string](Get-RowValue -Row $row -Name 'MessageId')
            $offset   = [System.TimeZoneInfo]::Local.GetUtcOffset([datetime]::Now)

            Write-Host ('Anchor message {0} at {1:o} (Kind={2})' -f `
                (Protect-Value -Value $anchorId -Reveal $Reveal), $anchor, $anchor.Kind)

            # Every probe value is stamped Unspecified so that nothing on this side converts it on
            # the way out. The only difference between the three queries is the number on the clock
            # face, which is exactly the thing being measured.
            $bare = [datetime]::SpecifyKind($anchor, 'Unspecified')
            $probes = [ordered]@{
                'as returned'  = $bare
                'plus offset'  = $bare.Add($offset)
                'minus offset' = $bare.Subtract($offset)
            }
            if ($offset -eq [timespan]::Zero) {
                Write-Verdict 'Note' 'This machine is at UTC+00:00, so a shifted window is identical to an unshifted one. Re-run somewhere with an offset to settle this.' 'Unknown'
                $probes = [ordered]@{ 'as returned' = $bare }
            }

            $hits = @()
            foreach ($label in $probes.Keys) {
                Start-Sleep -Seconds 1
                $probeStart = $probes[$label].AddMinutes(-2)
                $probeEnd   = $probes[$label].AddMinutes(2)
                $found      = @(Get-MessageTraceV2 -StartDate $probeStart -EndDate $probeEnd -ResultSize 50)
                $requests++

                $hit = @($found | Where-Object { [string](Get-RowValue -Row $_ -Name 'MessageId') -eq $anchorId }).Count -gt 0
                if ($hit) { $hits += $label }
                Write-Host ('  {0,-13} {1:HH:mm:ss}..{2:HH:mm:ss}  {3,3} rows  anchor {4}' -f `
                    $label, $probeStart, $probeEnd, $found.Count, $(if ($hit) { 'FOUND' } else { 'absent' }))
            }

            if ($hits -contains 'as returned') {
                $basisVerdict = 'RoundTrips'
                Write-Verdict 'Verdict' 'A returned timestamp can be handed straight back. The paging cursor round-trips; keep -TimeBasis Utc.' 'Good'
            }
            elseif ($hits.Count -gt 0) {
                $basisVerdict = 'Shifted'
                Write-Verdict 'Verdict' ("The window had to be shifted '{0}' to find the anchor. The request clock and the output clock differ by this machine's UTC offset - run Get-ExoQueue with -TimeBasis Local." -f $hits[0]) 'Bad'
            }
            else {
                Write-Verdict 'Verdict' 'The anchor was not found in any of the three windows. Re-run; if it repeats, do not trust paging until it is explained.' 'Unknown'
            }
        }

        # ---------------------------------------------------------------------------------------
        Write-Head 'Question 3: do -RecipientAddress and -StartingRecipientAddress compose?'

        $address = [string](Get-RowValue -Row $row -Name 'RecipientAddress')
        $filterVerdict = 'Skipped'
        if ([string]::IsNullOrWhiteSpace($address)) {
            Write-Verdict 'Verdict' 'Skipped: the sample row carries no RecipientAddress.' 'Unknown'
        }
        else {
            Write-Host ('Filtering on {0}' -f (Protect-Value -Value $address -Reveal $Reveal))

            Start-Sleep -Seconds 1
            $filtered = @(Get-MessageTraceV2 -StartDate $start -EndDate $end -RecipientAddress $address -ResultSize 50)
            $requests++

            Start-Sleep -Seconds 1
            $combined = @(Get-MessageTraceV2 -StartDate $start -EndDate $end -RecipientAddress $address `
                -StartingRecipientAddress $address -ResultSize 50)
            $requests++

            $strayAlone    = @($filtered | Where-Object { [string](Get-RowValue -Row $_ -Name 'RecipientAddress') -ne $address }).Count
            $strayCombined = @($combined | Where-Object { [string](Get-RowValue -Row $_ -Name 'RecipientAddress') -ne $address }).Count

            # Width-padded rather than hand-spaced: the two labels differ in length, and counting the
            # spaces by eye put the row counts in different columns, which is precisely the comparison
            # a reader makes here.
            Write-Host ('  {0,-26}{1,4} rows, {2} for another recipient' -f '-RecipientAddress alone', $filtered.Count, $strayAlone)
            Write-Host ('  {0,-26}{1,4} rows, {2} for another recipient' -f 'both parameters together', $combined.Count, $strayCombined)

            if ($strayAlone -gt 0) {
                $filterVerdict = 'NotFiltered'
                Write-Verdict 'Verdict' '-RecipientAddress did not filter on its own. -JournalOnly and -JournalExclude cannot be trusted here at all.' 'Bad'
            }
            elseif ($strayCombined -gt 0) {
                $filterVerdict = 'DroppedWhenPaging'
                Write-Verdict 'Verdict' '-RecipientAddress is DROPPED when -StartingRecipientAddress is present. A journal-filtered run widens from page 2 onward - use -JournalOnly only on single-page runs until this is handled.' 'Bad'
            }
            elseif ($combined.Count -eq 0 -and $filtered.Count -gt 0) {
                $filterVerdict = 'ExclusiveCursor'
                Write-Verdict 'Verdict' 'They compose, and -StartingRecipientAddress is exclusive of the address given. Paging is sound; expect no duplicate rows at page boundaries.' 'Good'
            }
            else {
                $filterVerdict = 'Composes'
                Write-Verdict 'Verdict' 'They compose. Journal-filtered runs page correctly.' 'Good'
            }
        }

        # ---------------------------------------------------------------------------------------
        Write-Head 'Question 4: is ResultSize capped for this role?'

        Start-Sleep -Seconds 1
        $big = @(Get-MessageTraceV2 -StartDate $start -EndDate $end -ResultSize 2000)
        $requests++
        Write-Host ('Asked for 2000, received {0}' -f $big.Count)

        # A short page is genuinely ambiguous: it means either the window holds that many messages or
        # the role caps the page there. Only 1000 is documented, but a round number is a far better
        # sign of a configured limit than of a coincidence, so it is called out rather than filed
        # under "not enough data" - the cost of missing a cap is reading a truncated queue as an
        # empty one.
        $capVerdict = 'Inconclusive'
        if ($big.Count -eq 2000) {
            $capVerdict = 'Uncapped'
            Write-Verdict 'Verdict' 'Not capped at or below 2000. ResultSizeCapped on a real run would be genuine news.' 'Good'
        }
        elseif ($big.Count -eq 1000) {
            $capVerdict = 'CappedAt1000'
            Write-Verdict 'Verdict' 'Exactly 1000 for a request of 2000 - the documented service default. This role is almost certainly capped: expect ResultSizeCapped=True and EffectivePageSize=1000 on every run, and do not read a short page as an empty queue.' 'Bad'
        }
        elseif (@(100, 250, 500) -contains $big.Count) {
            $capVerdict = 'ProbablyCapped'
            Write-Verdict 'Verdict' ('Exactly {0} for a request of 2000. That is a round number, which is what a configured limit looks like and not what a queue depth usually looks like. Re-run with a different -LookbackHours: an identical count over a different window is a cap, a different count is data.' -f $big.Count) 'Bad'
        }
        else {
            Write-Verdict 'Verdict' ('{0} rows for a request of 2000. Either the window holds only that many messages or this role caps the page there. Re-run with a different -LookbackHours to tell them apart - an identical count over a different window is a cap.' -f $big.Count) 'Unknown'
        }

        # ---------------------------------------------------------------------------------------
        Write-Head 'Summary'

        # The four verdicts are scattered over a screen and a half of output by the time this prints,
        # and the one that matters most is whichever one came out bad. Collected here so the answer
        # to "do I have to change anything before I trust a real run" is one list, not a re-read.
        $nameKnown = $matched.Count -gt 0
        $actions   = [System.Collections.Generic.List[string]]::new()

        if (-not $nameKnown -and $dateNames.Count -gt 0) {
            $actions.Add("Q2: add '{0}' to `$script:ExoQueueReceivedNames in Get-ExoQueue.ps1, or every message reports as undated." -f $dateNames[0])
        }
        elseif (-not $nameKnown) {
            $actions.Add('Q2: no DateTime property was returned at all. The received time cannot be read; ordering and -AgeMinutes are both meaningless until this is explained.')
        }
        if ($basisVerdict -eq 'Shifted') {
            # Compared against the default the script actually carries, not against a literal. The
            # default moved from Utc to Local in 1.5.3 - on the evidence this very check produced -
            # and a hardcoded "the default of Utc" then reported a finding against a build that had
            # already adopted the answer.
            $currentDefault = 'unknown'
            try {
                $scriptPath = Join-Path $PSScriptRoot 'Get-ExoQueue.ps1'
                if (Test-Path $scriptPath) {
                    $m = [regex]::Match((Get-Content $scriptPath -Raw), '\[string\]\$TimeBasis\s*=\s*''(Utc|Local)''')
                    if ($m.Success) { $currentDefault = $m.Groups[1].Value }
                }
            }
            catch {
                # Not fatal: an unreadable script just means the default is unknown, and the branch
                # below then gives the explicit instruction rather than the reassurance. Saying so
                # beats an empty catch that leaves 'unknown' looking like a measurement.
                Write-Verbose "Could not read the -TimeBasis default from Get-ExoQueue.ps1: $($_.Exception.Message)"
            }

            if ($currentDefault -eq 'Local') {
                Write-Verdict 'Q1 action' 'None. This tenant needs -TimeBasis Local and that is already the default in Get-ExoQueue.ps1.' 'Good'
            }
            else {
                $actions.Add("Q1: run Get-ExoQueue with -TimeBasis Local. The default here is '$currentDefault', which queries the wrong window from page 2 onward in this tenant.")
            }
        }
        if ($basisVerdict -eq 'Inconclusive') { $actions.Add('Q1: the time basis was not settled - the anchor was in none of the three windows. Re-run before trusting a multi-page run.') }
        if ($basisVerdict -eq 'Skipped')      { $actions.Add('Q1: not asked, because Q2 found no timestamp to feed back. Settle Q2 and re-run.') }
        if ($filterVerdict -eq 'NotFiltered')       { $actions.Add('Q3: -RecipientAddress does not filter. Do not use -JournalOnly or -JournalExclude at all.') }
        if ($filterVerdict -eq 'DroppedWhenPaging') { $actions.Add('Q3: -RecipientAddress is dropped once paging starts. Use -JournalOnly only on runs that fit in one page.') }
        if ($filterVerdict -eq 'Skipped')           { $actions.Add('Q3: not asked, because the sample row carried no RecipientAddress.') }
        if (@('CappedAt1000', 'ProbablyCapped') -contains $capVerdict) {
            $actions.Add('Q4: expect ResultSizeCapped=True on every run. A short page here is a cap, not an empty queue.')
        }

        if ($actions.Count -eq 0) {
            Write-Verdict 'Actions' "None. Get-ExoQueue's defaults match this tenant." 'Good'
        }
        else {
            Write-Verdict 'Actions' ('{0} to take before trusting a real run:' -f $actions.Count) 'Bad'
            foreach ($action in $actions) { Write-Host ('  - {0}' -f $action) -ForegroundColor Yellow }
        }

        Write-Host ''
        Write-Host ('{0} queries issued, against a documented limit of 100 per rolling 5 minutes.' -f $requests)
        Write-Host 'Nothing was written: no files, no registry, no exports.'
        Write-Host ''
        Write-Host 'Confirm against the script itself, which is also read-only under -WhatIf:' -ForegroundColor Cyan
        Write-Host '    Get-ExoQueue -AgeMinutes 60 -ResultSize 2000 -Quiet -PassThru -WhatIf'

        [pscustomobject]@{
            Connected         = $true
            SampleRows        = $sample.Count
            ReceivedName      = $receivedName
            ReceivedNameKnown = $nameKnown
            TimeBasisResult   = $basisVerdict
            FilterComposition = $filterVerdict
            PageSizeAsked     = 2000
            PageSizeGot       = $big.Count
            PageSizeResult    = $capVerdict
            ActionsNeeded     = $actions.ToArray()
            Requests          = $requests
        }
    }
}

Test-ExoQueueTenantAssumption -LookbackHours $LookbackHours -Reveal ([bool]$ShowAddresses)
