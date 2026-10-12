Set-StrictMode -Version Latest

$script:AppxCache = $null

# The excerpt's per-line loop, compiled. Export-TlcLogExcerpt calls it once per file; the
# selection, early-exit and cap rules are documented there and must stay identical to the
# PowerShell loop this replaced. Repeats: a line's pattern is the line after its timestamp
# with every run of digits and hex made '#', and after RepeatLimit lines of one pattern the
# rest are counted rather than written. Finding 324.
#
# Compiled on first use, not at import: Add-Type costs seconds on Windows PowerShell 5.1, and only
# a run that builds an excerpt needs it - the wizard never does.
function Initialize-TlcExcerptFilter {
    if ('Tlc.ExcerptFilter' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System; using System.Collections.Generic; using System.IO;
namespace Tlc {
    public sealed class ExcerptRepeat {
        public string Pattern; public int Count; public int Omitted; public string FirstOmitted; public string LastOmitted; public string Sample;
    }
    public sealed class ExcerptFilter {
        // Every maximal run of hex characters that contains a digit becomes '#': the same rule
        // as the pattern [0-9A-Fa-f]*[0-9][0-9A-Fa-f]*, without a regex call per line, which
        // cost seconds on .NET Framework.
        private static string PatternOf(string body) {
            var result = new System.Text.StringBuilder(body.Length);
            int i = 0;
            while (i < body.Length) {
                char c = body[i];
                if (!Uri.IsHexDigit(c)) { result.Append(c); i++; continue; }
                int start = i; bool digit = false;
                while (i < body.Length && Uri.IsHexDigit(body[i])) { if (char.IsDigit(body[i])) digit = true; i++; }
                if (digit) result.Append('#'); else result.Append(body, start, i - start);
            }
            return result.ToString();
        }
        private readonly Dictionary<string, int> seen = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly Dictionary<string, ExcerptRepeat> omitted = new Dictionary<string, ExcerptRepeat>(StringComparer.Ordinal);
        private readonly string startText; private readonly string endText;
        public readonly int MaxLines; public readonly int RepeatLimit;
        public int Written; public int Omitted; public bool Truncated;

        public ExcerptFilter(string startText, string endText, int maxLines, int repeatLimit) {
            this.startText = startText; this.endText = endText; MaxLines = maxLines; RepeatLimit = repeatLimit;
        }

        public void CopyFile(TextReader reader, TextWriter writer) {
            bool seenInWindow = false;
            string line;
            while ((line = reader.ReadLine()) != null) {
                if (Written >= MaxLines) { Truncated = true; return; }
                if (line.Length < 19 || line[4] != '-') continue;
                string prefix = line.Substring(0, 19);
                if (string.CompareOrdinal(prefix, startText) < 0) continue;
                if (string.CompareOrdinal(prefix, endText) > 0) { if (seenInWindow) return; continue; }
                seenInWindow = true;
                if (RepeatLimit > 0) {
                    int space = line.IndexOf(' ');
                    string body = space > 0 ? line.Substring(space + 1) : line;
                    string pattern = PatternOf(body);
                    int count; seen.TryGetValue(pattern, out count); count++; seen[pattern] = count;
                    if (count > RepeatLimit) {
                        ExcerptRepeat repeat;
                        if (!omitted.TryGetValue(pattern, out repeat)) {
                            repeat = new ExcerptRepeat { Pattern = pattern, FirstOmitted = prefix, Sample = body };
                            omitted[pattern] = repeat;
                        }
                        repeat.LastOmitted = prefix;
                        Omitted++;
                        continue;
                    }
                }
                writer.WriteLine(line);
                Written++;
            }
        }

        public ExcerptRepeat[] GetRepeats() {
            var list = new List<ExcerptRepeat>(omitted.Values);
            foreach (var repeat in list) { repeat.Count = seen[repeat.Pattern]; repeat.Omitted = repeat.Count - RepeatLimit; }
            list.Sort((a, b) => a.Omitted != b.Omitted ? b.Omitted.CompareTo(a.Omitted) : string.CompareOrdinal(a.FirstOmitted, b.FirstOmitted));
            return list.ToArray();
        }
    }
}
"@
}

<#
    Desktop collectors.

    The Auto lane here is the reason this toolbox is worth building. New Teams
    writes rolling logs to disk continuously, so a bundle can be assembled for an
    issue that has already cleared - which is the situation this toolbox was built for.
    The Prompted lane still adds the encrypted media/signaling support files when
    a user is available to trigger them.
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

function Get-TlcLogFileStart {
    <#
    .SYNOPSIS
        Determines when a Teams log file started.
    .DESCRIPTION
        The filename carries the start time (MSTeams_2026-08-21_13-38-44.05.log) and
        is more reliable than CreationTime, which a copy or a roaming profile can
        rewrite. CreationTime is the fallback when the name does not parse.

        The value in the name is LOCAL time. Verified 2026-08-22: the file
        MSTeams_2026-08-22_00-32-43.04.log has CreationTime 00:32:43 local and
        CreationTimeUtc 05:32:43, so the name matches local - while the first line
        inside that same file reads 2026-08-22T05:32:43, which is UTC.

        The name and the contents of one file therefore use different reference
        frames. See Select-TlcLogFileInWindow for what depends on that.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $File
    )

    if ($File.Name -match '_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})') {
        try {
            return [datetime]::new(
                [int]$Matches[1], [int]$Matches[2], [int]$Matches[3],
                [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
        } catch {
            Write-Verbose "Filename timestamp did not parse for $($File.Name); using CreationTime."
        }
    }
    return $File.CreationTime
}

function Test-TlcFileHeldForWrite {
    <#
    .SYNOPSIS
        True when another handle has the file open for writing.
    .DESCRIPTION
        Opening for read while allowing only other READERS fails with a sharing violation
        exactly when a writer holds the file. Nothing is written and the handle is closed
        at once. A missing or unreadable file is reported as not held, so a permissions
        problem cannot make a closed log look live.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return $false
    } catch [System.IO.IOException] {
        # 32 is ERROR_SHARING_VIOLATION; anything else is not evidence of a writer.
        return (($_.Exception.HResult -band 0xFFFF) -eq 32)
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Select-TlcLogFileInWindow {
    <#
    .SYNOPSIS
        Selects log files whose lifetime overlaps the repro window.
    .DESCRIPTION
        Overlap, not containment. A single rolling log routinely spans hours, so a
        file that started before the window and was still being written during it
        is exactly the file that holds the evidence.

        WindowStart and WindowEnd must be LOCAL. Both sides of the comparison here are
        local - the filename timestamp and LastWriteTime - so a UTC window would
        select the wrong files by the size of the offset, silently.

        This is the half of the pair that is easy to get wrong: Export-TlcLogExcerpt
        takes the same local window and converts it to UTC internally, because the
        timestamps inside the files are UTC while the names are not. One window, two
        frames, and the conversion belongs in the function that reads the contents.
        The entry point passes Scope.WindowStart.LocalTime to both for that reason.
    #>
    [CmdletBinding()]
    param(
        # An empty folder is a real case - Teams installed, nothing logged yet - and it was a
        # parameter-binding error rather than the "no client logs" row (review 2026-09-30).
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowNull()] [System.IO.FileInfo[]] $Files,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd
    )

    foreach ($file in @($Files | Where-Object { $_ })) {
        # Re-read from the file itself before trusting either value. Get-ChildItem returns
        # the DIRECTORY ENTRY's copy of LastWriteTime and Length, and NTFS updates that
        # lazily while a writer holds the file open - which Teams always does for the log
        # it is writing. Measured 2026-09-24 mid-call: the active MSTeams log enumerated as
        # 22:48:20 / 79,381 bytes while the file itself read 22:48:56 / 438,451, and the
        # SlimCore media log enumerated 18:23:33 against a real 22:48:08, four and a half
        # hours stale. Both editions. The file that holds the evidence is exactly the one
        # an enumerated timestamp drops from a recent window. Finding 299.
        $file.Refresh()
        $start = Get-TlcLogFileStart -File $file
        $end = $file.LastWriteTime

        # A log that is still open has not ended. Its last write is only the last time it had
        # something to say, and SlimCore - the media log - writes at call setup and teardown
        # and is silent in between. Measured on a live call: a 50-second capture mid-call
        # took the MSTeams log and dropped the SlimCore log of the very call being sampled,
        # because its last write predated the session by eight minutes. Only checked when it
        # would change the answer, and only a writer's handle counts.
        $stillOpen = $false
        if ($end -lt $WindowStart -and $start -le $WindowEnd) {
            $stillOpen = Test-TlcFileHeldForWrite -Path $file.FullName
            if ($stillOpen) { $end = Get-Date }
        }

        if ($start -le $WindowEnd -and $end -ge $WindowStart) {
            [pscustomobject]@{
                File      = $file
                StartTime = $start
                EndTime   = $end
                SizeBytes = $file.Length
                StillOpen = $stillOpen
            }
        }
    }
}

function Open-TlcSharedRead {
    <#
    .SYNOPSIS
        Opens a file for reading even while Teams is writing to it.
    .DESCRIPTION
        Teams keeps its current log open, and the current log is usually the one
        holding the evidence. The default StreamReader constructor requests a share
        mode the running client will not grant, so the active log - the file that
        matters most - is the one that fails. Explicitly allowing ReadWrite and
        Delete lets the copy proceed against a live writer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    return [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
}

function Copy-TlcOpenFile {
    <#
    .SYNOPSIS
        Copies a file that may be locked by a running process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination
    )

    $source = Open-TlcSharedRead -Path $Path
    try {
        $target = [System.IO.File]::Create($Destination)
        try {
            $source.CopyTo($target)
        } finally {
            $target.Dispose()
        }
    } finally {
        $source.Dispose()
    }
}

function ConvertFrom-TlcLogTimestamp {
    <#
    .SYNOPSIS
        Parses a Teams log line timestamp.
    .DESCRIPTION
        Verified 2026-08-21 against MSTeams 26225.1803.5037.3180, and this is a trap
        worth spelling out. A log line looks like:

            2026-08-21T19:23:53.355634-05:00

        The file itself was created at 14:23:53 local, which is 19:23:53 UTC. So the
        time VALUE is UTC, but the client appends the LOCAL offset to it. The suffix
        is misleading rather than descriptive.

        Both obvious readings are wrong by the offset:
          - treating the value as local time     -> 5 hours early here
          - parsing it as a DateTimeOffset       -> 5 hours late here (19:23 -05:00 = 00:23Z)

        The only correct reading is to take the date and time component and treat it
        as UTC, discarding the offset. Returns $null when the line is not a
        timestamped log line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Line
    )

    if ($Line.Length -lt 19 -or $Line[4] -ne '-') { return $null }

    if ($Line -notmatch '^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(\.\d+)?') { return $null }

    $text = "$($Matches[1])T$($Matches[2])$($Matches[3])"
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($text, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $null
    }

    return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
}

# Messages the Teams client writes in volume that are known not to be a fault on the machine,
# matched against the text of a repeating line after its timestamp.
$script:KnownLogNoise = @(
    @{
        # Finding 326. TeamsProcessInfo::GetTeamsAndWv2Processes logs "Running as Admin, checking
        # for explorer.exe children" and then opens every process on the machine; each one the
        # signed-in user may not open logs a WIL Exception and LogHr pair from psutils_win.cpp,
        # 80070057 for the System Idle Process that starts each burst and 80070005 for the rest.
        # Measured on two machines on build 26246.1606.5149.6600: 165 to 196 failures a scan,
        # every 12 seconds on one and every 2 minutes on the other, 85 to 94 percent of the bytes
        # in the main log.
        Pattern = 'psutils_win\.cpp\(\d+\).*\b800700(05|57)\b'
        Note    = 'Known Teams client noise, not a fault on this machine: when the signed-in user is in the local Administrators group, Teams opens every process to find its own and logs an error, nearly always Access is denied, for each one it may not open, a burst of lines each time it looks. It is why the main Teams log reaches back less far than usual.'
    }
)

function Get-TlcLogNoiseNote {
    <#
    .SYNOPSIS
        Says what a known repeating Teams message means, or returns nothing for any other.
    .DESCRIPTION
        A flood of errors reads as the fault until someone has chased it down. Finding 326
        chased one: the Access Denied errors from psutils_win.cpp are the Teams client's own
        process scan, not a problem on the machine it runs on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [AllowNull()] [string] $Sample)

    if (-not $Sample) { return $null }
    foreach ($noise in $script:KnownLogNoise) {
        if ($Sample -match $noise.Pattern) { return $noise.Note }
    }
    return $null
}

function Export-TlcLogExcerpt {
    <#
    .SYNOPSIS
        Writes the log lines that fall inside the repro window.
    .DESCRIPTION
        Support wants whole files, but whole files are 2 MB each and a triage pass
        should not require reading all of them. The excerpt is an index, not a
        replacement, so the full files ship alongside it.

        See ConvertFrom-TlcLogTimestamp for why line timestamps are treated as UTC
        and their offset suffix ignored.

        Performance note, because this is the single most expensive thing the toolbox
        does. An earlier version called ConvertFrom-TlcLogTimestamp per line, which
        meant a function call, a regex and a DateTime parse for every one of roughly a
        hundred thousand lines - eleven seconds on a five megabyte collection.

        The timestamps are fixed-width ISO-8601, and ISO-8601 sorts lexicographically
        in the same order as it sorts chronologically. So the window bounds are
        rendered once as strings and each line is compared as a string. No parsing, no
        allocation, and the comparison is exact rather than approximate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $Files,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [int] $MaxLines = 20000,
        # How many lines of one repeating message are written before the rest are counted
        # instead. A client that logs the same error many times a second filled the whole cap
        # with it: on the lab endpoint, 20,000 lines covered three minutes of a 31-minute window,
        # nearly all of them one Access Denied error. Every line stays in the full logs beside
        # the excerpt. 0 writes everything. Finding 324.
        [int] $RepeatLimit = 20
    )

    $startUtc = $WindowStart.ToUniversalTime()
    $endUtc = $WindowEnd.ToUniversalTime()

    # 'yyyy-MM-ddTHH:mm:ss' - the first 19 characters of a log line.
    #
    # TRUNCATION IS CORRECT HERE, and it is wrong a few hundred lines below in
    # Export-TlcLogTimeline. The difference is what the comparison decides.
    #
    # This is SELECTION, and both the bounds and the line are truncated to the same whole
    # second, so the window is inclusive of its first and last second. A line at
    # 04:16:10.999999 is kept when the window ends at 04:16:10 - over-inclusive by under a
    # second, at both ends. That is the safe direction for evidence: including a line
    # marginally outside the window costs a line of noise, excluding one inside it loses
    # evidence silently, and nobody reviewing the bundle can tell that it happened.
    # Verified empirically 2026-09-10.
    #
    # The timeline's key is ORDERING, where truncation made lines inside the same second
    # fall back to file order and produced two inverted pairs in a real 20,000-line run.
    # See finding 145. Do not "fix" the two the same way - narrowing this one would turn a
    # harmless surplus into silent evidence loss.
    $startText = $startUtc.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $endText = $endUtc.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

    $unreadable = [System.Collections.Generic.List[string]]::new()

    # The per-line work runs in compiled code: PowerShell 7 pays about ten times what 5.1 does
    # per method call, and with repeats being counted this loop took 22 s on 7 for a 34 MB log
    # (finding 324, the same cause as findings 304 and 313). Selection, early exit and the cap
    # are exactly the rules described above; see Tlc.ExcerptFilter.
    Initialize-TlcExcerptFilter
    $filter = [Tlc.ExcerptFilter]::new($startText, $endText, $MaxLines, $RepeatLimit)

    $writer = [System.IO.StreamWriter]::new($DestinationPath, $false, [System.Text.Encoding]::UTF8)
    try {
        $writer.WriteLine("# TLC window excerpt: $($startUtc.ToString('o')) to $($endUtc.ToString('o')) UTC")
        $writer.WriteLine('# Line timestamps are UTC values; the offset suffix written by Teams is ignored.')

        foreach ($file in $Files) {
            $writer.WriteLine("===== $($file.Name) =====")

            $stream = $null
            $reader = $null
            try {
                $stream = Open-TlcSharedRead -Path $file.FullName
                $reader = [System.IO.StreamReader]::new($stream)
            } catch {
                # One locked or vanished file must not abort the whole excerpt.
                $unreadable.Add($file.Name)
                $writer.WriteLine("[TLC] Could not read this file: $($_.Exception.Message)")
                if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
                continue
            }

            try {
                $filter.CopyFile($reader, $writer)
            } finally {
                $reader.Dispose()
            }
            if ($filter.Truncated) { break }
        }

        if ($filter.Truncated) {
            $writer.WriteLine("[TLC] Excerpt truncated at $MaxLines lines. The full logs are alongside this file.")
        }

        # What was left out, by pattern, most first. At the end because the excerpt is written
        # as it is read; the manifest and Blockers.csv carry the same facts to the top.
        $repeats = @($filter.GetRepeats() | ForEach-Object {
            [pscustomobject][ordered]@{
                Count = $_.Count; Omitted = $_.Omitted; FirstOmitted = $_.FirstOmitted; LastOmitted = $_.LastOmitted; Sample = $_.Sample
                # What a known flood means, where one is known (finding 326).
                Note  = Get-TlcLogNoiseNote -Sample $_.Sample
            }
        })
        if ($repeats.Count -gt 0) {
            $writer.WriteLine("[TLC] Repeating messages: after the first $RepeatLimit lines of each, $($filter.Omitted) further line(s) were left out of this excerpt. The full logs alongside it have every line.")
            foreach ($repeat in $repeats) {
                $text = if ($repeat.Sample.Length -gt 300) { $repeat.Sample.Substring(0, 300) + '...' } else { $repeat.Sample }
                $writer.WriteLine("[TLC]   $($repeat.Count) in the window, $($repeat.Omitted) left out, $($repeat.FirstOmitted) to $($repeat.LastOmitted) UTC: $text")
                if ($repeat.Note) { $writer.WriteLine("[TLC]     $($repeat.Note)") }
            }
        }
    } finally {
        $writer.Dispose()
    }

    return [pscustomobject]@{
        Path       = $DestinationPath
        LineCount  = $filter.Written
        Truncated  = $filter.Truncated
        Unreadable = @($unreadable)
        Omitted    = $filter.Omitted
        Repeats    = $repeats
    }
}
function Export-TlcLogTimeline {
    <#
    .SYNOPSIS
        Merges the window excerpt into one chronological stream across log families.
    .DESCRIPTION
        Window-Excerpt.log is an index grouped by file, which was comfortable when three
        log families were collected. Collection now spans seven, so a single launch
        sequence is spread across nine sections and the reader has to stitch the ordering
        together by eye. That is exactly the work a machine should do.

        This writes a second artifact rather than replacing the excerpt, because the two
        answer different questions. The excerpt answers "what did THIS component do", which
        is what you want once you know where to look. The timeline answers "what happened,
        in order", which is what you want first - and it is the view that shows an update
        finishing moments before a renderer crash, across two files that would otherwise be
        four sections apart.

        It is built from the excerpt rather than from the source logs on purpose. The
        excerpt is already the filtered subset - at most MaxLines lines rather than the
        hundred thousand in the originals - so merging costs a read of a small file instead
        of a second pass over every log. It also inherits the excerpt's truncation, which
        keeps the two artifacts describing the same set of lines rather than disagreeing.

        Sorting is on the timestamp as an ordinal string, the same trick the excerpt uses to
        avoid parsing: fixed-width ISO-8601 sorts lexicographically in chronological order.
        The sort is stable, so lines sharing a timestamp keep their original file order
        rather than being shuffled.

        THE KEY INCLUDES FRACTIONAL SECONDS, and that is not a detail. An earlier version
        used the 19-character prefix, which stops at whole seconds - so two lines in the same
        second sorted by file order instead of by time. Measured on a real 20,000-line
        timeline: only 2 pairs were affected, but both were two families writing inside the
        same second, which is the exact case this artifact exists to resolve. A timeline that
        is right 99.99% of the time and wrong precisely where cross-family causality is being
        read is worse than no timeline, because it will be believed. Teams writes six
        fractional digits; the key takes whatever is there and pads it, so families with
        differing precision still compare correctly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExcerptPath,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    if (-not (Test-Path -LiteralPath $ExcerptPath)) {
        return [pscustomobject]@{ Path = $DestinationPath; LineCount = 0; SourceCount = 0; Written = $false }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $sources = [System.Collections.Generic.List[string]]::new()
    $current = '(unknown)'
    $order = 0

    foreach ($line in [System.IO.File]::ReadLines($ExcerptPath)) {
        if ($line.StartsWith('===== ')) {
            $current = $line.Trim('= ').Trim()
            $sources.Add($current)
            continue
        }
        if ($line.StartsWith('#') -or $line.StartsWith('[TLC]')) { continue }
        if ($line.Length -lt 19 -or $line[4] -ne '-') { continue }

        # Seconds, then fractional digits padded to a fixed width so the whole thing stays
        # ordinally comparable. A line with no fraction pads to zeros and therefore sorts
        # before anything within the same second, which is the correct reading of "no
        # fraction recorded".
        $key = $line.Substring(0, 19)
        $fraction = ''
        if ($line.Length -gt 20 -and $line[19] -eq '.') {
            $index = 20
            while ($index -lt $line.Length -and [char]::IsDigit($line[$index])) {
                $fraction += $line[$index]
                $index++
            }
        }
        $key = $key + '.' + $fraction.PadRight(7, '0')

        $entries.Add([pscustomobject]@{
            Key    = $key
            Order  = $order++
            Source = $current
            Line   = $line
        })
    }

    # Shortened for the left column: the family is the useful part, and the timestamp is
    # already on the line itself.
    $label = {
        param($name)
        $trimmed = $name -replace '_\d{4}-\d{2}-\d{2}.*$', '' -replace '\.log$', ''
        if ($trimmed.Length -gt 22) { $trimmed.Substring(0, 22) } else { $trimmed }
    }

    $writer = [System.IO.StreamWriter]::new($DestinationPath, $false, [System.Text.Encoding]::UTF8)
    try {
        $writer.WriteLine('# TLC window timeline: every in-window line from every log family, merged in order.')
        $writer.WriteLine('# Source is the log family the line came from. Window-Excerpt.log has the same lines grouped by file.')
        $writer.WriteLine('# Line timestamps are UTC values; the offset suffix written by Teams is ignored.')

        foreach ($entry in ($entries | Sort-Object Key, Order)) {
            $writer.WriteLine(('{0,-22}  {1}' -f (& $label $entry.Source), $entry.Line))
        }
    } finally {
        $writer.Dispose()
    }

    return [pscustomobject]@{
        Path        = $DestinationPath
        LineCount   = $entries.Count
        SourceCount = @($sources | Sort-Object -Unique).Count
        Written     = $true
    }
}

function Get-TlcLogSpan {
    <#
    .SYNOPSIS
        The stretches of time a set of log files covers, merged where one file follows on
        from the last.
    .DESCRIPTION
        Teams keeps only its most recent seven MSTeams_*.log files for a running client and
        the last seven of each earlier session, so the folder can reach back a month while
        holding nothing for most of it. The oldest file therefore says nothing about whether a
        window in between is covered: that needs the spans. Finding 325.

        A file runs from the time in its name to its last write. The newest file is still
        being written when a writer holds it, and a quiet client is not a gap, so that one
        runs to now. Files that meet, allowing ToleranceMinutes between one's last write and
        the next one's start, are one span; a restart leaves a real gap.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [System.IO.FileInfo[]] $Files,
        [int] $ToleranceMinutes = 2,
        [datetime] $Now = (Get-Date)
    )

    $items = @(
        foreach ($file in @($Files | Where-Object { $_ })) {
            $file.Refresh()
            if (-not $file.Exists) { continue }
            [pscustomobject]@{ File = $file; Start = Get-TlcLogFileStart -File $file; End = $file.LastWriteTime }
        }
    ) | Sort-Object Start
    $items = @($items)
    if ($items.Count -eq 0) { return @() }

    $newest = $items[-1]
    if (Test-TlcFileHeldForWrite -Path $newest.File.FullName) { $newest.End = $Now }

    $spans = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($item in $items) {
        $end = if ($item.End -lt $item.Start) { $item.Start } else { $item.End }
        if ($current -and $item.Start -le $current.End.AddMinutes($ToleranceMinutes)) {
            if ($end -gt $current.End) { $current.End = $end }
            $current.Files++
            continue
        }
        $current = [pscustomobject]@{ Start = $item.Start; End = $end; Files = 1 }
        $spans.Add($current)
    }
    return $spans.ToArray()
}

