Set-StrictMode -Version Latest

<#
    The wizard.

    Two rules carried over from Epo.Ui.Wizard.psm1.

    The wizard has no second implementation of anything. It builds a command line
    and runs THAT in a child process, so the command it shows is the command it
    runs, they cannot drift, and anything done here can be repeated unattended by
    copying one line.

    Command generation is a pure function. New-TlcUiCommand takes a model and
    returns a string, so quoting and parameter selection are unit-testable without
    putting a window on screen.
#>

function ConvertTo-TlcQuotedArgument {
    <#
    .SYNOPSIS
        Renders a value as a safe single-quoted PowerShell argument.
    .DESCRIPTION
        Single quotes, with embedded quotes doubled. A case number or user name is
        operator-supplied text and the generated line is meant to be pasted into a
        shell, so it has to survive apostrophes and spaces rather than assuming they
        will not appear.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function New-TlcUiCommand {
    <#
    .SYNOPSIS
        Builds the unattended command line for the current wizard selections.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Model,
        [string] $ScriptPath = '.\TLC-Toolbox.ps1'
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    # The call operator with a quoted path, always. The toolbox's real home is under
    # "OneDrive - Microsoft", so an unquoted path breaks at the first space - and the
    # generated line is meant to be pasted into a shell and just work.
    $parts.Add("& $(ConvertTo-TlcQuotedArgument -Value $ScriptPath)")
    $parts.Add("-Stage $($Model.Stage)")
    $parts.Add("-Scenario $($Model.Scenario)")

    foreach ($name in 'CaseNumber', 'AffectedUser', 'ConsentGrantedBy', 'ClientType', 'TargetDevice', 'CorrelationId', 'ConfigPath', 'OutputRoot') {
        if ($Model.Contains($name)) {
            $value = [string]$Model[$name]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $parts.Add("-$name $(ConvertTo-TlcQuotedArgument -Value $value)")
            }
        }
    }

    # The window belongs to the retrospective fork only.
    #
    # A capture session's window IS the session: it starts when the operator presses the button
    # and ends when they press Stop, so an impact time and a +/- span on the same command line
    # would describe a second, contradictory collection. -Stage Capture does not take them.
    #
    # Suppressed HERE rather than by stripping them out of the model. The model describes what
    # the form says, and the form still has an impact time in it - the coverage tile, its detail
    # window and the run summary panel all read those fields, and removing them made every one
    # of those throw under Set-StrictMode. What differs between the forks is the command, so the
    # command builder is where the difference belongs.
    $retrospective = [string]$Model.Stage -ne 'Capture'

    if ($retrospective -and $Model.Contains('ImpactTime') -and $Model.ImpactTime -is [datetime]) {
        $parts.Add("-ImpactTime $(ConvertTo-TlcQuotedArgument -Value $Model.ImpactTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))")
    }

    foreach ($name in 'WindowBeforeMinutes', 'WindowAfterMinutes') {
        if ($retrospective -and $Model.Contains($name) -and $null -ne $Model[$name]) {
            $parts.Add("-$name $([int]$Model[$name])")
        }
    }

    foreach ($name in 'PromptTimeoutMinutes', 'CaptureIntervalSeconds', 'CaptureMaxMinutes') {
        if ($Model.Contains($name) -and $null -ne $Model[$name]) {
            $parts.Add("-$name $([int]$Model[$name])")
        }
    }

    # The stop sentinel's path. Quoted like every other path, because the run folder lives
    # under "OneDrive - Microsoft" by default and an unquoted path breaks at the first space.
    if ($Model.Contains('CaptureStopSignalPath')) {
        $signal = [string]$Model['CaptureStopSignalPath']
        if (-not [string]::IsNullOrWhiteSpace($signal)) {
            $parts.Add("-CaptureStopSignalPath $(ConvertTo-TlcQuotedArgument -Value $signal)")
        }
    }

    # DeepCapture is set by the model only on the live fork, from the packet-capture tick. It
    # was left out of this list, so the tick changed nothing: the command in the box, which is
    # the one that runs, never asked for the capture (review 2026-09-30, finding 331).
    foreach ($name in 'SkipPrompted', 'ValidationOnly', 'DeepCapture') {
        if ($Model.Contains($name) -and $Model[$name]) {
            $parts.Add("-$name")
        }
    }

    # The only list-valued parameter. Each name is quoted separately and joined with commas,
    # which is what PowerShell's own array binding expects - "-FleetEndpoint 'A','B'". Passing
    # the joined string as one argument would bind a single endpoint literally named "A,B", and
    # the run would report one unreachable machine with a comma in its name.
    #
    # The parameter is FleetEndpoint, not Endpoint: the entry point already uses $endpoint as a
    # local for the machine being collected from, and PowerShell variable names are
    # case-insensitive, so the two would be one variable.
    #
    # Last, because it is the parameter most likely to be long, and the standing rule is that
    # this line is exactly what runs - so it has to stay readable enough to be checked before
    # it is pasted.
    if ($Model.Contains('Endpoint')) {
        $endpoints = @($Model['Endpoint'] | Where-Object { $_ })
        if ($endpoints.Count -gt 0) {
            $quoted = @($endpoints | ForEach-Object { ConvertTo-TlcQuotedArgument -Value ([string]$_) })
            $parts.Add("-FleetEndpoint $($quoted -join ',')")
        }
    }

    return ($parts -join ' ')
}

function New-TlcUiRunnerScript {
    <#
    .SYNOPSIS
        The lines of the script the wizard runs in a child process: the equivalent command,
        with its run object turned into the exit code.
    .DESCRIPTION
        TLC-Toolbox.ps1 exits 2 for a Blocked run only when it is the top-level script, so
        that a caller - a test, another script - still receives the run object (finding 290).
        The wizard's child process runs THIS script, which calls the entry point, so the entry
        point returned instead of exiting and the child exited 0. A package the privacy gate
        refused therefore read as "Finished." in the wizard and was added to the session
        zip as its raw, unsealed run folder (review 2026-09-30, finding 331).

        The run object is kept rather than printed: at a prompt it is useful, here it would
        print a two-column dump of run metadata under every result.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $Command)

    return @(
        '$InformationPreference = ''Continue'''
        "`$tlcResult = @($Command)"
        '$tlcLast = $tlcResult | Select-Object -Last 1'
        '$tlcStatus = if ($tlcLast -is [System.Collections.IDictionary]) { if ($tlcLast.Contains(''Status'')) { [string]$tlcLast[''Status''] } } elseif ($null -ne $tlcLast -and $tlcLast.PSObject.Properties[''Status'']) { [string]$tlcLast.Status }'
        'if ($tlcStatus -eq ''Blocked'') { exit 2 }'
    )
}

function ConvertTo-TlcWindowTranscript {
    <#
    .SYNOPSIS
        A run's output as the window shows it, with what a refused Package says in the
        window's language.
    .DESCRIPTION
        The run prints English, and its output stays the run's own record. The exception is a
        refused Package: why each endpoint was refused, what to do about it, and the closing
        instruction, which names buttons. Every one of those lines comes from
        Get-TlcPackageRefusalText, so each is recognised by its English and shown as the entry
        for its key, worded for the window, with the controls it names filled in from the
        same table. Finding 338.

        A reason carries values - a count, the masked ids, the files - so its English is a
        template, and the line is matched against it whole, with the values read back out and
        put into the window's wording unchanged. Each kind of line is looked for only behind
        the prefix the run prints it with: "- " for a reason, "To fix: " for a fix, nothing for
        the rest. A partial or unprefixed match is left alone, because a translated sentence
        beside English it no longer describes is worse than English. A table without the key
        leaves the line as the run wrote it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Text,
        [Parameter(Mandatory)] [hashtable] $Table
    )

    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }

    # The controls each line names, filled in from the table after the values the line
    # carries, so the sentence says each one exactly as it is labelled in this language.
    $controlLabel = @{
        PackageFixAccounts   = @('TileSignIn', 'DeclareButton')
        PackageFixConsent    = @('ConsentLabel')
        PackageFixClosing    = @('PackageButton')
        PackageReasonConsent = @('ConsentLabel')
    }

    $entries = @(foreach ($entry in (Get-TlcPackageRefusalText).Values) {
        $key = [string]$entry.Key
        if (-not $key) { continue }
        $english = [string]$entry.English
        $pattern = (@([regex]::Split($english, '(\{\d+\})') | ForEach-Object {
            if ($_ -match '^\{\d+\}$') { '(.+?)' } else { [regex]::Escape($_) }
        }) -join '')
        $prefix = if ($key -like 'PackageReason*') { '- ' } elseif ($key -like 'PackageFix*' -and $key -ne 'PackageFixClosing') { 'To fix: ' } else { '' }
        [pscustomobject]@{
            Key    = $key
            Prefix = $prefix
            Match  = [regex]::new('^' + $pattern + '$')
            Order  = @([regex]::Matches($english, '\{(\d+)\}') | ForEach-Object { [int]$_.Groups[1].Value })
        }
    })

    # Split with the separators kept, so every line ending comes back exactly as it was.
    $pieces = [regex]::Split($Text, '(\r?\n)')
    for ($i = 0; $i -lt $pieces.Count; $i += 2) {
        $line = [regex]::Match($pieces[$i], '^(\s*)(To fix: |- )?(.*?)\s*$')
        $prefix = $line.Groups[2].Value
        $body = $line.Groups[3].Value
        foreach ($entry in $entries) {
            if ($entry.Prefix -ne $prefix -or -not $Table.ContainsKey($entry.Key)) { continue }
            $found = $entry.Match.Match($body)
            if (-not $found.Success) { continue }

            $values = [object[]]::new($(if (@($entry.Order).Count) { (@($entry.Order) | Measure-Object -Maximum).Maximum + 1 } else { 0 }))
            for ($g = 1; $g -lt $found.Groups.Count; $g++) { $values[$entry.Order[$g - 1]] = $found.Groups[$g].Value }
            if ($controlLabel.ContainsKey($entry.Key)) {
                $values = @($values) + @($controlLabel[$entry.Key] | ForEach-Object { Get-TlcString -Table $Table -Key $_ })
            }
            $said = if (@($values).Count) { Get-TlcString -Table $Table -Key $entry.Key -Argument $values } else { Get-TlcString -Table $Table -Key $entry.Key }
            if ($prefix -eq 'To fix: ') { $said = "$(Get-TlcString -Table $Table -Key 'TranscriptToFix') $said" }
            elseif ($prefix) { $said = $prefix + $said }
            $pieces[$i] = $line.Groups[1].Value + $said
            break
        }
    }
    return ($pieces -join '')
}
function Add-TlcRunOutput {
    <#
    .SYNOPSIS
        What a run's newest output adds to the log box, and what it told the window.
    .DESCRIPTION
        Output is read every 200 ms in whatever pieces the child has flushed, so a line can
        arrive in two. Everything done to it on the way to the screen needs the whole line:
        the window's markers (TLC-PHASE, TLC-SAMPLES) are read and taken out, and the lines
        that say what to do are said in the window's language. So an unfinished last line is
        held back as Pending and read with the rest of it on the next call, and -Final, once
        the run has exited, lets it through as it is. The run writes no output without a
        line ending, so a held line waits one read at most.

        Phase is the newest marker in the output. It used to be the first: a short trace
        whose Reproduce and Collect markers arrived in one read was left showing Reproduce.
        Samples is the newest count. Neither is in Text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Pending,
        [AllowEmptyString()] [AllowNull()] [string] $New,
        [Parameter(Mandatory)] [hashtable] $Table,
        [switch] $Final
    )

    $text = [string]$Pending + [string]$New
    $cut = $text.LastIndexOf("`n")
    if ($Final) {
        $whole = $text; $rest = ''
    } elseif ($cut -ge 0) {
        $whole = $text.Substring(0, $cut + 1); $rest = $text.Substring($cut + 1)
    } else {
        $whole = ''; $rest = $text
    }

    $phase = $null
    $phases = [regex]::Matches($whole, 'TLC-PHASE:(\w+)')
    if ($phases.Count -gt 0) { $phase = $phases[$phases.Count - 1].Groups[1].Value }
    $samples = $null
    $counts = [regex]::Matches($whole, 'TLC-SAMPLES:(\d+)')
    if ($counts.Count -gt 0) { $samples = [int]$counts[$counts.Count - 1].Groups[1].Value }
    $supportWaiting = $null
    $waits = [regex]::Matches($whole, 'TLC-SUPPORTWAIT:(Start|End)')
    if ($waits.Count -gt 0) { $supportWaiting = $waits[$waits.Count - 1].Groups[1].Value -eq 'Start' }
    $metrics = @([regex]::Matches($whole, '(?m)^TLC-METRIC:([^\r\n]+)') | ForEach-Object {
        $_.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
    })
    $supportResult = $null
    $results = [regex]::Matches($whole, '(?m)^TLC-SUPPORTRESULT:([^\r\n]+)')
    if ($results.Count) { $supportResult = $results[$results.Count - 1].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop }
    $supportState = $null
    $states = [regex]::Matches($whole, 'TLC-SUPPORTSTATE:(Generating|Waiting|Settling|Fallback|Copying)')
    if ($states.Count) { $supportState = $states[$states.Count - 1].Groups[1].Value }
    $stopSteps = @([regex]::Matches($whole, '(?m)^TLC-STOPSTEP:([^\r\n]+)') | ForEach-Object {
        $_.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
    })
    $supportProgress = $null
    $progress = [regex]::Matches($whole, '(?m)^TLC-SUPPORTPROGRESS:([^\r\n]+)')
    if ($progress.Count) { $supportProgress = $progress[$progress.Count - 1].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop }

    # Marker lines go with their line ending, so taking one out leaves no blank line behind.
    $shown = [regex]::Replace($whole, '(?m)^[^\r\n]*TLC-(PHASE|SAMPLES|SUPPORTWAIT|METRIC|SUPPORTRESULT|SUPPORTSTATE|STOPSTEP|SUPPORTPROGRESS):[^\r\n]*(\r?\n|$)', '')
    $shown = ConvertTo-TlcWindowTranscript -Text $shown -Table $Table

    $lines = @($shown -split '\r?\n' | Where-Object { $_.Trim() })
    return [pscustomobject]@{
        Text     = $shown
        Pending  = $rest
        Phase    = $phase
        Samples  = $samples
        SupportWaiting = $supportWaiting
        Metrics = $metrics
        SupportResult = $supportResult
        SupportState = $supportState
        StopSteps = $stopSteps
        SupportProgress = $supportProgress
        LastLine = $(if ($lines.Count) { $lines[-1].Trim() } else { '' })
    }
}
function Update-TlcTranscriptView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.RichTextBox] $View,
        [AllowEmptyString()] [string] $Text = '',
        [hashtable] $Strings
    )

    $previous = if ($View.Tag -is [string]) { [string]$View.Tag } else { '' }
    $append = $View.Document.Blocks.Count -gt 0 -and $Text.StartsWith($previous, [StringComparison]::Ordinal)
    $tail = $Text
    $accent = $View.FindResource('AccentBrush')
    $warning = $View.FindResource('WarningBrush')
    $controls = @('Stop run', 'Start trace')
    if ($Strings) {
        foreach ($key in 'CancelButton', 'StartTraceButton') {
            if ($Strings.ContainsKey($key)) { $controls += [string]$Strings[$key] }
        }
    }
    $pattern = '(?i)(^\s*(?:Scenario|Stage|Run path)\s*:|(?<!\S)-[A-Za-z][A-Za-z0-9]*\b|\bNot available\b|\badministrator\b|\bReproduce the problem now\b|' +
        (($controls | Sort-Object -Unique | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'

    $View.BeginChange()
    try {
        if ($append) {
            # Replace only the final partial/empty paragraph when more text arrives.
            $cut = $previous.LastIndexOf("`n") + 1
            $tail = $Text.Substring($cut)
            $View.Document.Blocks.Remove($View.Document.Blocks.LastBlock)
        } else {
            $View.Document.Blocks.Clear()
        }
        foreach ($line in @($tail -split '\r?\n')) {
            $paragraph = New-Object System.Windows.Documents.Paragraph
            $paragraph.Margin = [System.Windows.Thickness]::new(0)
            $paragraph.LineHeight = 18
            $heading = $line -match '^\s*(Running:|TLC-Toolbox run\b|Live capture\b|Auto lane\b|Prompted lane\b|ACTION REQUIRED\b|Deeper captures not running\b)'
            if ($heading) {
                $paragraph.FontWeight = 'SemiBold'
                $paragraph.Foreground = if ($line -match 'ACTION REQUIRED|not running') { $warning } else { $accent }
            }
            $offset = 0
            foreach ($match in [regex]::Matches($line, $pattern)) {
                if ($match.Index -gt $offset) {
                    $paragraph.Inlines.Add([System.Windows.Documents.Run]::new($line.Substring($offset, $match.Index - $offset)))
                }
                $run = [System.Windows.Documents.Run]::new($match.Value)
                $run.FontWeight = 'SemiBold'
                $run.Foreground = if ($match.Value -match '(?i)Not available|administrator') { $warning } else { $accent }
                $paragraph.Inlines.Add($run)
                $offset = $match.Index + $match.Length
            }
            if ($offset -lt $line.Length) { $paragraph.Inlines.Add([System.Windows.Documents.Run]::new($line.Substring($offset))) }
            $View.Document.Blocks.Add($paragraph)
        }
        $View.Tag = $Text
    } finally {
        $View.EndChange()
    }
    $View.ScrollToEnd()
}

function Get-TlcCaptureMetricBand {
    [CmdletBinding()]
    param(
        [ValidateSet('Rtt', 'Memory')] [string] $Name,
        [Parameter(Mandatory)] [psobject] $Sample
    )

    if ($Name -eq 'Rtt') {
        if ($null -eq $Sample.Rtt) { return 'Neutral' }
        if ([double]::IsNaN($Sample.Rtt) -or [double]::IsInfinity($Sample.Rtt) -or $Sample.Rtt -lt 0) {
            throw 'The live RTT metric is invalid.'
        }
        if ($Sample.Rtt -gt 500) { return 'Blocked' }
        if ($Sample.Rtt -ge 200) { return 'Warning' }
        return 'Pass'
    }
    $total = $Sample.PSObject.Properties['TotalRamMb']
    $available = $Sample.PSObject.Properties['AvailableRamMb']
    if (-not $total -or -not $available -or $null -eq $total.Value -or $null -eq $available.Value) {
        return 'Neutral'
    }
    if ($total.Value -le 0 -or $available.Value -lt 0 -or $available.Value -gt $total.Value -or
        [double]::IsNaN($total.Value) -or [double]::IsInfinity($total.Value) -or
        [double]::IsNaN($available.Value) -or [double]::IsInfinity($available.Value)) {
        throw 'The live physical memory metrics are invalid.'
    }
    $percent = 100 * [double]$available.Value / [double]$total.Value
    # Critical takes precedence; the 4 GB healthy exception applies only outside that band.
    if ($percent -lt 1 -or $available.Value -lt 500) { return 'Blocked' }
    if ($percent -lt 10 -and $available.Value -lt 4096) { return 'Warning' }
    return 'Pass'
}

function Set-TlcCaptureMemoryContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Windows.Controls.TextBlock] $Context,
        [Parameter(Mandatory)] [hashtable] $Strings,
        [AllowNull()] [psobject] $Sample,
        [switch] $Loading,
        [switch] $Preview
    )

    $Context.Tag = @{ Strings = $Strings; Sample = $Sample; Loading = [bool]$Loading; Preview = [bool]$Preview }
    $Context.Foreground = $Context.FindResource('TextSecondaryBrush')
    if ($null -ne $Sample -and $Sample.PSObject.Properties['TotalRamMb'] -and $null -ne $Sample.TotalRamMb -and
        $Sample.PSObject.Properties['AvailableRamMb'] -and $null -ne $Sample.AvailableRamMb) {
        $null = Get-TlcCaptureMetricBand -Name Memory -Sample $Sample -ErrorAction Stop
        $Context.Text = Get-TlcString -Table $Strings -Key 'LiveMemoryContext' -Argument @(
            ('{0:0.0}' -f ($Sample.TotalRamMb / 1024)), ('{0:0.0}' -f ($Sample.AvailableRamMb / 1024)),
            ('{0:0.0}' -f (100 * ($Sample.TotalRamMb - $Sample.AvailableRamMb) / $Sample.TotalRamMb)))
        if ($Preview) { $Context.Text += ' | ' + (Get-TlcString -Table $Strings -Key 'LiveMemoryPreview') }
    } elseif ($null -ne $Sample -and $Sample.PSObject.Properties['RamError'] -and $Sample.RamError) {
        $Context.Text = Get-TlcString -Table $Strings -Key 'LiveMemoryReadFailed' -Argument @($Sample.RamError)
        $Context.Foreground = $Context.FindResource('WarningBrush')
    } elseif ($Loading) {
        $Context.Text = Get-TlcString -Table $Strings -Key 'LiveMemoryLoading'
    } else {
        $Context.Text = Get-TlcString -Table $Strings -Key 'LiveMemoryUnavailable'
    }
}

function Initialize-TlcCaptureReading {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Element)

    $preview = [pscustomobject]@{ TotalRamMb = $null; AvailableRamMb = $null; RamError = $null }
    try {
        $ram = Get-TlcSystemMemory -ErrorAction Stop
        $preview.TotalRamMb = $ram.TotalMb
        $preview.AvailableRamMb = $ram.AvailableMb
    } catch {
        $preview.RamError = $_.Exception.Message
        Write-TlcToolLog -Message 'Initial physical RAM reading failed.' -Level 'WARN' -ErrorRecord $_
    }
    Update-TlcCaptureChart -Element $Element -Samples @() -Loading -MemoryPreview $preview -ErrorAction Stop
    return $preview
}

function Update-TlcStopProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [object[]] $Records = @(),
        [AllowNull()] [psobject] $SupportProgress,
        [ValidateSet('Running', 'Complete', 'Warning', 'Failed')] [string] $Outcome = 'Running',
        [datetime] $Now = (Get-Date)
    )

    if (-not $State.Contains('RunFork') -or $State.RunFork -ne 'Capture' -or
        ($State.Contains('RunValidationOnly') -and $State.RunValidationOnly)) {
        $Element.StopProgressPanel.Visibility = 'Collapsed'
        return
    }
    if (-not $State.Contains('StopSteps')) {
        $State.StopSteps = @{ Sampling = 'Pending'; Logs = 'Pending'; Support = 'Pending'; Finalize = 'Pending' }
        $State.StopDetailKey = ''; $State.StopStartedAt = $null; $State.StopLastUpdateAt = $null; $State.SupportProgress = $null
    }
    if ($PSBoundParameters.ContainsKey('Outcome') -or -not $State.Contains('StopOutcome')) {
        $State.StopOutcome = $Outcome
    } else {
        $Outcome = $State.StopOutcome
    }
    foreach ($record in $Records) {
        if ($record.Step -notin 'Sampling', 'Logs', 'Support', 'Finalize' -or
            $record.Status -notin 'Running', 'Complete', 'Skipped', 'Warning' -or
            -not $State.Strings.ContainsKey([string]$record.DetailKey)) {
            throw 'The collector reported an invalid stopping step.'
        }
        $State.StopSteps[$record.Step] = [string]$record.Status
        $State.StopDetailKey = [string]$record.DetailKey
        $State.StopLastUpdateAt = $Now
    }
    if ($null -ne $SupportProgress) {
        $State.SupportProgress = $SupportProgress
        $State.StopLastUpdateAt = $Now
    }
    $active = ($State.Contains('RunStopRequested') -and $State.RunStopRequested) -or
        ($State.Contains('CapturePhase') -and $State.CapturePhase -in 'Collect', 'Finished') -or @($Records).Count -gt 0
    if (-not $active) { $Element.StopProgressPanel.Visibility = 'Collapsed'; return }
    if ($null -eq $State.StopStartedAt) { $State.StopStartedAt = $Now }
    if ($State.StopSteps.Sampling -eq 'Pending') { $State.StopSteps.Sampling = 'Running' }
    if ($State.CapturePhase -eq 'Collect' -and $State.StopSteps.Sampling -eq 'Running' -and
        $State.StopDetailKey -ne 'StopDetailDeep') { $State.StopSteps.Sampling = 'Complete' }
    if ($Outcome -eq 'Failed') {
        foreach ($step in @('Sampling', 'Logs', 'Support', 'Finalize')) {
            if ($State.StopSteps[$step] -eq 'Running') { $State.StopSteps[$step] = 'Failed' }
        }
    }
    $review = $Outcome -in 'Warning', 'Failed' -or @($State.StopSteps.Values | Where-Object { $_ -in 'Warning', 'Skipped', 'Failed' }).Count -gt 0
    $titleKey = if ($Outcome -eq 'Running') { 'StopFlowHeading' }
        elseif ($review) { 'StopFlowReview' } else { 'StopFlowFinished' }
    $Element.StopProgressTitle.Text = Get-TlcString -Table $State.Strings -Key $titleKey
    $Element.StopProgressTitle.Foreground = $Element.StopProgressTitle.FindResource(
        $(if ($Outcome -eq 'Failed') { 'BlockedBrush' } elseif ($review) { 'WarningBrush' } elseif ($Outcome -eq 'Complete') { 'PassBrush' } else { 'AccentBrush' }))
    $brushes = @{ Pending = 'TextSecondaryBrush'; Running = 'AccentBrush'; Complete = 'PassBrush'; Skipped = 'NeutralBrush'; Warning = 'WarningBrush'; Failed = 'BlockedBrush' }
    $stepKeys = @{ Sampling = 'StopStepSampling'; Logs = 'StopStepLogs'; Support = 'StopStepSupport'; Finalize = 'StopStepFinalize' }
    $statusKeys = @{ Pending = 'StopStatusPending'; Running = 'StopStatusRunning'; Complete = 'StopStatusComplete'; Skipped = 'StopStatusSkipped'; Warning = 'StopStatusWarning'; Failed = 'StopStatusFailed' }
    foreach ($step in 'Sampling', 'Logs', 'Support', 'Finalize') {
        $status = $State.StopSteps[$step]
        $control = $Element["Stop${step}Text"]
        $control.Text = (Get-TlcString -Table $State.Strings -Key $stepKeys[$step]) + ' - ' +
            (Get-TlcString -Table $State.Strings -Key $statusKeys[$status])
        $control.Foreground = $control.FindResource($brushes[$status])
        $control.FontWeight = if ($status -in 'Running', 'Warning', 'Failed') { 'SemiBold' } else { 'Normal' }
    }
    $Element.StopProgressDetail.Text = Get-TlcString -Table $State.Strings `
        -Key $(if ($State.StopDetailKey) { $State.StopDetailKey } else { 'StopDetailAcknowledging' })
    $Element.StopProgressDetail.Foreground = $Element.StopProgressDetail.FindResource('TextSecondaryBrush')
    $Element.StopProgressActivity.Text = if ($null -ne $State.StopLastUpdateAt) {
        Get-TlcString -Table $State.Strings -Key 'StopLastUpdate' -Argument @([int][math]::Max(0.0, ($Now - $State.StopLastUpdateAt).TotalSeconds))
    } else { Get-TlcString -Table $State.Strings -Key 'StopAwaitingUpdate' }
    if ($null -ne $State.SupportProgress -and $State.Contains('SupportWaitingSince') -and $State.SupportWaitingSince) {
        $progress = $State.SupportProgress
        $facts = Get-TlcString -Table $State.Strings -Key 'StopSupportFacts' -Argument @(
            $progress.Artifacts, $progress.Files, ('{0:0.0}' -f ($progress.Bytes / 1MB)))
        $detail = switch ($progress.Phase) {
            'Waiting' { Get-TlcString -Table $State.Strings -Key 'StopSupportArrival' -Argument @($progress.ArrivalRemainingSeconds) }
            'Settling' {
                $quiet = Get-TlcString -Table $State.Strings -Key 'StopSupportQuiet' -Argument @($progress.QuietSeconds, $progress.SettleSeconds)
                if ($progress.IncompleteFolders -gt 0) {
                    $quiet += ' | ' + (Get-TlcString -Table $State.Strings -Key 'StopSupportMarkers' -Argument @($progress.IncompleteFolders))
                }
                $quiet
            }
            'Copying' {
                $copied = Get-TlcString -Table $State.Strings -Key 'StopSupportCopied' -Argument @($progress.CopiedArtifacts, $progress.Artifacts, $progress.FailedArtifacts)
                if ($progress.CurrentArtifact) { $copied += ' | ' + $progress.CurrentArtifact }
                $copied
            }
            default { throw 'The collector reported an invalid support progress phase.' }
        }
        $Element.SupportResultText.Text = "$facts`n$detail"
        if ($progress.NewestWriteUtc) {
            $age = [int][math]::Max(0.0, ($Now.ToUniversalTime() - ([datetimeoffset]::Parse($progress.NewestWriteUtc)).UtcDateTime).TotalSeconds)
            $Element.SupportResultText.Text += ' | ' + (Get-TlcString -Table $State.Strings -Key 'StopSupportLastWrite' -Argument @($age))
        }
    }
    $Element.StopProgressPanel.Visibility = 'Visible'
}

function Update-TlcRunLoading {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [switch] $Running,
        [datetime] $Now = (Get-Date)
    )

    $key = ''
    $age = $null
    $rotation = $Element.RunLoadingSpinner.RenderTransform
    if ($Running) {
        $phase = if ($State.Contains('CapturePhase')) { [string]$State.CapturePhase } else { '' }
        if ($State.Contains('SupportWaitingSince') -and $State.SupportWaitingSince) {
            $key = switch ([string]$State.SupportPhase) {
                'Generating' { 'WaitSupportGenerating' }
                'Waiting'    { 'WaitSupportWaiting' }
                'Settling'   { 'WaitSupportSettling' }
                'Copying'    { 'WaitSupportCopying' }
                'Fallback'   { 'WaitSupportAction' }
                default      { 'WaitSupportWaiting' }
            }
        } elseif ($State.Contains('RunStopRequested') -and $State.RunStopRequested -and $phase -ne 'Collect') {
            $key = 'WaitStopping'
        } elseif ($phase -eq 'Collect') {
            $key = 'WaitCollecting'
        } elseif ($phase -eq 'Arm') {
            $key = 'WaitArming'
        } elseif ($phase -eq 'Reproduce') {
            $samples = @($State.LiveSamples)
            if (-not $samples.Count) {
                $key = 'WaitFirstSample'
            } else {
                $age = [math]::Max(0.0, ($Now.ToUniversalTime() - ([datetimeoffset]::Parse($samples[-1].TimestampUtc)).UtcDateTime).TotalSeconds)
                if ($age -ge [math]::Max(10, 2 * $State.LiveChartIntervalSeconds)) { $key = 'WaitNextSample' }
            }
        } elseif ($State.Contains('RunWorkStage') -and $State.RunWorkStage -eq 'Package') {
            $key = 'WaitPackaging'
        } else {
            $key = 'WaitWorking'
        }
    }
    if (-not $key) {
        $Element.RunLoadingPanel.Visibility = 'Collapsed'
        if (-not $rotation.IsFrozen) { $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null) }
        $Element.RunLoadingText.Text = ''
        $State.RunWaitKey = ''
        $State.RunWaitSince = $null
        return
    }
    if (-not $State.Contains('RunWaitKey') -or $State.RunWaitKey -ne $key) {
        $State.RunWaitKey = $key
        $State.RunWaitSince = $Now
    }
    $seconds = if ($key -eq 'WaitNextSample') { [int]$age }
        else { [int][math]::Max(0.0, ($Now - $State.RunWaitSince).TotalSeconds) }
    $Element.RunLoadingText.Text = Get-TlcString -Table $State.Strings -Key $key -Argument @($seconds)
    $Element.RunLoadingSpinner.Visibility = if ($key -eq 'WaitSupportAction') { 'Collapsed' } else { 'Visible' }
    if ($key -eq 'WaitSupportAction') {
        if (-not $rotation.IsFrozen) { $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null) }
    } else {
        if ($rotation.IsFrozen) {
            $rotation = $rotation.Clone()
            $Element.RunLoadingSpinner.RenderTransform = $rotation
        }
        if (-not $rotation.HasAnimatedProperties) {
            $spin = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 360, [System.Windows.Duration]::new([timespan]::FromSeconds(1)))
            $spin.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $rotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin)
        }
    }
    $Element.RunLoadingText.Foreground = $Element.RunLoadingText.FindResource(
        $(if ($key -eq 'WaitSupportAction') { 'WarningBrush' } else { 'TextSecondaryBrush' }))
    $Element.RunLoadingPanel.Visibility = 'Visible'
    Update-TlcStopProgress -Element $Element -State $State -Now $Now
}

