<#
.SYNOPSIS
Runs the static analysis and test gate for the TLC Toolbox.

.DESCRIPTION
One command that has to pass before a change is done: PSScriptAnalyzer over the shipped code, then
Pester over Tests\.

Analysis and tests are reported separately rather than as one number, because they fail for
different reasons and the fix for each is different. The exit code is non-zero if either fails, so
this can gate a commit.

.PARAMETER Analysis
Run only the static analysis.

.PARAMETER Tests
Run only the tests.

.PARAMETER TestPath
Run a single test file rather than the whole folder.

.EXAMPLE
.\Invoke-TlcBuild.ps1

.EXAMPLE
.\Invoke-TlcBuild.ps1 -TestPath Tests\Tlc.Privacy.Tests.ps1
#>
[CmdletBinding()]
param(
    [switch] $Analysis,
    [switch] $Tests,
    [string] $TestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolboxRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$runAnalysis = $Analysis -or -not ($Analysis -or $Tests)
$runTests = $Tests -or -not ($Analysis -or $Tests)

$analysisFailed = 0
$testsFailed = 0
$testsSkipped = 0

# A mutation left in the source by a killed Tools\Invoke-TlcMutationCheck.ps1 run. The tool
# writes a record before it changes a file and removes it after a verified restore, so a record
# whose file still differs from its good hash is a mutation still applied, and every result this
# gate could produce would describe it (review 2026-09-30, finding 331).
foreach ($record in @(Get-ChildItem -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) 'tlc-mutation-pending') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $pending = Get-Content -LiteralPath $record.FullName -Raw | ConvertFrom-Json
    $current = if (Test-Path -LiteralPath $pending.Target) { (Get-FileHash -LiteralPath $pending.Target -Algorithm SHA256).Hash } else { '' }
    if ($current -ne $pending.GoodHash) {
        throw "A mutation is still applied to $($pending.Target) (run started $($pending.StartedUtc)). Restore it from $($pending.Backup), then delete $($record.FullName), before running the gate."
    }
}

