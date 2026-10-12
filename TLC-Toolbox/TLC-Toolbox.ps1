<#
.SYNOPSIS
    TLC-Toolbox - Teams Log Collection Toolbox.

.DESCRIPTION
    Automates the SfMC Log Collection Guidelines for Microsoft Teams, using the
    EPO-Toolbox backbone: staged execution, a .psd1 configuration contract, a
    correlated run folder, structured evidence, and a no-change validation mode.

    Teams support files cannot be collected silently - Ctrl + Alt + Shift + 1 is a
    user-initiated client action with no supported API. This toolbox is therefore a
    guided collector, splitting every scenario into Auto, Prompted and Manual lanes
    so that anything not collected is visible in the bundle rather than missing
    without explanation.

.PARAMETER Stage
    Stage to run: Scope, Collect, Validate or Package, in that order; each includes the ones
    before it. PreCheck is accepted and runs Collect -ValidationOnly. Report is not built and is
    refused. Every stage needs -Scenario, and -CaseNumber unless Scope.RequireCaseNumber is
    off; a stage acting on an earlier run also takes that run's -CorrelationId.

    Capture is the live fork and sits alongside Collect rather than after it. Collect selects
    from logs that already exist; Capture samples the machine while the operator reproduces the
    fault, creating evidence that would not otherwise be written. See docs\two-forks-design.md.

.PARAMETER Scenario
    Scenario id from the Log Collection Matrix. Use -ListScenarios to enumerate.

.PARAMETER ValidationOnly
    Runs discovery and readiness, writes the plan and evidence, collects nothing.

.PARAMETER IncludeRawIdentifiers
    Puts raw tenant, device and account ids into the bundle. Without it they appear only as
    stable masks (first eight and last four characters). Covers the join state, TacCorrelation
    and IdentityInventory.json. Give it to Collect and to Package when support needs raw values.

.EXAMPLE
    .\TLC-Toolbox.ps1 -Stage Scope -Scenario DesktopLaunchCrash -ValidationOnly

.EXAMPLE
    .\TLC-Toolbox.ps1 -Stage Collect -Scenario CallQuality -CaseNumber 1234567890123456 -ImpactTime '2026-08-21 09:15'

.EXAMPLE
    .\TLC-Toolbox.ps1 -Stage Capture -Scenario CallQuality -CaseNumber 1234567890123456 -CaptureIntervalSeconds 5
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Scope', 'PreCheck', 'Collect', 'Capture', 'Validate', 'Package', 'Report')]
    [string] $Stage = 'Scope',

    [string] $Scenario,

    [string] $ConfigPath,

    [string] $OutputRoot,

    [string] $CorrelationId,

    [string] $CaseNumber,

    [string] $AffectedUser,

    # Who authorised collection from this machine, for this engagement.
    #
    # It is a parameter and not a config value because consent is per engagement. The
    # shipped config leaves Privacy.ConsentGrantedBy empty and the local operator config
    # says so out loud: a standing value in an operator file would assert consent that
    # nobody actually gave, and would do it silently on every future run.
    #
    # Supplied here it lives exactly as long as the run does. It reaches the consent record
    # and the privacy gate, and nothing writes it back to any config file.
    [string] $ConsentGrantedBy,

    [string] $ClientType,

    [datetime] $ImpactTime = (Get-Date),

    [int] $WindowBeforeMinutes,

    [int] $WindowAfterMinutes,

    [string] $Description,

    [switch] $SkipPrompted,

    # Opt-in packet capture alongside a live session. Off by default, and deliberately.
    #
    # It needs administrator rights, it writes an ETL that grows with traffic, and it is
    # machine-wide - so it is a decision an operator makes on purpose for a case that needs the
    # wire, not something that happens because they ticked "capture live". Headers only, capped,
    # and stopped when the session ends; a sweep at the start of every capture reports one left
    # behind by an earlier session.
    [switch] $DeepCapture,

    # Live capture (-Stage Capture). Sampling cadence and the safety cap.
    #
    # Five seconds by default: the probes cost roughly half a second, so a one-second grid
    # would spend half its time observing, and anything slower than about ten seconds cannot
    # see a glitch short enough for a user to describe as "it cut out for a moment".
    [int] $CaptureIntervalSeconds = 5,

    # A session an operator forgets about must still end. Sixty minutes at five seconds is
    # 720 samples, which is a few hundred KB - the cap is against an abandoned session running
    # for days, not against the size of an honest one.
    [int] $CaptureMaxMinutes = 60,

    # Where the window writes the stop sentinel. A file rather than a handle, so a UI process
    # that is killed mid-session still leaves a session that can be stopped, and the samples
    # already written survive.
    [string] $CaptureStopSignalPath,

    [int] $PromptTimeoutMinutes = 10,

    [string] $TargetDevice,

    # Fleet mode. Additional machines to collect from in the same correlated run, alongside
    # this one. Absent means the ordinary single-machine collection, which is why it defaults
    # to empty rather than to the local computer - see docs\fleet-mode-plan.md.
    #
    # NOT named -Endpoint. PowerShell variable names are case-insensitive, so a parameter named
    # $Endpoint IS the $endpoint local the Collect, Validate and Package stages already use for
    # the machine being collected from - and a [string[]] type constraint on the parameter
    # silently coerces every one of those string assignments to a one-element array. Four
    # collection tests failed on "cannot convert System.String[] to System.String" before this
    # was renamed, none of them anywhere near fleet code.
    [string[]] $FleetEndpoint = @(),

    # Cloud Video Interop correlation. All optional: an engineer standing in a meeting
    # room will not have every value, and the correlation header lists what is missing
    # rather than refusing to be written. See docs\cvi-and-rooms.md.
    [string] $MeetingId,

    [string] $VideoTeleconferenceId,

    [string] $RoomResourceAccount,

    [string] $CodecAddress,

    [ValidateSet('Cisco', 'Pexip', 'Poly', 'Unknown')]
    [string] $CviPartner,

    [pscredential] $Credential,

    [switch] $ValidationOnly,

    # Raw tenant, device and account ids in the bundle. Off by default, so the bundle carries
    # only stable masks: raw identity should be a decision someone made, not a default they
    # inherited. Covers the join state, TacCorrelation and the identity inventory. Owner
    # decision 2026-09-24; finding 296.
    [switch] $IncludeRawIdentifiers,

    [switch] $ListScenarios
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolboxRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $toolboxRoot 'Modules'

# Before anything else, because everything else assumes it. A machine managed by WDAC or
# AppLocker runs PowerShell in ConstrainedLanguage, where this toolbox cannot function: the
# config file alone cannot be parsed there, and the collectors use [math], [System.IO.File],
# [Environment] and [Convert], all of which are refused.
#
# Without this check the run still failed - but it failed reporting "Configuration file could
# not be parsed", naming a file that is perfectly healthy. Measured 2026-09-10. That sends an
# engineer to inspect the config, or worse, to edit it. The mode is the cause and the mode is
# what gets named.
#
# Only property reads and string comparison here, so this check itself survives the mode it
# reports on. See finding 152.
$languageMode = 'unknown'
try { $languageMode = "$($ExecutionContext.SessionState.LanguageMode)" } catch { Write-Verbose 'Language mode unavailable; continuing.' }
if ($languageMode -ne 'FullLanguage' -and $languageMode -ne 'unknown') {
    Write-Warning "TLC-Toolbox cannot run in $languageMode mode."
    Write-Warning 'This machine restricts PowerShell, usually through WDAC or AppLocker. The toolbox needs FullLanguage: its configuration file cannot even be parsed otherwise, and the collectors rely on types this mode forbids. Nothing has been collected and nothing has been changed.'
    Write-Warning 'Options: run from a machine or account not covered by that policy, use the Teams admin center remote log collection instead, or ask the customer to permit this script under their policy.'
    throw "PowerShell is in $languageMode; TLC-Toolbox requires FullLanguage."
}

foreach ($module in 'Tlc.Config', 'Tlc.Logging', 'Tlc.Scope', 'Tlc.Collect.Desktop', 'Tlc.Collect.Rooms',
                    'Tlc.Collect.Web', 'Tlc.Collect.Network', 'Tlc.Collect.Cvi', 'Tlc.Capture', 'Tlc.Manual', 'Tlc.Fleet',
                    'Tlc.Privacy', 'Tlc.Package') {
    Import-Module (Join-Path $modulePath "$module.psm1") -Force -DisableNameChecking
}

if ($ListScenarios) {
    Get-TlcScenarioCatalog | ForEach-Object {
        [pscustomobject]@{
            Id       = $_.Id
            Component= $_.Component
            Auto     = $_.Auto.Count
            Prompted = $_.Prompted.Count
            Manual   = $_.Manual.Count
            Name     = $_.Name
        }
    }
    return
}

$explicitConfig = [bool] $ConfigPath
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $toolboxRoot 'Config\TeamsLogCollection.config.psd1'
}

# The run variable is declared here so the failure handler at the bottom can tell
# whether a run folder exists yet, and therefore whether diagnostics have anywhere
# to go. Everything from this point is inside the guard.
$run = $null

<#
    PRECHECK IS AN ALIAS, NOT A STAGE.

    Older notes describe a PreCheck stage meaning "discovery and readiness, collect nothing".
    That job already exists and has a different name: -Stage Collect -ValidationOnly. It is NOT
    -Stage Validate, which re-checks the artifacts of a run that already happened - the similar
    names are exactly why the mapping is stated here rather than guessed at by an operator.

    So PreCheck runs that job and says so, rather than being refused. Until 2026-09-23 it fell to
    the not-implemented branch and reported Complete for a run that did nothing (finding 285);
    refusing it honestly was better, and giving the operator what they meant is better again.

    Decided the same day: Report was DROPPED rather than built. It never had defined behaviour,
    and everything a report would carry is already written - Summary.csv, Blockers.csv and
    ManualChecklist.md by Collect, Manifest.json by Package. It is still accepted, so older notes
    get a sentence, and it is still Blocked. Finding 291.

    $requestedStage keeps the name that was typed, so Run.json records what was asked for as
    well as what ran.
#>
$requestedStage = $Stage
if ($Stage -eq 'PreCheck') {
    Write-Information "PreCheck is now -Stage Collect -ValidationOnly: discovery and readiness, collecting nothing. Running that." -InformationAction Continue
    $Stage = 'Collect'
    $ValidationOnly = [switch]$true
}