function Get-TlcSpanGap {
    <#
    .SYNOPSIS
        The parts of a window that no span covers, ignoring gaps shorter than a minute.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $Spans,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [int] $MinimumMinutes = 1
    )

    $gaps = [System.Collections.Generic.List[object]]::new()
    $cursor = $WindowStart
    foreach ($span in @($Spans | Where-Object { $_ } | Sort-Object Start)) {
        if ($span.End -le $cursor) { continue }
        if ($span.Start -ge $WindowEnd) { break }
        if ($span.Start -gt $cursor) {
            $gaps.Add([pscustomobject]@{ Start = $cursor; End = $span.Start })
        }
        if ($span.End -gt $cursor) { $cursor = $span.End }
        if ($cursor -ge $WindowEnd) { break }
    }
    if ($cursor -lt $WindowEnd) { $gaps.Add([pscustomobject]@{ Start = $cursor; End = $WindowEnd }) }
    return @($gaps | Where-Object { ($_.End - $_.Start).TotalMinutes -ge $MinimumMinutes })
}

function Save-TlcRotatedClientLog {
    <#
    .SYNOPSIS
        Copies Teams client logs that have rotated since a live session began, before Teams
        deletes them.
    .DESCRIPTION
        Teams keeps only its most recent MSTeams_*.log files for a running client: seven,
        measured on two machines on 2026-09-29, each capped near 2 MB. How long that covers
        depends on how much the client logs - about 22 minutes on a machine whose client was
        logging an Access Denied error eighteen times a second, about two hours on a quiet one.
        Older files of the running session are deleted as new ones start; only the last seven
        of each earlier session survive, which is why the folder still reaches back a month.

        So a live trace longer than that lost its beginning: a 31-minute trace collected main
        logs from minute 10 onwards, because the closing pass runs after the session and the
        first ten minutes were already gone. Finding 321.

        Called periodically during the session. The newest file of each family is the one being
        written, so it is left for the closing pass; everything older that was written during
        the session is copied once, into the same ClientLogs folder the closing pass uses.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [hashtable] $Collection,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [Parameter(Mandatory)] [datetime] $Since,
        # Names already copied, carried between calls so each file is copied once.
        [System.Collections.Generic.HashSet[string]] $Saved
    )

    $logRoot = Resolve-TlcPath -Path $Collection.ClientLogRoot
    if (-not (Test-Path -LiteralPath $logRoot)) { return @() }
    $destination = Join-Path $EndpointPath 'ClientLogs'

    $new = foreach ($pattern in @($Collection.ClientRollingLogPatterns)) {
        $files = @(Get-ChildItem -LiteralPath $logRoot -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($files.Count -lt 2) { continue }
        foreach ($file in $files[0..($files.Count - 2)]) {
            if ($file.LastWriteTime -lt $Since) { continue }
            if ($Saved -and $Saved.Contains($file.Name)) { continue }
            try {
                if (-not (Test-Path -LiteralPath $destination)) { $null = New-Item -ItemType Directory -Path $destination -Force }
                $copy = Join-Path $destination $file.Name
                Copy-TlcOpenFile -Path $file.FullName -Destination $copy
                # The source's times, kept: once Teams deletes the source, the copy's last write
                # is the only record of when that file ended, and coverage is judged from it.
                [System.IO.File]::SetCreationTime($copy, $file.CreationTime)
                [System.IO.File]::SetLastWriteTime($copy, $file.LastWriteTime)
            } catch {
                Write-Verbose "$($file.Name) could not be kept: $($_.Exception.Message)"
                continue
            }
            if ($Saved) { $null = $Saved.Add($file.Name) }
            $file.Name
        }
    }
    return @($new)
}

function Invoke-TlcClientLogCollection {
    <#
    .SYNOPSIS
        Auto lane. Harvests on-disk Teams client logs for the repro window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Collection,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $logRoot = Resolve-TlcPath -Path $Collection.ClientLogRoot
    if (-not (Test-Path -LiteralPath $logRoot)) {
        Write-TlcBlocker -Check 'ClientLogs' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
            -Detail "Teams client log folder not found: $logRoot" `
            -Remediation 'Confirm new Teams is installed for this user profile.' | Out-Null
        Write-TlcEvent -Phase 'Collect' -Step 'ClientLogs' -Status 'Failed' -Severity 'Critical' -Endpoint $Endpoint `
            -Message "Log root missing: $logRoot"
        return $null
    }

    $candidates = @(foreach ($pattern in $Collection.ClientLogPatterns) {
        Get-ChildItem -LiteralPath $logRoot -Filter $pattern -File -ErrorAction SilentlyContinue
    })

    $selected = @(Select-TlcLogFileInWindow -Files $candidates -WindowStart $WindowStart -WindowEnd $WindowEnd |
        Sort-Object StartTime)

    if ($selected.Count -eq 0) {
        # Name what IS on disk, not just what is missing. "No client logs overlap the repro
        # window" is accurate and leaves the engineer with nowhere to go; the next question is
        # always "then what window should I use", and the answer is sitting in $candidates.
        #
        # Measured 2026-09-11 on a real machine: a default 30/30 window selected 0 files while
        # 28 were present on disk. The old message reported the zero and never mentioned the
        # 28, so a collection that looked empty was indistinguishable from a machine with no
        # logs at all.
        $available = @($candidates | ForEach-Object { Get-TlcLogFileStart -File $_ } | Where-Object { $_ })
        $coverage = ''
        if ($available.Count -gt 0) {
            $earliest = ($available | Sort-Object | Select-Object -First 1)
            $latest = ($available | Sort-Object | Select-Object -Last 1)
            $coverage = " $($candidates.Count) log file(s) are present, covering $($earliest.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) to $($latest.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) local."
        } elseif ($candidates.Count -gt 0) {
            $coverage = " $($candidates.Count) log file(s) are present but none carry a readable start time."
        }

        Write-TlcBlocker -Check 'ClientLogs' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "No client logs overlap the repro window ($WindowStart to $WindowEnd).$coverage" `
            -Remediation 'Confirm the impact time, or widen the window with -WindowBeforeMinutes/-WindowAfterMinutes to cover the span above.' | Out-Null
        Write-TlcEvent -Phase 'Collect' -Step 'ClientLogs' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Message "No client logs overlap the repro window.$coverage"
        return $null
    }

    $destination = Join-Path $EndpointPath 'ClientLogs'
    $null = New-Item -ItemType Directory -Path $destination -Force

    $budgetBytes = [int64]$Collection.MaxBundleSizeMB * 1MB
    $used = [int64]0
    $copied = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()

    # The budget is spent nearest-first: files are ranked by how far the middle of each
    # one's span lies from the middle of the window. Spent in start order, as it was, the
    # old logs a running client still holds open (launcher, SlimCore) took the budget first,
    # and a simulated 1 MB budget kept those and skipped every main client log in the window -
    # the evidence the collection exists for. The copied files are still recorded in start
    # order. Finding 310.
    $windowMiddle = $WindowStart.AddTicks(($WindowEnd - $WindowStart).Ticks / 2)
    $byProximity = @($selected | Sort-Object {
        $middle = $_.StartTime.AddTicks(($_.EndTime - $_.StartTime).Ticks / 2)
        [math]::Abs(($middle - $windowMiddle).TotalSeconds)
    })
    $admitted = [System.Collections.Generic.HashSet[string]]::new()
    $planned = [int64]0
    foreach ($item in $byProximity) {
        if (($planned + $item.SizeBytes) -le $budgetBytes) {
            $null = $admitted.Add($item.File.FullName)
            $planned += $item.SizeBytes
        }
    }

    foreach ($item in $selected) {
        if (-not $admitted.Contains($item.File.FullName)) {
            $skipped.Add($item.File.Name)
            continue
        }
        try {
            $target = Join-Path $destination $item.File.Name
            Copy-TlcOpenFile -Path $item.File.FullName -Destination $target
            $copiedBytes = (Get-Item -LiteralPath $target -ErrorAction Stop).Length
        } catch {
            Write-Verbose "$($item.File.Name) could not be copied or measured: $($_.Exception.Message)"
            $failed.Add($item.File.Name)
            continue
        }
        $used += $copiedBytes
        $copied.Add([ordered]@{
            Name      = $item.File.Name
            StartTime = $item.StartTime.ToString('o')
            EndTime   = $item.EndTime.ToString('o')
            SizeBytes = $copiedBytes
            StillOpen = [bool]$item.StillOpen
        })
    }

    if ($skipped.Count -gt 0) {
        Write-TlcBlocker -Check 'ClientLogs.SizeBudget' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$($skipped.Count) log file(s) skipped; bundle budget of $($Collection.MaxBundleSizeMB) MB reached. Skipped, furthest from the middle of the window: $($skipped -join ', '). Their lines inside the window are still in Window-Excerpt.log." `
            -Remediation 'Raise Collection.MaxBundleSizeMB or narrow the repro window.' | Out-Null
    }

    if ($used -gt $budgetBytes) {
        Write-TlcBlocker -Check 'ClientLogs.SizeBudget' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "Client logs grew after selection: copied $used bytes against a selection budget of $budgetBytes bytes. Full copied files were retained." `
            -Remediation 'Use a narrower window or a larger Collection.MaxBundleSizeMB budget on the next collection. The existing evidence has not been truncated or deleted.' | Out-Null
    }

    if ($failed.Count -gt 0) {
        Write-TlcBlocker -Check 'ClientLogs.Locked' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$($failed.Count) log file(s) could not be read: $($failed -join ', ')" `
            -Remediation 'Re-run the collection, or close Teams and re-run to capture the active log.' | Out-Null
    }

    $excerpt = Export-TlcLogExcerpt -Files ($selected | ForEach-Object { $_.File }) `
                                    -WindowStart $WindowStart -WindowEnd $WindowEnd `
                                    -DestinationPath (Join-Path $destination 'Window-Excerpt.log')

    # The excerpt reads every selected file, including any the size budget left out of the
    # bundle - their lines in the window are worth having - but it says "the full logs are
    # alongside", which is not true of those. Said at its end, where the other notes are
    # (review 2026-09-30).
    if ($skipped.Count -gt 0) {
        [System.IO.File]::AppendAllText($excerpt.Path,
            "[TLC] Not copied in full, because of the $($Collection.MaxBundleSizeMB) MB size budget: $($skipped -join ', '). Their lines inside the window are in this excerpt; the rest of those files is not in the bundle.$([Environment]::NewLine)",
            (New-Object System.Text.UTF8Encoding($false)))
    }

    # The main client log's coverage of the window, from the files that exist - in the log
    # folder, and copies already in ClientLogs whose source Teams has since deleted, which is
    # what a live trace keeps as they rotate. Up to now at most: the rest has not happened.
    # The folder reaching back a month said nothing about a window inside it. Finding 325.
    $mainPattern = if (@($Collection['ClientRollingLogPatterns']).Count -gt 0 -and @($Collection['ClientRollingLogPatterns'])[0]) { [string]@($Collection['ClientRollingLogPatterns'])[0] } else { 'MSTeams_*.log' }
    $mainFiles = @($candidates | Where-Object { $_ -and $_.Name -like $mainPattern })
    $sourceNames = @($mainFiles | ForEach-Object { $_.Name })
    $keptCopies = @(Get-ChildItem -LiteralPath $destination -File -Filter $mainPattern -ErrorAction SilentlyContinue | Where-Object { $sourceNames -notcontains $_.Name })
    $coverageEnd = if ($WindowEnd -gt (Get-Date)) { Get-Date } else { $WindowEnd }
    $mainGaps = @()
    if ($coverageEnd -gt $WindowStart -and @($mainFiles + $keptCopies).Count -gt 0) {
        $mainGaps = @(Get-TlcSpanGap -Spans (Get-TlcLogSpan -Files @($mainFiles + $keptCopies)) -WindowStart $WindowStart -WindowEnd $coverageEnd)
    }
    if ($mainGaps.Count -gt 0) {
        $gapMinutes = [int][math]::Round((@($mainGaps | ForEach-Object { ($_.End - $_.Start).TotalMinutes }) | Measure-Object -Sum).Sum)
        $ranges = @($mainGaps | Select-Object -First 5 | ForEach-Object { "$($_.Start.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) to $($_.End.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))" }) -join '; '
        Write-TlcBlocker -Check 'ClientLogs.Gap' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "The main Teams log ($mainPattern) has nothing for $gapMinutes minute(s) of the window, local time: $ranges. Teams keeps only its most recent seven of these files for a running client, so the earlier part of a long session is deleted as it logs, and a restart leaves a short gap. The other logs, the event logs and the client state in this bundle may still cover it." `
            -Remediation 'Nothing collected later can recover it. For a fault that recurs, collect soon after it happens, or run a live trace, which keeps these files as they rotate.' | Out-Null
    }

    # The merged view. Built from the excerpt, so it costs a read of an already-filtered
    # file rather than a second pass over every source log.
    $timeline = Export-TlcLogTimeline -ExcerptPath $excerpt.Path `
                                      -DestinationPath (Join-Path $destination 'Window-Timeline.log')

    $manifest = [ordered]@{
        LogRoot        = $logRoot
        WindowStart    = $WindowStart.ToString('o')
        WindowEnd      = $WindowEnd.ToString('o')
        CandidateCount = @($candidates).Count
        SelectedCount  = $selected.Count
        CopiedCount    = $copied.Count
        SkippedForSize = @($skipped)
        FailedToRead   = @($failed)
        BytesCopied    = $used
        Excerpt        = [ordered]@{
            LineCount  = $excerpt.LineCount
            Truncated  = $excerpt.Truncated
            Unreadable = @($excerpt.Unreadable)
            # Lines of a repeating message left out after its first few (finding 324).
            Omitted    = $excerpt.Omitted
            Repeats    = @(@($excerpt.Repeats) | Select-Object -First 10)
        }
        Timeline       = [ordered]@{
            LineCount   = $timeline.LineCount
            SourceCount = $timeline.SourceCount
        }
        # Local times the main client log does not cover inside the window (finding 325).
        MainLogGaps    = @($mainGaps | ForEach-Object { [ordered]@{ Start = $_.Start.ToString('o'); End = $_.End.ToString('o') } })
        Files          = @($copied)
    }

    $manifestPath = Join-Path $destination 'ClientLogs.manifest.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    # A truncated excerpt is the difference between "here is your window" and "here is
    # the start of your window". An engineer reading Window-Excerpt.log has no way to
    # tell which they got unless we say so somewhere they actually look, so this is
    # raised as a Blockers.csv warning rather than left buried in the manifest JSON.
    if ($excerpt.Truncated) {
        Write-TlcBlocker -Check 'ClientLogs.Excerpt' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "Window-Excerpt.log stops at the $($excerpt.LineCount)-line cap and does not cover the whole window." `
            -Remediation 'Narrow the window, or read the full per-file logs copied alongside the excerpt.' | Out-Null
    }

    if (@($excerpt.Unreadable).Count -gt 0) {
        Write-TlcBlocker -Check 'ClientLogs.Excerpt' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$(@($excerpt.Unreadable).Count) file(s) could not be read into the excerpt." `
            -Remediation 'See Excerpt.Unreadable in ClientLogs.manifest.json for the file list and reasons.' | Out-Null
    }

    # A flood is evidence in its own right, and it is also why Teams' own logs reach back less
    # far than expected: the client keeps a fixed number of files, and one message written many
    # times a second fills them. Measured on the lab endpoint: one Access Denied error, about
    # eighteen times a second, left seven files covering 22 minutes. Finding 324. That error
    # turned out to be the client's own process scan, so a flood Teams is known to produce says
    # so rather than inviting a chase (finding 326).
    $flood = @(@($excerpt.Repeats) | Where-Object { $_.Omitted -ge 1000 })
    if ($flood.Count -gt 0) {
        $top = $flood[0]
        $text = if ($top.Sample.Length -gt 200) { $top.Sample.Substring(0, 200) + '...' } else { $top.Sample }
        $remediation = if ($top.Note) {
            "$($top.Note) Nothing on this machine needs fixing for it. The full logs have every line; to keep more of them, collect soon after a fault or run a live trace."
        } else {
            'The full logs have every line. A message repeating this often shortens how far back Teams'' own logs reach; if it is an error, it may be the fault or a separate problem worth raising.'
        }
        Write-TlcBlocker -Check 'ClientLogs.Repeats' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
            -Detail ("Teams wrote one message $($top.Count) times in the window; $($top.Omitted) of them were left out of Window-Excerpt.log after the first few" +
                     $(if ($flood.Count -gt 1) { ", and $($flood.Count - 1) other message(s) repeated over a thousand times" } else { '' }) + ": $text") `
            -Remediation $remediation | Out-Null
    }

    Write-TlcEvent -Phase 'Collect' -Step 'ClientLogs' -Status 'Complete' -Endpoint $Endpoint `
        -Message "Copied $($copied.Count) of $($selected.Count) overlapping log file(s); excerpt $($excerpt.LineCount) line(s)." `
        -EvidencePath $manifestPath

    # Which log series made it, not just how many files. A CallQuality bundle that took the
    # client log and silently missed SlimCore - the media log - read "1 file(s)" and looked
    # complete. Naming the series makes a missing one visible in the row an engineer reads.
    $series = @($copied | Group-Object { [string]$_.Name -replace '_\d{4}-\d{2}-\d{2}_.*$', '' } |
        Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    Write-TlcBlocker -Check 'ClientLogs' -Status 'Success' -Endpoint $Endpoint `
        -Detail "$($copied.Count) file(s) ($series), $([math]::Round($used/1MB,1)) MB, excerpt $($excerpt.LineCount) line(s)." | Out-Null

    return $manifest
}

function Get-TlcAppxPackage {
    <#
    .SYNOPSIS
        Returns the Teams and SlimCore packages, enumerating Appx once.
    .DESCRIPTION
        Get-AppxPackage enumerates every installed package and costs over a second.
        It was being called twice here and again from Get-TlcEnvironmentFact, so a
        single collection paid for it three times. One call, cached for the session,
        because the set of installed packages does not change during a run.
    #>
    [CmdletBinding()]
    param([switch] $Refresh)

    if ($Refresh) { $script:AppxCache = $null }

    if ($null -eq $script:AppxCache) {
        $packages = @()
        try {
            $packages = @(Get-AppxPackage -ErrorAction Stop)
        } catch {
            Write-Verbose "Get-AppxPackage is unavailable: $($_.Exception.Message)"
        }

        $script:AppxCache = [ordered]@{
            Teams    = $packages | Where-Object { $_.Name -eq 'MSTeams' } | Select-Object -First 1
            SlimCore = $packages | Where-Object { $_.Name -like 'Microsoft.Teams.SlimCore*' } | Select-Object -First 1
        }
    }

    return $script:AppxCache
}

function Get-TlcClientUpdateHistory {
    <#
    .SYNOPSIS
        When the Teams client last changed version, and what it changed from.
    .DESCRIPTION
        "Did this start after an update?" is the first question in any regression, and the
        bundle could not answer it. Get-AppxPackage has no usable InstalledDate - the
        property exists but is empty on both Windows PowerShell 5.1 and PowerShell 7 for
        this package, measured - and the AppXDeploymentServer channel only records trust
        label validation on launch, not installs.

        The Launcher log has the answer. Every start writes both the running build and the
        build the previous session ran:

            AppVersion: Current desktopAppVersion: 26225.1803.5037.3180
            AppVersion: Previous session desktopAppVersion: 26213.1006.5014.9784

        A line where those differ is an update, timestamped by the log that recorded it.
        On the machine this was written for that recovered four transitions across August
        from logs alone.

        The install folder's CreationTime is reported alongside as StagedAtLocal. The two
        are different facts and both matter: the package was staged on the 20th and first
        run on the 21st, so "installed" and "the user got it" are a day apart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogRoot,
        [string] $Pattern = 'Launcher_*.log'
    )

    $result = [ordered]@{
        Transitions    = @()
        CurrentVersion = $null
        LastUpdateLocal = $null
        PreviousVersion = $null
        StagedAtLocal  = $null
        Scanned        = 0
    }

    # Resolve-TlcPath lives in Tlc.Config and expands the %VAR% placeholders the config
    # uses. Falling back to the raw path rather than requiring it: this function is also
    # called from the dashboard's background runspace, which imports a deliberately narrow
    # set of modules, and a caller that has already resolved its path should not need the
    # whole config module loaded to use it. Same failure shape as finding 73.
    $resolved = $LogRoot
    $resolver = Get-Command -Name 'Resolve-TlcPath' -ErrorAction SilentlyContinue
    if ($resolver) { $resolved = & $resolver -Path $LogRoot }

    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) { return $result }

    $files = @(Get-ChildItem -LiteralPath $resolved -File -Filter $Pattern -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime)
    $result.Scanned = $files.Count
    if ($files.Count -eq 0) { return $result }

    $transitions = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        try {
            # Opened through Open-TlcSharedRead, not File::ReadLines. Teams holds the
            # current launcher log open and refuses the default share mode, so a plain
            # read throws on exactly the file that describes the running session - the
            # one worth having. That is finding 9, met again in a new place.
            #
            # Capped at 40 lines: the version pair is written at startup - measured at
            # line 5 of an 18-line file - so reading further only costs time.
            $current = $null
            $previous = $null
            $stream = Open-TlcSharedRead -Path $file.FullName
            try {
                $reader = [System.IO.StreamReader]::new($stream)
                try {
                    for ($i = 0; $i -lt 40; $i++) {
                        $line = $reader.ReadLine()
                        if ($null -eq $line) { break }
                        if (-not $current -and $line -match 'Current desktopAppVersion:\s*(\S+)') { $current = $Matches[1] }
                        elseif (-not $previous -and $line -match 'Previous session desktopAppVersion:\s*(\S+)') { $previous = $Matches[1] }
                        if ($current -and $previous) { break }
                    }
                } finally { $reader.Dispose() }
            } finally { $stream.Dispose() }

            if (-not $current) { continue }
            $result.CurrentVersion = $current

            if ($previous -and $previous -ne $current) {
                # When the session STARTED, which is when the new build first ran. The last
                # write moves on for as long as that session logs, so a client updated three
                # days ago and running since read as updated minutes ago (review 2026-09-30).
                $startedAt = Get-TlcLogFileStart -File $file
                $transitions.Add([ordered]@{
                    WhenLocal = $(if ($startedAt) { $startedAt.ToString('o') } else { $file.LastWriteTime.ToString('o') })
                    From      = $previous
                    To        = $current
                })
            }
        } catch {
            Write-Verbose "Could not read $($file.Name): $($_.Exception.Message)"
        }
    }

    $result.Transitions = @($transitions)
    if ($transitions.Count -gt 0) {
        $latest = $transitions[$transitions.Count - 1]
        $result.LastUpdateLocal = $latest.WhenLocal
        $result.PreviousVersion = $latest.From
    }

    # Where the running build was staged. Separate from the transition above, and present
    # even when no launcher log recorded a change - a machine that has only ever run one
    # build still has an install date.
    try {
        $package = (Get-TlcAppxPackage).Teams
        if ($package -and $package.InstallLocation) {
            $folder = Get-Item -LiteralPath ([string]$package.InstallLocation) -ErrorAction Stop
            $result.StagedAtLocal = $folder.CreationTime.ToString('o')
        }
    } catch {
        Write-Verbose "Could not read the install location: $($_.Exception.Message)"
    }

    return $result
}