if ($runAnalysis) {
    Write-Information '' -InformationAction Continue
    Write-Information 'Static analysis' -InformationAction Continue

    try {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
    } catch {
        # A missing gate dependency should name the fix, not the exception. Anyone who
        # has just cloned this will hit it, and "module not found" is not the useful part.
        throw "PSScriptAnalyzer is required by this gate and is not installed. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
    }

    $settings = Join-Path $toolboxRoot 'PSScriptAnalyzerSettings.psd1'
    # Tests\ is deliberately not linted under these settings. Test code legitimately
    # does things the shipped code should not, and mixing the two means the signal
    # from Modules\ drowns in noise from fixtures.
    $targets = @(Get-ChildItem -LiteralPath $toolboxRoot -File -Filter '*.ps1') +
               @(Get-ChildItem -LiteralPath (Join-Path $toolboxRoot 'Modules') -File -Filter '*.psm1')

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $findings.AddRange([object[]] @(Invoke-ScriptAnalyzer -Path $target.FullName -Settings $settings))
    }

    # Tools\, under its own rule set.
    #
    # It was scanned by nothing until 2026-09-15 and had quietly accumulated 67 findings - six
    # empty catch blocks, a function shadowing the built-in Write-Log, four unapproved verbs.
    # None of that was ever reported, because the loop above stops at Modules\ and the summary
    # line printed a zero regardless. A folder nobody lints looks exactly like a clean one.
    #
    # Separate settings because the contract differs: these scripts print a console report for a
    # person watching, so Write-Host is correct in them and wrong in the product.
    $toolsFolder = Join-Path $toolboxRoot 'Tools'
    $toolsSettings = Join-Path $toolboxRoot 'PSScriptAnalyzerSettings.Tools.psd1'
    $toolTargets = @(Get-ChildItem -LiteralPath $toolsFolder -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    foreach ($target in $toolTargets) {
        $findings.AddRange([object[]] @(Invoke-ScriptAnalyzer -Path $target.FullName -Settings $toolsSettings))
    }

    # Tests\, under its own rule set - the last folder that was scanned by nothing.
    #
    # It held 46 findings, 11 of them real: two assignments to automatic variables ($input is
    # the pipeline enumerator, $event belongs to eventing), five empty catch blocks that
    # swallowed which exception was thrown, and two variables computed then abandoned in tests
    # that read their answer from somewhere else entirely.
    #
    # Separate settings again because the contract differs once more: a test may reach into
    # scopes to observe them and execute a generated string to prove it runs, and neither is
    # acceptable in code that ships.
    $testsFolder = Join-Path $toolboxRoot 'Tests'
    $testsSettings = Join-Path $toolboxRoot 'PSScriptAnalyzerSettings.Tests.psd1'
    $testTargets = @(Get-ChildItem -LiteralPath $testsFolder -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    foreach ($target in $testTargets) {
        $findings.AddRange([object[]] @(Invoke-ScriptAnalyzer -Path $target.FullName -Settings $testsSettings))
    }
    $targets = @($targets) + @($toolTargets) + @($testTargets)

    if ($findings.Count) {
        foreach ($finding in $findings) {
            Write-Information ("  {0}  {1}:{2}  {3}" -f $finding.RuleName,
                (Split-Path -Leaf $finding.ScriptPath), $finding.Line, $finding.Message) -InformationAction Continue
        }
        $analysisFailed = $findings.Count
        Write-Information "  $($findings.Count) finding(s)." -InformationAction Continue
    } else {
        Write-Information "  Clean across $($targets.Count) file(s)." -InformationAction Continue
    }
}

if ($runTests) {
    Write-Information '' -InformationAction Continue
    Write-Information 'Tests' -InformationAction Continue

    try {
        Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
    } catch {
        # Windows ships Pester 3.4, which will not run these files at all, so the
        # version is the part worth saying out loud.
        throw "Pester 5 or later is required by this gate. Install it with: Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck"
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        # The UI cases load WPF markup, which needs STA. They skip rather than fail on
        # an MTA host, so say so instead of leaving a silent gap in the count.
        Write-Information '  Note: not an STA thread, so the wizard cases will skip. Use Windows PowerShell for full coverage.' -InformationAction Continue
    }

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = if ($TestPath) { $TestPath } else { Join-Path $toolboxRoot 'Tests' }
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'

    $result = Invoke-Pester -Configuration $configuration

    # A container that fails to load reports no failed tests, because none of its tests
    # ever ran. Counting only FailedCount would let a test file with a discovery-time
    # error - a broken -Skip expression, a syntax error, a missing module - pass the
    # gate silently, which is the opposite of what a gate is for.
    #
    # The discriminator is which tests claim the file, not anything on the container.
    # A Pester container carries no Tests property at all, so an earlier version of this
    # check - "failed and holds no tests" - was true of every failing container and
    # labelled ordinary test failures as load failures.
    #
    # FullName, not the FileInfo itself. Item is a System.IO.FileInfo, and FileInfo
    # stringifies to whatever path it was constructed with: the full path when Pester is
    # handed explicit files, but the bare leaf name when it is handed a folder and
    # discovers them - which is how this script calls it. Comparing that against
    # ScriptBlock.File, which is always absolute, matched nothing and flagged every
    # failing file as unloadable. Reproducing it with explicit file paths tested a
    # different code path and looked fine.
    $brokenContainers = @($result.Containers | Where-Object {
        if ($_.Passed) { return $false }
        if ($_.Result -ne 'Failed') { return $false }

        $file = if ($_.Item -is [System.IO.FileInfo]) { $_.Item.FullName } else { [string]$_.Item }
        $owned = @($result.Tests | Where-Object {
            $_.ScriptBlock -and ([string]$_.ScriptBlock.File) -eq $file
        })
        return ($owned.Count -eq 0)
    })
    foreach ($container in $brokenContainers) {
        $name = if ($container.Item -is [System.IO.FileInfo]) { $container.Item.FullName } else { [string]$container.Item }
        Write-Warning "Test file failed to load: $name"
    }

    $testsFailed = $result.FailedCount + $brokenContainers.Count

    # Failures are named, not just counted. This is the mirror of the skipped block below,
    # and it was missing: the summary said "Test failures: 1" and Pester's own Normal-verbosity
    # output had already scrolled past by the time anyone read it.
    #
    # That is not a cosmetic gap. A run failed once here, could not be reproduced across nine
    # subsequent clean runs, and could not be investigated at all because nothing had recorded
    # WHICH test it was. A gate that reports a count without a name turns a one-off into an
    # unfixable one - and a flake nobody can name is a flake nobody can fix.
    #
    # The message is included, trimmed to one line. The file and the expanded name identify the
    # test; the first line of the error usually identifies the cause, which is the difference
    # between "it failed again" and "it failed the same way".
    #
    # Every line in this block carries a FAILED marker. Not because the block was wrong - it
    # named its test correctly - but because on 2026-09-09 a gate run was piped through
    # Select-String with a pattern that matched the "N test(s) failed:" header and not the
    # indented name beneath it. The count survived the filter and the identity did not, and an
    # intermittent failure that never reproduced lost the only record of what it was. Output
    # whose whole purpose is to be read after piping should not depend on the reader guessing
    # the indent.
    if ($result.FailedCount) {
        Write-Information '' -InformationAction Continue
        Write-Information "  $($result.FailedCount) test(s) failed:" -InformationAction Continue
        foreach ($test in ($result.Tests | Where-Object { $_.Result -eq 'Failed' })) {
            $file = if ($test.ScriptBlock -and $test.ScriptBlock.File) { Split-Path -Leaf $test.ScriptBlock.File } else { '(unknown file)' }
            Write-Information ("    FAILED  {0}: {1}" -f $file, $test.ExpandedName) -InformationAction Continue

            # ErrorRecord is a collection; a test can fail more than one assertion. Joined and
            # collapsed to a single line so the summary stays readable, because a summary that
            # scrolls is the thing being fixed.
            $reason = (@($test.ErrorRecord) -join ' ') -replace '\s+', ' '
            if ($reason) {
                if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) + '...' }
                Write-Information ("    FAILED  because: {0}" -f $reason.Trim()) -InformationAction Continue
            }
        }
    }

    # Skipped tests are named, not just counted. A skip is legitimate here - no Teams
    # installed, an MTA host - but in the summary line a skipped test is indistinguishable
    # from a passing one, and a -Skip condition evaluated at discovery against a variable
    # that is not set yet silently skips rather than failing. That has happened in this
    # repository, and the suite reported green while the new coverage never ran. Anything
    # that did not actually execute gets said out loud.
    $testsSkipped = $result.SkippedCount
    if ($testsSkipped) {
        Write-Information '' -InformationAction Continue
        Write-Information "  $testsSkipped test(s) did not run:" -InformationAction Continue
        foreach ($test in ($result.Tests | Where-Object { $_.Result -eq 'Skipped' })) {
            Write-Information ("    SKIPPED {0}: {1}" -f (Split-Path -Leaf $test.ScriptBlock.File), $test.ExpandedName) -InformationAction Continue
        }
    }
}

