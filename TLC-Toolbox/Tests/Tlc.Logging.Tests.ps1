#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
Diagnostics for a run that happened somewhere unreachable.

Before this existed, the entry point had no top-level failure capture at all: an unhandled error
terminated the script before Complete-TlcRun, so Run.json was never written and the error was
recorded nowhere. A customer whose collection failed had nothing to send back but a console
message.

Culture is in the environment header deliberately. The customer collector accepts a
locally-formatted time, and parsing follows the current culture - so a machine on a different
locale can read the same input differently and produce a bundle for the wrong window while
appearing to work.
#>

BeforeAll {
    $script:ToolboxRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Logging.psm1') -Force
}

Describe 'Get-TlcEnvironmentFact' {

    It 'records the facts needed to debug a run from a distance' -ForEach @(
        @{ Key = 'PsVersion' }
        @{ Key = 'PsEdition' }
        @{ Key = 'Culture' }
        @{ Key = 'TimeZoneId' }
        @{ Key = 'UtcOffsetHours' }
        @{ Key = 'OsBuild' }
        @{ Key = 'Elevated' }
        @{ Key = 'ExecutionPolicy' }
        @{ Key = 'LanguageMode' }
    ) {
        (Get-TlcEnvironmentFact).Contains($Key) | Should -BeTrue
    }

    It 'still reports the execution policy when the Security module will not load' {
        <#
        Get-ExecutionPolicy lives in Microsoft.PowerShell.Security, and that module can fail to
        load - a type-data conflict made it unavailable here, in exactly the way the GUI runs a
        stage, and the cmdlet threw CommandNotFoundException. The field went blank.

        Losing this one is worse than losing most, because it is the field that diagnoses "the
        script will not run on my machine". PSExecutionPolicyPreference is set by powershell.exe
        from -ExecutionPolicy and needs no module at all.
        #>
        Mock Get-ExecutionPolicy -ModuleName Tlc.Logging { throw [System.Management.Automation.CommandNotFoundException]::new('unavailable') }

        $previous = $env:PSExecutionPolicyPreference
        $env:PSExecutionPolicyPreference = 'RemoteSigned'
        try {
            (Get-TlcEnvironmentFact).ExecutionPolicy | Should -Be 'RemoteSigned'
        } finally {
            $env:PSExecutionPolicyPreference = $previous
        }
    }

    It 'says so rather than going blank when the policy cannot be determined at all' {
        Mock Get-ExecutionPolicy -ModuleName Tlc.Logging { throw [System.Management.Automation.CommandNotFoundException]::new('unavailable') }

        $previous = $env:PSExecutionPolicyPreference
        $env:PSExecutionPolicyPreference = ''
        try {
            (Get-TlcEnvironmentFact).ExecutionPolicy | Should -Be 'unavailable'
        } finally {
            $env:PSExecutionPolicyPreference = $previous
        }
    }

    It 'records the language mode, because constrained mode breaks the toolbox quietly' {
        # A normal setting in a locked-down enterprise. Without it recorded, a run that fails
        # there looks like an ordinary bug.
        (Get-TlcEnvironmentFact).LanguageMode |
            Should -Be ($ExecutionContext.SessionState.LanguageMode.ToString())
    }

    It 'always fills in the culture' {
        # Without it, a wrong-window bundle is undiagnosable remotely.
        (Get-TlcEnvironmentFact).Culture | Should -Not -BeNullOrEmpty
    }

    It 'gives a fresh timestamp on every call' {
        <#
        Caching the whole record froze CapturedAtUtc, so a second run in the same session stamped
        its log header with the first run's time. The tool log exists to debug runs from a
        distance; a plausible-looking wrong timestamp in it is worse than no cache at all.
        #>
        $first = Get-TlcEnvironmentFact
        Start-Sleep -Milliseconds 20
        $second = Get-TlcEnvironmentFact
        $second.CapturedAtUtc | Should -Not -Be $first.CapturedAtUtc
    }

    It 'reads the per-thread and per-session facts on every call' {
        # ApartmentState is a property of the calling thread and the process execution policy can
        # be changed mid-session, so neither can be answered from a cache filled somewhere else.
        (Get-TlcEnvironmentFact).ApartmentState |
            Should -Be ([System.Threading.Thread]::CurrentThread.GetApartmentState().ToString())
    }

    It 'only pays for the expensive machine lookups once' {
        # Get-AppxPackage plus the CIM query cost over a second. They describe the machine, which
        # does not change during a run, so they are the part that is cached.
        Mock Get-CimInstance -ModuleName Tlc.Logging { [pscustomobject]@{ Caption = 'Test OS'; BuildNumber = '1' } }

        Get-TlcEnvironmentFact -Refresh | Out-Null
        Get-TlcEnvironmentFact | Out-Null
        Get-TlcEnvironmentFact | Out-Null

        Should -Invoke Get-CimInstance -ModuleName Tlc.Logging -Times 1 -Exactly
    }

    It 'still reports the cached machine facts on later calls' {
        $first = Get-TlcEnvironmentFact -Refresh
        $second = Get-TlcEnvironmentFact
        $second.OsBuild | Should -Be $first.OsBuild
        $second.TeamsVersion | Should -Be $first.TeamsVersion
    }
}

