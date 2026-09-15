<#
.SYNOPSIS
Proves, offline, that Get-ExoQueue's paging retrieves a known corpus EXACTLY - no losses, no
duplicates, correctly ordered.

.DESCRIPTION
The paging loop is the part of Get-ExoQueue a tenant cannot usefully test. A lab queue is too
shallow to page at all, and a production queue has no known answer to check against, so a run that
silently drops half the queue looks exactly like a run that did not. This substitutes a simulated
Get-MessageTraceV2 whose contents ARE known, and checks the retrieved set against them.

The simulator models Microsoft's documented contract:

    "Pagination isn't supported in this cmdlet. To query subsequent data, use the
     StartingRecipientAddress and EndDate parameters with the values from the Recipient address
     and Received Time properties respectively of the previous result in the next query."

For EndDate paging to walk backwards the service must return NEWEST first, so the last row of a page
is the oldest, and StartingRecipientAddress disambiguates rows sharing the boundary timestamp. That
resume rule has two plausible readings - the cursor row is returned again, or it is not - and the
documentation does not say which. Both are exercised, because the script has to be correct under
either and the tenant, not the script, decides.

Also measures the ResultSize cap probe: which server-side caps are detected, which fall into the
documented blind spot below ExoQueueCapProbeThreshold, and whether a quiet queue still costs the
single query it should.

READ-ONLY with respect to Exchange Online: nothing connects, and Get-MessageTraceV2,
Get-ConnectionInformation and Connect-ExchangeOnline are all stubs. Output files are written under
$env:TEMP, never to the real results folder.

.EXAMPLE
.\Test-ExoQueuePagingFidelity.ps1

Runs every scenario and prints a line per case; green is a pass, red means the retrieved set did not
match the corpus.