try {

$config = Import-TlcConfig -ConfigPath $ConfigPath

# An operator naming a file with -ConfigPath means that file and nothing else. The
# overlay applies only to the shipped default, so a fixture config in a test never
# picks up the running machine's identifiers.
if (-not $explicitConfig) {
    $config = Merge-TlcLocalConfig -Config $config -LocalPath (Get-TlcLocalConfigPath -ToolboxRoot $toolboxRoot)
    # Then the per-user overlay the wizard's Declare button writes, so the toolbox folder is
    # never written to and runs from a read-only share. Finding 323.
    $config = Merge-TlcLocalConfig -Config $config -LocalPath (Get-TlcUserConfigPath)
}

if (-not $Scenario) { $Scenario = $config.Scope.DefaultScenario }

# Consent applies to this run only. Set on the in-memory config so the gate, the consent
# record and the bundle all read one value, and never written back to disk - the whole point
# of taking it per run is that it expires with the run.
#
# An explicitly empty -ConsentGrantedBy is honoured as "not granted" rather than ignored, so
# passing the parameter can never be a way to accidentally assert consent.
if ($PSBoundParameters.ContainsKey('ConsentGrantedBy')) {
    $config.Privacy.ConsentGrantedBy = $ConsentGrantedBy
}

# The same check the wizard runs before it spawns anything. Shared rather than duplicated:
# a pre-flight check carrying its own copy of these conditions would eventually pass a run
# this then refuses, and an operator who learns the fast check lies will stop trusting it.
$requestProblems = @(Test-TlcRunRequest -Scenario $Scenario -CaseNumber $CaseNumber `
                                        -ValidationOnly:$ValidationOnly -Config $config)
if ($requestProblems.Count -gt 0) { throw $requestProblems[0].Message }

$scenarioEntry = Resolve-TlcScenario -Scenario $Scenario

$effective = Get-TlcEffectiveConfig -Config $config -OutputRoot $OutputRoot -Scenario $scenarioEntry.Id

$run = Initialize-TlcRun -RunRoot $effective.RunRoot `
                         -Scenario $scenarioEntry.Id `
                         -CorrelationId $CorrelationId `
                         -CaseNumber $CaseNumber `
                         -CustomerName $config.CustomerName `
                         -ValidationOnly:$ValidationOnly

Write-Information "TLC-Toolbox run $($run.CorrelationId)" -InformationAction Continue
Write-Information "  Scenario : $($scenarioEntry.Name)" -InformationAction Continue
Write-Information "  Stage    : $Stage" -InformationAction Continue
Write-Information "  Run path : $($run.RunPath)" -InformationAction Continue

$windowBefore = if ($PSBoundParameters.ContainsKey('WindowBeforeMinutes')) { $WindowBeforeMinutes } else { $config.Scope.ReproWindowBeforeMinutes }
$windowAfter = if ($PSBoundParameters.ContainsKey('WindowAfterMinutes')) { $WindowAfterMinutes } else { $config.Scope.ReproWindowAfterMinutes }

# Which of the two jobs this run is doing, decided once and then obeyed by every
# reader of the scope record.
#
# -Stage Capture takes no -ImpactTime and no window minutes: the command builder
# suppresses them because a live trace's window IS the session. That left the
# defaults in play here, so a capture run recorded a full retrospective window
# around "now" that nothing in the capture path ever read. Measured on run
# 8ba960dd: an hour-wide window on a trace that covered seconds.
$windowMode = if ($Stage -eq 'Capture') { 'Live' } else { 'Retrospective' }

# Package, Report and Validate act ON a finished run and are handed its correlation
# id, so they land in the same folder and re-run this phase - overwriting Scope.json.
# Without this, packaging a live trace would replace its empty window with exactly
# the retrospective lie the mode exists to prevent, and the bundle handed over would
# carry it. The mode is read back from what the run already recorded rather than
# re-derived, because by then the stage no longer says which fork it was.
if ($windowMode -eq 'Retrospective' -and $Stage -in @('Package', 'Report', 'Validate')) {
    $priorScopePath = Join-Path $run.RunPath 'Scope.json'
    if (Test-Path -LiteralPath $priorScopePath) {
        try {
            $priorScope = Get-Content -LiteralPath $priorScopePath -Raw -ErrorAction Stop | ConvertFrom-Json
            $priorMode = $priorScope.PSObject.Properties |
                         Where-Object { $_.Name -eq 'WindowMode' } |
                         Select-Object -First 1
            if ($priorMode -and [string]$priorMode.Value -eq 'Live') { $windowMode = 'Live' }
        } catch {
            Write-Verbose "Existing Scope.json in $($run.RunPath) could not be read; treating this run as retrospective."
        }
    }
}

$scope = New-TlcScopeRecord -Scenario $scenarioEntry.Id `
                            -ImpactTime $ImpactTime `
                            -WindowBeforeMinutes $windowBefore `
                            -WindowAfterMinutes $windowAfter `
                            -AffectedUser $AffectedUser `
                            -CaseNumber $CaseNumber `
                            -ClientType $ClientType `
                            -Description $Description `
                            -WindowMode $windowMode

$scopePath = Export-TlcEvidence -Name 'Scope.json' -InputObject $scope
$scopeMessage = if ($windowMode -eq 'Live') {
    'Live trace: no retrospective window. The times covered are measured by the capture session.'
} else {
    "Repro window $($scope.WindowStart.UtcTime) to $($scope.WindowEnd.UtcTime) UTC"
}
Write-TlcEvent -Phase 'Scope' -Step 'CaptureScope' -Status 'Complete' `
               -Message $scopeMessage `
               -EvidencePath $scopePath

# A bare time on the command line is resolved against today, so -ImpactTime '22:15'
# typed at 00:30 means tonight - a window in the future that no log can cover. The
# run then completes cleanly with an empty collection, because an empty window is not
# an error anywhere. The engineer's input is not rewritten here, but it is made
# impossible to miss.
#
# Live traces are exempt: they never read the impact time, so warning about it would
# be a blocker against a value that has no effect on the run.
if ($windowMode -ne 'Live' -and $ImpactTime -gt (Get-Date)) {
    Write-TlcBlocker -Check 'Scope.ImpactTime' -Status 'Warning' -Severity 'Warning' `
                     -Detail "The impact time $($ImpactTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)) is in the future, so the window covers logs that do not exist yet." `
                     -Remediation 'Pass -ImpactTime with a full date, or the previous day if you meant last night.' | Out-Null
    Write-TlcEvent -Phase 'Scope' -Step 'ImpactTime' -Status 'Warning' -Severity 'Warning' `
                   -Message 'Impact time is in the future; the collection will be empty.'
}

# An affected user is optional, and on a single-account machine its absence costs nothing.
# On a machine with more than one account signed in it costs the bundle its subject: new
# Teams writes diagnostics for every signed-in account regardless of tenant, the privacy gate
# reports that faithfully, and with no affected user named there is nothing anywhere in the
# evidence that says which of them the case is actually about.
#
# Measured 2026-09-11 on a two-account machine: a blank user completed cleanly, Scope.json
# recorded "", Summary.csv omitted it, and no blocker mentioned it. Silently accepted and
# silently unrecoverable later, because the person who knew is gone by the time anyone reads
# the bundle.
#
# Stated rather than enforced, and Information rather than Warning. The toolbox already
# applies exactly this reasoning to the CVI correlation header, whose own comment says
# missing fields are listed explicitly "because a blank line in a handover document reads as
# 'not applicable' when it actually means 'nobody has looked yet'". That principle simply
# had not reached the main bundle.
if ([string]::IsNullOrWhiteSpace($AffectedUser)) {
    Write-TlcBlocker -Check 'Scope.AffectedUser' -Status 'Success' -Severity 'Information' `
                     -Detail 'No affected user was named. Client diagnostics cover every account signed in to Teams on this machine, so if more than one is signed in the bundle will not record which of them this case concerns.' `
                     -Remediation 'Pass -AffectedUser, or type the user in the wizard, if the machine has more than one account signed in.' | Out-Null
    Write-TlcEvent -Phase 'Scope' -Step 'AffectedUser' -Status 'Complete' -Severity 'Information' `
                   -Message 'No affected user named; the bundle will not identify whose case this is.'
} else {
    # The affected user is the operator's own account.
    #
    # Asked whether the notice above still earns its place now that the wizard seeds the field
    # with the current user. It does - the command line still reaches it, which is every
    # scripted and unattended run. But measuring the two paths showed the seeding had opened a
    # WORSE gap than the one it closed:
    #
    #   blank                     -> Information blocker, "nobody named a user"
    #   seeded with the operator  -> nothing recorded at all
    #
    # A blank says nobody looked. A name says "this case is about this person", with the full
    # confidence of a recorded fact - and since the wizard now fills it in by default, that
    # claim is made on every run whether or not anyone chose it. An engineer collecting for a
    # customer who does not clear the box ships a bundle labelled with their own identity.
    #
    # Same distinction as finding 56: "unavailable" and "a claim about the machine" must not
    # collapse into one. So the match is stated rather than judged. It is correct and
    # unremarkable when someone collects on their own machine, which is the common case; it is
    # the thread to pull when the bundle turns out to be about somebody else.
    #
    # Wrapped, because a bundle must not fail over a note about itself.
    $operatorUpn = ''
    try { $operatorUpn = Get-TlcCurrentUserUpn } catch {
        Write-Verbose "The operator's UPN could not be read, so the affected user cannot be compared to it."
    }

    if ($operatorUpn -and $AffectedUser.Trim() -ieq $operatorUpn) {
        Write-TlcBlocker -Check 'Scope.AffectedUser.IsOperator' -Status 'Success' -Severity 'Information' `
                         -Detail "The affected user is the account running this collection ($operatorUpn). That is expected when an engineer collects on their own machine, and is what the wizard fills in by default - so if this bundle is about somebody else, the field was left unchanged." `
                         -Remediation 'No action if this is a self-collection. Otherwise re-run with -AffectedUser naming the person the case is about.' | Out-Null
        Write-TlcEvent -Phase 'Scope' -Step 'AffectedUser' -Status 'Complete' -Severity 'Information' `
                       -Message 'The affected user is the operator running the collection.'
    }
}

$plan = [ordered]@{
    CorrelationId  = $run.CorrelationId
    Scenario       = $scenarioEntry.Id
    # What was TYPED, which differs from the stage that ran when an alias was used. Plan.json
    # ships in the bundle, so a reader should be able to see that PreCheck was asked for and
    # Collect -ValidationOnly is what happened.
    RequestedStage = $requestedStage
    RunStage       = $Stage
    StageOrder     = $effective.StageOrder
    Lanes          = $scope.Lanes
    EffectiveConfig= $effective
}
$planPath = Export-TlcEvidence -Name 'Plan.json' -InputObject $plan
Write-TlcEvent -Phase 'Scope' -Step 'WritePlan' -Status 'Complete' -EvidencePath $planPath

# The Manual lane is emitted for every run, so evidence the toolbox cannot gather
# is visible as an outstanding item rather than silently absent from the bundle.
#
# A scenario with no Auto lane (Mobile) also puts its Prompted items here: they are done
# on another device, the toolbox cannot prompt for them, and the checklist is the only
# place they get written down. Decided HERE, in the phase every stage runs, because Package
# re-runs it and rewrites the file - a checklist extended only by Collect was overwritten
# with the shorter one inside the bundle itself. Finding 298.
$checklistItems = @($scope.Lanes.Manual)
if (@($scenarioEntry.Auto).Count -eq 0) {
    $checklistItems = @(@($scenarioEntry.Prompted) + $checklistItems | Where-Object { $_ })
}
if ($scope.Lanes.Manual.Count -gt 0) {
    foreach ($item in $scope.Lanes.Manual) {
        Write-TlcBlocker -Check $item -Status 'Warning' -Severity 'Warning' `
                         -Detail 'Portal-only evidence. The toolbox cannot collect this.' `
                         -Remediation 'Collect manually and add to the bundle before handing over.' | Out-Null
    }
}
if ($checklistItems.Count -gt 0) {
    $checklistPath = New-TlcManualChecklist -Items $checklistItems -Scope $scope -RunPath $run.RunPath -CaseNumber $CaseNumber
    Write-TlcEvent -Phase 'Scope' -Step 'ManualChecklist' -Status 'Warning' -Severity 'Warning' `
                   -Message "$($checklistItems.Count) manual item(s) required for this scenario" `
                   -EvidencePath $checklistPath
}

function Write-TlcStaleTraceReport {
    # A trace the probe could not see into is not a trace that is running. Both used to be
    # reported as "is still running", so an unelevated -DeepCapture run on a machine with
    # nothing running read as a leaked capture. Measured 2026-09-28. Finding 315.
    param([object[]] $Stale, [string] $Endpoint)
    # Three groups, not two. A marker is the record of a capture, not a capture: an orphaned
    # one was reported as "still running: ... no longer running", and one whose tool could not
    # answer belongs with the unknowns (review 2026-09-30, finding 331).
    $unchecked = @('Unknown', 'UnconfirmedMarker')
    $running = @($Stale | Where-Object { $_.Kind -notin $unchecked -and $_.Kind -ne 'OrphanedMarker' })
    $orphaned = @($Stale | Where-Object { $_.Kind -eq 'OrphanedMarker' })
    $unknown = @($Stale | Where-Object { $_.Kind -in $unchecked })
    Write-Information '' -InformationAction Continue
    if ($running.Count -gt 0) {
        Write-Information "  A capture left running by an earlier session ($($running.Count)):" -InformationAction Continue
    }
    foreach ($trace in $Stale) {
        $verb = if ($trace.Kind -in $unchecked) { 'Check with' } elseif ($trace.Kind -eq 'OrphanedMarker') { 'Remove it with' } else { 'Stop it with' }
        Write-Information "    $($trace.Detail)  ${verb}: $($trace.StopWith)" -InformationAction Continue
    }
    $parts = @()
    if ($running.Count -gt 0) { $parts += 'A packet or ETW trace from an earlier session is still running: ' + (@($running | ForEach-Object { $_.Detail }) -join '; ') }
    if ($orphaned.Count -gt 0) { $parts += 'An earlier session left the record of a capture behind: ' + (@($orphaned | ForEach-Object { $_.Detail }) -join '; ') }
    if ($unknown.Count -gt 0) { $parts += 'Whether a trace from an earlier session is still running could not be checked: ' + (@($unknown | ForEach-Object { $_.Detail }) -join '; ') }
    $fixes = @()
    if ($running.Count -gt 0) { $fixes += 'Stop it: ' + (@($running | ForEach-Object { $_.StopWith }) -join '; ') }
    if ($orphaned.Count -gt 0) { $fixes += 'Remove it: ' + (@($orphaned | ForEach-Object { $_.StopWith }) -join '; ') }
    # No prefix for the unknown case: each remediation carries its own verb ("Nothing to stop",
    # "Run as administrator and check"), and "Check: Nothing to stop" read as a contradiction.
    if ($unknown.Count -gt 0) { $fixes += (@($unknown | ForEach-Object { $_.StopWith }) -join '; ') }
    Write-TlcBlocker -Check 'Capture:StaleTrace' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
                     -Detail ($parts -join ' ') -Remediation ($fixes -join '. ') | Out-Null
}

if ($ValidationOnly) {
    # EPO semantics: produce the plan and evidence, change nothing, return before
    # any collection begins.
    #
    # Before returning, run whatever pre-flight the CHOSEN stage has. Without this the
    # validation was identical for both forks - measured 2026-09-15, byte for byte: same
    # three blockers, same seven files, whether the run was a gather or a live trace. A
    # check that cannot tell the two jobs apart is not validating the job.
    #
    # The capture pre-flight is the part worth having. "Will this trace actually capture
    # packets, and is there a stale trace already running" is precisely what an operator
    # wants answered BEFORE they spend twenty minutes reproducing a fault, and it is the
    # one thing a capture run cannot tell them afterwards. Both probes are read-only and
    # cost about a second, which is why they can run on a stage that promises to change
    # nothing.
    if ($Stage -eq 'Capture') {
        $endpoint = if ($TargetDevice) { $TargetDevice } else { $env:COMPUTERNAME }

        $deep = @(Get-TlcDeepCaptureOption)
        $unavailable = @($deep | Where-Object { -not $_.Available })
        if ($unavailable.Count -gt 0) {
            Write-Information '' -InformationAction Continue
            Write-Information "  Deeper captures would not run ($($unavailable.Count) of $($deep.Count)):" -InformationAction Continue
            foreach ($option in $unavailable) {
                Write-Information "    $($option.Title) - $($option.Reason)" -InformationAction Continue
            }
            Write-TlcBlocker -Check 'Capture:DeepCapture' -Status 'Warning' -Severity 'Information' -Endpoint $endpoint `
                             -Detail ("A trace started now would sample only. Not available: " + (@($unavailable | ForEach-Object { "$($_.Title) ($($_.Reason))" }) -join '; ')) `
                             -Remediation 'Run the toolbox as administrator if the deeper captures are wanted.' | Out-Null
        }

        # Same filter as the capture stage: an unanswerable pktmon question is noise on an
        # ordinary unelevated run, and noise on every run is how a real warning gets ignored.
        $stale = @(Get-TlcStaleCaptureTrace | Where-Object { $DeepCapture -or $_.Kind -ne 'Unknown' })
        if ($stale.Count -gt 0) { Write-TlcStaleTraceReport -Stale $stale -Endpoint $endpoint }

        Write-TlcEvent -Phase 'ValidationOnly' -Step 'CapturePreflight' -Status 'Complete' -Endpoint $endpoint `
                       -Message "$($deep.Count - $unavailable.Count) of $($deep.Count) deeper capture(s) available; $($stale.Count) stale trace(s)."
    }

    Write-TlcEvent -Phase 'ValidationOnly' -Step 'Return' -Status 'Complete' -Message 'No changes made.'
    $result = Complete-TlcRun -Status 'ValidationOnly'
    Write-Information '' -InformationAction Continue
    Write-Information 'ValidationOnly: no collection performed. No changes made.' -InformationAction Continue
    Write-Information "Evidence: $($result.RunPath)" -InformationAction Continue
    return $result
}

$desktopScenarios = @('DesktopLaunchCrash', 'DesktopSignIn', 'CallQuality', 'MeetingJoin', 'Files', 'Vdi', 'CviRoomSegment')

function Write-TlcWebLogNetworkRow {
    <#
        Teams' own offline periods, read from the web logs the Prompted lane just harvested, for
        the window the run covers. Nothing when no web logs were harvested. Finding 307: with
        Teams' programs blocked, the web logs were the only evidence that Teams itself knew it
        was offline, and the bundle carried them without saying so.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EndpointPath,
        [Parameter(Mandatory)] [string] $Endpoint,
        [Parameter(Mandatory)] [datetime] $WindowStartUtc,
        [Parameter(Mandatory)] [datetime] $WindowEndUtc
    )

    $supportPath = Join-Path $EndpointPath 'SupportFiles'
    $zips = @(foreach ($pattern in @($config.Collection.WebLogPatterns)) {
        Get-ChildItem -LiteralPath $supportPath -Filter $pattern -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.zip' }
    })
    if ($zips.Count -eq 0) { return $null }

    $state = Get-TlcWebLogNetworkState -ZipPath @($zips | Sort-Object LastWriteTime -Descending)[0].FullName `
                                       -WindowStartUtc $WindowStartUtc -WindowEndUtc $WindowEndUtc
    $spans = @($state.Offline)
    if ($spans.Count -gt 0) {
        $described = @($spans | ForEach-Object {
            if ($_.ToUtc) { "$($_.FromUtc) to $($_.ToUtc) ($($_.Seconds) s, signal $($_.Signal))" } else { "from $($_.FromUtc), not back online when the logs were taken (signal $($_.Signal))" }
        })
        Write-TlcBlocker -Check 'SupportFiles.TeamsOffline' -Status 'Warning' -Severity 'Warning' -Endpoint $Endpoint `
            -Detail "Teams' own web logs record it going offline in the window: $($described -join '; '). The toolbox's network probes run outside Teams, so they can pass while Teams itself has no connection." `
            -Remediation 'Compare with Network.LocalFirewall, Network.Proxy and Network.HostsFile, which name causes on this machine. The transitions are in the web logs, Core/diagnostics-logs.txt, under NetworkStateProvider.' | Out-Null
    } elseif ($state.Read) {
        Write-TlcBlocker -Check 'SupportFiles.TeamsOffline' -Status 'Success' -Severity 'Information' -Endpoint $Endpoint `
            -Detail "Teams' own web logs record no offline period in the window." | Out-Null
    }
    return $state
}