function Update-TlcCaptureChart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Samples,
        [switch] $Animate,
        [ValidateRange(1, 3600)] [int] $IntervalSeconds = 5,
        [string] $StartedUtc = '',
        [System.Collections.IDictionary] $Centers,
        [switch] $Loading,
        [AllowNull()] [psobject] $MemoryPreview
    )

    $recent = @($Samples | Select-Object -Last 120)
    $windowSeconds = 119 * $IntervalSeconds
    $started = if ($StartedUtc) { [datetimeoffset]::Parse($StartedUtc) }
        elseif ($recent.Count) { [datetimeoffset]::Parse($recent[0].TimestampUtc) }
        else { $null }
    $windowStart = $started
    if ($recent.Count) {
        $latest = [datetimeoffset]::Parse($recent[-1].TimestampUtc)
        if (($latest - $started).TotalSeconds -gt $windowSeconds) {
            $windowStart = $latest.AddSeconds(-$windowSeconds)
        }
    }
    $elapsedStart = if ($null -ne $started) { ($windowStart - $started).TotalSeconds } else { 0 }
    foreach ($name in 'Rtt', 'Memory') {
        $path = $Element["Live${name}Path"]
        $value = $Element["Live${name}Value"]
        $unit = if ($name -eq 'Rtt') { 'ms' } else { 'MB' }
        $geometry = New-Object System.Windows.Media.GeometryGroup
        $segments = @{}
        $bands = [System.Collections.Generic.List[object]]::new()
        $brushes = @{}
        foreach ($band in 'Pass', 'Warning', 'Blocked', 'Neutral') {
            $resource = if ($name -eq 'Memory' -and $band -eq 'Neutral') { 'TeamsGraphBrush' } else { "${band}Brush" }
            $brushes[$band] = $path.FindResource($resource)
        }
        $old = $path.Tag
        $duration = $null
        if ($Animate -and $old -and $recent.Count -gt 1) {
            $interval = ([datetimeoffset]::Parse($recent[-1].TimestampUtc) - [datetimeoffset]::Parse($recent[-2].TimestampUtc)).TotalSeconds
            if ($interval -gt 0) {
                $duration = [System.Windows.Duration]::new([timespan]::FromSeconds([math]::Min(10, $interval)))
            }
        }
        $values = @($recent | Where-Object { $null -ne $_.$name } | ForEach-Object { [double]$_.$name })
        $center = if ($Centers -and $Centers.Contains($name) -and $null -ne $Centers[$name]) {
            [double]$Centers[$name]
        } elseif ($old -and $old.ContainsKey('Center') -and $null -ne $old.Center) {
            [double]$old.Center
        } elseif ($values.Count) { $values[0] } else { $null }
        if ($Centers -and $null -ne $center) { $Centers[$name] = $center }
        $floor = if ($null -ne $center -and $center -eq 0) { -1 } else { 0 }
        $ceiling = if ($null -ne $center -and $center -gt 0) { 2 * $center } else { 1 }
        if ($values.Count) {
            $maximum = ($values | Measure-Object -Maximum).Maximum
            if ($maximum -gt $ceiling) { $ceiling = [math]::Ceiling($maximum) }
        }
        $lastValue = if ($recent.Count -and $null -ne $recent[-1].$name) { '{0:0.0}' -f $recent[-1].$name } else { '?' }
        $value.Text = if ($Loading -and -not $recent.Count) {
            Get-TlcString -Table $Element.LiveMemoryContext.Tag.Strings -Key 'LiveMetricLoading'
        } else { "$lastValue $unit" }
        $Element["Live${name}Maximum"].Text = '{0:0.#}' -f $ceiling
        $Element["Live${name}Middle"].Text = '{0:0.#}' -f (($ceiling + $floor) / 2)
        $Element["Live${name}Minimum"].Text = '{0:0.#}' -f $floor
        foreach ($tick in @(
            @{ Name = 'Start'; Seconds = $elapsedStart }
            @{ Name = 'Middle'; Seconds = $elapsedStart + $windowSeconds / 2 }
            @{ Name = 'End'; Seconds = $elapsedStart + $windowSeconds }
        )) {
            $format = if ($tick.Seconds -ge 3600) { 'hh\:mm\:ss' } else { 'mm\:ss' }
            $Element["Live${name}Time$($tick.Name)"].Text = [timespan]::FromSeconds($tick.Seconds).ToString($format)
        }
        $previous = $null
        if ($recent.Count) {
            $previousStamp = ''
            foreach ($sample in $recent) {
                $timestamp = [datetimeoffset]::Parse($sample.TimestampUtc)
                if ($timestamp -lt $windowStart) { $previous = $null; continue }
                if ($null -eq $sample.$name) { $previous = $null; continue }
                $x = 300 * (($timestamp - $windowStart).TotalSeconds / $windowSeconds)
                $point = [System.Windows.Point]::new($x, 100 - (100 * ([double]$sample.$name - $floor) / ($ceiling - $floor)))
                $band = Get-TlcCaptureMetricBand -Name $name -Sample $sample -ErrorAction Stop
                $entry = @{
                    Offset = [math]::Max(0.0, [math]::Min(1.0, $(if ($null -ne $previous) { $previous.X / 300 } else { $x / 300 })))
                    Color = $brushes[$band].Color
                    FromOffset = $null
                }
                $bands.Add($entry)
                if ($null -ne $previous) {
                    $line = [System.Windows.Media.LineGeometry]::new($previous, $point)
                    $key = "$previousStamp|$($sample.TimestampUtc)"
                    $segments[$key] = $line
                    if ($null -ne $duration) {
                        $fromStart = $null
                        $fromEnd = $null
                        if ($old.Segments.ContainsKey($key)) {
                            $fromStart = $old.Segments[$key].StartPoint
                            $fromEnd = $old.Segments[$key].EndPoint
                        } elseif ($previousStamp -eq $old.LastTimestamp -and $null -ne $old.LastPoint) {
                            $fromStart = $old.LastPoint
                            $fromEnd = $old.LastPoint
                        }
                        if ($null -ne $fromStart) {
                            $entry.FromOffset = [math]::Max(0.0, [math]::Min(1.0, $fromStart.X / 300))
                            $startAnimation = [System.Windows.Media.Animation.PointAnimation]::new($fromStart, $previous, $duration)
                            $endAnimation = [System.Windows.Media.Animation.PointAnimation]::new($fromEnd, $point, $duration)
                            $startAnimation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                            $endAnimation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                            $line.BeginAnimation([System.Windows.Media.LineGeometry]::StartPointProperty, $startAnimation)
                            $line.BeginAnimation([System.Windows.Media.LineGeometry]::EndPointProperty, $endAnimation)
                        }
                    }
                    $geometry.Children.Add($line)
                }
                $previous = $point
                $previousStamp = [string]$sample.TimestampUtc
            }
        }
        if ($geometry.Children.Count -eq 0 -and $null -ne $previous) {
            $geometry.Children.Add([System.Windows.Media.EllipseGeometry]::new($previous, 1.5, 1.5))
        }
        $currentBand = if ($recent.Count -and $null -ne $recent[-1].$name) {
            Get-TlcCaptureMetricBand -Name $name -Sample $recent[-1] -ErrorAction Stop
        } else { 'Neutral' }
        $currentBrush = $brushes[$currentBand]
        $Element["Live${name}Key"].Fill = $currentBrush
        $value.Foreground = $currentBrush
        $stroke = $currentBrush
        if ($bands.Count -gt 1) {
            # Hard stops retain historical bands; an interval uses its newer saved reading.
            $stroke = [System.Windows.Media.LinearGradientBrush]::new()
            $stroke.MappingMode = 'Absolute'
            $stroke.StartPoint = [System.Windows.Point]::new(0, 0)
            $stroke.EndPoint = [System.Windows.Point]::new(300, 0)
            $color = $bands[0].Color
            $stroke.GradientStops.Add([System.Windows.Media.GradientStop]::new($color, 0))
            foreach ($entry in $bands) {
                if ($entry.Color -ne $color) {
                    foreach ($stopColor in @($color, $entry.Color)) {
                        $stop = [System.Windows.Media.GradientStop]::new($stopColor, $entry.Offset)
                        if ($null -ne $duration -and $null -ne $entry.FromOffset) {
                            $move = [System.Windows.Media.Animation.DoubleAnimation]::new($entry.FromOffset, $entry.Offset, $duration)
                            $move.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                            $stop.BeginAnimation([System.Windows.Media.GradientStop]::OffsetProperty, $move)
                        }
                        $stroke.GradientStops.Add($stop)
                    }
                    $color = $entry.Color
                }
            }
            $stroke.GradientStops.Add([System.Windows.Media.GradientStop]::new($color, 1))
        }
        $path.Stroke = $stroke
        $path.Fill = $stroke
        $path.Data = $geometry
        $path.Tag = @{
            Segments = $segments
            LastTimestamp = if ($recent.Count) { [string]$recent[-1].TimestampUtc } else { '' }
            LastPoint = $previous
            Center = $center
        }
    }
    $context = $Element.LiveMemoryContext
    $last = if ($recent.Count) { $recent[-1] } else { $MemoryPreview }
    Set-TlcCaptureMemoryContext -Context $context -Strings $context.Tag.Strings -Sample $last `
        -Loading:$Loading -Preview:($recent.Count -eq 0 -and $null -ne $MemoryPreview) -ErrorAction Stop
    $Element.LiveNetworkValues.Text = if ($recent.Count) {
        $last = $recent[-1]
        $jitter = if ($null -ne $last.Jitter) { '{0:0.0}' -f $last.Jitter } else { '?' }
        $loss = if ($null -ne $last.Loss) { '{0:0.0}' -f $last.Loss } else { '?' }
        "STUN jitter: $jitter ms   |   STUN loss: $loss %"
    } else { 'STUN jitter: ? ms   |   STUN loss: ? %' }
}

function ConvertFrom-TlcWizardTimeText {
    <#
    .SYNOPSIS
        Reads the time box, returning $null when the text cannot be understood.
    .DESCRIPTION
        Separate from Resolve-TlcWizardImpactTime so the caller can tell "the operator
        typed midnight" apart from "the operator typed something this did not
        understand, so it became midnight". Those were previously the same answer,
        which is what made the failure invisible.

        The parser used to accept only HH:mm and HH.mm. Everything else silently became
        midnight - so '2:30 PM', the most natural way to type an afternoon time here,
        produced a window fourteen and a half hours off. Unlike a future impact time
        that lands nowhere, midnight is in the past and does have logs, so the run
        returned a full, plausible bundle covering the wrong hour. That is worse than
        an empty one: nothing about it looks wrong.

        Accepted: 14:30, 14.30, 2:30 PM, 2:30pm, 2:30 p.m., 9 AM, 1430, 930, 14:30:00.
        A bare hour with no meridiem is read on the 24-hour clock, which is what the
        box asks for.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $TimeText)

    if ([string]::IsNullOrWhiteSpace($TimeText)) { return $null }
    $text = $TimeText.Trim()

    # Peel off an AM/PM suffix first, so the numeric part is parsed the same way with
    # or without one.
    $meridiem = ''
    if ($text -match '(?i)^(.*?)\s*([ap])\.?\s*m\.?$') {
        $meridiem = $Matches[2].ToLowerInvariant()
        $text = $Matches[1].Trim()
    }

    $hour = -1
    $minute = 0

    if ($text -match '^(\d{1,2})\s*[:.]\s*(\d{1,2})(?:\s*[:.]\s*\d{1,2})?$') {
        # Seconds are accepted and discarded: a repro window is not that precise, and
        # rejecting them would send a perfectly clear entry to midnight.
        $hour = [int]$Matches[1]
        $minute = [int]$Matches[2]
    } elseif ($text -match '^(\d{3,4})$') {
        # Compact 24-hour, as people type it on a keypad: 1430, or 930 for 09:30.
        $digits = $Matches[1].PadLeft(4, '0')
        $hour = [int]$digits.Substring(0, 2)
        $minute = [int]$digits.Substring(2, 2)
    } elseif ($text -match '^(\d{1,2})$') {
        $hour = [int]$Matches[1]
    } else {
        return $null
    }

    if ($meridiem) {
        if ($hour -lt 1 -or $hour -gt 12) { return $null }
        if ($meridiem -eq 'p' -and $hour -ne 12) { $hour += 12 }
        if ($meridiem -eq 'a' -and $hour -eq 12) { $hour = 0 }
    }

    if ($hour -lt 0 -or $hour -gt 23 -or $minute -lt 0 -or $minute -gt 59) { return $null }

    return [timespan]::new($hour, $minute, 0)
}

function Resolve-TlcWizardImpactTime {
    <#
    .SYNOPSIS
        Combines the date picker and the time box into one instant.
    .DESCRIPTION
        Split across two controls because a WPF DatePicker carries no time, and the
        time is the part that matters for a repro window. An unreadable time falls
        back to midnight on the chosen date rather than refusing to build a command,
        so the wizard stays usable while the operator is still typing.

        The fallback is why ConvertFrom-TlcWizardTimeText is a separate function: the
        wizard calls it directly to warn about text it did not understand, because a
        silent midnight is indistinguishable from a deliberate one.
    #>
    [CmdletBinding()]
    param(
        [datetime] $Date,
        [string] $TimeText
    )

    $parsed = ConvertFrom-TlcWizardTimeText -TimeText $TimeText
    $hour = if ($parsed) { $parsed.Hours } else { 0 }
    $minute = if ($parsed) { $parsed.Minutes } else { 0 }

    return (Get-Date -Year $Date.Year -Month $Date.Month -Day $Date.Day -Hour $hour -Minute $minute -Second 0)
}

function ConvertTo-TlcWindowMinuteCount {
    <#
    .SYNOPSIS
        Converts a window figure and its unit into the minutes the toolbox takes.
    .DESCRIPTION
        The entry point has exactly one window vocabulary: -WindowBeforeMinutes and
        -WindowAfterMinutes. The unit dropdown is a convenience on top of that, so the
        conversion happens here and the generated command still says minutes - the
        equivalent command box promises to be what actually runs, and a command
        expressed in a unit the script does not accept would break that.

        An unreadable or non-positive figure falls back to the supplied default rather
        than to zero. int::TryParse writes 0 into its ref on failure instead of leaving
        the target alone, so the default has to be applied after the parse, not before:
        assigning first and parsing over it silently produced a zero-length window.

        The unit is matched on its first letter, lowercased. The dropdown shows "Hours"
        and this function is also called with 'hours' from tests and could be called
        with either from anywhere else - matching the exact display string would make a
        capitalisation change in the UI silently convert hours as if they were minutes,
        which is a sixtyfold error in the collection window with nothing to show for it.

        Hours are multiplied in [long] and capped. 35,791,395 hours overflows [int], and
        a silent wrap would turn a large window into a negative one, which reads as a
        valid instruction to collect backwards.

        The ceiling is ten years rather than [int]::MaxValue. Capping at the type limit
        looked safe and was not: 2,147,483,647 minutes is roughly four thousand years,
        and subtracting that from the impact date throws an un-representable DateTime on
        the coverage tile. Ten years exceeds any plausible Teams log retention - the
        logs on a working machine reach back weeks - by enough that no real collection
        can be affected, while staying well inside the date arithmetic.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Text,
        [string] $Unit = 'minutes',
        [int] $Default = 30
    )

    $value = $Default
    $parsed = 0
    if ([int]::TryParse($Text, [ref] $parsed) -and $parsed -gt 0) { $value = $parsed }

    # Ten years, in minutes.
    $ceiling = 10L * 365L * 24L * 60L

    if ($Unit -and $Unit.Trim().ToLowerInvariant().StartsWith('h')) {
        $minutes = [long]$value * 60L
        if ($minutes -gt $ceiling) { return [int]$ceiling }
        return [int]$minutes
    }

    if ([long]$value -gt $ceiling) { return [int]$ceiling }
    return $value
}

function ConvertTo-TlcCaptureIntervalSeconds {
    <#
    .SYNOPSIS
        The sampling interval in seconds, from whatever the dropdown is showing.
    .DESCRIPTION
        The items read "5 seconds" rather than "5", because a bare number beside a label
        reading "Sample every" is ambiguous about its unit. That leaves the parsing here, in
        one place, so the command and the run cannot end up disagreeing about the cadence.

        An unreadable or absent selection falls back to the documented default rather than to
        zero. Int32.TryParse writes 0 into its ref on failure rather than leaving the target
        alone, which is how the window boxes once turned a cleared field into a zero-minute
        window - so the default is applied after the parse, never before it.
    #>
    # PSUseSingularNouns, suppressed here rather than excluded in the settings file, because the
    # rule is worth keeping everywhere else. "Seconds" is the unit, not a plural of a thing: this
    # codebase names units into identifiers on purpose - WindowBeforeMinutes, CaptureIntervalSeconds,
    # PromptTimeoutMinutes - and a caller that cannot see the unit is a caller who will eventually
    # pass minutes. ConvertTo-TlcCaptureInterval would satisfy the analyser by removing the one
    # part of the name that stops a bug.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The trailing noun is a unit of measure, and dropping it would make the contract ambiguous.')]
    [CmdletBinding()]
    param(
        [AllowEmptyString()] [AllowNull()] [string] $Text,
        [int] $Default = 5
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $Default }

    $match = [regex]::Match($Text, '\d+')
    if (-not $match.Success) { return $Default }

    $parsed = 0
    if (-not [int]::TryParse($match.Value, [ref] $parsed)) { return $Default }
    if ($parsed -lt 1) { return $Default }

    return $parsed
}

function Test-TlcScenarioSupportsCapture {
    <#
    .SYNOPSIS
        Whether a live trace can say anything useful about this scenario.
    .DESCRIPTION
        The capture engine samples THIS machine: the media path from here, this machine's TCP
        connections and adapters, and the local ms-teams processes. That makes it meaningless
        for a scenario whose subject is somewhere else.

        Named explicitly rather than derived from lane counts, because the distinction is not
        "has automated collection" - it is "is the thing being diagnosed running on this
        machine". Teams Rooms and Rooms on Android are separate devices, a tenant service
        problem has no local component at all, a phone is a phone, and a CVI room segment is
        somebody else's bridge.

        Offering the button anyway and letting the run produce a flat series would be worse
        than not offering it: the samples would be real, and real measurements of the wrong
        machine are the hardest kind of wrong evidence to spot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ScenarioId
    )

    $remote = @('Rooms', 'RoomsAndroid', 'TenantService', 'Mobile', 'CviRoomSegment')
    return ($ScenarioId -and $remote -notcontains $ScenarioId)
}

function Get-TlcChevronOpacity {
    <#
    .SYNOPSIS
        How solid the header chevrons should be, for the theme in use.
    .DESCRIPTION
        One pale lavender asset, two very different backgrounds. The header band is painted with
        SurfaceBrush - NOT HeaderBrush, which is a different colour and was measured against by
        mistake the first time - so behind the chevrons sits #FFFFFF in light and #161B22 in
        dark.

        Measured against the mean opaque ink of TLC-Chevrons.png (#BBB5F9):

            light  #BBB5F9 on #FFFFFF   1.89:1
            dark   #BBB5F9 on #161B22   9.14:1

        The same artwork is nearly five times higher contrast in dark. That is not a subtle
        difference to be nudged; it is why the chevrons whisper on one theme and shout on the
        other.

        Dark is reduced to 0.55, compositing to #717098 and 3.68:1 - about twice the light-mode
        figure rather than equal to it, because a decoration that disappears is as wrong as one
        that shouts, and dark backgrounds carry a little more contrast comfortably.

        Light stays at full strength. At 1.89:1 the chevrons are already close to the floor of
        what is visible at all; taking anything off would erase them.

        A function rather than a literal so the numbers are assertable, and so the measurements
        live with the value instead of in a commit message.
    #>
    [CmdletBinding()]
    param(
        [bool] $Dark
    )

    if ($Dark) { return 0.55 }
    return 1.0
}

function Set-TlcWizardString {
    <#
    .SYNOPSIS
        Applies a resolved string table to every translatable control in the window.
    .DESCRIPTION
        One function, called at startup AND again whenever the language changes, so the two
        paths cannot drift. A separate "apply on change" routine would eventually translate a
        control the startup path had forgotten, or the reverse, and the difference would only
        show on the second language.

        Every control is reached by name and skipped if absent, so a markup change that drops
        a control degrades to an untranslated window rather than a crash on startup. The name
        list is asserted against the markup by Tlc.Localization.Tests.ps1, which is where a
        missing control should be caught - loudly, at gate time - rather than here.

        Deliberately NOT localized:

          - The scenario list. Those names are the shared vocabulary between this tool, the
            collection guidelines and the case notes an engineer writes; translating them
            would break the link between what the operator picked and what the bundle says.
          - The tile VALUES and the banners. They are not static text: the tile renderer and the
            banner refresh draw them from the metric each time, translating as they draw
            (Get-TlcTileText, and the keys a banner carries), so the metric itself stays English
            for everything that compares or logs it. Only the tile captions are set here.
          - Anything in the transcript, which is the child process's console output.

        The window is what is translated. The evidence is not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [hashtable] $Strings
    )

    $text = @{
        WhatHappenedHeading = 'WhatHappenedHeading'; ScenarioLabel = 'ScenarioLabel'; LaneText = 'ScenarioHint'
        CaseNumberLabel = 'CaseNumberLabel'; AffectedUserLabel = 'AffectedUserLabel'
        ConsentLabel = 'ConsentLabel'; ConsentHintText = 'ConsentHint'
        PathChooserHeading = 'PathChooserHeading'; PathChooserCaption = 'PathChooserCaption'
        GatherHeading = 'GatherHeading'; ImpactTimeLabel = 'ImpactTimeLabel'
        ImpactAtLabel = 'ImpactAtLabel'; WindowLabel = 'WindowLabel'
        BeforeLabel = 'BeforeLabel'; AfterLabel = 'AfterLabel'
        LiveHeading = 'LiveHeading'; LiveCaption = 'LiveCaption'
        LiveChartCaption = 'LiveChartCaption'; LiveChartAnimationHint = 'LiveChartAnimationHint'; SupportActionText = 'SupportActionText'
        LiveRttPassLegend = 'LiveRttPassLegend'; LiveRttWarningLegend = 'LiveRttWarningLegend'; LiveRttBlockedLegend = 'LiveRttBlockedLegend'
        LiveMemoryPassLegend = 'LiveMemoryPassLegend'; LiveMemoryWarningLegend = 'LiveMemoryWarningLegend'; LiveMemoryBlockedLegend = 'LiveMemoryBlockedLegend'
        LiveMemoryNeutralLegend = 'LiveMemoryNeutralLegend'
        LiveRttContext = 'LiveRttContext'
        GatherPathSelected = 'PathSelected'; LivePathSelected = 'PathSelected'
        SampleEveryLabel = 'SampleEveryLabel'; OptionsHeading = 'OptionsHeading'
        RoomsDeviceLabel = 'RoomsDeviceLabel'; EndpointsLabel = 'EndpointsLabel'
        OutputFolderLabel = 'OutputFolderLabel'; CaptureIntervalHint = 'CaptureIntervalHint'
        # The dashboard's captions. Their values are drawn by the tile renderer, which
        # translates them as it draws them (Get-TlcTileText); a caption is plain chrome.
        ClientCaption = 'TileClient'; LogsCaption = 'TileLogs'; RetentionCaption = 'TileRetention'
        ActivityCaption = 'TileActivity'; CrashCaption = 'TileCrash'; CoverageCaption = 'TileCoverage'
        NetworkCaption = 'TileNetwork'; UpdateCaption = 'TileUpdate'; SignInCaption = 'TileSignIn'
        # The run summary and the progress panel, which replace the form while a run goes.
        SummaryScenarioLabel = 'SummaryScenarioLabel'; SummaryCaseLabel = 'SummaryCaseLabel'
        SummaryUserLabel = 'SummaryUserLabel'; SummaryWindowLabel = 'SummaryWindowLabel'
        SummaryConsentLabel = 'ConsentLabel'; ProgressHeading = 'ProgressHeading'
        CapturePhaseArm = 'PhaseArm'; CapturePhaseReproduce = 'PhaseReproduce'; CapturePhaseCollect = 'PhaseCollect'
    }
    foreach ($name in $text.Keys) {
        if ($Element.Contains($name) -and $Element[$name]) {
            $Element[$name].Text = Get-TlcString -Table $Strings -Key $text[$name]
        }
    }

    $content = @{
        GatherPathButton = 'GatherPathButton'; LivePathButton = 'LivePathButton'
        ForgetCaseButton = 'ForgetButton'
        CancelButton = 'CancelButton'; PackageButton = 'PackageButton'; SkipSupportButton = 'SkipSupportButton'
        GenerateSupportButton = 'GenerateSupportButton'
        ShowLiveGraphBox = 'ShowLiveGraphBox'
        OpenButton = 'OpenButton'; ValidateButton = 'ValidateButton'
        SkipPromptedBox = 'SkipPromptedBox'; ValidationOnlyBox = 'ValidationOnlyBox'
        ElevateButton = 'ElevateButton'; DeepCaptureBox = 'DeepCaptureBox'
        SummaryConsentSave = 'RecordButton'
    }
    foreach ($name in $content.Keys) {
        if ($Element.Contains($name) -and $Element[$name]) {
            $Element[$name].Content = Get-TlcString -Table $Strings -Key $content[$name]
        }
    }

    $tip = @{
        GatherPathButton = 'GatherPathTip'; LivePathButton = 'LivePathTip'
        ForgetCaseButton = 'ForgetTip'
        CancelButton = 'CancelTip'; PackageButton = 'PackageTip'
        OpenButton = 'OpenTip'; ValidateButton = 'ValidateTip'
        CollectButton = 'CollectTip'; SettingsButton = 'SettingsTip'
        ComparisonLink = 'ComparisonLinkTip'
        RunLoadingPanel = 'WaitTip'
        ConsentMeBox = 'ConsentMeTip'; ConsentBox = 'ConsentBoxTip'
        ImpactWindowRow = 'ImpactWindowTip'; CaptureIntervalBox = 'SampleIntervalTip'
        ElevateButton = 'ElevateTip'; DeepCaptureBox = 'DeepCaptureTip'
        ToolChoiceDismiss = 'DismissRecommendationTip'; ScenarioAdvisoryDismiss = 'DismissAdvisoryTip'
    }
    foreach ($name in $tip.Keys) {
        if ($Element.Contains($name) -and $Element[$name]) {
            $Element[$name].ToolTip = Get-TlcString -Table $Strings -Key $tip[$name]
        }
    }
    foreach ($metricTip in @(
        @{ Name = 'LiveRttHeading'; Key = 'LiveRttTip'; Threshold = 'LiveRttThresholdTip'
            Sources = 'https://support.microsoft.com/en-us/teams/meetings/monitor-call-and-meeting-quality-in-microsoft-teams', 'https://learn.microsoft.com/en-us/microsoftteams/stream-classification-in-call-quality-dashboard' }
        @{ Name = 'LiveMemoryHeading'; Key = 'LiveMemoryTip'; Threshold = 'LiveMemoryThresholdTip'
            Sources = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-performance-problems-in-windows#memory' }
    )) {
        if ($Element.Contains($metricTip.Name)) {
            $body = [System.Windows.Controls.TextBlock]::new()
            $body.Text = (Get-TlcString -Table $Strings -Key $metricTip.Key) + "`n`n" +
                (Get-TlcString -Table $Strings -Key $metricTip.Threshold) + "`n`n" +
                (Get-TlcString -Table $Strings -Key 'LiveThresholdSources') + "`n" + ($metricTip.Sources -join "`n")
            $body.TextWrapping = 'Wrap'
            $tooltip = [System.Windows.Controls.ToolTip]::new()
            $tooltip.Style = $Element[$metricTip.Name].FindResource('GraphMetricTip')
            $tooltip.Content = $body
            $Element[$metricTip.Name].ToolTip = $tooltip
        }
    }
    if ($Element.Contains('LiveMemoryContext')) {
        $context = $Element.LiveMemoryContext
        $last = if ($context.Tag -is [hashtable]) { $context.Tag.Sample } else { $null }
        $loading = $context.Tag -is [hashtable] -and $context.Tag.Loading
        $preview = $context.Tag -is [hashtable] -and $context.Tag.Preview
        Set-TlcCaptureMemoryContext -Context $context -Strings $Strings -Sample $last -Loading:$loading -Preview:$preview -ErrorAction Stop
        if ($loading) {
            foreach ($name in 'LiveRttValue', 'LiveMemoryValue') {
                if ($Element.Contains($name)) { $Element[$name].Text = Get-TlcString -Table $Strings -Key 'LiveMetricLoading' }
            }
        }
    }

    # In-field prompts. The typed consent field has two: the whole question when it is the only
    # way to answer, and "someone else" when the signed-in account's checkbox sits beside it -
    # so which one is shown follows whether that checkbox is on screen.
    $prompts = @(
        @{ Field = 'ConsentBox'; Box = 'ConsentMeBox'; Alone = 'ConsentPlaceholder'; Beside = 'ConsentPlaceholderOther' }
        @{ Field = 'SummaryConsentBox'; Box = 'SummaryConsentMeBox'; Alone = 'SummaryConsentPlaceholder'; Beside = 'SummaryConsentPlaceholderOther' }
    )
    foreach ($prompt in $prompts) {
        if (-not ($Element.Contains($prompt.Field) -and $Element[$prompt.Field])) { continue }
        $beside = $Element.Contains($prompt.Box) -and $Element[$prompt.Box] -and [string]$Element[$prompt.Box].Visibility -eq 'Visible'
        $Element[$prompt.Field].Tag = Get-TlcString -Table $Strings -Key $(if ($beside) { $prompt.Beside } else { $prompt.Alone })
    }

    # The sampling choices carry their number in Tag, which is what the model reads, so the
    # words around it can be translated.
    if ($Element.Contains('CaptureIntervalBox') -and $Element.CaptureIntervalBox) {
        foreach ($item in $Element.CaptureIntervalBox.Items) {
            $seconds = 0
            if ([int]::TryParse([string]$item.Tag, [ref] $seconds)) {
                $item.Content = Get-TlcString -Table $Strings -Key 'SampleSeconds' -Argument @($seconds)
            }
        }
    }

    # The primary button's label depends on the chosen path, so it is set by $showPath rather
    # than here - setting it here as well would overwrite "Start trace" with "Collect" every
    # time the language changed mid-session. The caller re-runs $showPath afterwards.

    # A Hyperlink carries its text as inlines, not as Content or Text.
    if ($Element.Contains('AdminCenterLink') -and $Element.AdminCenterLink) {
        $Element.AdminCenterLink.Inlines.Clear()
        $Element.AdminCenterLink.Inlines.Add((Get-TlcString -Table $Strings -Key 'AdminCenterLink'))
    }
    if ($Element.Contains('ComparisonLink') -and $Element.ComparisonLink) {
        $Element.ComparisonLink.Inlines.Clear()
        $Element.ComparisonLink.Inlines.Add((Get-TlcString -Table $Strings -Key 'ComparisonLink'))
    }

    # The two window-unit choices are ComboBoxItems whose Content the model reads back by
    # string. Translating them would break ConvertTo-TlcWindowMinuteCount, which matches on
    # "minutes" - so the VALUE stays English and only what is displayed changes. Tag carries
    # the invariant token the code matches on.
    if ($Element.Contains('WindowUnitBox') -and $Element.WindowUnitBox) {
        foreach ($item in $Element.WindowUnitBox.Items) {
            $tag = [string]$item.Tag
            if ($tag -eq 'minutes') { $item.Content = Get-TlcString -Table $Strings -Key 'UnitMinutes' }
            elseif ($tag -eq 'hours') { $item.Content = Get-TlcString -Table $Strings -Key 'UnitHours' }
        }
    }

    Set-TlcWizardScenarioName -Element $Element -Strings $Strings
}

function Set-TlcWizardScenarioName {
    <#
    .SYNOPSIS
        Labels the scenario list in the window's language, keeping the English name one hover away.
    .DESCRIPTION
        Each item carries its catalog entry in Tag. The label is the translated name; the tooltip
        is the English one, wherever the two differ, because the English name is what the
        collection guidelines, the case notes and the bundle say, and an engineer matching one to
        the other needs to see it. Items that are not scenarios are left alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [hashtable] $Strings
    )

    if (-not ($Element.Contains('ScenarioBox') -and $Element.ScenarioBox)) { return }
    foreach ($item in $Element.ScenarioBox.Items) {
        if ($item -isnot [System.Windows.Controls.ComboBoxItem]) { continue }
        $scenario = $item.Tag
        if ($scenario -is [string] -and $scenario -in 'ScenarioGroupCommon', 'ScenarioGroupLive', 'ScenarioGroupRemote') {
            $item.Content = Get-TlcString -Table $Strings -Key $scenario
            continue
        }
        if (-not $scenario -or -not $scenario.Id) { continue }
        $shown = Get-TlcScenarioDisplayName -Scenario $scenario -Table $Strings
        $item.Content = $shown
        $item.ToolTip = if ($shown -cne [string]$scenario.Name) { [string]$scenario.Name } else { $null }
    }
}

function Initialize-TlcWizardScenarioList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [object[]] $Catalog,
        [Parameter(Mandatory)] [hashtable] $Strings
    )

    $box = $Element.ScenarioBox
    $box.Items.Clear()
    $commonIds = @('CallQuality', 'DesktopLaunchCrash', 'DesktopSignIn')
    $common = @(foreach ($id in $commonIds) { $Catalog | Where-Object { $_.Id -eq $id } })
    foreach ($section in @(
        @{ Key = 'ScenarioGroupCommon'; Items = $common }
        @{ Key = 'ScenarioGroupLive'; Items = @($Catalog | Where-Object {
            $_.Id -notin $commonIds -and (Test-TlcScenarioSupportsCapture -ScenarioId $_.Id)
        }) }
        @{ Key = 'ScenarioGroupRemote'; Items = @($Catalog | Where-Object {
            -not (Test-TlcScenarioSupportsCapture -ScenarioId $_.Id)
        }) }
    )) {
        $group = @($section.Items)
        if (-not $group.Count) { continue }
        $header = [System.Windows.Controls.ComboBoxItem]::new()
        $header.Tag = $section.Key
        $header.Style = $box.FindResource('ScenarioGroupHeader')
        $header.IsEnabled = $false
        $header.Focusable = $false
        $header.IsTabStop = $false
        [System.Windows.Automation.AutomationProperties]::SetAutomationId($header, [string]$header.Tag)
        $null = $box.Items.Add($header)
        foreach ($scenario in $group) {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Tag = $scenario
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($item, "Scenario-$($scenario.Id)")
            $null = $box.Items.Add($item)
        }
    }
    Set-TlcWizardScenarioName -Element $Element -Strings $Strings
    $box.SelectedIndex = -1
}

function Get-TlcWizardSelectedScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [object[]] $Catalog
    )

    $box = $Element.ScenarioBox
    $selection = $box.PSObject.Properties['SelectedItem']
    if ($selection -and $selection.Value -is [System.Windows.Controls.ComboBoxItem]) {
        $item = $selection.Value
        if (-not $item.IsEnabled -or $item.Tag -isnot [System.Collections.IDictionary] -or -not $item.Tag.Contains('Id')) { return $null }
        $resolved = @($Catalog | Where-Object { $_.Id -eq $item.Tag.Id })
        if ($resolved.Count -ne 1) { throw 'The selected scenario does not resolve to one catalog entry.' }
        return $resolved[0]
    }
    # Untagged selectors used by command-model callers retain their original catalog ordering.
    $index = $box.SelectedIndex
    if ($index -ge 0 -and $index -lt $Catalog.Count) { return $Catalog[$index] }
    return $null
}

function Show-TlcSettingsWindow {
    <#
    .SYNOPSIS
        The settings window. Returns the language chosen, or $null if nothing changed.
    .DESCRIPTION
        Takes its strings from the table it is given rather than through
        Set-TlcWizardString, because it is built fresh on each open. That matters for the
        case the feature exists for: an operator who has landed in a language they cannot
        read opens this window, and it has to already be in that language so the option
        they recognise is the one on screen.

        The language applies on selection rather than on a separate OK button. It is
        reversible in the same window and the effect is visible behind the dialog, so a
        confirm step would be a click asking "are you sure" about something already undone by
        picking the previous entry.

        The theme does NOT apply live, and the window says so rather than leaving it to be
        discovered. The theme is merged into each window at XAML parse time, so a live swap
        would repaint the handful of elements bound with DynamicResource and leave the ~188
        bound with StaticResource in the old colours. A half-themed window is worse than one
        that waits for the next open.

        Returns a hashtable of what changed, or $null if nothing did. A hashtable rather than
        a string because there are now two settings and the caller has to be able to tell
        which one moved.

        -PassThru builds the window, wires every handler and returns it with its elements
        instead of showing it, the way the comparison window and the session log picker do,
        so a test can press the real buttons through the real handlers without blocking on a
        dialog. The Start menu row is only provable that way.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] $Owner,
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [Parameter(Mandatory)] [string] $ThemePath,
        [Parameter(Mandatory)] [string] $Current,
        [string] $CurrentTheme = 'System',
        # Called with the newly chosen tag each time the language changes, so the window
        # behind updates live. Returning the final value as well would make the caller
        # handle the same change twice.
        [scriptblock] $OnChange,
        [switch] $PassThru
    )

    $settingsStrings = Get-TlcStringTable -Language $Current -ToolboxRoot $ToolboxRoot
    $settingsWindow = Import-TlcXaml -Path (Join-Path (Join-Path $ToolboxRoot 'Ui') 'Settings.xaml') -ThemePath $ThemePath

    # The title bar, which WPF does not paint. Missed when this window was written, and it
    # showed: a light caption over dark content, the same gap the capability comparison had.
    # Measured from the theme this window actually loaded, so it cannot disagree with itself.
    $null = Set-TlcWindowChromeFromSurface -Window $settingsWindow -Surface ($settingsWindow.TryFindResource('SurfaceBrush'))

    $settingsElement = Get-TlcUiElement -Root $settingsWindow -Name @(
        'SettingsHeading', 'SettingsLanguageLabel', 'LanguageBox',
        'SettingsThemeLabel', 'ThemeBox', 'SettingsThemeHint',
        'SettingsLanguageHint', 'SettingsTranslationNote', 'SettingsAbout', 'SettingsCloseButton',
        'SettingsShortcutLabel', 'ShortcutButton', 'ShortcutButtonText', 'ShortcutHint'
    )

    $settingsWindow.Title = 'TLC Toolbox - ' + (Get-TlcString -Table $settingsStrings -Key 'SettingsHeading')
    $settingsElement.SettingsHeading.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsHeading'
    $settingsElement.SettingsLanguageLabel.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsLanguageLabel'
    $settingsElement.SettingsLanguageHint.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsLanguageHint'
    $settingsElement.SettingsThemeLabel.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsThemeLabel'
    $settingsElement.SettingsThemeHint.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsThemeHint'
    $settingsElement.SettingsTranslationNote.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsTranslationNote'
    $settingsElement.SettingsCloseButton.Content = Get-TlcString -Table $settingsStrings -Key 'SettingsClose'
    $settingsElement.SettingsShortcutLabel.Text = Get-TlcString -Table $settingsStrings -Key 'SettingsShortcutLabel'

    # The Start menu row is drawn from the entry on disk, so the button offers the action
    # that applies now. A failure to read it shows in the row's hint and does not stop the
    # window opening: it is one setting among several. Finding 341.
    $null = Update-TlcShortcutSetting -ButtonText $settingsElement.ShortcutButtonText -Hint $settingsElement.ShortcutHint -Strings $settingsStrings -ToolboxRoot $ToolboxRoot

    # Version and author, read from the manifest rather than typed here. Deliberately NOT
    # localised: a version number and a person's name are the same in every language, and
    # they are what somebody quotes back when reporting a defect.
    #
    # Failure here must not stop the window opening - it is a caption, and a settings dialog
    # that refuses to open because it could not read a version number would be a worse fault
    # than the missing caption.
    try {
        # Import-TlcDataFile, not Import-PowerShellDataFile: that cmdlet lives in
        # Microsoft.PowerShell.Utility, and a module loaded through the manifest does not
        # get it in session state - so this would work in every test, which imports module
        # files directly, and fail in the product. There is a guard holding that line.
        $settingsManifest = Import-TlcDataFile -Path (Join-Path $ToolboxRoot 'Tlc.psd1')
        $about = "TLC Toolbox $($settingsManifest.ModuleVersion)"
        if ($settingsManifest.Author) { $about += "  -  $($settingsManifest.Author)" }
        $settingsElement.SettingsAbout.Text = $about
    } catch {
        Write-Verbose "The version stamp could not be read: $($_.Exception.Message)"
        $settingsElement.SettingsAbout.Text = ''
    }

    # Each language is listed under its own name, never translated into the current one. The
    # person most likely to need this menu is the one who cannot read what is currently on
    # screen, and they are looking for the word they recognise.
    $languages = @(Get-TlcLanguage)
    foreach ($languageOption in $languages) {
        $settingsItem = New-Object System.Windows.Controls.ComboBoxItem
        $settingsItem.Tag = $languageOption.Tag
        $settingsItem.Content = $languageOption.Name
        $null = $settingsElement.LanguageBox.Items.Add($settingsItem)
    }
    $selected = [Math]::Max(0, [array]::IndexOf(@($languages | ForEach-Object { $_.Tag }), $Current))
    $settingsElement.LanguageBox.SelectedIndex = $selected

    # The theme names ARE translated, unlike the language names: someone reading this row can
    # by definition read the current language, and "Follow system setting" is a sentence
    # rather than a proper noun. The Tag carries the invariant id that Settings.json stores.
    $themes = @(Get-TlcThemeOption)
    foreach ($theme in $themes) {
        $settingsItem = New-Object System.Windows.Controls.ComboBoxItem
        $settingsItem.Tag = $theme.Id
        $settingsItem.Content = Get-TlcString -Table $settingsStrings -Key $theme.Key
        $null = $settingsElement.ThemeBox.Items.Add($settingsItem)
    }
    $settingsElement.ThemeBox.SelectedIndex = [Math]::Max(0, [array]::IndexOf(@($themes | ForEach-Object { $_.Id }), $CurrentTheme))

    <#
        A HASHTABLE MUTATED IN PLACE, not $script: variables.

        Inside a GetNewClosure() block, $script: refers to the NEW dynamic module the closure
        creates - not to this module. So the handlers below wrote $script:SettingsChosen into a
        scope that vanished with them, and the check after ShowDialog read this module's copy,
        which still held the starting value. Neither the language nor the appearance setting
        has ever persisted. Proved in isolation, not inferred: a closure reading $script:X sees
        '' and its write never reaches the enclosing module. Finding 289.

        A hashtable captured by reference is shared by both sides, which is the same reason
        the wizard carries $state.
    #>
    $choice = @{ Language = $Current; Theme = $CurrentTheme }

    $settingsElement.LanguageBox.Add_SelectionChanged({
        $settingsItem = $settingsElement.LanguageBox.SelectedItem
        if (-not $settingsItem) { return }
        $tag = [string]$settingsItem.Tag
        if (-not $tag -or $tag -eq $choice.Language) { return }
        $choice.Language = $tag
        if ($OnChange) { & $OnChange $tag }
    }.GetNewClosure())

    $settingsElement.ThemeBox.Add_SelectionChanged({
        $settingsItem = $settingsElement.ThemeBox.SelectedItem
        if (-not $settingsItem) { return }
        $id = [string]$settingsItem.Tag
        if ($id) { $choice.Theme = $id }
    }.GetNewClosure())

    $settingsElement.ShortcutButton.Add_Click({
        $null = Update-TlcShortcutSetting -ButtonText $settingsElement.ShortcutButtonText -Hint $settingsElement.ShortcutHint -Strings $settingsStrings -ToolboxRoot $ToolboxRoot -Toggle
    }.GetNewClosure())

    $settingsElement.SettingsCloseButton.Add_Click({ $settingsWindow.Close() }.GetNewClosure())

    if ($PassThru) { return [pscustomobject]@{ Window = $settingsWindow; Element = $settingsElement; Choice = $choice } }

    $settingsWindow.Owner = $Owner
    $null = $settingsWindow.ShowDialog()

    $changed = @{}
    if ($choice.Language -ne $Current) { $changed['Language'] = $choice.Language }
    if ($choice.Theme -ne $CurrentTheme) { $changed['Theme'] = $choice.Theme }
    if ($changed.Count -eq 0) { return $null }
    return $changed
}

function Get-TlcCoverageTileOverride {
    <#
    .SYNOPSIS
        What the "Window" readiness tile should say when it cannot honestly measure coverage,
        or $null to let it compute normally.
    .DESCRIPTION
        The readiness tiles sit above "What happened", so they stay on screen when the path
        panels below are hidden. Eight of the nine describe the machine and are true whichever
        job is being done. The Window tile is the exception: it measures whether retained logs
        cover the impact window, which is a question only the gathering path asks.

        Two cases where it must not answer.

        BEFORE A PATH IS CHOSEN. The form seeds the impact time with now and the window with
        plus and minus thirty minutes, so the window always ends in the future and the tile
        always came up amber - "Ends in the future" on every single launch, in the top row,
        about a value nobody typed. An alarm that fires every time is an alarm operators learn
        to scroll past, and it fires here before the operator has even said which job they are
        doing. Same defect as the panels below it: answering for a job nobody picked.

        ON THE LIVE PATH. A live trace reads no retained logs and has no typed window, so the
        same amber warning describes a value the run will not use.

        Returns $null once the gathering path is chosen, so the caller computes the real
        coverage - which is the one case where the question means something.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Model,
        # Whether the operator has picked a job yet. Passed in rather than inferred from the
        # model: the model defaults to the gathering stage so the command box has something to
        # show, which makes "not chosen" and "chose gathering" identical inside it.
        [bool] $PathChosen = $true
    )

    if (-not $PathChosen) {
        $parts = @(New-TlcMetricText -Key 'DetailCoveragePickAJob' -English 'This measures whether the logs still on disk cover the window you ask for, which only applies when packaging existing logs. Choose a job under "What to do" and it will answer.')
        return [ordered]@{
            Status = 'Neutral'
            Value  = 'Pick a job'
            Detail = Join-TlcMetricText $parts; DetailParts = $parts
        }
    }

    if ([string]$Model.Stage -ne 'Capture') { return $null }

    $parts = @(New-TlcMetricText -Key 'DetailCoverageLive' -English 'A live trace records from the moment you start it until you press Stop run, so retained-log coverage does not apply. Package existing logs instead if the fault has already happened.')
    return [ordered]@{
        Status = 'Neutral'
        Value  = 'Live trace'
        Detail = Join-TlcMetricText $parts; DetailParts = $parts
    }
}

function Get-TlcRunSummaryWindowText {    <#
    .SYNOPSIS
        The "window" line on the run summary panel, for either fork.
    .DESCRIPTION
        The two forks have different notions of time and the panel has one line for it.

        Gather selects from logs that already exist, so its line is the impact time and the
        span either side. Capture creates the evidence as it goes, so there is no window until
        the session ends - the session IS the window. Reading the impact time off a capture
        model threw outright, because the model deliberately does not carry one: a capture
        command that also stated a retrospective window would be describing two different
        collections on one line.

        A function rather than an inline expression so that both forks are provable without
        starting a process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Model,
        # The window's string table. Without one the line is the English below, which the
        # en-US entries reproduce exactly.
        [hashtable] $Strings
    )

    $say = {
        param([string] $Key, [string] $English, [object[]] $Argument)
        $template = if ($Strings -and $Strings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Strings[$Key])) { [string]$Strings[$Key] } else { $English }
        if ($Argument) {
            try { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $template, $Argument) }
            catch [System.FormatException] { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $English, $Argument) }
        }
        return $template
    }

    if ([string]$Model.Stage -eq 'Capture') {
        return (& $say 'SummaryWindowLive' 'Live capture  -  sampling until you press Stop run')
    }

    if (-not $Model.Contains('ImpactTime') -or $null -eq $Model['ImpactTime']) {
        return (& $say 'SummaryWindowNone' '(no window)')
    }

    return (& $say 'SummaryWindowSpan' '{0}  -{1} / +{2} min' @(
        ([datetime]$Model['ImpactTime']).ToString('yyyy-MM-dd HH:mm'), $Model['WindowBeforeMinutes'], $Model['WindowAfterMinutes']))
}

function Set-TlcRunActionButton {
    <#
    .SYNOPSIS
        Puts Stop run in the primary button's place while a run is going, and puts the primary
        button back when it ends.
    .DESCRIPTION
        Stop run used to appear on the far left, beside the settings gear, while a greyed-out
        Start trace kept the primary place on the right, so the one live action was where
        nobody looked. Reported 2026-09-29. Finding 321.

        Returns the primary button's visibility from before the run, so the caller can put
        back exactly what was there: it is hidden until a job is chosen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [bool] $Running,
        [string] $RestoreVisibility = 'Visible',
        [switch] $LiveCapture
    )

    if ($Element.Contains('LiveStaticPanel') -and $Running -and $LiveCapture) {
        $Element.LiveStaticPanel.Visibility = 'Collapsed'
    }
    if ($Running) {
        $before = [string]$Element.CollectButton.Visibility
        $Element.CollectButton.Visibility = 'Collapsed'
        $Element.CancelButton.IsEnabled = $true
        $Element.CancelButton.Visibility = 'Visible'
        if ($Element.Contains('SkipSupportButton')) {
            $Element.SkipSupportButton.Visibility = 'Collapsed'
            $Element.SkipSupportButton.IsEnabled = $true
        }
        return $before
    }

    $Element.CancelButton.Visibility = 'Collapsed'
    if ($Element.Contains('SkipSupportButton')) { $Element.SkipSupportButton.Visibility = 'Collapsed' }
    if ($Element.Contains('SupportActionPanel')) { $Element.SupportActionPanel.Visibility = 'Collapsed' }
    $Element.CollectButton.Visibility = if ($RestoreVisibility) { $RestoreVisibility } else { 'Visible' }
    return [string]$Element.CollectButton.Visibility
}

function Select-TlcStaleWizardLog {
    <#
    .SYNOPSIS
        Picks the wizard's own tool logs that may be deleted: past the newest few, only those
        that are also old, and never more than a hard cap kept.
    .DESCRIPTION
        The wizard used to keep its newest ten logs by count alone. On 2026-09-29 a series of
        test launches, each opening a wizard, deleted the user's log from four days earlier,
        and the volume shadow copies held only zeros for it, so it could not be recovered.
        Launches come in bursts, while testing or retrying, and a burst is exactly when an
        earlier log is worth having. Now a log also survives while it is younger than
        KeepDays. The logs are a few kilobytes each, so the cap only stops unbounded growth.
        Finding 327.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.IO.FileInfo[]] $Log,
        [int] $Keep = 10,
        [int] $KeepDays = 14,
        [int] $Cap = 100,
        [datetime] $Now = (Get-Date)
    )

    $sorted = @($Log | Sort-Object LastWriteTime -Descending)
    $oldest = $Now.AddDays(-$KeepDays)
    for ($i = $Keep; $i -lt $sorted.Count; $i++) {
        if ($i -ge $Cap -or $sorted[$i].LastWriteTime -lt $oldest) { $sorted[$i] }
    }
}

function New-TlcWindowExceptionHandler {
    <#
    .SYNOPSIS
        The wizard's last line of defence: a Dispatcher.UnhandledException handler that logs
        what reached it and keeps the window open.
    .DESCRIPTION
        Every wizard handler is meant to be wrapped, and one that was not - Activated - threw
        inside WM_ACTIVATE whenever a tile's detail window was closed more than 30 seconds
        after the last gather. Windows delivers WM_ACTIVATE as a callback from the kernel, so
        the exception did not close the window, it ended the process: Windows Error Reporting
        recorded 0xe0434352 and then 0xc000041d, and nothing reached any log. Present from
        0.1.18 to 0.1.20 at least. Finding 328.

        Anything that still reaches the dispatcher is written to the tool log with its script
        stack, shown in the transcript card, and marked handled - the same trade every wrapped
        handler already makes, because nothing the wizard does is worth losing the form over.

        The element table is captured here, in a scope that holds nothing else, for the
        reason the fault happened at all: a handler that resolves $element by name gets
        whichever function defining one is on the stack at the time.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Element)

    return {
        param($source, $e)
        $null = $source
        try {
            # Through PSObject: ErrorRecord belongs to the exceptions PowerShell raises, and
            # reading it off any other type throws under StrictMode.
            $held = $e.Exception.PSObject.Properties['ErrorRecord']
            $record = if ($held -and $held.Value) {
                $held.Value
            } else {
                New-Object System.Management.Automation.ErrorRecord($e.Exception, 'UnhandledWindowException', 'NotSpecified', $null)
            }
            Write-TlcToolLog -Message 'An exception reached the window unhandled. The window stayed open.' -Level 'ERROR' -ErrorRecord $record
            $Element.LogPanel.Visibility = 'Visible'
            $Element.LogBox.Text += "`r`n[window] $($e.Exception.Message)"
        } catch {
            Write-Verbose "The unhandled window exception could not be reported: $($_.Exception.Message)"
        }
        $e.Handled = $true
    }.GetNewClosure()
}

function Get-TlcWizardConsent {
    <#
    .SYNOPSIS
        The consent the form records: the signed-in account when its box is ticked, otherwise
        whatever was typed.
    .DESCRIPTION
        One reader for the model, the startup hint, the Collect warning and the Package picker.
        Two readers of "who consented" would eventually disagree, and the one that disagreed
        with the privacy gate would promise something the gate then denied.

        The account is read from the checkbox's Tag, not from what it displays, the same split
        the window unit uses: the display can be trimmed to fit, the value cannot.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Element)

    if ($Element.Contains('ConsentMeBox') -and $Element.ConsentMeBox -and $Element.ConsentMeBox.IsChecked -eq $true) {
        $account = [string]$Element.ConsentMeBox.Tag
        if ($account) { return $account }
    }
    if ($Element.Contains('ConsentBox') -and $Element.ConsentBox) { return [string]$Element.ConsentBox.Text }
    return ''
}

function Get-TlcDeepCaptureReasonText {
    <#
    .SYNOPSIS
        Why a deeper capture cannot run, in the window's language.
    .DESCRIPTION
        Built from the facts the option carries - whether its tool is present, whether the
        toolbox is elevated, which tool - rather than by reading its English Reason, which
        Capture.json records and which has to stay English. Get-TlcDeepCaptureReason writes that
        English from the same facts, and Tlc.Ui.Tests.ps1 requires the English entries here to
        reproduce it for every combination. An available option keeps its own sentence.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Option,
        [Parameter(Mandatory)] [hashtable] $Table
    )

    if ($Option.Available) { return [string]$Option.Reason }
    $noTool = -not $Option.ToolPresent
    $notAdmin = -not $Option.Elevated
    $packet = ([string]$Option.Name -eq 'PacketCapture')
    $key = if ($noTool -and $notAdmin) { if ($packet) { 'DeepReasonNoPacketToolNotAdmin' } else { 'DeepReasonNoToolNotAdmin' } }
           elseif ($noTool) { if ($packet) { 'DeepReasonNoPacketTool' } else { 'DeepReasonNoTool' } }
           elseif ($notAdmin) { 'DeepReasonNotAdmin' }
           else { '' }
    if (-not $key) { return [string]$Option.Reason }
    return (Get-TlcString -Table $Table -Key $key -Argument @([string]$Option.Tool))
}
function Set-TlcWizardConsentAccount {
    <#
    .SYNOPSIS
        Offers the signed-in account as a consent checkbox, or leaves the typed field as the
        only way to record consent when no account could be read.
    .DESCRIPTION
        The box is left UNTICKED. Consent is an act, and a box that arrives ticked records
        nobody's; the shipped config leaves Privacy.ConsentGrantedBy empty for the same reason.

        With no account the checkbox is hidden and the typed field keeps its full prompt: the
        fallback. With one, the typed field stays beside it for consent given by somebody else,
        and its prompt says so.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [AllowEmptyString()] [string] $Account,
        # The window's string table, for the "someone else" prompts. English without one.
        [hashtable] $Strings
    )

    $other = if ($Strings) { Get-TlcString -Table $Strings -Key 'ConsentPlaceholderOther' } else { 'Or someone else: name and role' }
    $summaryOther = if ($Strings) { Get-TlcString -Table $Strings -Key 'SummaryConsentPlaceholderOther' } else { 'Or someone else' }
    $pairs = @(
        @{ Box = 'ConsentMeBox'; Text = 'ConsentMeText'; Field = 'ConsentBox'; Other = $other }
        @{ Box = 'SummaryConsentMeBox'; Text = 'SummaryConsentMeText'; Field = 'SummaryConsentBox'; Other = $summaryOther }
    )
    foreach ($pair in $pairs) {
        if (-not ($Element.Contains($pair.Box) -and $Element[$pair.Box])) { continue }
        $box = $Element[$pair.Box]
        $box.IsChecked = $false
        if ($Account) {
            $box.Tag = $Account
            if ($Element.Contains($pair.Text) -and $Element[$pair.Text]) { $Element[$pair.Text].Text = $Account }
            $box.Visibility = 'Visible'
            if ($Element.Contains($pair.Field) -and $Element[$pair.Field]) { $Element[$pair.Field].Tag = $pair.Other }
        } else {
            $box.Tag = ''
            $box.Visibility = 'Collapsed'
        }
    }
    Update-TlcWizardConsentField -Element $Element
}

function Update-TlcWizardConsentField {
    <#
    .SYNOPSIS
        Hides the typed consent field while the account box beside it is ticked, so only one
        answer to "who consented" is on screen at a time.
    .DESCRIPTION
        Hidden, not cleared: unticking brings back whatever was typed. And Hidden rather than
        Collapsed: the field is taller than the checkbox, so collapsing it made everything below
        the row jump when the box was ticked.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Element)

    foreach ($pair in @(@('ConsentMeBox', 'ConsentBox'), @('SummaryConsentMeBox', 'SummaryConsentBox'))) {
        if (-not ($Element.Contains($pair[1]) -and $Element[$pair[1]])) { continue }
        $ticked = $Element.Contains($pair[0]) -and $Element[$pair[0]] -and $Element[$pair[0]].IsChecked -eq $true
        $Element[$pair[1]].Visibility = if ($ticked) { 'Hidden' } else { 'Visible' }
    }
}

function Get-TlcWizardModel {
    <#
    .SYNOPSIS
        Reads the current window state into a model for command generation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Element,
        [Parameter(Mandatory)] [object[]] $Catalog,
        [string] $Stage = 'Collect',
        [string] $CorrelationId,
        # Which of the two jobs this run is. 'Gather' selects from logs already written;
        # 'Capture' samples the machine live. Passed in rather than read from a control because
        # the choice is a property of the session, not of a checkbox that could disagree with it.
        [ValidateSet('Gather', 'Capture')]
        [string] $Fork = 'Gather',
        # Where a live capture session will look for its stop sentinel. Passed in rather than
        # generated here because this function runs on every keystroke to refresh the command
        # box, and a path generated per call would change under the operator as they typed -
        # and would no longer match the file the Stop button writes.
        [string] $CaptureStopSignalPath
    )

    $selectedScenario = Get-TlcWizardSelectedScenario -Element $Element -Catalog $Catalog
    $scenarioId = if ($selectedScenario) { [string]$selectedScenario.Id } else { '' }

    $date = if ($Element.ImpactDate.SelectedDate) { [datetime]$Element.ImpactDate.SelectedDate } else { Get-Date }
    $impact = Resolve-TlcWizardImpactTime -Date $date -TimeText $Element.ImpactTimeBox.Text

    # The window is typed in whichever unit the dropdown shows, but the toolbox only
    # speaks minutes, so it is converted here rather than anywhere closer to the UI.
    # Everything downstream - the equivalent command, the coverage tile, the run itself
    # - then reads one number in one unit.
    #
    # Read from Tag, not from what the item displays. The items are ComboBoxItems whose
    # Content is translated and whose Tag is the invariant English token this matches on.
    # Reading the display text worked until the window could be shown in Spanish, at which
    # point the unit silently stopped matching 'hours' and every window in an hours-based
    # form would have been collected as minutes - a sixtyfold error in the window, with
    # nothing on screen to show for it.
    $unit = 'minutes'
    if ($Element.Contains('WindowUnitBox') -and $Element.WindowUnitBox.SelectedItem) {
        $selected = $Element.WindowUnitBox.SelectedItem
        $tag = if ($selected.PSObject.Properties['Tag']) { [string]$selected.Tag } else { '' }
        $unit = if ($tag) { $tag } else { [string]$selected }
    }

    $before = ConvertTo-TlcWindowMinuteCount -Text $Element.BeforeBox.Text -Unit $unit
    $after = ConvertTo-TlcWindowMinuteCount -Text $Element.AfterBox.Text -Unit $unit

    # The case box is an editable ComboBox. Its Text is the typed value, but a selection
    # made from the remembered list is not always in Text yet when the change handlers
    # run - which produced a command carrying the affected user and no -CaseNumber, the
    # exact mislabelling this feature exists to prevent. Text wins when it holds
    # something, because that is what the user last typed; the selection is the fallback.
    $case = [string]$Element.CaseBox.Text
    if ([string]::IsNullOrWhiteSpace($case) -and $Element.CaseBox.PSObject.Properties['SelectedItem']) {
        $case = [string]$Element.CaseBox.SelectedItem
    }

    $model = [ordered]@{
        Stage               = $Stage
        Scenario            = $scenarioId
        CaseNumber          = $case
        AffectedUser        = $Element.UserBox.Text
        ConsentGrantedBy    = Get-TlcWizardConsent -Element $Element
        ImpactTime          = $impact
        WindowBeforeMinutes = $before
        WindowAfterMinutes  = $after
        SkipPrompted        = [bool]$Element.SkipPromptedBox.IsChecked
        ValidationOnly      = [bool]$Element.ValidationOnlyBox.IsChecked
        OutputRoot          = $Element.OutputBox.Text
    }

    # Read through Get-TlcFleetEndpoint rather than split here, so the wizard and the entry
    # point agree on what a list means - blanks dropped, duplicates dropped case-insensitively,
    # comment lines ignored. A second parser would eventually disagree with the first.
    #
    # Only when the box is enabled. A disabled box can still hold text from before readiness
    # was measured, and collecting from endpoints the operator was told were unavailable is
    # the worst possible reading of "the control was ignored".
    #
    # And only on the gathering fork. The fleet lane belongs to the Collect stage; -Stage
    # Capture samples the machine it is running on and never reads the list. Emitting it there
    # would put names on the command line that the run then ignores, which is exactly what the
    # box is hidden on that path to prevent.
    if ($Fork -ne 'Capture' -and $Element.Contains('EndpointBox') -and $Element.EndpointBox.IsEnabled) {
        $raw = @([string]$Element.EndpointBox.Text -split '[,;\r\n]')
        $endpoints = @(Get-TlcFleetEndpoint -Endpoint $raw)
        if ($endpoints.Count -gt 0) { $model['Endpoint'] = $endpoints }
    }

    if ($scenarioId -eq 'Rooms') { $model['TargetDevice'] = $Element.DeviceBox.Text }
    if ($CorrelationId) { $model['CorrelationId'] = $CorrelationId }

    # The second fork. Capture is a stage of its own rather than a switch on Collect, because
    # the two do genuinely different things: Collect copies logs that already exist, Capture
    # samples the machine while the operator reproduces the fault.
    #
    # The fork arrives as a parameter because the model is built on every keystroke to refresh
    # the command box, and the choice lives in the window's state - reading it from a control
    # would put the decision in two places. Checked in one place, here, so the equivalent
    # command in the box and the process that actually starts can never disagree about which
    # fork is running.
    #
    # Validation-only no longer overrides the fork. It used to rewrite the stage to Collect,
    # so ticking it on the live path produced "-Stage Collect -ValidationOnly -ImpactTime ...
    # -WindowBeforeMinutes 30" - a retrospective plan built from window controls that are
    # collapsed on that path and that the operator could neither see nor set. The entry point
    # returns on -ValidationOnly BEFORE the stage switch, so -Stage Capture -ValidationOnly is
    # valid and means exactly what it says: plan the trace, record nothing. Measured against
    # the real entry point - it writes a Live scope, takes no samples and returns clean.
    # PACKAGE IS NOT ONE OF THE TWO FORKS, and the override has to say so. It acts ON a
    # finished run, which was produced by whichever fork made it, so rewriting the stage
    # here started a second live trace when the operator pressed Package with the live path
    # still selected - reported 2026-09-22 as "the package button on the live trace fork
    # seems to just start a new run". The finished evidence was never packaged, and what
    # came back was another recording of a fault that had already happened.
    #
    # Validate-Only is already handled below by leaving the stage at Capture, which is
    # correct and different: validating the LIVE job is still the live job. Package is not
    # a job at all.
    if ($Fork -eq 'Capture' -and $Stage -ne 'Package') {
        $model.Stage = 'Capture'

        # The sentinel is wiring for a session that a validation-only run never starts, so
        # naming it on that command line would be a parameter nothing reads.
        if ($Stage -ne 'Validate-Only' -and $CaptureStopSignalPath) {
            $model['CaptureStopSignalPath'] = $CaptureStopSignalPath
        }

        # The cadence, read from the dropdown rather than assumed. Emitted even when it equals
        # the entry point's own default, because the command line in the box is the record of
        # what was run - a reader six months later should not have to know what the default
        # was in this build to know how often the machine was sampled.
        $interval = ConvertTo-TlcCaptureIntervalSeconds -Text $(
            if ($Element.Contains('CaptureIntervalBox') -and $Element.CaptureIntervalBox.SelectedItem) {
                # Tag is the number; Content is the translated words around it.
                $picked = $Element.CaptureIntervalBox.SelectedItem
                if ($picked.PSObject.Properties['Tag'] -and $picked.Tag) { [string]$picked.Tag }
                elseif ($picked.PSObject.Properties['Content']) { [string]$picked.Content }
                else { [string]$picked }
            } else { '' })
        $model['CaptureIntervalSeconds'] = $interval

        <#
            THE TICK IS THE DECISION, because the packet capture is the one deeper capture
            this toolbox starts. Start-TlcDeepCapture runs pktmon and nothing else, so
            -DeepCapture is a choice about that one capability and the operator can clear it
            for a run that should not leave a machine-wide trace running.

            It was briefly inferred from a count of available capabilities instead. That
            emitted the switch whenever ANY of the three could run, including when the two it
            does not control were the available ones.
        #>
        if ($Element.Contains('DeepCaptureBox') -and $Element.DeepCaptureBox.IsChecked) {
            $model['DeepCapture'] = $true
        }
    }

    # The Validate button means "plan it, change nothing". That is not a stage of its own: it is
    # a switch on whichever stage the chosen path runs. Gathering plans a Collect; the live path
    # plans a Capture. Rewriting the stage here is what used to make the live path silently
    # validate the other job.
    if ($Stage -eq 'Validate-Only') {
        if ($Fork -ne 'Capture') { $model.Stage = 'Collect' }
        $model.ValidationOnly = $true
    }

    return $model
}

function Show-TlcDetailWindow {
    <#
    .SYNOPSIS
        Shows the shared detail window for a dashboard tile.
    .DESCRIPTION
        A tile has room for four words and its tooltip has room for a sentence. What sits
        behind the number - which crashes, which folder, what the tunnel actually is -
        needs a scrollable body, so every tile opens the same window with different
        content rather than six near-identical ones.

        ActionText and Action are optional and drive the second button. When there is
        nothing to do beyond reading, the button stays collapsed rather than appearing
        disabled - a greyed-out control invites a hunt for the thing that would enable it.

        Facts is an optional ordered dictionary rendered as a real two-column layout above
        the prose. Before it existed, callers lined names up by padding them with spaces,
        which reads correctly only in a monospace font - and that was half the reason the
        body was monospace, which in turn made every explanatory sentence look like
        console output. Structured data goes in Facts; sentences and paths go in Body.

        Monospace switches the body to a fixed-width font. It is off by default because
        almost everything here is prose, and on for exactly one caller: the equivalent
        command, which is a command line and the one thing in the wizard that genuinely is
        code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Owner,
        [Parameter(Mandatory)] [string] $ToolboxRoot,
        [Parameter(Mandatory)] [string] $ThemePath,
        [Parameter(Mandatory)] [string] $Heading,
        [AllowEmptyString()] [string] $Summary = '',
        [AllowEmptyString()] [string] $Body = '',
        [System.Collections.IDictionary] $Facts,
        [switch] $Monospace,
        [string] $ActionText,
        [scriptblock] $Action,
        # Passed in rather than read here so a detail window cannot end up with a different
        # title bar from the wizard that opened it, if Windows' theme changed in between.
        [bool] $Dark
    )

    $detailWindow = Import-TlcXaml -Path (Join-Path (Join-Path $ToolboxRoot 'Ui') 'Detail.xaml') -ThemePath $ThemePath
    $detailElement = Get-TlcUiElement -Root $detailWindow -Name @(
        'DetailHeading', 'DetailSummary', 'DetailBody', 'DetailFacts', 'DetailSeparator',
        'DetailActionButton'
    )

    $detailWindow.Title = "TLC Toolbox - $Heading"
    $detailElement.DetailHeading.Text = $Heading
    $detailElement.DetailSummary.Text = $Summary
    $detailElement.DetailBody.Text = $Body

    if ($Monospace) {
        $detailElement.DetailBody.FontFamily = $detailWindow.FindResource('MonoFont')
    }

    # Rows are built here rather than bound in XAML. PowerShell objects bind to WPF
    # through PSObject's type descriptor and the failure mode when it does not take is a
    # silently empty panel, which is exactly the kind of quiet wrong this dashboard is
    # supposed to avoid. Constructing the elements is a few more lines and cannot fail
    # invisibly.
    if ($Facts -and $Facts.Count -gt 0) {
        $rowIndex = 0
        foreach ($key in $Facts.Keys) {
            $value = [string]$Facts[$key]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }

            $null = $detailElement.DetailFacts.RowDefinitions.Add(
                (New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

            $name = New-Object System.Windows.Controls.TextBlock
            $name.Text = [string]$key
            $name.Style = $detailWindow.FindResource('CaptionText')
            $name.Margin = New-Object System.Windows.Thickness 0, 0, 16, 6
            $name.VerticalAlignment = 'Top'
            [System.Windows.Controls.Grid]::SetRow($name, $rowIndex)
            [System.Windows.Controls.Grid]::SetColumn($name, 0)
            $null = $detailElement.DetailFacts.Children.Add($name)

            $text = New-Object System.Windows.Controls.TextBlock
            $text.Text = $value
            $text.Style = $detailWindow.FindResource('BodyText')
            $text.TextWrapping = 'Wrap'
            $text.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
            [System.Windows.Controls.Grid]::SetRow($text, $rowIndex)
            [System.Windows.Controls.Grid]::SetColumn($text, 1)
            $null = $detailElement.DetailFacts.Children.Add($text)

            $rowIndex++
        }

        if ($rowIndex -gt 0) {
            $detailElement.DetailFacts.Visibility = 'Visible'
            # The rule only earns its place when there is prose underneath it to divide.
            if (-not [string]::IsNullOrWhiteSpace($Body)) {
                $detailElement.DetailSeparator.Visibility = 'Visible'
            }
        }
    }

    if ($ActionText -and $Action) {
        $detailElement.DetailActionButton.Content = $ActionText
        $detailElement.DetailActionButton.Visibility = 'Visible'
        $detailElement.DetailActionButton.Add_Click({
            try {
                & $Action
            } catch {
                Write-TlcToolLog -Message 'A detail window action failed.' -Level 'WARN' -ErrorRecord $_
            }
        }.GetNewClosure())
    }

    # Escape closes. The Close button used to supply this through IsCancel, and removing
    # the button would have taken keyboard dismissal with it - a regression nobody would
    # notice until they tried to close the window without a mouse.
    $detailWindow.Add_KeyDown({
        param($src, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $detailWindow.Close() }
    }.GetNewClosure())

    $detailWindow.Owner = $Owner
    $detailWindow.Add_SourceInitialized({
            $null = Set-TlcWindowDarkChrome -Window $detailWindow -Dark $Dark
        }.GetNewClosure())
    $null = $detailWindow.ShowDialog()
}

function Get-TlcCrashDetail {
    <#
    .SYNOPSIS
        The crash events behind the dashboard count, one block each.
    .DESCRIPTION
        The tile says how many. The question immediately after is always which, and until
        now the answer meant opening Event Viewer and rebuilding the same filter by hand.

        Application 1000 carries the faulting module and offset in its inserted properties,
        which is the part that actually identifies a crash - two crashes with the same
        count and different faulting modules are two different problems.

        Labels are written as "Name: value" rather than padded out to a common width. The
        padded form only lines up in a monospace font, and the detail window is no longer
        monospace - it renders prose in the same proportional face as the rest of the
        wizard, where trailing spaces produce ragged columns rather than aligned ones.

        -Strings is the window's resolved string table. Without it the text is English,
        which is what a caller outside the window (a test, a transcript) wants. The event
        message itself is quoted as Windows wrote it and is never translated here.
    #>
    [CmdletBinding()]
    param(
        [int] $Hours = 24,
        [string] $Match = 'ms-teams|Teams|MSTeams',
        [hashtable] $Strings
    )

    $say = {
        param([string] $Key, [string] $English, [object[]] $Arguments)
        $template = if ($Strings) { Get-TlcString -Table $Strings -Key $Key } else { $English }
        if ($template -eq $Key) { $template = $English }
        if ($null -eq $Arguments) { return $template }
        try { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $template, $Arguments) }
        catch [System.FormatException] { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $English, $Arguments) }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            Id = @(1000, 1001)
            StartTime = (Get-Date).AddHours(-$Hours)
        } -ErrorAction Stop | Where-Object { $_.Message -match $Match })
    } catch {
        # By error id as well as by text: the message is localized, so on a German or Japanese
        # Windows the English match missed and "no crashes" read as "could not be read"
        # (review 2026-09-30).
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match 'No events were found') {
            return (& $say 'CrashDetailNone' 'No Teams crash events in the Application log over the last {0} hours.' @($Hours))
        }
        return (& $say 'CrashDetailUnreadable' 'The Application log could not be read: {0}' @($_.Exception.Message))
    }

    if ($events.Count -eq 0) {
        return (& $say 'CrashDetailNone' 'No Teams crash events in the Application log over the last {0} hours.' @($Hours))
    }

    foreach ($crash in ($events | Sort-Object TimeCreated -Descending)) {
        $lines.Add((& $say 'CrashDetailHeader' '{0}   {1}, event {2}' @($crash.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $crash.ProviderName, $crash.Id)))

        # Positions 0-3 of a 1000 record are the faulting application name, version,
        # timestamp and then the faulting module. Read defensively: 1001 has an entirely
        # different shape, and a truncated record has fewer properties than expected.
        $properties = @($crash.Properties | ForEach-Object { [string]$_.Value })
        if ($crash.Id -eq 1000 -and $properties.Count -ge 5) {
            $lines.Add('    ' + (& $say 'CrashDetailApplication' 'Faulting application: {0} {1}' @($properties[0], $properties[1])))
            $lines.Add('    ' + (& $say 'CrashDetailModule' 'Faulting module: {0} {1}' @($properties[3], $properties[4])))
        }

        $message = ($crash.Message -replace '\s+', ' ').Trim()
        if ($message.Length -gt 300) { $message = $message.Substring(0, 300) + '...' }
        $lines.Add("    $message")
        $lines.Add('')
    }

    return ($lines -join [Environment]::NewLine)
}

function Show-TlcWizard {
    <#
    .SYNOPSIS
        Opens the guided collection window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolboxRoot
    )

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'The wizard needs an STA thread. Start it with Start-TlcToolbox.ps1, which handles this.'
    }

    $catalog = @(Get-TlcScenarioCatalog)

    # The theme follows the OS unless the operator has overridden it in Settings. Following
    # the system is the default, because an engineer who has already told Windows which they
    # want should not have to say it again in every tool - but a shared or imaged machine is
    # not always set the way the person at it would like, which is why the override exists.
    $uiFolder = Join-Path $ToolboxRoot 'Ui'

    # The appearance preference, read before the theme is resolved.
    #
    # Wrapped and defaulted, for the same reason the language read is: a preference file is
    # not worth failing to open the tool over, and 'System' is exactly what the toolbox did
    # before this setting existed - so an unreadable file behaves like no file at all.
    $themeChoice = 'System'
    try { $themeChoice = [string](Get-TlcSettings).Theme } catch {
        Write-Verbose "Settings unreadable; following the system theme. $($_.Exception.Message)"
    }

    $themeArgs = @{ LightThemePath = (Join-Path $uiFolder 'Theme.xaml') }
    if ($themeChoice -eq 'Dark') { $themeArgs['ForceDark'] = $true }
    elseif ($themeChoice -eq 'Light') { $themeArgs['ForceLight'] = $true }

    # Derived from the CHOICE, not from Test-TlcDarkMode.
    #
    # $isDark picks the wordmark variant and the chevron opacity, and those have to match the
    # theme actually in use. Reading the OS here would have put the dark wordmark - drawn in
    # near-black navy, effectively invisible on white - onto a light window whenever an
    # operator forced Light on a machine set to Dark. The two came from the same source while
    # there was only one source; they do not any more.
    $isDark = switch ($themeChoice) {
        'Dark'  { $true }
        'Light' { $false }
        default { Test-TlcDarkMode }
    }

    $themePath = Get-TlcThemePath @themeArgs
    $window = Import-TlcXaml -Path (Join-Path $uiFolder 'Wizard.xaml') -ThemePath $themePath

    # The wizard gets its own tool log, because until now it had none at all.
    #
    # Write-TlcToolLog returns immediately when no log has been opened, and a log is only
    # opened by Initialize-TlcRun - which happens in the CHILD process that performs a run,
    # never in this one. So every failure handler in this file wrote to nowhere: $protect
    # logged nothing, and so did the progress timer's catch. Combined with $protect's window
    # report being swallowed if $element is unreachable, a UI-thread exception here had no
    # route to any log, any file or the screen.
    #
    # That is not hypothetical. A null $window inside $finish threw on every single run for a
    # day, and the only symptom anywhere was a status line blaming the progress timer.
    #
    # It lives in temp rather than beside the runs on purpose. This is diagnostics about the
    # TOOL, not evidence about the customer: it must exist before any run folder does - which
    # is the whole point, since the failures it catches happen outside a run - the run root
    # may not be writable yet, and it must never be swept into a bundle.
    #
    # One file per window, because two wizards open at once would interleave into a shared
    # one and neither would be readable. That accumulates, so the older ones are pruned here:
    # unbounded growth in temp is untidy, and a folder full of near-identical files is also
    # the fastest way to make the one that matters hard to find.
    #
    # Failure to open the log must not stop the window opening: a tool that will not start is
    # worse than one that is hard to debug.
    try {
        # The process id as well as the second: two windows opened in the same second shared
        # one file, and the second header overwrote the first (review 2026-09-30).
        $uiLogPath = Join-Path ([System.IO.Path]::GetTempPath()) ("TLC-wizard-{0}-{1}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture), $PID)
        $null = Start-TlcToolLog -Path $uiLogPath -Context 'TLC-Toolbox wizard'
        Write-TlcToolLog -Message "Wizard opened. Theme: $(if ($isDark) { 'dark' } else { 'light' })."

        # Whether this process carries the toolbox's taskbar identity: the first thing to know
        # when an operator reports the window grouped with PowerShell, or named after it on the
        # taskbar. None is expected when the wizard was opened from a console, because the
        # launcher sets it only in a process of its own. Finding 341.
        $taskbarIdentity = Get-TlcProcessAppId
        Write-TlcToolLog -Message "Taskbar identity: $(if ($taskbarIdentity) { $taskbarIdentity } else { 'none, so the window groups with PowerShell' })."

        # Newest kept, and never the one just opened. Pruning is best-effort: a log held open
        # by another wizard simply stays. Anything younger than a fortnight stays too, so a
        # burst of launches cannot delete a recent log (finding 327).
        $older = @(Select-TlcStaleWizardLog -Log @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'TLC-wizard-*.log' -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -ne $uiLogPath }))
        foreach ($stale in $older) { Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction SilentlyContinue }
        if ($older.Count -gt 0) { Write-TlcToolLog -Message "Pruned $($older.Count) wizard log(s) older than the most recent ten and more than 14 days old, or past the 100 kept." }
    } catch {
        Write-Verbose "The wizard tool log could not be opened: $($_.Exception.Message)"
    }

    $element = Get-TlcUiElement -Root $window -Name @(
        'BannerImage', 'ChevronImage', 'ScenarioBox', 'LaneText', 'CaseBox', 'UserBox',
        'ConsentBox', 'ConsentHintText', 'ConsentMeBox', 'ConsentMeText',
        'ImpactDate', 'ImpactTimeBox', 'TimeHintText', 'BeforeBox', 'AfterBox', 'WindowUnitBox',
        'DeepCapabilityPanel', 'DeepCapabilityHeading', 'DeepCapabilityList', 'ElevateButton',
        'DeepCaptureBox', 'DeepCaptureReason',
        'SkipPromptedBox', 'CaptureIntervalBox', 'CaptureIntervalHint',
        'PathChooser', 'GatherPathButton', 'LivePathButton', 'PathUnavailableHint',
        'GatherPanel', 'LivePanel', 'SharedOptionsPanel', 'GatherOnlyOptions',
        'CapturePhasePanel', 'CapturePhaseArm', 'CapturePhaseReproduce', 'CapturePhaseCollect', 'CapturePhaseDetail',
        'ValidationOnlyBox', 'DeviceBox', 'DeviceHintText',
                'OutputBox', 'OutputHintText',
        'CommandBox', 'CancelButton', 'SkipSupportButton', 'LogBox', 'LogView', 'LogPanel', 'RunProgress', 'RunStatusText',
        'LiveChartPanel', 'LiveChartCaption', 'LiveRttPath', 'LiveRttValue', 'LiveMemoryPath', 'LiveMemoryValue',
        'LiveNetworkValues', 'SupportActionPanel', 'SupportActionText', 'SupportResultText', 'GenerateSupportButton', 'LiveProgressText',
        'LiveStaticPanel', 'ShowLiveGraphBox', 'LiveRttKey', 'LiveMemoryKey', 'LiveChartAnimationHint',
        'LiveRttHeading', 'LiveMemoryHeading', 'LiveRttContext',
        'LiveMemoryContext', 'LiveRttPassLegend', 'LiveRttWarningLegend', 'LiveRttBlockedLegend',
        'LiveMemoryPassLegend', 'LiveMemoryWarningLegend', 'LiveMemoryBlockedLegend', 'LiveMemoryNeutralLegend',
        'GatherPathSelected', 'LivePathSelected', 'GatherPathOutline', 'LivePathOutline',
        'LiveRttMaximum', 'LiveRttMiddle', 'LiveRttMinimum', 'LiveRttTimeStart', 'LiveRttTimeMiddle', 'LiveRttTimeEnd',
        'LiveMemoryMaximum', 'LiveMemoryMiddle', 'LiveMemoryMinimum', 'LiveMemoryTimeStart', 'LiveMemoryTimeMiddle', 'LiveMemoryTimeEnd',
        'LiveProgressRow',
        'RunLoadingPanel', 'RunLoadingText', 'RunLoadingSpinner',
        'StopProgressPanel', 'StopProgressTitle', 'StopProgressActivity', 'StopProgressDetail',
        'StopSamplingText', 'StopLogsText', 'StopSupportText', 'StopFinalizeText',
        'ForgetCaseButton', 'CaseHintText',
        'ClientTile', 'ClientValue', 'LogsTile', 'LogsValue',
        'RetentionTile', 'RetentionValue', 'ActivityTile', 'ActivityValue',
        'CrashTile', 'CrashValue', 'CoverageTile', 'CoverageValue',
        'NetworkTile', 'NetworkValue', 'UpdateTile', 'UpdateValue', 'SignInTile', 'SignInValue',
        'MetricAgeText',
        'ToolChoiceBanner', 'ToolChoiceValue', 'ToolChoiceDetail',
        'ScenarioAdvisoryBanner', 'ScenarioAdvisoryValue', 'ScenarioAdvisoryDetail',
        'AudioAdvisoryButton', 'AudioAdvisoryText',
        'FormPanel', 'RunSummaryPanel', 'SummaryScenario', 'SummaryCase', 'SummaryUser', 'SummaryWindow', 'SummaryWarning',
        'SummaryConsentRow', 'SummaryConsentLabel', 'SummaryConsentBox', 'SummaryConsentSave', 'SummaryConsentMeBox', 'SummaryConsentMeText', 'SummaryDeepCapture',
        'EndpointBox', 'EndpointHintText',
        'AdminCenterLink', 'AdminCenterLinkHost', 'HeaderLinks', 'LinkSeparator', 'ComparisonLink', 'ToolChoiceDetailRun', 'ToolChoiceDismiss', 'ScenarioAdvisoryDismiss', 'RunProgressHeader',
        'SettingsButton', 'HeaderBanner', 'ActionFooter', 'FooterCommandGroup',
        'WhatHappenedHeading', 'WhatHappenedToggle', 'WhatHappenedSummary', 'WhatHappenedBody',
        'ScenarioLabel', 'CaseNumberLabel', 'AffectedUserLabel', 'ConsentLabel',
        'PathChooserHeading', 'PathChooserCaption', 'GatherHeading', 'ImpactTimeLabel',
        'ImpactAtLabel', 'WindowLabel', 'BeforeLabel', 'AfterLabel',
        'LiveHeading', 'LiveCaption', 'SampleEveryLabel', 'OptionsHeading',
        'RoomsDeviceLabel', 'EndpointsLabel', 'OutputFolderLabel',
        'ClientCaption', 'LogsCaption', 'RetentionCaption', 'ActivityCaption', 'CrashCaption',
        'CoverageCaption', 'NetworkCaption', 'UpdateCaption', 'SignInCaption',
        'SummaryScenarioLabel', 'SummaryCaseLabel', 'SummaryUserLabel', 'SummaryWindowLabel',
        'ProgressHeading', 'ImpactWindowRow',
        'ValidateButton', 'CollectButton', 'PackageButton', 'OpenButton'
    )

    # Keep the live recommendation controls, but host their card only in Feature comparison.
    $null = $element.ToolChoiceBanner.Parent.Children.Remove($element.ToolChoiceBanner)

    # The last line of defence. Every handler is meant to be wrapped, and one that was not -
    # Activated - threw inside WM_ACTIVATE whenever a tile's detail window was closed more than
    # 30 seconds after the last gather. The process ended with nothing in any log: Windows
    # Error Reporting recorded 0xe0434352 and 0xc000041d and the window simply vanished
    # (finding 328). See New-TlcWindowExceptionHandler.
    $window.Dispatcher.add_UnhandledException((New-TlcWindowExceptionHandler -Element $element))

    # Two pieces of one banner. Either can be missing without stopping the window -
    # Set-TlcUiBanner reports that rather than throwing, because a decoration must not
    # be able to prevent the tool it decorates from opening.
    #
    # The wordmark has a dark variant because the artwork's title is near-black navy,
    # drawn for a white page and effectively invisible on a dark header.
    #
    # The chevrons have one asset for both, but not one opacity: the dark header is darker
    # than the light one, so the same pale lavender reads harder against it. See
    # Get-TlcChevronOpacity for the measurements.
    $wordmark = if ($isDark) { 'TLC-Wordmark-Dark.png' } else { 'TLC-Wordmark.png' }
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $ToolboxRoot 'Assets') $wordmark))) {
        $wordmark = 'TLC-Wordmark.png'
    }

    $null = Set-TlcUiBanner -Image $element.BannerImage -ToolboxRoot $ToolboxRoot -FileName $wordmark
    $null = Set-TlcUiBanner -Image $element.ChevronImage -ToolboxRoot $ToolboxRoot -FileName 'TLC-Chevrons.png'
    $element.ChevronImage.Opacity = Get-TlcChevronOpacity -Dark $isDark

    # Display language. Read before anything is shown, so the window opens in the chosen
    # language rather than flashing English first.
    #
    # Wrapped, because a preference file is not worth failing to open the tool over: an
    # unreadable or hand-edited Settings.json falls back to English, and the window still
    # opens. Get-TlcSettings already validates the tag against the tables that ship, so an
    # edited file naming a language with no table cannot produce a window of key names.
    $language = 'en-US'
    try { $language = [string](Get-TlcSettings).Language } catch {
        Write-Verbose "Settings unreadable; opening in English. $($_.Exception.Message)"
    }
    $strings = Get-TlcStringTable -Language $language -ToolboxRoot $ToolboxRoot 3>&1 |
        ForEach-Object {
            # Warnings from the loader carry the reason a table did not load, and a windowed
            # process has no console for them to reach. Routed into the tool log so the file a
            # customer sends back explains a window full of key names.
            if ($_ -is [System.Management.Automation.WarningRecord]) {
                Write-TlcToolLog -Message ([string]$_.Message) -Level 'WARN'
            } else { $_ }
        }
    if ($strings -isnot [hashtable]) { $strings = @{} }
    Set-TlcWizardString -Element $element -Strings $strings

    # Recorded because the failure mode is silent by design. A missing table renders every
    # label as its own key name, which looks like a rendering fault rather than a lookup
    # miss, and the tool log is the only place that can say which of the two it was.
    Write-TlcToolLog -Message ("Display language {0}; {1} string(s) loaded from {2}." -f `
        $language, $strings.Keys.Count, (Get-TlcLanguagePath -Language $language -ToolboxRoot $ToolboxRoot))

    $configPath = Join-Path (Join-Path $ToolboxRoot 'Config') 'TeamsLogCollection.config.psd1'
    $config = $null
    try {
        $config = Import-TlcConfig -ConfigPath $configPath
        $config = Merge-TlcLocalConfig -Config $config -LocalPath (Get-TlcLocalConfigPath -ToolboxRoot $ToolboxRoot)
        # The same two overlays the entry point applies, in the same order. Finding 323.
        $config = Merge-TlcLocalConfig -Config $config -LocalPath (Get-TlcUserConfigPath)
    } catch {
        Write-Verbose "Wizard could not read the configuration: $($_.Exception.Message)"
    }

    # Whether THIS machine is itself a Teams Rooms device.
    #
    # It decides what the Rooms hint should say, and the honest answer matters because a blank
    # box is not inert: TLC-Toolbox.ps1 resolves the endpoint as
    # `if ($TargetDevice) { $TargetDevice } else { $env:COMPUTERNAME }`, so leaving it empty
    # collects from the machine the wizard is running on. On a room console that is exactly
    # right and saves typing the device's own name; on an engineer's laptop it is a run that
    # will stop at the "not a Rooms device" blocker. The operator could not tell which case
    # they were in, because the hint said only "Host name or FQDN of the device."
    #
    # Same pattern as the output hint below - say what a blank box actually does, read from the
    # config rather than written into the markup, so it cannot promise a path the tool no longer
    # uses. One Test-Path, so it is free on the UI thread.
    $localIsRoomsDevice = $false
    if ($config -and $config.Rooms) {
        try {
            $rigelRoot = Resolve-TlcPath -Path ([string]$config.Rooms.RigelRoot)
            if ($rigelRoot) { $localIsRoomsDevice = [bool](Test-Path -LiteralPath $rigelRoot) }
        } catch {
            Write-Verbose "The Rooms root could not be checked: $($_.Exception.Message)"
        }
    }

    # Say where a blank box actually sends the run, read from the config rather than
    # written into the markup, so the hint cannot promise a path the tool no longer
    # uses. A failure to read it is not worth blocking the window for.
    $configuredRunRoot = ''
    if ($config) {
        $configuredRoot = Resolve-TlcPath -Path ([string]$config.RunRoot)
        if ($configuredRoot) {
            $element.OutputBox.Tag = $configuredRoot
            $configuredRunRoot = [string]$configuredRoot
        }
    }
    $element.OutputHintText.Text = if ($configuredRunRoot) {
        Get-TlcString -Table $strings -Key 'OutputHintBlank' -Argument @($configuredRunRoot)
    } else {
        Get-TlcString -Table $strings -Key 'OutputHintCreated'
    }

    # One answer to "what is the consent situation", used by the startup hint, the Collect
    # warning and the Package picker. Three copies of this would eventually disagree, and the
    # copy that disagreed with the privacy gate would promise something the gate then denied.
    #
    # Reads the same two settings the gate reads. The typed value wins over the configured one
    # because it is the more recent statement about this engagement.
    $consentState = {
        $required = $true
        if ($config -and $config.Contains('Privacy') -and $config.Privacy.Contains('RequireConsent')) {
            $required = [bool]$config.Privacy.RequireConsent
        }

        $configured = ''
        if ($config -and $config.Contains('Privacy') -and $config.Privacy.Contains('ConsentGrantedBy')) {
            $configured = [string]$config.Privacy.ConsentGrantedBy
        }

        $typed = ''
        try { $typed = Get-TlcWizardConsent -Element $element } catch { $typed = '' }

        $granted = if ($typed) { $typed } else { $configured }
        return [pscustomobject]@{
            Required   = $required
            Configured = $configured
            Granted    = $granted
            Missing    = ($required -and -not $granted)
        }
    }

    $consentMissing = { return (& $consentState).Missing }

    # Consent state is said at startup, not discovered at Package time. The gate refuses a
    # bundle while this is blank, and an operator who only learns that after collecting has
    # already spent the customer's time. Configured consent is named so nobody types a second
    # authorisation over one an engagement already recorded.
    $startupConsent = & $consentState
    # Held as a key and its arguments rather than as text, so the language-change handler can
    # say the same thing in the new language. It was an English literal at first, and then
    # English text kept for that handler to put back; both left a configured consent in
    # English in a translated window. Found rendering Tamil, 2026-10-01; finding 334.
    $consentHintOverride = if (-not $startupConsent.Required) { @{ Key = 'ConsentNotRequired' } }
                           elseif ($startupConsent.Configured) { @{ Key = 'ConsentConfigured'; Args = @($startupConsent.Configured) } }
                           else { $null }
    $element.ConsentHintText.Text = if ($consentHintOverride) {
        Get-TlcString -Table $strings -Key $consentHintOverride.Key -Argument $consentHintOverride.Args
    } else {
        Get-TlcString -Table $strings -Key 'ConsentHint'
    }

    # Said now, not when the background probe lands. The endpoint box ships disabled, and a
    # greyed box with no explanation reads as a fault - which is exactly what a live window
    # showed at startup, an empty hint beside a dead control. Readiness takes three system
    # reads and runs off the UI thread, so the honest placeholder is that it is still being
    # worked out; the metric callback replaces this with what is actually missing.
    # The version, in the title bar. Costs nothing and is the one place a build number is
    # legible without opening a dialog - which is what would have settled the 2026-09-22
    # cycle where a fix was reported as broken by an operator holding the previous build.
    # Failure leaves the title as the markup set it, because a missing version must not
    # stop the window opening.
    try {
        $manifest = Import-TlcDataFile -Path (Join-Path $ToolboxRoot 'Tlc.psd1')
        if ($manifest.ModuleVersion) { $window.Title = "$($window.Title)  $($manifest.ModuleVersion)" }
    } catch {
        Write-Verbose "The window title version could not be read: $($_.Exception.Message)"
    }

    $element.EndpointHintText.Text = Get-TlcString -Table $strings -Key 'EndpointHintChecking'

    # The empty state is markup now rather than seeded text. An empty console-grey panel
    # at rest reads as something that failed to load, so saying what has not happened yet
    # and what the two run buttons do costs nothing - but it is guidance, not transcript,
    # and it used to be rendered as monospace console output inside the log box, with the
    # names padded out with spaces to line up. It is a two-column grid in Wizard.xaml now,
    # swapped for the transcript the moment a run starts.

    Initialize-TlcWizardScenarioList -Element $element -Catalog $catalog -Strings $strings

    # The repro window the form opens with, held in variables rather than repeated as
    # literals further down, because the impact time is now seeded RELATIVE to the after
    # window and the two drifting apart is exactly what put the default window in the
    # future.
    #
    # SEEDED FROM CONFIG, because the entry point already honours these keys and the
    # wizard did not. TLC-Toolbox.ps1 falls back to Scope.ReproWindowBeforeMinutes when
    # the parameter is absent - but the wizard always passes the parameter explicitly, so
    # a configured window was silently overridden by a hardcoded 30 for anyone driving the
    # tool through the window rather than the command line. The setting is documented in
    # configuration.md, which made it worse: it read as inert rather than as ignored.
    #
    # A value that is missing, unparseable or negative falls back to 30 rather than
    # failing. This runs while the window is being built, and a malformed local overlay
    # should not be able to stop the toolbox opening.
    $defaultBeforeMinutes = 30
    $defaultAfterMinutes = 30
    if ($config -and $config.Contains('Scope')) {
        $parsed = 0
        if ([int]::TryParse([string]$config.Scope.ReproWindowBeforeMinutes, [ref]$parsed) -and $parsed -ge 0) {
            $defaultBeforeMinutes = $parsed
        }
        $parsed = 0
        if ([int]::TryParse([string]$config.Scope.ReproWindowAfterMinutes, [ref]$parsed) -and $parsed -ge 0) {
            $defaultAfterMinutes = $parsed
        }
    }

    # THE IMPACT TIME DEFAULTS TO THE AFTER-WINDOW AGO, NOT TO NOW.
    #
    # Seeded to now, the default window ran from now-30 to now+30 and the Window tile
    # opened on "Ends in the future" on every single package job - a warning about the
    # form's own defaults, before the operator had touched anything. A tile that is amber
    # every time teaches people to ignore it, which costs the times it means something.
    #
    # Backing the impact off by the after-window makes the window end at the current
    # minute instead. The HH:mm box truncates the seconds away, so the end lands a few
    # seconds in the PAST rather than exactly on the boundary - measured at 21:41:00
    # against a clock reading 21:41:48, which reads as Covered rather than Ends in the
    # future.
    #
    # The DATE comes from the same shifted value, not from today. Subtracting thirty
    # minutes at 00:10 lands on yesterday, and seeding today's date beside a 23:40 time
    # would produce a window twenty-four hours from where the operator expects it.
    $seededImpact = (Get-Date).AddMinutes(-$defaultAfterMinutes)
    $element.ImpactDate.SelectedDate = $seededImpact.Date
    $element.ImpactTimeBox.Text = $seededImpact.ToString('HH:mm')

    # The affected user, defaulted to whoever is running the toolbox.
    #
    # In most collections the person at the keyboard IS the affected user, and an empty field
    # is a field that gets left empty - which costs the bundle its subject. Scope.AffectedUser
    # exists precisely because a blank user is silently unrecoverable later, and a default that
    # is right most of the time is better than a blocker that fires every time.
    #
    # Whether it is still the DEFAULT is tracked, not just the text. Two things need to know
    # the difference: the case-history restore below, which brings back the user recorded
    # against a remembered case and previously only fired into an empty box, and anything
    # later that wants to distinguish "nobody chose this" from "somebody typed it". Without
    # the flag, seeding the field would have silently disabled the restore - turning a feature
    # that prevents mislabelling into one that cannot fire.
    $defaultUser = ''
    try { $defaultUser = Get-TlcCurrentUserUpn } catch {
        Write-Verbose "The affected user could not be defaulted: $($_.Exception.Message)"
    }
    if ($defaultUser) { $element.UserBox.Text = $defaultUser }

    # The same account, offered as a consent checkbox that is never ticked for the operator.
    # No account means no checkbox: the typed field is the fallback and keeps the whole row.
    Set-TlcWizardConsentAccount -Element $element -Account $defaultUser -Strings $strings

    $element.BeforeBox.Text = [string]$defaultBeforeMinutes
    $element.AfterBox.Text = [string]$defaultAfterMinutes

    # The deeper captures, answered BEFORE the run rather than reported after it.
    #
    # Each row is a disabled checkbox: ticked for a capture that will run, empty for one
    # that will not, with the reason beside it. The shape is the message - an empty greyed
    # box next to "Not available because the toolbox is not running as administrator" says
    # in one glance what three lines in a transcript said an hour too late.
    #
    # Built once, at startup. Elevation and the presence of pktmon, netsh and logman do not
    # change while the window is open, and re-reading them on every scenario change would
    # spend work to produce the same answer.
    $buildDeepCapability = {
        param([hashtable] $Table, [bool] $KeepTick)
        if (-not $Table) { $Table = $state.Strings }
        $element.DeepCapabilityList.Children.Clear()

        $options = @()
        try {
            $options = @(Get-TlcDeepCaptureOption -OutputPath ([System.IO.Path]::GetTempPath()))
        } catch {
            Write-Verbose "The deep-capture options could not be read: $($_.Exception.Message)"
        }

        if (@($options).Count -eq 0) {
            $element.DeepCapabilityPanel.Visibility = 'Collapsed'
            # Cleared as well as hidden. A hidden panel whose box is still ticked would emit
            # -DeepCapture for a capability the run could not even enumerate.
            $element.DeepCaptureBox.IsChecked = $false
            return
        }

        $available = @($options | Where-Object { $_.Available }).Count

        <#
            THE PACKET CAPTURE IS THE ONLY ONE THE TOOLBOX STARTS.

            Start-TlcDeepCapture runs pktmon and nothing else, so -DeepCapture is a decision
            about this one capability. The tick therefore means "this will run", it can be
            cleared for a run that does not want a machine-wide trace, and the model reads it
            directly rather than inferring intent from a count.
        #>
        $packet = @($options | Where-Object { $_.Name -eq 'PacketCapture' }) | Select-Object -First 1
        $packetReady = [bool]($packet -and $packet.Available)

        $element.DeepCaptureBox.IsEnabled = $packetReady
        # A redraw for a language change keeps the operator's tick; only a capture that can no
        # longer run is cleared.
        if (-not $KeepTick) { $element.DeepCaptureBox.IsChecked = $packetReady }
        elseif (-not $packetReady) { $element.DeepCaptureBox.IsChecked = $false }
        if ($packetReady -or -not $packet) {
            $element.DeepCaptureReason.Visibility = 'Collapsed'
        } else {
            $element.DeepCaptureReason.Text = Get-TlcDeepCaptureReasonText -Option $packet -Table $Table
            $element.DeepCaptureReason.Visibility = 'Visible'
        }

        <#
            THE RESTART BUTTON, SHOWN ONLY WHEN IT WOULD CHANGE THE ANSWER.

            Offered when elevation is the thing standing in the way - not merely when
            something is unavailable. pktmon missing from the image is not fixed by
            reopening as administrator, and a button that promises to fix it would send the
            operator through a UAC prompt and a lost form to arrive at the same panel.

            Get-TlcIsElevated rather than parsing the reason text: the reason is a translated
            sentence and matching on its words would break in every language but English.
        #>
        $elevated = $true
        try { $elevated = Get-TlcIsElevated } catch {
            Write-Verbose "Elevation could not be read, so the reopen button stays hidden: $($_.Exception.Message)"
        }

        # Only an option whose tool is present can be unblocked by rights. Counting every
        # unavailable option offered the button on a machine where the only thing missing was
        # a tool (review 2026-09-30, finding 331).
        $fixableByRights = @($options | Where-Object { -not $_.Available -and $_.ToolPresent })
        $blockedByRights = (-not $elevated) -and ($fixableByRights.Count -gt 0)
        $element.ElevateButton.Visibility = if ($blockedByRights) { 'Visible' } else { 'Collapsed' }

        $element.DeepCapabilityHeading.Text = Get-TlcString -Table $Table -Key 'DeepCaptureCount' -Argument @($available, @($options).Count)

        <#
            THE MANUAL ONES, AS A REPORT RATHER THAN AS CONTROLS.

            Everything except the packet capture is a command the operator runs by hand -
            Get-TlcDeepCaptureOption says so itself, and nothing in this toolbox starts them.
            They were previously drawn as checkboxes, which promised both that they would run
            and that the tick could be changed. Neither was true, and it was reported as
            exactly that: "cant uncheck the boxes. plus they dont look quite right".

            A TextBlock with a leading marker cannot be mistaken for a control, and it cannot
            be clicked at, so there is nothing to explain.
        #>
        # Titles by the option's invariant name; an option this list does not know keeps its own.
        $optionKey = @{ PacketCapture = 'DeepOptionPacketCapture'; NetshTrace = 'DeepOptionNetshTrace'; EtwSession = 'DeepOptionEtwSession' }
        foreach ($option in @($options | Where-Object { $_.Name -ne 'PacketCapture' })) {
            $title = if ($optionKey.ContainsKey([string]$option.Name)) { Get-TlcString -Table $Table -Key $optionKey[[string]$option.Name] } else { [string]$option.Title }
            $row = New-Object System.Windows.Controls.TextBlock
            $row.Text = [string]::Join('', [char[]](0x2022, 0x20)) + $title
            $row.Style = $window.FindResource('CaptionText')
            $row.TextWrapping = 'Wrap'
            $row.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            # Both halves: what it would answer, and the command that produces it. The
            # command is the actionable part and belongs where it can be copied from.
            $row.ToolTip = "$([string]$option.Answers)`r`n`r`n$([string]$option.Command)"
            $row.Foreground = $window.FindResource($(
                if ($option.Available) { 'TextPrimaryBrush' } else { 'TextSecondaryBrush' }))
            $null = $element.DeepCapabilityList.Children.Add($row)

            if (-not $option.Available) {
                $why = New-Object System.Windows.Controls.TextBlock
                $why.Text = Get-TlcDeepCaptureReasonText -Option $option -Table $Table
                $why.Style = $window.FindResource('CaptionText')
                $why.TextWrapping = 'Wrap'
                $why.Margin = New-Object System.Windows.Thickness 14, 0, 0, 2
                $null = $element.DeepCapabilityList.Children.Add($why)
            }
        }

        # Said once, above the list, rather than repeated on every row.
        if (@($element.DeepCapabilityList.Children).Count -gt 0) {
            $caption = New-Object System.Windows.Controls.TextBlock
            $caption.Text = Get-TlcString -Table $Table -Key 'DeepCaptureManualCaption'
            $caption.Style = $window.FindResource('CaptionText')
            $caption.TextWrapping = 'Wrap'
            $element.DeepCapabilityList.Children.Insert(0, $caption)
        }
    }
    & $buildDeepCapability $strings $false
    # ComboBoxItems rather than bare strings, so the displayed text can be translated while
    # Tag keeps the invariant token Get-TlcWizardModel matches on. Bare strings made the
    # display text and the value the same thing, which is fine in one language only.
    #
    # Labelled from the table the window opened with. Set-TlcWizardString ran above, before
    # these items existed, so English literals here opened every saved non-English window with
    # its units in English until the language was changed again. Found rendering Tamil,
    # 2026-10-01: the unit box read "Minut" in a window otherwise in Tamil.
    foreach ($unit in 'minutes', 'hours') {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Tag = $unit
        $item.Content = Get-TlcString -Table $strings -Key $(if ($unit -eq 'minutes') { 'UnitMinutes' } else { 'UnitHours' })
        $null = $element.WindowUnitBox.Items.Add($item)
    }
    $element.WindowUnitBox.SelectedIndex = 0

    # --- case memory --------------------------------------------------------
    # Remembered cases fill the drop-down; the box stays editable so a new case can be
    # typed over them. Nothing is selected by default - starting a run against whatever
    # case happened to be used last is exactly the mislabelling this is meant to avoid.
    $refreshCaseHistory = {
        param([hashtable] $Table)
        if (-not $Table) { $Table = $state.Strings }
        $remembered = @(Get-TlcCaseHistory)
        $typed = [string]$element.CaseBox.Text

        $element.CaseBox.Items.Clear()
        foreach ($entry in $remembered) { $null = $element.CaseBox.Items.Add($entry.CaseNumber) }

        $element.CaseBox.Text = $typed
        $element.ForgetCaseButton.IsEnabled = ($remembered.Count -gt 0)

        $element.CaseHintText.Text = if ($remembered.Count -eq 0) {
            Get-TlcString -Table $Table -Key 'CaseHintBlank'
        } else {
            Get-TlcString -Table $Table -Key 'CaseHintRemembered' -Argument @($remembered.Count)
        }
    }
    # Given the startup table explicitly: this first call comes before the wizard state that
    # every later call reads the current table from.
    & $refreshCaseHistory $strings

    # Picking a remembered case brings its affected user back with it, because the two
    # were recorded together and retyping one without the other is how a bundle ends up
    # labelled for the wrong person.
    #
    # SelectedItem is also copied into Text explicitly. An editable ComboBox does not
    # reliably push the selection into its text buffer before the change handlers read
    # it, so the model was seeing an empty case box on the very tick where the user had
    # just chosen a case - producing a command with the affected user filled in and no
    # -CaseNumber at all.
    $element.CaseBox.Add_SelectionChanged({
        $picked = [string]$element.CaseBox.SelectedItem
        if (-not $picked) { return }

        if ($element.CaseBox.Text -ne $picked) { $element.CaseBox.Text = $picked }

        $match = @(Get-TlcCaseHistory | Where-Object { $_.CaseNumber -eq $picked })
        if ($match.Count -gt 0 -and $match[0].AffectedUser) {
            # Overrides the seeded default, but never something the operator typed.
            #
            # The condition used to be "-not $element.UserBox.Text", which stopped working the
            # moment the field was seeded with the current user: the box is never empty now, so
            # the restore would have silently stopped firing and a remembered case would come
            # back labelled for whoever was at the keyboard. That is the exact mislabelling
            # this restore exists to prevent, so the test is against the DEFAULT rather than
            # against emptiness.
            $current = [string]$element.UserBox.Text
            if (-not $current -or $current -eq $defaultUser) {
                $element.UserBox.Text = $match[0].AffectedUser
            }
        }
    })

    $entryPoint = Join-Path $ToolboxRoot 'TLC-Toolbox.ps1'
    # RunTimer holds the dispatcher timer that polls a running collection. It lives here
    # rather than in the run handler's own scope because a DispatcherTimer referenced only
    # by a local is unreachable the moment that handler returns, and a collected timer
    # stops ticking silently - the child finishes while the window waits for ever.
    $state = [ordered]@{ CorrelationId = ''; RunPath = ''; UpdateHistory = $null; RunTimer = $null; RunProcess = $null; RunCancelled = $false; CaptureStopAcknowledged = $false; CollectVisibility = 'Collapsed'; SessionRuns = @(); PackageQueue = @(); PackageDone = @(); PackageRefused = @(); PackageZip = $false; RunStage = $null; RunFork = $null; RunValidationOnly = $false; Fork = $null; Language = 'en-US'; Theme = 'System'; CapturePhase = $null; CapturePhaseSince = $null; CaptureSamples = 0; CaptureSignal = (Join-Path ([System.IO.Path]::GetTempPath()) ("tlc-capture-{0}.signal" -f [guid]::NewGuid().ToString('N').Substring(0,8))); ZipSessionRuns = $null; MeetingAddin = $null; RunStarted = $null; RunSpoke = $false; Platform = $null; Audio = $null; Power = $null; WebViewCrash = $null; Cache = $null; Tls = $null; SignIn = $null; FleetReadiness = $null; MetricShell = $null; MetricHandle = $null; MetricTimer = $null; MetricBusy = $false; MetricGatheredAt = $null; BannerSignature = @{}; BannerDismissed = @{}; ConsentHintOverride = $consentHintOverride; ConfiguredRunRoot = $configuredRunRoot; RunScenarioId = $null; RunModel = $null }

    # Seeded from what was actually read at startup, not left on the defaults.
    #
    # $state is built here, long after the preference file is read near the top of this
    # function, and the settings window takes its CURRENT selection from $state. Leaving these
    # on their defaults meant a window correctly rendered in Spanish opened its own settings
    # dialog with English selected - the dialog reported the default rather than the state,
    # and picking Spanish again would then have been a no-op that saved nothing.
    $state.Language = $language
    $state.Theme = $themeChoice
    # The table itself, for handlers that re-render text after the window is built. Seeded here
    # and replaced whenever the language changes, so a re-render always uses the CURRENT
    # language rather than the one the window happened to open in.
    $state.Strings = $strings
    $state.LiveSamples = @()
    $state.LiveSampleStartedUtc = ''
    $state.LiveChartIntervalSeconds = 5
    $state.LiveChartCenters = @{ Rtt = $null; Memory = $null }
    $state.LiveMemoryPreview = $null
    $state.RunStopRequested = $false
    $state.RunWaitKey = ''
    $state.RunWaitSince = $null
    $state.RunWorkStage = ''
    $state.FormattingTranscript = $false
    $element.LogBox.Add_TextChanged({
        if ($state.FormattingTranscript) { return }
        $state.FormattingTranscript = $true
        try {
            Update-TlcTranscriptView -View $element.LogView -Text $element.LogBox.Text -Strings $state.Strings
        } catch {
            Write-TlcToolLog -Message 'Transcript formatting failed; displaying the preserved plain text.' -Level 'WARN' -ErrorRecord $_
            $element.LogView.Document.Blocks.Clear()
            $paragraph = [System.Windows.Documents.Paragraph]::new(
                [System.Windows.Documents.Run]::new($element.LogBox.Text + "`r`nTranscript formatting failed: " + $_.Exception.Message))
            $element.LogView.Document.Blocks.Add($paragraph)
        } finally {
            $state.FormattingTranscript = $false
        }
    }.GetNewClosure())
    if (-not @([System.Windows.Media.Fonts]::SystemFontFamilies | Where-Object { $_.Source -eq 'Aptos' }).Count) {
        Write-TlcToolLog -Message 'Aptos is not installed; the transcript uses its Segoe UI fallback.' -Level 'INFO'
    }
    $state.SupportWaitingSince = $null
    $state.SupportPhase = 'Generating'

    # Which of the three capture phases is live, and what the operator should be doing in it.
    #
    # The phases are named on screen because a capture run looks exactly like a gather run from
    # outside - same bar, same log - while asking something completely different of the person
    # watching. There is a window, opening after warm-up and closing when they press Stop,
    # during which the fault has to actually happen; miss it and the session faithfully records
    # a machine behaving perfectly.
    #
    # Only the live phase is drawn in the foreground colour. Three equally-weighted labels would
    # be a diagram of the process rather than an answer to "what am I meant to be doing now".
    $setCapturePhase = {
        param([string] $Phase)

        $state.CapturePhase = $Phase
        $state.CapturePhaseSince = Get-Date

        $labels = @{
            Arm       = $element.CapturePhaseArm
            Reproduce = $element.CapturePhaseReproduce
            Collect   = $element.CapturePhaseCollect
        }
        foreach ($name in $labels.Keys) {
            $labels[$name].Foreground = if ($name -eq $Phase) {
                $window.FindResource('AccentBrush')
            } else {
                $window.FindResource('TextSecondaryBrush')
            }
        }

        & $renderCapturePhaseDetail
    }

    # The sentence under the phase labels, from the current phase and table. Separate so a
    # language change can redraw it without restarting the phase clock.
    $renderCapturePhaseDetail = {
        $element.CapturePhaseDetail.Text = switch ([string]$state.CapturePhase) {
            'Arm'       { Get-TlcString -Table $state.Strings -Key 'PhaseDetailArm' }
            'Reproduce' { Get-TlcString -Table $state.Strings -Key 'PhaseDetailReproduce' }
            # Names the Teams prompt rather than leaving it in the log.
            #
            # Stop run ends the recording, but not the run: the Prompted lane then asks for
            # Teams' own support files, and that ask can sit there for ten minutes. An operator
            # who has just pressed Stop reasonably expects to be finished, and a phase panel
            # saying "writing the summary" while the log quietly says ACTION REQUIRED is the
            # exact mismatch this panel exists to prevent.
            'Collect'   { Get-TlcString -Table $state.Strings -Key 'PhaseDetailCollect' }
            'Finished'  { $element.RunStatusText.Text }
            default     { '' }
        }
    }


    $renderSupportAction = {
        $key = switch ($state.SupportPhase) {
            'Generating' { 'SupportAutoGenerating' }
            'Waiting' { 'SupportAutoWaiting' }
            'Settling' { 'SupportAutoSettling' }
            'Copying' { 'SupportAutoCopying' }
            default { 'SupportActionText' }
        }
        $element.SupportActionText.Text = Get-TlcString -Table $state.Strings -Key $key
        $element.GenerateSupportButton.Visibility = if ($state.SupportPhase -eq 'Fallback') { 'Visible' } else { 'Collapsed' }
        $element.GenerateSupportButton.IsEnabled = $state.SupportPhase -eq 'Fallback'
        $element.SupportActionPanel.Background = $window.FindResource(
            $(if ($state.SupportPhase -eq 'Fallback') { 'WarningSurfaceBrush' } else { 'NeutralSurfaceBrush' }))
        $element.SupportActionPanel.BorderBrush = $window.FindResource(
            $(if ($state.SupportPhase -eq 'Fallback') { 'WarningBrush' } else { 'BorderStrongBrush' }))
    }.GetNewClosure()

    # One dismissal rule, used by both banners.
    #
    # Dismissal is remembered against WHAT was dismissed rather than THAT something was. Both
    # banners are recomputed on every scenario change and every dashboard refresh, so a
    # boolean would either be overwritten on the next refresh - making the button look dead -
    # or, if checked before showing, would suppress every later banner of that kind too.
    # Suppressing the next one is the worse failure and the silent one: it hides advice the
    # reader has never seen.
    #
    # Keyed on the rendered text rather than on a scenario id, so an advisory that changes
    # because the machine changed also counts as new and earns its space again.
    $showBanner = {
        param([string] $Key, $Banner, [string] $Signature)
        $state.BannerSignature[$Key] = $Signature
        $Banner.Visibility = if ($state.BannerDismissed[$Key] -eq $Signature) { 'Collapsed' } else { 'Visible' }
    }

    # Paired with $showBanner: the handler records the signature that was on screen when the
    # button was pressed, rather than recomputing it and risking dismissing something else.
    # It collapses the banner here as well, because nothing guarantees a refresh follows a
    # click - without that the button would do nothing visible until the next scenario change.
    $dismissBanner = {
        param([string] $Key, $Banner)
        $state.BannerDismissed[$Key] = [string]$state.BannerSignature[$Key]
        $Banner.Visibility = 'Collapsed'
    }

    # --- dashboard ----------------------------------------------------------
    # Status names map to the theme's existing brush pairs, so a red tile here is
    # the same red as a blocked finding in EPO rather than a second colour language.
    $tileBrush = @{
        Pass    = @{ Border = 'PassBrush';    Fill = 'PassSurfaceBrush';    Ink = 'PassBrush' }
        Warning = @{ Border = 'WarningBrush'; Fill = 'WarningSurfaceBrush'; Ink = 'WarningBrush' }
        Blocked = @{ Border = 'BlockedBrush'; Fill = 'BlockedSurfaceBrush'; Ink = 'BlockedBrush' }
        Neutral = @{ Border = 'NeutralBrush'; Fill = 'NeutralSurfaceBrush'; Ink = 'TextSecondaryBrush' }
    }

    # The last metric each tile was given, so a click can show what is behind the number
    # without recomputing it - and so the detail window cannot disagree with the tile it
    # was opened from.
    $tileMetric = @{}

    $setTile = {
        param($Tile, $Value, $Metric)

        $key = if ($tileBrush.ContainsKey($Metric.Status)) { $Metric.Status } else { 'Neutral' }
        $brush = $tileBrush[$key]

        $Tile.BorderBrush = $window.FindResource($brush.Border)
        $Tile.Background = $window.FindResource($brush.Fill)
        $Value.Foreground = $window.FindResource($brush.Ink)
        # Drawn in the window's language; the metric itself stays English, because its value
        # is compared and logged by code that must not change with the display language.
        $Value.Text = Get-TlcTileText -Text ([string]$Metric.Value) -Table $state.Strings

        # The tooltip carries the sentence the tile has no room for. A four-word
        # value is only actionable if the reason behind it is one hover away.
        $Tile.ToolTip = Get-TlcMetricDetail -Metric $Metric -Table $state.Strings

        if ($Tile.Name) { $tileMetric[$Tile.Name] = $Metric }
    }

    # Every tile with the control its value is drawn in, so a language change can redraw the
    # dashboard from the metrics it already holds rather than measuring again.
    $tilePairs = @(
        @{ Tile = $element.ClientTile;    Value = $element.ClientValue }
        @{ Tile = $element.LogsTile;      Value = $element.LogsValue }
        @{ Tile = $element.RetentionTile; Value = $element.RetentionValue }
        @{ Tile = $element.ActivityTile;  Value = $element.ActivityValue }
        @{ Tile = $element.CrashTile;     Value = $element.CrashValue }
        @{ Tile = $element.CoverageTile;  Value = $element.CoverageValue }
        @{ Tile = $element.NetworkTile;   Value = $element.NetworkValue }
        @{ Tile = $element.UpdateTile;    Value = $element.UpdateValue }
        @{ Tile = $element.SignInTile;    Value = $element.SignInValue }
    )
    $renderTiles = {
        foreach ($pair in $tilePairs) {
            if ($tileMetric.ContainsKey([string]$pair.Tile.Name)) {
                & $setTile $pair.Tile $pair.Value $tileMetric[[string]$pair.Tile.Name]
            } else {
                $pair.Value.Text = Get-TlcString -Table $state.Strings -Key 'TileChecking'
            }
        }
    }
    & $renderTiles

    # Which console to be at, recomputed whenever one of its inputs changes. Reads the
    # tiles' own metrics rather than recomputing them, so the banner cannot contradict the
    # dashboard it sits above.
    #
    # Deliberately styled Neutral in both directions. The theme's Pass green means "this
    # machine is healthy", and a green banner saying "collect here" would read as a health
    # verdict rather than the routing advice it is.
    $refreshToolChoice = {
        $scenarioForChoice = Get-TlcWizardSelectedScenario -Element $element -Catalog $catalog
        if (-not $scenarioForChoice) {
            $element.ToolChoiceBanner.Visibility = 'Collapsed'
            $element.AdminCenterLinkHost.Visibility = 'Collapsed'
            $element.LinkSeparator.Visibility = 'Collapsed'
            return
        }

        $choice = $null
        try {
            $choice = Get-TlcToolChoice -Scenario $scenarioForChoice `
                -SignIn    $tileMetric['SignInTile'] `
                -Client    $tileMetric['ClientTile'] `
                -Retention $tileMetric['RetentionTile'] `
                -Platform  $state.Platform `
                -FleetReadiness $state.FleetReadiness
        } catch {
            # Routing advice must never be able to stop the window working. A banner that
            # cannot be computed is simply not shown.
            Write-Verbose "Tool choice could not be worked out: $($_.Exception.Message)"
            $choice = $null
        }

        if (-not $choice) {
            $element.ToolChoiceBanner.Visibility = 'Collapsed'
            return
        }

        # Drawn from the keys the choice carries, in the window's language. Value and Detail stay
        # the English the signature below is made of, so changing language neither shows a
        # dismissed banner again nor dismisses one nobody has read.
        $element.ToolChoiceValue.Text = if ($choice.Contains('ValueKey')) {
            Get-TlcString -Table $state.Strings -Key $choice.ValueKey
        } else { [string]$choice.Value }
        $element.ToolChoiceBanner.BorderBrush = $window.FindResource('NeutralBrush')
        $element.ToolChoiceBanner.Background = $window.FindResource('NeutralSurfaceBrush')
        $element.ToolChoiceValue.Foreground = $window.FindResource('TextPrimaryBrush')

        # The links live in the header banner's bottom-right corner now, left of the chevrons,
        # not inside this card. Only their visibility is decided here.
        #
        # They were moved out of the header once on the argument that a link belongs where the
        # reader decides to act on the advice, and moved back after three attempts to place them
        # inside the card - stacked under the sentence, inline at the end of it, and in a second
        # Grid column - each of which either left a gap that read as a carriage return or
        # surrendered the right edge. The header has the room the card does not.
        #
        # The admin center link stays conditional rather than becoming a permanent header
        # fixture: a standing "collect from the admin center" beside a scenario with no remote
        # route would be wrong, not merely noisy.
        #
        # The separator collapses with the link it separates. A lone "Feature comparison"
        # preceded by a bar reads as a missing item rather than a tidy row.
        $wantsLink = ($choice.Choice -eq 'AdminCenter')
        # A part that names the scenario names it as the list does, in the window's language.
        $scenarioShown = Get-TlcScenarioDisplayName -Scenario $scenarioForChoice -Table $state.Strings
        $element.ToolChoiceDetailRun.Text = if ($choice.Contains('DetailParts')) {
            @($choice.DetailParts | ForEach-Object {
                $arguments = @($_['Args'] | ForEach-Object { if ([string]$_ -ceq [string]$scenarioForChoice.Name) { $scenarioShown } else { $_ } })
                Get-TlcString -Table $state.Strings -Key $_.Key -Argument $arguments
            }) -join ' '
        } else { [string]$choice.Detail }

        $linkVisibility = if ($wantsLink) { 'Visible' } else { 'Collapsed' }
        $element.AdminCenterLinkHost.Visibility = $linkVisibility
        $element.LinkSeparator.Visibility = $linkVisibility

        # Dismissal is keyed on the advice itself. See $showBanner for why a boolean here
        # would either be overwritten by the next refresh or suppress the opposite verdict.
        & $showBanner 'ToolChoice' $element.ToolChoiceBanner ('{0}|{1}' -f $choice.Value, $choice.Detail)
    }

    # A precondition that bears on the selected scenario. Separate from the tool-choice
    # banner because it answers a different question: not "which console", but "here is a
    # thing already visible on this machine that would explain the report".
    #
    # Scenario-gated on purpose. A disabled Outlook add-in has nothing to do with a network
    # trace, and a warning that appears when it is irrelevant is a warning people learn to
    # scroll past.
    $refreshScenarioAdvisory = {
        $scenarioForAdvisory = Get-TlcWizardSelectedScenario -Element $element -Catalog $catalog
        $element.AudioAdvisoryButton.Visibility = 'Collapsed'
        $element.AudioAdvisoryButton.Tag = $null
        $element.ScenarioAdvisoryValue.Visibility = 'Visible'
        $element.ScenarioAdvisoryDetail.Visibility = 'Visible'

        $show = $false
        $signature = ''
        # What the advice IS, independent of the language it is shown in, so a language change
        # neither brings back an advisory that was dismissed nor counts as new advice.
        $identity = ''
        $say = $state.Strings
        try {
            # Ordered, first match wins, most consequential first.
            #
            # The platform advisory outranks the add-in one because it is about whether the
            # evidence exists here at all, not about a cause worth checking. It is also not
            # scenario-gated: on VDI the media logs are somewhere else regardless of what the
            # engineer came to collect.
            if ($state.Platform -and $state.Platform.IsVirtualDesktop) {
                $element.ScenarioAdvisoryValue.Text = Get-TlcString -Table $say -Key 'AdvisoryVdiHeading'
                $element.ScenarioAdvisoryDetail.Text = Get-TlcPlatformAdvisoryText -Platform $state.Platform -Strings $say
                $identity = 'Vdi|' + (Get-TlcPlatformAdvisoryText -Platform $state.Platform)
                $element.ScenarioAdvisoryBanner.BorderBrush = $window.FindResource('WarningBrush')
                $element.ScenarioAdvisoryBanner.Background = $window.FindResource('WarningSurfaceBrush')
                $element.ScenarioAdvisoryValue.Foreground = $window.FindResource('WarningBrush')
                $show = $true
            }
            # MeetingJoin only. The add-in is what puts the Teams button in Outlook, so a
            # disabled one is a direct cause of "I cannot create a Teams meeting" - and is
            # unrelated to every other scenario in the catalog.
            elseif ($scenarioForAdvisory -and $scenarioForAdvisory.Id -eq 'MeetingJoin' -and $state.MeetingAddin -and
                $state.MeetingAddin.Status -ne 'Success') {
                # The heading is the add-in's own name, and the detail is the collector's
                # finding; both stay as written, the way the scenario names do.
                $element.ScenarioAdvisoryValue.Text = 'Teams Meeting Add-in'
                $element.ScenarioAdvisoryDetail.Text = "$($state.MeetingAddin.Detail) $($state.MeetingAddin.Remediation)".Trim()
                $identity = 'Addin|' + $element.ScenarioAdvisoryDetail.Text
                $element.ScenarioAdvisoryBanner.BorderBrush = $window.FindResource('WarningBrush')
                $element.ScenarioAdvisoryBanner.Background = $window.FindResource('WarningSurfaceBrush')
                $element.ScenarioAdvisoryValue.Foreground = $window.FindResource('WarningBrush')
                $show = $true
            }
            # CallQuality only, and ordered ahead of power because a missing or errored
            # endpoint is a definite cause where a power scheme is a contributory one.
            #
            # Deliberately NOT raised for the Rooms, RoomsAndroid or CviRoomSegment
            # scenarios: those are about an appliance in a room, and the audio endpoints
            # measured here belong to the machine the toolbox is running on. Reporting this
            # machine's microphone while the engineer is investigating a room console would
            # be a confident answer to a question nobody asked.
            elseif ($scenarioForAdvisory -and $scenarioForAdvisory.Id -eq 'CallQuality' -and $state.Audio -and
                $state.Audio.Available -and
                ($state.Audio.CaptureCount -eq 0 -or $state.Audio.UnhealthyCount -gt 0)) {
                $element.ScenarioAdvisoryValue.Text = Get-TlcString -Table $say -Key 'AdvisoryAudioHeading'
                if ($state.Audio.CaptureCount -eq 0) {
                    $element.ScenarioAdvisoryDetail.Text = Get-TlcString -Table $say -Key 'AdvisoryAudioNone'
                    $identity = 'Audio|none'
                } else {
                    $names = @($state.Audio.Unhealthy | ForEach-Object { "$($_.Name) [$($_.Status)]" }) -join '; '
                    $element.ScenarioAdvisoryDetail.Text = Get-TlcString -Table $say -Key 'AdvisoryAudioUnhealthy' -Argument @($state.Audio.UnhealthyCount)
                    $identity = "Audio|$($state.Audio.UnhealthyCount)|$names"
                }
                $facts = [ordered]@{}
                foreach ($device in @($state.Audio.Unhealthy)) {
                    $typeProperty = ([pscustomobject]$device).PSObject.Properties['DeviceType']
                    $deviceType = if ($typeProperty -and $typeProperty.Value) { [string]$typeProperty.Value } else { Get-TlcString -Table $say -Key 'TileUnknown' }
                    $facts["$($facts.Count + 1)."] = "$($device.Name)`r`n$(Get-TlcString -Table $say -Key 'AdvisoryAudioType'): $deviceType`r`n$(Get-TlcString -Table $say -Key 'FactStatus'): $($device.Status)"
                }
                $element.AudioAdvisoryButton.Tag = @{
                    Heading = $element.ScenarioAdvisoryValue.Text
                    Summary = $element.ScenarioAdvisoryDetail.Text
                    Body = (Get-TlcString -Table $say -Key 'AdvisoryAudioDisplayNote') + "`r`n`r`n" + (Get-TlcString -Table $say -Key 'AdvisoryAudioAdvice')
                    Facts = $facts
                }
                $element.AudioAdvisoryText.Text = "$($element.ScenarioAdvisoryValue.Text): $($element.ScenarioAdvisoryDetail.Text) $(Get-TlcString -Table $say -Key 'AdvisoryAudioOpen')"
                $element.AudioAdvisoryButton.Visibility = 'Visible'
                $element.ScenarioAdvisoryValue.Visibility = 'Collapsed'
                $element.ScenarioAdvisoryDetail.Visibility = 'Collapsed'
                $element.ScenarioAdvisoryBanner.BorderBrush = $window.FindResource('WarningBrush')
                $element.ScenarioAdvisoryBanner.Background = $window.FindResource('WarningSurfaceBrush')
                $element.ScenarioAdvisoryValue.Foreground = $window.FindResource('WarningBrush')
                $show = $true
            }
            # CallQuality only. Power saver throttles the CPU and video encoding is the first
            # thing a call notices, so this presents as poor quality on a network that
            # measures perfectly - the exact case a network-shaped bundle cannot close.
            elseif ($scenarioForAdvisory -and $scenarioForAdvisory.Id -eq 'CallQuality' -and $state.Power -and
                ($state.Power.Throttling -eq $true -or $state.Power.OnBattery -eq $true)) {
                $element.ScenarioAdvisoryValue.Text = Get-TlcString -Table $say -Key 'AdvisoryPowerHeading'
                $notes = @()
                if ($state.Power.Throttling -eq $true) {
                    $notes += Get-TlcString -Table $say -Key 'AdvisoryPowerScheme' -Argument @([string]$state.Power.PowerScheme)
                }
                if ($state.Power.OnBattery -eq $true) {
                    $notes += if ($null -ne $state.Power.ChargePercent) {
                        Get-TlcString -Table $say -Key 'AdvisoryPowerBatteryCharge' -Argument @($state.Power.ChargePercent)
                    } else {
                        Get-TlcString -Table $say -Key 'AdvisoryPowerBattery'
                    }
                }
                $notes += Get-TlcString -Table $say -Key 'AdvisoryPowerVideo'
                $element.ScenarioAdvisoryDetail.Text = ($notes -join ' ')
                $identity = "Power|$($state.Power.Throttling)|$($state.Power.PowerScheme)|$($state.Power.OnBattery)|$($state.Power.ChargePercent)"
                $element.ScenarioAdvisoryBanner.BorderBrush = $window.FindResource('WarningBrush')
                $element.ScenarioAdvisoryBanner.Background = $window.FindResource('WarningSurfaceBrush')
                $element.ScenarioAdvisoryValue.Foreground = $window.FindResource('WarningBrush')
                $show = $true
            }
            # DesktopLaunchCrash only - "Client Launch, Crash, or Performance Issue", the one
            # scenario where how long the client takes to start is the complaint.
            #
            # THE THRESHOLD IS A HEURISTIC AND SAYS SO. Microsoft publishes no size limit for
            # the Teams cache, so this cannot cite one and must not imply it exists. 2 GB is
            # the line because it is where "multi-gigabyte" starts, which is the language the
            # collector's own reference uses; the development machine measured 5,043 MB, so
            # the condition is reachable on an ordinary working machine rather than only on a
            # pathological one.
            #
            # It is deliberately phrased as something to rule out rather than as a cause. A
            # large cache is not a fault, plenty of healthy clients carry one, and a confident
            # steer on weak evidence is the failure this project cares most about. The size is
            # stated so the engineer judges it rather than being handed a verdict.
            elseif ($scenarioForAdvisory -and $scenarioForAdvisory.Id -eq 'DesktopLaunchCrash' -and $state.Cache -and
                [double]$state.Cache.TotalMB -ge 2048) {
                $gb = [math]::Round([double]$state.Cache.TotalMB / 1024, 1)
                $element.ScenarioAdvisoryValue.Text = Get-TlcString -Table $say -Key 'AdvisoryCacheHeading'
                $cacheNotes = @(Get-TlcString -Table $say -Key 'AdvisoryCacheSize' -Argument @($gb))
                if ($state.Cache.LargestFolder) { $cacheNotes += Get-TlcString -Table $say -Key 'AdvisoryCacheLargest' -Argument @([string]$state.Cache.LargestFolder) }
                $cacheNotes += Get-TlcString -Table $say -Key 'AdvisoryCacheAdvice'
                $element.ScenarioAdvisoryDetail.Text = ($cacheNotes -join ' ')
                $identity = "Cache|$gb|$($state.Cache.LargestFolder)"
                $element.ScenarioAdvisoryBanner.BorderBrush = $window.FindResource('WarningBrush')
                $element.ScenarioAdvisoryBanner.Background = $window.FindResource('WarningSurfaceBrush')
                $element.ScenarioAdvisoryValue.Foreground = $window.FindResource('WarningBrush')
                $show = $true
            }
        } catch {
            Write-Verbose "Scenario advisory could not be worked out: $($_.Exception.Message)"
            $show = $false
        }

        if ($show) {
            $signature = $identity
            & $showBanner 'ScenarioAdvisory' $element.ScenarioAdvisoryBanner $signature
        } else {
            $element.ScenarioAdvisoryBanner.Visibility = 'Collapsed'
        }
    }

    $logRoot = ''
    $logPatterns = @('MSTeams_*.log')
    $rollingPatterns = @('MSTeams_*.log')
    $stateRoot = ''
    $privacyConfig = $null
    if ($config) {
        $logRoot = Resolve-TlcPath -Path ([string]$config.Collection.ClientLogRoot)
        if ($config.Collection.ClientLogPatterns) {
            $logPatterns = @($config.Collection.ClientLogPatterns)
        }
        # The rolling subset bounds three tiles - see Get-TlcLogInventory. Falling back to
        # the full pattern list here would reintroduce the defect it exists to prevent, so
        # the fallback is the built-in default instead.
        if ($config.Collection.ClientRollingLogPatterns) {
            $rollingPatterns = @($config.Collection.ClientRollingLogPatterns)
        }
        # The sign-in tile predicts the privacy gate's account check, so it needs both the
        # state folder the accounts are recorded in and the config that decides which are
        # recognised. Passed as a plain hashtable: a runspace argument crosses a boundary
        # that will not carry anything richer.
        $stateRoot = Resolve-TlcPath -Path ([string]$config.Collection.ClientStateRoot)
        if ($config.Contains('Privacy')) {
            $privacyConfig = @{
                KnownAccountIds       = @($config.Privacy.KnownAccountIds)
                BlockOnUnknownAccount = [bool]$config.Privacy.BlockOnUnknownAccount
            }
        }
    }

    $inventory = $null
    $inventoryError = ''
    try {
        if ($logRoot) {
            $inventory = Get-TlcLogInventory -LogRoot $logRoot -Pattern $logPatterns -RollingPattern $rollingPatterns
        } else {
            $inventoryError = 'The configuration did not supply Collection.ClientLogRoot.'
        }
    } catch {
        $inventoryError = $_.Exception.Message
    }

    if ($inventory) {
        try {
            & $setTile $element.LogsTile      $element.LogsValue      (Get-TlcLogVolumeMetric -Inventory $inventory)
            & $setTile $element.RetentionTile $element.RetentionValue (Get-TlcRetentionMetric -Inventory $inventory)
            & $setTile $element.ActivityTile  $element.ActivityValue  (Get-TlcActivityMetric -Inventory $inventory)
        } catch {
            $inventoryError = $_.Exception.Message
            $inventory = $null
        }
    }

    if (-not $inventory) {
        # "No log folder" is a legitimate answer about this machine, so rendering a
        # code failure that way produces a believable lie: the tile looks like a
        # finding rather than a fault, and nothing says the number was never computed.
        # An unknown has to look unknown. This mattered - a missing manifest export
        # made every log tile read as a clean, plausible "no logs here".
        # Named for what it holds: this is the wizard's own scope, and a plain $parts here would be
        # found first by every handler that opens a window and builds its own.
        $uninspectedParts = @(New-TlcMetricText -Key 'DetailLogsUninspected' -English 'The log folder could not be inspected, so these are unknown rather than zero. {0}' -Argument @($inventoryError))
        $unavailable = [ordered]@{
            Status = 'Neutral'; Value = 'Unavailable'
            Detail = Join-TlcMetricText $uninspectedParts; DetailParts = $uninspectedParts
        }
        foreach ($pair in @(
            @{ Tile = $element.LogsTile;      Value = $element.LogsValue },
            @{ Tile = $element.RetentionTile; Value = $element.RetentionValue },
            @{ Tile = $element.ActivityTile;  Value = $element.ActivityValue },
            @{ Tile = $element.CoverageTile;  Value = $element.CoverageValue }
        )) {
            & $setTile $pair.Tile $pair.Value $unavailable
        }

        Write-Warning "Dashboard log metrics unavailable: $inventoryError"
    }

    # The time the figures above were measured at, shown because they are no longer
    # necessarily from when the window opened. A dashboard that silently re-measures is
    # worse than one that never does: the operator cannot tell whether "2 crashes" is
    # current or twenty minutes stale, and the whole point of these tiles is that they
    # are true at the moment they are read.
    $setMetricAge = {
        $element.MetricAgeText.Text = if ($state.MetricBusy) {
            Get-TlcString -Table $state.Strings -Key 'MetricMeasuring'
        } elseif ($state.MetricGatheredAt) {
            Get-TlcString -Table $state.Strings -Key 'MetricMeasuredAt' -Argument @($state.MetricGatheredAt)
        } else { '' }
    }

    # Three metrics cost far more than the rest of the dashboard put together, and all
    # are paid before the window can appear unless they are moved off the UI thread:
    #
    #   Get-TlcClientMetric      ~1.5 s, almost entirely the Appx module auto-loading.
    #                            Warm it is under 5 ms, but the wizard is a fresh process
    #                            every time, so the cold cost is the only one that matters.
    #   Get-TlcCrashMetric       ~1.7 s to read the Application log.
    #   Get-TlcNetworkPathMetric ~780 ms cold (~90 ms warm) for the fast form. It joins
    #                            them because it is under the other two either way, so it
    #                            costs the window nothing. The full form the bundle uses
    #                            costs 2.5 s, nearly all of it Get-VpnConnection, and is
    #                            deliberately not called here.
    #
    # They share one runspace and one timer rather than having three of each: the window
    # is waiting on the slowest of them either way, and more timers would be more things
    # to stop on close. All three tiles read "Checking..." until it returns.
    #
    # Polling from a DispatcherTimer keeps every control touch on the thread that owns
    # it - handing a WPF element to a background runspace is the reliable way to make
    # this crash.
    # Held as a scriptblock rather than being handed straight to AddScript, because the
    # gather now runs more than once: the window re-measures when it is reactivated, and
    # a [powershell] instance cannot be reused after EndInvoke. Each gather builds a fresh
    # one from this same script.
    $metricScript = {
        param($ModuleFolder, $LogRoot, $StateRoot, $Privacy)

        # Tlc.Collect.Desktop supplies Get-TlcAppxPackage, which Get-TlcClientMetric
        # calls. A nested module cannot see a sibling's private state, so this runspace
        # imports both files directly rather than relying on the manifest.
        #
        # Tlc.Config is here for Resolve-TlcPath, which the update-history scan uses to
        # expand a configured log root. The scan degrades to the raw path without it, but
        # importing it means a %VAR% path resolves here the same way it does everywhere
        # else rather than only working by accident when the caller pre-resolved it.
        Import-Module (Join-Path $ModuleFolder 'Tlc.Config.psm1') -Force
        # Tlc.Logging supplies Invoke-TlcNativeCommand, which Get-TlcPowerFact uses to run
        # powercfg. Omitting it does NOT fail loudly, and that was measured rather than
        # assumed: without this line the runspace returns PowerScheme = '' and the detail
        # "The active power scheme could not be read." on a machine where powercfg answers
        # exit 0 from the same session. The call throws inside Get-TlcPowerFact, its catch
        # writes a verbose line nobody reads, and a healthy machine reports a fault it does
        # not have - so the throttling advisory would never fire. Same class as the
        # Tlc.Fleet omission below.
        Import-Module (Join-Path $ModuleFolder 'Tlc.Logging.psm1') -Force -DisableNameChecking
        # Tlc.Privacy supplies Protect-TlcIdentifier, which the sign-in metric uses to mask
        # the account ids it reports. Omitting it was silent in the worst way: the metric
        # resolves the masker with Get-Command and falls back when it is absent, so every
        # undeclared id rendered as the same literal string and the detail window told the
        # operator to declare ids it then refused to distinguish. Reported from a real
        # machine on 2026-09-21. Same class as the Tlc.Logging omission above.
        Import-Module (Join-Path $ModuleFolder 'Tlc.Privacy.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $ModuleFolder 'Tlc.Collect.Desktop.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $ModuleFolder 'Tlc.Collect.Network.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $ModuleFolder 'Tlc.Ui.Metrics.psm1') -Force
        # Tlc.Fleet supplies Get-TlcFleetReadiness. A runspace sees only what it imports, and
        # omitting this did not fail loudly - the whole metric block threw, the catch swallowed
        # it, and the endpoint hint simply stayed on its "checking..." placeholder forever.
        Import-Module (Join-Path $ModuleFolder 'Tlc.Fleet.psm1') -Force -DisableNameChecking

        # The update history is returned alongside its metric so the tile's click handler
        # can show the whole transition list without rescanning a hundred launcher logs
        # on the UI thread.
        $history = if ($LogRoot) { Get-TlcClientUpdateHistory -LogRoot $LogRoot } else { $null }

        # The Crashes tile reads the Application event log, and a WebView2 renderer crash
        # does not reliably reach it. Gathered here so the tile can count both rather than
        # reporting "None" to somebody investigating a crash.
        $webView = if ($StateRoot) { Get-TlcWebViewCrashFact -StateRoot $StateRoot } else { $null }

        # The certificate chain for a Teams host, ~870 ms. Feeds the Network tile, which
        # could otherwise report "Direct" in green on a machine whose TLS sessions are
        # being terminated and re-signed by a firewall - intermediation is detected from
        # services on THIS machine, and break-and-inspect leaves none.
        $tls = Get-TlcTlsCertificateFact -HostName 'teams.microsoft.com'

        # Cache footprint, ~355 ms. A multi-gigabyte cache is a common explanation for slow
        # start - "common", not "documented": Microsoft publishes no size limit, and this
        # code must not imply one exists.
        $cache = if ($StateRoot) { Get-TlcCacheFootprint -Path $StateRoot } else { $null }

        return [ordered]@{
            Client        = Get-TlcClientMetric
            Crash         = Get-TlcCrashMetric -WebView $webView
            WebViewCrash  = $webView
            Cache         = $cache
            Tls           = $tls
            Network       = Get-TlcNetworkPathMetric -Tls $tls
            Update        = Get-TlcUpdateMetric -History $history
            SignIn        = Get-TlcSignInMetric -StateRoot $StateRoot -Privacy $Privacy
            UpdateHistory = $history
            # Read here rather than on demand: the fact costs ~535 ms of registry work, and
            # the advisory that uses it is re-evaluated on every scenario change. Doing it
            # on the UI thread would stall the window each time the dropdown moved.
            MeetingAddin  = Get-TlcMeetingAddinHealth -Addin (Get-TlcMeetingAddinFact)
            # Same reasoning as MeetingAddin, and the same trap. The platform decides both
            # the tool-choice banner and an advisory, so it is read on every scenario change;
            # doing the registry and service work on the UI thread would stall the dropdown.
            Platform      = Get-TlcPlatform
            # Same reasoning again: WinRM service, listener and domain state are three
            # separate reads, and the endpoint box's enabled state depends on them.
            FleetReadiness = Get-TlcFleetReadiness
            # The two endpoint facts from the 2026-09-16 coverage audit. Both feed a
            # scenario advisory that is re-evaluated on every dropdown change, so they are
            # read once here rather than on demand: measured at ~1540 ms for the audio
            # endpoints (Get-PnpDevice) and ~530 ms for power, which on the UI thread would
            # stall the scenario box by two seconds every time it moved. They ride the
            # existing runspace for the same reason the other three do - the window is
            # already waiting on Get-TlcClientMetric and Get-TlcCrashMetric, so these cost
            # the window nothing.
            Audio          = Get-TlcAudioDeviceFact
            Power          = Get-TlcPowerFact
        }
    }

    # The endpoint hint from the last fleet-readiness answer, in the current language. Says what
    # the feature DOES, not how to type into it: "Other endpoints / comma or line separated"
    # describes a text box, and an engineer who does not already know fleet mode exists learns
    # nothing from it - and this is the one capability that answers the admin center's "nobody
    # has to be at the machine". The readiness note and the reason it is unavailable are the
    # probe's own findings and stay as it wrote them.
    $renderEndpointHint = {
        $readiness = $state.FleetReadiness
        $element.EndpointHintText.Text = if (-not $readiness) {
            Get-TlcString -Table $state.Strings -Key 'EndpointHintChecking'
        } elseif ($readiness.Ready) {
            ((Get-TlcString -Table $state.Strings -Key 'EndpointHintReady') + ' ' + [string]$readiness.Note).Trim()
        } else {
            [string]$readiness.Detail
        }
    }

    $metricTimer = New-Object System.Windows.Threading.DispatcherTimer
    $metricTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $metricTimer.Add_Tick({
        if (-not $state.MetricHandle -or -not $state.MetricHandle.IsCompleted) { return }
        $state.MetricTimer.Stop()

        $noResult = @(New-TlcMetricText -Key 'DetailCheckNoResult' -English 'The background check did not return a result.')
        $failed = [ordered]@{
            Status = 'Neutral'; Value = 'Unavailable'
            Detail = Join-TlcMetricText $noResult; DetailParts = $noResult
        }

        try {
            $result = @($state.MetricShell.EndInvoke($state.MetricHandle))
            if ($result.Count -gt 0 -and $result[0]) {
                & $setTile $element.ClientTile  $element.ClientValue  $result[0].Client
                & $setTile $element.CrashTile   $element.CrashValue   $result[0].Crash
                & $setTile $element.NetworkTile $element.NetworkValue $result[0].Network
                & $setTile $element.UpdateTile  $element.UpdateValue  $result[0].Update
                & $setTile $element.SignInTile  $element.SignInValue  $result[0].SignIn
                $state.UpdateHistory = $result[0].UpdateHistory
                $state.MeetingAddin = $result[0].MeetingAddin
                $state.Platform = $result[0].Platform
                $state.Audio = $result[0].Audio
                $state.Power = $result[0].Power
                $state.WebViewCrash = $result[0].WebViewCrash
                $state.Cache = $result[0].Cache
                $state.Tls = $result[0].Tls
                $state.SignIn = $result[0].SignIn

                # A greyed-out box with no explanation reads as a fault, so the hint says what
                # is missing rather than only that the feature is off. "WinRM has no listener"
                # sends someone to Enable-PSRemoting; "unavailable" sends them to guess - and
                # the fix is usually somebody else's to make, so they need to know what to ask
                # for.
                $readiness = $result[0].FleetReadiness
                if ($readiness) {
                    # Kept on $state as well as applied here, because the tool-choice banner
                    # now mentions the remote route when the control is worth offering, and
                    # that banner is recomputed on every scenario change long after this.
                    $state.FleetReadiness = $readiness
                    $element.EndpointBox.IsEnabled = [bool]$readiness.Ready
                    & $renderEndpointHint
                }
            } else {                & $setTile $element.ClientTile  $element.ClientValue  $failed
                & $setTile $element.CrashTile   $element.CrashValue   $failed
                & $setTile $element.NetworkTile $element.NetworkValue $failed
                & $setTile $element.UpdateTile  $element.UpdateValue  $failed
                & $setTile $element.SignInTile  $element.SignInValue  $failed
            }
        } catch {
            $failed.DetailParts = @(New-TlcMetricText -Key 'DetailCheckFailed' -English 'The background check failed: {0}' -Argument @($_.Exception.Message))
            $failed.Detail = Join-TlcMetricText $failed.DetailParts
            & $setTile $element.ClientTile  $element.ClientValue  $failed
            & $setTile $element.CrashTile   $element.CrashValue   $failed
            & $setTile $element.NetworkTile $element.NetworkValue $failed
            & $setTile $element.UpdateTile  $element.UpdateValue  $failed
            & $setTile $element.SignInTile  $element.SignInValue  $failed
        } finally {
            # Disposed and cleared together. A second gather builds a new instance, and
            # leaving the finished one on $state would mean a stale handle that reports
            # IsCompleted forever - the tick would then re-render the previous result
            # every 250 ms instead of waiting for the new one.
            try { if ($state.MetricShell) { $state.MetricShell.Dispose() } } catch { Write-Verbose "The metric runspace could not be disposed: $($_.Exception.Message)" }
            $state.MetricShell = $null
            $state.MetricHandle = $null
            $state.MetricBusy = $false
            $state.MetricGatheredAt = Get-Date

            # The banner depends on the client and sign-in tiles, which only exist once
            # this has returned. Refreshed here as well as on form changes, or it would
            # stay blank until the user happened to touch a field. The advisory depends on
            # the add-in fact, which arrives the same way.
            #
            # Inside a catch of its own: a throw from a finally block escapes the tick, and
            # an exception that escapes a timer callback ends the process (finding 328).
            try {
                & $setMetricAge
                & $refreshToolChoice
                & $refreshScenarioAdvisory
            } catch {
                Write-TlcToolLog -Message 'Refreshing the dashboard after the background check failed.' -Level 'WARN' -ErrorRecord $_
            }
        }
    })
    $state.MetricTimer = $metricTimer

    $startMetricGather = {
        # One gather at a time. Without this an operator alt-tabbing repeatedly would
        # start a second runspace while the first was still running, and the tick handler
        # holds exactly one handle - the earlier one would be abandoned undisposed.
        if ($state.MetricBusy) { return }
        $state.MetricBusy = $true
        $element.MetricAgeText.Text = Get-TlcString -Table $state.Strings -Key 'MetricMeasuring'

        $metricShell = [powershell]::Create()
        $null = $metricShell.AddScript($metricScript).
            AddArgument((Join-Path $ToolboxRoot 'Modules')).
            AddArgument($logRoot).AddArgument($stateRoot).AddArgument($privacyConfig)
        $state.MetricShell = $metricShell
        $state.MetricHandle = $metricShell.BeginInvoke()
        $state.MetricTimer.Start()
    }

    & $startMetricGather

    # Re-measure when the window is brought back to the front.
    #
    # THE TRIGGER IS Window.Activated, not SystemEvents and not a polling timer. Both
    # alternatives were measured on both editions in an STA WPF context and rejected:
    # SystemEvents fires on a thread that is not the one owning these controls, and a
    # timer spends CPU re-reading a machine nobody is looking at. Activation is the
    # moment the answer is about to be read, which is the only moment it has to be true.
    #
    # THROTTLED, because activation is not a rare event - clicking between this window and
    # a browser raises it every time, and the gather costs about two seconds of Appx, event
    # log and PnP work. Inside the throttle the existing figures stand, which is correct:
    # they were measured seconds ago.
    #
    # WRAPPED, although it is declared before $protect exists. It runs inside WM_ACTIVATE,
    # which Windows delivers as a callback from the kernel, and an exception there does not
    # close the window - it ends the process, with nothing in any log. Closing a tile's
    # detail window more than 30 seconds after the last gather did exactly that from 0.1.18
    # to 0.1.20: the detail window's own $element hid this one, and setting MetricAgeText on
    # it threw. Finding 328.
    $window.Add_Activated({
        try {
            if ($state.MetricBusy) { return }
            if ($state.MetricGatheredAt -and
                ((Get-Date) - $state.MetricGatheredAt).TotalSeconds -lt 30) { return }
            & $startMetricGather
        } catch {
            Write-TlcToolLog -Message 'Re-measuring the dashboard when the window was activated failed.' -Level 'WARN' -ErrorRecord $_
        }
    })

    $window.Add_Closed({
        # A window closed while the check is still running would otherwise leave the
        # runspace alive and hold the process open.
        try { $state.MetricTimer.Stop() } catch { Write-Verbose 'Metric timer was already stopped.' }
        try {
            if ($state.MetricHandle -and -not $state.MetricHandle.IsCompleted) { $state.MetricShell.Stop() }
        } catch { Write-Verbose 'Metric query was already finished.' }
    })

    # Closing the window while a run is going.
    #
    # The run is a separate process, so closing the window used to leave it running with
    # nobody watching it: a collection or a package finished on its own, unseen, but a live
    # trace went on sampling the machine until its time limit, with no Stop run left to press
    # and its sentinel in TEMP (review 2026-09-30, finding 331). Now a live trace is asked to
    # stop the way Stop run asks - acknowledge, then skip the support files - and ended only
    # if it answers neither; any other run is left to finish, after saying so.
    $window.Add_Closing({
        param($source, $e)
        try {
            $process = $state.RunProcess
            if (-not $process -or $process.HasExited) { return }

            if ($state.RunFork -eq 'Capture' -and $state.CaptureSignal) {
                $answer = Show-TlcConfirmation -Owner $window `
                    -Heading (Get-TlcString -Table $state.Strings -Key 'CloseDuringTraceState') `
                    -Message (Get-TlcString -Table $state.Strings -Key 'CloseDuringTraceEffect') `
                    -Question (Get-TlcString -Table $state.Strings -Key 'CloseDuringTraceAsk') `
                    -ConfirmText (Get-TlcString -Table $state.Strings -Key 'FactYes') `
                    -CancelText (Get-TlcString -Table $state.Strings -Key 'FactNo')
                if (-not $answer) { $e.Cancel = $true; return }

                $element.RunStatusText.Text = Get-TlcString -Table $state.Strings -Key 'RunStoppingBeforeClose'
                Sync-TlcUiPaint
                $running = { -not $process.HasExited }.GetNewClosure()
                $null = Stop-TlcCaptureSession -StopSignalPath $state.CaptureSignal -IsRunning $running `
                    -TimeoutSeconds 15 -AcceptAcknowledgement -OnWait { Sync-TlcUiPaint }
                if (-not $process.HasExited) {
                    $null = Stop-TlcCaptureSession -StopSignalPath $state.CaptureSignal -IsRunning $running `
                        -TimeoutSeconds 60 -OnWait { Sync-TlcUiPaint }
                }
                if (-not $process.HasExited) {
                    try {
                        foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" -ErrorAction SilentlyContinue)) {
                            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
                        }
                    } catch { Write-Verbose "Could not enumerate the run's child processes: $($_.Exception.Message)" }
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                }
                Write-TlcToolLog -Message 'The window was closed during a live trace; the trace was stopped first.' -Level 'INFO'
            } else {
                $answer = Show-TlcConfirmation -Owner $window `
                    -Heading (Get-TlcString -Table $state.Strings -Key 'CloseDuringRunState') `
                    -Message (Get-TlcString -Table $state.Strings -Key 'CloseDuringRunEffect') `
                    -Question (Get-TlcString -Table $state.Strings -Key 'CloseDuringRunAsk') `
                    -ConfirmText (Get-TlcString -Table $state.Strings -Key 'FactYes') `
                    -CancelText (Get-TlcString -Table $state.Strings -Key 'FactNo')
                if (-not $answer) { $e.Cancel = $true; return }
                Write-TlcToolLog -Message "The window was closed during a run (process $($process.Id)); it was left to finish." -Level 'INFO'
            }
        } catch {
            $e.Cancel = $true
            Write-TlcToolLog -Message 'Checking for a run in progress when the window closed failed.' -Level 'WARN' -ErrorRecord $_
            $element.LiveProgressText.Text = "Closing could not be confirmed: $($_.Exception.Message)"
        }
    })

    $updateCommand = {
        $stage = if ($element.ValidationOnlyBox.IsChecked) { 'Validate-Only' } else { 'Collect' }
        $model = Get-TlcWizardModel -Element $element -Catalog $catalog -Stage $stage -CorrelationId $state.CorrelationId -CaptureStopSignalPath $state.CaptureSignal -Fork $(if ($state.Fork) { $state.Fork } else { 'Gather' })
        $element.CommandBox.Text = New-TlcUiCommand -Model $model -ScriptPath '.\TLC-Toolbox.ps1'

        # A time the parser could not read becomes midnight, which is a real time that
        # has real logs behind it - so the run succeeds and quietly covers the wrong
        # hour. Saying so here is the difference between a typo and a wasted collection.
        if ($null -eq (ConvertFrom-TlcWizardTimeText -TimeText $element.ImpactTimeBox.Text)) {
            $element.TimeHintText.Text = Get-TlcString -Table $state.Strings -Key 'TimeHintUnreadable'
        } else {
            # Says what the window DOES, not just how to type a time.
            #
            # "Collect", a "Stop run" button and "30 minutes after" are all the vocabulary of
            # a recorder, and together they read as "this records for 30 minutes". It does
            # not: Teams writes these logs continuously whether or not this tool exists, the
            # toolbox enables nothing, and the window only chooses which of the existing lines
            # to take. Measured - a window ten times wider changed the run by 4.7 seconds.
            #
            # The format hint stays on the same line because it is still needed and there is
            # no room for two; the error text replaces the whole line when a time will not
            # parse, which is the case that matters more.
            $element.TimeHintText.Text = Get-TlcString -Table $state.Strings -Key 'TimeHint'
        }

        # The live tile. Everything else on the dashboard can be green while the window
        # the user has actually typed sits outside the retained logs, so this is
        # recomputed on every change rather than once at startup.
        #
        # Taken from $model, not recomputed from the controls: the model is what built
        # the command in the box above, so the tile cannot end up describing a window
        # different from the one that will actually run. Skipped entirely when the
        # inventory is unknown, so "Unavailable" is not overwritten by a confident
        # answer derived from nothing.
        $coverageOverride = Get-TlcCoverageTileOverride -Model $model -PathChosen ([bool]$state.Fork)
        if ($coverageOverride) {
            & $setTile $element.CoverageTile $element.CoverageValue $coverageOverride
        } elseif ($inventory) {
            try {
                $impact = [datetime]$model.ImpactTime
                $coverage = Get-TlcCoverageMetric -Inventory $inventory `
                    -WindowStart $impact.AddMinutes(-[int]$model.WindowBeforeMinutes) `
                    -WindowEnd $impact.AddMinutes([int]$model.WindowAfterMinutes)
                & $setTile $element.CoverageTile $element.CoverageValue $coverage
            } catch {
                $parts = @(New-TlcMetricText -Key 'DetailCoverageFailed' -English 'Coverage could not be worked out: {0}' -Argument @($_.Exception.Message))
                & $setTile $element.CoverageTile $element.CoverageValue ([ordered]@{
                    Status = 'Neutral'; Value = 'Unavailable'
                    Detail = Join-TlcMetricText $parts; DetailParts = $parts
                })
            }
        }

        # The "Client updated" tile also depends on the window, and for the same reason the
        # coverage tile does: its amber state means "the update landed INSIDE the window you
        # are collecting, so the logs span two client builds".
        #
        # That state was unreachable. The tile is computed once in the metric runspace, which
        # calls Get-TlcUpdateMetric with the history and no window at all - and the function
        # only goes amber when both window bounds are bound. So the branch was dead in the
        # product while the tests passed the window explicitly and kept it green, and
        # wizard.md documented a behaviour that could not happen. Same shape as the missing
        # cmdlet in finding 200: the tests exercised a path the product never took.
        #
        # Recomputed here, where the window is known, and only on the gathering fork. A live
        # trace has no window for an update to land inside, so passing one would recreate the
        # exact defect the coverage override exists to prevent.
        if ($state.UpdateHistory) {
            if ($state.Fork -and [string]$model.Stage -ne 'Capture') {
                try {
                    $impact = [datetime]$model.ImpactTime
                    & $setTile $element.UpdateTile $element.UpdateValue (Get-TlcUpdateMetric -History $state.UpdateHistory `
                        -WindowStart $impact.AddMinutes(-[int]$model.WindowBeforeMinutes) `
                        -WindowEnd $impact.AddMinutes([int]$model.WindowAfterMinutes))
                } catch {
                    Write-Verbose "Update tile could not be recomputed: $($_.Exception.Message)"
                }
            } else {
                # No window in play, so the tile reports the age of the build and nothing about
                # a window - which is what it says before any path is chosen.
                & $setTile $element.UpdateTile $element.UpdateValue (Get-TlcUpdateMetric -History $state.UpdateHistory)
            }
        }

        $scenario = Get-TlcWizardSelectedScenario -Element $element -Catalog $catalog
        $isRooms = ($model.Scenario -eq 'Rooms')
        $element.DeviceBox.IsEnabled = $isRooms

        # A greyed-out box with no explanation reads as a fault. Say which scenario
        # turns it on rather than leaving the user to guess - and once it IS on, say what
        # leaving it blank will do, because blank means "this machine" rather than "nothing".
        #
        # Read from the string table, not hardcoded. RoomsDeviceHintOn and RoomsDeviceHintOff
        # existed in all ten language files and NOTHING read them: this line assigned English
        # literals, so twenty translated strings could never reach the screen. The localisation
        # suite passed throughout, because it checks that every table carries every en-US key -
        # not that any key is used.
        $hintKey = if (-not $isRooms) {
            'RoomsDeviceHintOff'
        } elseif ($localIsRoomsDevice) {
            'RoomsDeviceHintLocal'
        } else {
            'RoomsDeviceHintOn'
        }
        $element.DeviceHintText.Text = Get-TlcString -Table $state.Strings -Key $hintKey

        $element.LaneText.Text = Get-TlcString -Table $state.Strings -Key 'ScenarioHint'
        if ($scenario) {
            $element.LaneText.Text += "`r`n" + (Get-TlcString -Table $state.Strings -Key 'LaneCounts' -Argument @(
                @($scenario.Auto).Count, @($scenario.Prompted).Count, @($scenario.Manual).Count))
        }
        $element.LaneText.Foreground = $window.FindResource('TextSecondaryBrush')

        # The scenario decides whether the admin center is a route at all, so the banner
        # is re-evaluated with it rather than only when the metrics land.
        & $refreshToolChoice
        & $refreshScenarioAdvisory
    }

    # Required-field problems belong beside the field, including an unselected scenario.
    $problemHint = @{ CaseNumber = 'CaseHintText'; Scenario = 'LaneText' }
    $problemFocus = @{ CaseNumber = 'CaseBox'; Scenario = 'ScenarioBox' }

    # The problem as the window says it. Test-TlcRunRequest's Message is written for the
    # command line ("Pass -CaseNumber, or use -ValidationOnly"), which names switches an
    # operator at this form cannot see; its Key is the same problem worded for the form, and
    # the controls it names are filled in from the table, so the sentence always carries the
    # label exactly as it is shown in this language. A problem without a key in the table
    # falls back to the English rather than to a key name.
    $problemControlLabel = @{
        ProblemCaseNumber      = 'ValidationOnlyBox'
        ProblemScenarioMissing = 'WhatHappenedHeading'
    }
    $problemText = {
        param($Problem)
        $key = [string]$Problem.Key
        if (-not $key -or -not $state.Strings.ContainsKey($key)) { return [string]$Problem.Message }
        $arguments = @($Problem.Argument | Where-Object { $null -ne $_ })
        if ($problemControlLabel.ContainsKey($key)) {
            $arguments += Get-TlcString -Table $state.Strings -Key $problemControlLabel[$key]
        }
        return (Get-TlcString -Table $state.Strings -Key $key -Argument $arguments)
    }

    $showRunProblem = {
        param($Problem)

        $field = [string]$Problem.Field
        $message = & $problemText $Problem

        <#
            THE FIELD HAS TO BE ON SCREEN BEFORE ANY OF THIS MEANS ANYTHING.

            Reported 2026-09-22: "Start Trace does not successfully scroll back to the missing
            required field." Both of the fields this can complain about - the scenario and the
            case number - live inside "What happened", and choosing a job COLLAPSES that
            section. So the sequence was: press Start trace, the toolbox reports a missing case
            number, and the case box is not on the form at all.

            Focus() on a collapsed element does nothing and reports nothing. The flash then
            animated a control with no rendered size. The operator saw a button that appeared
            to do nothing, which is exactly the "the click was missed" reading the flash below
            was written to prevent.

            Expand, lay out, scroll, focus - in that order. UpdateLayout is not optional:
            BringIntoView on an element that has just been made visible computes against a
            layout pass that has not happened yet and scrolls to where the element used to be.
        #>
        if ($problemFocus.ContainsKey($field)) {
            try {
                & $setWhatHappenedCollapsed $false
                $window.UpdateLayout()
            } catch {
                Write-Verbose "What happened could not be expanded for $($field): $($_.Exception.Message)"
            }
        }

        # The element that ends up carrying the message, so the flash lands on whatever the
        # operator is about to read rather than on a control chosen in advance.
        $carrier = $null

        if ($problemHint.ContainsKey($field)) {
            $hint = $element[$problemHint[$field]]
            $hint.Text = $message
            $hint.Foreground = $window.FindResource('WarningBrush')
            $carrier = $hint
        } else {
            # Unmapped, so it goes where run output goes. Silently dropping a problem because
            # no hint was wired for it would be the worst outcome here.
            $element.LogPanel.Visibility = 'Visible'
            $element.LogBox.Text = "$(Get-TlcString -Table $state.Strings -Key 'RunCannotStart')`r`n$message`r`n"
            $carrier = $element.LogView
        }

        # Pressing Collect a second time with the same problem writes the same text, which is
        # no visible change at all - the button looks dead and the reasonable conclusion is
        # that the click was missed. So the message is flashed on EVERY attempt, not only when
        # it is new.
        #
        # Opacity rather than colour: the foreground is a shared theme brush, and theme brushes
        # are frozen, so animating one throws - and if it did not, it would animate every other
        # control using that brush.
        if ($carrier) {
            try {
                $flash = New-Object System.Windows.Media.Animation.DoubleAnimation
                $flash.From = 0.15
                $flash.To = 1.0
                $flash.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220))
                $flash.AutoReverse = $true
                # THREE, asked for by name: "flash the text 3 times whenever this missing info
                # condition is met". One AutoReverse cycle is one visible flash, so the repeat
                # count is the flash count.
                $flash.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::new(3)
                # Handing back a null animation on completion returns the property to its own
                # value, so a run of flashes cannot leave the element stuck part-faded.
                $flash.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
                $carrier.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $flash)
            } catch {
                Write-Verbose "The problem could not be flashed: $($_.Exception.Message)"
            }
        }

        if ($problemFocus.ContainsKey($field)) {
            try {
                $target = $element[$problemFocus[$field]]
                # Scrolled to before it is focused. Focus alone moves the keyboard caret and
                # WPF may or may not bring the control into view depending on how it is
                # nested; BringIntoView is the part that is actually being asked for here,
                # and it scrolls the least amount needed.
                $target.BringIntoView()
                $null = $target.Focus()
            } catch {
                Write-Verbose "The control for $field could not be shown or focused: $($_.Exception.Message)"
            }
        }
    }

    # Restores whatever the hint normally says, and its normal colour. Called before every
    # attempt so a fixed problem stops being reported, and a second problem does not appear
    # underneath a stale first one.
    $clearRunProblems = {
        # Stop any flash before restoring the normal hint.
        foreach ($name in @('CaseHintText', 'LaneText')) {
            try {
                $element[$name].BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                $element[$name].Opacity = 1.0
            } catch { Write-Verbose "The $name hint animation could not be cleared." }
            $element[$name].Foreground = $window.FindResource('TextSecondaryBrush')
        }

        & $refreshCaseHistory
        & $updateCommand
    }

    # Zips the bundles a session produced into one file, for the common case of sending
    # several collections to the same support case. The bundles themselves are already
    # sealed with their own manifests; this is a carrier, not a substitute, which is why it
    # runs after packaging rather than instead of it.
    # What the privacy gate will say about this run, asked before the operator commits to a
    # selection rather than after three packages have already refused. It reads the same two
    # settings the gate reads, so it cannot promise something the gate then denies - and it
    # deliberately reports nothing when consent is present, because a banner that is always
    # there is a banner nobody reads.
    # Whether consent is missing. The fact only - callers phrase it, because the same fact
    # means different things at different moments: at Collect it is a caveat about what will
    # happen later, at Package it is the reason the next click will be refused.
    #
    # $consentMissing itself is defined with $consentState near the top, because the startup
    # hint needs the same answer before any handler exists.
    $packagePreflight = {
        if (-not (& $consentMissing)) { return '' }
        return (Get-TlcString -Table $state.Strings -Key 'PackageConsentMissing')
    }

    $zipSessionRuns = {
        param([string[]] $Path)

        $selected = @($Path | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($selected.Count -eq 0) { return $null }

        $parent = Split-Path -Parent $selected[0]
        $zipPath = Join-Path $parent ('TLC-Session-{0}.zip' -f (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture))
        try {
            return (New-TlcSessionArchive -RunPath $selected -DestinationPath $zipPath)
        } catch {
            Write-Verbose "Session zip failed: $($_.Exception.Message)"
            return $null
        }
    }

    $runStage = {
        param([string] $Stage)
        # A NEW collection must never inherit the previous one's correlation id, and Package
        # must always keep it.
        #
        # The id names the run folder. Carrying it from one Collect to the next put three
        # collections into one folder: measured 2026-09-11 on a real session where
        # CreateRunFolder fired three times, hours apart, against the same id. The evidence
        # files were overwritten each time while Blockers.csv accumulated all three runs, so
        # the bundle ended up with the last collection's logs, the last collection's window in
        # Scope.json, and twenty-six blocker rows describing three different collections. Every
        # artifact was internally consistent and the bundle as a whole described something that
        # never happened.
        #
        # Package is the opposite case: it operates ON an existing run and needs the id to find
        # it. So the id is cleared when starting new work and kept when acting on finished work.
        $correlationId = if ($Stage -eq 'Package') { $state.CorrelationId } else { '' }
        $model = Get-TlcWizardModel -Element $element -Catalog $catalog -Stage $Stage -CorrelationId $correlationId -CaptureStopSignalPath $state.CaptureSignal -Fork $(if ($state.Fork) { $state.Fork } else { 'Gather' })

        # Asked here, before anything is spawned. The same question the entry point asks, from
        # the same function, so this cannot pass a run the entry point would refuse.
        #
        # Measured 2026-09-08: without this, starting a collection with no case number took
        # 8.1 to 17.4 seconds to come back and say so - all of it process spawn and module
        # load, none of it spent discovering anything the form did not already know.
        & $clearRunProblems
        $problems = @(Test-TlcRunRequest -Scenario $model.Scenario -CaseNumber $model.CaseNumber `
                                         -ValidationOnly:([bool]$model.ValidationOnly) -Config $config)
        if ($problems.Count -gt 0) {
            & $showRunProblem $problems[0]
            return
        }

        $state.RunFork = [string]$model.Stage
        $state.RunValidationOnly = [bool]$model.ValidationOnly

        $command = New-TlcUiCommand -Model $model -ScriptPath $entryPoint

        # Coverage is a warning, never a gate. The dashboard already knows whether the
        # selected window falls inside the retained logs, and today an operator can collect a
        # window the logs do not reach and only find out afterwards.
        #
        # It does not stop the run. The inventory is a heuristic about what is on disk now,
        # and the operator may know something it does not - a second client, a copied folder,
        # a machine whose clock was wrong. Refusing a collection on that would be the
        # confident wrong answer this tool exists to avoid.
        #
        # It also cannot be shown beside the form, because the form is put away the moment the
        # run starts. It goes in the run summary, which is on screen for the whole run beside
        # a live Cancel button, and into the transcript, which is kept.
        #
        # Validate is warned too, deliberately. Validate exists to report what would stop a
        # collection being useful before anything is committed to, and a window the logs do
        # not reach is the most useful thing it could say.
        $coverage = $null
        try { if ($tileMetric.ContainsKey('CoverageTile')) { $coverage = $tileMetric['CoverageTile'] } }
        catch { $coverage = $null }

        $coverageWarning = ''
        if ($coverage -and $coverage.Status -in @('Warning', 'Blocked')) {
            $coverageWarning = Get-TlcString -Table $state.Strings -Key 'RunCoverageWarning' -Argument @(
                (Get-TlcTileText -Text ([string]$coverage.Value) -Table $state.Strings), (Get-TlcMetricDetail -Metric $coverage -Table $state.Strings))
        }

        # Consent is warned about here and gated at Package, never gated here.
        #
        # Gating Collect would be wrong: an operator may legitimately gather evidence to a
        # local folder while the customer's approval is still being obtained, and Validate
        # exists precisely to run before anything is committed to. But saying nothing is worse
        # than either - a collection can run for half an hour and only then be refused at the
        # one step that turns it into something sendable, after the customer's time is spent.
        #
        # Same treatment as the coverage warning for the same reason: on screen for the whole
        # run, and in the transcript, which is what gets kept and read afterwards.
        $warnings = @($coverageWarning | Where-Object { $_ })
        $consentIsMissing = ($Stage -ne 'Package' -and (& $consentMissing))
        if ($consentIsMissing) {
            $warnings += Get-TlcString -Table $state.Strings -Key 'RunConsentMissing'
        }
        $coverageWarning = ($warnings -join '  ')

        if ($coverageWarning) {
            $element.SummaryWarning.Text = $coverageWarning
            $element.SummaryWarning.Visibility = 'Visible'
        } else {
            $element.SummaryWarning.Visibility = 'Collapsed'
        }

        # The consent field follows the warning that asks for it. Offered only when it is
        # actually missing: a run that already has consent gets no row, and the panel keeps
        # the shape it had before this existed.
        if ($consentIsMissing) {
            $element.SummaryConsentBox.Text = ''
            if ($element.Contains('SummaryConsentMeBox') -and $element.SummaryConsentMeBox) { $element.SummaryConsentMeBox.IsChecked = $false }
            $element.SummaryConsentRow.Visibility = 'Visible'
        } else {
            $element.SummaryConsentRow.Visibility = 'Collapsed'
        }

        # The deeper captures, restated where the operator can see them WHILE recording.
        # The panel beside the checkbox is part of the form, and the form is gone by now -
        # so without this the one moment that decides whether the recording will answer the
        # question is also the one moment the answer is off screen.
        #
        # Live path only. On a gather run there is no capture session for these to attach
        # to, and a row about packet capture beside a retrospective copy would be noise.
        $element.SummaryDeepCapture.Visibility = 'Collapsed'
        if ($Stage -ne 'Package' -and $state.Fork -eq 'Capture') {
            try {
                $deep = @(Get-TlcDeepCaptureOption -OutputPath ([System.IO.Path]::GetTempPath()))
                if (@($deep).Count -gt 0) {
                    $on = @($deep | Where-Object { $_.Available })
                    $off = @($deep | Where-Object { -not $_.Available })
                    $line = if ($off.Count -eq 0) {
                        Get-TlcString -Table $state.Strings -Key 'DeepSummaryAll' -Argument @($deep.Count)
                    } elseif ($on.Count -eq 0) {
                        Get-TlcString -Table $state.Strings -Key 'DeepSummaryNone' -Argument @($deep.Count, (Get-TlcDeepCaptureReasonText -Option $off[0] -Table $state.Strings))
                    } else {
                        Get-TlcString -Table $state.Strings -Key 'DeepSummarySome' -Argument @($on.Count, $deep.Count, (($off | ForEach-Object { Get-TlcString -Table $state.Strings -Key $(switch ([string]$_.Name) { 'PacketCapture' { 'DeepOptionPacketCapture' } 'NetshTrace' { 'DeepOptionNetshTrace' } 'EtwSession' { 'DeepOptionEtwSession' } default { [string]$_.Title } }) }) -join ', '), (Get-TlcDeepCaptureReasonText -Option $off[0] -Table $state.Strings))
                    }
                    $element.SummaryDeepCapture.Text = $line
                    $element.SummaryDeepCapture.Visibility = 'Visible'
                }
            } catch {
                Write-Verbose "The deep-capture state could not be summarised: $($_.Exception.Message)"
            }
        }

        # Remember the case on use, not on typing. Recording every keystroke would fill
        # the list with half-typed fragments; a case that has actually been collected
        # against is one worth offering again.
        if ($model.CaseNumber) {
            $null = Add-TlcCaseHistoryEntry -CaseNumber $model.CaseNumber -AffectedUser $model.AffectedUser
            & $refreshCaseHistory
        }

        # First real output, so the transcript card appears. It is collapsed until now: before
        # a run there is nothing to show, and an empty bordered box reads as something that
        # failed to load.
        $element.LogPanel.Visibility = 'Visible'
        # The warning goes into the transcript too. The summary panel is on screen for the run;
        # the transcript is what gets kept and read afterwards, and a caveat that vanished when
        # the window closed would not be in the record the bundle is judged on.
        $runningLabel = Get-TlcString -Table $state.Strings -Key 'TranscriptRunning'
        $element.LogBox.Text = if ($coverageWarning) {
            "$(Get-TlcString -Table $state.Strings -Key 'TranscriptWarning') $coverageWarning`r`n`r`n$runningLabel`r`n$command`r`n`r`n"
        } else {
            "$runningLabel`r`n$command`r`n`r`n"
        }
        Sync-TlcUiPaint

        $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $temp = [System.IO.Path]::GetTempPath()
        $runner = Join-Path $temp "tlc-ui-$stamp.ps1"
        $stdout = Join-Path $temp "tlc-ui-$stamp.out"
        $stderr = Join-Path $temp "tlc-ui-$stamp.err"

        # The command goes into a script file rather than through -Command.
        #
        # The generated line is full of single-quoted arguments, and passing it as a
        # -Command string means it is quoted twice: once by Start-Process building the
        # command line and again by the child parsing it. That produced a child which
        # exited 1 having written nothing at all, which is the least debuggable failure
        # available. A script file has no quoting layer to get wrong.
        #
        # The runner keeps the run object instead of printing it: the entry point returns it,
        # which is useful at a prompt and is noise here - it would print a two-column dump of
        # run metadata under every result. Apart from that the command is the line shown in
        # the box. The run object also decides the exit code: see New-TlcUiRunnerScript.
        $script = New-TlcUiRunnerScript -Command $command
        Set-Content -LiteralPath $runner -Value $script -Encoding utf8

        $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

        # Buttons that start or consume a run are disabled while one is in flight. Two
        # concurrent collections would write into two run folders and interleave their
        # output into one transcript, and the second would look like corruption of the
        # first.
        $runButtons = @($element.ValidateButton, $element.CollectButton, $element.PackageButton, $element.OpenButton)
        $wasEnabled = @{}
        foreach ($button in $runButtons) { $wasEnabled[$button.Name] = $button.IsEnabled; $button.IsEnabled = $false }

        # The form is three sections of inputs and it sits between the dashboard and the
        # progress bar, so on a normal window the bar starts below the fold - the operator
        # has to scroll to watch the thing they just started. During a run the inputs are
        # not editable anyway, so they are replaced by two rows stating what was chosen.
        #
        # Taken from $model rather than re-read from the controls, so the summary cannot
        # describe a different run from the one that is executing. The model carries the
        # scenario Id; the catalog turns it into the name the operator picked.
        $chosenScenario = @($catalog | Where-Object { $_.Id -eq $model.Scenario })
        # Kept so a language change during the run can name it again in the new language.
        $state.RunScenarioId = [string]$model.Scenario
        $element.SummaryScenario.Text = if ($chosenScenario.Count -gt 0) {
            Get-TlcScenarioDisplayName -Scenario $chosenScenario[0] -Table $state.Strings
        } else {
            [string]$model.Scenario
        }
        $element.SummaryCase.Text = if ($model.CaseNumber) { [string]$model.CaseNumber } else { Get-TlcString -Table $state.Strings -Key 'SummaryNone' }
        $element.SummaryUser.Text = if ($model.AffectedUser) { [string]$model.AffectedUser } else { Get-TlcString -Table $state.Strings -Key 'SummaryNone' }
        $element.SummaryWindow.Text = Get-TlcRunSummaryWindowText -Model $model -Strings $state.Strings
        $state.RunModel = $model

        $element.FormPanel.Visibility = 'Collapsed'
        $element.RunSummaryPanel.Visibility = 'Visible'

        $element.RunProgress.Visibility = 'Visible'
        $element.RunProgressHeader.Visibility = 'Visible'
        $element.CancelButton.Content = Get-TlcString -Table $state.Strings -Key 'CancelButton'
        $liveCapture = $state.RunFork -eq 'Capture' -and -not $state.RunValidationOnly
        $element.RunSummaryPanel.Visibility = if ($liveCapture) { 'Collapsed' } else { 'Visible' }
        $state.CollectVisibility = Set-TlcRunActionButton -Element $element -Running $true -LiveCapture:$liveCapture
        $state.RunStarted = Get-Date
        $state.RunSpoke = $false
        $state.RunStopRequested = $false
        $state.RunWaitKey = ''
        $state.RunWaitSince = $null
        $state.RunWorkStage = $Stage
        $state.StopSteps = @{ Sampling = 'Pending'; Logs = 'Pending'; Support = 'Pending'; Finalize = 'Pending' }
        $state.StopStartedAt = $null
        $state.StopLastUpdateAt = $null
        $state.StopDetailKey = ''
        $state.StopOutcome = 'Running'
        $state.SupportProgress = $null
        $element.StopProgressPanel.Visibility = 'Collapsed'
        $state.LiveSamples = @()
        $state.LiveSampleStartedUtc = ''
        $state.LiveChartIntervalSeconds = if ($liveCapture) { [int]$model.CaptureIntervalSeconds } else { 5 }
        $state.LiveChartCenters = @{ Rtt = $null; Memory = $null }
        $state.SupportWaitingSince = $null
        $state.SupportPhase = 'Generating'
        & $renderSupportAction
        $element.SupportActionPanel.Visibility = 'Collapsed'
        $element.GenerateSupportButton.IsEnabled = $true
        $element.SupportResultText.Text = ''
        $element.LiveProgressText.Text = ''
        Update-TlcCaptureChart -Element $element -Samples @() -IntervalSeconds $state.LiveChartIntervalSeconds
        $state.LiveMemoryPreview = if ($liveCapture) { Initialize-TlcCaptureReading -Element $element } else { $null }
        $element.RunStatusText.Text = Get-TlcString -Table $state.Strings -Key 'RunStarting' -Argument @(0)

        # Only a capture run has phases worth naming. A gather run is over in about thirty
        # seconds and asks nothing of the operator while it runs.
        #
        # And only a capture that actually captures. -ValidationOnly returns before the stage
        # switch, so a validated trace never arms, never records and never waits for Stop -
        # showing "1. Arm / 2. Reproduce / 3. Collect" over it would instruct the operator to
        # go and reproduce a fault for a run that has already finished.
        if ($state.RunFork -eq 'Capture' -and -not $state.RunValidationOnly) {
            $state.CapturePhase = 'Arm'
            $state.CapturePhaseSince = Get-Date
            $state.CaptureSamples = 0
            $element.CapturePhasePanel.Visibility = 'Visible'
            $element.ShowLiveGraphBox.Visibility = 'Visible'
            $element.LiveChartPanel.Visibility = if ($element.ShowLiveGraphBox.IsChecked) { 'Visible' } else { 'Collapsed' }
            $element.RunProgress.Visibility = if ($element.ShowLiveGraphBox.IsChecked) { 'Collapsed' } else { 'Visible' }
            & $setCapturePhase 'Arm'
        } else {
            $state.CapturePhase = $null
            $element.CapturePhasePanel.Visibility = 'Collapsed'
            $element.LiveChartPanel.Visibility = 'Collapsed'
            $element.ShowLiveGraphBox.Visibility = 'Collapsed'
        }
        Update-TlcRunLoading -Element $element -State $state -Running

        # Belt and braces over the compaction above. Putting the form away is what makes the
        # bar reachable, but "reachable" depends on heights that are not fixed - a long
        # scenario name, a wrapped advisory banner or a validation hint all push it down, and
        # the window can be resized smaller than the layout was measured at.
        #
        # BringIntoView scrolls the least amount needed and does nothing when the target is
        # already visible, so on a normal window this is a no-op. It only earns its place on
        # the layouts that would otherwise have hidden the bar.
        #
        # Sync-TlcUiPaint first: the visibility changes above have not been laid out yet, and
        # scrolling to an element whose position is still the old one moves to the wrong
        # place. Pumping at Background priority runs after Layout.
        Sync-TlcUiPaint
        try { $element.RunProgress.BringIntoView() } catch {
            Write-Verbose "The progress bar could not be scrolled into view: $($_.Exception.Message)"
        }

        try {
            # The runner path is quoted.
            #
            # Start-Process joins -ArgumentList with spaces before handing it to the shell, so an
            # unquoted path splits at its first space and powershell.exe reports the fragment as
            # "does not have a '.ps1' extension", exits -196608, and nothing runs. The runner
            # currently lives in TEMP and has no spaces, which is the only reason this has
            # worked - it would break on any profile whose user name has one.
            $process = Start-Process -FilePath $shell `
                                     -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"") `
                                     -WorkingDirectory $ToolboxRoot `
                                     -RedirectStandardOutput $stdout `
                                     -RedirectStandardError $stderr `
                                     -NoNewWindow -PassThru
        } catch {
            $element.LogBox.Text += "`r`n$(Get-TlcString -Table $state.Strings -Key 'LogFailedToRun' -Argument @($_.Exception.Message))"
            $element.RunProgress.Visibility = 'Collapsed'
            Update-TlcRunLoading -Element $element -State $state
            $null = Set-TlcRunActionButton -Element $element -Running $false -RestoreVisibility $state.CollectVisibility
            $element.FormPanel.Visibility = 'Visible'
            $element.RunSummaryPanel.Visibility = 'Collapsed'
            $element.RunStatusText.Text = Get-TlcString -Table $state.Strings -Key 'RunFailedToStart'
            foreach ($button in $runButtons) { $button.IsEnabled = $wasEnabled[$button.Name] }
            foreach ($file in $runner, $stdout, $stderr) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
            return
        }

        # No -Wait. Start-Process -Wait blocks the thread it is called on, and that thread
        # is the UI thread - so the whole window froze for the length of the collection,
        # repainting nothing and reporting "Not Responding" to Windows on a long one. A
        # measured desktop collect is 14 seconds; a run that waits for the user to press
        # Ctrl + Alt + Shift + 1 is up to ten minutes of a dead window.
        #
        # Instead the process is polled on a dispatcher timer. The UI thread stays free
        # between ticks, so the window paints, the progress bar animates, tiles still
        # respond, and output appears as it is produced rather than all at once at the end.
        $offset = @{ Out = 0L; Err = 0L }

        # Reads whatever has been appended since the last tick. Shared read because the
        # child still holds these files open for writing - the default share mode throws
        # on exactly the file being written, which is finding 9 in another guise.
        $readNew = {
            param([string] $Path, [string] $Key)
            if (-not (Test-Path -LiteralPath $Path)) { return '' }
            $text = ''
            try {
                $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open,
                                                      [System.IO.FileAccess]::Read,
                                                      [System.IO.FileShare]::ReadWrite)
                try {
                    # Length is read BEFORE the reader is created, and the offset advanced
                    # from that captured value.
                    #
                    # StreamReader.Dispose closes the stream it wraps, so reading
                    # $stream.Length afterwards throws ObjectDisposedException - which the
                    # outer catch swallowed, leaving the offset at zero. Every tick then
                    # re-read the file from the beginning and appended the whole thing
                    # again: a 553-byte log became a 40,924-character transcript in eight
                    # ticks, growing without bound for as long as the run lasted.
                    $length = $stream.Length
                    if ($length -gt $offset[$Key]) {
                        $null = $stream.Seek($offset[$Key], [System.IO.SeekOrigin]::Begin)
                        $reader = [System.IO.StreamReader]::new($stream)
                        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                        $offset[$Key] = $length
                    }
                } finally { $stream.Dispose() }
            } catch {
                Write-Verbose "Could not tail $Path : $($_.Exception.Message)"
            }
            return $text
        }.GetNewClosure()

        # Local aliases for the two objects the polling closures need.
        #
        # GetNewClosure copies the LOCAL variables of the scope that creates the closure.
        # $element and $state belong to Show-TlcWizard, one scope up, so they are not
        # copied - inside the closure they read as empty and every property access fails
        # with "the property cannot be found on this object". Aliasing them into locals
        # first is what makes them travel.
        #
        # The closure itself is not optional either: $timer, $process and the temp paths
        # are locals of this handler, which has returned by the time the first tick fires,
        # so a plain scriptblock cannot see them. Both halves are needed, and getting one
        # without the other produced two different misleading errors before this landed.
        $ui = $element
        $runState = $state
        # Same reason, one scope further out: the phase setter is a local of Show-TlcWizard,
        # so without an alias the tick would see nothing and every phase change would fail with
        # "the expression after & must be a command name".
        $setPhase = $setCapturePhase
        $renderSupport = $renderSupportAction

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(200)

        # Held on $state, which lives as long as the window. A DispatcherTimer referenced
        # only by a local in this scriptblock is unreachable the moment the handler
        # returns, and a collected timer simply stops ticking - the run then completes in
        # the child while the window sits on "Starting..." for ever. That is precisely
        # what happened on the first attempt here.
        $state.RunTimer = $timer

        # Cancel stops the collection. The process is kept on $state so the handler,
        # which is wired once at startup, can reach the run that is in flight now.
        #
        # Killing the child alone is not enough: it is a powershell.exe that has itself
        # spawned the collectors, and stopping only the parent leaves those running with
        # nothing reading their output. The whole tree goes, matched on parent id.
        $state.RunProcess = $process
        $state.RunCancelled = $false
        $state.LogPendingOut = ''
        $state.LogPendingErr = ''
        $state.CaptureStopAcknowledged = $false

        $finish = {
            $timer.Stop()
            Update-TlcRunLoading -Element $ui -State $runState

            # One last read: the child can write between the final tick and exiting. -Final
            # lets through a last line that has no line ending.
            $tailOut = Add-TlcRunOutput -Pending $runState.LogPendingOut -New (& $readNew $stdout 'Out') -Table $runState.Strings -Final
            $tailErr = Add-TlcRunOutput -Pending $runState.LogPendingErr -New (& $readNew $stderr 'Err') -Table $runState.Strings -Final
            $tail = $tailOut.Text + $tailErr.Text
            Update-TlcStopProgress -Element $ui -State $runState -Records $tailOut.StopSteps -SupportProgress $tailOut.SupportProgress
            $runState.LogPendingOut = ''
            $runState.LogPendingErr = ''
            if ($tail) { $ui.LogBox.Text += $tail }

            if ($ui.LogBox.Text -match 'Run path\s*:\s*(.+)') {
                $runState.RunPath = $Matches[1].Trim()
                $runState.CorrelationId = Split-Path -Leaf $runState.RunPath

                # Every collection this window has produced, newest first. Each Collect now
                # gets its own folder, so a session that collected three times has three
                # genuinely separate sets of evidence rather than three overwrites of one -
                # and the operator is the only person who knows which of them matter.
                if (-not $runState.SessionRuns) { $runState.SessionRuns = @() }
                if ($Stage -ne 'Package' -and ($runState.SessionRuns -notcontains $runState.RunPath)) {
                    $runState.SessionRuns = @($runState.RunPath) + @($runState.SessionRuns)
                }

                $wasEnabled['PackageButton'] = ($Stage -ne 'Validate-Only')
                $wasEnabled['OpenButton'] = $true

                # Surfaced, not just enabled. Both act on a finished run, and until one exists
                # they are two controls an operator has to read and rule out on every session.
                #
                # Open run folder appears for BOTH forks: every run writes a run folder, and a
                # live trace's samples are as much evidence as a gather's copied logs. Package
                # is withheld from a validation-only run, which deliberately collects nothing
                # and so has nothing to package.
                $ui.OpenButton.Visibility = 'Visible'
                if ($Stage -ne 'Validate-Only') { $ui.PackageButton.Visibility = 'Visible' }
            }

            # ExitCode on a -PassThru process is not populated until the object is
            # refreshed, so reading it straight after HasExited gives an empty string -
            # which rendered as "Finished with exit code ." Refresh first, and treat an
            # unreadable code as success rather than inventing a failure: the transcript
            # is the authority on what happened, and a spurious error line above a clean
            # run is worse than no line at all.
            $exitCode = $null
            try { $process.Refresh(); $exitCode = $process.ExitCode } catch { $exitCode = $null }

            # A cancelled run is not a finished one, and saying "Finished." after somebody
            # pressed Cancel is the sort of small lie that makes an operator doubt the rest
            # of the window. The kill also produces a non-zero exit code that means nothing
            # here, so it is not reported either.
            if ($runState.RunCancelled) {
                $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunStopped'
            } elseif ($exitCode -eq 2) {
                # REFUSED, and said in words. Exit 2 is the entry point's code for a Blocked
                # run - a package the privacy gate turned down, a stage that is not built.
                # This used to read "Finished." because the child exited 0 for those, which
                # told the operator a refused package had succeeded. Finding 290.
                $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunBlocked'
            } elseif ($null -ne $exitCode -and $exitCode -ne 0) {
                $ui.LogBox.Text += "`r`n$(Get-TlcString -Table $runState.Strings -Key 'LogExitCode' -Argument @($exitCode))"
                $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunExitCode' -Argument @($exitCode)
            } else {
                $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunFinished'
            }
            $stopOutcome = if ($runState.RunCancelled -or ($null -ne $exitCode -and $exitCode -ne 0)) { 'Failed' }
                elseif ($null -eq $exitCode) { 'Warning' } else { 'Complete' }
            Update-TlcStopProgress -Element $ui -State $runState -Outcome $stopOutcome

            $ui.RunProgress.Visibility = 'Collapsed'
            $ui.LiveProgressText.Text = $ui.RunStatusText.Text
            Update-TlcCaptureChart -Element $ui -Samples $runState.LiveSamples `
                -IntervalSeconds $runState.LiveChartIntervalSeconds -StartedUtc $runState.LiveSampleStartedUtc -Centers $runState.LiveChartCenters
            $null = Set-TlcRunActionButton -Element $ui -Running $false -RestoreVisibility $runState.CollectVisibility
            if ($runState.RunFork -eq 'Capture' -and -not $runState.RunValidationOnly) {
                & $setPhase 'Finished'
                $ui.CapturePhasePanel.Visibility = 'Visible'
            } else {
                $ui.CapturePhasePanel.Visibility = 'Collapsed'
            }
            $ui.FormPanel.Visibility = 'Visible'
            $ui.RunSummaryPanel.Visibility = 'Collapsed'
            $ui.LogBox.ScrollToEnd()
            foreach ($button in $runButtons) { $button.IsEnabled = $wasEnabled[$button.Name] }

            # Package becomes the primary action once there is something to package, and
            # goes back to secondary once it has been used. Enabling a grey button is a
            # state change nobody notices: the operator has just watched a wall of log
            # output scroll past and has no signal that the next step is now available.
            # Collect stops being primary at the same moment, because re-collecting is no
            # longer the obvious thing to do.
            #
            # Styles come from Theme.xaml, which is EPO's file and is never edited - these
            # are looked up by key, not redefined.
            # Looked up from the button, not from $window.
            #
            # $finish is built with GetNewClosure inside $runStage, so it captures that local
            # scope; $window belongs to the enclosing function and is NOT captured. Calling
            # $window.FindResource here threw "You cannot call a method on a null-valued
            # expression" on every single run - swallowed by the timer's try/catch into
            # "Progress reporting failed; the run may still be going", which is why the
            # symptom named the progress timer and not the thing that was actually broken.
            # The run itself had already finished and its evidence was already on disk.
            #
            # A FrameworkElement resolves resources by walking its own tree up to the window
            # and then the application, so the button finds the same style the window would
            # have. TryFindResource rather than FindResource: a missing key should cost a
            # restyle, not the rest of the completion handler.
            #
            # Styles come from Theme.xaml, which is EPO's file and is never edited - these
            # are looked up by key, not redefined.
            if ($wasEnabled['PackageButton'] -and $ui.PackageButton.IsEnabled) {
                $primary = $ui.PackageButton.TryFindResource('PrimaryButton')
                $secondary = $ui.CollectButton.TryFindResource('SecondaryButton')
                if ($primary) { $ui.PackageButton.Style = $primary }
                if ($secondary) { $ui.CollectButton.Style = $secondary }
            }

            foreach ($file in $runner, $stdout, $stderr) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }

            # Drain the multi-run package queue one run at a time. Starting the next only
            # once this one has exited is what keeps the "no two runs at once" rule the run
            # buttons enforce, and it is the only point at which the zip can know every
            # bundle it is meant to carry has actually been written.
            #
            # This runs after the temp files are cleaned up, because the next run creates
            # its own set and an early return would leak this one's.
            #
            # $runStage and $zipSessionRuns are reached through $state rather than through
            # this closure: GetNewClosure captures the local scope, and both are defined in
            # the function scope outside it.
            if ($Stage -eq 'Package' -and -not $runState.RunCancelled) {
                # Only a SEALED run counts as packaged. A package the privacy gate refused
                # used to be added here regardless, and New-TlcSessionArchive then zipped its
                # raw run folder - unsealed, unmasked evidence handed over as if it had passed
                # (review 2026-09-30, finding 331). The bundle on disk is the witness, not the
                # exit code alone: an unreadable exit code is treated as success above.
                $sealedBundle = if ($runState.RunPath) {
                    Join-Path (Split-Path -Parent $runState.RunPath) ('TLC-{0}.zip' -f (Split-Path -Leaf $runState.RunPath))
                } else { $null }
                if ($exitCode -ne 2 -and $sealedBundle -and (Test-Path -LiteralPath $sealedBundle)) {
                    if (@($runState.PackageDone) -notcontains $runState.RunPath) {
                        $runState.PackageDone = @($runState.PackageDone) + @($runState.RunPath)
                    }
                } elseif ($runState.RunPath -and (@($runState.PackageRefused) -notcontains $runState.RunPath)) {
                    $runState.PackageRefused = @($runState.PackageRefused) + @($runState.RunPath)
                }

                $remaining = @($runState.PackageQueue)
                if ($remaining.Count -gt 0) {
                    $runState.PackageQueue = @($remaining | Select-Object -Skip 1)
                    $runState.CorrelationId = Split-Path -Leaf $remaining[0]
                    $runState.RunPath = $remaining[0]
                    if ($runState.RunStage) { & $runState.RunStage 'Package' }
                } elseif ($runState.PackageZip) {
                    $runState.PackageZip = $false
                    $archive = $null
                    if (@($runState.PackageDone).Count -gt 0) {
                        $archive = if ($runState.ZipSessionRuns) { & $runState.ZipSessionRuns @($runState.PackageDone) } else { $null }
                        if ($archive) {
                            $ui.LogBox.Text += "`r`n`r`n$(Get-TlcString -Table $runState.Strings -Key 'LogSessionArchive' -Argument @($archive.Path))`r`n  $(Get-TlcString -Table $runState.Strings -Key 'LogSessionArchiveCounts' -Argument @($archive.RunCount, $archive.FileCount, [math]::Round($archive.Bytes / 1MB, 1)))"
                            $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunPackagedZipped' -Argument @($archive.RunCount)
                            foreach ($leaf in @($archive.SkippedRuns)) {
                                if (@($runState.PackageRefused | ForEach-Object { Split-Path -Leaf $_ }) -notcontains $leaf) {
                                    $runState.PackageRefused = @($runState.PackageRefused) + @($leaf)
                                }
                            }
                        } else {
                            # The bundles are written and on disk; only the carrier failed.
                            $ui.LogBox.Text += "`r`n`r`n$(Get-TlcString -Table $runState.Strings -Key 'LogZipFailed')"
                        }
                    }
                    $refused = @($runState.PackageRefused)
                    if ($refused.Count -gt 0) {
                        $names = @($refused | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
                        $ui.LogBox.Text += "`r`n`r`n$(Get-TlcString -Table $runState.Strings -Key 'LogNotZipped' -Argument @($names))"
                        $ui.RunStatusText.Text = if ($archive) {
                            Get-TlcString -Table $runState.Strings -Key 'RunPackagedSomeRefused' -Argument @($archive.RunCount, $refused.Count)
                        } else {
                            Get-TlcString -Table $runState.Strings -Key 'RunNothingSealed'
                        }
                    }
                    $ui.LogBox.ScrollToEnd()
                }
            }
        }.GetNewClosure()

        # The try/catch is inline rather than routed through $protect. A tick that throws
        # on a dispatcher timer is raised on the UI thread and would take the window down
        # mid-collection, which is the one moment there is unsaved work on screen - so it
        # is guarded, but guarded here where the timer can also be stopped. A handler that
        # throws every 200 ms would otherwise keep throwing.
        $timer.Add_Tick({
            try {
                # Each stream is read whole-line, on its own: an unfinished line in one must
                # not be joined to the next read of the other. Phase markers are for this
                # window, not for the operator, and are taken out before the log is written,
                # because a reader scrolling back should see what happened, not the wiring
                # that reported it. Add-TlcRunOutput does both, and says the lines that tell
                # the operator what to do in the window's language. Finding 338.
                $fromOut = Add-TlcRunOutput -Pending $runState.LogPendingOut -New (& $readNew $stdout 'Out') -Table $runState.Strings
                $fromErr = Add-TlcRunOutput -Pending $runState.LogPendingErr -New (& $readNew $stderr 'Err') -Table $runState.Strings
                $runState.LogPendingOut = $fromOut.Pending
                $runState.LogPendingErr = $fromErr.Pending

                # Newest wins: a tick can carry several samples, and the newest count is the
                # one worth showing.
                if ($null -ne $fromErr.Samples) { $runState.CaptureSamples = $fromErr.Samples }
                if ($null -ne $fromOut.Samples) { $runState.CaptureSamples = $fromOut.Samples }
                $phaseSeen = if ($fromOut.Phase) { $fromOut.Phase } else { $fromErr.Phase }
                if ($phaseSeen -and $runState.CapturePhase) { & $setPhase $phaseSeen }
                if ($runState.RunFork -eq 'Capture') {
                    $steps = @(if ($fromOut.PSObject.Properties['StopSteps']) { $fromOut.StopSteps })
                    $supportProgress = if ($fromOut.PSObject.Properties['SupportProgress']) { $fromOut.SupportProgress } else { $null }
                    if ($null -ne $fromOut.SupportResult) { $ui.SupportResultText.Text = [string]$fromOut.SupportResult }
                    if ($fromOut.SupportState) {
                        $runState.SupportPhase = $fromOut.SupportState
                        & $renderSupport
                    }
                    if ($phaseSeen -eq 'Collect') {
                        $ui.CancelButton.IsEnabled = $false
                        $ui.CancelButton.Content = Get-TlcString -Table $runState.Strings -Key 'RunStopping'
                    }
                    if ($null -ne $fromOut.SupportWaiting) {
                        $ui.SkipSupportButton.Visibility = if ($fromOut.SupportWaiting) { 'Visible' } else { 'Collapsed' }
                        $ui.SupportActionPanel.Visibility = if ($fromOut.SupportWaiting) { 'Visible' } else { 'Collapsed' }
                        $runState.SupportWaitingSince = if ($fromOut.SupportWaiting) { Get-Date } else { $null }
                    }
                    Update-TlcStopProgress -Element $ui -State $runState -Records $steps -SupportProgress $supportProgress
                    if (@($fromOut.Metrics).Count) {
                        foreach ($metric in $fromOut.Metrics) {
                            foreach ($name in 'Rtt', 'Memory') {
                                if ($null -eq $runState.LiveChartCenters[$name] -and $null -ne $metric.$name) {
                                    $runState.LiveChartCenters[$name] = [double]$metric.$name
                                }
                            }
                        }
                        if (-not $runState.LiveSampleStartedUtc) { $runState.LiveSampleStartedUtc = $fromOut.Metrics[0].TimestampUtc }
                        $runState.LiveSamples = @(@($runState.LiveSamples) + @($fromOut.Metrics) | Select-Object -Last 120)
                        if ($ui.ShowLiveGraphBox.IsChecked) {
                            Update-TlcCaptureChart -Element $ui -Samples $runState.LiveSamples -Animate `
                                -IntervalSeconds $runState.LiveChartIntervalSeconds -StartedUtc $runState.LiveSampleStartedUtc -Centers $runState.LiveChartCenters
                        }
                    }
                    $elapsed = (Get-Date) - $runState.RunStarted
                    $age = if ($runState.LiveSamples.Count) {
                        [int]((Get-Date).ToUniversalTime() - ([datetimeoffset]::Parse($runState.LiveSamples[-1].TimestampUtc)).UtcDateTime).TotalSeconds
                    } else { '?' }
                    $ui.LiveProgressText.Text = Get-TlcString -Table $runState.Strings -Key 'LiveProgressText' -Argument @(
                        $elapsed.ToString('hh\:mm\:ss'), $runState.CaptureSamples, $age)
                    if ($runState.StopStartedAt) {
                        $finishing = (Get-Date) - $runState.StopStartedAt
                        $ui.LiveProgressText.Text = Get-TlcString -Table $runState.Strings -Key 'StopLiveProgress' -Argument @(
                            $finishing.ToString('hh\:mm\:ss'), $runState.CaptureSamples)
                    }
                }

                $new = $fromOut.Text + $fromErr.Text
                if ($new.Trim()) {
                    $ui.LogBox.Text += $new
                    $ui.LogBox.ScrollToEnd()

                    # The status line is the last non-empty line the run printed. It tracks
                    # the lanes as they open, so a long prompted wait reads as "Prompted
                    # lane" rather than as a stalled window.
                    $last = if ($fromErr.LastLine) { $fromErr.LastLine } else { $fromOut.LastLine }
                    if ($last) {
                        $runState.RunSpoke = $true
                        $ui.RunStatusText.Text = $last
                    }
                }

                # During Reproduce the child prints nothing for minutes at a time - by design,
                # since a line per sample would bury the log. A static status line through a
                # twenty-minute silence is indistinguishable from a hung tool, and the operator
                # who kills it loses the session. So the elapsed time moves even when the run
                # has nothing to say.
                if ($runState.CapturePhase -eq 'Reproduce' -and $runState.CapturePhaseSince) {
                    $recording = (Get-Date) - $runState.CapturePhaseSince
                    # The count, not just the clock. Elapsed time moves identically whether the
                    # sampler is working or wedged, so on its own it proves the window is alive
                    # rather than that anything is being recorded.
                    $taken = [int]$runState.CaptureSamples
                    $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Argument @($recording, $taken) `
                        -Key $(if ($taken -eq 1) { 'RunRecordingOne' } else { 'RunRecordingMany' })
                }

                # A run prints nothing until the child has started PowerShell and imported
                # its modules. Settled, that is one to three seconds; it stretches to twenty
                # or more when the module files have just been written, because the next read
                # of a changed file waits on a virus scan. Measured: 267 ms for a settled
                # module against 1,050 ms for the same file immediately after a rewrite.
                #
                # So the wait is real but its length is not predictable, and no fixed
                # estimate would be right - an earlier version of this line promised "about
                # 25 s", which was measured during heavy editing and is five times too long
                # for anyone just running the tool.
                #
                # A counter needs no estimate. It names the phase so the silence reads as
                # expected, and it moves, which is the part that separates a live run from a
                # stuck one. The indeterminate bar cannot do that: it animates from the UI
                # thread, so it proves the window is alive rather than the run.
                if (-not $runState.RunSpoke) {
                    $elapsed = [int]((Get-Date) - $runState.RunStarted).TotalSeconds
                    $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunStarting' -Argument @($elapsed)
                }

                Update-TlcRunLoading -Element $ui -State $runState -Running:(-not $process.HasExited)
                if ($process.HasExited) { & $finish }
            } catch {
                $timer.Stop()
                Update-TlcRunLoading -Element $ui -State $runState
                $ui.RunProgress.Visibility = 'Collapsed'
                $null = Set-TlcRunActionButton -Element $ui -Running $false -RestoreVisibility $runState.CollectVisibility
                $ui.FormPanel.Visibility = 'Visible'
                $ui.RunSummaryPanel.Visibility = 'Collapsed'
                $ui.RunStatusText.Text = Get-TlcString -Table $runState.Strings -Key 'RunProgressFailed' -Argument @($_.Exception.Message)
                # Named on screen as well as logged. The previous wording said only that
                # progress reporting had failed, which pointed at the timer - the one part
                # that was working - and said nothing about the cause. A null reference in
                # the completion handler then hid behind it on every run for a day.
                Write-TlcToolLog -Message 'The run progress timer failed.' -Level 'WARN' -ErrorRecord $_
                $ui.StopProgressDetail.Text = $ui.RunStatusText.Text
                $ui.StopProgressDetail.Foreground = $ui.StopProgressDetail.FindResource('WarningBrush')
                foreach ($button in $runButtons) { $button.IsEnabled = $wasEnabled[$button.Name] }
            }
        }.GetNewClosure())
        $timer.Start()
    }

    # Published on the state so the completion handler can reach them. $finish is built with
    # GetNewClosure inside $runStage, which captures that local scope - these live in the
    # function scope outside it, and the queue drain runs from $finish.
    $state.RunStage = $runStage
    $state.ZipSessionRuns = $zipSessionRuns

    <#
        Every handler is wrapped.

        A WPF event handler that throws takes the dispatcher with it, so an exception
        raised while somebody is typing in the case-number box closes the window and
        loses whatever they had entered. None of these handlers do anything worth
        losing a window over: the command box is rebuilt on the next keystroke anyway,
        so a failure is recorded and the wizard stays up.
    #>
    $protect = {
        param([scriptblock] $Action, [string] $Name)

        # Captured HERE, because GetNewClosure captures this scope's locals only. $element
        # belongs to Show-TlcWizard, one scope out, so the closure below used to see $null for
        # it - and every handler failure in the wizard fell through to the "could not be shown
        # in the window either" branch. That branch was written as a rare fallback; it was the
        # only path. It is why the language setting could fail silently on every change.
        # Finding 289.
        $ui = $element

        return {
            try {
                & $Action
            } catch {
                # Logged first, and to a file, because the window is the least reliable place
                # to report a window failure. The wizard opens its own tool log at startup so
                # this actually writes; before that it silently did nothing.
                Write-TlcToolLog -Message "Wizard handler '$Name' failed." -Level 'WARN' -ErrorRecord $_
                try {
                    # Reveal the transcript card first. It starts collapsed, so a handler that
                    # fails before any run would otherwise write its error into a hidden
                    # control and vanish - the exact silent failure this wrapper exists to
                    # prevent.
                    $ui.LogPanel.Visibility = 'Visible'
                    $ui.LogBox.Text += "`r`n[$Name] $($_.Exception.Message)"
                } catch {
                    # $element unreachable, so there is nowhere on screen to say this. The
                    # tool log above still has it; say where, rather than swallowing the
                    # second failure the way the first one used to be swallowed.
                    Write-Verbose "Could not report the handler failure in the window: $($_.Exception.Message)"
                    Write-TlcToolLog -Message "The failure in '$Name' could not be shown in the window either." -Level 'WARN' -ErrorRecord $_
                }
            }
        }.GetNewClosure()
    }

    $onChanged = & $protect $updateCommand 'update command'

    # The live trace is offered only where it can measure the thing being diagnosed.
    #
    # Re-evaluated on every scenario change rather than once at startup, and it also has to undo
    # itself: an operator who picks Rooms and then goes back to Call quality must get the button
    # back, and a disabled control that never re-enables is worse than one that was never there.
    $applyCaptureAvailability = {
        $chosenScenario = Get-TlcWizardSelectedScenario -Element $element -Catalog $catalog
        $scenarioId = if ($chosenScenario) { [string]$chosenScenario.Id } else { '' }
        $supported = Test-TlcScenarioSupportsCapture -ScenarioId $scenarioId

        $element.LivePathButton.IsEnabled = $supported
        $element.PathUnavailableHint.Visibility = if ($supported) { 'Collapsed' } else { 'Visible' }
        # From the current table. This was an English literal, so the translated sentence in
        # every table never reached the screen - found rendering Tamil, 2026-10-01.
        $element.PathUnavailableHint.Text = if ($supported) { '' } elseif (-not $scenarioId) {
            Get-TlcString -Table $state.Strings -Key 'ProblemScenarioMissing' -Argument @(
                (Get-TlcString -Table $state.Strings -Key 'WhatHappenedHeading'))
        } else {
            Get-TlcString -Table $state.Strings -Key 'PathUnavailable'
        }

        # If the operator was already on the live path when they switched to a scenario that
        # cannot use it, move them off it rather than leaving a live panel open over a run that
        # would measure the wrong machine.
        if (-not $supported -and $state.Fork -eq 'Capture') {
            & $showPath $(if ($scenarioId) { 'Gather' } else { '' })
        }
    }
    $element.ScenarioBox.Add_SelectionChanged((& $protect { & $applyCaptureAvailability } 'capture availability'))
    & $applyCaptureAvailability

    $element.ScenarioBox.Add_SelectionChanged($onChanged)
    $element.WindowUnitBox.Add_SelectionChanged($onChanged)
    foreach ($boxName in 'UserBox', 'ConsentBox', 'ImpactTimeBox', 'BeforeBox', 'AfterBox', 'DeviceBox', 'OutputBox') {
        $element[$boxName].Add_TextChanged($onChanged)
    }

    # Checked and Unchecked rather than Click, so ticking the box from the run summary's
    # Record button hides the typed field and refreshes the command the same way a click does.
    $onConsentTicked = & $protect {
        Update-TlcWizardConsentField -Element $element
        & $updateCommand
    } 'consent checkbox'
    foreach ($boxName in 'ConsentMeBox', 'SummaryConsentMeBox') {
        $element[$boxName].Add_Checked($onConsentTicked)
        $element[$boxName].Add_Unchecked($onConsentTicked)
    }

    # CaseBox is an editable ComboBox, which has no TextChanged of its own - the event
    # belongs to the TextBox inside its template. Add_SelectionChanged alone would miss
    # everything the user types, so both are wired: the selection for picking a
    # remembered case, the inner box for typing a new one.
    $element.CaseBox.Add_SelectionChanged($onChanged)
    $element.CaseBox.Add_Loaded({
        $editable = $element.CaseBox.Template.FindName('PART_EditableTextBox', $element.CaseBox)
        if ($editable) {
            $editable.Add_TextChanged($onChanged)
        } else {
            Write-Verbose 'The case box has no PART_EditableTextBox, so typing will not refresh the command.'
        }
    })
    $element.ImpactDate.Add_SelectedDateChanged($onChanged)
    $element.SkipPromptedBox.Add_Click($onChanged)
    $element.CaptureIntervalBox.Add_SelectionChanged($onChanged)
    # The tick changes the command line, and the standing rule is that the equivalent command
    # is exactly what runs - so clearing it has to remove -DeepCapture from the box as well.
    $element.DeepCaptureBox.Add_Click($onChanged)
    $element.ValidationOnlyBox.Add_Click($onChanged)

    <#
        REOPEN ELEVATED, FROM A CONTROL THE OPERATOR CAN ACTUALLY PRESS.

        Reported 2026-09-22: the capability panel said "0 of 3 available - not running as
        administrator" three times over and offered nothing to click. Stating a fact and
        leaving the operator to work out the remedy is not the same as offering it.

        "REOPEN", not "restart", and the product named. "Restart as administrator" was
        reported as ambiguous the next day: in the middle of a customer's reproduction, an
        offer that might restart the MACHINE is an alarming thing to be handed, and nobody
        should have to click a button to find out which one it meant.

        A new elevated process, then close this one - in that order. Closing first would
        leave nothing on screen if the prompt is declined, and "the toolbox vanished" is a
        worse outcome than "the button appeared not to work".

        The path is QUOTED. Start-Process does not quote the elements of -ArgumentList, and
        this toolbox ships to paths with spaces in them - this one has two - so unquoted,
        -File is handed one word and the elevated process dies without a window, which looks
        exactly like the prompt having been declined.
    #>
    $element.ElevateButton.Add_Click((& $protect {
        $launcher = Join-Path $ToolboxRoot 'Start-TlcToolbox.ps1'
        if (-not (Test-Path -LiteralPath $launcher)) {
            throw "The launcher could not be found at $launcher, so the toolbox cannot reopen itself."
        }

        $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $arguments = @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$launcher`"")

        try {
            Start-Process -FilePath $shell -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
        } catch {
            # Declined, or no interactive desktop to show the prompt on. Said on the panel
            # the button sits in, because that is where the operator is looking - and NOT
            # thrown, because a cancelled UAC prompt is a decision, not a fault.
            Write-TlcToolLog -Message 'The elevated reopen was not granted.' -Level 'INFO'
            $element.DeepCapabilityHeading.Text =
                'Deeper captures on this machine - administrator rights were not granted, so these stay unavailable.'
            return
        }

        Write-TlcToolLog -Message 'Reopening elevated at the operator''s request.' -Level 'INFO'
        $window.Close()
    } 'reopen as administrator'))

    # Choosing a path is what makes the rest of the form exist.
    #
    # Both buttons stay visible after the choice so it can be changed without restarting, and
    # the chosen one is marked so the form says which job it is set up for. The panels are
    # collapsed rather than disabled: a greyed-out window field on a live trace still invites
    # the question "why can't I set that", and the answer is that it does not apply at all.
    #
    # An empty $Path clears back to the unchosen state. Clicking the already-selected job is
    # what sends it: a pair of buttons where one is visibly selected reads as a toggle, and
    # there was no other way back to the default short of restarting the window - which an
    # operator who picked the wrong job by accident had to actually do.
    # The "What happened" section, collapsed to a one-line summary once a job is chosen.
    #
    # Scenario, case and user are settled by then - the job could not be picked without
    # them - and the section is three rows of inputs sitting between the dashboard and the
    # form the operator is now filling in.
    #
    # COLLAPSED, NOT HIDDEN. "What happened" is exactly what somebody re-reads when a run
    # does not look right, so the header stays on screen, carries the summary, and brings
    # the section back on click. A section that vanishes is one an operator has to rebuild
    # from memory.
    $setWhatHappenedCollapsed = {
        param([bool] $Collapsed)

        $selectedScenario = Get-TlcWizardSelectedScenario -Element $element -Catalog $catalog
        if (-not $selectedScenario) { $Collapsed = $false }
        $element.WhatHappenedBody.Visibility = if ($Collapsed) { 'Collapsed' } else { 'Visible' }

        if (-not $Collapsed) {
            $element.WhatHappenedSummary.Visibility = 'Collapsed'
            return
        }

        # The summary is built from the controls rather than from a stored copy, so it
        # cannot describe a different choice from the one on the form.
        $parts = @()
        if ($selectedScenario) { $parts += Get-TlcScenarioDisplayName -Scenario $selectedScenario -Table $state.Strings }
        $case = [string]$element.CaseBox.Text
        if ($case) { $parts += $case }
        $user = [string]$element.UserBox.Text
        if ($user) { $parts += $user }

        $element.WhatHappenedSummary.Text = ($parts -join '  -  ')
        $element.WhatHappenedSummary.Visibility = 'Visible'
    }

    $showPath = {
        param([string] $Path)

        $state.Fork = if ($Path) { $Path } else { $null }
        $element.LiveStaticPanel.Visibility = if ($Path -eq 'Capture') { 'Collapsed' } else { 'Visible' }
        $element.GatherPanel.Visibility = if ($Path -eq 'Gather') { 'Visible' } else { 'Collapsed' }
        $element.LivePanel.Visibility = if ($Path -eq 'Capture') { 'Visible' } else { 'Collapsed' }
        $element.SharedOptionsPanel.Visibility = if ($Path) { 'Visible' } else { 'Collapsed' }

        # Two of the options are not actually shared. The Rooms device names a separate
        # appliance and the endpoint list drives the fleet lane, which only the Collect stage
        # runs - a capture run reads neither, so on the live path they would take input and
        # silently discard it.
        $element.GatherOnlyOptions.Visibility = if ($Path -eq 'Capture') { 'Collapsed' } else { 'Visible' }

        # The run buttons mean nothing until there is a job to run.
        $element.CollectButton.Visibility = if ($Path) { 'Visible' } else { 'Collapsed' }
        $element.ValidateButton.Visibility = if ($Path) { 'Visible' } else { 'Collapsed' }

        foreach ($choice in @(
            @{ Name = 'GatherPathButton'; Path = 'Gather'; Indicator = 'GatherPathSelected'; Outline = 'GatherPathOutline' }
            @{ Name = 'LivePathButton'; Path = 'Capture'; Indicator = 'LivePathSelected'; Outline = 'LivePathOutline' }
        )) {
            $button = $element[$choice.Name]
            $label = Get-TlcString -Table $state.Strings -Key $choice.Name
            $selected = if ($Path -eq $choice.Path) { Get-TlcString -Table $state.Strings -Key 'PathSelected' } else { '' }
            $button.Content = $label
            $element[$choice.Indicator].Visibility = if ($selected) { 'Visible' } elseif ($Path) { 'Hidden' } else { 'Collapsed' }
            $element[$choice.Indicator].Text = Get-TlcString -Table $state.Strings -Key 'PathSelected'
            $element[$choice.Outline].BorderBrush = if ($selected) {
                $window.FindResource('AccentBrush')
            } else { [System.Windows.Media.Brushes]::Transparent }
            [System.Windows.Automation.AutomationProperties]::SetItemStatus($button, $selected)
        }

        # CHOOSING A JOB IS THE MOMENT THE ROUTING QUESTION IS SETTLED.
        #
        # "The admin center can do most of this" answers "which console should I be at".
        # Once the operator has picked a job here they have answered it, and leaving the
        # banner up spends a row of screen on advice that has been acted on - above the
        # form they are now trying to fill in.
        #
        # Dismissed through the same rule any other dismissal uses, keyed on what the
        # banner says, so a recommendation that genuinely CHANGES later still comes back.
        # Collapsing it directly as well, because nothing guarantees a refresh follows.
        #
        # And the scenario, case and user are settled too - they were chosen before a job
        # could be picked. The section collapses to a one-line summary rather than hiding,
        # because "what happened" is exactly what an operator re-reads when a run does not
        # look right.
        if ($Path) {
            & $setWhatHappenedCollapsed $true
        } else {
            # CLEARING THE JOB PUTS THE SECTION BACK. Pressing the selected fork again
            # deselects it - there is no job any more, so the answers that a job was chosen
            # from are live again and the form should look the way it did before.
            #
            # Without this the section stayed collapsed with no job selected, which is the
            # one state where nothing on screen explains why three inputs are missing.
            #
            # The BANNER deliberately does not come back. Dismissal is keyed on what the
            # advice says, so it returns when the recommendation genuinely changes - not
            # because the operator is still deciding which job to run.
            & $setWhatHappenedCollapsed $false
        }

        # Collect means something different on each path, and the button is the last thing an
        # operator reads before committing.
        $element.CollectButton.Content = Get-TlcString -Table $state.Strings `
            -Key $(if ($Path -eq 'Capture') { 'StartTraceButton' } else { 'CollectButton' })

        & $updateCommand
    }

    # The toggle. Clicking the job already selected clears the form back to its opening state
    # rather than re-selecting it, which is a no-op the operator cannot distinguish from a
    # dead button.
    $togglePath = {
        param([string] $Path)
        if ($state.Fork -eq $Path) { & $showPath '' } else { & $showPath $Path }
    }

    $element.GatherPathButton.Add_Click((& $protect { & $togglePath 'Gather' } 'gather path'))
    $element.LivePathButton.Add_Click((& $protect { & $togglePath 'Capture' } 'live path'))

    # Everything a handler wrote rather than the markup, redrawn in a newly chosen language.
    # Set-TlcWizardString covers what the markup carries; these are the sentences built from
    # state - counts, paths, measured values, the banners - which were each written once in
    # whatever language the window opened in and stayed that way until something re-ran them.
    # Each reads $state.Strings, which the caller has already pointed at the new table.
    $retranslate = {
        param([hashtable] $Table)
        if (-not $element.CancelButton.IsEnabled) {
            $element.CancelButton.Content = Get-TlcString -Table $Table -Key 'RunStopping'
        }
        # A configured or not-required consent keeps saying so rather than reverting to the
        # translated "required" sentence Set-TlcWizardString puts there.
        if ($state.ConsentHintOverride) {
            $element.ConsentHintText.Text = Get-TlcString -Table $Table -Key $state.ConsentHintOverride.Key -Argument $state.ConsentHintOverride['Args']
        }
        & $applyCaptureAvailability
        $element.OutputHintText.Text = if ($state.ConfiguredRunRoot) {
            Get-TlcString -Table $Table -Key 'OutputHintBlank' -Argument @($state.ConfiguredRunRoot)
        } else {
            Get-TlcString -Table $Table -Key 'OutputHintCreated'
        }
        & $renderEndpointHint
        & $renderTiles
        # The run summary, while a run has it on screen in place of the form.
        if ($state.RunScenarioId -and [string]$element.RunSummaryPanel.Visibility -eq 'Visible') {
            $running = @($catalog | Where-Object { $_.Id -eq $state.RunScenarioId })
            if ($running.Count -gt 0) { $element.SummaryScenario.Text = Get-TlcScenarioDisplayName -Scenario $running[0] -Table $Table }
            if ($state.RunModel) { $element.SummaryWindow.Text = Get-TlcRunSummaryWindowText -Model $state.RunModel -Strings $Table }
        }
        & $setMetricAge
        & $refreshToolChoice
        & $refreshScenarioAdvisory
        & $refreshCaseHistory $Table
        & $buildDeepCapability $Table $true
        & $renderCapturePhaseDetail
        if ($element.StopProgressPanel.Visibility -eq 'Visible') {
            Update-TlcStopProgress -Element $element -State $state
        }
        & $renderSupportAction
    }

    # Settings. The language applies live rather than on restart: Set-TlcWizardString is the
    # same function the startup path uses, so there is no second code path that could
    # translate a different set of controls.
    #
    # $showPath is re-run afterwards because the primary button's label belongs to the chosen
    # path, not to the string table - re-setting it here would put "Collect" back over a live
    # trace's "Start trace" every time the language changed.
    $element.SettingsButton.Add_Click((& $protect {
        Write-TlcToolLog -Message "Settings opened (current language $($state.Language))."

        # Copied into locals FIRST, because GetNewClosure captures the LOCAL scope only -
        # $element, $showPath and $ToolboxRoot all belong to Show-TlcWizard, one scope out,
        # and are not captured by it.
        #
        # Without this the callback still ran, because PowerShell then resolved the names
        # dynamically against whatever scope invoked it - which is Show-TlcSettingsWindow,
        # whose own $element is the settings window's six controls. The symptom was
        # "The property 'ScenarioBox' cannot be found on this object" raised from inside
        # ShowDialog, with nothing on screen and the wizard apparently ignoring the button.
        #
        # This is the same trap New-TlcConsentRecord hit reading its caller's locals: a
        # function that works only because of where it happens to be called from.
        $ui = $element
        $setPath = $showPath
        $rerender = $retranslate
        $uiRoot = $ToolboxRoot
        # $state TOO. It was the one name this list missed, so the closure below resolved
        # $state dynamically at call time - from inside the settings window's handler, where
        # it is not the wizard's state - and threw "The property 'Language' cannot be found
        # on this object" on every language change. The window never translated, and the
        # failure could not be shown either, because $protect had the same defect. Found by
        # a debug run on 2026-09-23; finding 289.
        $wizardState = $state

        $apply = {
            param([string] $Tag)
            $wizardState.Language = $Tag
            $table = Get-TlcStringTable -Language $Tag -ToolboxRoot $uiRoot
            # Published on $state as well as applied to the controls. Handlers that RE-RENDER
            # text later - the scenario change re-writes the Rooms hint, $showPath re-writes the
            # primary button - need the CURRENT table, and the outer $strings variable is not it:
            # this scriptblock is GetNewClosure'd, so assigning $strings here would update a
            # captured copy and leave every later handler rendering the startup language. A
            # hashtable mutated in place is visible everywhere, which is why $state already
            # carries UpdateHistory and Platform for the same reason.
            $wizardState.Strings = $table
            Set-TlcWizardString -Element $ui -Strings $table
            # Then everything the handlers built from state rather than from the markup: the
            # tiles, the banners, the hints that carry a count or a path. Each was written in
            # the language the window opened in and stayed that way until something happened
            # to re-run it. $retranslate says which; finding 334.
            & $rerender $table
            & $setPath $(if ($wizardState.Fork) { $wizardState.Fork } else { '' })
        }.GetNewClosure()

        $chosen = Show-TlcSettingsWindow -Owner $window -ToolboxRoot $ToolboxRoot -ThemePath $themePath `
                                         -Current $state.Language -CurrentTheme $state.Theme -OnChange $apply

        # Persisted only when something actually changed, and only after the window closes.
        # Writing on every selection would put a file write behind each keystroke of a
        # drop-down, and persisting a value the operator immediately changed back is a
        # preference they did not express.
        if ($chosen) {
            try {
                $save = @{}
                if ($chosen.ContainsKey('Language')) { $save['Language'] = $chosen['Language'] }
                if ($chosen.ContainsKey('Theme')) {
                    $save['Theme'] = $chosen['Theme']
                    $state.Theme = $chosen['Theme']
                }
                $null = Set-TlcSettings @save

                # The theme cannot be applied to a window whose colours were merged at parse
                # time, so the change is recorded where someone looking for it will find it.
                # The settings window has already said it applies next time.
                if ($save.ContainsKey('Theme')) {
                    Write-TlcToolLog -Message "Appearance set to $($save['Theme']); applies the next time the window opens."
                }
            } catch {
                Write-TlcToolLog -Message "Settings could not be saved: $($_.Exception.Message)" -Level 'WARN'
            }
        }
    } 'settings'))

    $element.CancelButton.Add_Click((& $protect {
        $process = $state.RunProcess
        if (-not $element.CancelButton.IsEnabled -or -not $process -or $process.HasExited) { return }

        # Sync-TlcUiPaint pumps input while the stop handshake waits. Disable first so
        # another click cannot enter this handler and send a second stop request.
        $element.CancelButton.IsEnabled = $false
        $element.CancelButton.Content = Get-TlcString -Table $state.Strings -Key 'RunStopping'
        $state.RunStopRequested = $true
        Update-TlcRunLoading -Element $element -State $state -Running
        try {
        $element.RunStatusText.Text = Get-TlcString -Table $state.Strings -Key 'RunStopping'

        # A live capture session is asked to stop, not killed.
        #
        # Killing it costs the operator the part of the evidence they most need: the samples
        # are on disk because they are appended as they are taken, but Capture.json - the
        # summary that says whether the media path held up, how bad it got, and whether the
        # adapters changed - is written when the session ENDS. A killed session leaves 240
        # JSON lines and nothing that reads them.
        #
        # The first press waits for the session to ACKNOWLEDGE, by removing the sentinel, and
        # then leaves the run alone: it goes on to collect the logs written during the session
        # and to ask for Teams' support files, which takes minutes. This used to wait ten
        # seconds for the process to EXIT and kill it otherwise, so every live trace stopped
        # from here was killed part way through that collection - measured on a 31-minute
        # trace, which lost Capture.json, Run.json and the support files. Finding 321.
        #
        # A second press skips the support-file wait, and then waits for the run to finish.
        # The kill is the fallback for a session that answers neither.
        if ($state.RunFork -eq 'Capture' -and $state.CaptureSignal) {
            # Sampling can already be over without a press - the session's own cap ends it - and
            # then nothing will acknowledge a stop, so the press means "skip the rest" instead.
            if (-not $state.CaptureStopAcknowledged -and $state.CapturePhase -ne 'Collect') {
                $element.LogBox.Text += "`r`n`r`n$(Get-TlcString -Table $state.Strings -Key 'LogStopAsked')"
                $element.LogBox.ScrollToEnd()
                Sync-TlcUiPaint

                # The wait lives in Tlc.Capture rather than here, so the behaviour can be tested
                # without spawning a process and a button handler cannot drift from it.
                $stopResult = Stop-TlcCaptureSession -StopSignalPath $state.CaptureSignal `
                    -IsRunning { -not $process.HasExited }.GetNewClosure() `
                    -TimeoutSeconds 15 -AcceptAcknowledgement -OnWait { Sync-TlcUiPaint }

                if ($stopResult.Stopped -or $stopResult.Acknowledged) {
                    $state.CaptureStopAcknowledged = $true
                    $element.RunStatusText.Text = Get-TlcString -Table $state.Strings -Key 'RunSamplingStopped'
                    $element.LogBox.Text += "`r`n$(Get-TlcString -Table $state.Strings -Key 'LogSamplingStopped' -Argument @(Get-TlcString -Table $state.Strings -Key 'SkipSupportButton'))"
                    $element.LogBox.ScrollToEnd()
                    return
                }
            } else {
                $element.LogBox.Text += "`r`n`r`n$(Get-TlcString -Table $state.Strings -Key 'LogSkippingSupport')"
                $element.LogBox.ScrollToEnd()
                Sync-TlcUiPaint

                $stopResult = Stop-TlcCaptureSession -StopSignalPath $state.CaptureSignal `
                    -IsRunning { -not $process.HasExited }.GetNewClosure() `
                    -TimeoutSeconds 60 -OnWait { Sync-TlcUiPaint }

                if ($stopResult.Stopped) {
                    $element.LogBox.Text += "`r`n$(Get-TlcString -Table $state.Strings -Key 'LogFinishedAfterStop')"
                    $element.LogBox.ScrollToEnd()
                    return
                }
            }

            $element.LogBox.Text += "`r`n$(Get-TlcString -Table $state.Strings -Key 'LogSessionUnanswered')"
            $element.LogBox.ScrollToEnd()
        }

        # Only a run that is actually killed reads as stopped. One that was asked to stop and
        # finished on its own reports how it finished.
        $state.RunCancelled = $true

        # Children first, then the shell that started them. The child is a powershell.exe
        # which has itself spawned the collectors; stopping only that leaves them running
        # with nobody reading their output, and the run folder half written.
        try {
            $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" -ErrorAction SilentlyContinue)
            foreach ($child in $children) {
                Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Verbose "Could not enumerate the run's child processes: $($_.Exception.Message)"
        }

        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue

        # The polling tick sees HasExited on its next pass and runs the normal completion
        # path - re-enabling the buttons, hiding the bar and cleaning the temp files - so
        # cancelling and finishing take the same route out.
        $element.LogBox.Text += "`r`n`r`n$(Get-TlcString -Table $state.Strings -Key 'LogStoppedKept')"
        $element.LogBox.ScrollToEnd()
        } finally {
            $element.CancelButton.IsEnabled = (-not $process.HasExited -and -not $state.RunCancelled -and
                -not $state.CaptureStopAcknowledged -and $state.CapturePhase -ne 'Collect')
            if ($element.CancelButton.IsEnabled) {
                $state.RunStopRequested = $false
                $element.CancelButton.Content = Get-TlcString -Table $state.Strings -Key 'CancelButton'
            }
        }
    } 'cancel run'))

    $element.ShowLiveGraphBox.Add_Checked((& $protect {
        $element.LiveChartPanel.Visibility = 'Visible'
        $element.RunProgress.Visibility = 'Collapsed'
        Update-TlcCaptureChart -Element $element -Samples $state.LiveSamples `
            -IntervalSeconds $state.LiveChartIntervalSeconds -StartedUtc $state.LiveSampleStartedUtc -Centers $state.LiveChartCenters `
            -Loading:($state.RunProcess -and -not $state.RunProcess.HasExited -and $state.LiveSamples.Count -eq 0) `
            -MemoryPreview $(if ($state.Contains('LiveMemoryPreview')) { $state.LiveMemoryPreview })
    } 'show live graphs'))
    $element.ShowLiveGraphBox.Add_Unchecked((& $protect {
        $element.LiveChartPanel.Visibility = 'Collapsed'
        Update-TlcCaptureChart -Element $element -Samples @()
        $element.RunProgress.Visibility = if ($state.RunProcess -and -not $state.RunProcess.HasExited) { 'Visible' } else { 'Collapsed' }
    } 'hide live graphs'))

    $element.GenerateSupportButton.Add_Click((& $protect {
        if (-not $element.GenerateSupportButton.IsEnabled -or $element.SupportActionPanel.Visibility -ne 'Visible') { return }
        $element.GenerateSupportButton.IsEnabled = $false
        $state.SupportPhase = 'Generating'
        & $renderSupportAction
        $element.SupportResultText.Text = Get-TlcString -Table $state.Strings -Key 'RunStarting' -Argument @(0)
        try {
            New-Item -ItemType File -Path "$($state.CaptureSignal).trigger" -Force -ErrorAction Stop | Out-Null
        } catch {
            $element.GenerateSupportButton.IsEnabled = $true
            $state.SupportPhase = 'Fallback'
            & $renderSupportAction
            throw
        }
    } 'generate support files'))

    $element.SkipSupportButton.Add_Click((& $protect {
        if (-not $element.SkipSupportButton.IsEnabled -or $element.SkipSupportButton.Visibility -ne 'Visible') { return }
        $element.SkipSupportButton.IsEnabled = $false
        try {
            New-Item -ItemType File -Path $state.CaptureSignal -Force -ErrorAction Stop | Out-Null
            $element.RunStatusText.Text = Get-TlcString -Table $state.Strings -Key 'LogSkippingSupport'
        } catch {
            $element.SkipSupportButton.IsEnabled = $true
            throw
        }
    } 'skip support files'))

    # Forget removes the case currently in the box; with the box empty it clears the
    # lot, after asking. Deleting a list of customer case numbers on a stray click is
    # not something to do silently, and neither is keeping them when asked not to.
    $element.ForgetCaseButton.Add_Click((& $protect {
        $current = ([string]$element.CaseBox.Text).Trim()

        if ($current) {
            $null = Remove-TlcCaseHistoryEntry -CaseNumber $current
            # Clear the field as well. Leaving the number sitting there after "Forgot
            # 12345." reads as though the click did nothing, and a second click just
            # repeats the same message against an entry that is already gone - which
            # also left the clear-all prompt below unreachable without hand-editing the
            # field. Emptying it makes the second click mean "forget the rest".
            $element.CaseBox.Text = ''
            & $refreshCaseHistory
            $element.CaseHintText.Text = Get-TlcString -Table $state.Strings -Key 'CaseHintForgot' -Argument @($current)
            return
        }

        $remembered = @(Get-TlcCaseHistory)
        if ($remembered.Count -eq 0) { return }

        $answer = [System.Windows.MessageBox]::Show(
            (Get-TlcString -Table $state.Strings -Key 'ForgetAllPrompt' -Argument @($remembered.Count)),
            'TLC Toolbox',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question)

        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            $null = Remove-TlcCaseHistoryEntry -All
            & $refreshCaseHistory
            $element.CaseHintText.Text = Get-TlcString -Table $state.Strings -Key 'CaseHintCleared'
        }
    } 'forget case'))

    $element.ValidateButton.Add_Click((& $protect { & $runStage 'Validate-Only' } 'validate'))
    $element.CollectButton.Add_Click((& $protect { & $runStage 'Collect' } 'collect'))
    $element.PackageButton.Add_Click((& $protect {
        # Any press of Package starts a fresh intent. Without this, a multi-run package
        # that was stopped part way leaves a queue and a pending zip behind, and the next
        # single Package silently resumes someone else's work.
        $state.PackageQueue = @()
        $state.PackageDone = @()
        $state.PackageRefused = @()
        $state.PackageZip = $false

        # One collection: package it, as before. Several: ask which, because only the
        # operator knows which run caught the fault and which two were the wrong window.
        $sessionRuns = @($state.SessionRuns | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($sessionRuns.Count -le 1) { & $runStage 'Package'; return }

        $choice = Show-TlcSessionLogPicker -RunPath $sessionRuns -Owner $window -Warning (& $packagePreflight)
        if (-not $choice) { return }

        # Queued, not looped. Each stage spawns a child process and returns immediately,
        # so packaging three runs in a foreach would start three at once - the exact
        # concurrent-run case the run buttons are disabled to prevent - and would zip
        # before any of them had written anything. The queue is drained one run at a
        # time from the completion handler instead.
        $queue = @($choice.RunPath)
        $state.PackageQueue = @($queue | Select-Object -Skip 1)
        $state.PackageZip = [bool]$choice.Zip
        $state.CorrelationId = Split-Path -Leaf $queue[0]
        $state.RunPath = $queue[0]
        & $runStage 'Package'
    } 'package'))

    $element.OpenButton.Add_Click((& $protect {
        # Invoke-Item rather than Start-Process explorer.exe -ArgumentList: Start-Process does
        # not quote its arguments, and the run folder usually sits under a path with spaces
        # in it, "OneDrive - Microsoft" among them (review 2026-09-30).
        if ($state.RunPath -and (Test-Path -LiteralPath $state.RunPath)) {
            Invoke-Item -LiteralPath $state.RunPath
        }
    } 'open evidence'))

    # --- dashboard tiles are controls, not decoration -----------------------
    # Each opens the same detail window with its own content. The tile answers "how
    # much"; the click answers "which", which is the question everyone asks next and
    # which previously meant rebuilding the same Event Viewer filter by hand.
    $tileDetailOf = {
        param([string] $Name)
        if ($tileMetric.ContainsKey($Name)) { return (Get-TlcMetricDetail -Metric $tileMetric[$Name] -Table $state.Strings) }
        return (Get-TlcString -Table $state.Strings -Key 'TileDetailPending')
    }

    $openLogFolder = {
        # Invoke-Item, not Start-Process explorer.exe -ArgumentList, which does not quote a
        # path with spaces in it (review 2026-09-30).
        if ($logRoot -and (Test-Path -LiteralPath $logRoot)) {
            Invoke-Item -LiteralPath $logRoot
        }
    }.GetNewClosure()

    # The header link. Routed through $protect so a shell that refuses to open a browser
    # cannot take the window down - the same reasoning as every other handler here, and it
    # matters more for this one because a decoration failing is not worth a crash.
    #
    # The URI is read back off the control rather than repeated here. It is declared once
    # in the XAML, next to the text describing it, so the link cannot end up pointing
    # somewhere other than what it says.
    #
    # No param() block: $protect invokes its action with no arguments, so a handler
    # declaring $Sender and $EventArgs would receive neither and then throw reading them
    # under StrictMode - inside a wrapper whose whole job is to swallow that quietly.

    # No NavigateUri on this one, so RequestNavigate would never fire - the handler is on
    # Click instead. A Hyperlink raises Click whether or not it has somewhere to navigate,
    # which is what makes it usable as an in-window action rather than a link out.
    #
    # Wrapped in $protect like every other handler here: a decoration that throws must not
    # take the window down with it.
    $element.ComparisonLink.Add_Click((& $protect {
        Show-TlcCapabilityComparison -Owner $window -Strings $state.Strings -Recommendation $element.ToolChoiceBanner
    } 'feature comparison'))

    # Dismissing records WHAT was dismissed, not THAT something was. $refreshToolChoice runs
    # again on the next scenario change or dashboard refresh and would otherwise put the
    # banner straight back; keying on the advice means it stays gone while it says the same
    # thing, and returns when the recommendation genuinely changes.
    #
    # Collapsing here as well as leaving it to the refresh, because nothing guarantees a
    # refresh follows a click - without this the button would appear to do nothing until the
    # next scenario change.
    $element.ToolChoiceDismiss.Add_Click((& $protect {
        & $dismissBanner 'ToolChoice' $element.ToolChoiceBanner
    } 'dismiss recommendation'))

    $element.ScenarioAdvisoryDismiss.Add_Click((& $protect {
        & $dismissBanner 'ScenarioAdvisory' $element.ScenarioAdvisoryBanner
    } 'dismiss advisory'))

    $element.AudioAdvisoryButton.Add_Click((& $protect {
        $detail = $element.AudioAdvisoryButton.Tag
        if ($detail) {
            & $showDetail -Heading $detail.Heading -Summary $detail.Summary -Body $detail.Body -Facts $detail.Facts
        }
    } 'audio advisory details'))

    # The heading toggles its own section. Both directions: an operator who collapsed it by
    # choosing a job must be able to get it back, and one who expanded it must be able to
    # put it away again without re-picking the job.
    $element.WhatHappenedToggle.Add_Click((& $protect {
        $isCollapsed = ($element.WhatHappenedBody.Visibility -eq 'Collapsed')
        & $setWhatHappenedCollapsed (-not $isCollapsed)
    } 'toggle what happened'))



    # Records consent DURING a run, which is the one field an operator can discover they
    # need after the form has already gone away.
    #
    # It writes into ConsentBox rather than carrying its own value. ConsentBox is what
    # Get-TlcWizardModel reads and what the Package stage is judged against, so a second
    # store would be a second answer to the question the privacy gate refuses on - and the
    # two would disagree the first time somebody used the other one.
    $element.SummaryConsentSave.Add_Click((& $protect {
        $mine = $element.SummaryConsentMeBox.IsChecked -eq $true -and [string]$element.SummaryConsentMeBox.Tag
        $name = if ($mine) { [string]$element.SummaryConsentMeBox.Tag } else { [string]$element.SummaryConsentBox.Text }
        if ([string]::IsNullOrWhiteSpace($name)) {
            [System.Windows.MessageBox]::Show(
                (Get-TlcString -Table $state.Strings -Key 'RecordConsentPrompt'),
                (Get-TlcString -Table $state.Strings -Key 'RecordConsentTitle'), 'OK', 'Warning') | Out-Null
            return
        }

        # Onto the form's own controls, which Get-TlcWizardConsent reads: the account box
        # when that was ticked, the typed field otherwise.
        if ($mine) {
            $element.ConsentMeBox.IsChecked = $true
        } else {
            $element.ConsentMeBox.IsChecked = $false
            $element.ConsentBox.Text = $name.Trim()
        }
        $element.SummaryConsentRow.Visibility = 'Collapsed'
        $element.SummaryWarning.Visibility = 'Collapsed'
        Write-TlcToolLog -Message 'Consent was recorded while a run was in progress.' -Level 'INFO'

        # Into the transcript as well as the field. The run log is what gets read afterwards,
        # and "consent was recorded" belongs in the same place as everything else that
        # happened during the run. Appended the same way the run's own output is.
        $element.LogBox.Text += "`r`n  $(Get-TlcString -Table $state.Strings -Key 'LogConsentRecorded' -Argument @($name.Trim()))"
    } 'record consent'))

    $showDetail = {
        param([string] $Heading, [string] $Summary, [string] $Body, [string] $ActionText, [scriptblock] $Action, $Facts)
        $arguments = @{
            Owner = $window; ToolboxRoot = $ToolboxRoot; ThemePath = $themePath
            Heading = $Heading; Summary = $Summary; Body = $Body
            Dark = $isDark
        }
        if ($Facts) { $arguments['Facts'] = $Facts }
        if ($ActionText -and $Action) { $arguments['ActionText'] = $ActionText; $arguments['Action'] = $Action }
        Show-TlcDetailWindow @arguments
    }.GetNewClosure()

    $element.LogsTile.Add_Click((& $protect {
        $s = $state.Strings
        # Structured values go in Facts and prose goes in Body. They used to be one
        # string with names padded out to line up, which only reads correctly in a
        # monospace font - and that dependency was what made the whole panel monospace.
        $facts = [ordered]@{}
        if ($inventory) {
            $facts[(Get-TlcString -Table $s -Key 'FactFiles')] = Get-TlcString -Table $s -Key 'FactFilesMatching' -Argument @($inventory.FileCount, ($logPatterns -join ', '))
            $facts[(Get-TlcString -Table $s -Key 'FactSize')] = "$([math]::Round($inventory.TotalBytes / 1MB, 1)) MB"
            if ($inventory.OldestStart) { $facts[(Get-TlcString -Table $s -Key 'FactOldest')] = $inventory.OldestStart }
            if ($inventory.NewestWrite) { $facts[(Get-TlcString -Table $s -Key 'FactNewest')] = $inventory.NewestWrite }
        }

        # Free space belongs here rather than on a tile of its own. It only matters in
        # relation to the logs - a full disk stops Teams writing them and stops a
        # collection landing - and a tenth tile that is green on every healthy machine
        # would dilute the ones worth reading. DriveInfo, not WMI: 1 ms against 448 ms.
        $diskNote = ''
        try {
            $drive = [System.IO.DriveInfo]::new($env:SystemDrive)
            $facts[(Get-TlcString -Table $s -Key 'FactFreeDisk')] = Get-TlcString -Table $s -Key 'FactFreeDiskValue' -Argument @([math]::Round($drive.AvailableFreeSpace / 1GB, 1), [math]::Round($drive.TotalSize / 1GB, 1), $env:SystemDrive)
            if ($drive.AvailableFreeSpace -lt 5GB) {
                $diskNote = Get-TlcString -Table $s -Key 'DetailLowDisk'
            }
        } catch {
            Write-Verbose "Free space could not be read: $($_.Exception.Message)"
        }

        $body = if ($logRoot) { "$(Get-TlcString -Table $s -Key 'DetailLogFolderLabel')`r`n$logRoot" } else { Get-TlcString -Table $s -Key 'DetailNoLogFolder' }
        if ($diskNote) { $body += "`r`n$diskNote" }

        & $showDetail (Get-TlcString -Table $s -Key 'TileLogs') (& $tileDetailOf 'LogsTile') $body (Get-TlcString -Table $s -Key 'DetailOpenLogFolder') $openLogFolder $facts
    } 'logs tile'))

    # Shows the STEPS rather than jumping straight to the browser.
    #
    # Reported 2026-09-22: "how to collect logs from admin center is missing". The banner had
    # been telling operators to go to the admin center since it was written, and the only
    # thing behind this link was Microsoft's documentation page - correct, and not the same
    # as being told what to click. The steps, the roles needed and the three preconditions
    # that silently produce no bundle at all now sit one click from the recommendation that
    # sends someone there.
    #
    # The documentation is still one further click away, on the button, because the portal's
    # wording moves and Microsoft's page is the thing that stays right.
    $element.AdminCenterLink.Add_RequestNavigate((& $protect {
        $steps = Get-TlcAdminCenterProcedure
        $s = $state.Strings
        $say = { param($Part) Get-TlcMetricText -Part $Part -Table $s }

        $facts = [ordered]@{}
        $n = 0
        foreach ($step in $steps.Steps) { $n++; $facts[(Get-TlcString -Table $s -Key 'FactStep' -Argument @($n))] = & $say $step }
        $facts[(Get-TlcString -Table $s -Key 'FactRolesNeeded')] = & $say $steps.Roles

        $lines = @(
            Get-TlcString -Table $s -Key 'AdminFromDocs'
            ''
            Get-TlcString -Table $s -Key 'AdminBeforeStart'
            ''
        )
        foreach ($p in $steps.Preconditions) { $lines += "  - $(& $say $p)" }
        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'AdminNotContainHeading'
        $lines += ''
        $lines += & $say $steps.NotCollected
        $lines += ''
        $lines += & $say $steps.Retention
        $lines += ''
        $lines += & $say $steps.PowerShell
        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'AdminDocsButtonNote' -Argument @(Get-TlcString -Table $s -Key 'FactStep' -Argument @(1))

        # The URI comes off the CONTROL, not from a literal here. A copy in the handler is a
        # second place to be wrong and the way a link ends up pointing somewhere other than
        # what it says - there is a test holding this.
        #
        # Read NOW, into a local, and the local captured. The closure used to read
        # $element.AdminCenterLink when the button was pressed, but GetNewClosure does not
        # capture $element - it belongs to an outer scope - so by then it was $null and the
        # button started a process with an empty path. Finding 289.
        $docsUri = [string]$element.AdminCenterLink.NavigateUri
        $openDocs = { Start-Process $docsUri }.GetNewClosure()
        & $showDetail (Get-TlcString -Table $s -Key 'AdminHeading') `
            (Get-TlcString -Table $s -Key 'AdminSummary') `
            ($lines -join [Environment]::NewLine) (Get-TlcString -Table $s -Key 'AdminDocsButton') $openDocs $facts
    } 'admin center steps'))

    $element.ActivityTile.Add_Click((& $protect {
        $s = $state.Strings
        $body = "$(Get-TlcString -Table $s -Key 'DetailActivityBody')`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailLogFolderLabel')`r`n$logRoot"
        & $showDetail (Get-TlcString -Table $s -Key 'TileActivity') (& $tileDetailOf 'ActivityTile') $body (Get-TlcString -Table $s -Key 'DetailOpenLogFolder') $openLogFolder $null
    } 'activity tile'))

    $element.CrashTile.Add_Click((& $protect {
        $s = $state.Strings
        $body = Get-TlcCrashDetail -Hours 24 -Strings $s
        $facts = [ordered]@{}

        # WebView2 renderer crashes, which the Application log above does not record. Shown
        # here whatever the count, because zero from a Crashpad folder that EXISTS is a
        # positive statement - "it has crashed zero times" - and is different from the
        # folder being absent, which says only that this profile has never crashed or that
        # the client stores them elsewhere.
        $webView = $state.WebViewCrash
        if ($webView) {
            $facts[(Get-TlcString -Table $s -Key 'FactWebViewCrashes')] = if (-not $webView.Supported) {
                Get-TlcString -Table $s -Key 'FactWebViewNotMeasurable'
            } elseif ([int]$webView.TotalCount -eq 0) {
                Get-TlcString -Table $s -Key 'FactNoneRecorded'
            } else {
                Get-TlcString -Table $s -Key 'FactWebViewReports' -Argument @($webView.TotalCount, $webView.NewestLocal)
            }
            if ($webView.ReportPath) { $facts[(Get-TlcString -Table $s -Key 'FactReportFolder')] = $webView.ReportPath }
            $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailCrashWebViewBody')"
        }

        & $showDetail (Get-TlcString -Table $s -Key 'DetailHeadingCrash') (& $tileDetailOf 'CrashTile') $body '' $null $facts
    } 'crash tile'))

    $element.ClientTile.Add_Click((& $protect {
        $s = $state.Strings
        $facts = [ordered]@{}
        $body = Get-TlcString -Table $s -Key 'DetailClientBody'
        try {
            $package = (Get-TlcAppxPackage).Teams
            if ($package) {
                $facts[(Get-TlcString -Table $s -Key 'FactVersion')] = $package.Version
                $facts[(Get-TlcString -Table $s -Key 'FactStatus')] = $package.Status
                $facts[(Get-TlcString -Table $s -Key 'FactSignature')] = $package.SignatureKind
                $facts[(Get-TlcString -Table $s -Key 'FactInstallPath')] = $package.InstallLocation
                $facts[(Get-TlcString -Table $s -Key 'FactPresentOnDisk')] = Get-TlcString -Table $s -Key $(if (Test-Path -LiteralPath ([string]$package.InstallLocation)) { 'FactYes' } else { 'FactNo' })
            } else {
                $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailClientNotRegistered')"
            }
        } catch {
            $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailClientUnreadable' -Argument @($_.Exception.Message))"
        }

        # Audio and power fold in here rather than taking a tenth and eleventh tile, for the
        # same reason Wi-Fi went into the Network detail and free disk into the Logs detail:
        # the grid is deliberately 3x3, and a metric that reads green on every healthy
        # machine dilutes the eight beside it that carry a verdict. They are read from
        # $state, already gathered by the dashboard runspace, so opening this costs nothing.
        if ($state.Audio -and $state.Audio.Available) {
            $facts[(Get-TlcString -Table $s -Key 'FactAudioPlayback')] = if ($state.Audio.RenderCount -gt 0) {
                (@($state.Audio.RenderDevices | ForEach-Object { $_.Name }) -join '; ')
            } else { Get-TlcString -Table $s -Key 'FactAudioNoPlayback' }
            $facts[(Get-TlcString -Table $s -Key 'FactAudioRecording')] = if ($state.Audio.CaptureCount -gt 0) {
                (@($state.Audio.CaptureDevices | ForEach-Object { $_.Name }) -join '; ')
            } else { Get-TlcString -Table $s -Key 'FactAudioNoRecording' }
            if ($state.Audio.UnhealthyCount -gt 0) {
                $facts[(Get-TlcString -Table $s -Key 'FactAudioFaults')] = (@($state.Audio.Unhealthy | ForEach-Object { "$($_.Name) [$($_.Status)]" }) -join '; ')
            }
        }
        if ($state.Cache -and $state.Cache.TotalMB) {
            $mb = [double]$state.Cache.TotalMB
            $facts[(Get-TlcString -Table $s -Key 'FactCacheSize')] = if ($mb -ge 1024) {
                '{0:N1} GB' -f ($mb / 1024)
            } else { '{0:N0} MB' -f $mb }
            if ($state.Cache.LargestFolder) { $facts[(Get-TlcString -Table $s -Key 'FactLargestCacheFolder')] = $state.Cache.LargestFolder }
        }

        if ($state.Power) {
            if ($state.Power.PowerScheme) { $facts[(Get-TlcString -Table $s -Key 'FactPowerScheme')] = $state.Power.PowerScheme }
            $facts[(Get-TlcString -Table $s -Key 'FactPowerSource')] = if ($state.Power.OnBattery -eq $true) {
                if ($null -ne $state.Power.ChargePercent) { Get-TlcString -Table $s -Key 'FactBatteryAt' -Argument @($state.Power.ChargePercent) } else { Get-TlcString -Table $s -Key 'FactBattery' }
            } elseif ($state.Power.OnBattery -eq $false) {
                Get-TlcString -Table $s -Key 'FactMains'
            } else {
                [string]$state.Power.BatteryDetail
            }
        }

        & $showDetail (Get-TlcString -Table $s -Key 'DetailHeadingClient') (& $tileDetailOf 'ClientTile') $body '' $null $facts
    } 'client tile'))

    $element.RetentionTile.Add_Click((& $protect {
        $s = $state.Strings
        $facts = [ordered]@{}
        if ($inventory) {
            if ($inventory.OldestStart) { $facts[(Get-TlcString -Table $s -Key 'FactOldest')] = $inventory.OldestStart }
            if ($inventory.NewestWrite) { $facts[(Get-TlcString -Table $s -Key 'FactNewest')] = $inventory.NewestWrite }
            if ($inventory.RollingFileCount -and
                $inventory.RollingFileCount -ne $inventory.FileCount) {
                $facts[(Get-TlcString -Table $s -Key 'FactMeasuredFrom')] = Get-TlcString -Table $s -Key 'FactMeasuredFromValue' -Argument @($inventory.RollingFileCount, $inventory.FileCount)
            } else {
                $facts[(Get-TlcString -Table $s -Key 'FactFiles')] = $inventory.FileCount
            }
        }
        $body = Get-TlcString -Table $s -Key 'DetailRetentionBody'
        if ($inventory -and $inventory.RollingFileCount -ne $inventory.FileCount) {
            $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailRetentionRolling')"
        }
        & $showDetail (Get-TlcString -Table $s -Key 'TileRetention') (& $tileDetailOf 'RetentionTile') $body (Get-TlcString -Table $s -Key 'DetailOpenLogFolder') $openLogFolder $facts
    } 'retention tile'))

    $element.CoverageTile.Add_Click((& $protect {
        $s = $state.Strings
        $fork = if ($state.Fork) { $state.Fork } else { 'Gather' }
        $model = Get-TlcWizardModel -Element $element -Catalog $catalog -Stage 'Collect' -CorrelationId $state.CorrelationId -CaptureStopSignalPath $state.CaptureSignal -Fork $fork

        # The facts are the window this tile measured. When it did not measure one - no path
        # chosen yet, or the live path, where there is no window at all - listing an impact
        # time and a span either side would present the form's seeded defaults as the run's
        # actual settings. The tile itself says it does not apply; its detail window must not
        # then hand over three numbers that look like it does.
        $facts = [ordered]@{}
        if ($state.Fork -and $fork -ne 'Capture') {
            $facts = [ordered]@{}
            $facts[(Get-TlcString -Table $s -Key 'ImpactTimeLabel')] = $model.ImpactTime
            $facts[(Get-TlcString -Table $s -Key 'FactBefore')] = Get-TlcString -Table $s -Key 'FactMinutes' -Argument @($model.WindowBeforeMinutes)
            $facts[(Get-TlcString -Table $s -Key 'FactAfter')] = Get-TlcString -Table $s -Key 'FactMinutes' -Argument @($model.WindowAfterMinutes)
        }

        $body = if (-not $state.Fork) {
            Get-TlcString -Table $s -Key 'DetailCoverageBodyPick'
        } elseif ($fork -eq 'Capture') {
            Get-TlcString -Table $s -Key 'DetailCoverageBodyLive'
        } else {
            Get-TlcString -Table $s -Key 'DetailCoverageBodyGather'
        }
        & $showDetail (Get-TlcString -Table $s -Key 'DetailHeadingCoverage') (& $tileDetailOf 'CoverageTile') $body '' $null $facts
    } 'coverage tile'))

    $element.NetworkTile.Add_Click((& $protect {
        $s = $state.Strings
        $facts = [ordered]@{}
        $lines = @()
        try {
            $intermediation = Get-TlcNetworkIntermediation
            $facts[(Get-TlcString -Table $s -Key 'FactPath')] = Get-TlcMetricText -Part (Get-TlcNetworkPathPart -Intermediation $intermediation) -Table $s

            # The TLS chain, which is the other half of "is this traffic reaching Microsoft
            # untouched". Shown whether or not it is clean: a chain ending at a public root
            # is a positive statement, and the tile's green depends on it.
            $tls = $state.Tls
            if ($tls) {
                $facts[(Get-TlcString -Table $s -Key 'FactTlsChain')] = if (-not $tls.Handshake) {
                    Get-TlcString -Table $s -Key 'FactTlsNoHandshake' -Argument @($tls.HostName)
                } elseif ($tls.PubliclyRooted) {
                    Get-TlcString -Table $s -Key 'FactTlsPublicRoot' -Argument @($tls.ChainRoot)
                } else {
                    Get-TlcString -Table $s -Key 'FactTlsNotPublic' -Argument @($tls.ChainRoot)
                }
                if ($tls.TlsProtocol) { $facts[(Get-TlcString -Table $s -Key 'FactTlsProtocol')] = $tls.TlsProtocol }
            }
            foreach ($tunnel in $intermediation.Tunnels) {
                $services = @($tunnel.Services | ForEach-Object { "$($_.Name) = $($_.Status)" }) -join ', '
                # The service names and their states are what Windows reports, so they stay as read.
                $running = Get-TlcString -Table $s -Key $(if ($tunnel.Running) { 'FactYes' } else { 'FactNo' })
                $facts[$tunnel.Product] = "$(Get-TlcString -Table $s -Key 'FactTunnelState' -Argument @($tunnel.Kind, $running))$(if ($services) { " ($services)" })"
            }
            foreach ($name in 'teams.microsoft.com', 'worldaz.tr.teams.microsoft.com') {
                $chain = Resolve-TlcDnsChain -HostName $name
                $lines += Get-TlcString -Table $s -Key 'DetailDnsResolves' -Argument @($name, ($chain.Addresses -join ', '), $chain.HopCount)
                foreach ($hop in $chain.Chain) {
                    $target = if ($hop.Contains('NameHost')) { $hop.NameHost } else { $hop.IPAddress }
                    $lines += "    $($hop.Name) [$($hop.Type)] -> $target"
                }
                $lines += ''
            }

            # The radio, folded in here rather than given a tenth tile. It belongs to the
            # network path, and the dashboard grid is deliberately 3x3 - it was tightened from
            # 162px to 92px on request, and a tile that reads green on every wired machine
            # would dilute the eight that carry a verdict. Same call as the free-disk fact,
            # which went into the Logs detail for the same reason.
            $wifi = Get-TlcWifiFact
            $facts[(Get-TlcString -Table $s -Key 'FactWifi')] = switch ($wifi.State) {
                'NotPresent'   { Get-TlcString -Table $s -Key 'FactWifiNone' }
                'Disconnected' { Get-TlcString -Table $s -Key 'FactWifiDisconnected' }
                'Connected'    {
                    $parts = @()
                    if ($wifi.SignalPercent) { $parts += Get-TlcString -Table $s -Key 'FactWifiSignal' -Argument @($wifi.SignalPercent) }
                    if ($wifi.Band) { $parts += $wifi.Band }
                    if ($wifi.RadioType) { $parts += $wifi.RadioType }
                    if ($wifi.ReceiveMbps) { $parts += Get-TlcString -Table $s -Key 'FactWifiReceive' -Argument @($wifi.ReceiveMbps) }
                    if ($parts.Count) { $parts -join ', ' } else { Get-TlcString -Table $s -Key 'FactWifiNoDetail' }
                }
                default        { $wifi.Detail }
            }
        } catch {
            $lines += Get-TlcString -Table $s -Key 'DetailNetworkUnreadableBody' -Argument @($_.Exception.Message)
        }
        $body = Get-TlcString -Table $s -Key 'DetailNetworkBody'
        if ($lines.Count) { $body += "`r`n`r`n" + ($lines -join [Environment]::NewLine) }
        & $showDetail (Get-TlcString -Table $s -Key 'TileNetwork') (& $tileDetailOf 'NetworkTile') $body '' $null $facts
    } 'network tile'))

    $element.UpdateTile.Add_Click((& $protect {
        $s = $state.Strings
        $facts = [ordered]@{}
        $body = Get-TlcString -Table $s -Key 'DetailUpdateBody'
        $history = $state.UpdateHistory
        if ($history) {
            $facts[(Get-TlcString -Table $s -Key 'FactCurrentVersion')] = $history.CurrentVersion
            if ($history.StagedAtLocal) { $facts[(Get-TlcString -Table $s -Key 'FactBuildStaged')] = $history.StagedAtLocal }
            $facts[(Get-TlcString -Table $s -Key 'FactLauncherLogs')] = Get-TlcString -Table $s -Key 'FactScanned' -Argument @($history.Scanned)

            if (@($history.Transitions).Count -gt 0) {
                $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailUpdateHistory')`r`n"
                foreach ($transition in $history.Transitions) {
                    $when = [datetime]::Parse($transition.WhenLocal, [cultureinfo]::InvariantCulture)
                    $body += ("`r`n{0}    {1}  ->  {2}" -f $when.ToString('yyyy-MM-dd HH:mm'), $transition.From, $transition.To)
                }
                $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailUpdateRetention')"
            } else {
                $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailUpdateNoChange')"
            }
        } else {
            $body += "`r`n`r`n$(Get-TlcString -Table $s -Key 'DetailUpdateNotLoaded')"
        }
        & $showDetail (Get-TlcString -Table $s -Key 'TileUpdate') (& $tileDetailOf 'UpdateTile') $body '' $null $facts
    } 'update tile'))

    $element.SignInTile.Add_Click((& $protect {
        $s = $state.Strings
        $facts = [ordered]@{}

        # The per-identity breakdown, first, because it is the thing the tile is actually
        # talking about. Before this the window reported "1 person, 2 tenants" and then
        # said nothing whatever about either, so an operator looking at a working machine
        # had no way to check the claim or act on it.
        $metric = $state.SignIn
        if ($metric -and $metric.Contains('Identities') -and @($metric.Identities).Count -gt 0) {
            $i = 0
            foreach ($identity in $metric.Identities) {
                $i++
                $status = if ($identity.Declared) { Get-TlcString -Table $s -Key 'FactIdentityExpected' } else { Get-TlcString -Table $s -Key 'FactIdentityUndeclared' }
                # Resolved is false when the account carried no domain; the metric keeps the
                # English word for logs, and the window says it in the operator's language.
                $tenant = if ($identity.Contains('Resolved') -and -not $identity.Resolved) { Get-TlcString -Table $s -Key 'FactTenantUnresolved' } else { [string]$identity.Tenant }
                if ($identity.TenantId) { $tenant += " / $($identity.TenantId)" }
                $facts[(Get-TlcString -Table $s -Key 'FactIdentity' -Argument @($i))] = Get-TlcString -Table $s -Key 'FactIdentityValue' -Argument @($tenant, $identity.Id, $status)
            }
        }

        if ($stateRoot) { $facts[(Get-TlcString -Table $s -Key 'FactStateFolder')] = $stateRoot }
        $facts[(Get-TlcString -Table $s -Key 'FactAccountsExpected')] = @($privacyConfig.KnownAccountIds).Count
        $facts[(Get-TlcString -Table $s -Key 'FactRefuseUnexpected')] = Get-TlcString -Table $s -Key $(if ($privacyConfig.BlockOnUnknownAccount) { 'FactYes' } else { 'FactNo' })

        $declareLabel = Get-TlcString -Table $s -Key 'DeclareButton'
        $lines = @(
            Get-TlcString -Table $s -Key 'DetailSignInDeclared'
            ''
            Get-TlcString -Table $s -Key 'DetailSignInWhy'
            ''
            Get-TlcString -Table $s -Key 'DetailSignInNothingSent'
        )

        if ($metric -and $metric.Contains('UndeclaredCount') -and [int]$metric.UndeclaredCount -gt 0) {
            $localPath = ''
            # The per-user overlay, which is where the button below writes: never into the
            # toolbox folder, which may be read-only or shared. Finding 323.
            $pathFinder = Get-Command -Name 'Get-TlcUserConfigPath' -ErrorAction SilentlyContinue
            if ($pathFinder) { $localPath = [string](& $pathFinder) }

            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInHowHeading'
            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInPress' -Argument @($declareLabel)
            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInByHand'
            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInStep1'
            if ($localPath) { $lines += "   $localPath" }
            $lines += Get-TlcString -Table $s -Key 'DetailSignInStep2'
            $lines += ''
            # The snippet is PowerShell, so it stays exactly as typed in every language.
            $lines += '      @{ Privacy = @{ KnownAccountIds = @('
            $lines += "          '00000000-0000-0000-0000-000000000000'"
            $lines += "          '11111111-1111-1111-1111-111111111111'"
            $lines += '      ) } }'
            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInStep3'
            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInShortIds'
            $lines += ''
            $lines += Get-TlcString -Table $s -Key 'DetailSignInOptOut'
        }

        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'DetailSignInAboutHeading'
        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'DetailSignInDomain'
        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'DetailSignInSource'
        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'DetailSignInTwoTenants'
        $lines += ''
        $lines += Get-TlcString -Table $s -Key 'DetailSignInGreen'

        # The Notepad task, offered as a button. Only when there is something to declare -
        # a green tile gets no button, because there is nothing for it to do.
        #
        # It is a BUTTON rather than something the toolbox does on its own. Writing account
        # ids onto a machine is a disclosure decision and belongs to the operator; a default
        # that did it quietly would be the thing the privacy gate exists to prevent, wearing
        # a helpful face.
        $declareText = ''
        $declareAction = $null
        if ($metric -and $metric.Contains('UndeclaredCount') -and [int]$metric.UndeclaredCount -gt 0) {
            $declareText = $declareLabel

            # Copied into a local first, because GetNewClosure captures this scope only and the
            # name belongs to Show-TlcWizard. Uncaptured, $stateRoot read as empty, so the
            # button looked for 'app_settings.json' relative to wherever the process happened
            # to be, found nothing, and told the operator there were no accounts to declare -
            # on the very tile that had just counted them. Finding 289. The string table is
            # copied for the same reason.
            $declareStateRoot = $stateRoot
            $declareStrings = $s

            $declareAction = {
                $declareTitle = Get-TlcString -Table $declareStrings -Key 'DeclareTitle'
                try {
                    $settings = Join-Path $declareStateRoot 'app_settings.json'
                    $ids = @()
                    if (Test-Path -LiteralPath $settings) {
                        $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
                        if ($json.PSObject.Properties.Name -contains 'active_users') {
                            $ids = @($json.active_users | ForEach-Object { [string]$_.id } | Where-Object { $_ })
                        }
                    }
                    if (@($ids).Count -eq 0) {
                        [System.Windows.MessageBox]::Show(
                            (Get-TlcString -Table $declareStrings -Key 'DeclareNoIds'),
                            $declareTitle, 'OK', 'Warning') | Out-Null
                        return
                    }

                    $target = Get-TlcUserConfigPath
                    $written = Add-TlcKnownAccountId -LocalPath $target -AccountId $ids

                    $message = if ($written.Written) {
                        $note = "$(Get-TlcString -Table $declareStrings -Key 'DeclareDone' -Argument @(@($written.Added).Count))`r`n$target"
                        if ($written.BackupPath) { $note += "`r`n`r`n$(Get-TlcString -Table $declareStrings -Key 'DeclareBackup')`r`n$($written.BackupPath)" }
                        $note += "`r`n`r`n$(Get-TlcString -Table $declareStrings -Key 'DeclareReopen' -Argument @(Get-TlcString -Table $declareStrings -Key 'TileSignIn'))"
                        $note
                    } else {
                        "$(Get-TlcString -Table $declareStrings -Key 'DeclareNothing')`r`n$target"
                    }
                    Write-TlcToolLog -Message "Declared $(@($written.Added).Count) account id(s) into the local overlay." -Level 'INFO'
                    [System.Windows.MessageBox]::Show($message, $declareTitle, 'OK', 'Information') | Out-Null
                } catch {
                    Write-TlcToolLog -Message 'Declaring the signed-in accounts failed.' -Level 'WARN' -ErrorRecord $_
                    [System.Windows.MessageBox]::Show(
                        "$(Get-TlcString -Table $declareStrings -Key 'DeclareFailed')`r`n`r`n$($_.Exception.Message)",
                        $declareTitle, 'OK', 'Error') | Out-Null
                }
            }.GetNewClosure()
        }

        & $showDetail (Get-TlcString -Table $s -Key 'DetailHeadingSignIn') (& $tileDetailOf 'SignInTile') ($lines -join [Environment]::NewLine) $declareText $declareAction $facts
    } 'sign-in tile'))

    & $onChanged

    # The caption bar belongs to the desktop window manager, so a dark theme on the content
    # leaves a white title bar above it. Hooked on SourceInitialized because the handle does
    # not exist before that and the caption is already painted after it.
    $window.Add_SourceInitialized({
            $null = Set-TlcWindowDarkChrome -Window $window -Dark $isDark
        }.GetNewClosure())

    $null = $window.ShowDialog()
}

Export-ModuleMember -Function Initialize-TlcWizardScenarioList, Get-TlcWizardSelectedScenario, Update-TlcStopProgress, Initialize-TlcCaptureReading, Update-TlcRunLoading, ConvertTo-TlcQuotedArgument, Update-TlcCaptureChart, Update-TlcTranscriptView, New-TlcUiCommand, ConvertTo-TlcWindowTranscript, Add-TlcRunOutput, ConvertFrom-TlcWizardTimeText,
    Resolve-TlcWizardImpactTime, ConvertTo-TlcWindowMinuteCount, Set-TlcRunActionButton, Select-TlcStaleWizardLog, New-TlcWindowExceptionHandler, New-TlcUiRunnerScript, Get-TlcWizardConsent, Get-TlcDeepCaptureReasonText, Set-TlcWizardConsentAccount, Set-TlcWizardScenarioName, Update-TlcWizardConsentField, Get-TlcWizardModel, Get-TlcRunSummaryWindowText, Get-TlcCoverageTileOverride, Test-TlcScenarioSupportsCapture, Get-TlcChevronOpacity, ConvertTo-TlcCaptureIntervalSeconds, Set-TlcWizardString, Show-TlcSettingsWindow, Show-TlcDetailWindow, Get-TlcCrashDetail, Show-TlcWizard