Describe 'Write-TlcToolLog' {

    It 'does nothing, and throws nothing, when no log is open' {
        # Logging must never be able to break the thing it is observing.
        { Write-TlcToolLog -Message 'no log open' } | Should -Not -Throw
    }

    It 'writes an environment header when the log is started' {
        $path = Join-Path $TestDrive 'header.log'
        Start-TlcToolLog -Path $path -Context 'Test' | Out-Null
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -BeLike '*PsVersion*'
        $content | Should -BeLike '*Culture*'
    }

    It 'records an exception with its stack' {
        $path = Join-Path $TestDrive 'error.log'
        Start-TlcToolLog -Path $path -Context 'Test' | Out-Null
        try { throw 'simulated failure' } catch { Write-TlcToolLog -Message 'It failed.' -Level 'ERROR' -ErrorRecord $_ }

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -BeLike '*[ERROR]*'
        $content | Should -BeLike '*simulated failure*'
        $content | Should -BeLike '*Stack*'
    }
}

Describe 'Write-TlcStartupFailure' {

    It 'writes a standalone log when there is no run folder yet' {
        # Anything that fails before Initialize-TlcRun has nowhere to write, and those
        # are the failures caused by the machine the tool is running on.
        try { throw 'config is unreadable' } catch { $errorRecord = $_ }
        $path = Write-TlcStartupFailure -ErrorRecord $errorRecord

        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeTrue

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -BeLike '*PsVersion*'
        $content | Should -BeLike '*config is unreadable*'
        $content | Should -BeLike '*Stack*'

        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Initialize-TlcRun and Complete-TlcRun' {

    It 'opens a tool log before anything else can fail' {
        $run = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs') -Scenario 'DesktopLaunchCrash'
        Test-Path -LiteralPath (Join-Path $run.RunPath 'ToolLog.txt') | Should -BeTrue
    }

    It 'records a failure status and the error in Run.json' {
        $run = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-failed') -Scenario 'DesktopLaunchCrash'
        try { throw 'simulated failure' } catch { $errorRecord = $_ }
        Complete-TlcRun -Status 'Failed' -ErrorRecord $errorRecord | Out-Null

        $runJson = Get-Content -LiteralPath (Join-Path $run.RunPath 'Run.json') -Raw | ConvertFrom-Json
        $runJson.Status | Should -Be 'Failed'
        $runJson.Error.Message | Should -BeLike '*simulated failure*'
    }

    It 'writes events as JSON Lines so a partial run stays readable' {
        # A cancelled or crashed run still leaves every event up to that point parseable,
        # which a single JSON document would not.
        $run = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-events') -Scenario 'Network'
        Write-TlcEvent -Phase 'Test' -Step 'One' -Status 'Complete' -Message 'first'
        Write-TlcEvent -Phase 'Test' -Step 'Two' -Status 'Warning' -Severity 'Warning' -Message 'second'

        $lines = @(Get-Content -LiteralPath (Join-Path $run.RunPath 'Events.jsonl'))
        $lines.Count | Should -BeGreaterThan 1
        foreach ($line in $lines) { { $line | ConvertFrom-Json } | Should -Not -Throw }
    }
}

Describe 'Write-TlcBlocker' {

    It 'marks a Blocked row as blocked and leaves a Warning row unblocked' {
        Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-blockers') -Scenario 'Network' | Out-Null
        $blocked = Write-TlcBlocker -Check 'Test.Blocked' -Status 'Blocked' -Severity 'Critical' -Detail 'x'
        $warned = Write-TlcBlocker -Check 'Test.Warning' -Status 'Warning' -Severity 'Warning' -Detail 'x'

        $blocked.Blocked | Should -BeTrue
        $warned.Blocked | Should -BeFalse
    }
}

Describe 'Export-TlcEvidence' {
    <#
        An empty collection piped to ConvertTo-Json produces no output, so no file was written -
        and Collect.json still named it. A window with zero events left EventLogPath pointing at
        nothing, which reads exactly like a lane that never ran. Seen on every capture of the
        live call test, where the session windows were quiet.
    #>

    BeforeAll {
        Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-evidence') -Scenario 'DesktopLaunchCrash' | Out-Null
    }

    It 'writes an empty collection as [] rather than writing nothing' {
        $path = Export-TlcEvidence -Name 'EventLogs.json' -InputObject @() -Endpoint 'TESTPC'
        Test-Path -LiteralPath $path | Should -BeTrue -Because 'the path is recorded in Collect.json, so the file has to exist'
        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be '[]'
    }

    It 'still serialises a populated collection and an object as before' {
        $path = Export-TlcEvidence -Name 'Two.json' -InputObject @(@{ A = 1 }, @{ A = 2 }) -Endpoint 'TESTPC'
        # Enumerated explicitly: 5.1's ConvertFrom-Json emits a JSON array as ONE pipeline
        # object, so wrapping it in @() counts 1 on 5.1 and 2 on 7.
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($parsed | ForEach-Object { $_ }).Count | Should -Be 2
        $path = Export-TlcEvidence -Name 'Empty-Map.json' -InputObject @{} -Endpoint 'TESTPC'
        ((Get-Content -LiteralPath $path -Raw) -replace '\s', '') | Should -Be '{}' -Because 'an empty dictionary is an object, not a list'
    }
}

<#
Native stderr is a terminating error on 5.1.

Windows PowerShell 5.1 wraps each stderr line from a native command in a NativeCommandError
record whenever that stream is redirected. Both entry points set $ErrorActionPreference to
Stop and module functions inherit it, so a redirected native command threw the moment the
executable wrote one line to stderr - even on exit 0.

The reason it survived so long is that it is inverted against the cases that matter. dsregcmd
on a healthy machine is silent, so every test and every well-configured device passed. It
writes to stderr when the join state is broken, which is the condition the collector exists to
capture. The catch block then recorded "dsregcmd is unavailable" - a false statement about a
tool that is installed and working - and the join state was missing from the bundle.
#>

Describe 'Invoke-TlcNativeCommand' {

    It 'survives a command that writes to stderr, where a bare redirect throws on 5.1' {
        $ErrorActionPreference = 'Stop'

        # The pattern the collectors used, exercised for real. It throws on 5.1 and does NOT
        # throw on 7 - and that asymmetry is the whole reason the defect survived: it is
        # invisible to anyone developing or testing on PowerShell 7, while every customer
        # endpoint runs 5.1.
        $threw = $false
        try { $null = @(& schtasks.exe /Query /TN 'TLC-NoSuchTask-ZZZ' 2>&1) } catch { $threw = $true }

        if ($PSVersionTable.PSVersion.Major -le 5) {
            $threw | Should -BeTrue -Because 'a redirected native stderr line terminates under Stop on 5.1'
        } else {
            $threw | Should -BeFalse -Because 'PowerShell 7 does not raise NativeCommandError, which is exactly why the 5.1 defect went unnoticed'
        }

        # The helper must behave identically on both, so a collector written against it does
        # not depend on which host the engineer happened to test with.
        $result = Invoke-TlcNativeCommand -FilePath 'schtasks.exe' -ArgumentList @('/Query', '/TN', 'TLC-NoSuchTask-ZZZ')
        $result.Available | Should -BeTrue
        $result.ExitCode | Should -Not -Be 0
        $result.Errors.Count | Should -BeGreaterThan 0
    }

    It 'still reports a genuinely missing executable as unavailable' {
        # This distinction is the point. "The tool is not installed" and "the tool answered on
        # stderr" are different facts about the endpoint and must not collapse into one.
        $result = Invoke-TlcNativeCommand -FilePath 'tlc-definitely-not-real-zzz.exe'
        $result.Available | Should -BeFalse
        $result.Detail | Should -Not -BeNullOrEmpty
    }

    It 'returns stdout and exit code for a command that succeeds' {
        $result = Invoke-TlcNativeCommand -FilePath 'whoami.exe'
        $result.Available | Should -BeTrue
        $result.ExitCode | Should -Be 0
        ($result.Output -join '') | Should -Not -BeNullOrEmpty
    }

    It 'restores the caller ErrorActionPreference' {
        $ErrorActionPreference = 'Stop'
        $null = Invoke-TlcNativeCommand -FilePath 'whoami.exe'
        $ErrorActionPreference | Should -Be 'Stop'
    }

    It 'no shipping file redirects native stderr without holding the preference at Continue' {
        # AST rather than a text search: a regex for 2>&1 cannot tell whether the enclosing
        # scope has already set Continue, and would fail the two remote scriptblocks that
        # handle this correctly inline.
        #
        # Sweeps Tools\ and the root entry points as well as Modules\. The entry points are
        # where $ErrorActionPreference = 'Stop' is actually SET, so they are the last place the
        # trap should have been left unswept - the guard originally looked only at Modules\.
        $roots = @(
            (Join-Path $script:ToolboxRoot 'Modules'),
            (Join-Path $script:ToolboxRoot 'Tools')
        )
        $files = @()
        foreach ($dir in $roots) {
            if (Test-Path $dir) { $files += @(Get-ChildItem $dir -File | Where-Object { $_.Extension -in '.psm1', '.ps1' }) }
        }
        $files += @(Get-ChildItem $script:ToolboxRoot -Filter '*.ps1' -File)
        $offenders = @()

        foreach ($module in $files) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($module.FullName, [ref]$null, [ref]$errors)
            if ($errors -and $errors.Count) { continue }

            $redirections = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.RedirectionAst] -and
                $node.FromStream -eq [System.Management.Automation.Language.RedirectionStream]::Error
            }, $true)

            foreach ($redirection in $redirections) {
                # Only native commands. The hazard is NativeCommandError, which PowerShell
                # creates for external executables; a cmdlet's redirected error stream is
                # ordinary and legitimate - Tlc.Collect.Network uses one deliberately to
                # swallow nested-cmdlet noise from Get-NetIPConfiguration.
                $command = $redirection.Parent
                while ($command -and $command -isnot [System.Management.Automation.Language.CommandAst]) { $command = $command.Parent }
                if (-not $command) { continue }

                $name = $command.GetCommandName()
                if (-not $name) { continue }
                $isNative = $name -match '\.exe$'
                if (-not $isNative) {
                    $resolved = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
                    $isNative = ($resolved -and $resolved.CommandType -eq 'Application')
                }
                if (-not $isNative) { continue }

                # Walk out to the enclosing scriptblock and ask whether Continue is set in it.
                $scope = $redirection
                $guarded = $false
                while ($scope) {
                    if ($scope -is [System.Management.Automation.Language.ScriptBlockAst]) {
                        $assignments = $scope.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                            $node.Left.Extent.Text -match 'ErrorActionPreference' -and
                            $node.Right.Extent.Text -match 'Continue'
                        }, $false)
                        if ($assignments.Count -gt 0) { $guarded = $true; break }
                    }
                    $scope = $scope.Parent
                }
                if (-not $guarded) {
                    $offenders += "$($module.Name):$($redirection.Extent.StartLineNumber) $name $($redirection.Extent.Text)"
                }
            }
        }

        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'redirected native stderr terminates under Stop on 5.1 and silently loses the evidence'
    }
}