function Get-TlcCacheFootprint {
    <#
    .SYNOPSIS
        Size and file count of each folder in the Teams cache tree.
    .DESCRIPTION
        The toolbox copies individual files out of this tree but never recorded how big
        it is, and the size is often the answer. On the machine this was written for,
        EBWebView - the WebView2 profile store - holds 4.2 GB across 16,333 files. That
        is a first-order explanation for a slow start and for disk pressure, and it costs
        one directory walk to find.

        Uses DirectoryInfo.EnumerateFiles because it carries Length with the enumeration
        rather than re-stating each path. Measured on that same tree: 476 ms, against
        3,318 ms for Get-ChildItem -Recurse and 13,727 ms for
        [System.IO.Directory]::EnumerateFiles with a FileInfo per result. The naive .NET
        form is the slowest of the three, so "use .NET, it is faster" is not the rule
        here - carrying the metadata is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $resolved = Resolve-TlcPath -Path $Path
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
        return [ordered]@{ Path = $resolved; Exists = $false; Folders = @(); TotalMB = 0; TotalFiles = 0 }
    }

    $folders = [System.Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    $totalFiles = 0

    try {
        $root = New-Object System.IO.DirectoryInfo $resolved
        foreach ($sub in $root.GetDirectories()) {
            $bytes = 0L
            $count = 0
            try {
                foreach ($file in $sub.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) {
                    $bytes += $file.Length
                    $count++
                }
            } catch {
                # A folder that cannot be walked - a permission or a reparse point - must
                # not cost the whole measurement.
                Write-Verbose "Could not size $($sub.Name): $($_.Exception.Message)"
            }

            $folders.Add([ordered]@{
                Name      = $sub.Name
                FileCount = $count
                SizeBytes = $bytes
                SizeMB    = [math]::Round($bytes / 1MB, 1)
            })
            $totalBytes += $bytes
            $totalFiles += $count
        }
    } catch {
        Write-Verbose "Could not enumerate $resolved : $($_.Exception.Message)"
    }

    return [ordered]@{
        Path       = $resolved
        Exists     = $true
        # Sorted by a scriptblock on the raw byte count, not by property name and not on
        # the rounded megabytes. Sort-Object cannot resolve a bare property name against a
        # hashtable - it sorts by nothing and returns insertion order, which briefly had
        # the summary reporting a 2.6 MB folder as the largest on a 4.2 GB tree. Sorting
        # the rounded value is the subtler version of the same fault: anything under
        # 50 KB rounds to 0.0 and ties arbitrarily.
        Folders    = @($folders | Sort-Object -Property { $_.SizeBytes } -Descending)
        TotalMB    = [math]::Round($totalBytes / 1MB, 1)
        TotalFiles = $totalFiles
    }
}

function Get-TlcMachineFact {
    <#
    .SYNOPSIS
        Endpoint hardware and resource state.
    .DESCRIPTION
        Microsoft treats endpoint hardware as part of call quality - CQD carries CPU model
        and core count as dimensions - and graphics driver age is a documented factor in
        video, background effects and screen sharing. None of it was in the bundle.

        Every value is optional. A machine that will not answer one WMI query still has to
        produce an inventory, so each is guarded separately rather than the block as a
        whole.
    #>
    [CmdletBinding()]
    param()

    $fact = [ordered]@{}

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $fact['Manufacturer'] = $cs.Manufacturer
        $fact['Model'] = $cs.Model
        $fact['TotalMemoryGB'] = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    } catch { Write-Verbose "Win32_ComputerSystem unavailable: $($_.Exception.Message)" }

    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $fact['CpuName'] = $cpu.Name
        $fact['CpuCores'] = $cpu.NumberOfCores
        $fact['CpuLogicalProcessors'] = $cpu.NumberOfLogicalProcessors
    } catch { Write-Verbose "Win32_Processor unavailable: $($_.Exception.Message)" }

    # Driver date matters more than the model. A 2021 driver on a 2026 machine is a
    # standing explanation for video and background-effect faults.
    $fact['Gpus'] = @(
        try {
            Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object {
                [ordered]@{
                    Name          = $_.Name
                    DriverVersion = $_.DriverVersion
                    DriverDate    = if ($_.DriverDate) { $_.DriverDate.ToUniversalTime().ToString('o') } else { $null }
                }
            }
        } catch { Write-Verbose "Win32_VideoController unavailable: $($_.Exception.Message)" }
    )

    try {
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        $fact['SystemDrive'] = $env:SystemDrive
        $fact['SystemDriveFreeGB'] = [math]::Round($drive.FreeSpace / 1GB, 1)
        $fact['SystemDriveSizeGB'] = [math]::Round($drive.Size / 1GB, 1)
    } catch { Write-Verbose "Win32_LogicalDisk unavailable: $($_.Exception.Message)" }

    # Whether Teams was even running answers a question the bundle could not: a window
    # with no client process behind it explains an empty collection on its own.
    #
    # Summed across processes, not taken from the first one. Teams is multi-process -
    # measured two ms-teams processes at 47 MB and 23 MB - so Select-Object -First 1
    # returned whichever the pipeline happened to yield and reported 22.5 MB for a client
    # actually using 70 MB. The start time is the earliest, which is when the client
    # launched rather than when a child process spawned.
    $processes = @(Get-Process -Name 'ms-teams' -ErrorAction SilentlyContinue)
    $fact['TeamsProcessRunning'] = ($processes.Count -gt 0)
    if ($processes.Count -gt 0) {
        $fact['TeamsProcessCount'] = $processes.Count
        $fact['TeamsWorkingSetMB'] = [math]::Round((($processes | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 1)
        $fact['TeamsHandleCount'] = ($processes | Measure-Object -Property HandleCount -Sum).Sum
        $starts = @($processes | ForEach-Object { try { $_.StartTime } catch { $null } } | Where-Object { $_ })
        if ($starts.Count -gt 0) {
            # @() around the sort as well as the Count test above. The guard makes this safe
            # today, but the rule enforced in the tests is absolute - a filtering pipeline is
            # always wrapped before anything is read off it - because a rule with exceptions
            # is one someone has to re-derive at the point of changing it.
            $fact['TeamsStartTimeUtc'] = (@($starts | Sort-Object)[0]).ToUniversalTime().ToString('o')
        }
    }

    return $fact
}

function Get-TlcAudioDeviceFact {
    <#
    .SYNOPSIS
        The audio endpoints a call could have used, split into playback and recording.
    .DESCRIPTION
        A blind spot until 2026-09-17, and not even recorded as a gap the way Wi-Fi was: a
        bundle about "bad audio" could not say what the machine was playing through or
        listening on. Headsets and their drivers are among the commonest real causes, and a
        disabled or errored endpoint is the sort of thing that looks like a network fault from
        every other angle.

        THE OBVIOUS API IS THE WRONG ONE. Win32_SoundDevice returns the audio CONTROLLERS -
        measured here, exactly two: "Intel(R) Display Audio" and "Realtek High Definition
        Audio(SST)". Neither is a device a call can use. Get-PnpDevice -Class AudioEndpoint
        returns the endpoints themselves, which is what the question is about.

        RENDER VERSUS CAPTURE comes from the endpoint id rather than from the name. Windows
        formats an MMDevice instance id as {0.0.0.00000000} for render and {0.0.1.00000000}
        for capture, so the split is structured and survives a localised machine - where
        matching the word "Microphone" would not. Verified against this machine: the two
        monitor outputs and the speakers carry 0.0.0, the microphone array carries 0.0.1.

        NAMES ARE KEPT, not masked, and the line is the same one Get-TlcWifiFact draws.
        "Speakers (Realtek High Definition Audio(SST))" is a hardware model string and is
        precisely the diagnostic - it names the driver stack that carried the audio - so it is
        recorded like the adapter description beside it. An SSID is masked because it names
        somebody's organisation; a sound card does not. The one case that blurs this is a
        Bluetooth headset, whose endpoint can carry a user-chosen label, and that is called out
        in output-reference.md rather than solved by mangling every model name.

        NOT COLLECTED: which endpoint was the DEFAULT. The documented way to ask is
        IMMDeviceEnumerator::GetDefaultAudioEndpoint, which needs a COM interop type built at
        run time - and Add-Type is refused outright under ConstrainedLanguage, which is where
        this toolbox runs on a WDAC or AppLocker managed endpoint. A capability that throws on
        exactly the managed machines this is written for is worse than a named gap, so the gap
        is named.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $fact = [ordered]@{
        Available       = $false
        RenderCount     = 0
        CaptureCount    = 0
        HealthyCount    = 0
        UnhealthyCount  = 0
        RenderDevices   = @()
        CaptureDevices  = @()
        Unhealthy       = @()
        Detail          = ''
        CollectedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    $endpoints = @()
    try {
        $endpoints = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop)
    } catch {
        # Not "no audio devices". The difference matters for the same reason it does in the
        # Wi-Fi and capture sweeps: an unexamined machine must not read as a clean one.
        $fact.Detail = "The audio endpoint list could not be read: $($_.Exception.Message)"
        return $fact
    }

    $fact.Available = $true

    if ($endpoints.Count -eq 0) {
        $fact.Detail = 'No audio endpoints are present. A call on this machine had nothing to play through or record from.'
        return $fact
    }

    $describe = {
        param($Device)
        $result = [ordered]@{
            Name   = [string]$Device.FriendlyName
            Status = [string]$Device.Status
            DeviceType = 'Unknown'
            FormFactor = 'UnknownFormFactor'
            FormFactorCode = $null
            TypeSource = 'Unavailable'
            TypeDetail = ''
        }
        # Read Windows' cached PKEY_AudioEndpoint_FormFactor, not the friendly name.
        # The registry layout is best effort; absent or denied metadata stays unknown.
        if ([string]$Device.InstanceId -match '\{0\.0\.([01])\.[^}]+\}\.(\{[0-9a-fA-F-]{36}\})$') {
            $flow = if ($Matches[1] -eq '0') { 'Render' } else { 'Capture' }
            $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$flow\$($Matches[2])\Properties"
            $key = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},0'
            try {
                $properties = Get-ItemProperty -LiteralPath $path -Name $key -ErrorAction Stop
                $value = $properties.PSObject.Properties[$key]
                $code = 0
                if (-not $value -or -not [int]::TryParse([string]$value.Value, [ref]$code) -or $code -lt 0 -or $code -gt 10) {
                    throw 'Windows did not provide a recognized audio endpoint form factor.'
                }
                $forms = @('RemoteNetworkDevice', 'Speakers', 'LineLevel', 'Headphones', 'Microphone',
                    'Headset', 'Handset', 'UnknownDigitalPassthrough', 'SPDIF', 'DigitalAudioDisplayDevice', 'UnknownFormFactor')
                $types = @('Remote audio', 'Speakers', 'Line-level audio', 'Headphones', 'Microphone',
                    'Headset', 'Handset', 'Digital passthrough', 'Digital audio (S/PDIF)', 'Display audio (HDMI / DisplayPort)', 'Unknown')
                $result.FormFactorCode = $code
                $result.FormFactor = $forms[$code]
                $result.DeviceType = $types[$code]
                $result.TypeSource = 'Windows MMDevices / PKEY_AudioEndpoint_FormFactor'
            } catch {
                $result.TypeDetail = "Audio device type could not be read: $($_.Exception.Message)"
                Write-Verbose $result.TypeDetail
            }
        } else {
            $result.TypeDetail = 'Audio device type unavailable: the endpoint id has no recognized MMDevice property path.'
        }
        $result
    }

    $render = @($endpoints | Where-Object { [string]$_.InstanceId -match '\{0\.0\.0\.' })
    $capture = @($endpoints | Where-Object { [string]$_.InstanceId -match '\{0\.0\.1\.' })

    $described = @{}
    foreach ($device in $endpoints) { $described[[string]$device.InstanceId] = & $describe $device }
    $fact.RenderDevices = @($render | ForEach-Object { $described[[string]$_.InstanceId] })
    $fact.CaptureDevices = @($capture | ForEach-Object { $described[[string]$_.InstanceId] })
    $fact.RenderCount = $render.Count
    $fact.CaptureCount = $capture.Count

    $healthy = @($endpoints | Where-Object { [string]$_.Status -eq 'OK' })
    $unhealthy = @($endpoints | Where-Object { [string]$_.Status -ne 'OK' })
    $fact.HealthyCount = $healthy.Count
    $fact.UnhealthyCount = $unhealthy.Count
    $fact.Unhealthy = @($unhealthy | ForEach-Object { $described[[string]$_.InstanceId] })

    # No recording device is a complete explanation for "nobody could hear me", and it is worth
    # saying in those words rather than leaving a reader to notice a zero.
    $notes = [System.Collections.Generic.List[string]]::new()
    $notes.Add("$($fact.RenderCount) playback and $($fact.CaptureCount) recording endpoint(s).")
    $unknownTypes = @($described.Values | Where-Object { $_.TypeSource -eq 'Unavailable' }).Count
    if ($unknownTypes -gt 0) { $notes.Add("Device type metadata was unavailable for $unknownTypes endpoint(s); see TypeDetail.") }
    if ($fact.CaptureCount -eq 0) {
        $notes.Add('There is no recording endpoint at all, which on its own explains a call where the far side heard nothing.')
    }
    if ($fact.UnhealthyCount -gt 0) {
        $notes.Add("$($fact.UnhealthyCount) endpoint(s) are not reporting OK.")
    }
    $fact.Detail = ($notes -join ' ')

    return $fact
}

