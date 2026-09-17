#Requires -Version 5.1

<#
    Tests for Get-ExoQueue v1.5.2.

    Every Context named "Defect N" is a regression test for a specific fault in v1.4.2. The same
    faults are demonstrated against the old file in Get-ExoQueue.Baseline.Tests.ps1, so each pair
    shows the before and the after.

    Nothing here touches a tenant, the real registry, or C:\temp:
      - Get-MessageTraceV2, Get-ConnectionInformation and Connect-ExchangeOnline are global stubs.
        Get-MessageTraceV2 in particular is generated inside the live REST session and appears
        nowhere in the ExchangeOnlineManagement module tree, so Pester's Mock cannot find it and a
        real global function has to be defined first.
      - -OutputPath is pointed at TestDrive.
      - Connect-ExchangeOnline throws if reached, so a test that accidentally tries to connect
        fails loudly instead of hanging on an MFA prompt.

    Pages are supplied as scriptblocks that receive the StartDate, EndDate and
    StartingRecipientAddress they were actually asked for, and build their rows relative to that
    EndDate. That is what makes the time-basis assertions hold regardless of the running machine's
    UTC offset.

    Run:
      powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 6.0.0; Invoke-Pester -Path C:\dev-scripts\Get-ExoQueue.Tests.ps1 -Output Detailed"
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Get-ExoQueue.ps1'

    function global:Get-MessageTraceV2 {
        [CmdletBinding()]
        param(
            [datetime]$StartDate,
            [datetime]$EndDate,
            [object]$Status,
            [int]$ResultSize,
            [string]$StartingRecipientAddress,
            [object]$RecipientAddress,
            [object]$SenderAddress
        )

        $global:ExoCalls.Add([pscustomobject]@{
            Index                    = $global:ExoCalls.Count
            StartDate                = $StartDate
            EndDate                  = $EndDate
            Status                   = @($Status)
            ResultSize               = $ResultSize
            StartingRecipientAddress = $StartingRecipientAddress
            RecipientAddress         = $RecipientAddress
            SenderAddress            = $SenderAddress
        })

        if ($global:ExoThrow.Count -gt 0) {
            $t = $global:ExoThrow[0]
            $global:ExoThrow.RemoveAt(0)
            if ($t) { throw $t }
        }

        if ($global:ExoPages.Count -eq 0) { return @() }
        $page = $global:ExoPages[0]
        if ($global:ExoPages.Count -gt 1) { $global:ExoPages.RemoveAt(0) }

        if ($page -is [scriptblock]) {
            return @(& $page $StartDate $EndDate $StartingRecipientAddress)
        }
        return @($page)
    }

    function global:Get-ConnectionInformation {
        param([object]$ErrorAction)
        [pscustomobject]@{
            Id                = 1
            State             = 'Connected'
            TokenStatus       = 'Active'
            UserPrincipalName = 'admin@contoso.onmicrosoft.com'
            Organization      = 'contoso.onmicrosoft.com'
        }
    }

    function global:Connect-ExchangeOnline {
        param([object]$ShowProgress, [object]$ErrorAction)
        throw 'Tests must never connect to Exchange Online.'
    }

    # A genuine .NET type, not a pscustomobject. PSObject.Copy() isolates a pscustomobject but does
    # NOT isolate this, which is the whole point: the grouping defect it exposes is invisible against
    # the stub rows and only appears against the typed objects a real Get-MessageTraceV2 returns.
    if (-not ('ExoQueueTestRow' -as [type])) {
        Add-Type -TypeDefinition @'
public class ExoQueueTestRow {
    public string   Organization;
    public string   MessageId;
    public System.DateTime Received;
    public string   SenderAddress;
    public string   RecipientAddress;
    public string   Status;
    public long     Size;
    public string   Subject;
}
'@
    }

    function global:New-Row {
        param(
            [string]$MessageId,
            # Named -From, not -Sender: $Sender is a PowerShell automatic variable used by eventing.
            [string]$From      = 'sender@contoso.com',
            [string]$Recipient = 'rcpt@contoso.com',
            [datetime]$ReceivedUtc,
            [string]$Status    = 'Pending',
            [string]$Subject   = 'probe message',
            [switch]$Unspecified,
            [switch]$NoSubject,
            [switch]$Typed
        )

        $kind = if ($Unspecified) { [System.DateTimeKind]::Unspecified } else { [System.DateTimeKind]::Utc }

        # -Typed has a fixed shape, so it cannot honour -NoSubject. Nothing needs both.
        if ($Typed) {
            $typedRow                  = New-Object ExoQueueTestRow
            $typedRow.Organization     = 'contoso.onmicrosoft.com'
            $typedRow.MessageId        = $MessageId
            $typedRow.Received         = [datetime]::SpecifyKind($ReceivedUtc, $kind)
            $typedRow.SenderAddress    = $From
            $typedRow.RecipientAddress = $Recipient
            $typedRow.Status           = $Status
            $typedRow.Size             = 2048
            $typedRow.Subject          = $Subject
            return $typedRow
        }

        $row = [ordered]@{
            Organization     = 'contoso.onmicrosoft.com'
            MessageId        = $MessageId
            Received         = [datetime]::SpecifyKind($ReceivedUtc, $kind)
            SenderAddress    = $From
            RecipientAddress = $Recipient
            Status           = $Status
            Size             = 2048
        }
        # Omitting Subject entirely, rather than setting it to '', exercises the StrictMode-safe
        # property accessor against a genuinely absent property.
        if (-not $NoSubject) { $row.Subject = $Subject }

        [pscustomobject]$row
    }

    # A page that fills ResultSize exactly, with strictly decreasing Received values anchored to
    # the EndDate the cmdlet was actually handed.
    function global:New-FullPage {
        param([int]$Count, [string]$Tag, [switch]$Unspecified)
        {
            param($StartDate, $EndDate, $StartingRecipientAddress)
            $anchor = $EndDate.ToUniversalTime()
            1..$Count | ForEach-Object {
                New-Row -MessageId "$Tag-$_" `
                    -From    ('s{0}@contoso.com' -f ($_ % 3)) `
                    -Recipient ('r{0}-{1}@contoso.com' -f $Tag, $_) `
                    -ReceivedUtc $anchor.AddSeconds(-$_) `
                    -Unspecified:$Unspecified
            }
        }.GetNewClosure()
    }

    # The service floors EndDate to whole seconds, so since 1.6.4 the paging cursor is rounded up to
    # the next one. Tests that assert the cursor value have to apply the same rule, or they assert a
    # contract the service does not implement.
    function global:ConvertTo-CeilSecond {
        param([datetime]$Utc)
        $rem = $Utc.Ticks % [TimeSpan]::TicksPerSecond
        if ($rem -eq 0) { return $Utc }
        return $Utc.AddTicks([TimeSpan]::TicksPerSecond - $rem)
    }

    . $script:ScriptPath
}

