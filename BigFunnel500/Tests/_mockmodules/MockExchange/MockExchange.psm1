# Mock Exchange surface, packaged as a module so PowerShell command
# auto-loading resolves these in place of the real cmdlets. That lets the
# monitor run as the top-level -File script, the way a scheduled task invokes
# it, so its exit codes are the process exit codes.
#
# The size objects mimic Unlimited<ByteQuantifiedSize> as measured on
# Exchange SE RTM 15.2.2562.17: a wrapper carrying IsUnlimited and Value,
# where ToBytes() exists only on the inner value, never on the wrapper.

function New-MockSize {
    param([int64]$Bytes, [switch]$Unlimited, [switch]$Garbage)

    $wrapper = New-Object psobject

    if ($Unlimited) {
        $wrapper | Add-Member NoteProperty IsUnlimited $true
        $wrapper | Add-Member NoteProperty Value $null
        $wrapper | Add-Member ScriptMethod ToString { 'Unlimited' } -Force
        return $wrapper
    }

    if ($Garbage) {
        $wrapper | Add-Member NoteProperty IsUnlimited $false
        $inner = New-Object psobject
        $inner | Add-Member ScriptMethod ToString { 'not a size at all' } -Force
        $wrapper | Add-Member NoteProperty Value $inner
        $wrapper | Add-Member ScriptMethod ToString { 'not a size at all' } -Force
        return $wrapper
    }

    $gb   = [math]::Round($Bytes / 1GB, 3)
    $text = '{0} GB ({1:N0} bytes)' -f $gb, $Bytes

    $inner = New-Object psobject
    $inner | Add-Member NoteProperty _b $Bytes
    $inner | Add-Member ScriptMethod ToBytes { $this._b } -Force
    $inner | Add-Member ScriptMethod ToString { $text }.GetNewClosure() -Force

    $wrapper | Add-Member NoteProperty IsUnlimited $false
    $wrapper | Add-Member NoteProperty Value $inner
    $wrapper | Add-Member ScriptMethod ToString { $text }.GetNewClosure() -Force
    return $wrapper
}

function Get-MailboxDatabase {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Identity, [switch]$Status)

    $names = @('MDB01', 'MDB02', 'MDB03')
    $owner = if ($env:MOCK_ACTIVE_ELSEWHERE -eq '1') { 'EXCH-99.example.com' } else { $env:COMPUTERNAME + '.example.com' }

    if ($Identity) {
        if ($names -notcontains $Identity) {
            throw ("The operation couldn't be performed because object '" + $Identity + "' couldn't be found.")
        }
        return [pscustomobject]@{ Name = $Identity; Mounted = $null; MountedOnServer = $owner }
    }

    # Mounted is left $null deliberately, reproducing the passive-DAG-node
    # behaviour measured in the lab. MountedOnServer is populated from any node.
    foreach ($n in $names) {
        [pscustomobject]@{ Name = $n; Mounted = $null; MountedOnServer = $owner }
    }
}