function Get-TlcClockFact {
    <#
    .SYNOPSIS
        How far this machine's clock is from Microsoft's, and whether Windows Time is running.
    .DESCRIPTION
        A wrong clock is a classic cause of sign-in failure that looks like anything but the
        clock. Kerberos refuses a skew beyond its tolerance - 5 minutes by default, per
        learn.microsoft.com "Maximum tolerance for computer clock synchronization" - and the
        toolbox recorded neither the offset nor whether anything keeps the clock right. Found
        while simulating the fault on the lab endpoint, whose Windows Time service was stopped. Finding 308.

        The reference is the Date header of the Entra sign-in endpoint: the server a sign-in
        failure would be about, reached the way Teams reaches it. One HEAD request, resolution
        one second, latency halved out. Unreachable is reported as unmeasured, never as zero.
    #>
    [CmdletBinding()]
    param(
        [string] $ReferenceUrl = 'https://login.microsoftonline.com/',
        [int] $TimeoutMs = 5000
    )

    $fact = [ordered]@{
        Measured        = $false
        OffsetSeconds   = $null
        Reference       = $ReferenceUrl
        TimeServiceStatus = ''
        Detail          = ''
        CollectedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    try { $fact.TimeServiceStatus = [string](Get-Service -Name w32time -ErrorAction Stop).Status } catch { $fact.TimeServiceStatus = 'not found' }

    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($ReferenceUrl)
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutMs
        $request.AllowAutoRedirect = $false
        $sent = [datetime]::UtcNow
        try {
            $response = $request.GetResponse()
        } catch [System.Net.WebException] {
            # A 4xx still carries a Date header, which is all this needs.
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $response = if ($responseProperty) { $responseProperty.Value } else { $null }
            if (-not $response) { throw }
        }
        $received = [datetime]::UtcNow
        $dateHeader = $response.Headers['Date']
        if (-not $dateHeader) { $fact.Detail = 'The reference answered without a Date header.'; return $fact }
        $server = [datetime]::Parse($dateHeader, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $localMid = $sent.AddTicks(($received - $sent).Ticks / 2)
        $fact.OffsetSeconds = [math]::Round(($localMid - $server).TotalSeconds)
        $fact.Measured = $true
    } catch {
        $fact.Detail = "The reference time could not be read: $($_.Exception.Message)"
    } finally {
        if ($response) { $response.Close() }
    }
    return $fact
}

function Get-TlcPowerFact {
    <#
    .SYNOPSIS
        Whether the machine was throttling itself, and whether it was on mains.
    .DESCRIPTION
        The last of the three endpoint gaps found in the 2026-09-16 coverage audit. CPU and GPU
        were already collected; nothing recorded what makes them slow down. A laptop on Power
        saver, or discharging, throttles the CPU - and video encoding is the first thing a Teams
        call notices. It presents as poor quality on a network that measures perfectly, which is
        exactly the case a network-shaped bundle cannot close.

        THE POWER PLAN COMES FROM powercfg, NOT WMI, and that is measured rather than stylistic.
        Win32_PowerPlan in root\cimv2\power failed on this machine with:

            "Only administrators have permission to add, remove, or configure server software
             during a Terminal services remote session."

        That namespace is unavailable to an ordinary user in a session Windows treats as remote -
        which is a large share of the machines this toolbox runs on, since engineers reach
        customer endpoints exactly that way. `powercfg /getactivescheme` answered on the same
        machine, in the same session, with exit 0.

        THE GUID IS THE ANSWER, NOT THE NAME IN BRACKETS. powercfg prints
        "Power Scheme GUID: 381b4222-... (Balanced)" and the parenthesised part is localised;
        the GUID is not. Matching the word "Balanced" would work here and fail on a German
        machine - the same trap as the netsh phrasing in findings 187 and 221, and the audio
        endpoint split in 239. The well-known scheme GUIDs are published by Microsoft, so the
        name is derived from the GUID and the raw line is kept as evidence either way.

        NOT COLLECTED: temperature. MSAcpi_ThermalZoneTemperature returns Access denied
        unelevated - measured - and the toolbox deliberately does not ask for elevation during a
        collection. Reported as a named gap rather than as a silent absence, the same way the
        default audio endpoint is.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $fact = [ordered]@{
        PowerSchemeGuid = ''
        PowerScheme     = ''
        PowerSchemeRaw  = ''
        Throttling      = $null
        BatteryPresent  = $false
        BatteryCount    = 0
        OnBattery       = $null
        ChargePercent   = $null
        BatteryDetail   = ''
        ThermalDetail   = 'Not collected: MSAcpi_ThermalZoneTemperature needs elevation, and a collection does not ask for it.'
        Detail          = ''
        CollectedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }

    # Published scheme GUIDs. Language-independent, and the reason the bracketed name is not
    # parsed. An unrecognised GUID is reported as itself rather than guessed at.
    $schemes = @{
        '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
        'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
        'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate Performance'
    }

    if (Get-Command powercfg.exe -ErrorAction SilentlyContinue) {
        try {
            $run = Invoke-TlcNativeCommand -FilePath 'powercfg.exe' -ArgumentList @('/getactivescheme')
            if ($run.Available -and $run.ExitCode -eq 0) {
                $text = (@($run.Lines) -join ' ')
                $fact.PowerSchemeRaw = $text.Trim()
                $match = [regex]::Match($text, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
                if ($match.Success) {
                    $guid = $match.Groups[1].Value.ToLowerInvariant()
                    $fact.PowerSchemeGuid = $guid
                    $fact.PowerScheme = if ($schemes.ContainsKey($guid)) { $schemes[$guid] } else { 'Custom or unrecognised scheme' }
                    # Power saver is the one that costs a call measurable quality.
                    $fact.Throttling = ($guid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a')
                }
            }
        } catch {
            Write-Verbose "powercfg could not be read: $($_.Exception.Message)"
        }
    }

    # Win32_Battery, which DID answer where the power namespace did not. Two rows on this
    # machine, because a Surface Book has a battery in each half - so the count is reported and
    # the charge is taken as the lowest, not the first.
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        $fact.BatteryCount = $batteries.Count
        $fact.BatteryPresent = ($batteries.Count -gt 0)

        if ($batteries.Count -gt 0) {
            $charges = @($batteries | ForEach-Object { $_.EstimatedChargeRemaining } | Where-Object { $null -ne $_ })
            if ($charges.Count -gt 0) {
                $fact.ChargePercent = (@($charges | Sort-Object)[0])
            }

            # BatteryStatus 1 is the documented "discharging" value; 2 means the system has
            # access to AC. Anything else is a charging or level state, none of which means
            # running on battery. Unknown codes leave OnBattery null rather than guessing.
            $statuses = @($batteries | ForEach-Object { [int]$_.BatteryStatus })
            if (@($statuses | Where-Object { $_ -eq 1 }).Count -gt 0) {
                $fact.OnBattery = $true
                $fact.BatteryDetail = 'At least one battery is discharging, so the machine was not on mains.'
            } elseif (@($statuses | Where-Object { $_ -eq 2 -or ($_ -ge 3 -and $_ -le 11) }).Count -gt 0) {
                $fact.OnBattery = $false
                $fact.BatteryDetail = 'The system has access to AC.'
            } else {
                $fact.BatteryDetail = "Battery status code(s) $($statuses -join ', ') are not ones this recognises, so mains state is not known."
            }
        } else {
            $fact.BatteryDetail = 'No battery, so this is a desktop or a virtual machine and power state is not a factor.'
        }
    } catch {
        $fact.BatteryDetail = "The battery list could not be read: $($_.Exception.Message)"
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    if ($fact.PowerScheme) { $notes.Add("Power scheme: $($fact.PowerScheme).") }
    else { $notes.Add('The active power scheme could not be read.') }
    if ($fact.Throttling -eq $true) {
        $notes.Add('Power saver throttles the CPU, which degrades video encoding before it affects anything else.')
    }
    if ($fact.OnBattery -eq $true) {
        $notes.Add("Running on battery at $($fact.ChargePercent)%.")
    }
    $fact.Detail = ($notes -join ' ')

    return $fact
}

function Get-TlcMeetingAddinHealth {
    <#
    .SYNOPSIS
        Classifies the Teams Meeting Add-in state into one verdict.
    .DESCRIPTION
        "The Teams button has gone from Outlook" has three ordinary causes that look
        identical from the outside, and they are mutually exclusive in a specific order:
        a disabled add-in stays disabled whatever its LoadBehavior says, and LoadBehavior
        means nothing if nothing is installed.

        Extracted so the collector's blocker and the wizard's advisory read the same
        verdict rather than each deciding for itself. Two renderings of one judgement is
        how a dashboard ends up disagreeing with the bundle it produced.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Addin)

    $disabledTeams = @($Addin.Resiliency | Where-Object { $_.IsTeams -and $_.List -ne 'DoNotDisableAddinList' })
    $loadBehaviours = @($Addin.Registrations | ForEach-Object { $_.LoadBehavior })
    $installedVersions = @($Addin.Installed.Current.Versions)

    if ($disabledTeams.Count -gt 0) {
        return [ordered]@{
            Status      = 'Warning'
            Reason      = 'Disabled'
            Detail      = "Outlook has the Teams Meeting Add-in on $($disabledTeams.Count) resiliency list(s): $(($disabledTeams | ForEach-Object { $_.List }) -join ', '). Outlook disables an add-in that crashed it, and the button stays missing until it is re-enabled."
            Remediation = 'Outlook > File > Options > Add-ins > Disabled Items, re-enable the Teams add-in. Or clear the entry under HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Resiliency\DisabledItems.'
        }
    }

    if ($installedVersions.Count -eq 0) {
        return [ordered]@{
            Status      = 'Warning'
            Reason      = 'NotInstalled'
            Detail      = "No Teams Meeting Add-in found at $($Addin.Installed.Current.Path)."
            Remediation = 'Expected when Outlook is not installed. Otherwise repair the Teams client, which provisions the add-in.'
        }
    }

    # @() around the filter is load-bearing. Where-Object returns nothing when every
    # registration is 3 - the healthy case - and .Count on nothing throws under
    # Set-StrictMode -Version Latest.
    #
    # This shipped for months without firing because the two conditions mask each other:
    # a machine with no registrations short-circuits on the left, and a machine whose
    # add-in is on a resiliency list returns from the branch above. It needed a properly
    # registered, healthy add-in to crash, which is the one state the development machine
    # did not have.
    $misconfigured = @($loadBehaviours | Where-Object { $_ -ne 3 })
    if ($loadBehaviours.Count -gt 0 -and $misconfigured.Count -eq $loadBehaviours.Count) {
        return [ordered]@{
            Status      = 'Warning'
            Reason      = 'LoadBehavior'
            Detail      = "The add-in is installed but its LoadBehavior is $($loadBehaviours -join ', ') rather than 3, so Outlook will not load it at startup."
            Remediation = 'Set LoadBehavior to 3 under HKCU:\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect.'
        }
    }

    $detail = "Teams Meeting Add-in $($installedVersions -join ', ') installed, LoadBehavior $($loadBehaviours -join ', ')."
    if ($installedVersions.Count -gt 1) {
        $detail += ' More than one version is present, which is itself a known cause of add-in faults.'
    }

    return [ordered]@{
        Status      = 'Success'
        Reason      = 'Healthy'
        Detail      = $detail
        Remediation = ''
    }
}

function Get-TlcMeetingAddinFact {
    <#
    .SYNOPSIS
        Teams Meeting Add-in state: versions, load behaviour, and whether Outlook disabled it.
    .DESCRIPTION
        "The Teams button has gone from Outlook" had no coverage at all, and it is usually
        one of three things: the add-in is not installed, its LoadBehavior is not 3, or
        Outlook's crash protection has disabled it.

        The install path is %LOCALAPPDATA%\Microsoft\TeamsMeetingAdd-in - hyphenated. Most
        write-ups give TeamsMeetingAddin, which does not exist on a current machine; the
        unhyphenated form is the classic-Teams location and is checked separately, because
        finding both is itself a migration symptom.

        Outlook's Resiliency keys hold opaque hashes as value names - 2CE47651 and the
        like - so a count of disabled items says nothing about which add-in is affected.
        The value data is a binary blob with the DLL path and ProgID embedded as UTF-16,
        so it is decoded here. On the machine this was written for, that turned "2 disabled
        items" into "both of them are the Teams Meeting Add-in", which is the whole answer.
    #>
    [CmdletBinding()]
    param()

    $installRoots = [ordered]@{
        Current = Join-Path $env:LOCALAPPDATA 'Microsoft\TeamsMeetingAdd-in'
        Legacy  = Join-Path $env:LOCALAPPDATA 'Microsoft\TeamsMeetingAddin'
    }

    $installed = [ordered]@{}
    foreach ($name in $installRoots.Keys) {
        $path = $installRoots[$name]
        $versions = @()
        if (Test-Path -LiteralPath $path) {
            $versions = @(Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue |
                            ForEach-Object { $_.Name } | Sort-Object)
        }
        $installed[$name] = [ordered]@{ Path = $path; Present = (Test-Path -LiteralPath $path); Versions = $versions }
    }

    # LoadBehavior 3 means "load at startup". Anything else and Outlook will not show the
    # button, whatever else is correct.
    $registrations = @(
        foreach ($hive in 'HKCU:', 'HKLM:') {
            $key = "$hive\SOFTWARE\Microsoft\Office\Outlook\Addins\TeamsAddin.FastConnect"
            $properties = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($properties) {
                [ordered]@{
                    Hive         = $hive.TrimEnd(':')
                    LoadBehavior = $properties.LoadBehavior
                    FriendlyName = $properties.FriendlyName
                }
            }
        }
    )

    $resiliency = @(
        foreach ($listName in 'DisabledItems', 'CrashingAddinList', 'DoNotDisableAddinList') {
            $key = "HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Resiliency\$listName"
            $item = Get-Item -Path $key -ErrorAction SilentlyContinue
            if (-not $item) { continue }

            foreach ($valueName in $item.GetValueNames()) {
                $decoded = ''
                try {
                    $bytes = $item.GetValue($valueName)
                    if ($bytes -is [byte[]]) {
                        # The blob is a struct with UTF-16 strings inside. Splitting on
                        # nulls and keeping runs of letters recovers the DLL path and the
                        # ProgID without needing to parse the structure.
                        $text = [System.Text.Encoding]::Unicode.GetString($bytes)
                        $decoded = (($text -split "`0" | Where-Object { $_ -match '[a-zA-Z]{4,}' }) -join ' | ')
                    }
                } catch {
                    Write-Verbose "Could not decode $listName\$valueName : $($_.Exception.Message)"
                }

                [ordered]@{
                    List      = $listName
                    ValueName = $valueName
                    Decoded   = $decoded
                    IsTeams   = ($decoded -match 'teams')
                }
            }
        }
    )

    $office = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue

    return [ordered]@{
        Installed        = $installed
        Registrations    = $registrations
        Resiliency       = @($resiliency)
        OfficeProducts   = if ($office) { $office.ProductReleaseIds } else { $null }
        OfficeVersion    = if ($office) { $office.VersionToReport } else { $null }
        CollectedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-TlcDeviceJoinState {
    <#
    .SYNOPSIS
        How the device is joined, without the identifiers that say to whom.
    .DESCRIPTION
        The toolbox recorded DomainJoined from Win32_ComputerSystem, which reports False
        on an Entra-joined machine and reads as "unmanaged" for a device that is very much
        managed. dsregcmd answers properly.

        Split deliberately. The join state - AzureAdJoined, DomainJoined, WorkplaceJoined -
        is the whole diagnostic and carries no customer data at all. The identifiers in the
        same output do: tenant id, tenant name, device id, the signed-in UPN. Phase 0
        finding 11 established that Teams client logs contain no tenant GUIDs, and the
        privacy gate was built on account object ids for exactly that reason, so collecting
        these raw would put tenant identity into a customer-facing bundle for the first
        time.

        So the flags are always collected and the identifiers are masked through
        Protect-TlcIdentifier, which yields a stable, correlatable value without
        republishing the original. A masked tenant id still answers "is this the same
        tenant as the last bundle"; it does not answer "which tenant".

        -IncludeRawIdentifiers exists for the case where support genuinely needs the tenant
        GUID, and is off unless a caller asks. Raw identity should be a decision someone
        made, not a default they inherited.
    #>
    [CmdletBinding()]
    param([switch] $IncludeRawIdentifiers)

    $state = [ordered]@{
        Source           = 'dsregcmd'
        Available        = $false
        AzureAdJoined    = $null
        DomainJoined     = $null
        WorkplaceJoined  = $null
        EnterpriseJoined = $null
        CollectedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }

    $lines = @()
    # Through the shared helper: a redirected native stderr line is a terminating error on
    # 5.1 under Stop, and dsregcmd only writes to stderr when the join state is broken -
    # so the old form lost the join state on exactly the devices that needed it reported.
    $dsreg = Invoke-TlcNativeCommand -FilePath 'dsregcmd.exe' -ArgumentList @('/status')
    if (-not $dsreg.Available) {
        Write-Verbose "dsregcmd is unavailable: $($dsreg.Detail)"
        return $state
    }
    $lines = $dsreg.Lines
    $state.Available = $true

    # "Key : Value" with variable padding. Parsed by splitting on the first colon rather
    # than by fixed columns, because the padding differs between Windows builds.
    $values = @{}
    foreach ($line in $lines) {
        $text = [string]$line
        $index = $text.IndexOf(':')
        if ($index -lt 1) { continue }
        $key = $text.Substring(0, $index).Trim()
        if ($key) { $values[$key] = $text.Substring($index + 1).Trim() }
    }

    foreach ($flag in 'AzureAdJoined', 'DomainJoined', 'WorkplaceJoined', 'EnterpriseJoined') {
        if ($values.ContainsKey($flag)) { $state[$flag] = ($values[$flag] -eq 'YES') }
    }

    # Masked by default. The mask is stable, so two bundles from the same tenant still
    # correlate, and it is not reversible into the original.
    #
    # TenantName is deliberately not collected at all. Protect-TlcIdentifier keeps the
    # first eight characters, which for a short name like "Microsoft" leaves
    # "Microsof...soft" - a mask in name only. The masked tenant id already provides the
    # correlation, and the customer's name is recorded properly in Consent.json, so the
    # field adds nothing and leaks what it claims to hide. Weakening the shared masking
    # rule to cover it would have made every other identifier in the bundle blunter.
    foreach ($pair in @(
        @{ Key = 'TenantId'; Name = 'TenantId' }
        @{ Key = 'DeviceId'; Name = 'DeviceId' }
        @{ Key = 'Executing Account Name'; Name = 'ExecutingAccount' }
    )) {
        if (-not $values.ContainsKey($pair.Key)) { continue }
        $raw = $values[$pair.Key]
        if (-not $raw) { continue }

        # Fails closed. If the masking helper cannot be reached the identifier is dropped
        # rather than emitted raw, and rather than thrown - a missing privacy utility must
        # not be able to leak an identifier, and must not cost the whole client inventory
        # either. Tlc.Privacy is loaded alongside this module by the manifest, so in a real
        # run it is simply there.
        $masked = $null
        try {
            $masked = Protect-TlcIdentifier -Value $raw
        } catch {
            Write-Verbose "Protect-TlcIdentifier is unavailable, so $($pair.Name) is omitted: $($_.Exception.Message)"
            continue
        }

        $state["$($pair.Name)Masked"] = $masked
        if ($IncludeRawIdentifiers) { $state[$pair.Name] = $raw }
    }

    $state['RawIdentifiersIncluded'] = [bool]$IncludeRawIdentifiers
    return $state
}

function Get-TlcLaunchEnvironmentFact {
    <#
    .SYNOPSIS
        Environmental conditions Microsoft documents as stopping new Teams from installing or
        launching: reparse points over the folders the client reads through, and the package
        policy values that block sideloading.
    .DESCRIPTION
        Microsoft ships TeamsLaunchCheck.ps1 for "new Teams will not start", and these are the
        parts of it nothing else in the toolbox looked at. Both failure modes are invisible in
        the client's own logs: the client does not report that its cache folder is a junction
        pointing somewhere it cannot write, it just exits.

        A reparse point is reported with its target, because the finding is not "this is a
        junction" - plenty of managed machines redirect AppData deliberately - it is "this is a
        junction and here is where it actually goes". Judging that is the engineer's job.

        Registry values that do not exist are reported as not set rather than as findings. These
        keys only appear once something has written them, so absence is the normal, healthy
        state and flagging it would fill the bundle with noise on every machine.

        Source: learn.microsoft.com/en-us/microsoftteams/troubleshoot/teams-administration/
        new-teams-not-starting
    #>
    [CmdletBinding()]
    param(
        [string] $DataPath
    )

    $result = [ordered]@{
        Paths          = @()
        ReparsePoints  = @()
        RegistryValues = @()
        Detail         = ''
    }

    if (-not $DataPath) {
        $DataPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'LaunchEnvironment.psd1'
    }
    if (-not (Test-Path -LiteralPath $DataPath)) {
        $result.Detail = "The launch-environment list is missing at $DataPath, so these conditions were not checked."
        return (New-Object psobject -Property $result)
    }

    try {
        $table = Import-TlcCollectorData -Path $DataPath
    } catch {
        $result.Detail = "The launch-environment list could not be read: $($_.Exception.Message)"
        return (New-Object psobject -Property $result)
    }

    $shellFolderKey = if ($table.Contains('ShellFolderKey') -and $table.ShellFolderKey) {
        [string]$table.ShellFolderKey
    } else {
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    }
    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($folder in @($table.ShellFolders)) {
        $path = ''
        try {
            $entry = Get-ItemProperty -LiteralPath $shellFolderKey -Name $folder.Value -ErrorAction Stop
            # User Shell Folders stores unexpanded values such as %USERPROFILE%\..., which
            # Test-Path and Get-Item will not follow. Shell Folders happens to store them
            # expanded, so code written against the wrong key works until it meets the right
            # one.
            $path = [Environment]::ExpandEnvironmentVariables([string]$entry.($folder.Value))
        } catch {
            Write-Verbose "Shell folder $($folder.Value) is not set: $($_.Exception.Message)"
        }
        if ($path) { $targets.Add([pscustomobject]@{ Label = [string]$folder.Label; Path = $path }) }
    }

    foreach ($name in @($table.TempVariables)) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($value) { $targets.Add([pscustomobject]@{ Label = $name; Path = $value }) }
    }

    $paths = [System.Collections.Generic.List[object]]::new()
    $reparse = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $exists = $false
        $isReparse = $false
        $linkType = ''
        $linkTarget = ''
        try {
            $item = Get-Item -LiteralPath $target.Path -Force -ErrorAction Stop
            $exists = $true
            $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isReparse) {
                # LinkType and Target are absent on 5.1 for some reparse kinds, so neither is
                # assumed to be readable. A junction reported without its target is still the
                # finding; the target is what makes it actionable.
                try { $linkType = [string]$item.LinkType } catch { $linkType = '' }
                try { $linkTarget = (@($item.Target) -join '; ') } catch { $linkTarget = '' }
            }
        } catch {
            Write-Verbose "Could not inspect $($target.Path): $($_.Exception.Message)"
        }

        $row = [pscustomobject]@{
            Label      = $target.Label
            Path       = $target.Path
            Exists     = $exists
            IsReparse  = $isReparse
            LinkType   = $linkType
            LinkTarget = $linkTarget
        }
        $paths.Add($row)
        if ($isReparse) { $reparse.Add($row) }
    }
    $result.Paths = $paths.ToArray()
    $result.ReparsePoints = $reparse.ToArray()

    # Whether AllowAllTrustedApps can still be the cause on this OS. Microsoft's own script
    # stops checking it above the build that fixed it and says so; without the same gate this
    # reports a fault on a patched machine that Microsoft's script passes, which is a false
    # positive on most current estates.
    $gateSkipped = @{}
    if ($table.Contains('BuildGate')) {
        $build = 0
        $revision = 0
        try {
            $build = [int][Environment]::OSVersion.Version.Build
            $revision = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR' -ErrorAction Stop).UBR
        } catch {
            Write-Verbose "The OS build could not be read, so build gates are not applied: $($_.Exception.Message)"
        }

        if ($build -gt 0) {
            foreach ($gateName in @($table.BuildGate.Keys)) {
                $gate = $table.BuildGate[$gateName]
                $fixed = $false
                if ($gate.Contains('AboveBuild') -and $build -gt [int]$gate.AboveBuild) {
                    $fixed = $true
                } elseif ($gate.Contains('Builds') -and $gate.Builds.Contains("$build")) {
                    $fixed = ($revision -ge [int]$gate.Builds["$build"])
                }
                if ($fixed) { $gateSkipped[$gateName] = [string]$gate.Note }
            }
        }
    }

    $values = [System.Collections.Generic.List[object]]::new()
    $unhealthy = [System.Collections.Generic.List[string]]::new()
    foreach ($wanted in @($table.RegistryValues)) {
        $present = $false
        $actual = $null
        try {
            $entry = Get-ItemProperty -LiteralPath $wanted.Path -Name $wanted.Name -ErrorAction Stop
            $actual = $entry.($wanted.Name)
            $present = $true
        } catch {
            Write-Verbose "$($wanted.Path)\$($wanted.Name) is not set."
        }

        $gateName = if ($wanted.Contains('Gate')) { [string]$wanted.Gate } else { '' }
        $gatedOut = $gateName -and $gateSkipped.ContainsKey($gateName)

        # Microsoft treats ANY non-zero value as healthy for the sideloading controls, not
        # specifically 1. A value of 2 is as healthy as 1 and must not read as a fault.
        $healthy = if ($wanted.Contains('Healthy')) { $wanted.Healthy } else { $null }
        $isProblem = $false
        if ($present -and -not $gatedOut -and $null -ne $healthy) {
            $isProblem = switch ("$healthy") {
                'NonZero' { [int]$actual -eq 0 }
                'Zero'    { [int]$actual -ne 0 }
                default   { "$actual" -ne "$healthy" }
            }
        }
        if ($isProblem) { $unhealthy.Add("$($wanted.Name)=$actual") }

        $values.Add([pscustomobject]@{
            Path     = [string]$wanted.Path
            Name     = [string]$wanted.Name
            Present  = $present
            Value    = $actual
            Expected = $healthy
            Problem  = $isProblem
            NotApplicable = [bool]$gatedOut
            Meaning  = [string]$wanted.Meaning
        })
    }
    $result.RegistryValues = $values.ToArray()
    $result['BuildGatesApplied'] = @($gateSkipped.Values)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("$($paths.Count) path(s) checked")
    if ($reparse.Count -gt 0) {
        $parts.Add("$($reparse.Count) is a reparse point: $(@($reparse | ForEach-Object { "$($_.Label) -> $(if ($_.LinkTarget) { $_.LinkTarget } else { 'target unreadable' })" }) -join ', ')")
    } else {
        $parts.Add('no reparse points')
    }
    if ($unhealthy.Count -gt 0) {
        $parts.Add("package policy blocking install: $($unhealthy -join ', ')")
    } else {
        $parts.Add('no package policy blocking install')
    }
    $result.Detail = ($parts -join '. ') + '.'

    return (New-Object psobject -Property $result)
}

function Get-TlcInterferingModuleFact {
    <#
    .SYNOPSIS
        Third-party DLLs loaded into the Teams processes that Microsoft documents as known to potentially
        block Teams or make it stop responding.
    .DESCRIPTION
        Microsoft's crash-triage guidance leads with this: confirm that antivirus and DLP are
        not interfering, and it publishes a table of applications and the DLLs they inject.
        The toolbox collected crash evidence - the Application log, WebView2 crash records,
        uae.json - and never once looked at what was actually loaded into the process. This
        closes that.

        PRESENCE IS A FACT, NOT A FAULT, and the wording throughout reflects that. Microsoft's
        own instruction is to "verify the presence of the DLLs, and also verify the ownership
        and integrity of the DLLs" - most of these are security products doing exactly what the
        customer bought them to do. A bundle that reports "CrowdStrike is injecting into Teams"
        as a defect is wrong most of the time and insulting the rest. What it should say is
        that a documented interaction exists and let an engineer weigh it.

        The application name is the point. "ms-teams.exe has cymemdef64.dll loaded" is a line
        someone has to go and search for; "Cylance Desktop Security is hooked into Teams" is a
        line they can act on.

        Ownership and integrity are reported too, because Microsoft asks for them and because
        a DLL on this list whose signature does not verify is a different conversation
        entirely - that is not an endpoint agent, that is something wearing its name.

        Source: learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/
        include-exclude-teams-from-antivirus-dlp
    #>
    [CmdletBinding()]
    param(
        [string] $DataPath
    )

    $result = [ordered]@{
        Inspected        = @()
        ProcessesFound   = 0
        ModulesInspected = 0
        Matches          = @()
        Detail           = ''
    }

    if (-not $DataPath) {
        $DataPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'InterferingModules.psd1'
    }
    if (-not (Test-Path -LiteralPath $DataPath)) {
        $result.Detail = "The interfering-module list is missing at $DataPath, so loaded modules were not checked."
        return (New-Object psobject -Property $result)
    }

    try {
        $table = Import-TlcCollectorData -Path $DataPath
    } catch {
        $result.Detail = "The interfering-module list could not be read: $($_.Exception.Message)"
        return (New-Object psobject -Property $result)
    }

    $processes = @(Get-Process -Name @($table.Processes) -ErrorAction SilentlyContinue)
    $result.ProcessesFound = $processes.Count
    if ($processes.Count -eq 0) {
        $result.Detail = 'None of the Teams processes are running, so their loaded modules could not be inspected. Run this while Teams is running to check for documented interference.'
        return (New-Object psobject -Property $result)
    }
    $result.Inspected = @($processes | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)

    # One flat lookup of everything worth matching, built once.
    $wanted = [System.Collections.Generic.List[object]]::new()
    foreach ($app in @($table.KnownApplications)) {
        foreach ($m in @($app.Modules)) {
            $wanted.Add([pscustomobject]@{ Pattern = $m; Application = [string]$app.Application })
        }
    }
    foreach ($m in @($table.OtherModules)) {
        $wanted.Add([pscustomobject]@{ Pattern = $m; Application = '' })
    }

    $seen = @{}
    foreach ($process in $processes) {
        $modules = @()
        try {
            # Modules is populated lazily and throws on a process that exits mid-enumeration
            # or that this token cannot open - a protected antivirus process, most often.
            $modules = @($process.Modules)
        } catch {
            Write-Verbose "Modules for $($process.ProcessName) ($($process.Id)) could not be read: $($_.Exception.Message)"
            continue
        }

        foreach ($module in $modules) {
            $result.ModulesInspected++

            # Each module is read defensively, not just the collection. Process.Modules is
            # materialised above, but the entries stay bound to a live process: when it exits
            # mid-enumeration the property access throws rather than returning empty, and
            # under StrictMode that takes the whole check down. Teams spawns and retires
            # helper processes constantly, so this is the normal case, not the edge.
            #
            # Both fields are taken here, in one guarded read, because the process can exit
            # between two accesses just as easily as before the first.
            $name = ''
            $modulePath = ''
            try {
                $name = [string]$module.ModuleName
                $modulePath = [string]$module.FileName
            } catch { continue }
            if (-not $name) { continue }

            foreach ($want in $wanted) {
                if ($name -notlike $want.Pattern) { continue }

                $key = '{0}|{1}' -f $process.ProcessName, $name
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true

                # Ownership and integrity, because Microsoft asks for them by name and because
                # an unsigned DLL on this list is a different finding from a signed one.
                $signer = ''
                $signatureStatus = 'Unknown'
                if ($modulePath) {
                    try {
                        $signature = Get-AuthenticodeSignature -LiteralPath $modulePath -ErrorAction Stop
                        $signatureStatus = [string]$signature.Status
                        if ($signature.SignerCertificate) { $signer = [string]$signature.SignerCertificate.Subject }
                    } catch {
                        Write-Verbose "Signature for $name could not be read: $($_.Exception.Message)"
                    }
                }

                # PSCustomObject, not [ordered]. An ordered hashtable does not expose its keys
                # as properties, so Group-Object, Select-Object and every downstream reader of
                # Collect.json get nothing from $_.Module. Caught by a proof run whose output
                # printed blank module names while the data underneath was correct.
                $result.Matches = @($result.Matches) + @([pscustomobject][ordered]@{
                    Process         = [string]$process.ProcessName
                    Module          = $name
                    Application     = $want.Application
                    Path            = $modulePath
                    SignatureStatus = $signatureStatus
                    Signer          = $signer
                })
            }
        }
    }

    $matched = @($result.Matches)
    $result.Detail = if ($matched.Count -eq 0) {
        "No documented interfering module is loaded into the Teams process(es). $($result.ModulesInspected) module(s) inspected across $($result.ProcessesFound) process(es)."
    } else {
        # @() around the whole pipeline, including Sort-Object. Sort-Object -Unique returns a
        # SCALAR when one value survives, and .Count on a scalar string throws under
        # Set-StrictMode - the same trap recorded three times already in this project.
        $named = @(@($matched | Where-Object { $_.Application } | ForEach-Object { $_.Application }) | Sort-Object -Unique)
        $label = if ($named.Count -gt 0) { $named -join ', ' }
                 else { (@(@($matched | ForEach-Object { $_.Module }) | Sort-Object -Unique)) -join ', ' }
        "$($matched.Count) documented module(s) are loaded into Teams: $label. Microsoft lists these as known to potentially block Teams or cause it to stop responding. Presence is expected on a managed machine and is not itself a fault - it is the first thing to rule in or out on a crash or hang."
    }

    return (New-Object psobject -Property $result)
}

function Get-TlcTacCorrelation {
    <#
    .SYNOPSIS
        The identifiers needed to match this bundle to a Teams admin center collection.
    .DESCRIPTION
        TAC remote log collection and this toolbox produce two separate bundles about the
        same incident, and nothing in either one points at the other. An engineer holding
        both has to establish by hand that they describe the same user on the same machine,
        which is exactly the problem the CVI correlation header solves across the interop
        boundary - the same idea, applied to two Microsoft surfaces instead.

        TAC keys a log request on UserId + DeviceId. What can be established locally:

          UserId    - the Entra object id, read from the client's own ECS request
                      parameters. This is the same identifier TAC uses. Verified.
          TenantId  - same source.
          DeviceId  - NOT directly. TAC's DeviceId comes from client health telemetry and
                      Microsoft does not document what it is derived from. The Entra
                      device id is reported here as the best local CANDIDATE and labelled
                      as one, because asserting a match that has never been verified is
                      how a bundle ends up cross-referenced to the wrong machine.

        MASKED BY DEFAULT, raw behind -IncludeRawIdentifiers. Owner decision 2026-09-24,
        finding 296 - the same rule the join state a few functions up has always followed.

        Until then this returned the raw user, tenant and device ids, and they reached the
        bundle raw in Inventory.json and Collect.json while the join state beside them masked
        the very same tenant and device ids. The reason for raw was the in-flight TAC request
        lookup, which needed the real UserId; that lookup no longer runs on the endpoint (it is
        a manual checklist step), so nothing here needs the raw value any more.

        The mask keeps the first eight and last four characters, so an engineer can still
        match a masked id by eye against the one the Teams admin center shows. Raw values are
        for the case where support genuinely needs them, and have to be asked for.

        Fails closed like the join state: if the masking helper cannot be reached the id is
        dropped rather than emitted raw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $StateRoot,
        [switch] $IncludeRawIdentifiers
    )

    # Gathered raw, emitted masked. The raw values live only in these locals.
    $raw = @{ UserId = ''; TenantId = ''; EntraDeviceId = '' }

    $result = [ordered]@{
        UserIdMasked           = ''
        TenantIdMasked         = ''
        EntraDeviceIdMasked    = ''
        DeviceIdIsCandidate    = $true
        MachineName            = $env:COMPUTERNAME
        Ring                   = ''
        Cloud                  = ''
        Region                 = ''
        RawIdentifiersIncluded = [bool]$IncludeRawIdentifiers
        Note                   = ''
    }

    $resolved = $StateRoot
    $resolver = Get-Command -Name 'Resolve-TlcPath' -ErrorAction SilentlyContinue
    if ($resolver -and $StateRoot) { $resolved = & $resolver -Path $StateRoot }

    if ($resolved) {
        $ecsPath = Join-Path $resolved 'ecs_request_param.json'
        if (Test-Path -LiteralPath $ecsPath) {
            try {
                $ecs = Get-Content -LiteralPath $ecsPath -Raw -ErrorAction Stop | ConvertFrom-Json
                foreach ($pair in @(
                    @{ Key = 'UserId';   Property = 'userId';   Raw = $true }
                    @{ Key = 'TenantId'; Property = 'tenantId'; Raw = $true }
                    @{ Key = 'Ring';     Property = 'ring';     Raw = $false }
                    @{ Key = 'Cloud';    Property = 'cloud';    Raw = $false }
                    @{ Key = 'Region';   Property = 'region';   Raw = $false }
                )) {
                    if ($ecs.PSObject.Properties.Name -contains $pair.Property) {
                        if ($pair.Raw) { $raw[$pair.Key] = [string]$ecs.$($pair.Property) }
                        else { $result[$pair.Key] = [string]$ecs.$($pair.Property) }
                    }
                }
            } catch {
                $result.Note = "ECS request parameters could not be read: $($_.Exception.Message)"
            }
        }
    }

    # dsregcmd rather than the registry: the registry layout differs between join states
    # and dsregcmd reports the same answer on all of them.
    $dsreg = Invoke-TlcNativeCommand -FilePath 'dsregcmd.exe' -ArgumentList @('/status')
    if ($dsreg.Available) {
        $line = @($dsreg.Lines | Where-Object { $_ -match '^\s*DeviceId\s*:' }) | Select-Object -First 1
        if ($line -and $line -match ':\s*(\S+)') { $raw.EntraDeviceId = $Matches[1] }
    } else {
        Write-Verbose "dsregcmd unavailable: $($dsreg.Detail)"
    }

    foreach ($name in 'UserId', 'TenantId', 'EntraDeviceId') {
        if (-not $raw[$name]) { continue }
        try {
            $result["$($name)Masked"] = Protect-TlcIdentifier -Value $raw[$name]
        } catch {
            # Dropped rather than emitted raw - a missing privacy helper must not leak an id.
            Write-Verbose "Protect-TlcIdentifier is unavailable, so $name is omitted: $($_.Exception.Message)"
            continue
        }
        if ($IncludeRawIdentifiers) { $result[$name] = $raw[$name] }
    }

    if (-not $result.Note) {
        $result.Note = if ($raw.UserId) {
            $how = if ($IncludeRawIdentifiers) { 'UserId' } else { 'UserIdMasked (first eight and last four characters)' }
            "$how matches the identifier TAC keys a log request on. EntraDeviceId is a candidate for TAC DeviceId, not a confirmed match - Microsoft does not document what TAC DeviceId is derived from."
        } else {
            'No signed-in user identifier found locally, so this bundle cannot be matched to a TAC collection by user.'
        }
    }

    return [pscustomobject]$result
}