.NOTES
Written 2026-09-14 for Get-ExoQueue 1.5.2, as the evidence for lowering ExoQueueCapProbeThreshold
from 1000 to 100. At 1000 the "cap 250" and "cap 500" cases below failed, returning one short page
and reporting it as a complete queue.
#>

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$out  = Join-Path $env:TEMP ('exoq-paging-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -Path $out -ItemType Directory -Force | Out-Null

$global:Corpus     = @()
$global:Resume     = 'Inclusive'
$global:ServiceCap = 0
$global:CallCount  = 0

function global:Get-MessageTraceV2 {
    [CmdletBinding()]
    param(
        [datetime]$StartDate, [datetime]$EndDate, [object]$Status, [int]$ResultSize,
        [string]$StartingRecipientAddress, [object]$RecipientAddress, [object]$SenderAddress
    )
    $global:CallCount++

    # The service reads StartDate/EndDate in LOCAL time and returns Received in UTC - measured in
    # a live lab tenant and the reason -TimeBasis defaults to Local since 1.5.3. The corpus is
    # held in UTC, so the incoming window has to be translated the same way the service translates
    # it. Without this the stub compared a UTC row against a local clock face and silently dropped
    # every message inside the machine's UTC offset - which read as catastrophic paging loss.
    $startUtc = if ($StartDate.Kind -eq [System.DateTimeKind]::Utc) { $StartDate } else { [datetime]::SpecifyKind($StartDate, [System.DateTimeKind]::Local).ToUniversalTime() }
    $endUtc   = if ($EndDate.Kind   -eq [System.DateTimeKind]::Utc) { $EndDate }   else { [datetime]::SpecifyKind($EndDate,   [System.DateTimeKind]::Local).ToUniversalTime() }

    $rows = $global:Corpus | Where-Object { $_.Received -le $endUtc -and $_.Received -ge $startUtc }
    # Newest first; ties broken by recipient address so the cursor is deterministic.
    $rows = @($rows | Sort-Object -Property @{ Expression = 'Received'; Descending = $true },
                                            @{ Expression = 'RecipientAddress'; Descending = $false })

    if (-not [string]::IsNullOrWhiteSpace($StartingRecipientAddress)) {
        $rows = @($rows | Where-Object {
            if ($_.Received -ne $endUtc) { return $true }
            if ($global:Resume -eq 'Inclusive') { return ([string]::CompareOrdinal($_.RecipientAddress, $StartingRecipientAddress) -ge 0) }
            return ([string]::CompareOrdinal($_.RecipientAddress, $StartingRecipientAddress) -gt 0)
        })
    }

    $limit = if ($global:ServiceCap -gt 0) { [Math]::Min($ResultSize, $global:ServiceCap) } else { $ResultSize }
    return @($rows | Select-Object -First $limit)
}

function global:Get-ConnectionInformation { [pscustomobject]@{ State = 'Connected'; Organization = 'probe.onmicrosoft.com' } }
function global:Connect-ExchangeOnline { throw 'Probe must never connect.' }
function global:Out-GridView { param([Parameter(ValueFromPipeline = $true)][object]$InputObject, [string]$Title) process { } }

$fake = New-Module -Name ExchangeOnlineManagement -ScriptBlock { function Get-ExoQueueProbeMarker { $true } }
$fake | Import-Module

. (Join-Path $root 'Get-ExoQueue.ps1')

function New-Corpus {
    param([int]$MessageCount, [int]$RecipientsPerMessage = 1, [int]$DistinctTimestamps = 0)
    $now = [datetime]::UtcNow
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($m = 1; $m -le $MessageCount; $m++) {
        # 100 ms apart, not 1 s: at one second per message a 3500-message corpus spans 58 minutes
        # and half of it falls outside the 30-minute query window, which reads as data loss when it
        # is the window working correctly. Spacing is irrelevant to the cursor logic under test.
        $slot = if ($DistinctTimestamps -gt 0) { $m % $DistinctTimestamps } else { $m }
        $received = [datetime]::SpecifyKind($now.AddMilliseconds(-60000 - ($slot * 100)), [System.DateTimeKind]::Utc)
        for ($r = 1; $r -le $RecipientsPerMessage; $r++) {
            $rows.Add([pscustomobject]@{
                MessageId        = ('<m{0:D6}@contoso.com>' -f $m)
                Received         = $received
                SenderAddress    = ('s{0}@contoso.com' -f ($m % 7))
                RecipientAddress = ('r{0:D6}-{1:D3}@contoso.com' -f $m, $r)
                Status           = 'Pending'
                Subject          = ('probe {0}' -f $m)
                Size             = 1024
            })
        }
    }
    @($rows)
}

function Test-Scenario {
    param(
        [string]$Label, [int]$MessageCount, [int]$RecipientsPerMessage = 1,
        [int]$DistinctTimestamps = 0, [int]$ResultSize = 10, [int]$ServiceCap = 0,
        [string]$Resume = 'Inclusive', [int]$MaxQueryPages = 200
    )

    $global:Corpus     = New-Corpus -MessageCount $MessageCount -RecipientsPerMessage $RecipientsPerMessage -DistinctTimestamps $DistinctTimestamps
    $global:Resume     = $Resume
    $global:ServiceCap = $ServiceCap
    $global:CallCount  = 0

    $dir = Join-Path $out ($Label -replace '[^\w]', '_')
    $r = Get-ExoQueue -AgeMinutes 30 -ResultSize $ResultSize -MaxQueryPages $MaxQueryPages `
        -Output None -Force -Quiet -PassThru -OutputPath $dir -ThrottleDelayMilliseconds 0 3>$null

    $expectedMessages = $MessageCount
    $expectedRows     = $MessageCount * $RecipientsPerMessage
    $gotMessages      = $r.MessageCount
    $gotRows          = $r.RecipientRowCount

    $expectedIds = [System.Collections.Generic.HashSet[string]]::new()
    $global:Corpus | ForEach-Object { [void]$expectedIds.Add($_.MessageId) }
    $gotIds = [System.Collections.Generic.HashSet[string]]::new()
    $r.Messages | ForEach-Object { [void]$gotIds.Add([string]$_.MessageId) }
    $missing = @($expectedIds | Where-Object { -not $gotIds.Contains($_) })

    # Ordering must be oldest-first across the dated messages.
    $dated = @($r.Messages | Where-Object { $null -ne $_.ReceivedUtc })
    $ordered = $true
    for ($i = 1; $i -lt $dated.Count; $i++) {
        if ($dated[$i].ReceivedUtc -lt $dated[$i - 1].ReceivedUtc) { $ordered = $false; break }
    }

    $ok = ($gotMessages -eq $expectedMessages) -and ($gotRows -eq $expectedRows) -and ($missing.Count -eq 0) -and $ordered
    $colour = if ($ok) { 'Green' } else { 'Red' }

    Write-Host ("  {0,-46} msgs {1,6}/{2,-6} rows {3,6}/{4,-6} pages {5,3} calls {6,3} dup {7,4} trunc {8,-6} {9} ordered={10}" -f `
        $Label, $gotMessages, $expectedMessages, $gotRows, $expectedRows, $r.PagesQueried, $global:CallCount,
        $r.DuplicateRows, $r.Truncated, $(if ($r.TruncationReason) { "($($r.TruncationReason))" } else { '' }), $ordered) -ForegroundColor $colour

    if ($missing.Count -gt 0) {
        Write-Host ("      MISSING {0} message(s), e.g. {1}" -f $missing.Count, (($missing | Select-Object -First 3) -join ', ')) -ForegroundColor Red
    }
    if ($r.ResultSizeCapped) { Write-Host "      ResultSizeCapped=True EffectivePageSize=$($r.EffectivePageSize)" -ForegroundColor Yellow }
}