function Get-MailboxStatistics {
    [CmdletBinding()]
    param([string]$Database, [string]$Identity, [string]$Server)

    if ($env:MOCK_FAIL_DB -and $Database -eq $env:MOCK_FAIL_DB) {
        throw "The Microsoft Exchange Information Store service on server 'EXCH-01.example.com' is inaccessible."
    }

    # A database that is mounted and reachable but holds no mailboxes: newly
    # created, or one every mailbox has already been moved off. The collection
    # succeeds and returns nothing, which is a different outcome from a database
    # that failed, and the only way to reach the export stage with zero rows.
    if ($env:MOCK_EMPTY -eq '1') { return }

    # Simulates a slow store so the run-budget gate has something to trip on.
    if ($env:MOCK_SLOW_MS) { Start-Sleep -Milliseconds ([int]$env:MOCK_SLOW_MS) }

    # Growth multiplier lets a later run simulate elapsed table growth, or
    # remediation when set below 1.0.
    $mult = 1.0
    if ($env:MOCK_GROWTH) { $mult = [double]$env:MOCK_GROWTH }

    # Index-health counters. Zero unless a switch is set, so the healthy-run
    # tests stay quiet and the health assertions are unambiguous.
    $notIndexed = 0
    $stale      = 0
    $corrupted  = 0
    if ($env:MOCK_STALE -eq '1')   { $notIndexed = 50; $stale = 25 }
    if ($env:MOCK_CORRUPT -eq '1') { $corrupted  = 3 }

    # Reproduces the state measured on Exchange Server SE 15.2.2562.17: a
    # mailbox BigFunnel reports as fully indexed whose posting list table reads
    # exactly 0 B, with the index accounted for in the POI and filter tables
    # instead. 'all' puts the whole population in that state, which is what the
    # lab showed; 'partial' leaves some mailboxes reporting normally, which is
    # what a mid-upgrade DAG would look like.
    $notPopulated = $env:MOCK_NOTPOPULATED

    # Name carries non-ASCII characters, built from code points so this file
    # stays pure ASCII on disk. Tests that Export-Csv preserves them.
    $nonAscii = 'Zo' + [char]0xE9 + ' Bj' + [char]0xF6 + 'rk'

    $spec = @(
        @{ N = 'Ana Ilic';        B = 2.40GB; G = $true  },   # already critical
        @{ N = 'Bo Persson';      B = 1.80GB; G = $true  },   # warning
        @{ N = $nonAscii;         B = 1.55GB; G = $true  },   # climbing past warning
        @{ N = 'Emerging Mbx';    B = 1.20GB; G = $true  },   # stays Normal, trends into Critical
        @{ N = 'Shared Helpdesk'; B = 0.20GB; G = $false },   # normal, flat
        @{ N = 'Unlimited Mbx';   B = 0;      U = $true  },   # Unlimited value
        @{ N = 'Garbage Mbx';     B = 0;      X = $true  }    # unparseable value
    )

    # A population large and spread out enough for percentiles to mean
    # something. The fixed seven above are too few and too clustered: their P95
    # and P99 land on the same value, which is the adaptive fallback case, not
    # the adaptive case.
    if ($env:MOCK_BULK) {
        $n = [int]$env:MOCK_BULK
        for ($k = 1; $k -le $n; $k++) {
            $spec += @{ N = ('Bulk Mbx {0:d3}' -f $k); B = [int64]((0.5 + ($k * 0.15)) * 1GB); G = $false }
        }
    }

    # Stable per-database hex prefix so GUIDs are valid and repeatable across
    # runs, which the growth-trending join depends on.
    $prefix = '{0:x8}' -f ([Math]::Abs($Database.GetHashCode()) -band 0x7FFFFFFF)

    $i = 0
    foreach ($s in $spec) {
        $i++
        $size = if ($s.ContainsKey('U'))     { New-MockSize -Unlimited }
                elseif ($s.ContainsKey('X')) { New-MockSize -Garbage }
                else {
                    $b = if ($s.G) { [int64]($s.B * $mult) } else { [int64]$s.B }
                    New-MockSize -Bytes $b
                }

        # Zero the posting list table without touching the index counters, so
        # the mailbox still looks indexed from every other angle. Under
        # 'partial' only the first three mailboxes are affected, leaving the
        # critical and warning rows to prove the two states coexist.
        if ($notPopulated -and -not $s.ContainsKey('U') -and -not $s.ContainsKey('X')) {
            if ($notPopulated -eq 'all' -or ($notPopulated -eq 'partial' -and $i -ge 3)) {
                $size = New-MockSize -Bytes 0
            }
        }

        # Where the index lives on a build that leaves the posting list table
        # empty. Non-zero on every row, healthy or not: POI and filter data
        # exist wherever there is an index, so a monitor that reads them only
        # in the broken case would never be exercised on the normal path.
        #
        # Scaled by the same growth multiplier as the posting list table, and on
        # the same rows. On a build where the posting list table is pinned at
        # 0 B these tables are the only place growth can appear at all, so a mock
        # that held them constant would leave the fallback metric untestable:
        # every delta would be zero, no projection could ever be produced, and a
        # monitor that silently ranked nothing would look like a monitor that
        # correctly found nothing.
        #
        # Sized per mailbox as well, because holding the base constant was very
        # nearly as bad. Identical bases plus an identical multiplier give every
        # growing mailbox an identical delta, so the fallback ranking came back a
        # twelve-way tie and a test asserting only that a ranking appeared could
        # not tell an ordering from an arbitrary one. The scale is monotonic in
        # $i so the expected order is known to the tests, and never drops below
        # 1.0 so every row stays above the payload floor other tests assert on.
        $poiScale = 1.0 + ($i * 0.35)
        $poiMult  = if ($s.G) { $mult * $poiScale } else { $poiScale }

        $poi    = [int64](1.427MB * $poiMult)
        $bigPoi = [int64](2.156MB * $poiMult)
        $filter = [int64](544KB   * $poiMult)

        $row = [ordered]@{
            DisplayName                        = $s.N
            MailboxGuid                        = [guid]('{0}-0000-0000-0000-{1:d12}' -f $prefix, $i)
            ItemCount                          = 1000 * $i
            TotalItemSize                      = '5.2 GB (5,583,457,484 bytes)'
            BigFunnelPostingListTableTotalSize = $size
            BigFunnelIsEnabled                 = $true
            BigFunnelIndexedCount              = 1000 * $i
            BigFunnelMessageCount              = 1000 * $i
            BigFunnelTotalPOISize              = New-MockSize -Bytes $poi
            BigFunnelLargePOITableTotalSize    = New-MockSize -Bytes $bigPoi
            BigFunnelFilterTableTotalSize      = New-MockSize -Bytes $filter
            BigFunnelNotIndexedCount           = $notIndexed
            BigFunnelCorruptedCount            = $(if ($s.N -eq 'Ana Ilic') { $corrupted } else { 0 })
            BigFunnelStaleCount                = $stale
            LastLogonTime                      = (Get-Date).AddHours(-3)
        }

        # A build that does not expose the counter at all. The property is
        # removed rather than zeroed, because absent and zero are different
        # facts and the monitor has to tell them apart: absent means it cannot
        # know, zero means the mailbox has no index.
        if ($env:MOCK_NO_INDEXED_COUNT -eq '1') { $row.Remove('BigFunnelIndexedCount') }

        [pscustomobject]$row
    }

    # Health, arbitration, system and archive mailboxes. On the lab server these
    # were 44 of 66 rows: posting list 0 B and no index at all, so they can never be
    # NotPopulated. They exist here because the escalation from WARN to ERROR
    # divides by the indexed population, and a mock with no unindexed rows
    # cannot tell a correct denominator from a wrong one.
    if ($env:MOCK_SYSTEM_MBX) {
        $sys = [int]$env:MOCK_SYSTEM_MBX
        for ($k = 1; $k -le $sys; $k++) {
            [pscustomobject]@{
                DisplayName                        = ('HealthMailbox-{0}-{1:d3}' -f $env:COMPUTERNAME, $k)
                MailboxGuid                        = [guid]('{0}-0000-0000-0001-{1:d12}' -f $prefix, $k)
                ItemCount                          = 0
                TotalItemSize                      = '0 B (0 bytes)'
                BigFunnelPostingListTableTotalSize = New-MockSize -Bytes 0
                BigFunnelIsEnabled                 = $true
                BigFunnelIndexedCount              = 0
                BigFunnelMessageCount              = 0
                BigFunnelTotalPOISize              = New-MockSize -Bytes 0
                BigFunnelLargePOITableTotalSize    = New-MockSize -Bytes 0
                BigFunnelFilterTableTotalSize      = New-MockSize -Bytes 0
                BigFunnelNotIndexedCount           = 0
                BigFunnelCorruptedCount            = 0
                BigFunnelStaleCount                = 0
                LastLogonTime                      = (Get-Date).AddHours(-3)
            }
        }
    }
}

Export-ModuleMember -Function Get-MailboxDatabase, Get-MailboxStatistics