AfterAll {
    # No 'global:' qualifier: the Function provider does not accept one, and
    # "Function:\global:X" silently removes nothing, leaving the stubs shadowing the real cmdlets
    # for the rest of the session.
    'Get-MessageTraceV2', 'Get-ConnectionInformation', 'Connect-ExchangeOnline',
    'New-Row', 'New-FullPage', 'ConvertTo-CeilSecond' |
        ForEach-Object { Remove-Item -Path "Function:$_" -ErrorAction SilentlyContinue }
    Remove-Variable -Name ExoCalls, ExoPages, ExoThrow -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-ExoQueue v1.5.x' {

    BeforeEach {
        $global:ExoCalls = [System.Collections.Generic.List[object]]::new()
        $global:ExoPages = [System.Collections.Generic.List[object]]::new()
        $global:ExoThrow = [System.Collections.Generic.List[object]]::new()

        # The request budget is script-scope on purpose, so two runs in one session share it. That
        # makes it cumulative across the whole suite: left alone, the tests would eventually cross
        # the 90-request threshold and one of them would Start-Sleep for the rest of the 5 minute
        # window. Reset it so each test starts with the whole budget.
        $script:ExoQueueRequestLog.Clear()

        $script:Common = @{
            Force                     = $true
            Quiet                     = $true
            PassThru                  = $true
            Output                    = 'None'
            OutputPath                = "$TestDrive"
            ThrottleDelayMilliseconds = 0
            RetryDelaySeconds         = 0
        }

        # Splatting a hashtable that already contains a key and also passing that parameter
        # explicitly is a binding error, so tests that need files set $script:Common.Output
        # instead. The hashtable is rebuilt above for every test, so the change cannot leak.
    }

    Context 'Paging' {

        It 'issues a single query when the first page is short' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $global:ExoCalls.Count                          | Should -Be 1
            $global:ExoCalls[0].StartingRecipientAddress    | Should -BeNullOrEmpty
            $r.PagesQueried                                 | Should -Be 1
            $r.Truncated                                    | Should -BeFalse
            $r.MessageCount                                 | Should -Be 1
        }

        It 'accumulates across pages and carries the cursor forward' {
            $global:ExoPages.Add((New-FullPage -Count 3 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 3 -Tag 'p2'))
            $global:ExoPages.Add(@(New-Row -MessageId 'last' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-20)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3

            $global:ExoCalls.Count | Should -Be 3
            $r.PagesQueried        | Should -Be 3
            $r.RecipientRowCount   | Should -Be 7
            $r.Truncated           | Should -BeFalse

            # Documented technique: the next query uses the recipient address of the LAST row of
            # the previous page.
            $global:ExoCalls[1].StartingRecipientAddress | Should -Be 'rp1-3@contoso.com'
            $global:ExoCalls[2].StartingRecipientAddress | Should -Be 'rp2-3@contoso.com'
        }

        It 'stops when a page returns only rows it has already seen' {
            # The same page forever. Without a guard this queries until MaxQueryPages.
            $frozen = [datetime]::UtcNow
            $repeat = @(
                New-Row -MessageId 'a' -Recipient 'a@contoso.com' -ReceivedUtc $frozen.AddSeconds(-1)
                New-Row -MessageId 'b' -Recipient 'b@contoso.com' -ReceivedUtc $frozen.AddSeconds(-2)
            )
            1..10 | ForEach-Object { $global:ExoPages.Add($repeat) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 10 -WarningAction SilentlyContinue

            $global:ExoCalls.Count | Should -Be 2
            $r.Truncated           | Should -BeTrue
            $r.TruncationReason    | Should -Be 'NoNewRows'
            $r.RecipientRowCount   | Should -Be 2
        }

        It 'pages through a burst that shares one timestamp' {
            # 5000 messages inside one second is a real shape during an incident, and it is exactly
            # what StartingRecipientAddress exists for: EndDate cannot move, so the recipient
            # address is the only half of the cursor that can. 1.5.0 stopped on the first equal
            # EndDate and retrieved 5 of these 20 rows.
            #
            # Held a few seconds back on purpose. The service floors EndDate to whole seconds, so
            # rows in the CURRENT second are not returned by a query ending "now" at all - putting
            # the burst there would make the cursor round up past the window end and trip the
            # forward-movement guard on a shape the service could never produce.
            $frozen = [datetime]::UtcNow.AddSeconds(-5)
            $burst = {
                param($StartDate, $EndDate, $StartingRecipientAddress)
                $n = $global:ExoCalls.Count
                1..2 | ForEach-Object {
                    New-Row -MessageId "burst-$n-$_" -Recipient "b$n-$_@contoso.com" -ReceivedUtc $frozen
                }
            }
            1..10 | ForEach-Object { $global:ExoPages.Add($burst) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 10 -WarningAction SilentlyContinue

            # It walks the burst to the page limit rather than giving up on page 2.
            $global:ExoCalls.Count | Should -Be 10
            $r.RecipientRowCount   | Should -Be 20
            $r.TruncationReason    | Should -Be 'MaxQueryPages'

            # Every request after the first carries the recipient address of the previous page's
            # last row, which is the only thing making progress here. The stub records its call
            # before it runs the page body, so the first page is tagged 1, not 0.
            $global:ExoCalls[1].StartingRecipientAddress | Should -Be 'b1-2@contoso.com'
            $global:ExoCalls[2].StartingRecipientAddress | Should -Be 'b2-2@contoso.com'
        }

        It 'stops when neither the timestamp nor the recipient address advances' {
            # The genuine stall: the same last row every time, so the next query would be identical
            # to the one just issued. Distinct MessageIds keep the rows "new", so the NoNewRows
            # guard cannot catch this one.
            # Held back from "now" for the same reason as the burst test above.
            $frozen = [datetime]::UtcNow.AddSeconds(-5)
            $stuck = {
                param($StartDate, $EndDate, $StartingRecipientAddress)
                $n = $global:ExoCalls.Count
                New-Row -MessageId "first-$n"  -Recipient 'a@contoso.com' -ReceivedUtc $frozen
                New-Row -MessageId "stuck-$n"  -Recipient 'z@contoso.com' -ReceivedUtc $frozen
            }
            1..10 | ForEach-Object { $global:ExoPages.Add($stuck) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 10 -WarningAction SilentlyContinue

            $r.Truncated           | Should -BeTrue
            $r.TruncationReason    | Should -Be 'CursorStalled'
            $global:ExoCalls.Count | Should -Be 2
        }

        It 'stops as CursorAdvanced when the cursor moves forward instead of back' {
            # A last row dated after the EndDate that was asked for means the time basis is wrong -
            # the service is answering on a different clock. Continuing would widen the window on
            # every page, which is the 1.4.3 defect. The reason names the diagnosis.
            $global:ExoPages.Add({
                param($StartDate, $EndDate, $StartingRecipientAddress)
                $anchor = $EndDate.ToUniversalTime()
                New-Row -MessageId 'a' -Recipient 'a@contoso.com' -ReceivedUtc $anchor.AddSeconds(-1)
                New-Row -MessageId 'b' -Recipient 'b@contoso.com' -ReceivedUtc $anchor.AddMinutes(5)
            })

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 10 `
                -TimeBasis 'Utc' -WarningVariable warnings -WarningAction SilentlyContinue

            $r.Truncated             | Should -BeTrue
            $r.TruncationReason      | Should -Be 'CursorAdvanced'
            $global:ExoCalls.Count   | Should -Be 1
            ($warnings | Out-String) | Should -Match 'TimeBasis Utc is wrong'
            ($warnings | Out-String) | Should -Match 'Try -TimeBasis Local'
        }

        It 'honours -MaxQueryPages and reports that the result is incomplete' {
            1..10 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 2 -Tag "p$_")) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 4 -WarningAction SilentlyContinue

            $global:ExoCalls.Count | Should -Be 4
            $r.PagesQueried        | Should -Be 4
            $r.Truncated           | Should -BeTrue
            $r.TruncationReason    | Should -Be 'MaxQueryPages'
        }

        It 'drops rows repeated across a page boundary and counts them' {
            $anchor = [datetime]::UtcNow
            $shared = New-Row -MessageId 'shared' -Recipient 'shared@contoso.com' -ReceivedUtc $anchor.AddSeconds(-2)

            $global:ExoPages.Add(@(
                New-Row -MessageId 'x' -Recipient 'x@contoso.com' -ReceivedUtc $anchor.AddSeconds(-1)
                $shared
            ))
            $global:ExoPages.Add(@(
                $shared
                New-Row -MessageId 'y' -Recipient 'y@contoso.com' -ReceivedUtc $anchor.AddSeconds(-3)
            ))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2

            $r.DuplicateRows     | Should -Be 1
            $r.RecipientRowCount | Should -Be 3
        }
    }

    Context 'Defect 2: the paging cursor mixed a local EndDate with a UTC one' {

        It 'round-trips the cursor without losing the UTC offset on the <Basis> basis' -ForEach @(
            @{ Basis = 'Utc' }
            @{ Basis = 'Local' }
        ) {
            $global:ExoPages.Add((New-FullPage -Count 3 -Tag 'p1'))
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3 -TimeBasis $Basis

            $global:ExoCalls.Count | Should -Be 2

            # The page-1 EndDate, minus 3 seconds, is the last row's Received. Page 2 must ask for
            # that instant - not that instant shifted by the machine's UTC offset, which was the
            # defect this context exists for.
            #
            # Since 1.6.4 the cursor is also rounded UP to the next whole second, because the service
            # floors EndDate to seconds and would otherwise exclude every row in the boundary second.
            # The offset property being tested here is unchanged by that; only the sub-second part is.
            $expectedUtc = ConvertTo-CeilSecond ($global:ExoCalls[0].EndDate.ToUniversalTime().AddSeconds(-3))
            $global:ExoCalls[1].EndDate.ToUniversalTime() | Should -Be $expectedUtc
        }

        It 'treats a Received value with an unspecified kind as UTC on the <Basis> basis' -ForEach @(
            @{ Basis = 'Utc' }
            @{ Basis = 'Local' }
        ) {
            # A REST deserialiser commonly hands back Kind=Unspecified. Treating that as local is
            # exactly the v1.4.2 defect.
            $global:ExoPages.Add((New-FullPage -Count 3 -Tag 'p1' -Unspecified))
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3 -TimeBasis $Basis

            $expectedUtc = ConvertTo-CeilSecond ($global:ExoCalls[0].EndDate.ToUniversalTime().AddSeconds(-3))
            $global:ExoCalls[1].EndDate.ToUniversalTime() | Should -Be $expectedUtc
        }

        It 'never lets EndDate move forward on the <Basis> basis' -ForEach @(
            @{ Basis = 'Utc' }
            @{ Basis = 'Local' }
        ) {
            1..6 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 2 -Tag "p$_")) }

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 6 `
                -TimeBasis $Basis -WarningAction SilentlyContinue

            $ends = @($global:ExoCalls | ForEach-Object { $_.EndDate.ToUniversalTime() })
            $ends.Count | Should -BeGreaterThan 2
            for ($i = 1; $i -lt $ends.Count; $i++) {
                $ends[$i] | Should -BeLessThan $ends[$i - 1]
            }
        }

        It 'keeps StartDate and EndDate on the same clock' {
            $global:ExoPages.Add((New-FullPage -Count 2 -Tag 'p1'))
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -TimeBasis 'Utc'

            foreach ($call in $global:ExoCalls) {
                $call.StartDate.Kind | Should -Be ([System.DateTimeKind]::Utc)
                $call.EndDate.Kind   | Should -Be ([System.DateTimeKind]::Utc)
            }
        }

        It 'takes one reading of the clock for the whole window' {
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 42 -ResultSize 100

            # Exactly 42 minutes, not approximately. v1.4.2 called Get-Date separately for each end.
            ($global:ExoCalls[0].EndDate - $global:ExoCalls[0].StartDate).TotalMinutes |
                Should -Be 42
        }

        It 'rejects a window wider than the documented 10 day per-query limit' {
            { Get-ExoQueue @script:Common -StartDate ([datetime]::UtcNow.AddDays(-11)) } |
                Should -Throw '*10 days per query*'
        }

        It 'rejects a window starting beyond the documented 90 day retention' {
            {
                Get-ExoQueue @script:Common `
                    -StartDate ([datetime]::UtcNow.AddDays(-100)) `
                    -EndDate   ([datetime]::UtcNow.AddDays(-95))
            } | Should -Throw '*90 days*'
        }
    }

    Context '1.6.5: an empty result says why it is empty' {

        BeforeEach {
            # The hint goes through Write-Ui, which -Quiet suppresses by design - it is operator
            # chatter, not a warning. $script:Common sets both -Quiet and -PassThru, so these tests
            # need a louder splat to see the console at all.
            $script:Loud = @{} + $script:Common
            $script:Loud.Remove('Quiet')
            $script:Loud.Remove('PassThru')
        }

        # Capture is inlined rather than wrapped in a helper: a function declared in a Context is not
        # in scope inside It on Pester 6. 6>&1 turns Write-Host into InformationRecord whose
        # MessageData is a HostInformationMessage rather than a string, so each record is coerced.

        It 'still reports zero, as it should' {
            $global:ExoPages.Add(@())
            $r = Get-ExoQueue @script:Common -AgeMinutes 30
            $r.MessageCount | Should -Be 0
        }

        It 'reports zero without claiming the tenant is empty' {
            # Reported from a live window: the lab held 40 Failed deliveries and a bare Get-ExoQueue
            # reported 0 - correctly - with nothing on screen explaining that -Status defaults to
            # Pending alone. A bare zero reads as "nothing is queued".
            $global:ExoPages.Add(@())
            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"
            $text | Should -Match 'filter result, not necessarily an empty tenant'
        }

        It 'points at the Pending-only default when -Status was not supplied' {
            $global:ExoPages.Add(@())
            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"
            $text | Should -Match 'defaults to Pending only'
        }

        It 'does not lecture about the default when -Status WAS supplied' {
            # The hint is about an unstated default. Repeating it to someone who named the statuses
            # explicitly is noise.
            $global:ExoPages.Add(@())
            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -Status Pending,Failed 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"
            $text | Should -Not -Match 'defaults to Pending only'
            $text | Should -Match 'Status=Pending, Failed'
        }

        It 'says nothing extra when there ARE results' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -Recipient 'a@contoso.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))))
            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"
            $text | Should -Not -Match 'filter result'
        }
    }

    Context '1.6.6: the console does not promise a query it will not make' {

        BeforeEach {
            $script:Loud = @{} + $script:Common
            $script:Loud.Remove('Quiet')
        }

        It 'never prints "Querying next page" - the old line was emitted before the loop decided' {
            # The progress callback fires BEFORE every stop condition is evaluated, so the page that
            # returned zero rows - the page that ENDS the run - still announced a next query. That
            # was the last line on screen at the end of every multi-page run.
            1..4 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 5 -Tag "p$_")) }
            $global:ExoPages.Add(@())

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -ResultSize 5 -MaxQueryPages 10 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Not -Match 'Querying next page'
            $text | Should -Not -Match 'message trace rows on page'
        }

        It 'keeps the per-page trail on the verbose stream for anyone debugging paging' {
            # $VerbosePreference has to be read in Get-ExoQueue's scope and passed into the callback:
            # the callback runs inside Get-ExoQueueTraceResult, an advanced function called WITHOUT
            # -Verbose, which sets its own SilentlyContinue and shadows the caller's preference.
            1..2 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 5 -Tag "v$_")) }
            $global:ExoPages.Add(@())

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -ResultSize 5 -Verbose 4>&1 |
                ForEach-Object { [string]$_ }) -join "`n"

            $text | Should -Match 'Page 1: 5 rows returned, 5 new, 5 total'
            $text | Should -Match 'Page 3: 0 rows returned, 0 new, 10 total'
        }

        It 'reports run time and page count once paging actually happened' {
            1..2 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 5 -Tag "e$_")) }
            $global:ExoPages.Add(@())

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -ResultSize 5 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match 'Retrieved in .+ over 3 pages\.'
        }

        It 'stays quiet about run time on a fast single-page run' {
            # Commentary on a query that took a quarter of a second is the clutter, not the cure.
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))))

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -ResultSize 100 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Not -Match 'Retrieved in'
        }
    }

    Context '1.6.6: the answer comes before the housekeeping' {

        BeforeEach {
            $script:Loud = @{} + $script:Common
            $script:Loud.Remove('Quiet')
        }

        It 'prints the count before any file path' {
            # The trend log used to be announced in three lines BETWEEN "Please wait.." and the
            # count, so the first thing on screen after the wait was housekeeping.
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))))

            $lines = @(Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } })

            $countAt = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like '*Number of messages in the queue*' })
            $filesAt = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like '*Files written*' })

            $countAt | Should -BeGreaterThan -1
            $filesAt | Should -BeGreaterThan $countAt
        }

        It 'gathers the trend log and the exports into one block' {
            $script:Loud.Output = 'CSV'
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))))

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -TopSenders 5 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match 'Files written:'
            $text | Should -Match 'Trend log'
            $text | Should -Match 'All results \(CSV\)'
            $text | Should -Match 'Top senders \(CSV\)'
            # The old lines aligned their colons with spaces baked into the string literal.
            $text | Should -Not -Match 'saved to\s+:'
        }

        It 'still shows the trend log when the queue is empty' {
            # The empty path returns early, before the export block, so it needs its own call.
            $global:ExoPages.Add(@())

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match 'Files written:'
            $text | Should -Match 'Trend log'
        }

        It 'states a zero once, not twice' {
            # "Number of messages in the queue: 0", then the filter explanation, then a separate
            # "No messages found in the queue." underneath it - three statements of one fact, with
            # the explanation squeezed in the middle.
            $global:ExoPages.Add(@())

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Not -Match 'No messages found in the queue'
            $text | Should -Match 'Number of messages in the queue'
            $text | Should -Match 'filter result, not necessarily an empty tenant'
        }

        It 'drops the recipient-delivery count when it only restates the message count' {
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -Recipient 'a@contoso.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))
                New-Row -MessageId 'm2' -Recipient 'b@contoso.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-3))
            ))

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Not -Match 'recipient deliveries'
        }

        It 'keeps the recipient-delivery count when a message fans out' {
            # Here the two numbers differ, and the gap between them IS the information.
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -Recipient 'a@contoso.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))
                New-Row -MessageId 'm1' -Recipient 'b@contoso.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))
                New-Row -MessageId 'm1' -Recipient 'c@contoso.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))
            ))

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match '\(3 recipient deliveries\)'
        }
    }

    Context '1.6.6: durations read in the unit that suits them' {

        It 'renders under a minute as seconds' {
            Format-ExoQueueDuration -Minutes 0.25 | Should -Be '15.0 s'
        }

        It 'renders ordinary queue ages as minutes' {
            Format-ExoQueueDuration -Minutes 41   | Should -Be '41.0 min'
            Format-ExoQueueDuration -Minutes 89.9 | Should -Match 'min'
        }

        It 'steps up to hours where minutes stop being readable' {
            # The outage case, and the one the old format read worst at: "404.0 min".
            Format-ExoQueueDuration -Minutes 404 | Should -Be '6.7 hr'
            Format-ExoQueueDuration -Minutes 90  | Should -Be '1.5 hr'
        }

        It 'steps up to days past two of them' {
            Format-ExoQueueDuration -Minutes 4320 | Should -Be '3.0 d'
        }

        It 'reports an absent duration rather than rendering null as zero' {
            Format-ExoQueueDuration -Minutes $null | Should -Be 'n/a'
        }

        It 'clamps a negative duration instead of printing a negative age' {
            # Received can sit a shade in the future relative to the local clock.
            Format-ExoQueueDuration -Minutes -5 | Should -Be '0.0 s'
        }

        It 'uses the scaled unit on the queue age line' {
            $script:Loud = @{} + $script:Common
            $script:Loud.Remove('Quiet')
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow.AddHours(-7))))

            $text = (Get-ExoQueue @script:Loud -StartDate ([datetime]::UtcNow.AddHours(-9)) 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match 'Queue age: oldest 7\.0 hr'
        }
    }

    Context '1.6.6: the destination heading says how much is hidden' {

        BeforeEach {
            $script:Loud = @{} + $script:Common
            $script:Loud.Remove('Quiet')

            $script:ThreeDomains = @(
                New-Row -MessageId 'd1' -Recipient 'a@one.com'   -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-2))
                New-Row -MessageId 'd2' -Recipient 'b@two.com'   -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-3))
                New-Row -MessageId 'd3' -Recipient 'c@three.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-4))
            )
        }

        It 'carries the total on the returned rows' {
            $rows = Get-ExoQueueDestination -Row $script:ThreeDomains -First 2
            @($rows).Count            | Should -Be 2
            @($rows)[0].TotalDomains  | Should -Be 3
        }

        It 'names the total when nothing is hidden, instead of claiming a top 10' {
            $global:ExoPages.Add($script:ThreeDomains)

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match 'Queued by destination domain \(3\):'
            $text | Should -Not -Match 'top 10'
        }

        It 'says how many domains it is hiding when the list IS cut' {
            # Ten rows under a "top 10" heading looks identical whether ten domains exist or four
            # hundred do, and those are different incidents.
            $global:ExoPages.Add($script:ThreeDomains)

            $text = (Get-ExoQueue @script:Loud -AgeMinutes 30 -TopDestinations 2 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match 'Queued by destination domain \(top 2 of 3\):'
        }

        It 'renders the domain age in the same scaled unit as the queue age line' {
            # Found by looking at a real lab screenshot: the console printed "AgeMinutes 3003.7"
            # directly underneath "Queue age: oldest 2.1 d". Same number, same screen, one of them
            # needing division - which is the exact problem 1.6.6 fixed one line further up.
            $global:ExoPages.Add(@(
                New-Row -MessageId 'old1' -Recipient 'a@slow.com' -ReceivedUtc ([datetime]::UtcNow.AddMinutes(-3003.7))
            ))

            $text = (Get-ExoQueue @script:Loud -StartDate ([datetime]::UtcNow.AddDays(-4)) 6>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

            $text | Should -Match '2\.1 d'
            $text | Should -Not -Match '3003\.7'
            $text | Should -Not -Match 'AgeMinutes'
        }

        It 'keeps AgeMinutes on the object as a number for callers to sort and threshold on' {
            # The scaled Age is for reading. Replacing the numeric property rather than adding
            # alongside it would break any caller doing "where AgeMinutes -gt 60".
            $rows = @(Get-ExoQueueDestination -Row $script:ThreeDomains -First 5)
            $rows[0].AgeMinutes | Should -BeOfType [double]
            $rows[0].Age        | Should -BeOfType [string]
        }
    }

    Context '1.6.3: the repeated hour is not ambiguous when the value carries an offset' {

        BeforeAll {
            # Find the local zone's next fall-back so this means something on a UTC build agent too.
            $script:LocalZone = [System.TimeZoneInfo]::Local
            $script:AmbiguousUtc = $null
            $probe = [datetime]::SpecifyKind([datetime]::UtcNow.Date, 'Utc')
            foreach ($h in 0..(400 * 24)) {
                $candidate = $probe.AddHours($h)
                $bare = [datetime]::SpecifyKind($candidate.ToLocalTime(), 'Unspecified')
                if ($script:LocalZone.IsAmbiguousTime($bare)) { $script:AmbiguousUtc = $candidate; break }
            }
            $script:ZoneHasDst = $null -ne $script:AmbiguousUtc
        }

        It 'treats a value carrying an offset as unambiguous, even inside the repeated hour' {
            if (-not $script:ZoneHasDst) { Set-ItResult -Skipped -Because 'this machine has no daylight saving'; return }

            # This is the correction to 1.6.2. A Kind=Local value produced by ToLocalTime() keeps the
            # daylight side in a hidden flag and serialises with its per-instant offset, so the
            # service - which was measured to be offset-aware - resolves it correctly.
            $local = $script:AmbiguousUtc.ToLocalTime()
            Test-ExoQueueAmbiguousRequestTime -RequestTime $local | Should -BeFalse
            ([datetime]::SpecifyKind($script:AmbiguousUtc, 'Utc')) |
                ForEach-Object { Test-ExoQueueAmbiguousRequestTime -RequestTime $_ } | Should -BeFalse
        }

        It 'proves the two readings of the repeated hour survive a round trip' {
            if (-not $script:ZoneHasDst) { Set-ItResult -Skipped -Because 'this machine has no daylight saving'; return }

            # Identical ticks, different instants. If this ever stopped holding, the cursor really
            # would be ambiguous and 1.6.2's stop would have been right after all.
            $early = $script:AmbiguousUtc.ToLocalTime()
            $late  = $script:AmbiguousUtc.AddHours(1).ToLocalTime()

            $early.Ticks | Should -Be $late.Ticks
            $early.ToString('o') | Should -Not -Be $late.ToString('o')
            $early.ToUniversalTime() | Should -Be $script:AmbiguousUtc
            $late.ToUniversalTime()  | Should -Be $script:AmbiguousUtc.AddHours(1)
        }

        It 'reports a bare caller-supplied value inside the repeated hour' {
            if (-not $script:ZoneHasDst) { Set-ItResult -Skipped -Because 'this machine has no daylight saving'; return }

            # The one genuinely lossy case: no offset to read, so a reading has to be chosen.
            $bare = [datetime]::SpecifyKind($script:AmbiguousUtc.ToLocalTime(), 'Unspecified')
            Test-ExoQueueAmbiguousRequestTime -RequestTime $bare | Should -BeTrue
        }

        It 'leaves ordinary bare values alone' {
            foreach ($offset in @(-90, -30, 30, 90)) {
                $t = [datetime]::SpecifyKind([datetime]::UtcNow.AddDays($offset).ToLocalTime(), 'Unspecified')
                if ($script:LocalZone.IsAmbiguousTime($t)) { continue }
                Test-ExoQueueAmbiguousRequestTime -RequestTime $t | Should -BeFalse -Because "$t is not in a repeated hour"
            }
        }

        It 'pages straight through the repeated hour instead of stopping' {
            if (-not $script:ZoneHasDst) { Set-ItResult -Skipped -Because 'this machine has no daylight saving'; return }

            # 1.6.2 stopped here as CursorAmbiguous. That was a false positive built on a test double
            # that discarded the offset, and it would have truncated healthy runs for an hour a year.
            #
            # The window is explicit and Kind=Local, because the next fall-back is months away: an
            # Age-based window ends at "now" and the cursor would move forward out of it, which is a
            # different stop (CursorAdvanced) and would not test this at all.
            $anchor = $script:AmbiguousUtc.AddMinutes(20)
            $global:ExoPages.Add(@(1..3 | ForEach-Object { New-Row -MessageId "amb$_" -Recipient "r$_@contoso.com" -ReceivedUtc $anchor.AddSeconds(-$_) }))
            $global:ExoPages.Add(@(1..3 | ForEach-Object { New-Row -MessageId "nxt$_" -Recipient "n$_@contoso.com" -ReceivedUtc $anchor.AddMinutes(-40).AddSeconds(-$_) }))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -ResultSize 3 -IncludeDelivered `
                    -StartDate $anchor.AddHours(-3).ToLocalTime() `
                    -EndDate   $anchor.AddMinutes(1).ToLocalTime() `
                    -WarningAction SilentlyContinue

            $r.TruncationReason | Should -Not -Be 'CursorAmbiguous'
            $r.MessageCount     | Should -Be 6
            $r.Truncated        | Should -BeFalse
        }

        It 'warns when the caller supplies a bare ambiguous -EndDate' {
            if (-not $script:ZoneHasDst) { Set-ItResult -Skipped -Because 'this machine has no daylight saving'; return }

            $endBare   = [datetime]::SpecifyKind($script:AmbiguousUtc.AddMinutes(20).ToLocalTime(), 'Unspecified')
            $startBare = $endBare.AddHours(-3)
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -StartDate $startBare -EndDate $endBare `
                    -IncludeDelivered -WarningAction SilentlyContinue

            @($r.Warnings | Where-Object { $_ -match 'occurs twice' }).Count | Should -Be 1
        }
    }

    Context '1.6.1: the tenant already knows its journal address' {

        BeforeEach {
            # Same known-empty registry as the Defect 1 context: these tests are about discovery,
            # and a real saved value in the user hive would mask it.
            Mock Test-Path        { $false } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Test-Path        { [System.IO.Directory]::Exists("$Path") -or [System.IO.File]::Exists("$Path") }
            Mock Get-ItemProperty { $null } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Get-ItemProperty { $null }
            Mock Set-ItemProperty { }
            # Get-JournalRule exists only inside a connected session, like Get-MessageTraceV2, so it
            # has to be a real global function rather than a Pester mock.
            $global:ExoJournalRules = @()
            function global:Get-JournalRule { param([object]$Identity, [object]$ErrorAction) $global:ExoJournalRules }
        }

        AfterEach {
            Remove-Item -Path 'Function:Get-JournalRule' -ErrorAction SilentlyContinue
            Remove-Variable -Name ExoJournalRules -Scope Global -ErrorAction SilentlyContinue
        }

        It 'reads the address out of an enabled journal rule instead of asking' {
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'Journal everything'; JournalEmailAddress = 'archive@vendor.example'; Enabled = $true }
            )
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly

            # Discovered, and used as the server-side recipient filter.
            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'archive@vendor.example'
        }

        It 'ignores a disabled rule, which is journaling nothing' {
            # Filtering on a disabled rule's address would remove nothing while looking like it had
            # worked, which is worse than not filtering.
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'Old'; JournalEmailAddress = 'retired@vendor.example'; Enabled = $false }
            )
            $global:ExoPages.Add(@())

            # Nothing to discover and nothing saved, and Common already carries -Force, so the
            # prompt is suppressed and the run must refuse rather than guess.
            { Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly } |
                Should -Throw -ExpectedMessage '*No journal address is available*'
        }

        It 'unwraps a display-name form' {
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'J'; JournalEmailAddress = 'Archive Mailbox <archive@vendor.example>'; Enabled = $true }
            )
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'archive@vendor.example'
        }

        It 'collects every enabled rule, for tenants journaling to more than one destination' {
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'A'; JournalEmailAddress = 'one@vendor.example'; Enabled = $true }
                [pscustomobject]@{ Name = 'B'; JournalEmailAddress = 'two@vendor.example'; Enabled = $true }
            )
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'one@vendor.example'
            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'two@vendor.example'
        }

        It 'lets -JournalSmtp override what the tenant says' {
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'J'; JournalEmailAddress = 'discovered@vendor.example'; Enabled = $true }
            )
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -JournalSmtp 'explicit@vendor.example'

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'explicit@vendor.example'
            @($global:ExoCalls[0].RecipientAddress) | Should -Not -Contain 'discovered@vendor.example'
        }

        It 'skips discovery on request' {
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'J'; JournalEmailAddress = 'discovered@vendor.example'; Enabled = $true }
            )
            $global:ExoPages.Add(@())

            # Discovery off, nothing saved, prompt suppressed by Common's -Force: it must refuse
            # rather than quietly fall back to the address it was told not to use.
            { Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -SkipJournalDiscovery } |
                Should -Throw -ExpectedMessage '*No journal address is available*'
        }

        It 'treats a rule disabled as text or an enum as disabled, not enabled' {
            # Enabled is documented as a bool, but nothing on disk pins that, and the string form
            # 'False' is truthy in PowerShell - so a check that only understood [bool] would read a
            # disabled rule as enabled and filter on an address journaling nothing.
            foreach ($state in @('False', 'Disabled', '0')) {
                $global:ExoJournalRules = @(
                    [pscustomobject]@{ Name = 'Off'; JournalEmailAddress = 'retired@vendor.example'; Enabled = $state }
                )
                $global:ExoPages.Clear()
                $global:ExoPages.Add(@())

                { Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly } |
                    Should -Throw -ExpectedMessage '*No journal address is available*' -Because "Enabled='$state' means disabled"
            }
        }

        It 'treats an absent Enabled property as enabled rather than discarding the rule' {
            $global:ExoJournalRules = @(
                [pscustomobject]@{ Name = 'No Enabled property'; JournalEmailAddress = 'archive@vendor.example' }
            )
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'archive@vendor.example'
        }

        It 'survives a role that cannot read journal rules' {            function global:Get-JournalRule { param([object]$Identity, [object]$ErrorAction) throw 'Access denied.' }
            $global:ExoPages.Add(@())

            # A message-tracking operator may not hold the journaling role. That is a reason to fall
            # back, not to fail the run - so the explicit address still works.
            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -JournalSmtp 'explicit@vendor.example'

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'explicit@vendor.example'
        }
    }

    Context '1.6.1: -JournalExclude reports what it threw away' {

        BeforeEach {
            Mock Test-Path        { $false } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Test-Path        { [System.IO.Directory]::Exists("$Path") -or [System.IO.File]::Exists("$Path") }
            Mock Get-ItemProperty { $null } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Get-ItemProperty { $null }
            Mock Set-ItemProperty { }
        }

        It 'counts the excluded deliveries' {
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                1..7 | ForEach-Object { New-Row -MessageId "j$_" -Recipient 'journal@vendor.example' -ReceivedUtc $now.AddSeconds(-$_) }
                1..3 | ForEach-Object { New-Row -MessageId "n$_" -Recipient "user$_@contoso.com"     -ReceivedUtc $now.AddSeconds(-$_) }
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalExclude -JournalSmtp 'journal@vendor.example'

            # Without this the run reported 3 and said nothing about the 7 it paid to retrieve.
            $r.JournalExcluded   | Should -Be 7
            $r.RecipientRowCount | Should -Be 3
        }

        It 'records the excluded count in the trend log' {
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                New-Row -MessageId 'j1' -Recipient 'journal@vendor.example' -ReceivedUtc $now.AddSeconds(-1)
                New-Row -MessageId 'n1' -Recipient 'user@contoso.com'       -ReceivedUtc $now.AddSeconds(-2)
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalExclude -JournalSmtp 'journal@vendor.example'

            Get-Content -LiteralPath $r.LogPath -Raw | Should -Match 'Exclude\(journal@vendor\.example,-1\)'
        }

        It 'warns when a truncated run also discarded most of what it retrieved' {
            # The combination that cannot be reasoned about: the count is not a floor for the
            # non-journal queue, because the pages spent on journal mail could have held anything.
            $now = [datetime]::UtcNow
            1..10 | ForEach-Object {
                $tag = $_
                $global:ExoPages.Add(@(1..4 | ForEach-Object {
                    New-Row -MessageId "j$tag-$_" -Recipient 'journal@vendor.example' -ReceivedUtc $now.AddSeconds(-($tag * 10 + $_))
                }))
            }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 4 -MaxQueryPages 3 `
                -JournalExclude -JournalSmtp 'journal@vendor.example' -WarningAction SilentlyContinue

            $r.Truncated | Should -BeTrue
            @($r.Warnings | Where-Object { $_ -match 'not a floor' }).Count | Should -Be 1
        }

        It 'stays quiet when nothing was excluded' {
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(New-Row -MessageId 'n1' -Recipient 'user@contoso.com' -ReceivedUtc $now.AddSeconds(-1)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalExclude -JournalSmtp 'journal@vendor.example'

            $r.JournalExcluded | Should -Be 0
            @($r.Warnings | Where-Object { $_ -match 'not a floor' }).Count | Should -Be 0
        }
    }

    Context '1.6.1: the saved journal address is scoped to a tenant' {

        BeforeEach {
            $global:ExoRegistry = @{}
            Mock Test-Path        { $global:ExoRegistry.ContainsKey("$Path") } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Test-Path        { [System.IO.Directory]::Exists("$Path") -or [System.IO.File]::Exists("$Path") }
            Mock Get-ItemProperty { if ($global:ExoRegistry.ContainsKey("$Path")) { [pscustomobject]@{ JournalSmtp = $global:ExoRegistry["$Path"] } } else { $null } } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Get-ItemProperty { $null }
            Mock Set-ItemProperty { $global:ExoRegistry["$Path"] = "$Value" }
            Mock New-Item         { } -ParameterFilter { "$Path" -like 'HKCU:*' }
            # Mocking New-Item at all shadows it for the output folder too, so the default has to
            # really create it or every run in this Context dies before it queries anything.
            Mock New-Item         { [System.IO.Directory]::CreateDirectory("$Path") }
        }

        AfterEach {
            Remove-Variable -Name ExoRegistry -Scope Global -ErrorAction SilentlyContinue
        }

        It 'prefers the value saved under the connected tenant over an unscoped one' {
            # The cross-tenant failure: one shared value meant a consultant moving between tenants
            # filtered one tenant's queue on another tenant's journal address, and got a number that
            # looked entirely reasonable.
            $global:ExoRegistry['HKCU:\Software\Microsoft\Exchange\ExoQueue'] = 'old-tenant@vendor.example'
            $global:ExoRegistry['HKCU:\Software\Microsoft\Exchange\ExoQueue\Tenants\contoso.onmicrosoft.com'] = 'right@vendor.example'
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'right@vendor.example'
            @($global:ExoCalls[0].RecipientAddress) | Should -Not -Contain 'old-tenant@vendor.example'
        }

        It 'still honours a pre-1.6.1 unscoped value, and warns which tenant it is being used against' {
            $global:ExoRegistry['HKCU:\Software\Microsoft\Exchange\ExoQueue'] = 'legacy@vendor.example'
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -WarningVariable warnings -WarningAction SilentlyContinue

            @($global:ExoCalls[0].RecipientAddress) | Should -Contain 'legacy@vendor.example'
            # -Quiet is in Common. The warning must survive it: an unattended cross-tenant run is
            # the case that most needs telling.
            @($warnings | Where-Object { "$_" -match 'saved without a tenant' }).Count | Should -Be 1
            @($warnings | Where-Object { "$_" -match 'contoso\.onmicrosoft\.com' }).Count | Should -Be 1
            $r | Should -Not -BeNullOrEmpty
        }

        It 'writes new saves under the tenant, not over the shared value' {
            $global:ExoPages.Add(@())

            # -Force skips the save, so this run has to be the interactive shape.
            $common = @{} + $script:Common
            $common.Remove('Force')
            $common.Remove('Quiet')
            $null = Get-ExoQueue @common -AgeMinutes 30 -JournalOnly -JournalSmtp 'new@vendor.example' -Confirm:$false 6>$null

            $global:ExoRegistry.Keys | Should -Contain 'HKCU:\Software\Microsoft\Exchange\ExoQueue\Tenants\contoso.onmicrosoft.com'
            $global:ExoRegistry.Keys | Should -Not -Contain 'HKCU:\Software\Microsoft\Exchange\ExoQueue'
        }
    }

    Context 'Defect 1: the journal switches filtered on the sender' {

        BeforeEach {
            # HKCU here is the real user hive, which may already hold a saved journal address from
            # ordinary use. These tests need a known-empty store. Only this Context mocks the
            # registry: the block that reads it runs only for -JournalOnly/-JournalExclude, and a
            # Test-Path mock in scope makes PSScriptAnalyzer see Test-Path as an alias of
            # PesterMock_script_Test-Path_..., which is why the hygiene checks live in their own
            # Describe below.
            Mock Test-Path        { $false } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Test-Path        { [System.IO.Directory]::Exists("$Path") -or [System.IO.File]::Exists("$Path") }
            Mock Get-ItemProperty { $null } -ParameterFilter { "$Path" -like 'HKCU:*' }
            Mock Get-ItemProperty { $null }
            Mock Set-ItemProperty { }
        }

        It 'filters -JournalOnly on the recipient and never sends a SenderAddress' {
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -JournalSmtp 'journal@contoso.com'

            $global:ExoCalls.Count | Should -BeGreaterThan 0
            foreach ($call in $global:ExoCalls) {
                @($call.RecipientAddress) | Should -Contain 'journal@contoso.com'
                $call.SenderAddress       | Should -BeNullOrEmpty
            }
        }

        It 'removes mail addressed TO the journal and keeps mail merely sent FROM it' {
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                New-Row -MessageId 'to-journal'   -From 'staff@contoso.com'   -Recipient 'journal@contoso.com' -ReceivedUtc $now.AddSeconds(-1)
                New-Row -MessageId 'from-journal' -From 'journal@contoso.com' -Recipient 'staff@contoso.com'   -ReceivedUtc $now.AddSeconds(-2)
                New-Row -MessageId 'unrelated'    -From 'a@contoso.com'       -Recipient 'b@contoso.com'       -ReceivedUtc $now.AddSeconds(-3)
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 `
                -JournalExclude -JournalSmtp 'journal@contoso.com'

            $ids = @($r.Messages.MessageId)
            $ids | Should -Not -Contain 'to-journal'
            $ids | Should -Contain 'from-journal'
            $ids | Should -Contain 'unrelated'
        }

        It 'matches a wildcard journal address across a whole domain' {
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                New-Row -MessageId 'j1'        -Recipient 'a@journal.contoso.com' -ReceivedUtc $now.AddSeconds(-1)
                New-Row -MessageId 'j2'        -Recipient 'b@journal.contoso.com' -ReceivedUtc $now.AddSeconds(-2)
                New-Row -MessageId 'unrelated' -Recipient 'c@contoso.com'         -ReceivedUtc $now.AddSeconds(-3)
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 `
                -JournalExclude -JournalSmtp 'a@journal.contoso.com', '*@journal.contoso.com'

            @($r.Messages.MessageId) | Should -Be @('unrelated')
        }

        It 'excludes journal mail without disturbing paging' {
            # A full page of nothing but journal mail must still trigger the next page: the raw
            # row count drives paging, and the exclusion is applied afterwards.
            $global:ExoPages.Add({
                param($StartDate, $EndDate, $StartingRecipientAddress)
                $anchor = $EndDate.ToUniversalTime()
                1..3 | ForEach-Object {
                    New-Row -MessageId "j$_" -Recipient 'journal@contoso.com' -ReceivedUtc $anchor.AddSeconds(-$_)
                }
            })
            $global:ExoPages.Add(@(New-Row -MessageId 'real' -Recipient 'user@contoso.com' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-20)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3 `
                -JournalExclude -JournalSmtp 'journal@contoso.com'

            $global:ExoCalls.Count   | Should -Be 2
            @($r.Messages.MessageId) | Should -Be @('real')
        }

        It 'rejects -JournalOnly together with -JournalExclude' {
            { Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -JournalExclude -JournalSmtp 'j@contoso.com' } |
                Should -Throw '*JournalOnly, JournalExclude*'
        }

        It 'fails fast under -Force when no journal address is available, without prompting' {
            Mock Read-Host { 'should-never-be-called@contoso.com' }

            { Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly } |
                Should -Throw '*No journal address is available*'

            Should -Invoke Read-Host -Times 0 -Exactly
        }

        It 'does not write to the registry under -Force' {
            Mock Set-ItemProperty { }
            Mock New-Item { }
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -JournalOnly -JournalSmtp 'journal@contoso.com'

            Should -Invoke Set-ItemProperty -Times 0 -Exactly
        }
    }

    Context 'Defect 3: Top Recipients counted from the deduplicated message set' {

        BeforeEach {
            $now = [datetime]::UtcNow
            # 3 messages, 5 recipient deliveries. m1 is a one-to-many message.
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -From 'bulk@contoso.com' -Recipient 'a@contoso.com' -ReceivedUtc $now.AddSeconds(-1)
                New-Row -MessageId 'm1' -From 'bulk@contoso.com' -Recipient 'b@contoso.com' -ReceivedUtc $now.AddSeconds(-2)
                New-Row -MessageId 'm1' -From 'bulk@contoso.com' -Recipient 'c@contoso.com' -ReceivedUtc $now.AddSeconds(-3)
                New-Row -MessageId 'm2' -From 'one@contoso.com'  -Recipient 'd@contoso.com' -ReceivedUtc $now.AddSeconds(-4)
                New-Row -MessageId 'm3' -From 'two@contoso.com'  -Recipient 'e@contoso.com' -ReceivedUtc $now.AddSeconds(-5)
            ))
        }

        It 'reports messages and recipient deliveries as separate counts' {
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $r.MessageCount      | Should -Be 3
            $r.RecipientRowCount | Should -Be 5
        }

        It 'counts every recipient in Top Recipients' {
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopRecipients 10

            @($r.TopRecipients).Count | Should -Be 5
            @($r.TopRecipients.Name)  | Should -Contain 'b@contoso.com'
            @($r.TopRecipients.Name)  | Should -Contain 'c@contoso.com'
            (@($r.TopRecipients) | Measure-Object -Property Count -Sum).Sum | Should -Be 5
        }

        It 'counts a one-to-many message once in Top Senders' {
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 10

            $bulk = @($r.TopSenders) | Where-Object { $_.Name -eq 'bulk@contoso.com' }
            $bulk.Count | Should -Be 1
            (@($r.TopSenders) | Measure-Object -Property Count -Sum).Sum | Should -Be 3
        }

        It 'labels each statistic with the population it was counted over' {
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 5 -TopRecipients 5

            @($r.TopSenders)[0].Population    | Should -Be 'Messages'
            @($r.TopRecipients)[0].Population | Should -Be 'RecipientDeliveries'
        }

        It 'keeps the full recipient list on the message row' {
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $m1 = @($r.Messages) | Where-Object { $_.MessageId -eq 'm1' }
            $m1.RecipientCount | Should -Be 3
            $m1.Recipients     | Should -Match 'a@contoso\.com'
            $m1.Recipients     | Should -Match 'b@contoso\.com'
            $m1.Recipients     | Should -Match 'c@contoso\.com'
        }

        It 'returns messages oldest first' {
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            # v1.4.2 sorted by MessageId, an opaque token, so the queue arrived in no useful order.
            @($r.Messages.MessageId) | Should -Be @('m3', 'm2', 'm1')
        }
    }

    Context 'Defect 9: rows without a MessageId were merged into one' {

        It 'keeps rows with a blank MessageId distinct' {
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                New-Row -MessageId ''   -Recipient 'a@contoso.com' -ReceivedUtc $now.AddSeconds(-1)
                New-Row -MessageId ''   -Recipient 'b@contoso.com' -ReceivedUtc $now.AddSeconds(-2)
                New-Row -MessageId 'm1' -Recipient 'c@contoso.com' -ReceivedUtc $now.AddSeconds(-3)
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $r.MessageCount | Should -Be 3
        }
    }

    Context 'Defect 23: Top-N ties were broken non-deterministically' {

        It 'produces identical output for two runs over the same data' {
            $build = {
                $now = [datetime]::UtcNow
                @('z', 'y', 'x', 'w') | ForEach-Object {
                    New-Row -MessageId "m-$_" -From "$_@contoso.com" -Recipient "$_@fabrikam.com" -ReceivedUtc $now.AddSeconds(-1)
                }
            }

            $global:ExoPages.Add((& $build))
            $first = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 2

            $global:ExoCalls.Clear()
            $global:ExoPages.Clear()
            $global:ExoPages.Add((& $build))
            $second = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 2

            @($first.TopSenders.Name) | Should -Be @($second.TopSenders.Name)
            @($first.TopSenders.Name) | Should -Be @('w@contoso.com', 'x@contoso.com')
        }
    }

    Context 'Defect 4: a failed page discarded every page already retrieved' {

        It 'keeps the rows it already has and flags the result as truncated' {
            $global:ExoPages.Add((New-FullPage -Count 2 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 2 -Tag 'p2'))

            $global:ExoThrow.Add($null)
            $global:ExoThrow.Add($null)
            1..5 | ForEach-Object { $global:ExoThrow.Add('The request was throttled (429).') }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxRetryCount 2 -WarningAction SilentlyContinue

            $r.RecipientRowCount | Should -Be 4
            $r.Truncated         | Should -BeTrue
            $r.TruncationReason  | Should -Be 'QueryFailed'
        }

        It 'retries a transient failure and returns a complete result when it clears' {
            $global:ExoThrow.Add('The server is busy. Please try again. (503)')
            $global:ExoThrow.Add($null)
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -MaxRetryCount 3

            $global:ExoCalls.Count | Should -Be 2
            $r.MessageCount        | Should -Be 1
            $r.Truncated           | Should -BeFalse
        }

        It 'does not retry an error that is not transient' {
            1..5 | ForEach-Object { $global:ExoThrow.Add('The user is not authorized to run Get-MessageTraceV2.') }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -MaxRetryCount 4 -WarningAction SilentlyContinue

            $global:ExoCalls.Count | Should -Be 1
            $r.Truncated           | Should -BeTrue
            $r.TruncationReason    | Should -Be 'QueryFailed'
        }
    }

    Context 'Defect 8: an empty queue wrote nothing to the trend log' {

        It 'writes a log entry when the queue is empty' {
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30

            $r.MessageCount | Should -Be 0
            $r.LogPath      | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $r.LogPath | Should -BeTrue
            @(Get-Content -LiteralPath $r.LogPath)[-1] | Should -Match '0 messages in the queue'
        }
    }

    Context 'Defect 5 and 7: the log could not distinguish a partial or a demo run' {

        It 'records the truncation state, the window, the status set and the version' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100
            $line = @(Get-Content -LiteralPath $r.LogPath)[-1]

            $line | Should -Match 'Truncated=False'
            $line | Should -Match 'Status=Pending'
            $line | Should -Match 'Pages=1/20'
            # Asserted from the result rather than pinned to a literal: the default moved from Utc
            # to Local in 1.5.3 on tenant evidence, and this test is about the log FORMAT.
            $line | Should -Match ([regex]::Escape("Basis=$($r.TimeBasis)"))
            $r.TimeBasis | Should -Not -BeNullOrEmpty
            # Asserted against the script's own version rather than a literal. A literal here meant
            # every version bump produced a spurious failure in a test that is not about the number.
            $line | Should -Match ([regex]::Escape("v$($r.Version)"))
            $r.Version | Should -Not -BeNullOrEmpty
            $line | Should -Match 'recipient deliveries'
        }

        It 'marks a truncated run in the log rather than persisting the short count as complete' {
            1..10 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 2 -Tag "p$_")) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -MaxQueryPages 3 -WarningAction SilentlyContinue
            $line = @(Get-Content -LiteralPath $r.LogPath)[-1]

            $line | Should -Match 'Truncated=True\(MaxQueryPages\)'
        }

        It 'records the delivered statuses when -IncludeDelivered is used' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -IncludeDelivered
            $line = @(Get-Content -LiteralPath $r.LogPath)[-1]

            $line                       | Should -Match 'Status=Pending\+Delivered'
            @($global:ExoCalls[0].Status) | Should -Contain 'Delivered'
        }

        It 'lets -Status override -IncludeDelivered with a warning' {
            $global:ExoPages.Add(@())

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -IncludeDelivered `
                -Status 'Failed', 'Quarantined' -WarningVariable warnings -WarningAction SilentlyContinue

            @($global:ExoCalls[0].Status) | Should -Be @('Failed', 'Quarantined')
            ($warnings | Out-String)      | Should -Match 'IncludeDelivered was ignored'
        }
    }

    Context 'Defect 18 and 19: output encoding and culture-sensitive paths' {

        It 'round-trips non-ASCII addresses through CSV' {
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -From 'sénder@exämple.com' -Recipient 'récipient@exämple.com' `
                    -Subject 'Überweisung' -ReceivedUtc ([datetime]::UtcNow)
            ))

            $script:Common.Output = 'CSV'
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $csv = @($r.OutputFiles | Where-Object { $_ -like '*.csv' })[0]
            $imported = @(Import-Csv -LiteralPath $csv)
            $imported[0].SenderAddress    | Should -Be 'sénder@exämple.com'
            $imported[0].RecipientAddress | Should -Be 'récipient@exämple.com'
            $imported[0].Subject          | Should -Be 'Überweisung'
        }

        It 'writes the log as UTF-8 rather than ASCII or ANSI' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100
            $bytes = [System.IO.File]::ReadAllBytes($r.LogPath)

            # Add-Content -Encoding UTF8 on 5.1 writes a BOM when it creates the file. Its default
            # is ANSI, which silently mangles any non-ASCII address that reaches the log line.
            $bytes.Length | Should -BeGreaterThan 3
            @($bytes[0], $bytes[1], $bytes[2]) | Should -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'names the output folder identically under a non-English culture' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture =
                    [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
                $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100
            }
            finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
            }

            $expected = [datetime]::Now.ToString('dd-MMM-yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
            (Split-Path -Path (Split-Path -Path $r.LogPath -Parent) -Leaf) | Should -Be $expected
        }

        It 'gives every file from one run the same timestamp' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $script:Common.Output = 'CSV'
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 5 -TopRecipients 5

            $stamps = @($r.OutputFiles | ForEach-Object {
                if ((Split-Path -Path $_ -Leaf) -match '(\d{2}-[A-Za-z]{3}-\d{4}--\d{4})') { $Matches[1] }
            })
            @($r.OutputFiles).Count      | Should -Be 3
            @($stamps | Select-Object -Unique).Count | Should -Be 1
        }
    }

    Context 'Defect 21: XML Top-N filenames gained a second extension' {

        It 'writes well-formed XML file names' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $script:Common.Output = 'XML'
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 5

            @($r.OutputFiles).Count | Should -Be 2
            foreach ($file in $r.OutputFiles) {
                $file | Should -Not -Match '\.xml-'
                $file | Should -Match '\.xml$'
                Test-Path -LiteralPath $file | Should -BeTrue
            }
        }
    }

    Context 'Defect 14 and 16: automation and Excel launch' {

        It 'never prompts under -Force' {
            Mock Read-Host { 'Y' }
            Mock Start-Process { }
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $script:Common.Output = 'CSV'
            $null = Get-ExoQueue @script:Common -AgeDays 1 -ResultSize 100 -WarningAction SilentlyContinue

            Should -Invoke Read-Host    -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'warns instead of throwing when Excel cannot be found' {
            Mock Get-ExoQueueExcelPath { $null }
            Mock Read-Host { 'Y' }
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $params = $script:Common.Clone()
            $params.Remove('Force')
            $params.Output = 'CSV'

            {
                Get-ExoQueue @params -AgeMinutes 30 -ResultSize 100 -WarningAction SilentlyContinue
            } | Should -Not -Throw
        }

        It 'warns when an exported value would be read as a spreadsheet formula' {
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -Subject '=cmd|calc' -ReceivedUtc ([datetime]::UtcNow)
            ))

            $script:Common.Output = 'CSV'
            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 `
                -WarningVariable warnings -WarningAction SilentlyContinue

            ($warnings | Out-String) | Should -Match 'evaluated as formulas'
        }

        It 'exports the value unaltered, because rewriting a subject would damage the evidence' {
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -Subject '=cmd|calc' -ReceivedUtc ([datetime]::UtcNow)
            ))

            $script:Common.Output = 'CSV'
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WarningAction SilentlyContinue
            $csv = @($r.OutputFiles | Where-Object { $_ -like '*.csv' })[0]

            @(Import-Csv -LiteralPath $csv)[0].Subject | Should -Be '=cmd|calc'
        }
    }

    Context 'Defect 12 and 13: the connection check proved nothing' {

        It 'fails fast under -Force when there is no connection, without trying to connect' {
            Mock Get-ConnectionInformation { $null }
            Mock Connect-ExchangeOnline { }

            { Get-ExoQueue @script:Common -AgeMinutes 30 } | Should -Throw '*Not connected to Exchange Online*'

            Should -Invoke Connect-ExchangeOnline -Times 0 -Exactly
        }

        It 'reports a connected session that cannot actually run the query' {
            # Simulates ExchangeOnlineManagement 3.4.0, which connects happily but has no
            # Get-MessageTraceV2 at all. Both versions are installed on this machine. Removing the
            # stub is more faithful than mocking Get-Command, which recurses into its own mock.
            $saved = Get-Item -Path 'Function:Get-MessageTraceV2'
            Remove-Item -Path 'Function:Get-MessageTraceV2'
            try {
                $probe = Test-ExoQueueConnection
            }
            finally {
                Set-Item -Path 'Function:global:Get-MessageTraceV2' -Value $saved.ScriptBlock
            }

            $probe.Connected | Should -BeFalse
            $probe.Reason    | Should -Match '3\.7\.0 or later'
        }
    }

    Context 'Defect 15: StrictMode safety' {

        It 'handles rows whose Subject property is genuinely absent' {
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow) -NoSubject
            ))

            $script:Common.Output = 'CSV'
            { Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 5 } |
                Should -Not -Throw
        }

        It 'reports truncation rather than throwing when no received time can be read' {
            $global:ExoPages.Add(@(
                [pscustomobject]@{ MessageId = 'm1'; RecipientAddress = 'a@contoso.com'; SenderAddress = 's@contoso.com' }
                [pscustomobject]@{ MessageId = 'm2'; RecipientAddress = 'b@contoso.com'; SenderAddress = 's@contoso.com' }
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2 -WarningAction SilentlyContinue

            $r.Truncated        | Should -BeTrue
            $r.TruncationReason | Should -Be 'CursorUnavailable'
        }
    }

    Context 'Defect 25 and 27: output contract' {

        It 'emits nothing to the pipeline without -PassThru' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $params = $script:Common.Clone()
            $params.Remove('PassThru')
            $out = Get-ExoQueue @params -AgeMinutes 30 -ResultSize 100 -TopSenders 5

            # v1.4.2 leaked Format-Table's FormatStartData objects into the success stream here.
            $out | Should -BeNullOrEmpty
        }

        It 'shows a scalar summary rather than every column by default' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $displayed = @($r.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames)
            $displayed | Should -Contain 'MessageCount'
            $displayed | Should -Contain 'RecipientRowCount'
            $displayed | Should -Contain 'Truncated'
            $displayed | Should -Not -Contain 'Messages'
        }

        It 'sets no global variables' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))
            @('QueueXml', 'TopSendersXml', 'TopRecipientsXml', 'JournalSmtp') |
                ForEach-Object { Remove-Variable -Name $_ -Scope Global -ErrorAction SilentlyContinue }

            $script:Common.Output = 'XML'
            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            foreach ($name in @('QueueXml', 'TopSendersXml', 'TopRecipientsXml', 'JournalSmtp')) {
                Get-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue |
                    Should -BeNullOrEmpty -Because "v1.4.2 set `$global:$name"
            }
        }

        It 'raises a catchable terminating error instead of returning silently' {
            Mock Get-ConnectionInformation { $null }

            $caught = $false
            try { Get-ExoQueue @script:Common -AgeMinutes 30 } catch { $caught = $true }

            $caught | Should -BeTrue
        }
    }

    Context '1.5.1 defect 1: grouping stamped its output onto the caller''s rows' {

        It 'leaves typed source rows untouched' {
            # -Typed matters here and nowhere else. PSObject.Copy() isolates a pscustomobject, so
            # against the ordinary stub rows this test passes even on the broken code. Against a
            # genuine .NET type - which is what Get-MessageTraceV2 returns - Copy() shares the
            # member set, and Add-Member on the copy landed on the source.
            $anchor = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                New-Row -Typed -MessageId 'm1' -Recipient 'a@contoso.com' -ReceivedUtc $anchor.AddSeconds(-1)
                New-Row -Typed -MessageId 'm1' -Recipient 'b@contoso.com' -ReceivedUtc $anchor.AddSeconds(-2)
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $r.MessageCount      | Should -Be 1
            $r.RecipientRowCount | Should -Be 2

            # The three names the grouping adds must exist on the message and on nothing else.
            foreach ($sourceRow in $r.RecipientRows) {
                $sourceRow.PSObject.Properties['RecipientCount'] | Should -BeNullOrEmpty
                $sourceRow.PSObject.Properties['Recipients']     | Should -BeNullOrEmpty
                $sourceRow.PSObject.Properties['ReceivedUtc']    | Should -BeNullOrEmpty
            }

            $r.Messages[0].RecipientCount | Should -Be 2
            $r.Messages[0].Recipients     | Should -Be 'a@contoso.com; b@contoso.com'
        }

        It 'carries every original property onto the message object' {
            # The message is now built from scratch rather than copied, so a property the builder
            # forgets is silently gone - and the export writes whatever the message carries.
            $global:ExoPages.Add(@(New-Row -Typed -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $sourceNames  = @($r.RecipientRows[0].PSObject.Properties.Name)
            $messageNames = @($r.Messages[0].PSObject.Properties.Name)

            @($sourceNames | Where-Object { $_ -notin $messageNames }) | Should -BeNullOrEmpty
            $r.Messages[0].Organization  | Should -Be 'contoso.onmicrosoft.com'
            $r.Messages[0].Size          | Should -Be 2048
            $r.Messages[0].SenderAddress | Should -Be 'sender@contoso.com'
        }
    }

    Context '1.5.1 defect 2: retries were not charged to the throttle budget' {

        It 'charges every request issued, not every page completed' {
            # The budget is the documented 100-per-5-minutes allowance. Charging it once per page
            # meant a run that retried spent four requests and recorded one, so it could cross the
            # real limit while believing it was well inside it.
            $global:ExoThrow.Add('The request was throttled (429).')
            $global:ExoThrow.Add('The request was throttled (429).')
            $global:ExoThrow.Add($null)
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $null = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -MaxRetryCount 4

            # The stub records a call before it throws, so ExoCalls is the count of requests that
            # really reached the service. The budget must agree with it, not with PagesQueried.
            $global:ExoCalls.Count               | Should -Be 3
            $script:ExoQueueRequestLog.Count     | Should -Be 3
        }
    }

    Context '1.5.1 defect 3: a server-side ResultSize cap ended the run at page 1' {

        It 'issues one more query when a short page is still large enough to be a cap' {
            # -ResultSize 2000 with a service that returns 1000 is the documented capped shape. The
            # short page is not proof the queue is empty, so it costs one more query to settle -
            # and that query is real, so it counts toward PagesQueried.
            $global:ExoPages.Add((New-FullPage -Count 1000 -Tag 'p1'))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000 -WarningAction SilentlyContinue

            $global:ExoCalls.Count | Should -Be 2
            $r.PagesQueried        | Should -Be 2
            $r.RecipientRowCount   | Should -Be 1000

            # The probe page came back empty, which is the short-page exit rather than a stall, so
            # the run is complete and says so.
            $r.Truncated           | Should -BeFalse

            # And the probe came back EMPTY, which is proof there was no cap - the short page really
            # was the end. Suspicion is not a finding.
            $r.ResultSizeCapped    | Should -BeFalse
        }

        It 'trusts a short page too small for any cap to explain' {
            # 99 rows is below the smallest page size a service limit could plausibly produce, so
            # nothing could have produced it but an exhausted queue. Probing here would cost a
            # request on every quiet-queue run, which is most of them.
            #
            # This was 999 until 1.5.2, on the reasoning that 1000 is the documented default and so
            # the smallest possible cap. It is not: a role capped at 100, 250 or 500 returned a
            # short page on the first query and was trusted, which is the under-report the probe
            # exists to prevent. See the 1.5.2 context below.
            $global:ExoPages.Add((New-FullPage -Count 99 -Tag 'p1'))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000

            $global:ExoCalls.Count | Should -Be 1
            $r.RecipientRowCount   | Should -Be 99
            $r.ResultSizeCapped    | Should -BeFalse
            $r.Truncated           | Should -BeFalse
        }

        It 'does not spend the extra query once a page has come back at exactly ResultSize' {
            # A full page proves the service honours -ResultSize, so the short page after it is the
            # documented end of the data. Probing anyway would cost a request on nearly every
            # ordinary multi-page run, and this is what stops that.
            $global:ExoPages.Add((New-FullPage -Count 2000 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 1500 -Tag 'p2'))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000 -WarningAction SilentlyContinue

            $global:ExoCalls.Count | Should -Be 2
            $r.RecipientRowCount   | Should -Be 3500

            # The point of the test. EffectivePageSize equal to ResultSize is proof there is no cap,
            # so flagging one here would be self-contradicting - and it is what the first cut of
            # this probe did, in the log line and the trend file, on any run whose last page landed
            # between the 1000 threshold and ResultSize.
            $r.EffectivePageSize | Should -Be 2000
            $r.ResultSizeCapped  | Should -BeFalse
        }

        It 'warns once about a confirmed cap, not once per page' {
            1..4 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 1000 -Tag "p$_")) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000 -MaxQueryPages 4 `
                -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings | Where-Object { $_ -match 'is capping ResultSize' }).Count | Should -Be 1
            @($r.Warnings | Where-Object { $_ -match 'is capping ResultSize' }).Count | Should -Be 1
        }

        It 'reports the largest page it saw and confirms the cap once the probe returns data' {
            # On the first run against a real tenant these two are the direct answer to "is my role
            # capped at 1000", which is otherwise invisible: a capped run looks complete. The second
            # full page of 1000 is what turns the suspicion into a finding - it proves the first
            # short page was not the end of the data.
            $global:ExoPages.Add((New-FullPage -Count 1000 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 1000 -Tag 'p2'))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000 -WarningAction SilentlyContinue

            $r.EffectivePageSize | Should -Be 1000
            $r.ResultSizeCapped  | Should -BeTrue
            $r.RecipientRowCount | Should -Be 2000
        }

        It 'suspects nothing on an ordinary run' {
            $global:ExoPages.Add((New-FullPage -Count 3 -Tag 'p1'))
            $global:ExoPages.Add(@(New-Row -MessageId 'last' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-20)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3

            $r.EffectivePageSize | Should -Be 3
            $r.ResultSizeCapped  | Should -BeFalse
        }
    }

    Context '1.5.2: the cap probe missed every cap below the documented default' {

        It 'detects a service capping at 250 while 5000 was requested' {
            # The regression this whole context exists for. Until 1.5.2 the probe was skipped for any
            # page under 1000 rows, so a role capped at 250 returned one short page, was read as an
            # exhausted queue, and reported 250 as the queue depth with Truncated=False - the exact
            # 1.4.x failure the probe was introduced to end, surviving inside its own fix.
            $global:ExoPages.Add((New-FullPage -Count 250 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 250 -Tag 'p2'))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 5000 -WarningAction SilentlyContinue

            # It kept paging instead of stopping at 250.
            $r.RecipientRowCount  | Should -Be 500
            $r.EffectivePageSize  | Should -Be 250
            $r.ResultSizeCapped   | Should -BeTrue
            $r.Truncated          | Should -BeFalse
        }

        It 'says so in the warning stream and on the result object' {
            $global:ExoPages.Add((New-FullPage -Count 100 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 100 -Tag 'p2'))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 5000 `
                -WarningVariable warnings -WarningAction SilentlyContinue

            @($warnings  | Where-Object { $_ -match 'is capping ResultSize' }).Count | Should -Be 1
            @($r.Warnings | Where-Object { $_ -match 'is capping ResultSize' }).Count | Should -Be 1
        }

        It 'writes the cap into the trend log rather than a bare count' {
            $global:ExoPages.Add((New-FullPage -Count 250 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 250 -Tag 'p2'))
            $global:ExoPages.Add(@())

            $path = Join-Path $TestDrive 'cap152'
            $r = Get-ExoQueue -AgeMinutes 30 -ResultSize 5000 -OutputPath $path `
                -Output None -Force -Quiet -PassThru -WarningAction SilentlyContinue `
                -ThrottleDelayMilliseconds 0 -RetryDelaySeconds 0

            Get-Content $r.LogPath -Raw | Should -Match 'EffectivePageSize=250\(CAPPED\)'
        }

        It 'still costs a quiet queue exactly one query' {
            # The reason the threshold is not simply zero. A queue below it is not a shape any
            # service limit produces, and probing it would put a second request on the most
            # common run of all.
            $global:ExoPages.Add((New-FullPage -Count 12 -Tag 'p1'))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 5000

            $global:ExoCalls.Count | Should -Be 1
            $r.RecipientRowCount   | Should -Be 12
            $r.Truncated           | Should -BeFalse
        }

        It 'reports the running version' {
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30

            # Compared against the script's own variable, not a literal. A literal here fails on
            # every bump while testing nothing about the behaviour this context is named for -
            # which it did, on the very next release.
            $r.Version | Should -Be $ExoQueueVersion
            $r.Version | Should -Not -BeNullOrEmpty
        }
    }

    Context '1.6.0: the two questions on-prem triage asks first' {

        It 'groups queued deliveries by recipient domain' {
            # The nearest available answer to NextHopDomain. One destination deferring is what this
            # exists to surface, so the deferring domain must come first and carry the weight.
            $anchor = [datetime]::UtcNow.AddMinutes(-30)
            $global:ExoPages.Add(@(
                1..12 | ForEach-Object { New-Row -MessageId "d$_" -Recipient "u$_@backedup.example" -ReceivedUtc $anchor.AddSeconds(-$_) }
                1..3  | ForEach-Object { New-Row -MessageId "o$_" -Recipient "u$_@fine.example"     -ReceivedUtc $anchor.AddSeconds(-$_) }
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 60 -ResultSize 100

            $r.TopDestinations.Count      | Should -BeGreaterThan 1
            $r.TopDestinations[0].Domain     | Should -Be 'backedup.example'
            $r.TopDestinations[0].Deliveries | Should -Be 12
            $r.TopDestinations[1].Domain     | Should -Be 'fine.example'
            $r.TopDestinations[1].Deliveries | Should -Be 3
        }

        It 'lower-cases the domain so one destination is one row' {
            $anchor = [datetime]::UtcNow.AddMinutes(-10)
            $global:ExoPages.Add(@(
                New-Row -MessageId 'a' -Recipient 'x@Contoso.Example' -ReceivedUtc $anchor
                New-Row -MessageId 'b' -Recipient 'y@contoso.example' -ReceivedUtc $anchor
                New-Row -MessageId 'c' -Recipient 'z@CONTOSO.EXAMPLE' -ReceivedUtc $anchor
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 60 -ResultSize 100

            @($r.TopDestinations).Count      | Should -Be 1
            $r.TopDestinations[0].Domain     | Should -Be 'contoso.example'
            $r.TopDestinations[0].Deliveries | Should -Be 3
        }

        It 'buckets an address with no domain visibly rather than dropping it' {
            $anchor = [datetime]::UtcNow.AddMinutes(-10)
            $global:ExoPages.Add(@(
                New-Row -MessageId 'a' -Recipient 'malformed' -ReceivedUtc $anchor
                New-Row -MessageId 'b' -Recipient 'ok@fine.example' -ReceivedUtc $anchor
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 60 -ResultSize 100

            @($r.TopDestinations.Domain) | Should -Contain '(no domain)'
            # Nothing is lost: the deliveries still add up to what was retrieved.
            (@($r.TopDestinations.Deliveries) | Measure-Object -Sum).Sum | Should -Be $r.RecipientRowCount
        }

        It 'reports oldest, median and newest queue age' {
            # A count cannot distinguish a burst from an outage. This is what does.
            $now = [datetime]::UtcNow
            $global:ExoPages.Add(@(
                New-Row -MessageId 'old' -Recipient 'a@x.example' -ReceivedUtc $now.AddMinutes(-60)
                New-Row -MessageId 'mid' -Recipient 'b@x.example' -ReceivedUtc $now.AddMinutes(-30)
                New-Row -MessageId 'new' -Recipient 'c@x.example' -ReceivedUtc $now.AddMinutes(-10)
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 120 -ResultSize 100

            $r.QueueAge.Counted       | Should -Be 3
            $r.QueueAge.Undated       | Should -Be 0
            $r.QueueAge.OldestMinutes | Should -BeGreaterThan 55
            $r.QueueAge.MedianMinutes | Should -BeGreaterThan 25
            $r.QueueAge.MedianMinutes | Should -BeLessThan 35
            $r.QueueAge.NewestMinutes | Should -BeLessThan 15
        }

        It 'counts undated messages separately instead of skipping them' {
            $now = [datetime]::UtcNow
            $rows = @(
                New-Row -MessageId 'dated' -Recipient 'a@x.example' -ReceivedUtc $now.AddMinutes(-20)
                [pscustomobject]@{ MessageId = 'undated'; RecipientAddress = 'b@x.example'; SenderAddress = 's@x.example'; Status = 'Pending'; Subject = 'no time' }
            )
            $global:ExoPages.Add($rows)

            $r = Get-ExoQueue @script:Common -AgeMinutes 120 -ResultSize 100 -WarningAction SilentlyContinue

            $r.QueueAge.Counted | Should -Be 1
            $r.QueueAge.Undated | Should -Be 1
        }

        It 'describes an empty queue without throwing' {
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 60

            @($r.TopDestinations).Count | Should -Be 0
            $r.QueueAge                 | Should -BeNullOrEmpty
        }
    }

    Context '1.5.1 defect 5: the run folder came from query completion, not run start' {

        It 'stamps the run from its start, not from when the query finished' {
            # A run that starts at 23:58 and pages for four minutes belongs to the day it started
            # and to the window it reports. Reading the clock afterwards filed it under the
            # following day and stamped the log with a time outside the run's own window.
            #
            # The sleep is what makes this a test rather than a tautology: the log timestamp has
            # second resolution, and the reported window end IS the run-start reading, so a stamp
            # taken after the query cannot agree with it once the query has taken two seconds.
            $global:ExoPages.Add({
                param($StartDate, $EndDate, $StartingRecipientAddress)
                Start-Sleep -Milliseconds 2100
                New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)
            })

            $script:Common.Output = 'CSV'
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $invariant = [System.Globalization.CultureInfo]::InvariantCulture
            $runStart  = $r.EndUtc.ToLocalTime()

            $logLine = @(Get-Content -LiteralPath $r.LogPath)[-1]
            $logLine | Should -BeLike ('{0} - *' -f $runStart.ToString('yyyy-MM-dd HH:mm:ss', $invariant))

            # The same reading names the folder and the file, so nothing about the run is filed
            # under a different minute from the rest of it.
            $dayName = Split-Path -Path (Split-Path -Path $r.OutputFiles[0] -Parent) -Leaf
            $dayName | Should -Be $runStart.ToString('dd-MMM-yyyy', $invariant)
            $r.OutputFiles[0] | Should -BeLike ('*{0}*' -f $runStart.ToString('dd-MMM-yyyy--HHmm', $invariant))
        }
    }

    Context '1.5.1 defects 7 and 8: warnings that never left the console, and -Output None' {

        It 'records a post-query warning on the result object' {
            # Warnings raised after the trace returned - grid truncation, formula risk, a missing
            # Excel - went to the console only, which is exactly the audience not watching during
            # an escalation. A subject beginning with = is the cheapest of the three to provoke.
            $global:ExoPages.Add(@(
                New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow) -Subject '=cmd|calc'
            ))

            $script:Common.Output = 'CSV'
            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WarningAction SilentlyContinue

            @($r.Warnings | Where-Object { $_ -match 'evaluated as formulas' }).Count | Should -Be 1
        }

        It 'rejects -Output None combined with a real format' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow)))

            $script:Common.Remove('Output')
            { Get-ExoQueue @script:Common -AgeMinutes 30 -Output None, CSV } |
                Should -Throw '*-Output None cannot be combined*'

            # It fails before querying, not after writing the CSV it was told not to write.
            $global:ExoCalls.Count | Should -Be 0
        }
    }

    Context '1.5.1 sweep: -WhatIf wrote, and declined files reported themselves as saved' {

        It 'creates nothing at all under -WhatIf' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))
            $script:Common.Output = 'CSV'
            $root = Join-Path -Path $TestDrive -ChildPath 'whatif'
            $script:Common.OutputPath = $root

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WhatIf

            # The dated folder and the trend log were unguarded while every export was guarded. The
            # trend log is the one file that is appended rather than replaced, so a -WhatIf run
            # permanently added a row to the history being trended.
            Test-Path -LiteralPath $root | Should -BeFalse
            $r.OutputFiles.Count          | Should -Be 0
        }

        It 'does not announce a file it declined to write' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))
            $script:Common.Output = 'CSV', 'XML'
            $script:Common.Remove('Quiet')
            $script:Common.OutputPath = Join-Path -Path $TestDrive -ChildPath 'declined'

            # Write-Ui goes to Write-Host, so Out-String on the whole invocation is what captures it.
            $text = & { Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WhatIf } 6>&1 | Out-String

            $text | Should -Not -Match 'CSV file with All Results saved to'
            $text | Should -Not -Match 'XML file saved to'
        }
    }

    Context '1.5.1 sweep: two runs in the same minute overwrote each other' {

        It 'falls back to a numbered name instead of replacing the earlier export' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'clobber'
            $script:Common.OutputPath = $folder
            $script:Common.Output = 'CSV'

            $global:ExoPages.Add(@(New-Row -MessageId 'first' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))
            $first = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $global:ExoPages.Clear()
            $global:ExoPages.Add(@(
                New-Row -MessageId 'second-a' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-4)
                New-Row -MessageId 'second-b' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-3)
            ))
            $second = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            # The file stamp has minute resolution, so both runs want the same name. Re-running
            # immediately with a narrower window is normal triage, which made the file most likely
            # to be destroyed the one taken seconds earlier. Asserted on content rather than on the
            # "(2)" suffix, because the two runs could straddle a minute boundary and get distinct
            # stamps honestly - Get-ExoQueueUnusedSuffix is pinned directly below.
            $second.OutputFiles[0] | Should -Not -Be $first.OutputFiles[0]
            @(Import-Csv -LiteralPath $first.OutputFiles[0]).Count  | Should -Be 1
            @(Import-Csv -LiteralPath $second.OutputFiles[0]).Count | Should -Be 2
        }

        It 'numbers from 2 and skips names already taken' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'unused'
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
            $target = Join-Path -Path $folder -ChildPath 'ExoQueue - 13-Aug-2026--1432.csv'

            Get-ExoQueueUnusedSuffix -Path @($target) | Should -Be ''

            Set-Content -LiteralPath $target -Value 'x' -Encoding UTF8
            Get-ExoQueueUnusedSuffix -Path @($target) | Should -Be ' (2)'

            Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'ExoQueue - 13-Aug-2026--1432 (2).csv') `
                -Value 'x' -Encoding UTF8
            Get-ExoQueueUnusedSuffix -Path @($target) | Should -Be ' (3)'
        }

        It 'keeps appending to the one trend log rather than numbering it' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'trend'
            $script:Common.OutputPath = $folder

            $global:ExoPages.Add(@(New-Row -MessageId 'a' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))
            $first = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $global:ExoPages.Clear()
            $global:ExoPages.Add(@(New-Row -MessageId 'b' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))
            $second = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            $second.LogPath | Should -Be $first.LogPath
            @(Get-Content -LiteralPath $second.LogPath).Count | Should -Be 2
        }
    }

    Context '1.5.1 sweep: one unreadable row disabled timestamps for the whole run' {

        It 'finds the received property from a later row when the first has none' {
            $anchor = [datetime]::UtcNow
            $rows = @(
                New-Row -MessageId 'm1' -ReceivedUtc $anchor.AddMinutes(-5)
                New-Row -MessageId 'm2' -ReceivedUtc $anchor.AddMinutes(-9)
                New-Row -MessageId 'm3' -ReceivedUtc $anchor.AddMinutes(-7)
            )
            # A row that carries no Received at all. Sampling only Row[0] used to blank ReceivedUtc
            # for every message in the run, which silently turned the oldest-first ordering into
            # arrival order - no warning, no missing column, just the wrong order.
            $rows = @([pscustomobject]@{ MessageId = 'm0'; RecipientAddress = 'r0@contoso.com' }) + $rows

            $grouped = @(Group-ExoQueueMessage -Row $rows)

            @($grouped | Where-Object { $null -ne $_.ReceivedUtc }).Count | Should -Be 3
        }

        It 'keeps messages with no received time off the head of the oldest-first list' {
            $anchor = [datetime]::UtcNow
            $rows = @(
                [pscustomobject]@{ MessageId = 'undated'; RecipientAddress = 'r0@contoso.com' }
                New-Row -MessageId 'oldest' -ReceivedUtc $anchor.AddMinutes(-9)
                New-Row -MessageId 'newest' -ReceivedUtc $anchor.AddMinutes(-1)
            )

            $grouped = @(Group-ExoQueueMessage -Row $rows)

            # Sort-Object puts nulls FIRST ascending, so an unreadable timestamp presented as the
            # most stuck mail in the tenant, at the top of the grid and the top of the CSV.
            $grouped[0].MessageId | Should -Be 'oldest'
            $grouped[1].MessageId | Should -Be 'newest'
            $grouped[2].MessageId | Should -Be 'undated'
        }

        It 'reports undated messages instead of letting the ordering degrade quietly' {
            $global:ExoPages.Add(@(
                [pscustomobject]@{ MessageId = 'u1'; RecipientAddress = 'r1@contoso.com'; Received = [datetime]::UtcNow }
                [pscustomobject]@{ MessageId = 'u2'; RecipientAddress = 'r2@contoso.com' }
            ))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WarningAction SilentlyContinue

            # Matched on the tail of the sentence: the cursor-unavailable warning this row also
            # triggers says "no readable received time" too.
            @($r.Warnings | Where-Object { $_ -match 'listed last rather than sorted' }).Count | Should -Be 1
        }
    }

    Context '1.5.1 sweep: -Quiet stopped on a prompt it had hidden' {

        It 'refuses rather than blocking when the question cannot be shown' {
            # The -AgeDays question is printed through Write-Ui, which -Quiet suppresses, so
            # Read-Host stopped an unattended run at a bare colon with nothing on screen to explain
            # it. -Force is what normally answers it, so it has to come off for this test; reaching
            # Read-Host would hang the suite rather than fail it.
            $script:Common.Remove('Force')

            { Get-ExoQueue @script:Common -AgeDays 1 -ResultSize 100 -WarningAction SilentlyContinue } |
                Should -Throw '*-Quiet cannot show*'

            $global:ExoCalls.Count | Should -Be 0
        }

        It 'still answers the question itself under -Force' {
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddHours(-2)))

            $r = Get-ExoQueue @script:Common -AgeDays 1 -ResultSize 100 -WarningAction SilentlyContinue

            $r.MessageCount | Should -Be 1
        }
    }

    Context '1.5.1 sweep: a run that finished on its last permitted page called itself INCOMPLETE' {

        It 'does not report truncation when the data ran out on the final permitted page' {
            # The loop leaves because the service returned a short page, but it leaves with $page
            # equal to the limit, and the post-loop check tested only that number. -MaxQueryPages 1
            # therefore mislabelled every run it was used on.
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -MaxQueryPages 1

            $r.PagesQueried     | Should -Be 1
            $r.Truncated        | Should -BeFalse
            $r.TruncationReason | Should -BeNullOrEmpty
        }

        It 'does not report truncation when a multi-page run exhausts on the last page it may query' {
            # The shape that makes this more than a corner case: two pages permitted, page 2 comes
            # back short, so the queue is genuinely empty AND the limit is genuinely reached.
            $global:ExoPages.Add((New-FullPage -Count 3 -Tag 'p1'))
            $global:ExoPages.Add(@(New-Row -MessageId 'last' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-20)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3 -MaxQueryPages 2

            $r.PagesQueried      | Should -Be 2
            $r.RecipientRowCount | Should -Be 4
            $r.Truncated         | Should -BeFalse
        }

        It 'still reports the page limit when it really did cut the run short' {
            # Every page full, so nothing ever signals exhaustion and the limit is the only reason
            # the run stopped. This is the case the flag must not swallow.
            1..3 | ForEach-Object { $global:ExoPages.Add((New-FullPage -Count 3 -Tag "p$_")) }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 3 -MaxQueryPages 2 `
                -WarningAction SilentlyContinue

            $r.PagesQueried     | Should -Be 2
            $r.Truncated        | Should -BeTrue
            $r.TruncationReason | Should -Be 'MaxQueryPages'
        }

        It 'does not write the false verdict into the trend log' {
            # The trend log is the artefact nobody goes back and corrects, so a wrong Truncated here
            # outlives the run that produced it.
            $script:Common.OutputPath = Join-Path -Path $TestDrive -ChildPath 'lastpage'
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -MaxQueryPages 1

            @(Get-Content -LiteralPath $r.LogPath)[-1] | Should -Match 'Truncated=False'
        }
    }

    Context '1.5.1 sweep: a probe page of nothing but duplicates was read as a cap' {

        It 'does not confirm a cap from rows the run had already seen' {
            # The probe exists to settle whether a short page was the end of the data. A service
            # that replays the page just returned answers "no" in rows and "nothing new" in
            # content, and judging it on the raw count reported a cap on that - the one value
            # .NOTES sends an operator to read when asking whether their role is capped.
            $anchor = [datetime]::UtcNow
            $page   = @(1..1000 | ForEach-Object {
                New-Row -MessageId ('m{0}' -f $_) -Recipient ('r{0}@contoso.com' -f $_) `
                    -ReceivedUtc $anchor.AddSeconds(-$_)
            })
            $global:ExoPages.Add($page)
            $global:ExoPages.Add($page)

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000 `
                -WarningVariable warnings -WarningAction SilentlyContinue

            $r.ResultSizeCapped  | Should -BeFalse
            $r.RecipientRowCount | Should -Be 1000
            $r.DuplicateRows     | Should -Be 1000

            # The replay is a stall, and that is what the run should say it stopped for.
            $r.TruncationReason | Should -Be 'NoNewRows'
            @($warnings | Where-Object { $_ -match 'is capping ResultSize' }).Count | Should -Be 0
        }

        It 'still confirms a cap when the probe brings back rows that are new' {
            # The regression guard for the fix above: moving the test below the dedup loop must not
            # cost the detection it was written for.
            $global:ExoPages.Add((New-FullPage -Count 1000 -Tag 'p1'))
            $global:ExoPages.Add((New-FullPage -Count 1000 -Tag 'p2'))
            $global:ExoPages.Add(@())

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 2000 -WarningAction SilentlyContinue

            $r.ResultSizeCapped  | Should -BeTrue
            $r.EffectivePageSize | Should -Be 1000
        }
    }

    Context '1.5.1 sweep: same-timestamp messages came back in scrambled order' {

        It 'keeps arrival order among messages sharing one timestamp' {
            # Sort-Object is not a stable sort on 5.1 and has no -Stable: 40 rows on one instant
            # came back 27, 26, 28, 30, 29, 22, 21 ... Nothing in the data explains it, so two runs
            # over an unchanged queue reordered the CSV and the grid for no visible reason.
            $instant = [datetime]::SpecifyKind([datetime]'2026-08-14T10:00:00', [System.DateTimeKind]::Utc)
            $rows = @(1..40 | ForEach-Object {
                New-Row -MessageId ('m{0:d2}' -f $_) -Recipient ('r{0}@contoso.com' -f $_) -ReceivedUtc $instant
            })

            $grouped = @(Group-ExoQueueMessage -Row $rows)

            @($grouped.MessageId) | Should -Be @(1..40 | ForEach-Object { 'm{0:d2}' -f $_ })
        }

        It 'still sorts oldest first, with ties in arrival order and undated at the tail' {
            $instant = [datetime]::SpecifyKind([datetime]'2026-08-14T10:00:00', [System.DateTimeKind]::Utc)
            $rows = @(
                [pscustomobject]@{ MessageId = 'undated'; RecipientAddress = 'r0@contoso.com' }
                New-Row -MessageId 'tie-b'  -ReceivedUtc $instant
                New-Row -MessageId 'newest' -ReceivedUtc $instant.AddMinutes(5)
                New-Row -MessageId 'tie-a'  -ReceivedUtc $instant
                New-Row -MessageId 'oldest' -ReceivedUtc $instant.AddMinutes(-5)
            )

            $grouped = @(Group-ExoQueueMessage -Row $rows)

            # tie-b before tie-a is the assertion, not an accident of naming: it arrived first.
            @($grouped.MessageId) | Should -Be @('oldest', 'tie-b', 'tie-a', 'newest', 'undated')
        }
    }

    Context '1.5.1 sweep: -Quiet opened a GridView on an unattended desktop' {

        BeforeEach {
            $script:Common.Output = 'GridView'
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))
        }

        It 'skips the grid and says so where -Quiet cannot hide it' {
            # -Output defaults to GridView and -Quiet is what an unattended run passes, so the
            # combination the help points a scheduled task at opened a window nobody was watching.
            # Mocked as well as asserted: a regression here would open a real window mid-suite.
            Mock Out-GridView { }

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WarningAction SilentlyContinue

            Should -Invoke Out-GridView -Times 0 -Exactly
            @($r.Warnings | Where-Object { $_ -match 'Quiet suppresses the GridView' }).Count | Should -Be 1
        }

        It 'still shows the grid when someone is there to look at it' {
            Mock Out-GridView { }
            $script:Common.Remove('Quiet')

            # Write-Ui goes to Write-Host, so Out-String on the whole invocation is what captures it.
            $text = & { Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WarningAction SilentlyContinue } 6>&1 |
                Out-String

            Should -Invoke Out-GridView -Times 1 -Exactly
            $text | Should -Match 'Current Queue:'
        }
    }

    Context '1.5.1 sweep: one file of a run was numbered and the rest were not' {

        It 'moves the whole set when any single name is taken' {
            $folder = Join-Path -Path $TestDrive -ChildPath 'suffixset'
            New-Item -Path $folder -ItemType Directory -Force | Out-Null
            $bare = Join-Path -Path $folder -ChildPath 'ExoQueue - 13-Aug-2026--1432.csv'
            $top  = Join-Path -Path $folder -ChildPath 'ExoQueue - 13-Aug-2026--1432-TopSenders.csv'

            # Only the Top-N name is taken. Resolved one file at a time, the pair came back
            # undecorated and " (2)", and the two halves of one run stopped corresponding - which
            # is the only thing the shared name was ever for.
            Set-Content -LiteralPath $top -Value 'x' -Encoding UTF8

            Get-ExoQueueUnusedSuffix -Path @($bare, $top) | Should -Be ' (2)'
        }

        It 'gives every file of one run the same suffix' {
            $script:Common.OutputPath = Join-Path -Path $TestDrive -ChildPath 'suffixrun'
            $script:Common.Output     = 'CSV'
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))

            $first = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 5 -TopRecipients 5
            $first.OutputFiles.Count | Should -Be 3

            # Clearing only the All Results file is the shape per-file resolution got wrong: the
            # second run took the freed name for that one and numbered the other two. Asserted on
            # agreement rather than on " (2)", because the two runs may straddle a minute boundary
            # and earn distinct stamps honestly - in which case they agree on no suffix at all.
            Remove-Item -LiteralPath @($first.OutputFiles | Where-Object { $_ -notmatch '-Top' })

            $second = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -TopSenders 5 -TopRecipients 5

            $suffixes = @($second.OutputFiles | ForEach-Object {
                if ($_ -match ' \((\d+)\)\.csv$') { $Matches[1] } else { '' }
            })
            $suffixes.Count                          | Should -Be 3
            @($suffixes | Select-Object -Unique).Count | Should -Be 1
        }
    }

    Context '1.5.1 sweep: -WhatIf named a trend log it had not written' {

        It 'reports no log path when the write was declined' {
            $script:Common.OutputPath = Join-Path -Path $TestDrive -ChildPath 'whatiflog'
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100 -WhatIf

            # OutputFiles already listed only what was written. LogPath still named the file the run
            # had just decided not to create, so a caller that read it got a file-not-found.
            $r.LogPath | Should -BeNullOrEmpty
        }

        It 'still reports the log path on an ordinary run' {
            $script:Common.OutputPath = Join-Path -Path $TestDrive -ChildPath 'reallog'
            $global:ExoPages.Add(@(New-Row -MessageId 'm1' -ReceivedUtc ([datetime]::UtcNow).AddMinutes(-5)))

            $r = Get-ExoQueue @script:Common -AgeMinutes 30 -ResultSize 100

            Test-Path -LiteralPath $r.LogPath | Should -BeTrue
        }
    }

    Context '1.5.1 performance' {

        It 'groups 20,000 rows well inside a stalled-console threshold' {
            # A generous ceiling, not a benchmark: 1.5.0 took roughly 60 s on this shape, so a
            # regression that reinstates the per-row helper calls fails here while ordinary machine
            # noise does not. The A/B measurement lives in the changelog.
            $anchor = [datetime]::UtcNow
            $rows   = [System.Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le 20000; $i++) {
                $rows.Add((New-Row -MessageId ('m{0}' -f [Math]::Ceiling($i / 2)) `
                    -From      ('s{0}@contoso.com' -f ($i % 50)) `
                    -Recipient ('r{0}@contoso.com' -f $i) `
                    -ReceivedUtc $anchor.AddSeconds(-$i)))
            }

            $elapsed = Measure-Command { $script:Grouped = @(Group-ExoQueueMessage -Row $rows.ToArray()) }

            $script:Grouped.Count           | Should -Be 10000
            $script:Grouped[0].RecipientCount | Should -Be 2
            $elapsed.TotalSeconds           | Should -BeLessThan 20
        }
    }

    Context 'Hygiene' {

        It 'does not use constructs this codebase avoids' {
            $text = Get-Content -LiteralPath $script:ScriptPath -Raw

            $text | Should -Not -Match '#region'
            $text | Should -Not -Match 'function\s+global:'
            $text | Should -Not -Match '\?\?'          # null-coalescing is PowerShell 7 only
            $text | Should -Not -Match '-Parallel'     # ForEach-Object -Parallel is PowerShell 7 only
        }

        It 'does not leave the caller in StrictMode after dot-sourcing' {
            $leaked = & {
                . $script:ScriptPath
                try { if ($neverAssignedAnywhere -like '*x*') { } ; $false } catch { $true }
            }
            $leaked | Should -BeFalse
        }

        It 'documents every parameter and provides examples' {
            $help = Get-Help Get-ExoQueue -Full

            @($help.Examples.Example).Count | Should -BeGreaterOrEqual 4

            $documented = @($help.Parameters.Parameter | Where-Object { $_.Description } | ForEach-Object { $_.Name })
            $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                      [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
            $actual = @((Get-Command Get-ExoQueue).Parameters.Keys | Where-Object { $_ -notin $common })

            @($actual | Where-Object { $_ -notin $documented }) | Should -BeNullOrEmpty
        }

        It 'exposes the four expected parameter sets' {
            @((Get-Command Get-ExoQueue).ParameterSets.Name) |
                Should -Be @('AgeMinutes', 'AgeHours', 'AgeDays', 'DateRange')
        }
    }
}

Describe 'Get-ExoQueue static analysis' {

    # Deliberately a separate Describe with no mocks in scope. Pester installs each mock as a
    # function named PesterMock_script_<Command>_<guid>, which makes PSScriptAnalyzer report every
    # mocked cmdlet in the script under test as an alias of that generated name.
    It 'passes PSScriptAnalyzer' {
        $findings = @(Invoke-ScriptAnalyzer -Path $script:ScriptPath -Severity Error, Warning -ExcludeRule @(
            # The colorised host output is this tool's interface, not diagnostics. Converting it to
            # Write-Verbose would remove the thing an operator reads during an escalation.
            'PSAvoidUsingWriteHost'
        ))

        if ($findings.Count -gt 0) {
            $findings | ForEach-Object { Write-Host ("  {0}:{1} {2}" -f $_.RuleName, $_.Line, $_.Message) }
        }
        $findings.Count | Should -Be 0
    }
}