Write-Host ''
Write-Host '=== Resume semantics: INCLUSIVE (cursor row returned again) ===' -ForegroundColor Cyan
Test-Scenario -Label 'single-recipient, distinct times, 3 pages'   -MessageCount 25  -ResultSize 10
Test-Scenario -Label 'single-recipient, exact page multiple'       -MessageCount 30  -ResultSize 10
Test-Scenario -Label 'multi-recipient (5 each)'                    -MessageCount 20  -RecipientsPerMessage 5 -ResultSize 10
Test-Scenario -Label 'burst: 40 msgs over 3 timestamps'            -MessageCount 40  -DistinctTimestamps 3  -ResultSize 10
Test-Scenario -Label 'burst: 50 msgs ALL on one timestamp'         -MessageCount 50  -DistinctTimestamps 1  -ResultSize 10

Write-Host ''
Write-Host '=== Resume semantics: EXCLUSIVE (cursor row not returned again) ===' -ForegroundColor Cyan
Test-Scenario -Label 'single-recipient, distinct times, 3 pages'   -MessageCount 25  -ResultSize 10 -Resume Exclusive
Test-Scenario -Label 'multi-recipient (5 each)'                    -MessageCount 20  -RecipientsPerMessage 5 -ResultSize 10 -Resume Exclusive
Test-Scenario -Label 'burst: 40 msgs over 3 timestamps'            -MessageCount 40  -DistinctTimestamps 3  -ResultSize 10 -Resume Exclusive
Test-Scenario -Label 'burst: 50 msgs ALL on one timestamp'         -MessageCount 50  -DistinctTimestamps 1  -ResultSize 10 -Resume Exclusive

Write-Host ''
Write-Host '=== ResultSize caps: does the probe catch them? ===' -ForegroundColor Cyan
Write-Host '    (documented service default is 1000; a restricted role could plausibly be lower)' -ForegroundColor DarkGray
Test-Scenario -Label 'cap 1000 of 3500, requested 5000'            -MessageCount 3500 -ResultSize 5000 -ServiceCap 1000
Test-Scenario -Label 'cap  500 of 1700, requested 5000'            -MessageCount 1700 -ResultSize 5000 -ServiceCap 500
Test-Scenario -Label 'cap  250 of  900, requested 5000'            -MessageCount 900  -ResultSize 5000 -ServiceCap 250
Test-Scenario -Label 'cap  100 of  350, requested 5000'            -MessageCount 350  -ResultSize 5000 -ServiceCap 100

Write-Host ''
Write-Host '=== Residual blind spot: a cap below the probe threshold (100) ===' -ForegroundColor Cyan
Write-Host '    Documented in .NOTES. No service is known to cap this low; recorded here so the' -ForegroundColor DarkGray
Write-Host '    limit stays visible rather than being quietly forgotten.' -ForegroundColor DarkGray
Test-Scenario -Label 'cap   10 of   35, requested 5000 (EXPECTED MISS)' -MessageCount 35 -ResultSize 5000 -ServiceCap 10

Write-Host ''
Write-Host '=== Cost check: a quiet queue must still cost ONE query ===' -ForegroundColor Cyan
Test-Scenario -Label 'quiet queue, 12 messages, requested 5000'    -MessageCount 12  -ResultSize 5000

Write-Host ''
Write-Host "Probe output under: $out" -ForegroundColor Yellow