function Invoke-TlcDesktopEvidence {
    <#
        The desktop auto lane over one window: inventory, client logs, state, event logs, and
        the scenario's extra lanes (VDI, media path, CVI header).

        Shared by both forks. Gather hands it the retrospective window; Capture hands it the
        session it just recorded. Until 0.1.10 only Gather called it, so a live trace of a call
        shipped samples and no Teams logs at all - the design said the Collect phase "gathers
        logs written during the session", and nothing did. Finding 297.

        Reads the run's script-scope state ($config, $run, $scenarioEntry and the CVI
        parameters) because both callers are the entry point's own stage switch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Endpoint,
        [Parameter(Mandatory)] [string] $EndpointPath,
        [Parameter(Mandatory)] [datetime] $WindowStart,
        [Parameter(Mandatory)] [datetime] $WindowEnd,
        [Parameter(Mandatory)] [ValidateSet('Collect', 'Capture')] [string] $Phase
    )

    # ClientStateRoot is the parent of the whole Teams cache tree, which is what the
    # footprint measures - the log folder is only one part of it.
    if ($Phase -eq 'Capture') {
        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailInventory'
    }
    $inventory = Get-TlcClientInventory -Endpoint $Endpoint -CacheRoot $config.Collection.ClientStateRoot -LogRoot $config.Collection.ClientLogRoot `
                                        -WindowStart $WindowStart -WindowEnd $WindowEnd -IncludeRawIdentifiers:$IncludeRawIdentifiers
    $inventoryPath = Export-TlcEvidence -Name 'Inventory.json' -InputObject $inventory -Endpoint $Endpoint
    Write-TlcEvent -Phase $Phase -Step 'ClientInventory' -Status 'Complete' -Endpoint $Endpoint `
                   -Message "Teams $($inventory.TeamsVersion)" -EvidencePath $inventoryPath

    if ($Phase -eq 'Capture') {
        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailClientLogs'
    }
    $logManifest = Invoke-TlcClientLogCollection -Collection $config.Collection `
                                                 -WindowStart $WindowStart -WindowEnd $WindowEnd `
                                                 -EndpointPath $EndpointPath -Endpoint $Endpoint

    if ($Phase -eq 'Capture') {
        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailClientState'
    }
    $stateFiles = Copy-TlcClientState -Collection $config.Collection -EndpointPath $EndpointPath -Endpoint $Endpoint

    if ($Phase -eq 'Capture') {
        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailEvents'
    }
    $events = Get-TlcEventLogEvidence -Collection $config.Collection `
                                      -WindowStart $WindowStart -WindowEnd $WindowEnd -Endpoint $Endpoint `
                                      -ReportSignInFaults:($scenarioEntry.Id -eq 'DesktopSignIn')
    $eventPath = Export-TlcEvidence -Name 'EventLogs.json' -InputObject @($events) -Endpoint $Endpoint

    # VDI runs everything the desktop scenario does, plus the environment facts
    # that decide whether media was optimised or fell back.
    $vdi = $null
    if ($scenarioEntry.Id -eq 'Vdi') {
        if ($Phase -eq 'Capture') {
            Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailVdi'
        }
        $vdi = Invoke-TlcVdiCollection -EndpointPath $EndpointPath -Endpoint $Endpoint
    }

    # The network scenario owns the full network collection, but call quality and
    # meeting join fail for network reasons often enough that the media path is
    # worth proving there too.
    $network = $null
    if ($scenarioEntry.Id -in @('CallQuality', 'MeetingJoin', 'CviRoomSegment')) {
        if ($Phase -eq 'Capture') {
            Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailNetwork'
        }
        Write-Information '  Auto lane (media path)' -InformationAction Continue
        $network = Invoke-TlcNetworkCollection -EndpointPath $EndpointPath -Endpoint $Endpoint -Scenario $scenarioEntry.Id -StateRoot $config.Collection.ClientStateRoot
    }

    # A hosts-file override of a Microsoft name breaks sign-in and launch as surely as it
    # breaks a call, and those scenarios run no network lane. Measured: with the Entra sign-in
    # names pointed at 0.0.0.0, a DesktopSignIn bundle had the resulting errors and nothing
    # naming the cause. Only the hosts file here - it is a file read, and the firewall read
    # costs seconds. Finding 307.
    $hostsCheck = $null
    if (-not $network) {
        $hostsCheck = Get-TlcLocalBlockFact -SkipFirewall
        Write-TlcNetworkCauseRow -LocalBlocks $hostsCheck -HostsOnly -Endpoint $Endpoint
    }

    # The CVI lane runs after the network collection because the whole point of the
    # room-segment test is what the network evidence says, and the correlation header
    # is what lets the partner find the same call in logs this toolbox cannot read.
    $cvi = $null
    if ($scenarioEntry.Id -eq 'CviRoomSegment') {
        Write-Information '  Auto lane (interop correlation)' -InformationAction Continue
        $headerArgs = @{
            CorrelationId = $run.CorrelationId
            Endpoint      = $Endpoint
            WindowStart   = $WindowStart
            WindowEnd     = $WindowEnd
            TeamsVersion  = [string]$inventory.TeamsVersion
        }
        foreach ($pair in @(
            @{ Key = 'CaseNumber';            Value = $CaseNumber }
            @{ Key = 'OrganizerUpn';          Value = $AffectedUser }
            @{ Key = 'MeetingId';             Value = $MeetingId }
            @{ Key = 'VideoTeleconferenceId'; Value = $VideoTeleconferenceId }
            @{ Key = 'RoomResourceAccount';   Value = $RoomResourceAccount }
            @{ Key = 'CodecAddress';          Value = $CodecAddress }
            @{ Key = 'CviPartner';            Value = $CviPartner }
        )) {
            if ($pair.Value) { $headerArgs[$pair.Key] = $pair.Value }
        }

        $header = New-TlcCorrelationHeader @headerArgs
        $cvi = Invoke-TlcCviCollection -EndpointPath $EndpointPath -Endpoint $Endpoint -Header $header
    }

    return [ordered]@{
        Inventory   = $inventory
        ClientLogs  = $logManifest
        ClientState = @($stateFiles)
        Events      = @($events)
        EventPath   = $eventPath
        Vdi         = $vdi
        Network     = $network
        HostsCheck  = $hostsCheck
        Cvi         = $cvi
    }
}