<#
Copy-Item creates the destination before it fails.

A locked source therefore leaves a zero-byte file: absent evidence wearing the shape of present
evidence. Measured on a real collection, 4 of 40 Teams logs failed this way because the running
client holds its newest log open - including a 376 KB log that landed as 0 bytes. The same
defect was written independently in three separate modules, which is why it is now a guard
rather than a habit. See findings 129 and 133.
#>

Describe 'Copy-Item partial-file handling' {

    It 'every Copy-Item in a shipping module deletes its partial file on failure' {
        $moduleRoot = Join-Path $script:ToolboxRoot 'Modules'
        $offenders = @()

        foreach ($module in Get-ChildItem $moduleRoot -Filter '*.psm1') {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($module.FullName, [ref]$null, [ref]$errors)
            if ($errors -and $errors.Count) { continue }

            $copies = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Copy-Item'
            }, $true)

            foreach ($copy in $copies) {
                $try = $copy.Parent
                while ($try -and $try -isnot [System.Management.Automation.Language.TryStatementAst]) {
                    $try = $try.Parent
                }
                if (-not $try) {
                    $offenders += "$($module.Name):$($copy.Extent.StartLineNumber) not inside try"
                    continue
                }
                # The failure path must delete the partial somewhere in the same function. Not
                # "inside the catch" specifically: Tlc.Collect.Rooms catches into a variable and
                # then removes the file if the copy errored OR landed at zero bytes, which is
                # stronger than a catch-block removal because it also catches a silent
                # zero-byte success. A guard that insisted on one shape failed correct code.
                $function = $copy.Parent
                while ($function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $function = $function.Parent
                }
                $scope = if ($function) { $function } else { $try }
                $removes = $scope.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Remove-Item'
                }, $true)
                if ($removes.Count -eq 0) {
                    $offenders += "$($module.Name):$($copy.Extent.StartLineNumber) nothing removes the partial file"
                }
            }
        }

        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'a failed copy leaves a zero-byte file that reads as an empty log rather than a missing one'
    }
}