function Get-TlcWebViewCrashFact {
    <#
    .SYNOPSIS
        Reports WebView2 renderer crashes without collecting the dumps.
    .DESCRIPTION
        New Teams is a WebView2 application, so a renderer crash is a real and common
        failure mode - the window goes blank or the app reloads itself - and it does not
        reliably reach the Application event log, which is where the Crashes tile looks.
        Crashpad writes those under EBWebView\Crashpad\reports.

        This deliberately reports COUNTS AND TIMES ONLY and never copies a dump.

        That is a privacy decision, not a size one. A minidump contains process memory,
        which for a signed-in Teams client means tokens, message content and whatever the
        user had on screen. The identity inventory scans text and would find none of it,
        so a dump would ride into a customer bundle as an unscannable blob the privacy
        gate cannot reason about. Microsoft made the same call: TAC log collection
        explicitly excludes heap dumps.

        Knowing three renderer crashes landed inside the repro window is most of the
        diagnostic value, and it carries none of that risk. If a dump is genuinely needed,
        the path is in the output and an engineer can take it deliberately, with consent,
        rather than by default.
    #>
    [CmdletBinding()]
    param(
        # AllowEmptyString because the config key can legitimately be blank, and the
        # caller should get a "not configured" fact rather than a parameter binding
        # exception that takes the whole inventory down with it.
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $StateRoot,
        [datetime] $WindowStart,
        [datetime] $WindowEnd
    )

    $result = [ordered]@{
        Supported     = $false
        ReportPath    = ''
        TotalCount    = 0
        InWindowCount = 0
        NewestLocal   = $null
        Reports       = @()
        Note          = ''
    }

    $resolved = $StateRoot
    $resolver = Get-Command -Name 'Resolve-TlcPath' -ErrorAction SilentlyContinue
    if ($resolver) { $resolved = & $resolver -Path $StateRoot }
    if (-not $resolved) { $result.Note = 'No client state folder configured.'; return [pscustomobject]$result }

    $reportPath = Join-Path (Join-Path (Join-Path $resolved 'EBWebView') 'Crashpad') 'reports'
    $result.ReportPath = $reportPath

    if (-not (Test-Path -LiteralPath $reportPath)) {
        $result.Note = 'No Crashpad report folder. Either WebView2 has not crashed on this profile, or the client stores them elsewhere.'
        return [pscustomobject]$result
    }

    $result.Supported = $true
    $files = @(Get-ChildItem -LiteralPath $reportPath -File -ErrorAction SilentlyContinue)
    $result.TotalCount = $files.Count

    if ($files.Count -eq 0) {
        $result.Note = 'Crashpad is present and has recorded no renderer crashes.'
        return [pscustomobject]$result
    }

    $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $result.NewestLocal = $newest.LastWriteTime.ToString('o')

    # Built with an explicit array rather than assigning the result of an if-expression.
    # PowerShell collapses @() from an if-expression to $null and unwraps a single-element
    # result to a bare object, so .Count throws under StrictMode on exactly the two cases
    # that matter most: no crashes at all, and precisely one crash. The tests caught this
    # by covering 0, 1 and many rather than only the comfortable middle.
    $inWindow = @()
    if ($PSBoundParameters.ContainsKey('WindowStart') -and $PSBoundParameters.ContainsKey('WindowEnd')) {
        $inWindow = @($files | Where-Object { $_.LastWriteTime -ge $WindowStart -and $_.LastWriteTime -le $WindowEnd })
    }
    $result.InWindowCount = @($inWindow).Count

    # Names and times only. The name is a GUID, so it carries nothing on its own, and it
    # gives an engineer something to ask for if a dump is genuinely needed.
    $result.Reports = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{
            Name      = $_.Name
            SizeBytes = $_.Length
            WhenLocal = $_.LastWriteTime.ToString('o')
            InWindow  = ($inWindow -contains $_)
        }
    })

    $result.Note = if ($result.InWindowCount -gt 0) {
        "$($result.InWindowCount) WebView2 renderer crash(es) inside the repro window. Dumps are not collected; the path is recorded so one can be taken deliberately."
    } else {
        "$($result.TotalCount) WebView2 renderer crash dump(s) present, none inside the repro window."
    }

    return [pscustomobject]$result
}