function Resolve-TlcRunEndpoint {
    <#
        Works out which endpoint folder a later stage should read.

        Collect names the folder after the machine the evidence came from, which for a
        remote Rooms collection is the device, not this computer. Validate and Package
        both assumed $env:COMPUTERNAME, so a Rooms collection against a real device
        could be collected and then never packaged: Package looked in
        Endpoints\<thisPC>\, found nothing, and stopped with "Nothing to package" on a
        run that had succeeded. Validate reported every artifact missing for the same
        reason.

        Resolution order matters. An explicit -TargetDevice wins. Otherwise the folder
        actually on disk is used - a run has one endpoint, and reading the name off the
        evidence means the operator does not have to repeat -TargetDevice on the
        Package call days later, which is exactly when they would not think to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RunPath,
        [string] $TargetDevice
    )

    $endpointsRoot = Join-Path $RunPath 'Endpoints'
    $present = @(Get-ChildItem -LiteralPath $endpointsRoot -Directory -ErrorAction SilentlyContinue)

    if ($TargetDevice) { return $TargetDevice }

    # Count is checked before any member is touched. Under Set-StrictMode -Version
    # Latest - which this script sets - reading a property off an EMPTY array throws
    # "The property 'Name' cannot be found on this object", and an empty Endpoints
    # folder is the ordinary case for -Stage Package run before -Stage Collect. The
    # first version of this crashed there instead of falling through to the
    # "Nothing to package" blocker that exists to handle exactly that.
    if ($present.Count -eq 0) { return $env:COMPUTERNAME }
    if ($present.Count -eq 1) { return $present[0].Name }

    $names = @($present | ForEach-Object { $_.Name })
    if ($names -contains $env:COMPUTERNAME) { return $env:COMPUTERNAME }

    return $present[0].Name
}