Describe 'Test-TlcDiskFullError' {
    # Finding 310: a full output volume said only "There is not enough space on the disk".
    It 'recognises a full disk, wrapped or not, and nothing else' {
        $full = [System.IO.IOException]::new('There is not enough space on the disk.', -2147024784)
        Test-TlcDiskFullError -Exception $full | Should -BeTrue
        Test-TlcDiskFullError -Exception ([System.Exception]::new('wrapped', $full)) | Should -BeTrue -Because 'cmdlets wrap the IOException'
        Test-TlcDiskFullError -Exception ([System.IO.IOException]::new('sharing violation', -2147024864)) | Should -BeFalse
        Test-TlcDiskFullError -Exception $null | Should -BeFalse
    }
}

Describe 'Get-TlcRemoteConnectHint' {
    # Finding 316. Only an unresolvable name gets a hint; everything else keeps WinRM's message.
    It 'names DNS for a name that does not resolve, and says nothing for one that does' {
        Get-TlcRemoteConnectHint -HostName 'tlc-no-such-host.invalid' | Should -Match 'does not resolve in DNS'
        Get-TlcRemoteConnectHint -HostName 'localhost' | Should -BeNullOrEmpty
    }
}

Describe 'A run id or endpoint name cannot leave the run folder' {
    <#
        Review 2026-09-30, finding 331. -CorrelationId and endpoint names are joined into paths
        as they were typed. '..\..\somewhere' put the run folder outside the output root, where
        Package later zips it and a re-run with the same id deletes and rewrites it. Both are
        held to a single folder name now, refused before anything is created.
    #>

    It 'refuses a run id that is not a single folder name, and creates nothing' {
        $root = Join-Path $TestDrive 'runs-traversal'
        $null = New-Item -ItemType Directory -Path $root -Force
        foreach ($bad in @('..\escaped', '..', 'a\b', 'C:\elsewhere', 'a/b')) {
            { Initialize-TlcRun -RunRoot $root -Scenario 'DesktopLaunchCrash' -CorrelationId $bad } |
                Should -Throw -ExpectedMessage '*cannot be used as a folder name*'
        }
        Test-Path -LiteralPath (Join-Path $TestDrive 'escaped') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
    }

    It 'still takes a guid and the readable ids the tests and operators use' {
        $root = Join-Path $TestDrive 'runs-good-ids'
        foreach ($good in @([guid]::NewGuid().ToString(), 'carry-forward-id', 'case_1234.retry')) {
            (Initialize-TlcRun -RunRoot $root -Scenario 'DesktopLaunchCrash' -CorrelationId $good).CorrelationId | Should -Be $good
        }
    }

    It 'refuses an endpoint name that is not a single folder name' {
        $null = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-endpoint') -Scenario 'DesktopLaunchCrash'
        { Export-TlcEvidence -Name 'x.json' -InputObject @{ a = 1 } -Endpoint '..\..\outside' } |
            Should -Throw -ExpectedMessage '*cannot be used as a folder name*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'outside') | Should -BeFalse
        (Export-TlcEvidence -Name 'x.json' -InputObject @{ a = 1 } -Endpoint 'MTR-ROOM-01') | Should -Exist
    }
}