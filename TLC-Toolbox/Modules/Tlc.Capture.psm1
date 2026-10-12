Set-StrictMode -Version Latest

<#
    Live capture.

    Every other collector in this toolbox answers "what was recorded?". This one answers "what is
    happening?", which is a different question and needs a different shape: a loop that observes
    repeatedly while an operator reproduces a fault, rather than one pass after the fact.

    The measurement that forced this: media path quality, the headline number for a call-quality
    case, was a burst of 10 STUN probes 50 ms apart - half a second of sampling, taken once, after
    the call had ended. A customer reporting twenty minutes of bad audio got half a second of
    evidence. Widening the repro window does not help, because the window selects log lines and a
    probe is not a log line.

    Design rules, each of which exists because the alternative fails badly:

    - A sampler that throws must not end the session. The session is the operator's time and it
      cannot be spent again; losing twenty minutes of media samples because a DNS lookup failed
      once would be indefensible. Every sampler is individually guarded and its failure is
      recorded as a sample of its own.

    - Samples are appended to disk as they are taken, not held in memory until the end. A session
      killed at minute nineteen still yields nineteen minutes of evidence.

    - Stopping is a file on disk, not a signal or a shared object. The UI writes it, the session
      polls for it. That survives the window dying, the process tree being killed, and the two
      running in different sessions entirely - none of which a shared handle survives.

    - The session ends by itself. An operator who walks away must not fill a disk, so there is a
      cap and it is recorded in the output rather than being a secret.
#>

$script:TeamsWebViewIds = $null
$script:TeamsWebViewIdsAt = [datetime]::MinValue

function Get-TlcSystemMemory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if (-not ('Microsoft.VisualBasic.Devices.ComputerInfo' -as [type])) {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    }
    # ComputerInfo reads GlobalMemoryStatusEx, without a CIM-provider warm-up.
    $info = [Microsoft.VisualBasic.Devices.ComputerInfo]::new()
    $total = $info.TotalPhysicalMemory
    $available = $info.AvailablePhysicalMemory
    if ($total -le 0 -or $available -gt $total) {
        throw 'Windows returned invalid physical memory totals.'
    }
    return [pscustomobject]@{
        TotalMb = [double]$total / 1MB
        AvailableMb = [double]$available / 1MB
    }
}

function Get-TlcTeamsWebViewMemory {
    <#
    .SYNOPSIS
        How many WebView2 processes belong to Teams, and their working set in MB.
    .DESCRIPTION
        New Teams draws its window in WebView2, so most of its memory is in msedgewebview2.exe
        processes rather than ms-teams.exe, alongside other apps' WebView2 processes. Teams' own
        are the ones whose command line names its package or its exe.

        The command line needs CIM, which costs about 350 ms, so the set of ids is looked up at
        most once a RefreshSeconds or when one of them has gone; each call otherwise costs one
        Get-Process, about 10 ms. A renderer Teams starts between look-ups is counted from the
        next one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([int] $RefreshSeconds = 60)

    $now = Get-Date
    $running = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue)
    $runningIds = @($running | ForEach-Object { $_.Id })
    $stale = ($null -eq $script:TeamsWebViewIds) -or
             (($now - $script:TeamsWebViewIdsAt).TotalSeconds -ge $RefreshSeconds) -or
             (@($script:TeamsWebViewIds | Where-Object { $runningIds -notcontains $_ }).Count -gt 0)
    if ($stale) {
        $script:TeamsWebViewIds = @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine -ErrorAction Stop |
                Where-Object { $_.CommandLine -match 'MSTeams_8wekyb3d8bbwe|--webview-exe-name=ms-teams\.exe' } |
                ForEach-Object { [int]$_.ProcessId })
        $script:TeamsWebViewIdsAt = $now
    }

    $mine = @($running | Where-Object { $script:TeamsWebViewIds -contains $_.Id })
    return [pscustomobject]@{
        Count        = $mine.Count
        WorkingSetMb = [math]::Round((($mine | Measure-Object WorkingSet64 -Sum).Sum / 1MB), 1)
    }
}

function Get-TlcCaptureSample {
    <#
    .SYNOPSIS
        One observation of everything worth watching while a fault is reproduced.
    .DESCRIPTION
        Each probe is guarded on its own. A sampler that throws contributes an Error field for
        that probe and the rest of the sample still lands - the point of sampling over time is
        the series, and a series with a hole in it is far more useful than no series.

        Which probes run is decided by the caller, because the cost differs by an order of
        magnitude: the media probe takes about half a second of wall time, the rest are cheap.
    #>
    [CmdletBinding()]
    param(
        [int] $Sequence = 0,
        [switch] $IncludeMedia,
        [switch] $IncludeNetwork,
        [switch] $IncludeProcesses,
        [string] $MediaHost = ''
    )

    $sample = [ordered]@{
        Sequence  = $Sequence
        TakenUtc  = (Get-Date).ToUniversalTime().ToString('o')
        Errors    = @()
    }

    # The sampler's own cost, recorded per sample.
    #
    # Two reasons. A reader judging "could this have caught a two-second glitch" needs to know
    # what the observation itself cost, not just the interval it was asked for. And a probe that
    # quietly becomes expensive - Get-NetTCPConnection grows with the connection table - stretches
    # the real interval away from the requested one, which would otherwise be invisible.
    $cost = [System.Diagnostics.Stopwatch]::StartNew()
    $failures = [System.Collections.Generic.List[string]]::new()

    if ($IncludeMedia) {
        try {
            $arguments = @{}
            if ($MediaHost) { $arguments['HostName'] = $MediaHost }
            $quality = Measure-TlcMediaPathQuality @arguments
            # Index access, not dotted. Measure-TlcMediaPathQuality returns an OrderedDictionary,
            # so $quality.Reachable reads a PROPERTY OF THE DICTIONARY rather than a key, and
            # under Set-StrictMode that throws. Every sample of the first end-to-end capture run
            # carried "The property 'Reachable' cannot be found on this object" and no media
            # reading at all - the one probe the live fork exists for.
            #
            # The key names are the ones the function actually emits. Reachable and RoundTripMs
            # were assumptions; the unit tests did not catch it because the mock returned the
            # shape this file assumed rather than the shape the real function returns.
            $sample['Media'] = [pscustomobject][ordered]@{
                # Resolved and Measured are separate faults: DNS failing and the relay not
                # answering need different remediation, and a single "reachable" flag hides
                # which one happened.
                Resolved     = [bool]$quality['Resolved']
                Measured     = [bool]$quality['Measured']
                RttAvgMs     = $quality['LatencyAvgMs']
                # The worst probe within the burst, kept because a burst whose average is fine
                # can still contain the spike the user felt.
                RttMaxMs     = $quality['LatencyMaxMs']
                JitterMs     = $quality['JitterMs']
                LossPercent  = $quality['LossPercent']
            }
        } catch {
            $failures.Add("Media: $($_.Exception.Message)")
        }
    }

    if ($IncludeNetwork) {
        # Connection state, which is the thing a snapshot cannot show. A call that drops and
        # re-establishes looks identical to a healthy one when you only look once.
        try {
            $connections = @(Get-NetTCPConnection -State Established -ErrorAction Stop |
                Where-Object { $_.RemotePort -in 443, 80 })
            $sample['TcpEstablished'] = $connections.Count
        } catch {
            $failures.Add("Tcp: $($_.Exception.Message)")
        }

        try {
            $up = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
            $sample['AdaptersUp'] = $up.Count
            # Named, because a Wi-Fi roam or a VPN coming up mid-call changes which adapter
            # carries the media and is invisible in a count alone.
            $sample['AdapterNames'] = @($up | ForEach-Object { $_.Name })
        } catch {
            $failures.Add("Adapters: $($_.Exception.Message)")
        }
    }

    if ($IncludeProcesses) {
        try {
            $ram = Get-TlcSystemMemory -ErrorAction Stop
            if ($null -eq $ram.TotalMb -or $null -eq $ram.AvailableMb -or
                $ram.TotalMb -le 0 -or $ram.AvailableMb -lt 0 -or $ram.AvailableMb -gt $ram.TotalMb) {
                throw 'Windows returned invalid physical memory totals.'
            }
            $sample['SystemMemory'] = $ram
        } catch {
            $failures.Add("SystemMemory: $($_.Exception.Message)")
        }
        # A hang and a leak both have a shape over time that a single reading cannot show.
        try {
            $teams = @(Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue)
            if ($teams.Count -gt 0) {
                $sample['TeamsProcessCount'] = $teams.Count
                $sample['TeamsWorkingSetMb'] = [math]::Round((($teams | Measure-Object WorkingSet64 -Sum).Sum / 1MB), 1)
                # The WebView2 half, reported separately because TeamsWorkingSetMb has always
                # meant ms-teams.exe alone. Measured on the lab endpoint: 53 MB in ms-teams.exe,
                # 627 MB in Teams' WebView2 processes. Finding 321.
                try {
                    $webView = Get-TlcTeamsWebViewMemory
                    $sample['TeamsWebViewCount'] = $webView.Count
                    $sample['TeamsWebViewWorkingSetMb'] = $webView.WorkingSetMb
                } catch {
                    $failures.Add("WebView2: $($_.Exception.Message)")
                }
                # Responding is the difference between "busy" and "hung", and it is the reason
                # this probe exists at all.
                $sample['TeamsResponding'] = -not (@($teams | Where-Object { -not $_.Responding }).Count -gt 0)
                # The oldest process's start time is the client's identity for this session. If
                # it changes between samples Teams restarted, which a process COUNT cannot show
                # when the restart falls between two samples. Finding 305.
                try {
                    $sample['TeamsStartedUtc'] = @($teams | Sort-Object StartTime | Select-Object -First 1)[0].StartTime.ToUniversalTime().ToString('o')
                } catch {
                    $sample['TeamsStartedUtc'] = $null
                }
            } else {
                $sample['TeamsProcessCount'] = 0
            }
        } catch {
            $failures.Add("Processes: $($_.Exception.Message)")
        }
    }

    $cost.Stop()
    $sample['SampleCostMs'] = $cost.ElapsedMilliseconds
    $sample.Errors = $failures.ToArray()
    return [pscustomobject]$sample
}

