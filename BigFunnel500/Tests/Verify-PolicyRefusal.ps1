<#
.SYNOPSIS
    Gate F - produce the scheduled-task policy refusal with a REAL access control,
    not an injected fault, and measure what the monitor actually says about it.

.DESCRIPTION
    This is the gap that matters most, because the blocked path IS the customer's
    primary environment and it has only ever been proven against a mock.

    run-tests.ps1 covers the refusal twice (T54d and the standalone case) by setting
    MOCK_TASK_DENY=1, which makes the script's own harness throw a synthetic "Access
    is denied". The monitor then matches it at :2282 with

        $msg -match '(?i)access is denied|0x80070005|not authorized|denied'

    and prints "policy prevents local administrators from creating scheduled tasks".

    That proves the HANDLER works when handed a message it already expects. It does
    not prove a real policy produces such a message. Those are different claims, and
    only the second one is what the customer is being told.

    So this gate takes the mock away and denies the right for real.

    THE CONTROL IS NOT OPTIONAL. An "access denied" from an account that could never
    register a task anyway proves nothing. F0 registers successfully first, with
    nothing in the way, so the denial in F1/F2 is attributable to the ACL and to
    nothing else. F4 registers successfully again afterwards, which is what makes the
    revert a measurement rather than an intention.

    TWO LEVERS, because an estate could use either and they are not the same thing:

      F1  the FILESYSTEM ACL on %SystemRoot%\System32\Tasks
      F2  the Task Scheduler's OWN per-folder security descriptor, held in the
          registry and reached through the Schedule.Service COM API

    F2 is the native mechanism and the likelier one in a managed estate. F1 is the
    blunter one. The gate runs F1 first and escalates to F2 only if F1 did not
    actually block, because if the blunt lever works the native one adds nothing.

    SAFETY. Three properties, in the order they matter:

      1. The deny ACE grants no right it does not need and REMOVES none that would
         prevent its own removal. WRITE_DAC and WRITE_OWNER are deliberately left
         out of the deny mask, so the account applying the deny can always lift it.
         Administrators additionally retain SeTakeOwnership/SeRestore.
      2. A DEAD-MAN'S SWITCH is registered BEFORE the deny is applied - a one-shot
         SYSTEM task that restores the baseline and fires in -DeadManMinutes. Order
         is load-bearing: once the deny is on, this account cannot create that task.
         If the session dies mid-gate the box heals itself without anyone logging in.
      3. Revert is verified by comparing the SDDL against the baseline captured
         before anything was touched, not by assuming Set-Acl worked.

    WHAT IT TOUCHES, and nothing else: one deny ACE naming exactly one principal,
    one temp directory, and up to three scheduled tasks all named BFGATEF*. It does
    not restart the Schedule service, does not edit policy, does not touch Exchange,
    and never denies a principal other than the one it runs as.

.NOTES
    Runs ON w25-ex01, pushed there by push-and-run-gateF.ps1. The monitor is invoked
    IN-PROCESS rather than through -File, because -TaskCredential is a PSCredential
    and cannot cross a process boundary - the monitor says so itself at :2413-2420.
    That costs the real process exit code, so $LASTEXITCODE is read instead and the
    run log is read back as corroboration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [System.Management.Automation.PSCredential]$TaskCredential,

    # Where the monitor lives on this box. Set by the trip script.
    [string]$MonitorPath = (Join-Path $PSScriptRoot '..\Monitor-BigFunnelPostingList.ps1'),

    # Its own name, so it can never collide with the product task or with Gate B's.
    [string]$TaskName = 'BFGATEF Policy Refusal Probe',

    [string]$WorkRoot = (Join-Path $env:ProgramData 'BFGateF'),

    # How long the self-heal waits before firing. Long enough that a slow gate does
    # not trip it, short enough that an abandoned box does not stay denied.
    [int]$DeadManMinutes = 15,

    # Skip the native-SD lever even if the filesystem one did not block. For a first
    # run where only the blunt lever is in question.
    [switch]$SkipNativeLever
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:fail    = 0
$script:results = [ordered]@{}