function Get-TlcClientInventory {
    <#
    .SYNOPSIS
        Auto lane. Captures the client and OS facts every support case asks for.
    #>
    [CmdletBinding()]
    param(
        [string] $Endpoint = $env:COMPUTERNAME,
        [string] $CacheRoot,
        [string] $LogRoot,
        [datetime] $WindowStart,
        [datetime] $WindowEnd,
        # Raw tenant, device and account ids in the join state and TacCorrelation. Off by
        # default: raw identity should be a decision someone made, not one they inherited.
        # It used to exist only on Get-TlcDeviceJoinState, where nothing passed it, so it
        # could not be reached from a run at all. Finding 296.
        [switch] $IncludeRawIdentifiers
    )

    $appx = Get-TlcAppxPackage
    $teams = $appx.Teams
    $slimcore = $appx.SlimCore
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    $webview2 = $null
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
                     'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
        $value = Get-ItemProperty -Path $key -Name pv -ErrorAction SilentlyContinue
        if ($value) { $webview2 = $value.pv; break }
    }

    # Status is the property that says whether the package can run at all, and it was not
    # being read. Anything other than Ok - DependencyIssue, Tampered, Modified, Disabled -
    # means Windows blocks Teams at activation, and every other field here would still
    # look perfectly healthy. An install location that no longer exists means the package
    # is registered but orphaned, which reads the same way.
    $packageStatus = $null
    $installLocation = $null
    $installLocationExists = $null
    $signatureKind = $null
    if ($teams) {
        $packageStatus = try { "$($teams.Status)" } catch { $null }
        $installLocation = try { [string]$teams.InstallLocation } catch { $null }
        if ($installLocation) { $installLocationExists = Test-Path -LiteralPath $installLocation }
        $signatureKind = try { "$($teams.SignatureKind)" } catch { $null }
    }

    $inventory = [ordered]@{
        Endpoint         = $Endpoint
        CollectedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        TeamsInstalled   = [bool]$teams
        TeamsVersion     = if ($teams) { $teams.Version } else { $null }
        TeamsPackageName = if ($teams) { $teams.PackageFullName } else { $null }
        TeamsPackageStatus        = $packageStatus
        TeamsInstallLocation      = $installLocation
        TeamsInstallLocationExists= $installLocationExists
        TeamsSignatureKind        = $signatureKind
        SlimCoreInstalled= [bool]$slimcore
        SlimCoreVersion  = if ($slimcore) { $slimcore.Version } else { $null }
        WebView2Version  = $webview2
        OsCaption        = if ($os) { $os.Caption } else { $null }
        OsVersion        = if ($os) { $os.Version } else { $null }
        OsBuild          = if ($os) { $os.BuildNumber } else { $null }
        LastBootUpTime   = if ($os) { $os.LastBootUpTime.ToUniversalTime().ToString('o') } else { $null }
        TimeZoneId       = [System.TimeZoneInfo]::Local.Id
        UtcOffsetHours   = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalHours
        IsVdiCandidate   = [bool]$slimcore
        Machine          = Get-TlcMachineFact
        AudioDevices     = Get-TlcAudioDeviceFact
        Clock            = Get-TlcClockFact
        Power            = Get-TlcPowerFact
        JoinState        = Get-TlcDeviceJoinState -IncludeRawIdentifiers:$IncludeRawIdentifiers
        MeetingAddin     = Get-TlcMeetingAddinFact
    }

    if ($CacheRoot) { $inventory['Cache'] = Get-TlcCacheFootprint -Path $CacheRoot }
    if ($LogRoot) { $inventory['UpdateHistory'] = Get-TlcClientUpdateHistory -LogRoot $LogRoot }

    # WebView2 renderer crashes. CacheRoot is the client state root, which is the parent
    # the Crashpad tree hangs off. Counts and times only - see Get-TlcWebViewCrashFact for
    # why the dumps themselves are deliberately left on the machine.
    if ($CacheRoot) {
        $inventory['TacCorrelation'] = Get-TlcTacCorrelation -StateRoot $CacheRoot -IncludeRawIdentifiers:$IncludeRawIdentifiers

        # What is actually loaded into the Teams processes, against Microsoft's published list
        # of DLLs known to potentially block Teams or cause it to stop responding. Their
        # crash-triage guidance
        # leads with this check and the toolbox had never made it.
        $inventory['InterferingModules'] = Get-TlcInterferingModuleFact

        # Reparse points over the folders the client reads through, and the package policy that
        # blocks sideloading. Microsoft's own launch-failure script checks these, and both are
        # invisible in the client's logs: new Teams does not report that its cache folder is a
        # junction pointing somewhere it cannot write, it just exits.
        $inventory['LaunchEnvironment'] = Get-TlcLaunchEnvironmentFact

        # NOT HERE: whether a TAC log request is already pending. That needed a Teams admin
        # session on the endpoint, which a customer run never has, so every real run recorded
        # "could not be read". It is now the first step of the TacRemoteClientLogs manual
        # checklist item. Owner decision 2026-09-24; finding 296.

        $crashArgs = @{ StateRoot = $CacheRoot }
        if ($PSBoundParameters.ContainsKey('WindowStart')) { $crashArgs['WindowStart'] = $WindowStart }
        if ($PSBoundParameters.ContainsKey('WindowEnd')) { $crashArgs['WindowEnd'] = $WindowEnd }
        $webviewCrash = Get-TlcWebViewCrashFact @crashArgs
        $inventory['WebViewCrashes'] = $webviewCrash

        if ($webviewCrash.InWindowCount -gt 0) {
            # Raised because the Crashes tile reads the Application log, and a renderer
            # crash does not reliably land there. Without this the bundle can say "no
            # crashes" while the user watched the window go blank.
            Write-TlcBlocker -Check 'ClientInventory.WebViewCrash' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                -Detail "$($webviewCrash.InWindowCount) WebView2 renderer crash(es) recorded inside the repro window. Dumps are not collected." `
                -Remediation "If a dump is needed, take it deliberately and with consent from $($webviewCrash.ReportPath)." | Out-Null
        }
    }

    if (-not $teams) {
        Write-TlcBlocker -Check 'ClientInventory' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
            -Detail 'New Teams (MSTeams) package not found for this user.' `
            -Remediation 'Run the collection in the affected user session.' | Out-Null
    } else {
        Write-TlcBlocker -Check 'ClientInventory' -Status 'Success' -Endpoint $Endpoint `
            -Detail "Teams $($teams.Version) on $($inventory.OsCaption) build $($inventory.OsBuild)." | Out-Null
    }

    # Separate from the check above, because the package being present and the package
    # being usable are different questions and only the first was ever asked.
    if ($teams) {
        if ($packageStatus -and $packageStatus -ne 'Ok') {
            Write-TlcBlocker -Check 'ClientInventory.PackageHealth' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
                -Detail "The MSTeams package reports status '$packageStatus', so Windows will block it at activation." `
                -Remediation 'Repair or re-register the package. DependencyIssue points at a missing framework package rather than at Teams itself; Tampered is usually set by an EDR product.' | Out-Null
        } elseif ($installLocationExists -eq $false) {
            Write-TlcBlocker -Check 'ClientInventory.PackageHealth' -Status 'Blocked' -Severity 'Critical' -Endpoint $Endpoint `
                -Detail "The package is registered but its install location is missing: $installLocation" `
                -Remediation 'The registration is orphaned. Re-register the package for this user.' | Out-Null
        } else {
            Write-TlcBlocker -Check 'ClientInventory.PackageHealth' -Status 'Success' -Endpoint $Endpoint `
                -Detail "Package status Ok, signed as $signatureKind, install location present." | Out-Null
        }
    }

    if ($inventory.Contains('Cache') -and $inventory.Cache.Exists) {
        $largest = @($inventory.Cache.Folders | Select-Object -First 1)
        $detail = "Teams cache is $($inventory.Cache.TotalMB) MB across $($inventory.Cache.TotalFiles) file(s)"
        if ($largest.Count -gt 0) { $detail += ", largest $($largest[0].Name) at $($largest[0].SizeMB) MB" }
        Write-TlcBlocker -Check 'ClientInventory.Cache' -Status 'Success' -Severity 'Information' -Endpoint $Endpoint `
            -Detail "$detail." | Out-Null
    }

    # Reported whether or not anything is wrong, because "the Teams button is missing in
    # Outlook" is a common report with three ordinary causes and no way to tell them apart
    # from the outside. The verdict comes from Get-TlcMeetingAddinHealth so the wizard's
    # advisory and this blocker cannot disagree.
    $addinHealth = Get-TlcMeetingAddinHealth -Addin $inventory.MeetingAddin
    $addinSeverity = if ($addinHealth.Status -eq 'Success') { 'Information' } else { 'Warning' }

    $addinBlocker = @{
        Check = 'ClientInventory.MeetingAddin'; Status = $addinHealth.Status
        Severity = $addinSeverity; Endpoint = $Endpoint; Detail = $addinHealth.Detail
    }
    if ($addinHealth.Remediation) { $addinBlocker['Remediation'] = $addinHealth.Remediation }
    Write-TlcBlocker @addinBlocker | Out-Null

    # "They can't hear me" / "I can't hear them" with nothing usable on one side. The data was
    # always in Inventory.json, and nothing said it: with the only microphone disabled on
    # the lab endpoint the bundle recorded Status Error and raised no row. Finding 305.
    #
    # Only the no-working-device case. Disconnected monitors report their audio endpoints as
    # Unknown - eight of thirteen on one healthy machine - so "any unhealthy endpoint" would
    # fire everywhere and teach people to skip the row.
    $audio = $inventory.AudioDevices
    foreach ($problem in @(Get-TlcAudioProblem -Audio $audio)) {
        Write-TlcBlocker -Check 'ClientInventory.Audio' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail $problem `
            -Remediation 'Check Device Manager and Settings > System > Sound. An endpoint in Error is usually disabled or its driver failed; Unknown usually means unplugged.' | Out-Null
    }

    foreach ($problem in @(Get-TlcClockProblem -Clock $inventory.Clock)) {
        Write-TlcBlocker -Check 'ClientInventory.Clock' -Status 'Warning' -Severity $problem.Severity -Endpoint $Endpoint `
            -Detail $problem.Detail -Remediation $problem.Remediation | Out-Null
    }

    # Reported because the value it replaces was actively misleading: Win32_ComputerSystem
    # says DomainJoined False on an Entra-joined machine, which reads as unmanaged.
    $join = $inventory.JoinState
    if ($join.Available) {
        $how = @()
        if ($join.AzureAdJoined) { $how += 'Entra joined' }
        if ($join.DomainJoined) { $how += 'domain joined' }
        if ($join.WorkplaceJoined) { $how += 'workplace joined' }
        if ($how.Count -eq 0) { $how += 'not joined to anything' }

        Write-TlcBlocker -Check 'ClientInventory.JoinState' -Status 'Success' -Severity 'Information' -Endpoint $Endpoint `
            -Detail $(if ($IncludeRawIdentifiers) {
                "Device is $($how -join ' and '). Raw tenant, device and account ids were included on request (-IncludeRawIdentifiers), in the join state and TacCorrelation alike."
            } else {
                "Device is $($how -join ' and '). Tenant, device and account ids appear only as stable masks, in the join state and TacCorrelation alike."
            }) | Out-Null
    }

    return $inventory
}

function Copy-TlcClientState {
    <#
    .SYNOPSIS
        Auto lane. Copies client state files that explain configuration and crashes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Collection,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [string] $Endpoint = $env:COMPUTERNAME
    )

    $stateRoot = Resolve-TlcPath -Path $Collection.ClientStateRoot
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        Write-TlcBlocker -Check 'ClientState' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "Client state folder not found: $stateRoot" | Out-Null
        return @()
    }

    $destination = Join-Path $EndpointPath 'ClientState'
    $null = New-Item -ItemType Directory -Path $destination -Force

    $copied = foreach ($name in $Collection.ClientStateFiles) {
        $source = Join-Path $stateRoot $name
        if (Test-Path -LiteralPath $source) {
            $target = Join-Path $destination $name
            try {
                Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
                $name
            } catch {
                # Copy-Item creates the destination before it fails. These are client state
                # files belonging to a Teams client that is usually still running, so a lock is
                # the expected case rather than the exceptional one - and without this the
                # zero-byte result was counted in "N of M state file(s) copied", reporting
                # absent evidence as collected. See findings 129 and 133.
                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                }
                Write-Verbose "$name could not be copied: $($_.Exception.Message)"
            }
        }
    }

    $copied = @($copied)
    $status = if ($copied.Count -gt 0) { 'Success' } else { 'Warning' }
    Write-TlcBlocker -Check 'ClientState' -Status $status -Endpoint $Endpoint `
        -Detail "$($copied.Count) of $(@($Collection.ClientStateFiles).Count) state file(s) copied." | Out-Null
    Write-TlcEvent -Phase 'Collect' -Step 'ClientState' -Status 'Complete' -Endpoint $Endpoint `
        -Message "$($copied.Count) state file(s) copied." -EvidencePath $destination

    return $copied
}

function Get-TlcClockProblem {
    <#
    .SYNOPSIS
        What, if anything, to say about the clock. Nothing when it is within tolerance.
    .DESCRIPTION
        An offset beyond 5 minutes - the Kerberos default tolerance - is a Warning, because
        sign-in fails over it. An unmeasured offset is said as such, never as a good one.

        The Windows Time service state is stated as a fact and never raised on its own. The first
        draft called a stopped service "nothing is keeping the clock right", and that is false:
        on the lab endpoint it is Manual with a trigger start, so Stopped is its normal state. Finding 308.
    #>
    [CmdletBinding()]
    param($Clock)

    if (-not $Clock) { return }
    $service = [string]$Clock.TimeServiceStatus
    if ($Clock.Measured -and [math]::Abs([double]$Clock.OffsetSeconds) -gt 300) {
        $ahead = if ([double]$Clock.OffsetSeconds -gt 0) { 'ahead of' } else { 'behind' }
        $minutes = [math]::Round([math]::Abs([double]$Clock.OffsetSeconds) / 60, 1)
        [pscustomobject]@{
            Severity    = 'Warning'
            Detail      = "This machine's clock is $minutes minute(s) $ahead Microsoft's (reference $($Clock.Reference)). Kerberos refuses more than 5 minutes by default, which breaks sign-in to on-premises and hybrid resources. Entra sign-in survived a clock 3 hours ahead when tested, so this alone does not explain a Microsoft 365 sign-in failure. Windows Time service: $service."
            Remediation = 'Correct the time: Settings > Time & language > Date & time > Sync now, or w32tm /resync from an elevated prompt. Then retry the sign-in.'
        }
    } elseif (-not $Clock.Measured) {
        [pscustomobject]@{
            Severity    = 'Information'
            Detail      = "The clock could not be compared with Microsoft's. $($Clock.Detail)".Trim()
            Remediation = 'Compare the time by hand with a trusted source if sign-in is failing.'
        }
    }
}

function Get-TlcAudioProblem {
    <#
    .SYNOPSIS
        One sentence per side (recording, playback) that has no working device. Nothing when
        both sides have one.
    .DESCRIPTION
        Only the no-working-device case. Disconnected monitors report their audio endpoints as
        Unknown - eight of thirteen on one healthy machine - so "any unhealthy endpoint" would
        fire everywhere. Finding 305: with the only microphone disabled the bundle recorded
        Status Error and raised no row at all.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Audio)

    if (-not $Audio -or -not $Audio.Available) { return }
    foreach ($side in @(
        @{ Name = 'microphone'; Devices = @($Audio.CaptureDevices | Where-Object { $_ }) }
        @{ Name = 'speaker or headset'; Devices = @($Audio.RenderDevices | Where-Object { $_ }) }
    )) {
        $working = @($side.Devices | Where-Object { [string]$_.Status -eq 'OK' })
        if ($working.Count -gt 0) { continue }
        $listed = if ($side.Devices.Count -gt 0) {
            ' Present but not working: ' + (($side.Devices | ForEach-Object { "$($_.Name) [$($_.Status)]" }) -join '; ') + '.'
        } else { ' None is present.' }
        "No working $($side.Name) on this machine.$listed"
    }
}

function Select-TlcTeamsFaultEvent {
    <#
    .SYNOPSIS
        The Application crash, error-report and hang records that are about Teams.
    .DESCRIPTION
        They were collected, then counted in with everything else. Matched on the message
        because 1000 and 1002 carry the faulting application there, and on the package name as
        well as the exe so a WER record (1001), which names the package, is caught too.
        Finding 305, proved with a real Application Error for a process named ms-teams.exe.
    #>
    [CmdletBinding()]
    param([object[]] $Records)

    foreach ($record in @($Records | Where-Object { $_ })) {
        if ($record.LogName -ne 'Application' -or $record.Id -notin 1000, 1001, 1002) { continue }
        if ([string]$record.Message -notmatch '(?i)ms-teams\.exe|MSTeams_8wekyb3d8bbwe') { continue }
        $kind = switch ($record.Id) { 1000 { 'crash' } 1001 { 'error report' } 1002 { 'hang' } }
        $module = if ([string]$record.Message -match '(?i)Faulting module name:\s*([^,\r\n]+)') { " in $($Matches[1].Trim())" } else { '' }
        [pscustomobject]@{
            Id          = $record.Id
            Kind        = $kind
            Module      = $module.Trim() -replace '^in\s+', ''
            TimeUtc     = $record.TimeCreatedUtc
            Description = "$kind$module at $($record.TimeCreatedUtc)"
        }
    }
}

function Select-TlcSignInFaultEvent {
    <#
    .SYNOPSIS
        Entra sign-in failures from AAD/Operational, with the code and description the event
        itself carries.
    .DESCRIPTION
        Quoted, not interpreted. Microsoft publishes no table for the 0xCAA... token-broker
        codes, so a meaning written here would be a guess with the bundle's authority. Windows
        puts its own description beside the code - "0xCAA70004 The server or proxy was not
        found" - and that is what a reader needs. A nested cause ("Error: ... (0xcaa70004),
        Description: ...") is preferred over the wrapper, which only says the broker failed.
        Finding 307.
    #>
    [CmdletBinding()]
    param([object[]] $Records)

    foreach ($record in @($Records | Where-Object { $_ })) {
        if ($record.LogName -ne 'Microsoft-Windows-AAD/Operational') { continue }
        $isError = if ($record.PSObject.Properties.Name -contains 'LevelValue' -or ($record -is [System.Collections.IDictionary] -and $record.Contains('LevelValue'))) {
            [int]$record.LevelValue -in 1, 2
        } else {
            [string]$record.Level -match '(?i)^(Error|Critical)$'
        }
        if (-not $isError) { continue }
        $message = [string]$record.Message
        $code = ''; $description = ''
        if ($message -match '(?i)\((0x[0-9a-f]{8})\),\s*Description:\s*([^,\r\n]+)') {
            $code = $Matches[1]; $description = $Matches[2]
        } elseif ($message -match '(?i)Error:\s*(0x[0-9a-f]{8})\s+([^\r\n]+)') {
            $code = $Matches[1]; $description = $Matches[2]
        }
        if (-not $code) { continue }
        [pscustomobject]@{
            Id          = $record.Id
            Code        = $code.ToUpperInvariant() -replace '^0X', '0x'
            Description = $description.Trim().TrimEnd('.')
            TimeUtc     = [string]$record.TimeCreatedUtc
        }
    }
}

function Get-TlcEventLogEvidence {
    <#
    .SYNOPSIS
        Auto lane. Windows events inside the repro window, across several logs.
    .DESCRIPTION
        Each configured log carries its own filter. A single id list applied to every log
        was throwing away most of what the logs contained: measured over thirty days on
        one machine it matched two System events, while excluding Kernel-Power 41 twice,
        6008 three times, 7031 once and 7000/7009 sixty-five times between them - and in
        Application it discarded 140 Error and Critical events including 37 from the .NET
        Runtime.

        Ids and Levels within one entry are OR'd. Get-WinEvent ANDs everything in a
        FilterHashtable, so this runs one query per dimension and merges on RecordId.
        The alternative loses real evidence: Application event 1001, the Windows Error
        Reporting record, is written at Information, so an Error-level filter drops every
        crash report while appearing to be the stricter, safer choice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Collection,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [string] $Endpoint = $env:COMPUTERNAME,
        # Name Entra sign-in errors in their own row. Only where sign-in is the question:
        # healthy machines log several an hour for other applications. Finding 307.
        [switch] $ReportSignInFaults
    )

    if (-not $Collection.IncludeEventLogs) { return @() }

    $definitions = @($Collection.EventLogs)
    if ($definitions.Count -eq 0) { return @() }

    $cap = if ($Collection.Contains('MaxEventsPerLog') -and $Collection.MaxEventsPerLog) {
        [int]$Collection.MaxEventsPerLog
    } else { 400 }

    $collected = [System.Collections.Generic.List[object]]::new()
    $perLog = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()

    # Published meanings for ids in channels already being collected. Nothing extra is
    # gathered: this turns a raw channel into an answer, which is the cheapest useful thing
    # the toolbox can do with evidence it already has. Keyed "<channel>|<id>".
    #
    # Only ids Microsoft documents are listed. A meaning inferred from a log sample would read
    # with exactly the same authority as the rest of the bundle while being a guess.
    $annotations = @{}
    $hresults = @{}
    try {
        $referencePath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Data') 'EventIdReference.psd1'
        if (Test-Path -LiteralPath $referencePath) {
            $reference = Import-TlcCollectorData -Path $referencePath
            foreach ($channel in @($reference.Channels)) {
                foreach ($documented in @($channel.Events)) {
                    $annotations["$($channel.Channel)|$($documented.Id)"] = [string]$documented.Meaning
                }
            }
            foreach ($code in @($reference.HResults)) {
                $hresults[([string]$code.Code).ToUpperInvariant()] = '{0}: {1}' -f $code.Name, $code.Meaning
            }
        }
    } catch {
        Write-Verbose "Event id reference could not be read: $($_.Exception.Message)"
    }

    foreach ($definition in $definitions) {
        $logName = [string]$definition.LogName
        if (-not $logName) { continue }

        # Wrapped in @() outside the if, not inside. An if-expression whose branch yields
        # an empty array produces nothing at all, so $ids would be $null and $ids.Count
        # would then fail under StrictMode - the same trap as finding 16.
        $ids = @(if ($definition.Contains('Ids')) { $definition.Ids })
        $levels = @(if ($definition.Contains('Levels')) { $definition.Levels })
        $messageMatch = if ($definition.Contains('MessageMatch')) { [string]$definition.MessageMatch } else { '' }

        # One query per dimension. No dimension at all means take the window unfiltered,
        # which is right for a channel that logs nothing above Information.
        $filters = @()
        if ($ids.Count -gt 0) { $filters += @{ LogName = $logName; StartTime = $WindowStart; EndTime = $WindowEnd; Id = $ids } }
        if ($levels.Count -gt 0) { $filters += @{ LogName = $logName; StartTime = $WindowStart; EndTime = $WindowEnd; Level = $levels } }
        if ($filters.Count -eq 0) { $filters += @{ LogName = $logName; StartTime = $WindowStart; EndTime = $WindowEnd } }

        $seen = @{}
        $forThisLog = [System.Collections.Generic.List[object]]::new()
        $logMissing = $false

        # Analytical and Debug channels can only be read forward in time. Get-WinEvent refuses
        # them outright without -Oldest, with an error that names the parameter - so without
        # this, adding such a channel to the configuration would produce a Warning blocker on
        # every single run instead of evidence.
        #
        # -Oldest is passed ONLY for those channels, never as a blanket. It changes which
        # events survive MaxEvents: measured on Application over 24 hours, without it the
        # first record returned was 09:30 and with it 10:09 - so it silently swaps "the newest
        # N in the window" for "the oldest N". On a capped classic channel that would quietly
        # discard the most recent evidence, which is usually the evidence.
        #
        # LogType rather than matching the error text, because the message is localised and
        # this has to work on a customer machine in any language. Costs about 29 ms per
        # channel, measured.
        $useOldest = $false
        $channelDisabled = $false
        try {
            $channel = Get-WinEvent -ListLog $logName -ErrorAction Stop
            $useOldest = ("$($channel.LogType)" -in @('Analytical', 'Debug'))
            $channelDisabled = (-not $channel.IsEnabled)
        } catch {
            Write-Verbose "Channel type for $logName could not be read: $($_.Exception.Message)"
        }

        # A disabled channel holds nothing, and an empty section that looks identical to a
        # healthy quiet one is the silent failure this collector exists to avoid. Said once
        # per channel, as a fact rather than an error: disabled analytic channels are the
        # normal state of a Windows machine, not a fault on this one.
        if ($channelDisabled) {
            Write-TlcBlocker -Check 'EventLogs.Channel' -Status 'Warning' -Severity 'Information' -Endpoint $Endpoint `
                -Detail "$logName is present but not enabled, so it holds no events. Enabling it changes machine state and requires elevation, so the toolbox does not do it." `
                -Remediation "If this channel matters for the case, enable it with wevtutil set-log `"$logName`" /enabled:true, reproduce the fault, then collect again." | Out-Null
        }

        foreach ($filter in $filters) {
            try {
                # Named $entry rather than $event: $Event is an automatic variable.
                foreach ($entry in (Get-WinEvent -FilterHashtable $filter -MaxEvents $cap -Oldest:$useOldest -ErrorAction Stop)) {
                    # RecordId is what makes the merge safe: an event matching both the id
                    # and the level filter would otherwise appear twice in the bundle.
                    if ($seen.ContainsKey($entry.RecordId)) { continue }
                    $seen[$entry.RecordId] = $true

                    # A provider whose message resources are missing throws on .Message
                    # rather than returning null, and one such event must not cost the
                    # whole log.
                    $message = try { $entry.Message } catch { '<the provider could not render this message>' }
                    $level = try { $entry.LevelDisplayName } catch { "Level $($entry.Level)" }

                    # Applied after retrieval because the message is not a queryable
                    # field. This exists for channels that are shared by every app on the
                    # machine: unfiltered, the notification platform contributed 202 of
                    # 211 events in a one-hour window - keep-alive pings and other
                    # applications' toasts - burying the nine that were about Teams.
                    if ($messageMatch -and $message -notmatch $messageMatch) { continue }

                    $annotationKey = "$logName|$($entry.Id)"
                    $meaning = if ($annotations.ContainsKey($annotationKey)) { $annotations[$annotationKey] } else { '' }

                    # An AppX deployment failure states its real cause in the HRESULT inside
                    # the message, not in the event id - Microsoft documents exactly one id
                    # for that channel and a table of codes. Reading the code out is the
                    # difference between "deployment failed" and "sideloading is disabled".
                    if ($hresults.Count -gt 0 -and $message) {
                        $codes = [System.Collections.Generic.List[string]]::new()
                        foreach ($hit in [regex]::Matches($message, '0x[0-9A-Fa-f]{8}')) {
                            $code = $hit.Value.ToUpperInvariant()
                            if ($hresults.ContainsKey($code) -and -not $codes.Contains($hresults[$code])) {
                                $codes.Add($hresults[$code])
                            }
                        }
                        if ($codes.Count -gt 0) {
                            $meaning = (@($meaning) + $codes | Where-Object { $_ }) -join ' '
                        }
                    }

                    $forThisLog.Add([ordered]@{
                        LogName        = $logName
                        RecordId       = $entry.RecordId
                        Id             = $entry.Id
                        Level          = $level
                        # The number as well as the name: LevelDisplayName is translated, so a
                        # test for 'Error' fails on a German or Japanese machine.
                        LevelValue     = [int]$entry.Level
                        ProviderName   = $entry.ProviderName
                        TimeCreatedUtc = $entry.TimeCreated.ToUniversalTime().ToString('o')
                        Message        = $message
                        Meaning        = $meaning
                    })
                }
            } catch {
                $text = $_.Exception.Message

                # Three outcomes that are not failures and must not read as one:
                # an empty window, a channel this build of Windows does not have, and a
                # channel that exists but has never been enabled. Matched by error id and
                # type as well as by text, because the text is localized (review 2026-09-30).
                if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $text -match 'No events were found') { continue }
                if ($_.FullyQualifiedErrorId -like 'NoMatchingLogsFound*' -or
                    $_.Exception -is [System.Diagnostics.Eventing.Reader.EventLogNotFoundException] -or
                    $text -match 'There is not an event log|could not be found|specified channel could not be found') {
                    $logMissing = $true
                    continue
                }

                Write-TlcBlocker -Check 'EventLogs.Channel' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                    -Detail "$logName could not be read: $text" | Out-Null
            }
        }

        if ($logMissing -and $forThisLog.Count -eq 0) {
            $missing.Add($logName)
            continue
        }

        # The newest records survive the cap, not the oldest. Each query already asks for its
        # newest $cap; merging two can exceed it, and trimming the ascending list with -First
        # kept the oldest and dropped the most recent fault evidence (review 2026-09-30).
        #
        # Sorted by a scriptblock, not by the property NAME: these records are ordered
        # dictionaries, and Sort-Object resolves a name against properties, not keys - measured
        # on both editions, "Sort-Object TimeCreatedUtc" left them in query order, so neither
        # EventLogs.json nor the cap was ever in time order.
        $ordered = @($forThisLog | Sort-Object { $_['TimeCreatedUtc'] })
        if ($ordered.Count -gt $cap) { $ordered = @($ordered | Select-Object -Last $cap) }

        $perLog[$logName] = $ordered.Count
        foreach ($record in $ordered) { $collected.Add($record) }
    }

    $records = @($collected)

    # A Teams crash or hang said out loud. They were collected, and then counted in with
    # everything else: "Application 2" in a row of per-log counts, with the faulting module
    # only in EventLogs.json. Found by producing a real Application Error for a process named
    # ms-teams.exe, finding 305. Matched on the message because 1000/1002 carry the faulting
    # application there, and on the package name as well as the exe so a WER record (1001),
    # which names the package, is caught too.
    $teamsFaults = @(Select-TlcTeamsFaultEvent -Records $records)
    if ($teamsFaults.Count -gt 0) {
        $described = @($teamsFaults | ForEach-Object { $_.Description })
        Write-TlcBlocker -Check 'EventLogs.TeamsFault' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "Windows recorded $($teamsFaults.Count) Teams fault(s) in the window: $($described -join '; ')." `
            -Remediation 'The faulting module is where to start: a Teams or WebView2 module points at the client, a third-party DLL at something injected into it. Full records are in EventLogs.json.' | Out-Null
    }

    $signInFaults = @(if ($ReportSignInFaults) { Select-TlcSignInFaultEvent -Records $records })
    if ($signInFaults.Count -gt 0) {
        $grouped = @($signInFaults | Group-Object Code, Description | Sort-Object Count -Descending | ForEach-Object {
            $first = @($_.Group | Sort-Object TimeUtc)[0]
            "$($first.Code) $($first.Description) (x$($_.Count), first $($first.TimeUtc))"
        })
        Write-TlcBlocker -Check 'EventLogs.SignInFault' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail ("Windows recorded $($signInFaults.Count) Entra sign-in error(s) in the window: $($grouped -join '; '). " +
                     'Healthy machines log a few of these every hour for other applications, so the ones that line up with the reported problem are the ones that matter.') `
            -Remediation 'The descriptions are Windows'' own. A server or proxy not found, or a timeout, points at the network path to login.microsoftonline.com; interaction required means the user must satisfy MFA or another challenge. The full records are in EventLogs.json.' | Out-Null
    }

    $summary = if ($perLog.Count -gt 0) {
        ($perLog.Keys | ForEach-Object { "$_ $($perLog[$_])" }) -join ', '
    } else {
        'no events in window'
    }

    Write-TlcBlocker -Check 'EventLogs' -Status 'Success' -Endpoint $Endpoint `
        -Detail "$($records.Count) event(s) in window across $($perLog.Count) log(s): $summary." | Out-Null

    if ($missing.Count -gt 0) {
        # Reported, not warned about. A channel absent from this build of Windows is a
        # fact about the machine, and silence would leave a reader assuming it was clean.
        Write-TlcBlocker -Check 'EventLogs.Unavailable' -Status 'Success' -Severity 'Information' -Endpoint $Endpoint `
            -Detail "Not present on this machine, so not collected: $($missing -join ', ')." | Out-Null
    }

    Write-TlcEvent -Phase 'Collect' -Step 'EventLogs' -Status 'Complete' -Endpoint $Endpoint `
        -Message "$($records.Count) event(s) collected."

    return $records
}

function Invoke-TlcSupportFilePrompt {
    <#
    .SYNOPSIS
        Prompted lane. Asks the user to trigger support file collection, then harvests it.
    .DESCRIPTION
        Ctrl + Alt + Shift + 1 has no API. That is still true, but the conclusion drawn from
        it - "so the only honest automation is to ask" - was wrong, and is corrected in
        Invoke-TlcWebLogTrigger, which delivers the shortcut with SendInput after attaching
        this thread's input queue to the foreground thread. Measured working three times on
        build 26225, bundle landing about 57-59 seconds later.

        This prompted lane remains, and remains the default, for two reasons that are about
        judgement rather than capability. Synthetic input goes wherever focus actually is, so
        an automated trigger is only safe when it can prove Teams came to the foreground -
        and on a customer's machine, seizing the foreground and typing into their Teams is a
        thing to do deliberately rather than by default. Asking also leaves the user in the
        loop on a collection that sweeps in every signed-in account, which the bundle
        demonstrably does.

        Retrospective runs ask by default. Live captures pass AutoTrigger after sampling,
        with the same foreground safeguards and an explicit manual fallback on failure.
        Anything that appeared before the prompt is ignored either way - otherwise a stale
        bundle from a previous incident gets attached to this case and reads as fresh
        evidence.

        Unattended runs skip this lane rather than blocking forever.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Collection,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [int] $TimeoutMinutes = 10,
        [switch] $AutoTrigger,
        [switch] $SkipPrompted,
        [string] $Endpoint = $env:COMPUTERNAME,
        # How long everything found must stay unchanged before it is harvested. Measured on
        # a live call, 2026-09-24: Teams wrote the Support Logs folder, went quiet for 25 s,
        # then wrote the PROD-WebLogs zip. 45 s clears that gap with margin. Finding 303.
        [int] $SettleSeconds = 45,
        # Quiet is not enough on its own for the folder: Teams pauses mid-bundle (111-128 s on one
        # machine, 31 s on another) before its final burst. That burst is the client's own
        # settings files copied last - app_settings.json on every install, plus
        # app_switcher_settings.json and tma_settings.json where those exist. ANY of them
        # present means the burst has begun, and the quiet period then covers the rest.
        #
        # The first version required app_switcher_settings.json alone, from three bundles on
        # ONE machine. A second machine's complete 413-file bundle never contains it, so every
        # harvest there waited four minutes and then warned about a bundle that was whole.
        # Finding 307.
        [string[]] $CompletionMarkers = @('app_settings.json', 'app_switcher_settings.json', 'tma_settings.json'),
        [int] $MarkerWaitSeconds = 240,
        [int] $PollSeconds = 5,
        # A live capture's stop sentinel. Present while this waits means the operator pressed Stop
        # run again to skip the wait, and is the only way they can: the wizard runs this with no
        # console, so the "Press Ctrl+C" this used to print could not be done. Finding 321.
        [string] $StopSignalPath = '',
        # How a console run is skipped: a key press, polled. It used to say "Press Ctrl+C to
        # skip", and Ctrl+C ends the whole run - no Run.json, no Capture.json, no bundle - rather
        # than skipping one step (review 2026-09-30). Injected so the skip path can be tested
        # without a keyboard; the default reads the console when there is one to read.
        [scriptblock] $KeySkipCheck = {
            try {
                if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                    return ([Console]::ReadKey($true).Key -eq [ConsoleKey]::S)
                }
            } catch {
                Write-Verbose "The console cannot be read for a key press: $($_.Exception.Message)"
            }
            return $false
        }
    )

    if ($SkipPrompted) {
        Write-TlcStopProgress -SignalPath $StopSignalPath -Step Support -Status Skipped -DetailKey 'StopDetailSupportSkipped'
        Write-TlcBlocker -Check 'SupportFiles' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail 'Prompted lane skipped (-SkipPrompted).' `
            -Remediation 'Re-run interactively with the affected user to capture media and signaling logs.' | Out-Null
        Write-TlcEvent -Phase 'Collect' -Step 'SupportFiles' -Status 'Skipped' -Severity 'Warning' -Endpoint $Endpoint `
            -Message 'Prompted lane skipped.'
        return $null
    }

    $dropFolder = Resolve-TlcPath -Path $Collection.SupportFileDropFolder
    $patterns = @($Collection.WebLogPatterns) + @($Collection.SupportLogPatterns)
    $promptedAt = Get-Date

    Write-Information '' -InformationAction Continue
    if ($AutoTrigger) {
        Write-Information '  Generating Teams support files automatically; no keyboard shortcut is normally needed.' -InformationAction Continue
    } else {
        Write-Information '  ACTION REQUIRED - Teams support files' -InformationAction Continue
        Write-Information '  In Teams, press Ctrl + Alt + Shift + 1 (Windows) or Option + Command + Shift + 1 (Mac).' -InformationAction Continue
    }
    Write-Information '  Waiting for the Teams download to finish.' -InformationAction Continue
    Write-Information "  Files land in: $dropFolder" -InformationAction Continue
    $console = $false
    try { $console = -not [Console]::IsInputRedirected -and [Environment]::UserInteractive } catch { $console = $false }
    $skipHow = if ($StopSignalPath) {
        'Use Skip support files to skip this step.'
    } elseif ($console) {
        'Press S to skip this step.'
    } else {
        'It ends by itself when the time is up.'
    }
    Write-Information "  Waiting up to $TimeoutMinutes minute(s). $skipHow" -InformationAction Continue
    if ($StopSignalPath) { Write-Information 'TLC-SUPPORTWAIT:Start' -InformationAction Continue }

    $deadline = $promptedAt.AddMinutes($TimeoutMinutes)
    $found = @()
    $skipRequested = {
        [bool](($StopSignalPath -and (Test-Path -LiteralPath $StopSignalPath)) -or (& $KeySkipCheck))
    }
    $skipped = $false
    $pendingAuto = [bool]$AutoTrigger
    $triggerState = @{ Sent = $false }
    $invokeTrigger = {
        if ($StopSignalPath) { Write-Information 'TLC-SUPPORTSTATE:Generating' -InformationAction Continue }
        $trigger = Invoke-TlcWebLogTrigger -TriggerOnly -DownloadPath $dropFolder -Endpoint $Endpoint -Confirm:$false
        $triggerState.Sent = [bool]$trigger.Triggered
        Write-Information "  $($trigger.Detail)" -InformationAction Continue
        if ($StopSignalPath) {
            Write-Information ('TLC-SUPPORTRESULT:' + ($trigger.Detail | ConvertTo-Json -Compress)) -InformationAction Continue
            Write-Information ('TLC-SUPPORTSTATE:' + $(if ($trigger.Triggered) { 'Waiting' } else { 'Fallback' })) -InformationAction Continue
        }
        if (-not $trigger.Triggered) {
            Write-TlcBlocker -Check 'SupportFiles.Trigger' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                -Detail $trigger.Detail -Remediation 'Press Ctrl + Alt + Shift + 1 in Teams manually, or skip support files.' | Out-Null
            Write-Information '  ACTION REQUIRED - automation could not start the download. Press Ctrl + Alt + Shift + 1 in Teams, retry, or skip support files.' -InformationAction Continue
        }
        Write-TlcEvent -Phase 'Collect' -Step 'SupportFilesTrigger' `
            -Status $(if ($trigger.Triggered) { 'Complete' } else { 'Warning' }) `
            -Endpoint $Endpoint -Message $trigger.Detail
    }

    $findArtifacts = {
        @(foreach ($pattern in $patterns) {
            Get-ChildItem -LiteralPath $dropFolder -Filter $pattern -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $promptedAt }
        })
    }

    # What "finished" is judged by: every artifact's name, and for a folder the count, bytes
    # and newest write of everything inside it. Refreshed per file, because an enumerated
    # timestamp is stale for anything still open (finding 299).
    $snapshotOf = {
        param($items)
        $count = 0
        $totalBytes = 0L
        $newestUtc = $null
        $signature = @(foreach ($item in @($items | Sort-Object Name)) {
            if ($item.PSIsContainer) {
                $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -ErrorAction SilentlyContinue)
                foreach ($f in $files) { $f.Refresh() }
                $bytes = ($files | Measure-Object -Property Length -Sum).Sum
                $newest = if ($files.Count) { @($files | Sort-Object LastWriteTime | Select-Object -Last 1)[0].LastWriteTime.Ticks } else { 0 }
                $count += $files.Count
                $totalBytes += $bytes
                if ($files.Count) {
                    $written = @($files | Sort-Object LastWriteTimeUtc | Select-Object -Last 1)[0].LastWriteTimeUtc
                    if ($null -eq $newestUtc -or $written -gt $newestUtc) { $newestUtc = $written }
                }
                "$($item.Name)|$($files.Count)|$bytes|$newest"
            } else {
                $item.Refresh()
                $count++
                $totalBytes += $item.Length
                if ($null -eq $newestUtc -or $item.LastWriteTimeUtc -gt $newestUtc) { $newestUtc = $item.LastWriteTimeUtc }
                "$($item.Name)|$($item.Length)|$($item.LastWriteTime.Ticks)"
            }
        }) -join ';'
        [pscustomobject]@{
            Signature = $signature; Files = $count; Bytes = $totalBytes
            NewestWriteUtc = if ($null -ne $newestUtc) { $newestUtc.ToString('o') } else { $null }
        }
    }
    $copyState = @{ Copied = 0; Failed = 0; Current = '' }
    $reportProgress = {
        param([string] $Phase, $Snapshot, [double] $Quiet = 0, [int] $Missing = 0)
        if (-not $StopSignalPath) { return }
        $progress = [ordered]@{
            Phase = $Phase; Artifacts = $found.Count
            Files = if ($Snapshot) { $Snapshot.Files } else { 0 }
            Bytes = if ($Snapshot) { $Snapshot.Bytes } else { 0 }
            NewestWriteUtc = if ($Snapshot) { $Snapshot.NewestWriteUtc } else { $null }
            QuietSeconds = [int][math]::Floor($Quiet); SettleSeconds = $SettleSeconds
            IncompleteFolders = $Missing
            ArrivalRemainingSeconds = [int][math]::Max(0.0, [math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
            CopiedArtifacts = $copyState.Copied; FailedArtifacts = $copyState.Failed; CurrentArtifact = $copyState.Current
        }
        Write-Information ('TLC-SUPPORTPROGRESS:' + ($progress | ConvertTo-Json -Compress)) -InformationAction Continue
    }

    while ((Get-Date) -lt $deadline) {
        if (& $skipRequested) { $skipped = $true; break }
        $found = @(& $findArtifacts)
        if ($found.Count -gt 0) { break }
        if ($pendingAuto) {
            $pendingAuto = $false
            if ($StopSignalPath -and (Test-Path -LiteralPath "$StopSignalPath.trigger")) {
                Remove-Item -LiteralPath "$StopSignalPath.trigger" -Force -ErrorAction Stop
            }
            & $invokeTrigger
        } elseif ($StopSignalPath -and (Test-Path -LiteralPath "$StopSignalPath.trigger")) {
            Remove-Item -LiteralPath "$StopSignalPath.trigger" -Force -ErrorAction Stop
            if (-not $triggerState.Sent) { & $invokeTrigger }
        }
        $found = @(& $findArtifacts)
        if ($found.Count -gt 0) { break }
        if (& $skipRequested) { $skipped = $true; break }
        & $reportProgress 'Waiting' $null
        Start-Sleep -Seconds $PollSeconds
    }

    # The first artifact is not the whole bundle. Teams writes the Support Logs folder and the
    # web-logs zip seconds apart, and keeps writing into the folder after it appears. Measured
    # on a live call: harvesting at first sight took the folder mid-write (647 of 651 files)
    # and missed the zip, which carries the web-media logs found nowhere else. So wait until
    # the whole set has been still for SettleSeconds. Capped, so a folder that never stops
    # changing cannot hold the run forever.
    $incompleteOf = {
        param($items)
        @(foreach ($item in @($items | Where-Object { $_.PSIsContainer })) {
            $marked = $false
            foreach ($marker in $CompletionMarkers) {
                if (Test-Path -LiteralPath (Join-Path $item.FullName $marker)) { $marked = $true; break }
            }
            if (-not $marked) { $item.Name }
        })
    }

    $incomplete = @()
    if ($found.Count -gt 0) {
        if ($StopSignalPath) {
            Write-Information 'TLC-SUPPORTSTATE:Settling' -InformationAction Continue
            Write-Information ('TLC-SUPPORTRESULT:' + ('Support files detected. Waiting for all files to finish writing before copying.' | ConvertTo-Json -Compress)) -InformationAction Continue
        }
        $settleCap = (Get-Date).AddMinutes(6)
        $snapshot = & $snapshotOf $found
        $last = $snapshot.Signature
        $stableSince = Get-Date
        while ((Get-Date) -lt $settleCap) {
            $quiet = ((Get-Date) - $stableSince).TotalSeconds
            $incomplete = @(& $incompleteOf $found)
            & $reportProgress 'Settling' $snapshot $quiet $incomplete.Count
            if ($quiet -ge $SettleSeconds -and $incomplete.Count -eq 0) { break }
            if ($quiet -ge $MarkerWaitSeconds) { break }
            # Skipping mid-bundle takes what has landed; the incomplete check below says so.
            if (& $skipRequested) { $skipped = $true; break }
            Start-Sleep -Seconds $PollSeconds
            $found = @(& $findArtifacts)
            $snapshot = & $snapshotOf $found
            if ($snapshot.Signature -ne $last) { $last = $snapshot.Signature; $stableSince = Get-Date }
        }
        $incomplete = @(& $incompleteOf $found)
    }

    if ($StopSignalPath -and (Test-Path -LiteralPath "$StopSignalPath.trigger")) {
        Remove-Item -LiteralPath "$StopSignalPath.trigger" -Force -ErrorAction Stop
    }

    # Acknowledged by removing the sentinel, the same handshake the capture session uses, so the
    # window can tell a skip that was honoured from a run that is stuck. Only when there is one:
    # a skip by key press has no sentinel, and an empty -LiteralPath is a binding error that
    # -ErrorAction does not suppress.
    if ($skipped -and $StopSignalPath) { Remove-Item -LiteralPath $StopSignalPath -Force -ErrorAction SilentlyContinue }

    if ($found.Count -eq 0) {
        Write-TlcStopProgress -SignalPath $StopSignalPath -Step Support `
            -Status $(if ($skipped) { 'Skipped' } else { 'Warning' }) `
            -DetailKey $(if ($skipped) { 'StopDetailSupportSkipped' } else { 'StopDetailSupportTimeout' })
        if ($StopSignalPath) { Write-Information 'TLC-SUPPORTWAIT:End' -InformationAction Continue }
        $why = if ($skipped) { 'Skipped by the operator while waiting for them.' } else { "No new support files appeared in $dropFolder within $TimeoutMinutes minute(s)." }
        Write-TlcBlocker -Check 'SupportFiles' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail $why `
            -Remediation $(if ($skipped) { 'If support needs the media and signaling logs, press Ctrl + Alt + Shift + 1 in Teams and add the bundle from the Downloads folder to the run.' } else { 'Confirm the user triggered collection and that the banner completed.' }) | Out-Null
        Write-TlcEvent -Phase 'Collect' -Step 'SupportFiles' -Status $(if ($skipped) { 'Skipped' } else { 'Warning' }) -Severity 'Warning' -Endpoint $Endpoint `
            -Message $(if ($skipped) { 'Support files skipped by the operator.' } else { 'No support files detected in the wait window.' })
        return $null
    }

    $destination = Join-Path $EndpointPath 'SupportFiles'
    if ($StopSignalPath) { Write-Information 'TLC-SUPPORTSTATE:Copying' -InformationAction Continue }
    $null = New-Item -ItemType Directory -Path $destination -Force

    $harvested = foreach ($item in $found) {
        $copyState.Current = $item.Name
        & $reportProgress 'Copying' $snapshot 0 $incomplete.Count
        $target = Join-Path $destination $item.Name
        try {
            if ($item.PSIsContainer) {
                $copy = Invoke-TlcNativeCommand -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') `
                    -ArgumentList @($item.FullName, $target, '/E', '/COPY:DAT', '/DCOPY:T', '/R:0', '/W:0', '/NFL', '/NDL', '/NP')
                if (-not $copy.Available -or $null -eq $copy.ExitCode -or $copy.ExitCode -ge 8) {
                    throw "Support-directory copy failed (robocopy exit $($copy.ExitCode)): $($copy.Detail) $($copy.Lines -join ' ')"
                }
            } else {
                Copy-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction Stop
            }
        } catch {
            $copyState.Failed++
            & $reportProgress 'Copying' $snapshot 0 $incomplete.Count
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Verbose "$($item.Name) could not be harvested: $($_.Exception.Message)"
            Write-TlcBlocker -Check 'SupportFiles.Copy' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                -Detail "Support artifact $($item.Name) could not be copied: $($_.Exception.Message)" `
                -Remediation 'Use the original completed files in the Downloads folder, or retry collection.' | Out-Null
            continue
        }
        # Size is read from what actually landed, not from the source. Reporting the source
        # length meant a zero-byte copy was recorded in the manifest with the original file's
        # size - evidence that reads as complete and is not there at all.
        $landed = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
        $copyState.Copied++
        $copyState.Current = ''
        & $reportProgress 'Copying' $snapshot 0 $incomplete.Count
        [ordered]@{
            Name          = $item.Name
            SizeBytes     = if ($item.PSIsContainer -or -not $landed) { $null } else { $landed.Length }
            LastWriteUtc  = $item.LastWriteTime.ToUniversalTime().ToString('o')
        }
    }

    $harvested = @($harvested)
    if ($incomplete.Count -gt 0) {
        Write-TlcBlocker -Check 'SupportFiles' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail ("$($harvested.Count) support artifact(s) harvested, but Teams had not finished writing: " + ($incomplete -join ', ') +
                     " never gained its closing file ($($CompletionMarkers -join ', ')) within $MarkerWaitSeconds s of quiet.") `
            -Remediation 'Compare the folder in the drop location with the copy in SupportFiles, and copy across anything added later.' | Out-Null
    } elseif ($harvested.Count -eq $found.Count) {
        Write-TlcBlocker -Check 'SupportFiles' -Status 'Success' -Endpoint $Endpoint `
            -Detail "$($harvested.Count) support artifact(s) harvested." | Out-Null
    } else {
        Write-TlcBlocker -Check 'SupportFiles' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "$($harvested.Count) of $($found.Count) support artifact(s) copied; collection is incomplete." `
            -Remediation 'Review SupportFiles.Copy and use the original completed files in Downloads.' | Out-Null
    }
    $complete = ($incomplete.Count -eq 0 -and $harvested.Count -eq $found.Count)
    Write-TlcEvent -Phase 'Collect' -Step 'SupportFiles' -Status $(if ($complete) { 'Complete' } else { 'Warning' }) -Endpoint $Endpoint `
        -Message "$($harvested.Count) support artifact(s) harvested." -EvidencePath $destination
    Write-TlcStopProgress -SignalPath $StopSignalPath -Step Support `
        -Status $(if ($complete -and -not $skipped) { 'Complete' } else { 'Warning' }) `
        -DetailKey $(if ($complete -and -not $skipped) { 'StopDetailSupportCopied' } else { 'StopDetailSupportPartial' })
    if ($StopSignalPath) { Write-Information 'TLC-SUPPORTWAIT:End' -InformationAction Continue }

    return $harvested
}

Export-ModuleMember -Function Get-TlcLaunchEnvironmentFact, Get-TlcInterferingModuleFact, Get-TlcAppxPackage, Get-TlcLogFileStart, Select-TlcLogFileInWindow, Export-TlcLogExcerpt,
    Get-TlcLogNoiseNote, Export-TlcLogTimeline,
    Open-TlcSharedRead, Copy-TlcOpenFile, ConvertFrom-TlcLogTimestamp,
    Invoke-TlcClientLogCollection, Save-TlcRotatedClientLog, Get-TlcLogSpan, Get-TlcSpanGap, Get-TlcClientInventory, Copy-TlcClientState,
    Get-TlcCacheFootprint, Get-TlcMachineFact, Get-TlcAudioDeviceFact, Get-TlcPowerFact, Get-TlcClientUpdateHistory, Get-TlcMeetingAddinFact, Get-TlcMeetingAddinHealth, Get-TlcDeviceJoinState,
    Get-TlcWebViewCrashFact, Get-TlcTacCorrelation,
    Get-TlcEventLogEvidence, Invoke-TlcSupportFilePrompt, Get-TlcAudioProblem, Get-TlcClockFact, Get-TlcClockProblem, Select-TlcTeamsFaultEvent, Select-TlcSignInFaultEvent, Test-TlcFileHeldForWrite