function Invoke-TlcCaptureSession {
    <#
    .SYNOPSIS
        Samples the machine repeatedly while an operator reproduces a fault.
    .DESCRIPTION
        Runs until one of three things happens, in this order of preference: the operator stops
        it, the cap is reached, or the caller's own deadline passes. All three are normal
        endings and the reason is recorded, because "why did this stop" is the first question
        anyone reading a short session will ask.

        Samples are written to Samples.jsonl as they are taken. A session that is killed at
        minute nineteen leaves nineteen minutes of evidence, which is the whole point of
        appending rather than accumulating.

        Stopping is a sentinel FILE. The window writes it; this polls for it. A shared object or
        an event handle would not survive the UI process being killed, which is exactly the case
        where the samples matter most.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string] $StopSignalPath = '',
        [int] $IntervalSeconds = 5,
        [int] $MaxMinutes = 60,
        [switch] $IncludeMedia,
        [switch] $IncludeNetwork,
        [switch] $IncludeProcesses,
        [string] $MediaHost = '',
        [scriptblock] $OnSample
    )

    if ($IntervalSeconds -lt 1) { $IntervalSeconds = 1 }
    if ($MaxMinutes -lt 1) { $MaxMinutes = 1 }

    if (-not (Test-Path -LiteralPath $EndpointPath)) {
        $null = New-Item -ItemType Directory -Path $EndpointPath -Force
    }
    $samplePath = Join-Path $EndpointPath 'Samples.jsonl'

    $sequence = 0
    $stopReason = 'Cap reached'

    # Nothing selected would spin a loop that observes nothing. Default to the cheap probes,
    # which is what an operator who did not think about it almost certainly wants.
    if (-not ($IncludeMedia -or $IncludeNetwork -or $IncludeProcesses)) {
        $IncludeNetwork = $true
        $IncludeProcesses = $true
    }

    # Warm the CIM modules before the clock starts.
    #
    # Measured: the first Get-NetTCPConnection/Get-NetAdapter pass costs 7,654 ms while the
    # module loads, against 553-634 ms once warm. Without this the first sample swallows the
    # whole interval - a 12-second session at a 2-second interval produced ONE sample, because
    # the first took nearly eight of those seconds.
    #
    # The result is discarded on purpose: it is a load, not an observation, and its timing
    # would misrepresent the machine at the moment the operator pressed start.
    $warmupMs = 0
    if ($IncludeNetwork -or $IncludeProcesses) {
        try {
            $warm = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Get-TlcCaptureSample -Sequence 0 -IncludeNetwork:$IncludeNetwork -IncludeProcesses:$IncludeProcesses
            $warm.Stop()
            $warmupMs = $warm.ElapsedMilliseconds
        } catch {
            Write-Verbose "Warm-up sample failed, continuing: $($_.Exception.Message)"
        }
    }

    # AFTER the warm-up, deliberately. The sampling grid is anchored to this, so starting the
    # clock before a five-second module load leaves the first few slots already overdue and the
    # loop fires them back to back to catch up - measured as 0.94s, 0.67s, 0.63s, 0.57s before
    # settling. The session's clock should start when sampling starts.
    $started = Get-Date
    $deadline = $started.AddMinutes($MaxMinutes)

    while ($true) {
        if ($StopSignalPath -and (Test-Path -LiteralPath $StopSignalPath)) {
            $stopReason = 'Stopped by the operator'
            break
        }
        if ((Get-Date) -ge $deadline) {
            $stopReason = "Cap of $MaxMinutes minute(s) reached"
            break
        }

        $sample = Get-TlcCaptureSample -Sequence ($sequence + 1) -MediaHost $MediaHost `
            -IncludeMedia:$IncludeMedia -IncludeNetwork:$IncludeNetwork -IncludeProcesses:$IncludeProcesses

        # A storage failure must reach the stage's failure handler and trace cleanup, not
        # advance the counter or tell the operator that an unsaved sample was recorded.
        $line = $sample | ConvertTo-Json -Compress -Depth 6 -ErrorAction Stop
        Add-Content -LiteralPath $samplePath -Value $line -Encoding utf8 -ErrorAction Stop
        $sequence++

        if ($OnSample) {
            # The caller's progress display must never take the session down with it.
            try { & $OnSample $sample } catch { Write-Verbose "OnSample handler failed: $($_.Exception.Message)" }
        }

        # Interruptible, and scheduled on an ABSOLUTE grid rather than sleeping a fixed period
        # after each sample.
        #
        # Sleeping "interval seconds after the last sample finished" adds the sampler's own cost
        # to every cycle, so the series drifts: measured at a 2-second interval with a 499 ms
        # sampler, the real spacing came out at 3.34 s and the gap grows with anything that
        # slows a probe. A time series whose spacing wanders is much harder to reason about -
        # "was that dip two seconds or five?" should not depend on how busy the machine was.
        #
        # Scheduling against start + n x interval keeps the grid honest. If a sample overruns
        # its slot the next one starts immediately rather than trying to catch up, which would
        # bunch samples together and misrepresent the machine even more.
        $nextDue = $started.AddSeconds($sequence * $IntervalSeconds)
        while ((Get-Date) -lt $nextDue) {
            if ($StopSignalPath -and (Test-Path -LiteralPath $StopSignalPath)) { break }
            $remaining = ($nextDue - (Get-Date)).TotalMilliseconds
            if ($remaining -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min(250, [Math]::Max(1, $remaining)))
        }
    }

    $ended = Get-Date
    $duration = [math]::Round(($ended - $started).TotalSeconds, 1)

    # Acknowledged by removing the sentinel. The window waits for exactly this: it tells a
    # session that has stopped sampling, and is now collecting the logs written during it, from
    # one that is wedged. It used to wait for the whole PROCESS to exit, gave up after ten
    # seconds, and killed every run in the middle of that collection - no Capture.json, no
    # Run.json, no support files, and the sentinel left behind in TEMP. Finding 321.
    if ($stopReason -eq 'Stopped by the operator') {
        Remove-Item -LiteralPath $StopSignalPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject][ordered]@{
        StartedUtc      = $started.ToUniversalTime().ToString('o')
        EndedUtc        = $ended.ToUniversalTime().ToString('o')
        DurationSeconds = $duration
        SampleCount     = $sequence
        IntervalSeconds = $IntervalSeconds
        # What was actually achieved, not what was asked for. A probe that costs more than the
        # interval silently stretches it, and a reader judging "was this sampled often enough
        # to catch a two-second glitch" needs the real number rather than the requested one.
        ActualIntervalSeconds = if ($sequence -gt 1) { [math]::Round($duration / $sequence, 2) } else { $null }
        WarmupMs        = $warmupMs
        StopReason      = $stopReason
        SamplePath      = $samplePath
        Probes          = @(
            if ($IncludeMedia) { 'Media' }
            if ($IncludeNetwork) { 'Network' }
            if ($IncludeProcesses) { 'Processes' }
        )
    }
}

function Get-TlcCaptureSummary {
    <#
    .SYNOPSIS
        Turns a session's samples into the few numbers a support engineer reads first.
    .DESCRIPTION
        A time series is evidence, but nobody opens a bundle and reads 240 JSON lines. This
        reduces them to what a reader wants in the first thirty seconds: did the media path stay
        up, how bad did it get, did anything change underneath.

        Worst values as well as averages, deliberately. A call that was perfect for nineteen
        minutes and unusable for one has a fine average and a real problem, and the average is
        the number that hides it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SamplePath
    )

    $summary = [ordered]@{
        SampleCount = 0
        Detail      = ''
    }

    if (-not (Test-Path -LiteralPath $SamplePath)) {
        $summary.Detail = 'No samples were recorded.'
        return [pscustomobject]$summary
    }

    $samples = @(
        foreach ($line in (Get-Content -LiteralPath $SamplePath -ErrorAction Stop)) {
            if (-not $line.Trim()) { continue }
            # A truncated final line is normal when a session is killed mid-write, and must not
            # cost the whole series.
            try { $line | ConvertFrom-Json } catch { Write-Verbose 'Skipped an unreadable sample line.' }
        }
    )

    $summary.SampleCount = $samples.Count
    if ($samples.Count -eq 0) {
        $summary.Detail = 'No readable samples.'
        return [pscustomobject]$summary
    }

    $parts = [System.Collections.Generic.List[string]]::new()

    $media = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'Media' -and $_.Media })
    if ($media.Count -gt 0) {
        $measured = @($media | Where-Object { $_.Media.Measured -eq $true })
        $dnsFailures = @($media | Where-Object {
            $_.Media.Measured -ne $true -and
            $_.Media.PSObject.Properties.Name -contains 'Resolved' -and $_.Media.Resolved -eq $false
        })
        $inconclusive = $media.Count - $measured.Count - $dnsFailures.Count
        $summary['MediaSamples'] = $media.Count
        # Keep the existing field name for readers of older captures. It counts STUN
        # measurements, not proof that the call's actual media path was healthy.
        $summary['MediaReachableCount'] = $measured.Count
        $summary['MediaDnsFailureCount'] = $dnsFailures.Count
        $summary['MediaInconclusiveCount'] = $inconclusive
        if ($measured.Count -gt 0) {
            $rtts = @($measured | ForEach-Object { [double]$_.Media.RttAvgMs } | Where-Object { $_ -gt 0 })
            if ($rtts.Count -gt 0) {
                $summary['RttAverageMs'] = [math]::Round((($rtts | Measure-Object -Average).Average), 1)
                $summary['RttWorstMs'] = [math]::Round((($rtts | Measure-Object -Maximum).Maximum), 1)
            }
            # The worst single probe seen anywhere in the session, which is a different and
            # usually larger number than the worst per-sample average.
            $peaks = @($measured | ForEach-Object { [double]$_.Media.RttMaxMs } | Where-Object { $_ -gt 0 })
            if ($peaks.Count -gt 0) {
                $summary['RttPeakMs'] = [math]::Round((($peaks | Measure-Object -Maximum).Maximum), 1)
            }
            $jitters = @($measured | ForEach-Object { [double]$_.Media.JitterMs } | Where-Object { $_ -ge 0 })
            if ($jitters.Count -gt 0) {
                $summary['JitterWorstMs'] = [math]::Round((($jitters | Measure-Object -Maximum).Maximum), 1)
            }
        }
        if ($measured.Count -eq $media.Count) {
            $parts.Add("the STUN relay answered in all $($media.Count) media samples")
        } elseif ($measured.Count -gt 0) {
            $parts.Add("the STUN relay answered in $($measured.Count) of $($media.Count) media samples")
        }
        if ($dnsFailures.Count -gt 0) {
            $parts.Add("DNS resolution failed in $($dnsFailures.Count) of $($media.Count) media samples")
        }
        if ($inconclusive -gt 0) {
            $parts.Add("STUN measurements were inconclusive in $inconclusive of $($media.Count) media samples; no reply cannot establish the call path's reachability")
        }

        $losses = @($measured | Where-Object {
            $_.Media.PSObject.Properties.Name -contains 'LossPercent' -and $null -ne $_.Media.LossPercent
        } | ForEach-Object { [double]$_.Media.LossPercent } | Where-Object { $_ -ge 0 -and $_ -le 100 })
        $worstMeasuredLoss = if ($losses.Count -gt 0) {
            [math]::Round((($losses | Measure-Object -Maximum).Maximum), 1)
        } else { $null }
        $summary['LossMeasuredSamples'] = $losses.Count
        $summary['LossWorstMeasuredPercent'] = $worstMeasuredLoss
        # A missing Media block after a probe error is also a hole in the series.
        $summary['LossWorstPercent'] = if ($losses.Count -eq $samples.Count) { $worstMeasuredLoss } else { $null }
        if ($losses.Count -lt $samples.Count) {
            $parts.Add("probe loss was not measured in $($samples.Count - $losses.Count) of $($samples.Count) samples; the worst loss for the full series is unknown")
        }
    }

    $adapters = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'AdapterNames' -and $null -ne $_.AdapterNames })
    if ($adapters.Count -gt 0) {
        $sets = @($adapters | ForEach-Object {
            ConvertTo-Json -InputObject @($_.AdapterNames | Sort-Object -Unique) -Compress
        })
        $changes = 0
        for ($i = 1; $i -lt $sets.Count; $i++) {
            if ($sets[$i] -ne $sets[$i - 1]) { $changes++ }
        }
        $summary['AdapterChanges'] = $changes
        if ($changes -gt 0) {
            $parts.Add("the set of connected adapters changed $changes time(s) during the session")
        }
    }

    $hung = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'TeamsResponding' -and -not $_.TeamsResponding })
    if ($hung.Count -gt 0) {
        # When, not just how often. A freeze the operator reports as "about a minute ago" is
        # matched against these times, and a count cannot be matched against anything.
        $firstHung = ([datetime]$hung[0].TakenUtc).ToUniversalTime()
        $lastHung = ([datetime]$hung[-1].TakenUtc).ToUniversalTime()
        $summary['NotRespondingSamples'] = $hung.Count
        $summary['NotRespondingFirstUtc'] = $firstHung.ToString('o')
        $summary['NotRespondingLastUtc'] = $lastHung.ToString('o')
        $parts.Add("Teams was not responding in $($hung.Count) sample(s), $($firstHung.ToLocalTime().ToString('HH:mm:ss')) to $($lastHung.ToLocalTime().ToString('HH:mm:ss')) local")
    }

    # Teams exiting and coming back. "It just closed" is one of the commonest reports, and a
    # crash that the client recovers from on its own leaves nothing in a snapshot taken after.
    $withCount = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'TeamsProcessCount' })
    $absent = @($withCount | Where-Object { [int]$_.TeamsProcessCount -eq 0 })
    if ($absent.Count -gt 0 -and $absent.Count -lt $withCount.Count) {
        $summary['NotRunningSamples'] = $absent.Count
        $summary['NotRunningFirstUtc'] = ([datetime]$absent[0].TakenUtc).ToUniversalTime().ToString('o')
        $parts.Add("Teams was not running in $($absent.Count) sample(s)")
    }
    $starts = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'TeamsStartedUtc' -and $_.TeamsStartedUtc } |
        ForEach-Object { ([datetime]$_.TeamsStartedUtc).ToUniversalTime().ToString('o') })
    $restarts = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $starts.Count; $i++) {
        if ($starts[$i] -ne $starts[$i - 1]) { $restarts.Add($starts[$i]) }
    }
    if ($restarts.Count -gt 0) {
        $summary['TeamsRestarts'] = $restarts.Count
        $summary['TeamsRestartedUtc'] = @($restarts)
        $parts.Add("Teams restarted $($restarts.Count) time(s) during the session")
    }

    $failed = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'Errors' -and @($_.Errors).Count -gt 0 })
    if ($failed.Count -gt 0) {
        $summary['SamplesWithErrors'] = $failed.Count
        $parts.Add("$($failed.Count) sample(s) had a probe that failed")
    }

    # Teams' whole footprint, ms-teams.exe plus its WebView2 processes, because the WebView2
    # half is most of it and is where a renderer leak shows. Growth over the session is the
    # number a performance case turns on. Finding 321.
    $memory = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'TeamsWebViewWorkingSetMb' } |
        ForEach-Object { [double]$_.TeamsWorkingSetMb + [double]$_.TeamsWebViewWorkingSetMb })
    if ($memory.Count -gt 0) {
        $summary['TeamsMemoryFirstMb'] = [math]::Round($memory[0], 1)
        $summary['TeamsMemoryPeakMb'] = [math]::Round((($memory | Measure-Object -Maximum).Maximum), 1)
        $summary['TeamsMemoryLastMb'] = [math]::Round($memory[-1], 1)
        $growth = [math]::Round($memory[-1] - $memory[0], 0)
        $parts.Add("Teams used $([math]::Round($memory[0], 0)) MB at the start and $([math]::Round($memory[-1], 0)) MB at the end, peak $([math]::Round($summary['TeamsMemoryPeakMb'], 0)) MB, WebView2 included ($(if ($growth -ge 0) { '+' })$growth MB)")
    }

    # How long the series covers, read from the samples themselves rather than from anything
    # the session reports about itself.
    #
    # "12 samples" alone does not tell a reader whether that is twelve seconds of a fault or
    # twelve minutes, and the interval that produced it is the thing that decides whether a
    # short glitch could have been visible at all. A bundle reader sees this sentence first and
    # often only this sentence.
    $span = $null
    $observed = $null
    $stamped = @($samples | Where-Object { $_.PSObject.Properties.Name -contains 'TakenUtc' -and $_.TakenUtc })
    if ($stamped.Count -gt 1) {
        try {
            $times = @($stamped | ForEach-Object { [datetime]$_.TakenUtc } | Sort-Object)
            $span = [math]::Round(($times[-1] - $times[0]).TotalSeconds, 1)
            $summary['SpanSeconds'] = $span
            $observed = [math]::Round($span / ($times.Count - 1), 1)
            $summary['ObservedIntervalSeconds'] = $observed
        } catch {
            Write-Verbose "Sample timestamps could not be compared: $($_.Exception.Message)"
        }
    }

    $scale = if ($span) {
        $window = if ($span -ge 120) { '{0:n1} minutes' -f ($span / 60) } else { "$span seconds" }
        " over $window" + $(if ($observed) { ", one every $observed s" } else { '' })
    } else {
        ''
    }

    $summary.Detail = if ($parts.Count -gt 0) {
        "$($samples.Count) sample(s)$scale" + ': ' + ($parts -join '; ') + '.'
    } else {
        "$($samples.Count) sample(s)$scale recorded."
    }

    return [pscustomobject]$summary
}

function Stop-TlcCaptureSession {
    <#
    .SYNOPSIS
        Asks a live capture session to stop, and reports whether it did.
    .DESCRIPTION
        Killing a capture session costs the operator the part of the evidence they most need.
        The samples survive a kill because they are appended as they are taken, but the summary
        - whether the media path held up, how bad it got, whether the adapters changed - is
        written when the session ENDS. A killed session leaves a few hundred JSON lines and
        nothing that reads them.

        So the sentinel is written and the session is given a moment to finish on its own. The
        caller decides what to do if it does not; this reports the outcome rather than
        escalating, because only the caller knows whether a kill is acceptable.

        IsRunning is a scriptblock rather than a Process, so the wait is testable without
        spawning anything, and so a caller that tracks liveness some other way can still use it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StopSignalPath,
        [Parameter(Mandatory)] [scriptblock] $IsRunning,
        [int] $TimeoutSeconds = 10,
        # Called on each poll, so a UI caller can keep repainting while it waits.
        [scriptblock] $OnWait,
        [int] $PollMilliseconds = 200,
        # Also return as soon as the session REMOVES the sentinel, which it does when sampling has
        # stopped. The process then goes on to collect the logs written during the session and can
        # legitimately take minutes; waiting for it to exit, and killing it when it did not, is
        # what destroyed a live trace's Capture.json and Run.json. Finding 321.
        [switch] $AcceptAcknowledgement
    )

    $result = [ordered]@{
        SignalWritten = $false
        Stopped       = $false
        Acknowledged  = $false
        WaitedSeconds = 0
        Error         = $null
    }

    try {
        New-Item -ItemType File -Path $StopSignalPath -Force | Out-Null
        $result.SignalWritten = $true
    } catch {
        # A sentinel that cannot be written is the caller's cue to fall back to force. Reported
        # rather than thrown: this runs from a button handler, and an exception there takes the
        # window down while the session keeps sampling.
        $result.Error = $_.Exception.Message
        return [pscustomobject]$result
    }

    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)

    # Liveness is checked BEFORE the deadline, every pass. That ordering is the whole point: a
    # session that exits during the final sleep is caught on the next pass rather than being
    # reported as still running and killed for nothing.
    #
    # An earlier version checked the deadline in the loop condition and repeated the liveness
    # check after the loop. It behaved correctly but the trailing check was unreachable in any
    # test that did not control the clock, so it could be deleted with the suite still green.
    # One check that is always exercised beats two where one is never proved.
    while ($true) {
        if (-not (& $IsRunning)) {
            $result.Stopped = $true
            break
        }
        if ($AcceptAcknowledgement -and -not (Test-Path -LiteralPath $StopSignalPath)) {
            $result.Acknowledged = $true
            break
        }
        if ((Get-Date) -ge $deadline) { break }

        Start-Sleep -Milliseconds $PollMilliseconds
        if ($OnWait) {
            try { & $OnWait } catch { Write-Verbose "Stop wait handler failed: $($_.Exception.Message)" }
        }
    }

    $result.WaitedSeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
    return [pscustomobject]$result
}

function Get-TlcDeepCaptureOption {
    <#
    .SYNOPSIS
        The deeper captures that could run alongside a live session, and whether they can.
    .DESCRIPTION
        Sampling answers "what did the machine look like, repeatedly". It cannot answer "what
        was actually on the wire", and some faults - a TLS reset mid-call, a relay that stops
        answering, a DNS answer that changes - only show up there.

        Those captures need administrator rights. The toolbox does not ask for them. Every other
        missing capability here is REPORTED rather than prompted for, and a tool that demands
        elevation halfway through a customer's reproduction gets cancelled; the operator then
        has neither the deep capture nor the session they were running.

        So this answers the question rather than acting on it: what is possible on this machine
        right now, what is not, precisely why not, and the exact command to run by hand instead.
        The same shape the media relay probe uses when Microsoft publishes no host name for a
        cloud - the check is recorded as skipped, with what to do instead, rather than silently
        producing nothing.

        NOT a wrapper that starts a packet capture. A trace started by a process that is then
        killed keeps running, keeps writing, and is invisible to whoever finds the machine
        later. Automating that safely needs a leftover sweep and an elevated environment to
        prove it in, and neither exists yet.
    #>
    [CmdletBinding()]
    param(
        [string] $OutputPath = 'C:\TLC-Toolbox\Deep'
    )

    $elevated = Get-TlcIsElevated

    $options = @(
        [ordered]@{
            Name    = 'PacketCapture'
            Title   = 'Packet capture'
            Answers = 'What was actually on the wire: resets, retransmits, a relay that stopped answering.'
            Tool    = 'pktmon.exe'
            Command = "pktmon start --capture --pkt-size 128 --file-name '$([System.IO.Path]::Combine($OutputPath, 'capture.etl'))'   # then: pktmon stop"
        }
        [ordered]@{
            Name    = 'NetshTrace'
            Title   = 'Network trace with stack context'
            Answers = 'The same traffic plus the Windows networking stack events around it.'
            Tool    = 'netsh.exe'
            Command = "netsh trace start capture=yes scenario=InternetClient_dbg tracefile='$([System.IO.Path]::Combine($OutputPath, 'trace.etl'))'   # then: netsh trace stop"
        }
        [ordered]@{
            Name    = 'EtwSession'
            Title   = 'ETW provider session'
            Answers = 'Provider-level events from the networking and TLS stacks during the fault.'
            Tool    = 'logman.exe'
            Command = "logman create trace TlcDeep -p Microsoft-Windows-WinINet -o '$([System.IO.Path]::Combine($OutputPath, 'etw.etl'))' -ets   # then: logman stop TlcDeep -ets"
        }
    )

    foreach ($option in $options) {
        # The packet capture is DELIVERED by either tool: pktmon when its session is free, netsh
        # trace when something else holds it - which on a managed machine is Defender, always
        # (finding 292). So it is available when either is present, and asking only about
        # pktmon would report the capability missing on a machine that can capture fine.
        #
        # The command follows the tool. It always said pktmon, so with pktmon missing the
        # option was available through netsh and told the operator to run a tool that is not
        # there; and where Defender holds pktmon's session the pktmon command refuses with
        # "already started", so the netsh route is named beside it (review 2026-09-30,
        # finding 331). The netsh arguments are the ones Start-TlcDeepCapture uses.
        if ($option.Name -eq 'PacketCapture') {
            $pktmon = Get-Command -Name 'pktmon.exe' -ErrorAction SilentlyContinue
            $netsh = Get-Command -Name 'netsh.exe' -ErrorAction SilentlyContinue
            $tool = if ($pktmon) { $pktmon } else { $netsh }
            $netshCommand = "netsh trace start capture=yes packettruncatebytes=128 report=disabled tracefile='$([System.IO.Path]::Combine($OutputPath, 'capture.etl'))'   # then: netsh trace stop"
            if (-not $pktmon -and $netsh) {
                $option['Tool'] = 'netsh.exe'
                $option['Command'] = $netshCommand
            } elseif ($pktmon -and $netsh) {
                $option['Command'] = "$($option.Command). If pktmon answers that it is already started, Defender for Endpoint holds its session; capture with netsh instead: $netshCommand"
            }
        } else {
            $tool = Get-Command $option.Tool -ErrorAction SilentlyContinue
        }

        $option['ToolPresent'] = [bool]$tool
        $option['Elevated'] = $elevated
        $option['Available'] = ([bool]$tool -and $elevated)
        # Named causes, not a bare false. "Unavailable" sends an engineer hunting for a
        # capability that is one right-click away.
        $option['Reason'] = Get-TlcDeepCaptureReason -Name $option.Name -Tool $option.Tool -ToolPresent ([bool]$tool) -Elevated $elevated

        [pscustomobject]$option
    }
}

function Get-TlcDeepCaptureReason {
    <#
    .SYNOPSIS
        Why a deeper capture can or cannot run, in English, from the facts that decide it.
    .DESCRIPTION
        Capture.json records this sentence, so it is English. The window says the same thing in
        its own language from the same three facts (Get-TlcDeepCaptureReasonText in the wizard)
        rather than by reading this text, and Tlc.Ui.Tests.ps1 holds the two together for every
        combination.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Name,
        [string] $Tool,
        [bool] $ToolPresent,
        [bool] $Elevated
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $ToolPresent) {
        # The packet capture is delivered by either tool, so it is missing only when both are.
        $reasons.Add($(if ($Name -eq 'PacketCapture') { 'neither pktmon.exe nor netsh.exe was found on this machine' } else { "$Tool was not found on this machine" }))
    }
    if (-not $Elevated) { $reasons.Add('the toolbox is not running as administrator') }

    if ($reasons.Count -eq 0) { return 'Available: run the command above alongside the capture session.' }
    return 'Not available because ' + ($reasons -join ', and ') + '.'
}

function Get-TlcStaleCaptureTrace {
    <#
    .SYNOPSIS
        Finds packet or ETW traces left running by an earlier session.
    .DESCRIPTION
        This is the prerequisite for ever starting one automatically, and it exists before the
        starting does on purpose.

        A `netsh trace` or `pktmon` session is a machine-wide thing, not a child of whatever
        started it. Kill the process and the trace keeps running, keeps writing, and survives
        the toolbox exiting - and the wizard's Stop button force-kills the run's process tree,
        so that is the ordinary path rather than a corner case. A tool whose job is diagnosing a
        sick machine would be quietly filling its disk.

        So: detect first, report always, and only then consider starting one. A sweep that runs
        at the start of every capture tells an operator about a trace their last session left
        behind even if this build never starts one.

        Reads state rather than changing it. Stopping someone else's trace - it might be a
        colleague's, or a monitoring agent's - is not a decision this should make silently, so
        the stop command is reported for a person to run.
    #>
    [CmdletBinding()]
    param()

    $found = [System.Collections.Generic.List[object]]::new()

    # netsh reports a running trace in its status output, but the absence of a sentence is NOT
    # evidence that nothing is running.
    #
    # The first version said "if the text does not contain 'no trace session', one is running",
    # which reports a phantom trace for every output it does not recognise. Measured:
    #
    #   "There is no trace session currently in progress."   -> clean          (correct)
    #   "Access is denied."                                  -> TRACE RUNNING  (wrong)
    #   German equivalent of the first line                  -> TRACE RUNNING  (wrong)
    #
    # So it raised a warning on any non-English Windows and on any failure. Note also that
    # netsh returns exit code 1 for the ordinary no-trace case, so the exit code cannot carry
    # this decision either - measured, not assumed.
    #
    # Detection is now positive: a known "nothing running" phrase means clean, a known running
    # marker means running, and anything else is reported as undetermined rather than guessed.
    $netshUnknown = $false
    if (Get-Command netsh.exe -ErrorAction SilentlyContinue) {
        try {
            $probe = Invoke-TlcNativeCommand -FilePath 'netsh.exe' -ArgumentList @('trace', 'show', 'status')
            $status = (@($probe.Lines) -join [Environment]::NewLine)

            if ($status -match 'no trace session|not currently running') {
                # Nothing running, said plainly.
            } elseif ($status -match '(?m)^\s*Status\s*:|Trace File\s*:|tracefile') {
                $found.Add([pscustomobject]@{
                    Kind    = 'NetshTrace'
                    Detail  = ($status -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / '
                    StopWith = 'netsh trace stop'
                })
            } elseif ($status.Trim()) {
                $netshUnknown = $true
            }
        } catch {
            $netshUnknown = $true
            Write-Verbose "netsh trace status could not be read: $($_.Exception.Message)"
        }
    }

    # An ETW session this toolbox created. Named rather than pattern-matched across everything,
    # because stopping a session some other product owns would be a fault of its own.
    #
    # A failed query is reported as undetermined, not as "none found" - the same false-clean
    # the pktmon probe had.
    $logmanUnknown = $false
    if (Get-Command logman.exe -ErrorAction SilentlyContinue) {
        try {
            $probe = Invoke-TlcNativeCommand -FilePath 'logman.exe' -ArgumentList @('query', '-ets')
            $sessions = (@($probe.Lines) -join [Environment]::NewLine)
            if ($probe.ExitCode -ne 0 -and $sessions -notmatch 'Data Collector Set') {
                $logmanUnknown = $true
            }
            foreach ($line in @($sessions -split "`r?`n")) {
                if ($line -match '^\s*(TlcDeep\S*)\s') {
                    $name = $Matches[1]
                    $found.Add([pscustomobject]@{
                        Kind    = 'EtwSession'
                        Detail  = "ETW session '$name' is still running."
                        StopWith = "logman stop $name -ets"
                    })
                }
            }
        } catch {
            $logmanUnknown = $true
            Write-Verbose "logman sessions could not be read: $($_.Exception.Message)"
        }
    }

    # A pktmon capture this toolbox started. Checked by the tool's own status first, and by the
    # marker second, because the two fail in opposite directions: the marker survives a killed
    # process but says nothing about whether the capture is still running, and the status is
    # authoritative but says nothing about who started it.
    #
    # "Could not determine" is reported as its own answer, never folded into "nothing found".
    # Measured: unelevated, `pktmon status` returns exit code 5 and "Failed to communicate with
    # the PktMon driver: Access is denied." - so on the ordinary unelevated run this check
    # cannot see a capture at all, and reporting a clean machine on the strength of a check
    # that never ran is the precise shape of a false clean.
    $pktmonUnknown = $false
    $pktmonOwner = ''
    if (Get-Command pktmon.exe -ErrorAction SilentlyContinue) {
        try {
            # Through the shared helper, not a raw 2>&1.
            #
            # On 5.1 a redirected native stderr becomes a NativeCommandError and THROWS under
            # the Stop preference both entry points set - so `pktmon status 2>&1` would throw on
            # exactly the machines where pktmon has something to say, which is every unelevated
            # one. Invoke-TlcNativeCommand exists for this and keeps stderr as text.
            $probe = Invoke-TlcNativeCommand -FilePath 'pktmon.exe' -ArgumentList @('status')
            $status = (@($probe.Lines) -join [Environment]::NewLine)
            $statusExit = $probe.ExitCode

            # WHO holds it, for the case where the answer comes back undetermined.
            #
            # SenseNdr is Microsoft Defender for Endpoint's network sensor, and its presence is
            # the whole reason the answer is undetermined on a managed machine: with it armed,
            # pktmon prints a configuration table and none of the phrases either pattern below
            # looks for. Naming the holder turns "could not be determined" into something an
            # operator can act on, which is the difference between a dead end and a signpost.
            if ($status -match 'SenseNdr') { $pktmonOwner = 'Defender' }

            # Positive detection in BOTH directions, and a third answer for anything else.
            #
            # The running pattern used to be 'Packet Monitor is (running|active)|Logging Mode'.
            # Measured 2026-09-16 on the first elevated run of Tools\Test-TlcDeepCapture.ps1,
            # with a capture genuinely live, this build of pktmon answered
            #
            #     "Packet Monitor is already started."
            #
            # which matches neither word. So the sweep reported a clean machine while a packet
            # capture was running - the precise false clean it exists to prevent, and the same
            # class as finding 187, where netsh's phrasing was assumed rather than measured.
            #
            # Absence of the running phrases is now NOT treated as clean. A recognised idle
            # phrase means idle, a recognised running phrase means running, and anything else
            # is undetermined - because an unrecognised answer is evidence that the output was
            # not what was expected, which is a third thing and usually the one worth printing.
            $idlePattern = 'Packet Monitor is not (running|started|active)|is currently off'
            $runningPattern = 'Packet Monitor is (running|active|already started|started)|Logging Mode'

            if ($statusExit -ne 0 -or $status -match 'Access is denied|Failed to communicate') {
                $pktmonUnknown = $true
            } elseif ($status -match $idlePattern) {
                # Nothing running, and the tool said so in words this code recognises.
            } elseif ($status -match $runningPattern) {
                $found.Add([pscustomobject]@{
                    Kind    = 'PacketCapture'
                    Detail  = 'A pktmon packet capture is running.'
                    StopWith = 'pktmon stop'
                })
            } else {
                $pktmonUnknown = $true
            }
        } catch {
            $pktmonUnknown = $true
            Write-Verbose "pktmon status could not be read: $($_.Exception.Message)"
        }
    }

    if ($pktmonUnknown -or $netshUnknown -or $logmanUnknown) {
        $which = @(
            if ($pktmonUnknown) { 'pktmon' }
            if ($netshUnknown) { 'netsh' }
            if ($logmanUnknown) { 'logman' }
        ) -join ', '

        # The reason is CHECKED, not assumed.
        #
        # This used to end "These need administrator rights" unconditionally. On the first
        # successful elevated run of Tools\Test-TlcDeepCapture.ps1 it said exactly that while
        # running as administrator - because the probes had failed for a completely different
        # reason, and the message named the only cause its author had in mind.
        #
        # An unelevated run is the common case and worth naming. An elevated one that still
        # cannot answer is the interesting case, and telling that operator to go and get rights
        # they already hold sends them to fix the one thing that is not wrong.
        #
        # The Defender case is named first because it is the most common of the three and the
        # only one with a way forward. Decided 2026-09-16: deep capture STAYS REFUSED on a
        # machine where Defender holds the session, and no "I accept stopping it" override is
        # offered. Three reasons, and the first is the one that settles it:
        #
        #   1. The cost cannot be paid back in the session. Restoring the sensor needs a
        #      REBOOT - tamper protection refuses the service restart even elevated - and an
        #      operator halfway through reproducing a fault cannot reboot. Accepting the
        #      override would destroy the session it was accepted for.
        #   2. It disables a security control on a customer endpoint. That is not a choice a
        #      diagnostic tool should put in front of an engineer under time pressure, and at
        #      many customers it is a policy breach regardless of who clicks yes.
        #   3. The evidence is replaceable. netsh trace does packet capture in its OWN session
        #      and does not contend for pktmon's, so refusing here costs a mechanism, not the
        #      capability.
        $reason = if ($pktmonOwner -eq 'Defender') {
            ('Microsoft Defender for Endpoint holds the single machine-wide pktmon session - its filters are ' +
             'named SenseNdr. That is the resting state of a managed machine rather than a fault. Measured ' +
             '2026-09-16: pktmon REFUSES to start over it, exit 5023 "Packet Monitor is already started.", so ' +
             'there is nothing to try by hand either - and taking the session from Defender would stop the EDR ' +
             'network sensor, which then needs a REBOOT to restore. A packet capture uses netsh trace instead, ' +
             'which captures in its own session and does not contend for this one.')
        } elseif (Get-TlcIsElevated) {
            'This window is already elevated, so rights are not the reason - treat the answer as unknown rather than clean.'
        } else {
            'These need administrator rights.'
        }

        # The remediation follows the reason. It said "Run as administrator" in all three cases,
        # including to an elevated operator looking at Defender's own session. Measured on
        # the lab endpoint 2026-09-28. Finding 315.
        $check = if ($pktmonOwner -eq 'Defender') {
            'Nothing to stop: this is Defender for Endpoint''s network sensor, so leave it running. To confirm no other capture is running: netsh trace show status'
        } elseif (Get-TlcIsElevated) {
            'Check by hand: pktmon status; netsh trace show status'
        } else {
            'Run as administrator and check: pktmon status; netsh trace show status'
        }

        $found.Add([pscustomobject]@{
            Kind    = 'Unknown'
            Detail  = "Whether a capture is running could not be determined - $which could not answer. $reason"
            StopWith = $check
            # Structured as well as described. Start-TlcDeepCapture has to know WHICH tools
            # could not answer - an undetermined pktmon beside a netsh that reported idle is the
            # case where netsh trace can still capture, and reading that out of the sentence
            # above would be parsing prose. Finding 292.
            Tools   = @(
                if ($pktmonUnknown) { 'pktmon' }
                if ($netshUnknown) { 'netsh' }
                if ($logmanUnknown) { 'logman' }
            )
            Owner   = $pktmonOwner
        })
    }

    # A marker with no running capture behind it. Reported rather than silently deleted: it
    # means a session was killed between writing the marker and starting the capture, or the
    # capture was stopped by something else, and either is worth an operator knowing once.
    #
    # Matched against the tool the MARKER names. It used to look only for a pktmon capture, so
    # once netsh trace became the fallback (finding 292) a live netsh capture of our own would
    # have been reported as an orphaned marker - telling an operator to delete the one record
    # that says a machine-wide trace is still writing.
    $marker = Get-TlcDeepCaptureMarkerPath
    if (Test-Path -LiteralPath $marker) {
        $markedTool = 'pktmon'
        try {
            $markedTool = [string](Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).Tool
        } catch {
            Write-Verbose "The deep capture marker could not be read: $($_.Exception.Message)"
        }
        $liveKind = if ($markedTool -eq 'netsh') { 'NetshTrace' } else { 'PacketCapture' }

        # A marker whose tool could not answer is not an orphan. Unelevated, pktmon cannot
        # answer at all, and this used to report "no longer running" with Remove-Item as the
        # fix: deleting the one record that a machine-wide trace may still be writing, on the
        # run least able to see it (review 2026-09-30, finding 331).
        $markedToolUnknown = if ($markedTool -eq 'netsh') { $netshUnknown } else { $pktmonUnknown }

        if ($markedToolUnknown) {
            $checkWith = if ($markedTool -eq 'netsh') { 'netsh trace show status' } else { 'pktmon status' }
            $stopWith = if ($markedTool -eq 'netsh') { 'netsh trace stop' } else { 'pktmon stop' }
            $found.Add([pscustomobject]@{
                Kind    = 'UnconfirmedMarker'
                Detail  = "A previous session recorded starting a $markedTool capture, and whether it is still running could not be checked."
                StopWith = "From an elevated prompt, check with $checkWith and stop it with $stopWith if it is running. Keep '$marker' until then: it is the record that this toolbox started it."
            })
        } elseif (@($found | Where-Object { $_.Kind -eq $liveKind }).Count -eq 0) {
            $found.Add([pscustomobject]@{
                Kind    = 'OrphanedMarker'
                Detail  = "A previous session recorded starting a $markedTool capture that is no longer running."
                StopWith = "Remove-Item '$marker'"
            })
        }
    }

    return $found.ToArray()
}

function Get-TlcIsElevated {
    <#
    .SYNOPSIS
        Whether this process is running as administrator.
    .DESCRIPTION
        A function rather than an inline check so the deep-capture paths can be tested on a
        machine that is not elevated - which is every development machine here, and so would
        otherwise mean the entire elevated branch ships having never executed.
    #>
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TlcDeepCaptureMarkerPath {
    <#
    .SYNOPSIS
        Where a started deep capture records that it exists.
    .DESCRIPTION
        A trace outlives the process that started it, so "what did we start" cannot live in
        memory. It goes to a file in a fixed location - not in the run folder, because a run
        folder can be moved, zipped or deleted while the trace it started keeps running.
    #>
    [CmdletBinding()]
    param()

    $folder = Join-Path ([System.IO.Path]::GetTempPath()) 'TlcDeepCapture'
    if (-not (Test-Path -LiteralPath $folder)) {
        $null = New-Item -ItemType Directory -Path $folder -Force
    }
    return Join-Path $folder 'started.json'
}

function Start-TlcDeepCapture {
    <#
    .SYNOPSIS
        Starts a packet capture alongside a live session, and records that it did.
    .DESCRIPTION
        pktmon rather than netsh trace. Both need elevation and both produce an ETL, but
        pktmon's stop is a single idempotent command that succeeds whether or not a capture is
        running, which matters when the stop path may be reached by a caller that cannot know
        the current state.

        The marker is written BEFORE the capture starts, not after.

        If it were written after, a process killed in the window between the two would leave a
        running trace that nothing knows about - the exact failure this whole design exists to
        prevent. Written first, the worst case is a marker describing a capture that never
        started, and the sweep confirms against the real tool state rather than trusting it.

        Refuses to start when one is already running. Two captures writing at once is a
        disk-filling fault with no upside, and the existing one may be someone else's.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $OutputPath,
        # Bounded by the caller. A capture with no ceiling is the thing that fills a disk.
        [int] $MaxFileSizeMb = 512
    )

    $result = [ordered]@{
        Started   = $false
        Tool      = 'pktmon'
        FilePath  = $null
        Reason    = ''
    }

    if (-not (Get-TlcIsElevated)) {
        $result.Reason = 'Not running as administrator, so a packet capture cannot be started.'
        return [pscustomobject]$result
    }

    $hasPktmon = [bool](Get-Command pktmon.exe -ErrorAction SilentlyContinue)
    $hasNetsh = [bool](Get-Command netsh.exe -ErrorAction SilentlyContinue)
    if (-not $hasPktmon -and -not $hasNetsh) {
        $result.Reason = 'pktmon.exe was not found on this machine, and neither was netsh.exe.'
        return [pscustomobject]$result
    }

    # The sweep's THIRD answer is a refusal here, not a shrug.
    #
    # This used to be a single `Where-Object { $_.Kind -ne 'Unknown' }`, which discarded exactly
    # the answer the sweep works hardest to produce. That filter could only ever throw away the
    # interesting case: the boring reason for an undetermined answer is an unelevated probe, and
    # this function has already returned above when it is not elevated. So every Unknown that
    # reaches this line came from an ELEVATED run that still could not tell whether a capture
    # was running - and starting one anyway is the same false-clean reasoning the sweep exists
    # to prevent, moved one layer up into its caller.
    #
    # Measured 2026-09-16. This machine runs Microsoft Defender for Endpoint, whose network
    # sensor holds a permanent pktmon session with filters named SenseNdr. With it armed,
    # `pktmon status` exits 0 and prints a component and filter table containing no
    # "Packet Monitor is ..." line at all, so the parser correctly answers Unknown - and this
    # filter threw that away and started anyway. pktmon has ONE machine-wide session, so that
    # is not a neighbourly act. And this is not an edge case: it is the resting state of every
    # Defender-managed machine, which is every machine this toolbox is ever run on.
    $sweep = @(Get-TlcStaleCaptureTrace)

    # A marker is a record, not a capture. Starting would overwrite it, so it still refuses,
    # but the reason no longer says a capture is running when the sweep said it is not, or
    # could not tell (review 2026-09-30, finding 331).
    $markerKinds = @('OrphanedMarker', 'UnconfirmedMarker')
    $existing = @($sweep | Where-Object { $_.Kind -ne 'Unknown' -and $_.Kind -notin $markerKinds })
    if ($existing.Count -gt 0) {
        $result.Reason = 'A capture is already running: ' + (@($existing | ForEach-Object { $_.Detail }) -join '; ')
        return [pscustomobject]$result
    }
    $records = @($sweep | Where-Object { $_.Kind -in $markerKinds })
    if ($records.Count -gt 0) {
        $result.Reason = ('Nothing was started, because the record of an earlier capture is still in place and starting would overwrite it: ' +
            (@($records | ForEach-Object { "$($_.Detail) $($_.StopWith)" }) -join '; '))
        return [pscustomobject]$result
    }

    <#
        WHICH MECHANISM, decided from which tools could and could not answer.

        Until 2026-09-23 this refused whenever ANY tool was undetermined. On a Defender-managed
        machine pktmon always is - Defender holds its single session - so the one capture this
        toolbox automated could never start on any machine it would ever run on. The refusal
        message itself said "use netsh trace instead", and the reasoning recorded here on
        2026-09-16 called refusing pktmon "a mechanism, not the capability". Nothing ever
        acted on either sentence. Finding 292.

        netsh trace captures in its OWN session and does not contend for pktmon's - measured
        running alongside Defender's session (finding 232). So:

          pktmon   when every tool answered and pktmon is present. Preferred: its stop is a
                   single idempotent command.
          netsh    when pktmon is the ONLY tool that could not answer, netsh itself reported
                   idle, and netsh is present. This is the managed-machine case.
          refuse   otherwise. An undetermined netsh or logman is not something to start
                   beside, for the same false-clean reason as above.

        An Unknown with no Tools list - an older record shape - is treated as undeterminable,
        because guessing which tool failed is the thing this whole design refuses to do.
    #>
    $undetermined = @($sweep | Where-Object { $_.Kind -eq 'Unknown' })
    $unknownTools = @()
    $untyped = $false
    foreach ($entry in $undetermined) {
        if ($entry.PSObject.Properties.Name -contains 'Tools' -and @($entry.Tools).Count -gt 0) {
            $unknownTools += @($entry.Tools)
        } else {
            $untyped = $true
        }
    }
    $unknownTools = @($unknownTools | Sort-Object -Unique)
    $onlyPktmonUnknown = (-not $untyped) -and ($unknownTools.Count -eq 1) -and ($unknownTools[0] -eq 'pktmon')

    $tool = $null
    if ($undetermined.Count -eq 0 -and $hasPktmon) {
        $tool = 'pktmon'
    } elseif ($hasNetsh -and ($undetermined.Count -eq 0 -or $onlyPktmonUnknown)) {
        $tool = 'netsh'
    }

    if (-not $tool) {
        $result.Reason = ('Nothing was started, because whether a capture is already running could not be ' +
            'determined: ' + (@($undetermined | ForEach-Object { $_.Detail }) -join '; ') +
            ' Starting one now could take a machine-wide capture session away from whatever already holds it.')
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }
    $etl = Join-Path $OutputPath 'PacketCapture.etl'

    if (-not $PSCmdlet.ShouldProcess($etl, "Start a packet capture with $tool")) {
        $result.Reason = 'Skipped by -WhatIf.'
        return [pscustomobject]$result
    }

    $result.Tool = $tool
    $stopWith = if ($tool -eq 'netsh') { 'netsh trace stop' } else { 'pktmon stop' }
    $liveKind = if ($tool -eq 'netsh') { 'NetshTrace' } else { 'PacketCapture' }

    # Marker first. See the note above - the ordering is the safety property. It records the
    # TOOL, because Stop-TlcDeepCapture stops only what the marker says this toolbox started.
    $marker = Get-TlcDeepCaptureMarkerPath
    [ordered]@{
        Tool        = $tool
        FilePath    = $etl
        StartedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        StartedByPid = $PID
        StopWith    = $stopWith
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $marker -Encoding utf8

    try {
        # Headers only, 128 bytes, in both tools: enough to see resets, retransmits and a relay
        # that stopped answering, without carrying a customer's media into a bundle.
        #
        # The output and the exit code are BOTH captured, and neither is assumed.
        #
        # pktmon reports failure by printing a message and returning a non-zero exit code - it
        # does not throw, and PowerShell's call operator does not raise on a non-zero exit. An
        # earlier version set Started = $true immediately after this line and was wrong in the
        # one case that matters: on a machine where the start failed, it reported a running
        # capture, wrote a marker for it, and produced no file. Measured: an unelevated start
        # returns exit code 5 with "Failed to communicate with the PktMon driver: Access is
        # denied." and the call operator completes normally.
        #
        # netsh: report=disabled, because stop otherwise writes a .cab report beside the .etl -
        # measured at 4 MB (finding 232) - which nothing asked for and which lands in a bundle.
        # overwrite=yes and maxsize bound it the way --file-size bounds pktmon.
        $startRun = if ($tool -eq 'netsh') {
            Invoke-TlcNativeCommand -FilePath 'netsh.exe' -ArgumentList @(
                'trace', 'start', 'capture=yes', 'packettruncatebytes=128', "maxsize=$MaxFileSizeMb",
                'overwrite=yes', 'report=disabled', "tracefile=$etl")
        } else {
            Invoke-TlcNativeCommand -FilePath 'pktmon.exe' -ArgumentList @(
                'start', '--capture', '--pkt-size', '128', '--file-size', "$MaxFileSizeMb", '--file-name', $etl)
        }
        $output = (@($startRun.Lines) -join [Environment]::NewLine)
        $exitCode = $startRun.ExitCode

        if ($exitCode -ne 0) {
            $first = @($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            $result.Reason = "$tool refused to start (exit $exitCode): $first"
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            return [pscustomobject]$result
        }

        # Confirmed against the tool, not inferred from the exit code.
        #
        # A zero exit is necessary but not sufficient: the point of this function is that a
        # capture is running, so the only honest confirmation is asking whether one is. This
        # also means a future tool that fails quietly cannot produce a false positive here.
        $running = @(Get-TlcStaleCaptureTrace | Where-Object { $_.Kind -eq $liveKind })
        if ($running.Count -eq 0) {
            $result.Reason = "$tool reported success but no capture is running. Nothing was started."
            # Through the helper like every other call. A raw invocation here would hit the real
            # tool even under test, and on 5.1 would carry the redirected-stderr trap into a
            # cleanup path - the worst place for a new terminating error.
            try {
                if ($tool -eq 'netsh') {
                    $null = Invoke-TlcNativeCommand -FilePath 'netsh.exe' -ArgumentList @('trace', 'stop')
                } else {
                    $null = Invoke-TlcNativeCommand -FilePath 'pktmon.exe' -ArgumentList @('stop')
                }
            } catch {
                Write-Verbose "$tool stop after a failed start also failed."
            }
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            return [pscustomobject]$result
        }

        $result.Started = $true
        $result.FilePath = $etl
        $via = if ($tool -eq 'netsh') {
            ' with netsh trace, because pktmon''s single session is held by something else (on a managed machine, Defender)'
        } else { '' }
        $result.Reason = "Capturing headers only (128 bytes) to $etl, capped at $MaxFileSizeMb MB$via."
    } catch {
        $result.Reason = "$tool could not be started: $($_.Exception.Message)"
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]$result
}

function Stop-TlcDeepCapture {
    <#
    .SYNOPSIS
        Stops a packet capture this toolbox started, and clears its marker.
    .DESCRIPTION
        STOPS ONLY WHAT THE MARKER SAYS THIS TOOLBOX STARTED.

        This used to run `pktmon stop` unconditionally, and was documented as safe to call when
        nothing is running. On a Defender-managed machine it is not: pktmon's single session
        belongs to Defender's network sensor, `pktmon stop` ends it, and restoring it needs a
        reboot (finding 222). Nothing reached that path only because Start refused on those
        machines. Once Start can succeed there with netsh trace (finding 292), guessing which
        tool to stop stops being hypothetical - so with no marker, nothing is stopped, and with
        one, only the tool it names.

        A missing marker is not an error, because this is reached from cleanup paths that
        cannot know the current state.

        The marker is cleared only after the tool reports the capture stopped. A marker removed
        first would hide a trace that is still running from the next sweep, which is worse than
        a stale marker - a stale marker causes one confusing message, a hidden trace fills a
        disk.
    #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        Stopped  = $false
        FilePath = $null
        SizeKb   = 0
        Reason   = ''
    }

    $marker = Get-TlcDeepCaptureMarkerPath
    if (-not (Test-Path -LiteralPath $marker)) {
        $result.Reason = 'No capture was recorded as started by this toolbox, so nothing was stopped.'
        return [pscustomobject]$result
    }

    $recorded = $null
    try { $recorded = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch {
        Write-Verbose "The deep capture marker could not be read: $($_.Exception.Message)"
    }
    # Read defensively: under StrictMode a missing property THROWS rather than reading as $null,
    # so a marker without a Tool field crashed this function instead of being refused - found by
    # the test that feeds it one.
    $tool = if ($recorded -and $recorded.PSObject.Properties.Name -contains 'Tool') { [string]$recorded.Tool } else { '' }

    # An unreadable marker names no tool, and stopping on a guess is the one thing this function
    # must never do. It is left in place so the sweep keeps reporting it.
    if ($tool -notin @('pktmon', 'netsh')) {
        $result.Reason = "The capture marker at $marker does not say which tool started it, so nothing was stopped. Check pktmon status and netsh trace show status by hand."
        return [pscustomobject]$result
    }

    $exe = if ($tool -eq 'netsh') { 'netsh.exe' } else { 'pktmon.exe' }
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        $result.Reason = "$exe was not found, so nothing could be stopped."
        return [pscustomobject]$result
    }

    try {
        $stopRun = if ($tool -eq 'netsh') {
            Invoke-TlcNativeCommand -FilePath 'netsh.exe' -ArgumentList @('trace', 'stop')
        } else {
            Invoke-TlcNativeCommand -FilePath 'pktmon.exe' -ArgumentList @('stop')
        }
        $output = (@($stopRun.Lines) -join [Environment]::NewLine)
        $exitCode = $stopRun.ExitCode

        # netsh returns exit 1 for "nothing to stop" - measured for the status command in
        # finding 187 - so for netsh the recognised idle phrase counts as stopped rather than
        # as a failure. Anything else non-zero is a failure, for either tool.
        $alreadyIdle = ($tool -eq 'netsh') -and ($output -match 'no trace session|not currently running')

        if ($exitCode -ne 0 -and -not $alreadyIdle) {
            # Same trap as the start path: a non-zero exit with a printed message and no
            # exception. Reporting "stopped" here would be the worst possible lie, because the
            # caller would clear the marker and a running capture would become invisible.
            $first = @($output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            $result.Reason = "$tool stop failed (exit $exitCode): $first"
            return [pscustomobject]$result
        }
        $result.Stopped = $true
    } catch {
        $result.Reason = "$tool stop failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $recordedFile = if ($recorded.PSObject.Properties.Name -contains 'FilePath') { [string]$recorded.FilePath } else { '' }
    if ($recordedFile -and (Test-Path -LiteralPath $recordedFile)) {
        $result.FilePath = $recordedFile
        $result.SizeKb = [math]::Round((Get-Item -LiteralPath $recordedFile).Length / 1KB, 1)
        $result.Reason = "Capture stopped. $($result.SizeKb) KB written to $recordedFile."
    } else {
        $result.Reason = 'Capture stopped. No capture file was recorded.'
    }

    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    return [pscustomobject]$result
}

Export-ModuleMember -Function Get-TlcSystemMemory, Get-TlcTeamsWebViewMemory, Get-TlcCaptureSample, Invoke-TlcCaptureSession, Get-TlcCaptureSummary, Stop-TlcCaptureSession, Get-TlcDeepCaptureOption, Get-TlcDeepCaptureReason, Get-TlcStaleCaptureTrace, Start-TlcDeepCapture, Stop-TlcDeepCapture, Get-TlcDeepCaptureMarkerPath, Get-TlcIsElevated