function Write-Head { param($Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan; Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray }
function Write-Measured { param($Label, $Value) Write-Host ('  {0} {1}' -f ([string]$Label).PadRight(38), $Value) }
function Write-Check {
    param($Label, [bool]$Ok, $Detail)
    if (-not $Ok) { $script:fail++ }
    Write-Host ('  {0}  {1}' -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Label) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
    if ($Detail) { Write-Host ('        ' + $Detail) -ForegroundColor DarkGray }
}

$tasksDir  = Join-Path $env:SystemRoot 'System32\Tasks'
$me        = '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName
$deadManTask = 'BFGATEF Self Heal'
$probeTask   = 'BFGATEF Raw Probe'

Write-Head 'Gate F - context'
Write-Measured 'machine'            ([Environment]::MachineName)
Write-Measured 'running as'         $me
Write-Measured 'elevated'           (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Write-Measured 'monitor'            $MonitorPath
Write-Measured 'Tasks folder'       $tasksDir
Write-Measured 'task credential'    $TaskCredential.UserName

if (-not (Test-Path -LiteralPath $MonitorPath)) { throw ('Monitor not found at ' + $MonitorPath) }
$MonitorPath = (Resolve-Path -LiteralPath $MonitorPath).Path

# The principal the deny will name. It is THIS account on purpose: it is the only
# one already proven to arrive over WinRM with an unfiltered admin token. A local
# account would be filtered by UAC on a network logon (EnableLUA is 1 here) and
# would then fail for lack of elevation rather than for policy - the wrong reason,
# and one that looks identical in the output.
$sid = ([Security.Principal.NTAccount]$me).Translate([Security.Principal.SecurityIdentifier]).Value
Write-Measured 'deny will name'     ('{0}  ({1})' -f $me, $sid)

New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

# ---------------------------------------------------------------- baseline ----
$baselineSddl = (Get-Acl -LiteralPath $tasksDir).Sddl
$baselineFile = Join-Path $WorkRoot 'baseline-tasks-dacl.sddl'
Set-Content -LiteralPath $baselineFile -Value $baselineSddl -Encoding ASCII -NoNewline

Write-Head 'Baseline'
Write-Host ('  ' + $baselineSddl) -ForegroundColor DarkGray
Write-Measured 'saved to' $baselineFile

# ------------------------------------------------------------ the two levers --
function Add-DenyAce {
    # CreateFiles + CreateDirectories ONLY. Not ChangePermissions, not TakeOwnership,
    # not Delete. That asymmetry is what guarantees Remove-DenyAce can still run
    # after this has taken effect.
    $acl  = Get-Acl -LiteralPath $tasksDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $me,
                [System.Security.AccessControl.FileSystemRights]'CreateFiles, CreateDirectories',
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Deny)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $tasksDir -AclObject $acl
}

function Remove-DenyAce {
    $acl = Get-Acl -LiteralPath $tasksDir
    $gone = 0
    foreach ($a in @($acl.Access)) {
        if ($a.AccessControlType -eq 'Deny' -and "$($a.IdentityReference)" -eq $me) {
            [void]$acl.RemoveAccessRuleSpecific($a); $gone++
        }
    }
    if ($gone) { Set-Acl -LiteralPath $tasksDir -AclObject $acl }
    return $gone
}

function Get-AceSet {
    # The DACL as a SORTED SET of ACE strings.
    #
    # This exists because the first version of F3 compared whole SDDL strings and
    # failed on a box that was already clean. Set-Acl CANONICALISES the DACL when it
    # rewrites it, so removing a deny ACE and putting the rest back can transpose
    # adjacent allow ACEs - measured on w25-ex01, where (A;CI;FA;;;SY) and
    # (A;OI;0x1f019f;;;SY) swapped, as did the matching pair for BA. Eight ACEs in,
    # eight ACEs out, every mask and flag identical, and a string comparison still
    # said the box had changed.
    #
    # Allow-ACE order does not affect an access check; only deny-before-allow does.
    # So the set is the honest comparison and the string is not. The string is still
    # checked afterwards, but as "did the exact restore work", not as "is the box
    # safe" - two questions that the first version ran together.
    param([string]$Sddl)
    if ($Sddl -match 'D:(?:[A-Z]*)(?<body>\(.*)$') {
        return @($Matches['body'] -split '(?<=\))(?=\()' | Sort-Object)
    }
    return @()
}

function Restore-BaselineDacl {
    # Order included, so the box ends byte-identical to how it was found rather than
    # merely equivalent to it.
    $acl = Get-Acl -LiteralPath $tasksDir
    $acl.SetSecurityDescriptorSddlForm($baselineSddl, [System.Security.AccessControl.AccessControlSections]::Access)
    Set-Acl -LiteralPath $tasksDir -AclObject $acl
}

function Get-NativeSd {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    # 4 = DACL_SECURITY_INFORMATION
    return $svc.GetFolder('\').GetSecurityDescriptor(4)
}

function Set-NativeSd {
    param([string]$Sddl)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $svc.GetFolder('\').SetSecurityDescriptor($Sddl, 0)
}

# ------------------------------------------------- how an attempt is measured --
function Invoke-RawRegistration {
    # The ground truth: what Windows itself says, with nothing of ours in the way.
    # Deliberately separate from the monitor run - if the two disagree, the monitor
    # is reshaping the error and that is exactly what this gate is here to catch.
    $out = [ordered]@{ Threw = $false; Type = ''; Message = ''; HResult = ''; Category = '' }
    try {
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -Command exit 0'
        $t = New-ScheduledTaskTrigger -Once -At ([datetime]::Now.AddYears(1))
        Register-ScheduledTask -TaskName $probeTask -Action $a -Trigger $t `
            -User $TaskCredential.UserName -Password $TaskCredential.GetNetworkCredential().Password `
            -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $out.Threw    = $true
        $out.Type     = $_.Exception.GetType().FullName
        $out.Message  = $_.Exception.Message
        $out.HResult  = ('0x{0:X8}' -f $_.Exception.HResult)
        $out.Category = "$($_.CategoryInfo.Category)"
    }
    finally {
        Unregister-ScheduledTask -TaskName $probeTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    return [pscustomobject]$out
}

function Invoke-MonitorRegistration {
    # IN-PROCESS. -TaskCredential is a PSCredential and cannot cross a process
    # boundary; the monitor documents that at :2413-2420. $LASTEXITCODE carries the
    # code that `exit` set, and the run log is read back as corroboration rather
    # than as the primary measurement.
    param([string]$Tag)
    $outDir = Join-Path $WorkRoot $Tag
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $global:LASTEXITCODE = 0
    $console = & {
        & $MonitorPath -RegisterScheduledTask -TaskName $TaskName -Scope Local `
            -TaskCredential $TaskCredential -OutputPath $outDir -NoElevate 2>&1 |
            ForEach-Object { "$_" }
    }
    $code = $LASTEXITCODE

    $log = Get-ChildItem -LiteralPath $outDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $logText = if ($log) { Get-Content -LiteralPath $log.FullName -Raw } else { '' }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode   = $code
        Console    = ($console -join "`n")
        LogText    = $logText
        # The claim under test, verbatim from :2283.
        SaysPolicy = ($logText -match 'policy prevents local administrators from creating scheduled tasks') -or
                     ($console -join "`n") -match 'policy blocking local admins'
    }
}

function Show-Attempt {
    param($Tag, $Raw, $Mon)
    Write-Measured 'raw Register-ScheduledTask threw' $Raw.Threw
    if ($Raw.Threw) {
        Write-Measured '  exception type' $Raw.Type
        Write-Measured '  HRESULT'        $Raw.HResult
        Write-Measured '  category'       $Raw.Category
        Write-Host     ('        message: ' + $Raw.Message) -ForegroundColor DarkGray
    }
    Write-Measured 'monitor exit code' $Mon.ExitCode
    Write-Measured 'monitor named it policy' $Mon.SaysPolicy
    $script:results[$Tag] = [pscustomobject]@{
        RawThrew = $Raw.Threw; RawType = $Raw.Type; RawHResult = $Raw.HResult
        RawMessage = $Raw.Message; MonExit = $Mon.ExitCode; MonSaysPolicy = $Mon.SaysPolicy
        MonLog = $Mon.LogText
    }
}

$denyApplied       = $false
$nativeApplied     = $false
$nativeBaseline    = $null
$deadManRegistered = $false

try {
    # ------------------------------------------------------------- F0 control --
    Write-Head 'F0 - control: registration works with nothing in the way'
    Write-Host '  Without this, an Access Denied later proves only that something failed.' -ForegroundColor DarkGray

    $raw0 = Invoke-RawRegistration
    $mon0 = Invoke-MonitorRegistration -Tag 'f0'
    Show-Attempt 'F0' $raw0 $mon0
    Write-Check 'F0 raw registration SUCCEEDS'      (-not $raw0.Threw) $raw0.Message
    Write-Check 'F0 monitor registration exits 0'   ($mon0.ExitCode -eq 0) ('exit ' + $mon0.ExitCode)

    if ($raw0.Threw -or $mon0.ExitCode -ne 0) {
        throw 'The control failed. This account cannot register a task even unrestricted, so nothing below would be attributable to the ACL. Stopping before anything is changed.'
    }

    # ------------------------------------------------------- dead-man's switch --
    # BEFORE the deny, not after. Once the deny is on, this account cannot create
    # this task, and a self-heal that could not be registered is not a safety net.
    Write-Head "Dead-man's switch"
    $healScript = Join-Path $WorkRoot 'self-heal.ps1'
    @(
        '$ErrorActionPreference = ''Continue'''
        ('$d = ' + ('"' + $tasksDir + '"'))
        ('$b = Get-Content -LiteralPath ' + ('"' + $baselineFile + '"') + ' -Raw')
        '$acl = Get-Acl -LiteralPath $d'
        '$acl.SetSecurityDescriptorSddlForm($b.Trim(), [System.Security.AccessControl.AccessControlSections]::Access)'
        'Set-Acl -LiteralPath $d -AclObject $acl'
        ('Add-Content -LiteralPath ' + ('"' + (Join-Path $WorkRoot 'self-heal.log') + '"') + ' -Value ("fired {0}" -f (Get-Date))')
    ) | Set-Content -LiteralPath $healScript -Encoding UTF8

    $healAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                       -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $healScript)
    $healTrigger = New-ScheduledTaskTrigger -Once -At ([datetime]::Now.AddMinutes($DeadManMinutes))
    Register-ScheduledTask -TaskName $deadManTask -Action $healAction -Trigger $healTrigger `
        -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
    $deadManRegistered = $true
    Write-Check 'self-heal task registered as SYSTEM' $true ('fires in {0} min, restores the baseline DACL' -f $DeadManMinutes)

    # ---------------------------------------------- F1 - the filesystem lever --
    Write-Head 'F1 - deny create on the Tasks folder, for this principal only'
    Add-DenyAce
    $denyApplied = $true
    $afterSddl = (Get-Acl -LiteralPath $tasksDir).Sddl
    Write-Check 'deny ACE is present' ($afterSddl -ne $baselineSddl) $afterSddl

    $raw1 = Invoke-RawRegistration
    $mon1 = Invoke-MonitorRegistration -Tag 'f1'
    Show-Attempt 'F1' $raw1 $mon1

    $f1Blocked = $raw1.Threw
    Write-Check 'F1 actually blocked the registration' $f1Blocked `
        $(if ($f1Blocked) { 'the filesystem ACL is a sufficient lever' }
          else { 'NOT BLOCKED - the Task Scheduler service did not honour the file ACL for this caller. F2 is the lever that matters here.' })

    if ($f1Blocked) {
        Write-Check 'F1 monitor exits 7' ($mon1.ExitCode -eq 7) ('exit ' + $mon1.ExitCode)
        Write-Check 'F1 monitor names it as policy' $mon1.SaysPolicy `
            $(if ($mon1.SaysPolicy) { 'the shipped diagnosis fired on a real refusal' }
              else { 'THE DIAGNOSIS DID NOT FIRE. The regex at :2282 does not match what Windows really said.' })
    }

    [void](Remove-DenyAce)
    $denyApplied = $false

    # -------------------------------------------------- F2 - the native lever --
    # RUN REGARDLESS of whether F1 blocked. The first version of this gate escalated
    # to the native lever ONLY when the filesystem one failed to block, on the
    # reasoning that if the blunt lever works the native one adds nothing. That was
    # optimising for the wrong question. "Did something block" is not what this gate
    # is for - "what does each real mechanism actually SAY" is, because the shipped
    # diagnosis is a regex against that text. Two levers can both block and still
    # produce different messages, and the native one is the likelier of the two in a
    # managed estate, so skipping it is skipping the more representative case.
    if (-not $SkipNativeLever) {
        Write-Head "F2 - deny via the Task Scheduler's own folder security descriptor"
        Write-Host '  The native mechanism, and the likelier one in a managed estate.' -ForegroundColor DarkGray

        $nativeBaseline = Get-NativeSd
        Set-Content -LiteralPath (Join-Path $WorkRoot 'baseline-native.sddl') -Value $nativeBaseline -Encoding ASCII -NoNewline
        Write-Host ('  baseline: ' + $nativeBaseline) -ForegroundColor DarkGray

        # Deny ACEs must precede allow ACEs in a DACL, so this goes in immediately
        # after the D: and any flag letters. 0x2 is create-child, the task-creation
        # right - WRITE_DAC (0x40000) is deliberately NOT denied, so this is
        # removable afterwards by the same principal.
        $denyAce = '(D;;0x2;;;{0})' -f $sid
        if ($nativeBaseline -match '(?<pre>.*D:(?:[A-Z]*))(?<rest>\(.*)') {
            $newSd = $Matches['pre'] + $denyAce + $Matches['rest']
        }
        else {
            throw ('Could not find a DACL to modify in: ' + $nativeBaseline)
        }

        Set-NativeSd -Sddl $newSd
        $nativeApplied = $true
        Write-Check 'native deny ACE applied' ((Get-NativeSd) -ne $nativeBaseline) $newSd

        $raw2 = Invoke-RawRegistration
        $mon2 = Invoke-MonitorRegistration -Tag 'f2'
        Show-Attempt 'F2' $raw2 $mon2

        Write-Check 'F2 actually blocked the registration' $raw2.Threw $raw2.Message
        if ($raw2.Threw) {
            Write-Check 'F2 monitor exits 7' ($mon2.ExitCode -eq 7) ('exit ' + $mon2.ExitCode)
            Write-Check 'F2 monitor names it as policy' $mon2.SaysPolicy `
                $(if ($mon2.SaysPolicy) { 'the shipped diagnosis fired on a real refusal' }
                  else { 'THE DIAGNOSIS DID NOT FIRE on the native lever.' })
        }

        Set-NativeSd -Sddl $nativeBaseline
        $nativeApplied = $false
        Write-Check 'native SD restored' ((Get-NativeSd) -eq $nativeBaseline) (Get-NativeSd)
    }
    elseif ($SkipNativeLever) {
        Write-Head 'F2 - SKIPPED (-SkipNativeLever)'
    }

    # ----------------------------------------------------- F3/F4 - the revert --
    Write-Head 'F3 - the revert is verified, not assumed'

    # Two questions, asked separately, because the first version ran them together
    # and got a red result on a box that was already safe.
    $preRestore = (Get-Acl -LiteralPath $tasksDir).Sddl
    $baseSet    = Get-AceSet $baselineSddl
    $nowSet     = Get-AceSet $preRestore
    $onlyBase   = @(Compare-Object $baseSet $nowSet | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })
    $onlyNow    = @(Compare-Object $baseSet $nowSet | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })

    Write-Check ('no permission differs from the baseline ({0} ACEs)' -f $baseSet.Count) `
        (($onlyBase.Count -eq 0) -and ($onlyNow.Count -eq 0)) `
        $(if ($onlyBase.Count -or $onlyNow.Count) { 'only-in-baseline: ' + ($onlyBase -join ' ') + '  |  only-now: ' + ($onlyNow -join ' ') }
          else { 'ACE sets identical - any ordering difference is canonicalisation, not a permission change' })

    # Now make it byte-exact as well, and check THAT separately. This is the weaker
    # claim of the two and it is reported as such: it proves the restore ran, not
    # that the box was ever unsafe.
    Restore-BaselineDacl
    $finalSddl = (Get-Acl -LiteralPath $tasksDir).Sddl
    Write-Check 'DACL is byte-identical to the baseline string' ($finalSddl -eq $baselineSddl) $finalSddl

    Write-Head 'F4 - control again: registration works once more'
    Write-Host '  This is what turns "we removed the ACE" into "the box is as we found it".' -ForegroundColor DarkGray
    $raw4 = Invoke-RawRegistration
    $mon4 = Invoke-MonitorRegistration -Tag 'f4'
    Show-Attempt 'F4' $raw4 $mon4
    Write-Check 'F4 raw registration SUCCEEDS again'    (-not $raw4.Threw) $raw4.Message
    Write-Check 'F4 monitor registration exits 0 again' ($mon4.ExitCode -eq 0) ('exit ' + $mon4.ExitCode)
}
catch {
    Write-Check 'Gate F ran to completion' $false $_.Exception.Message
}
finally {
    # Order matters here too: lift the denies FIRST, then remove the safety net that
    # exists to lift them.
    if ($denyApplied) {
        try { [void](Remove-DenyAce); Write-Host '  (finally) deny ACE removed' -ForegroundColor Yellow }
        catch { Write-Host ('  (finally) COULD NOT REMOVE DENY ACE: ' + $_.Exception.Message) -ForegroundColor Red }
    }
    if ($nativeApplied -and $nativeBaseline) {
        try { Set-NativeSd -Sddl $nativeBaseline; Write-Host '  (finally) native SD restored' -ForegroundColor Yellow }
        catch { Write-Host ('  (finally) COULD NOT RESTORE NATIVE SD: ' + $_.Exception.Message) -ForegroundColor Red }
    }

    $endSddl = try { (Get-Acl -LiteralPath $tasksDir).Sddl } catch { 'UNREADABLE' }
    # Semantic, not textual - same reason F3 is. A run that ends with the right
    # permissions in a canonicalised order is a clean box, and leaving the safety
    # net armed on that basis is a false alarm that puts a stray SYSTEM task on the
    # estate. Measured: the first run of this gate did exactly that.
    $endSet  = if ($endSddl -eq 'UNREADABLE') { @() } else { Get-AceSet $endSddl }
    $baseSetF = Get-AceSet $baselineSddl
    $clean   = ($endSddl -ne 'UNREADABLE') -and
               (@(Compare-Object $baseSetF $endSet).Count -eq 0)

    if ($deadManRegistered) {
        if ($clean) {
            Unregister-ScheduledTask -TaskName $deadManTask -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host '  self-heal task removed - the DACL is already back to baseline' -ForegroundColor DarkGray
        }
        else {
            Write-Host '  SELF-HEAL TASK LEFT IN PLACE ON PURPOSE. The DACL does not match the' -ForegroundColor Red
            Write-Host ('  baseline, so the net stays up. It fires within {0} minutes.' -f $DeadManMinutes) -ForegroundColor Red
        }
    }
    Unregister-ScheduledTask -TaskName $probeTask -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName  -Confirm:$false -ErrorAction SilentlyContinue

    Write-Head 'Gate F - what was measured'
    foreach ($k in $script:results.Keys) {
        $r = $script:results[$k]
        Write-Host ('  {0}  raw-threw={1,-5} exit={2,-3} names-policy={3,-5} {4}' -f `
                    $k.PadRight(3), $r.RawThrew, $r.MonExit, $r.MonSaysPolicy, $r.RawHResult)
        if ($r.RawMessage) { Write-Host ('       ' + $r.RawMessage) -ForegroundColor DarkGray }
    }

    Write-Host ''
    Write-Host ('  Tasks folder DACL at exit: {0}' -f $(if ($clean) { 'BASELINE - clean' } else { 'NOT BASELINE - see above' })) `
        -ForegroundColor $(if ($clean) { 'Green' } else { 'Red' })
    Write-Host ''
    Write-Host ('GATE F: {0}' -f $(if ($script:fail) { "$script:fail check(s) failed" } else { 'all checks passed' })) `
        -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
    Write-Host ''
}