switch ($Stage) {
    'Scope' {
        $result = Complete-TlcRun -Status 'Complete'
    }

    'Collect' {
        if ($scenarioEntry.Id -eq 'Rooms') {
            $endpoint = if ($TargetDevice) { $TargetDevice } else { $env:COMPUTERNAME }
            $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint
            $null = New-Item -ItemType Directory -Path $endpointPath -Force

            Write-Information '' -InformationAction Continue
            Write-Information "  Auto lane (Teams Rooms: $endpoint)" -InformationAction Continue

            $roomsArgs = @{
                Rooms        = $config.Rooms
                EndpointPath = $endpointPath
            }
            if ($TargetDevice) { $roomsArgs['TargetDevice'] = $TargetDevice }
            if ($Credential) { $roomsArgs['Credential'] = $Credential }

            $rooms = Invoke-TlcRoomsLogCollection @roomsArgs

            $collect = [ordered]@{
                Endpoint       = $endpoint
                CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Scenario       = $scenarioEntry.Id
                Rooms          = $rooms
            }
            $collectPath = Export-TlcEvidence -Name 'Collect.json' -InputObject $collect -Endpoint $endpoint

            [pscustomobject][ordered]@{
                CorrelationId = $run.CorrelationId
                Endpoint      = $endpoint
                Scenario      = $scenarioEntry.Id
                BundleName    = if ($rooms) { $rooms.BundleName } else { $null }
                BundleKB      = if ($rooms -and $rooms.Collected) { [math]::Round($rooms.BundleSizeBytes / 1KB, 1) } else { 0 }
                Collected     = [bool]($rooms -and $rooms.Collected)
                ManualItems   = $scope.Lanes.Manual.Count
            } | Export-Csv -LiteralPath (Join-Path $run.RunPath 'Summary.csv') -NoTypeInformation -Encoding utf8

            Write-TlcEvent -Phase 'Collect' -Step 'Complete' -Status 'Complete' -Endpoint $endpoint -EvidencePath $collectPath
            $result = Complete-TlcRun -Status 'Complete'
            break
        }

        if ($scenarioEntry.Id -eq 'WebClient') {
            $endpoint = $env:COMPUTERNAME
            $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint
            $null = New-Item -ItemType Directory -Path $endpointPath -Force

            Write-Information '' -InformationAction Continue
            Write-Information '  Auto lane (browser)' -InformationAction Continue
            $web = Invoke-TlcWebCollection -EndpointPath $endpointPath -SkipPrompted:$SkipPrompted -Endpoint $endpoint

            $collect = [ordered]@{
                Endpoint       = $endpoint
                CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Scenario       = $scenarioEntry.Id
                Web            = $web
            }
            $collectPath = Export-TlcEvidence -Name 'Collect.json' -InputObject $collect -Endpoint $endpoint

            [pscustomobject][ordered]@{
                CorrelationId = $run.CorrelationId
                Endpoint      = $endpoint
                Scenario      = $scenarioEntry.Id
                Browsers      = @($web.BrowserInventory.Browsers | Where-Object { $_.Installed }).Count
                ManualItems   = $scope.Lanes.Manual.Count
            } | Export-Csv -LiteralPath (Join-Path $run.RunPath 'Summary.csv') -NoTypeInformation -Encoding utf8

            Write-TlcEvent -Phase 'Collect' -Step 'Complete' -Status 'Complete' -Endpoint $endpoint -EvidencePath $collectPath
            $result = Complete-TlcRun -Status 'Complete'
            break
        }

        if ($scenarioEntry.Id -in @('Network', 'RoomsAndroid')) {
            $endpoint = $env:COMPUTERNAME
            $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint
            $null = New-Item -ItemType Directory -Path $endpointPath -Force

            Write-Information '' -InformationAction Continue
            if ($scenarioEntry.Id -eq 'RoomsAndroid') {
                # Said out loud because getting this wrong invalidates the whole bundle.
                # Network evidence gathered at a desk says nothing about the room.
                Write-Information '  Auto lane (network - run this from the ROOM segment, not your desk)' -InformationAction Continue
            } else {
                Write-Information '  Auto lane (network)' -InformationAction Continue
            }
            $network = Invoke-TlcNetworkCollection -EndpointPath $endpointPath -Endpoint $endpoint -Scenario $scenarioEntry.Id -StateRoot $config.Collection.ClientStateRoot

            if ($scenarioEntry.Id -eq 'RoomsAndroid') {
                Write-TlcBlocker -Check 'RoomsAndroid.Device' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                    -Detail ('Teams Rooms on Android exposes no local collection path - no Rigel tree, no PowerShell, no WinRM. ' +
                             'This bundle covers the network segment only; the device logs are not in it.') `
                    -Remediation ('Collect the device logs from the Teams Rooms Pro Management portal (Rooms > device > Actions > Log Collection), ' +
                                  'and the platform logs from the OEM portal. Both are on the manual checklist with the click paths.') | Out-Null
            }

            $collect = [ordered]@{
                Endpoint       = $endpoint
                CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Scenario       = $scenarioEntry.Id
                Network        = $network
            }
            $collectPath = Export-TlcEvidence -Name 'Collect.json' -InputObject $collect -Endpoint $endpoint

            [pscustomobject][ordered]@{
                CorrelationId   = $run.CorrelationId
                Endpoint        = $endpoint
                Scenario        = $scenarioEntry.Id
                TcpReachable    = @($network.TcpEndpoints | Where-Object { $_.Connected }).Count
                MediaPortsAnswered = $network.MediaPath.ReachableCount
                ProxyEnabled    = $network.Proxy.WinInet.ProxyEnabled
                ManualItems     = $scope.Lanes.Manual.Count
            } | Export-Csv -LiteralPath (Join-Path $run.RunPath 'Summary.csv') -NoTypeInformation -Encoding utf8

            Write-TlcEvent -Phase 'Collect' -Step 'Complete' -Status 'Complete' -Endpoint $endpoint -EvidencePath $collectPath
            $result = Complete-TlcRun -Status 'Complete'
            break
        }

        if ($scenarioEntry.Id -notin $desktopScenarios) {
            # Two different situations, which used to share one message.
            #
            # A scenario whose catalog entry has no Auto lane (Mobile, TenantService) has
            # nothing on THIS machine to read by design - the evidence is on a phone or in a
            # portal. "No collector implemented yet" told the operator the tool was unfinished
            # and made them look for a newer version that would never differ. Finding 298.
            #
            # A scenario that does declare Auto lanes but reaches here really is a gap, and
            # keeps the warning.
            $autoLanes = @($scenarioEntry.Auto)
            if ($autoLanes.Count -eq 0) {
                # The checklist itself, Prompted items included, is written by the scope phase
                # that every stage runs; this only names what is on it.
                $outstanding = @(@($scenarioEntry.Prompted) + @($scope.Lanes.Manual) | Where-Object { $_ })
                $manualCatalog = Get-TlcManualCatalog
                $titles = @(foreach ($id in $outstanding) {
                    if ($manualCatalog.Contains($id)) { $manualCatalog[$id].Title } else { $id }
                })
                Write-TlcEvent -Phase 'Collect' -Step 'NoLocalEvidence' -Status 'Complete' `
                               -Message "Scenario $($scenarioEntry.Id) has no evidence on this machine; $($outstanding.Count) item(s) are collected by hand."
                Write-TlcBlocker -Check "Collect:$($scenarioEntry.Id)" -Status 'Warning' -Severity 'Information' `
                                 -Detail ("Nothing to collect on this computer for this scenario - its evidence lives elsewhere: " + ($titles -join '; ') + '.') `
                                 -Remediation 'Work through ManualChecklist.md in the run folder and add each item to the bundle before packaging.' | Out-Null
                $result = Complete-TlcRun -Status 'Complete'
                break
            }

            Write-TlcEvent -Phase 'Collect' -Step 'NotImplemented' -Status 'Skipped' -Severity 'Warning' `
                           -Message "Collectors for scenario $($scenarioEntry.Id) arrive in a later phase."
            Write-TlcBlocker -Check "Collect:$($scenarioEntry.Id)" -Status 'Warning' -Severity 'Warning' `
                             -Detail 'No collector implemented for this scenario yet.' `
                             -Remediation 'Use a desktop scenario, or complete the manual checklist.' | Out-Null
            $result = Complete-TlcRun -Status 'Complete'
            break
        }

        $endpoint = $env:COMPUTERNAME
        $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint
        $null = New-Item -ItemType Directory -Path $endpointPath -Force

        # RoundtripKind so the offset in the stored string is honoured. Without it a
        # timestamp can be re-interpreted as local and shifted by the offset.
        #
        # A live scope has no window, and every collector below filters against one, so
        # there is nothing sensible to fall back to. Named here rather than allowed to
        # surface as "You cannot call a method on a null-valued expression" three frames
        # down in a collector.
        if ($null -eq $scope.WindowStart -or $null -eq $scope.WindowEnd) {
            throw 'This run folder holds a live trace, which has no retrospective window to collect against. Start a new run to package existing logs.'
        }
        $roundtrip = [System.Globalization.DateTimeStyles]::RoundtripKind
        $windowStart = [datetime]::Parse($scope.WindowStart.LocalTime, [cultureinfo]::InvariantCulture, $roundtrip)
        $windowEnd = [datetime]::Parse($scope.WindowEnd.LocalTime, [cultureinfo]::InvariantCulture, $roundtrip)

        Write-Information '' -InformationAction Continue
        Write-Information '  Auto lane' -InformationAction Continue

        $evidence = Invoke-TlcDesktopEvidence -Endpoint $endpoint -EndpointPath $endpointPath `
                                              -WindowStart $windowStart -WindowEnd $windowEnd -Phase 'Collect'
        $inventory = $evidence.Inventory
        $logManifest = $evidence.ClientLogs
        $stateFiles = $evidence.ClientState
        $events = $evidence.Events
        $eventPath = $evidence.EventPath
        $vdi = $evidence.Vdi
        $network = $evidence.Network
        $cvi = $evidence.Cvi

        Write-Information '  Prompted lane' -InformationAction Continue
        # Before the support-file prompt, which blocks: the operator sees every request at once.
        $browserCapture = $null
        if (@($scenarioEntry.Prompted) -contains 'HarCapture') {
            $browserCapture = Request-TlcBrowserCapture -EndpointPath $endpointPath -SkipPrompted:$SkipPrompted -Endpoint $endpoint
        }
        $support = Invoke-TlcSupportFilePrompt -Collection $config.Collection `
                                               -EndpointPath $endpointPath `
                                               -TimeoutMinutes $PromptTimeoutMinutes `
                                               -SkipPrompted:$SkipPrompted -Endpoint $endpoint
        $teamsNetwork = Write-TlcWebLogNetworkRow -EndpointPath $endpointPath -Endpoint $endpoint `
                                                  -WindowStartUtc $windowStart.ToUniversalTime() -WindowEndUtc $windowEnd.ToUniversalTime()

        $collect = [ordered]@{
            Endpoint      = $endpoint
            CollectedAtUtc= (Get-Date).ToUniversalTime().ToString('o')
            Scenario      = $scenarioEntry.Id
            Inventory     = $inventory
            ClientLogs    = $logManifest
            ClientState   = @($stateFiles)
            EventLogCount = @($events).Count
            EventLogPath  = $eventPath
            SupportFiles  = $support
            TeamsNetworkState = $teamsNetwork
            BrowserCaptureFolder = $browserCapture
            Vdi           = $vdi
            Network       = $network
            HostsCheck    = $evidence.HostsCheck
            Cvi           = $cvi
        }
        $collectPath = Export-TlcEvidence -Name 'Collect.json' -InputObject $collect -Endpoint $endpoint

        [pscustomobject][ordered]@{
            CorrelationId = $run.CorrelationId
            Endpoint      = $endpoint
            Scenario      = $scenarioEntry.Id
            TeamsVersion  = $inventory.TeamsVersion
            LogFilesCopied= if ($logManifest) { $logManifest.CopiedCount } else { 0 }
            ExcerptLines  = if ($logManifest) { $logManifest.Excerpt.LineCount } else { 0 }
            StateFiles    = @($stateFiles).Count
            EventsInWindow= @($events).Count
            SupportFiles  = if ($support) { @($support).Count } else { 0 }
            ManualItems   = $scope.Lanes.Manual.Count
        } | Export-Csv -LiteralPath (Join-Path $run.RunPath 'Summary.csv') -NoTypeInformation -Encoding utf8

        Write-TlcEvent -Phase 'Collect' -Step 'Complete' -Status 'Complete' -Endpoint $endpoint `
                       -EvidencePath $collectPath

        # Fleet mode. The local collection above has already happened and is the anchor of the
        # run; these are the other machines in the same investigation, carrying the same
        # correlation id.
        #
        # After the local one on purpose. If remoting is refused across the estate, the
        # operator still has this machine's evidence rather than a run that failed on endpoint
        # one and produced nothing - and the local collection is the part that always works.
        #
        # Serial, and one endpoint's failure does not stop the others. That is
        # Invoke-TlcFleetCollection's contract, measured at about 15 seconds an endpoint, and
        # the per-endpoint blockers land in the same Blockers.csv the rest of the run uses.
        $fleetNames = @(Get-TlcFleetEndpoint -Endpoint $FleetEndpoint |
            Where-Object { $_ -ne $env:COMPUTERNAME })
        if ($fleetNames.Count -gt 0) {
            Write-Information '' -InformationAction Continue
            Write-Information "  Fleet lane ($($fleetNames.Count) endpoint(s))" -InformationAction Continue

            $endpointsRoot = Join-Path $run.RunPath 'Endpoints'
            # Same window as the local collection, in UTC (finding 309). Read by the collector
            # below the same way the session factory reads $Credential.
            $fleetWindowStartUtc = $windowStart.ToUniversalTime()
            $fleetWindowEndUtc = $windowEnd.ToUniversalTime()
            $fleet = Invoke-TlcFleetCollection -Endpoint $fleetNames -RunPath $endpointsRoot `
                -CorrelationId $run.CorrelationId `
                -SessionFactory {
                    param([string] $Name)
                    # No credential guessing. If the estate needs explicit credentials this
                    # refuses, and the refusal is reported against the endpoint it belongs to -
                    # which is a better answer than a prompt nobody is present to fill in.
                    $arguments = @{ ComputerName = $Name; ErrorAction = 'Stop' }
                    if ($Credential) { $arguments['Credential'] = $Credential }
                    New-PSSession @arguments
                } `
                -Collector {
                    param($Session, [string] $Path, [string] $Name)
                    # The collector runs IN the remote session rather than copying the toolbox
                    # to it - option B in the plan. Nothing lands on the endpoint except what
                    # is read back.
                    Invoke-TlcRemoteClientLogCollection -Session $Session -EndpointPath $Path -Endpoint $Name `
                        -WindowStartUtc $fleetWindowStartUtc -WindowEndUtc $fleetWindowEndUtc
                }

            # A collected endpoint said nothing in Blockers.csv, so a reader could not tell a
            # fleet machine that sent everything from one that sent nothing, and the files it
            # could not copy were recorded only inside its Inventory.json. Finding 309.
            foreach ($name in @($fleet.Succeeded)) {
                $fleetInventory = Join-Path (Join-Path $endpointsRoot $name) 'Inventory.json'
                $facts = if (Test-Path -LiteralPath $fleetInventory) { Get-Content -LiteralPath $fleetInventory -Raw | ConvertFrom-Json } else { $null }
                if (-not $facts) { continue }
                $failedNames = @($facts.FilesFailed | Where-Object { $_ })
                $window = if ($facts.WindowStartUtc) { "in the window $($facts.WindowStartUtc) to $($facts.WindowEndUtc)" } else { 'with no window applied' }
                if ([int]$facts.FilesOffered -eq 0) {
                    # Whose profile was read decides what to try next (review 2026-09-30, finding 331).
                    $readFrom = if ($facts.PSObject.Properties['LogSource'] -and [string]$facts.LogSource -eq 'ConsoleUser') {
                        "in the signed-in user's profile"
                    } else {
                        "in the remoting account's own profile, because nobody was signed in at the console or their profile could not be told"
                    }
                    Write-TlcBlocker -Check 'Fleet.ClientLogs' -Status 'Warning' -Severity 'Warning' -Endpoint $name `
                        -Detail "No Teams client logs $window on this endpoint, $readFrom." `
                        -Remediation 'Widen the window, or collect while the person who runs Teams there is signed in.' | Out-Null
                } elseif ($failedNames.Count -gt 0) {
                    Write-TlcBlocker -Check 'Fleet.ClientLogs' -Status 'Warning' -Severity 'Warning' -Endpoint $name `
                        -Detail "$($facts.FilesCopied) of $($facts.FilesOffered) log file(s) $window copied; $($failedNames.Count) could not be read: $($failedNames -join ', ')." `
                        -Remediation 'The running client holds its current log open. Re-run later, or collect on that machine directly, to include it.' | Out-Null
                } else {
                    Write-TlcBlocker -Check 'Fleet.ClientLogs' -Status 'Success' -Endpoint $name `
                        -Detail "$($facts.FilesCopied) log file(s) $window copied." | Out-Null
                }
            }

            foreach ($blocker in @($fleet.Blocked)) {
                Write-TlcBlocker -Check 'Fleet' -Status 'Blocked' -Severity 'Warning' `
                                 -Endpoint $blocker.Endpoint `
                                 -Detail "Collection failed at the $($blocker.Stage) stage: $($blocker.Reason)" `
                                 -Remediation 'Check that the endpoint is reachable and that WinRM accepts this account.' | Out-Null
            }

            Write-Information "  Fleet lane: $($fleet.Status) - $(@($fleet.Succeeded).Count) collected, $(@($fleet.Blocked).Count) blocked" -InformationAction Continue
        }

        $result = Complete-TlcRun -Status 'Complete'
    }

    'Capture' {
        # The live fork. Fork 1 (Collect) selects from logs that already exist; this one
        # creates evidence that would not otherwise be written, by sampling the machine while
        # the operator reproduces the fault.
        #
        # It exists because the retrospective lane cannot answer "what was happening DURING
        # the call". The headline media-quality number in a Collect run is ten probes of 50 ms
        # taken once - half a second of measurement describing a twenty-minute call, and taken
        # after the call ended. See docs\two-forks-design.md.
        $endpoint = if ($TargetDevice) { $TargetDevice } else { $env:COMPUTERNAME }
        $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint
        $null = New-Item -ItemType Directory -Path $endpointPath -Force

        $stopSignal = if ($CaptureStopSignalPath) { $CaptureStopSignalPath } else { Join-Path $run.RunPath 'stop.signal' }
        # A sentinel left behind by an earlier session would stop this one on its first check,
        # producing a zero-sample run that looks like the operator stopped it immediately.
        if (Test-Path -LiteralPath $stopSignal) { Remove-Item -LiteralPath $stopSignal -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath "$stopSignal.trigger") {
            Remove-Item -LiteralPath "$stopSignal.trigger" -Force -ErrorAction Stop
        }

        Write-Information '' -InformationAction Continue
        Write-Information "  Live capture ($endpoint)" -InformationAction Continue
        Write-Information "  Sampling every $CaptureIntervalSeconds s, up to $CaptureMaxMinutes min. Reproduce the problem now." -InformationAction Continue

        # The manual stop instruction is for an operator who has no other way to stop this.
        #
        # A caller that passed its own sentinel path is managing the stop itself - the wizard
        # writes that file from its Stop button - so telling its user to run a New-Item command
        # is at best noise and at worst reads as "the button will not work". Printed only when
        # nothing else is driving the session.
        if (-not $PSBoundParameters.ContainsKey('CaptureStopSignalPath')) {
            Write-Information "  Stop with: New-Item -ItemType File -Path '$stopSignal'" -InformationAction Continue
        } else {
            Write-Information '  Press Stop run when you have finished reproducing it.' -InformationAction Continue
        }

        Write-TlcEvent -Phase 'Capture' -Step 'Start' -Status 'Started' -Endpoint $endpoint `
                       -Message "Live capture started at ${CaptureIntervalSeconds}s interval."

        # What this session could NOT see, recorded before it starts rather than discovered
        # afterwards. A bundle that answers "was there a packet capture?" with silence sends
        # the next engineer looking for a file that was never written.
        $deep = @(Get-TlcDeepCaptureOption)
        $unavailable = @($deep | Where-Object { -not $_.Available })

        # A trace left running by an earlier session, reported before this one starts. It is
        # machine-wide, it survives whatever started it, and on a customer machine it is a
        # disk-filling fault that a diagnostic tool would have caused itself.
        #
        # "Could not determine" is only worth saying when it changes what the operator should
        # do. On an ordinary unelevated run the toolbox is not starting captures, and the marker
        # check still catches anything a previous toolbox session left behind - so an
        # unanswerable pktmon question is noise, and noise on every run is how a real warning
        # gets ignored. When -DeepCapture was asked for, not knowing genuinely matters.
        $stale = @(Get-TlcStaleCaptureTrace | Where-Object { $DeepCapture -or $_.Kind -ne 'Unknown' })
        if ($stale.Count -gt 0) { Write-TlcStaleTraceReport -Stale $stale -Endpoint $endpoint }

        if ($unavailable.Count -gt 0) {
            Write-Information '' -InformationAction Continue
            Write-Information "  Deeper captures not running ($($unavailable.Count) of $($deep.Count)):" -InformationAction Continue
            foreach ($option in $unavailable) {
                Write-Information "    $($option.Title) - $($option.Reason)" -InformationAction Continue
            }
            Write-TlcBlocker -Check 'Capture:DeepCapture' -Status 'Warning' -Severity 'Information' -Endpoint $endpoint `
                             -Detail ("Sampling only. Not running: " + (@($unavailable | ForEach-Object { "$($_.Title) ($($_.Reason))" }) -join '; ')) `
                             -Remediation 'Run the toolbox as administrator, or run the commands recorded in Capture.json by hand alongside the session.' | Out-Null
        }

        $captureArgs = @{
            EndpointPath     = $endpointPath
            StopSignalPath   = $stopSignal
            IntervalSeconds  = $CaptureIntervalSeconds
            MaxMinutes       = $CaptureMaxMinutes
            IncludeMedia     = $true
            IncludeNetwork   = $true
            IncludeProcesses = $true
        }

        # Phase markers for whatever is driving this.
        #
        # A capture run has three phases and only the middle one asks anything of the operator,
        # but from outside they are indistinguishable: the same progress bar and the same log.
        # These lines let a UI say which phase is live without parsing prose that was written
        # to be read by a person.
        #
        # Printed rather than returned because the caller is a separate process reading stdout -
        # the same channel everything else here reports on.
        #
        # TLC-PHASE:Reproduce is emitted AFTER the warm-up returns, because that is the moment
        # sampling actually begins. Emitting it at the top of the stage would tell the operator
        # to reproduce the fault during the six seconds when nothing is being recorded.
        # Teams deletes its own older logs during a long session: it keeps only the most recent
        # MSTeams_*.log files for a running client, about twenty minutes on a busy one. So for a
        # desktop scenario on this machine the rotated files are copied as they rotate, about
        # every 30 seconds, rather than only by the closing pass. Finding 321.
        $keepRotated = ($scenarioEntry.Id -in $desktopScenarios) -and ($endpoint -eq $env:COMPUTERNAME)
        $rotatedSaved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $rotatedEvery = [Math]::Max(1, [int][Math]::Ceiling(30 / [Math]::Max(1, $CaptureIntervalSeconds)))
        $rotatedSince = Get-Date

        $captureArgs['OnSample'] = {
            param($sample)
            if ($sample.Sequence -eq 1) {
                Write-Information 'TLC-PHASE:Reproduce' -InformationAction Continue
            }
            # One short marker per sample. Stripped from the log by whatever is reading this,
            # so it costs nothing there, and it is the only evidence the operator has that the
            # session is accumulating anything - elapsed time alone moves identically whether
            # the sampler is working or wedged.
            Write-Information "TLC-SAMPLES:$($sample.Sequence)" -InformationAction Continue
            if ($CaptureStopSignalPath) {
                $metric = [ordered]@{
                    TimestampUtc = $sample.TakenUtc
                    Rtt = $null; Jitter = $null; Loss = $null; Memory = $null
                    TotalRamMb = $null; AvailableRamMb = $null; RamError = $null
                }
                if ($sample.PSObject.Properties['Media'] -and $sample.Media.Measured) {
                    $metric.Rtt = $sample.Media.RttAvgMs
                    $metric.Jitter = $sample.Media.JitterMs
                    $metric.Loss = $sample.Media.LossPercent
                }
                if ($sample.PSObject.Properties['TeamsWebViewWorkingSetMb']) {
                    $metric.Memory = $sample.TeamsWorkingSetMb + $sample.TeamsWebViewWorkingSetMb
                }
                if ($sample.PSObject.Properties['SystemMemory']) {
                    $metric.TotalRamMb = $sample.SystemMemory.TotalMb
                    $metric.AvailableRamMb = $sample.SystemMemory.AvailableMb
                }
                $metric.RamError = @($sample.Errors | Where-Object { $_ -like 'SystemMemory:*' }) -join '; '
                Write-Information ('TLC-METRIC:' + ($metric | ConvertTo-Json -Compress)) -InformationAction Continue
            }

            if ($keepRotated -and ($sample.Sequence % $rotatedEvery) -eq 0) {
                try { $null = Save-TlcRotatedClientLog -Collection $config.Collection -EndpointPath $endpointPath -Since $rotatedSince -Saved $rotatedSaved }
                catch { Write-Verbose "Rotated client logs could not be kept: $($_.Exception.Message)" }
            }
        }

        # Packet capture, when asked for and possible.
        #
        # Started before the sampler and stopped in a finally, so a sampler that throws cannot
        # leave a machine-wide trace running. That is the one guarantee this code has to make:
        # a pktmon capture outlives the process that started it, so anything other than a
        # guaranteed stop path leaves the operator's machine writing an ETL indefinitely.
        $deepStarted = $null
        # A HAR is recorded DURING the reproduction, so the request comes before sampling
        # starts. Asked after Stop, as the web closing pass used to, it described a recording
        # the operator could no longer make. Finding 302.
        $browserCapture = $null
        if (@($scenarioEntry.Prompted) -contains 'HarCapture') {
            $browserCapture = Request-TlcBrowserCapture -EndpointPath $endpointPath -SkipPrompted:$SkipPrompted `
                                                        -IncludeWebRtc:($scenarioEntry.Id -eq 'WebClient') -Endpoint $endpoint
        }
        if ($DeepCapture) {
            $deepStarted = Start-TlcDeepCapture -OutputPath $endpointPath
            Write-Information '' -InformationAction Continue
            Write-Information "  Packet capture: $($deepStarted.Reason)" -InformationAction Continue
            if (-not $deepStarted.Started) {
                Write-TlcBlocker -Check 'Capture:PacketCapture' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                                 -Detail "A packet capture was requested but did not start. $($deepStarted.Reason)" `
                                 -Remediation 'Re-run the toolbox as administrator, or run the packet capture command recorded in Capture.json by hand.' | Out-Null
            }
        }

        try {
            $session = Invoke-TlcCaptureSession @captureArgs
        } finally {
            if ($deepStarted -and $deepStarted.Started) {
                Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Sampling -Status Running -DetailKey 'StopDetailDeep'
                $deepStopped = Stop-TlcDeepCapture
                Write-Information "  Packet capture: $($deepStopped.Reason)" -InformationAction Continue
            }
        }

        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Sampling -Status Complete -DetailKey 'StopDetailSamplingStopped'
        Write-Information 'TLC-PHASE:Collect' -InformationAction Continue
        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailSummary'
        $summary = Get-TlcCaptureSummary -SamplePath $session.SamplePath

        # The closing pass: the logs written DURING the session, over exactly the session.
        #
        # Collect refuses a live-trace run folder, so this is the only place a capture bundle
        # can get Teams' own logs. Without it a live trace of a failing call shipped a sample
        # series and no client log, event log or inventory at all. Finding 297.
        #
        # ToLocalTime because the collectors compare against file times, and DateTime
        # comparison ignores Kind: a UTC value read as local shifts the window by the offset.
        $closing = $null
        if ($session.SampleCount -gt 0) {
            $roundtrip = [System.Globalization.DateTimeStyles]::RoundtripKind
            $sessionStart = [datetime]::Parse($session.StartedUtc, [cultureinfo]::InvariantCulture, $roundtrip).ToLocalTime()
            $sessionEnd = [datetime]::Parse($session.EndedUtc, [cultureinfo]::InvariantCulture, $roundtrip).ToLocalTime()

            Write-Information '' -InformationAction Continue
            if ($endpoint -ne $env:COMPUTERNAME) {
                Write-TlcBlocker -Check 'Capture:ClosingPass' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                                 -Detail "The session was recorded for $endpoint, but the closing log pass reads this computer ($env:COMPUTERNAME), so it was not run." `
                                 -Remediation 'Run the capture on the affected machine itself to include its logs.' | Out-Null
            } elseif ($scenarioEntry.Id -in $desktopScenarios) {
                Write-Information '  Auto lane (logs written during the session)' -InformationAction Continue
                # One last pass first, for a file that rotated in the final seconds.
                if ($keepRotated) {
                    try { $null = Save-TlcRotatedClientLog -Collection $config.Collection -EndpointPath $endpointPath -Since $rotatedSince -Saved $rotatedSaved }
                    catch { Write-Verbose "Rotated client logs could not be kept: $($_.Exception.Message)" }
                }
                $closing = Invoke-TlcDesktopEvidence -Endpoint $endpoint -EndpointPath $endpointPath `
                                                     -WindowStart $sessionStart -WindowEnd $sessionEnd -Phase 'Capture'

                # What only the copies above hold: files Teams deleted before the session ended.
                # The excerpt and the timeline are built from what is still on disk, so they start
                # later than the session and the reader has to be told. Finding 321.
                if ($keepRotated -and $rotatedSaved.Count -gt 0) {
                    $logRoot = Resolve-TlcPath -Path $config.Collection.ClientLogRoot
                    $keptOnly = @($rotatedSaved | Where-Object { -not (Test-Path -LiteralPath (Join-Path $logRoot $_)) } | Sort-Object)
                    if ($keptOnly.Count -gt 0) {
                        Write-TlcBlocker -Check 'Capture:RotatedLogs' -Status 'Warning' -Severity 'Information' -Endpoint $endpoint `
                            -Detail ("$($keptOnly.Count) client log file(s) written during the session were deleted by Teams before it ended: it keeps only its most recent MSTeams_*.log files for a running client. They were copied as they rotated and are in ClientLogs: " +
                                     ($keptOnly -join ', ') + '. Window-Excerpt.log and Window-Timeline.log are built from the files still on disk at the end, so they start later than the session.') `
                            -Remediation 'Read these files directly for the start of the session.' | Out-Null
                        $clientManifest = Join-Path $endpointPath 'ClientLogs\ClientLogs.manifest.json'
                        if (Test-Path -LiteralPath $clientManifest) {
                            $noted = Get-Content -LiteralPath $clientManifest -Raw | ConvertFrom-Json
                            $noted | Add-Member -NotePropertyName 'KeptDuringSession' -NotePropertyValue $keptOnly -Force
                            $noted | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $clientManifest -Encoding utf8
                        }
                    }
                }
            } elseif ($scenarioEntry.Id -eq 'WebClient') {
                Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailBrowser'
                Write-Information '  Auto lane (browser)' -InformationAction Continue
                $closing = [ordered]@{ Web = Invoke-TlcWebCollection -EndpointPath $endpointPath -SkipPrompted:$SkipPrompted -NoCapturePrompt -Endpoint $endpoint }
            } elseif ($scenarioEntry.Id -in @('Network', 'RoomsAndroid')) {
                Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs -Status Running -DetailKey 'StopDetailNetwork'
                Write-Information '  Auto lane (network, closing snapshot)' -InformationAction Continue
                $closing = [ordered]@{ Network = Invoke-TlcNetworkCollection -EndpointPath $endpointPath -Endpoint $endpoint -Scenario $scenarioEntry.Id -StateRoot $config.Collection.ClientStateRoot }
            }
        }
        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Logs `
            -Status $(if ($closing) { 'Complete' } elseif ($session.SampleCount -eq 0) { 'Skipped' } else { 'Warning' }) `
            -DetailKey 'StopDetailLogsFinished'

        # The Prompted lane belongs HERE, and only here.
        #
        # Ctrl+Alt+Shift+1 makes Teams write a fresh support bundle covering roughly the last
        # while. In the retrospective fork that is close to meaningless - a run investigating
        # last Tuesday fires the trigger and harvests a bundle dated today, which is evidence
        # about the wrong day presented alongside evidence about the right one.
        #
        # In a capture session it is exactly right: the operator has just reproduced the fault,
        # the trigger fires seconds later, and the bundle covers the session that produced the
        # samples sitting next to it in the same folder. The two halves describe the same event.
        #
        # After the samples, not before: the prompt blocks on the user, and asking them to
        # click something in Teams while they are meant to be reproducing a fault would corrupt
        # the very window the fork exists to capture.
        $support = $null
        if ($session.SampleCount -gt 0) {
            # Automatic generation needs room for Teams' measured 158s call-time latency.
            # The operator's explicit timeout still wins over the five-minute default.
            $capturePromptMinutes = if ($PSBoundParameters.ContainsKey('PromptTimeoutMinutes')) {
                $PromptTimeoutMinutes
            } else {
                5
            }

            Write-Information '' -InformationAction Continue
            Write-Information '  Prompted lane' -InformationAction Continue
            Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Support -Status Running -DetailKey 'StopDetailSupport'
            $support = Invoke-TlcSupportFilePrompt -Collection $config.Collection `
                                                   -EndpointPath $endpointPath `
                                                   -TimeoutMinutes $capturePromptMinutes `
                                                   -SkipPrompted:$SkipPrompted -Endpoint $endpoint `
                                                   -StopSignalPath $stopSignal -AutoTrigger:($endpoint -eq $env:COMPUTERNAME)
        } else {
            Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Support -Status Skipped -DetailKey 'StopDetailSupportSkipped'
        }

        Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Finalize -Status Running -DetailKey 'StopDetailFinalizing'
        # Teams' own offline periods over exactly the session, from the web logs just harvested.
        $teamsNetwork = $null
        if ($support -and $endpoint -eq $env:COMPUTERNAME) {
            $teamsNetwork = Write-TlcWebLogNetworkRow -EndpointPath $endpointPath -Endpoint $endpoint `
                -WindowStartUtc ([datetime]::Parse($session.StartedUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) `
                -WindowEndUtc ([datetime]::Parse($session.EndedUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime())
        }

        $capture = [ordered]@{
            Endpoint   = $endpoint
            Scenario   = $scenarioEntry.Id
            Session    = $session
            Summary    = $summary
            SupportFiles = $support
            TeamsNetworkState = $teamsNetwork
            BrowserCaptureFolder = $browserCapture
            DeepCapture = $deep
            PacketCapture = if ($deepStarted) { $deepStarted } else { $null }
        }
        $capturePath = Export-TlcEvidence -Name 'Capture.json' -InputObject $capture -Endpoint $endpoint

        # Same file, same shape as a gather run's, so Validate and a reader treat a capture
        # bundle's logs exactly like any other bundle's. The window is the session's.
        if ($closing) {
            $collect = [ordered]@{
                Endpoint       = $endpoint
                CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                Scenario       = $scenarioEntry.Id
                Source         = 'Capture'
                WindowStartUtc = $session.StartedUtc
                WindowEndUtc   = $session.EndedUtc
            }
            foreach ($key in $closing.Keys) {
                if ($key -eq 'Events') { $collect['EventLogCount'] = @($closing.Events).Count; continue }
                if ($key -eq 'EventPath') { $collect['EventLogPath'] = $closing.EventPath; continue }
                $collect[$key] = $closing[$key]
            }
            $collect['SupportFiles'] = $support
            $null = Export-TlcEvidence -Name 'Collect.json' -InputObject $collect -Endpoint $endpoint
        }

        Write-Information '' -InformationAction Continue
        Write-Information "  $($session.SampleCount) sample(s) over $($session.DurationSeconds)s. Ended: $($session.StopReason)." -InformationAction Continue
        if ($summary.Detail) { Write-Information "  $($summary.Detail)" -InformationAction Continue }

        # The probes cost real time - measured at roughly 2.2 s a sample with media included -
        # so an interval shorter than that cannot be honoured, and the series quietly becomes
        # coarser than the operator asked for. "Sampled every second" is the basis on which
        # someone later decides whether a two-second glitch could have been seen, so a gap
        # between requested and achieved has to be stated rather than left in a JSON field.
        if ($session.ActualIntervalSeconds -and $session.ActualIntervalSeconds -gt ($CaptureIntervalSeconds * 1.25)) {
            Write-Information "  Note: sampling achieved $($session.ActualIntervalSeconds)s against the $($CaptureIntervalSeconds)s requested; the probes cost more than the interval." -InformationAction Continue
            Write-TlcBlocker -Check 'Capture:IntervalNotAchieved' -Status 'Warning' -Severity 'Warning' `
                             -Detail "Requested a ${CaptureIntervalSeconds}s sampling interval; achieved $($session.ActualIntervalSeconds)s." `
                             -Remediation 'Treat the series as sampled at the achieved interval, or re-run with fewer probes for a finer grid.' | Out-Null
        }

        # A freeze seen in the samples goes where an engineer looks first. It was recorded in
        # Capture.json only, as a count: on a simulated 30-second hang the four samples that
        # caught it were correct, and nothing in Blockers.csv said so. Finding 305.
        if ($summary -and $summary.PSObject.Properties.Name -contains 'NotRespondingSamples') {
            Write-TlcBlocker -Check 'Capture:TeamsNotResponding' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                             -Detail ("Teams was not responding in $($summary.NotRespondingSamples) sample(s), from $($summary.NotRespondingFirstUtc) to $($summary.NotRespondingLastUtc) UTC. " +
                                      'Samples taken while it is frozen run slower, because the responsiveness check waits for the window.') `
                             -Remediation 'Match these times against the client log excerpt and the event logs in this bundle; a freeze that ends on its own leaves no crash record.' | Out-Null
        }

        $exited = $summary -and ($summary.PSObject.Properties.Name -contains 'NotRunningSamples' -or $summary.PSObject.Properties.Name -contains 'TeamsRestarts')
        if ($exited) {
            $what = @(
                if ($summary.PSObject.Properties.Name -contains 'NotRunningSamples') { "Teams was not running in $($summary.NotRunningSamples) sample(s), first at $($summary.NotRunningFirstUtc) UTC" }
                if ($summary.PSObject.Properties.Name -contains 'TeamsRestarts') { "it restarted $($summary.TeamsRestarts) time(s), new process started at $(@($summary.TeamsRestartedUtc) -join ', ') UTC" }
            ) -join '; '
            Write-TlcBlocker -Check 'Capture:TeamsExited' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                             -Detail "Teams exited during the session: $what." `
                             -Remediation 'Check EventLogs.json for an Application Error or Application Hang entry at that time, ClientState\previous_session_data.json for how the last session ended, and the Launcher log for the relaunch.' | Out-Null
        }

        # A session that sampled nothing is not a successful run that happened to be quiet. It
        # means the operator has no evidence, and saying "Complete" would hide that.
        if ($session.SampleCount -eq 0) {
            Write-TlcBlocker -Check 'Capture:NoSamples' -Status 'Blocked' -Severity 'Warning' `
                             -Detail 'The capture session ended without taking any samples.' `
                             -Remediation 'Re-run -Stage Capture, with the same -Scenario and -CaseNumber, and reproduce the problem before stopping the session.' | Out-Null
        }

        Write-TlcEvent -Phase 'Capture' -Step 'Complete' -Status 'Complete' -Endpoint $endpoint -EvidencePath $capturePath `
                       -Message "$($session.SampleCount) sample(s); $($session.StopReason)."
        # A second Stop run that arrived after the support-file wait had ended leaves the
        # sentinel behind; nothing reads it after this point. Finding 321.
        if (Test-Path -LiteralPath $stopSignal) { Remove-Item -LiteralPath $stopSignal -Force -ErrorAction SilentlyContinue }
        $result = Complete-TlcRun -Status 'Complete'
        break
    }

    'Validate' {
        # Validate is deliberately separate from Collect: a bundle handed over days
        # later can be re-checked without collecting anything again.
        $endpoint = Resolve-TlcRunEndpoint -RunPath $run.RunPath -TargetDevice $TargetDevice
        $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint

        $checks = @(
            @{ Name = 'Endpoints\Collect.json'; Path = Join-Path $endpointPath 'Collect.json' }
            @{ Name = 'Endpoints\Inventory.json'; Path = Join-Path $endpointPath 'Inventory.json' }
            @{ Name = 'ClientLogs manifest'; Path = Join-Path $endpointPath 'ClientLogs\ClientLogs.manifest.json' }
        )

        foreach ($check in $checks) {
            if (Test-Path -LiteralPath $check.Path) {
                $size = (Get-Item -LiteralPath $check.Path).Length
                $status = if ($size -gt 0) { 'Success' } else { 'Warning' }
                Write-TlcBlocker -Check "Validate:$($check.Name)" -Status $status -Endpoint $endpoint `
                                 -Detail "$size byte(s)." | Out-Null
            } else {
                Write-TlcBlocker -Check "Validate:$($check.Name)" -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                                 -Detail 'Artifact not present in this run.' `
                                 -Remediation 'Run -Stage Collect first.' | Out-Null
            }
        }

        # The browser-capture prompt tells the operator to drop their exports in WebCapture and
        # re-run Validate. Validate never looked there: with a HAR and a console log in place it
        # reported the same three rows as before, so an operator following the instructions had
        # no way to see that the tool had noticed. Finding 307.
        if (@($scenarioEntry.Prompted) -contains 'HarCapture') {
            $webCapture = Join-Path $endpointPath 'WebCapture'
            $dropped = @(Get-ChildItem -LiteralPath $webCapture -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
            $hars = @($dropped | Where-Object { $_.Name -match '\.har(\.json)?$' })
            if ($dropped.Count -eq 0) {
                Write-TlcBlocker -Check 'Validate:WebCapture' -Status 'Warning' -Severity 'Warning' -Endpoint $endpoint `
                                 -Detail "Nothing has been saved into $webCapture yet." `
                                 -Remediation 'Follow the browser-capture steps printed by Collect, save the exports there, then run -Stage Validate again.' | Out-Null
            } else {
                $status = if ($hars.Count -gt 0) { 'Success' } else { 'Warning' }
                $detail = "$($dropped.Count) file(s): $(@($dropped | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length / 1KB)) KB)" }) -join ', ')."
                if ($hars.Count -eq 0) { $detail += ' No HAR among them; the network trace is the part support reads first.' }
                Write-TlcBlocker -Check 'Validate:WebCapture' -Status $status -Endpoint $endpoint -Detail $detail | Out-Null
            }
        }

        Write-TlcEvent -Phase 'Validate' -Step 'CheckArtifacts' -Status 'Complete' -Endpoint $endpoint `
                       -Message "$($checks.Count) artifact check(s) evaluated."
        $result = Complete-TlcRun -Status 'Complete'
    }

    'Package' {
        # The privacy gate runs before anything is packaged. Once a bundle has left,
        # an unnoticed foreign identity inside it cannot be recalled, so this is the
        # one place the toolbox refuses to continue rather than warning.
        $endpoint = Resolve-TlcRunEndpoint -RunPath $run.RunPath -TargetDevice $TargetDevice
        $endpointPath = Join-Path (Join-Path $run.RunPath 'Endpoints') $endpoint

        if (-not (Test-Path -LiteralPath $endpointPath)) {
            # A scenario with no local lane (Mobile, TenantService) never creates an endpoint
            # folder, so "run -Stage Collect first" was false the moment Collect had run - the
            # same class as finding 298. Say what is actually true for it.
            $noLocalLane = @($scenarioEntry.Auto).Count -eq 0
            $detail = if ($noLocalLane) {
                "Scenario $($scenarioEntry.Id) keeps no evidence on this computer, so there is no bundle to seal."
            } else {
                "Nothing collected for this run under Endpoints\$endpoint."
            }
            $remediation = if ($noLocalLane) {
                'Hand over ManualChecklist.md from the run folder together with the exports it lists.'
            } else {
                'Run -Stage Collect first, or pass -CorrelationId of a collected run.'
            }
            Write-TlcBlocker -Check 'Package' -Status 'Blocked' -Severity 'Critical' -Endpoint $endpoint `
                             -Detail $detail -Remediation $remediation | Out-Null
            $result = Complete-TlcRun -Status 'Blocked'
            Write-Information '' -InformationAction Continue
            Write-Information 'Nothing to package.' -InformationAction Continue
            break
        }

        Write-Information '' -InformationAction Continue
        Write-Information '  Privacy gate' -InformationAction Continue

        # Every endpoint in the run is gated, not just the one being packaged. The gate
        # reads one endpoint's folder while the bundle seals the whole run, so gating a
        # single endpoint would leave the rest sealed but never inspected.
        #
        # A refused endpoint is excluded from the bundle rather than failing the run.
        # Across a fleet an unrecognised account is close to certain, and refusing a
        # ten-machine collection over one laptop is the pressure that gets the gate turned
        # off - at which point it protects nothing.
        $endpointNames = @(Get-ChildItem -LiteralPath (Join-Path $run.RunPath 'Endpoints') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
        if ($endpointNames.Count -eq 0) { $endpointNames = @($endpoint) }

        # Endpoints whose fleet collection failed, from the rows Collect wrote. Finding 309.
        $blockersPath = Join-Path $run.RunPath 'Blockers.csv'
        $fleetFailed = @(if (Test-Path -LiteralPath $blockersPath) {
            Import-Csv -LiteralPath $blockersPath | Where-Object { $_.Check -eq 'Fleet' -and $_.Status -eq 'Blocked' } | ForEach-Object { [string]$_.Endpoint }
        })

        # The lines a refusal prints come from the same place as the gate's own, so the wizard
        # can recognise each one and say it in the operator's language. Finding 338.
        $refusalText = Get-TlcPackageRefusalText
        $endpointResults = foreach ($name in $endpointNames) {
            $path = Join-Path (Join-Path $run.RunPath 'Endpoints') $name

            # Credentials out of any HAR before the scan reads it (finding 312). A sanitized export
            # still carries tokens in response bodies, so without this every real HAR was refused.
            foreach ($cleaned in @(Protect-TlcHarCredential -EndpointPath $path)) {
                Write-TlcBlocker -Check 'Privacy.HarRedaction' -Status 'Warning' -Severity 'Information' -Endpoint $name `
                    -Detail "Removed sign-in credentials from $($cleaned.File) before sealing: $($cleaned.JwtCount) token(s) and $($cleaned.RefreshCount) refresh token(s), replaced in place with REDACTED-BY-TLC-TOOLBOX. The requests that carried them are kept." `
                    -Remediation 'Nothing to do. The operator''s own copy of the export, outside the run folder, is untouched and still holds the tokens: delete it.' | Out-Null
            }

            # Third-party addresses out of any HAR (Privacy.ScrubUpn, on by default). The affected
            # user and the operator stay readable; support needs to find them. Finding 313.
            if ($config.Privacy.Contains('ScrubUpn') -and $config.Privacy.ScrubUpn) {
                $keepAddresses = @($AffectedUser)
                try { $keepAddresses += Get-TlcCurrentUserUpn } catch { Write-Verbose "The operator's address could not be read, so it is not kept." }
                foreach ($scrubbed in @(Protect-TlcHarAddress -EndpointPath $path -Keep $keepAddresses)) {
                    Write-TlcBlocker -Check 'Privacy.HarAddresses' -Status 'Warning' -Severity 'Information' -Endpoint $name `
                        -Detail "Masked $($scrubbed.MaskedCount) distinct email address(es) in $($scrubbed.File) (the domain is kept, the person is not); $($scrubbed.KeptCount) kept as the affected user or the operator." `
                        -Remediation 'Nothing to do. Set Privacy.ScrubUpn = $false only if support needs third-party addresses from the trace.' | Out-Null
                }
            }

            $inventory = Get-TlcIdentityInventory -EndpointPath $path -MaxScanBytesPerFile $config.Privacy.MaxScanBytesPerFile
            # The gate reads the in-memory inventory, raw ids and all, because it has to
            # compare them against KnownAccountIds. The FILE gets the masked copy unless raw
            # was asked for: it used to be the same object, raw ids and every GUID found in
            # the evidence included. Finding 296.
            $shareable = ConvertTo-TlcShareableIdentityInventory -Inventory $inventory -IncludeRawIdentifiers:$IncludeRawIdentifiers
            $inventoryPath = Export-TlcEvidence -Name 'IdentityInventory.json' -InputObject $shareable -Endpoint $name
            Write-TlcEvent -Phase 'Package' -Step 'IdentityInventory' -Status 'Complete' -Endpoint $name `
                           -Message "$($inventory.AccountCount) account(s), $($inventory.DistinctUpnCount) address(es), $($inventory.ClientArchives.Count) archive(s)." `
                           -EvidencePath $inventoryPath

            $verdict = Test-TlcPrivacyGate -Privacy $config.Privacy -Inventory $inventory -Endpoint $name

            # A fleet endpoint whose collection FAILED can still have a folder: the copies land
            # before a later step throws. It was sealed into the bundle and listed as included
            # while Blockers.csv said Blocked - a partial folder presented as a whole one.
            # Measured on a two-machine fleet. It is now withheld, the way a refused endpoint is,
            # with the reason recorded. Finding 309.
            if ($fleetFailed -contains $name) {
                $verdict.Blocked = $true
                $verdict.Status = 'Blocked'
                $verdict.Reasons = @(@($verdict.Reasons) + (Format-TlcRefusalText -Entry $refusalText.ReasonFleetFailed -Value @($name)))
                $verdict.Fixes = @(@($verdict.Fixes) + $refusalText.FixFleet.English)
                # The gate's own row above says Success for what it scanned, so without this
                # Blockers.csv never said the endpoint was left out. Finding 314.
                Write-TlcBlocker -Check 'Fleet' -Status 'Blocked' -Severity 'Warning' -Endpoint $name `
                    -Detail 'Withheld from the bundle: the collection failed, so the folder is partial. The files that did arrive stay in the run folder.' `
                    -Remediation $refusalText.FixFleet.English | Out-Null
            }

            # Consent is per machine, so the record sits with the evidence it authorises.
            # An excluded endpoint then takes its consent record out of the bundle with it,
            # rather than leaving an assertion about evidence that is not there.
            $endpointConsent = New-TlcConsentRecord -Privacy $config.Privacy -Scope $scope `
                                                    -CustomerName $config.CustomerName -CaseNumber $CaseNumber -Endpoint $name
            $null = Export-TlcEvidence -Name 'Consent.json' -InputObject $endpointConsent -Endpoint $name

            Write-Information "    $name" -InformationAction Continue
            foreach ($reason in $verdict.Reasons) { Write-Information "      - $reason" -InformationAction Continue }
            # What to do, under what is wrong. It was only in Blockers.csv, so the transcript -
            # all the wizard shows of a refused Package - listed the causes and then said
            # "resolve the items above" with nothing above saying how. Finding 336.
            if ($verdict.Blocked -and $verdict.Contains('Fixes')) {
                foreach ($fix in @($verdict.Fixes)) { Write-Information "      To fix: $fix" -InformationAction Continue }
            }
            if ($verdict.Blocked) { Write-Information "      $($refusalText.Excluded.English)" -InformationAction Continue }

            $verdict
        }

        $endpointResults = @($endpointResults)
        $excludedNames = @($endpointResults | Where-Object { $_.Blocked } | ForEach-Object { [string]$_.Endpoint })

        # Every endpoint refused leaves nothing to package. Checked before the verdict is
        # selected below, because that selection has nothing to select from in this case.
        if ($excludedNames.Count -eq $endpointResults.Count) {
            Write-TlcEvent -Phase 'Package' -Step 'PrivacyGate' -Status 'Failed' -Severity 'Critical' -Endpoint $endpoint `
                           -Message 'Every endpoint was refused by the privacy gate.'
            $result = Complete-TlcRun -Status 'Blocked'
            Write-Information '' -InformationAction Continue
            Write-Information $refusalText.AllRefused.English -InformationAction Continue
            Write-Information $refusalText.Closing.English -InformationAction Continue
            break
        }

        # The verdict that rides in the manifest's Privacy field, keeping the
        # single-endpoint bundle shape unchanged. An included endpoint is preferred: if the
        # machine this run was named after was itself excluded, reporting its Blocked
        # verdict beside a bundle that exists would read as a contradiction. The full story
        # is in the manifest's IncludedEndpoints and ExcludedEndpoints either way.
        #
        # Count is tested before any element is read. Indexing an empty array throws under
        # Set-StrictMode -Version Latest, which is the same trap Resolve-TlcRunEndpoint
        # documents - and which this walked straight into: with every endpoint excluded the
        # run failed with "Index was outside the bounds of the array" instead of the clean
        # refusal above.
        $included = @($endpointResults | Where-Object { -not $_.Blocked })
        $preferred = @($included | Where-Object { $_.Endpoint -eq $endpoint })

        $privacyResult = if ($preferred.Count -gt 0) { $preferred[0] }
                         elseif ($included.Count -gt 0) { $included[0] }
                         else { $endpointResults[0] }

        $consent = New-TlcConsentRecord -Privacy $config.Privacy -Scope $scope `
                                        -CustomerName $config.CustomerName -CaseNumber $CaseNumber -Endpoint $endpoint

        if ($excludedNames.Count -gt 0) {
            Write-Information '' -InformationAction Continue
            Write-Information "  $($excludedNames.Count) endpoint(s) excluded from the bundle: $($excludedNames -join ', ')" -InformationAction Continue
        }

        Write-Information '  Packaging' -InformationAction Continue
        $bundle = New-TlcBundle -Run $run -Privacy $config.Privacy -PrivacyResult $privacyResult `
                                -Consent $consent -EndpointResults $endpointResults -Endpoint $endpoint

        $result = Complete-TlcRun -Status 'Complete'
        if ($bundle) {
            Write-Information '' -InformationAction Continue
            Write-Information "Bundle : $($bundle.BundlePath)" -InformationAction Continue
            Write-Information "SHA256 : $($bundle.BundleSha256)" -InformationAction Continue
        }
    }

    default {
        <#
            Stages beyond these arrive with their modules in later phases.

            ACCEPTING THE NAME IS DELIBERATE. -Stage takes PreCheck and Report rather than
            failing parameter validation, because someone working from older notes deserves a
            sentence rather than a binding error.

            REPORTING COMPLETE WAS NOT. This wrote Status 'Complete' into Run.json for a stage
            that did nothing at all, so a bundle claimed a pipeline had run and a script
            checking the status could not tell the difference. The Describe that fixed
            StageOrder in Tlc.Configuration.Tests named this as the open half - "that is a
            separate question from what the bundle claims happened" - and this is that
            question. Found by a debug run on 2026-09-23; finding 285.

            'Blocked' is the honest status: the run was refused, the reason is recorded as a
            blocker, and the scope evidence written before the dispatch is still on disk.
        #>
        # Report was dropped rather than built (finding 291), so it gets a sentence saying where
        # its content already lives instead of a generic "not implemented". Anything else that
        # reaches here is a stage the ValidateSet offers without a handler.
        $detail = if ($Stage -eq 'Report') {
            'Report is not a separate stage. Everything a report would carry is already in the run folder: Summary.csv, Blockers.csv and ManualChecklist.md are written by Collect, and Manifest.json by Package.'
        } else {
            "Stage $Stage is not implemented in this build."
        }
        Write-TlcEvent -Phase $Stage -Step 'NotImplemented' -Status 'Skipped' -Severity 'Warning' `
                       -Message $detail
        # Capture is named because it is built. The remediation omitted Package once for the
        # same reason (finding 40) and had quietly omitted Capture since that stage arrived.
        Write-TlcBlocker -Check "Stage:$Stage" -Status 'Warning' -Severity 'Warning' `
                         -Detail $detail `
                         -Remediation 'Run -Stage Scope, Collect, Capture, Validate or Package.' | Out-Null
        $result = Complete-TlcRun -Status 'Blocked'
        Write-Information '' -InformationAction Continue
        Write-Information $detail -InformationAction Continue
        Write-Information 'Scope evidence was still written.' -InformationAction Continue
    }
}

Write-Information '' -InformationAction Continue
if ($Stage -eq 'Capture') {
    Write-TlcStopProgress -SignalPath $CaptureStopSignalPath -Step Finalize `
        -Status $(if ($result.Status -eq 'Complete') { 'Complete' } else { 'Warning' }) -DetailKey 'StopDetailFinished'
}
Write-Information "Run complete: $($result.Status)" -InformationAction Continue
Write-Information "Evidence: $($result.RunPath)" -InformationAction Continue

<#
    A REFUSED RUN EXITS 2.

    Until 2026-09-23 every Blocked run exited 0 - a package refused by the privacy gate, a stage
    that is not implemented - so a script could not tell a refusal from a success, and the
    wizard, which reads the exit code, reported a refused package as "Finished.". Decided the
    same day, from a debug run:

        0  Complete, or ValidationOnly
        1  Failed: an unhandled error (the catch below rethrows, which -File turns into 1)
        2  Blocked: refused, and the reason is recorded as a Blocked blocker

    ONLY WHEN RUN AS THE TOP-LEVEL SCRIPT. $MyInvocation.ScriptName names the script that CALLED
    this one, so it is empty for powershell.exe -File and for a call typed at a prompt, and
    populated for a call from another script, scriptblock or test. Without this gate, `exit`
    would rob Tlc.Run.Tests - which invokes this script in-process and reads its return value -
    of the result it asserts on.

    NOT CommandOrigin, which was tried first and is wrong on one edition. With [CmdletBinding()]
    on the script, Windows PowerShell 5.1 reports CommandOrigin 'Internal' even under -File, so
    5.1 exited 0 while PowerShell 7 exited 2 for the same refused run. The first probe of that
    approach had no CmdletBinding, so it passed on both - a measurement of a different script
    from the one being changed. ScriptName was then measured on the real shape: -File exits 2,
    and a calling script, a scriptblock and Pester all keep the result, on both editions.

    The result is emitted BEFORE exiting, so `$r = .\TLC-Toolbox.ps1 ...` at a prompt still
    captures it. Finding 290.
#>
if ($result.Status -eq 'Blocked' -and -not $MyInvocation.ScriptName) {
    $result
    exit 2
}
return $result

} catch {
    # Two failure shapes, because they need different answers.
    #
    # Before Initialize-TlcRun there is no run folder and no tool log, so a failure
    # here - an unreadable configuration, an output root that cannot be created -
    # has nowhere to write. Those are precisely the failures caused by the machine
    # the tool is running on, which is the machine nobody can reach. It gets a
    # standalone log in the temp folder instead.
    #
    # After a run exists, the diagnostics belong with the evidence.
    if ($null -eq $run) {
        $failureLog = Write-TlcStartupFailure -ErrorRecord $_

        Write-Information '' -InformationAction Continue
        Write-Warning "TLC-Toolbox could not start: $($_.Exception.Message)"
        if ($failureLog) {
            Write-Information '' -InformationAction Continue
            Write-Information 'Diagnostics were written. Send this file to the toolbox owner:' -InformationAction Continue
            Write-Information "  $failureLog" -InformationAction Continue
        }
        throw
    }

    Write-TlcToolLog -Message "Unhandled failure during stage $Stage." -Level 'ERROR' -ErrorRecord $_

    # Best effort from here: the run may have failed before these were usable, and a
    # secondary failure while recording the first one must not replace it.
    $failed = $null
    try {
        Write-TlcEvent -Phase $Stage -Step 'UnhandledError' -Status 'Failed' -Severity 'Critical' `
                       -Message $_.Exception.Message -ErrorRecord $_
        Write-TlcBlocker -Check "Stage:$Stage" -Status 'Blocked' -Severity 'Critical' `
                         -Detail $_.Exception.Message `
                         -Remediation 'Send the run folder, including ToolLog.txt, to the toolbox owner.' | Out-Null
        $failed = Complete-TlcRun -Status 'Failed' -ErrorRecord $_
    } catch {
        Write-Verbose "Could not finalize the failed run: $($_.Exception.Message)"
    }

    Write-Information '' -InformationAction Continue
    Write-Warning "Run FAILED: $($_.Exception.Message)"

    # A full output volume said only "There is not enough space on the disk" - true, and it left
    # the operator to guess whether the collection was lost. It is not: every file already
    # written is intact, and the stage can simply be run again. Run.json may also still show the
    # PREVIOUS stage's status, because it cannot be rewritten on a full disk - measured on a
    # full 64 MB volume, where it still read Complete after Package had failed. Finding 310.
    $diskFull = Test-TlcDiskFullError -Exception $_.Exception
    if ($diskFull -and $run) {
        $volume = try { [System.IO.Path]::GetPathRoot([string]$run.RunPath) } catch { '' }
        Write-Information '' -InformationAction Continue
        Write-Information "The output volume $volume is full. Nothing collected so far is lost: the run folder is intact at" -InformationAction Continue
        Write-Information "  $($run.RunPath)" -InformationAction Continue
        Write-Information "Free space on $volume, then run the same stage again with -CorrelationId $($run.CorrelationId) and the same -Scenario and -CaseNumber." -InformationAction Continue
        Write-Information 'Until then, Run.json in that folder may still show the status of the previous stage.' -InformationAction Continue
    }

    if ($failed) {
        Write-Information '' -InformationAction Continue
        Write-Information 'Diagnostics were still written. Send this folder to the toolbox owner:' -InformationAction Continue
        Write-Information "  $($failed.RunPath)" -InformationAction Continue
        Write-Information '  (ToolLog.txt in that folder has the environment and the full error.)' -InformationAction Continue
    }
    throw
}