Write-Information '' -InformationAction Continue

# "not run" rather than 0 for anything that was skipped by a switch.
#
# This line used to print "Analysis findings: 0" whether or not the analyser had run, and
# -Tests turns the analyser off. Every gate run reported through that switch therefore read as
# clean on static analysis from a check that never executed - and two real findings sat in
# shipped modules across several segments being reported as zero each time.
#
# The same trap the toolbox documents about grep audits and about netsh: a count of zero from a
# probe that did not run is indistinguishable from a count of zero from a probe that did.
$analysisText = if ($runAnalysis) { [string]$analysisFailed } else { 'not run (-Tests)' }
$testsText = if ($runTests) { [string]$testsFailed } else { 'not run (-Analysis)' }
$skippedText = if ($runTests) { [string]$testsSkipped } else { 'not run (-Analysis)' }
Write-Information ('Analysis findings: {0}    Test failures: {1}    Skipped: {2}' -f $analysisText, $testsText, $skippedText) -InformationAction Continue

# Signing state is reported, never enforced. The toolbox is unsigned during development and that is
# fine; what is not fine is handing it to a customer without noticing. Collect-TeamsLogs.cmd tells
# them to use -ExecutionPolicy Bypass precisely because of this, so the state belongs somewhere a
# person looks before a handover rather than only in a comment.
#
# The set comes from Tools\Get-TlcSignableFile.ps1, the same definition Set-TlcSignature.ps1 signs
# from. This file used to carry its own folder scan, which counted the build gate and lint config
# as product and adopted any scratch .ps1 left in the root - so the reported total moved when a
# throwaway script was deleted.
. (Join-Path $toolboxRoot 'Tools\Get-TlcSignableFile.ps1')
$signable = @(Get-TlcSignableFile -Root $toolboxRoot)
$unsigned = @($signable | Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -ne 'Valid' })
if ($unsigned.Count) {
    Write-Information ('Signing: {0} of {1} shipped file(s) are not validly signed. Run Tools\Set-TlcSignature.ps1 for detail.' -f $unsigned.Count, $signable.Count) -InformationAction Continue
} else {
    Write-Information ('Signing: all {0} shipped file(s) validly signed.' -f $signable.Count) -InformationAction Continue
}

if ($analysisFailed -or $testsFailed) { exit 1 }
exit 0
