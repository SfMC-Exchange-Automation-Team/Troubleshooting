#Requires -Version 5.1
<#
.SYNOPSIS
    Checks whether the how-to video still matches the tool it describes.

.DESCRIPTION
    A video is a snapshot. The tool keeps moving, and when they diverge nothing announces it - the
    video plays perfectly while teaching something that is no longer true. That is worse than having
    no video, because it is confidently wrong.

    This turns that risk into a check. It reads the claims out of New-ExoQueueHowToVideo.ps1 rather
    than restating them, so the check cannot itself go stale relative to the video, and tests each
    against the current Get-ExoQueue.ps1:

      1. Version      - the slide footer is generated from the tool, so it must match.
      2. Parameters   - every -Parameter the slides or narration name must still exist.
      3. Properties   - every result property the -PassThru scene displays must still be returned.
      4. Console text - the phrases the screenshots show must still be produced by a real run.
      5. Screenshots  - the images the scenes reference must still exist.

    Nothing here touches a tenant.

.PARAMETER VideoScript
    The video builder to read claims from.

.PARAMETER ToolScript
    The Get-ExoQueue.ps1 to check them against.

.EXAMPLE
    .\Test-ExoQueueVideoDrift.ps1

.NOTES
    Exit code is the number of drifted claims, so this can gate a release.
#>
[CmdletBinding()]
param(
    [string]$VideoScript,
    [string]$ToolScript,
    [string]$ShotDir
)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$parent = Split-Path -Parent $root

if (-not $ToolScript) {
    $ToolScript = @(
        (Join-Path $root 'Get-ExoQueue.ps1')
        (Join-Path $parent 'Get-ExoQueue.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ToolScript -or -not (Test-Path -LiteralPath $ToolScript)) {
    throw "Get-ExoQueue.ps1 not found beside this script or in the parent folder."
}

# The video BUILDER is the richest source of claims - it holds the on-screen bullets as well as the
# narration - but it is authoring tooling and is deliberately not published to the repo, because it
# depends on a lab tenant and a local toolchain. So fall back to the TRANSCRIPT, which ships in
# docs/ and carries the narration and the on-screen code blocks. That covers the two things most
# likely to drift, console wording and property names; only the bullet text is out of reach.
if (-not $VideoScript) {
    $VideoScript = @(
        (Join-Path $root 'New-ExoQueueHowToVideo.ps1')
        (Join-Path $parent 'New-ExoQueueHowToVideo.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

$claimSource = 'builder'
if (-not $VideoScript -or -not (Test-Path -LiteralPath $VideoScript)) {
    $VideoScript = @(
        (Join-Path $parent 'docs\Get-ExoQueue-HowTo.transcript.md')
        (Join-Path $root 'docs\Get-ExoQueue-HowTo.transcript.md')
        (Join-Path $root 'Get-ExoQueue-HowTo.transcript.md')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $claimSource = 'transcript'
}
if (-not $VideoScript) {
    throw "Neither New-ExoQueueHowToVideo.ps1 nor the video transcript could be found; nothing to check the tool against."
}

if (-not $ShotDir) {
    $ShotDir = @(
        (Join-Path $parent 'docs\images')
        (Join-Path $root 'docs\images')
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ExoQueue-HowTo-Shots')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

Write-Host ("tool   : {0}" -f $ToolScript) -ForegroundColor DarkGray
Write-Host ("claims : {0} ({1})" -f $VideoScript, $claimSource) -ForegroundColor DarkGray
Write-Host ("shots  : {0}" -f $ShotDir) -ForegroundColor DarkGray

$findings = [System.Collections.Generic.List[string]]::new()
$checks   = 0

function Test-Claim {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $script:checks++
    if ($Ok) { Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green }
    else {
        Write-Host ("  DRIFT {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkYellow }
        $script:findings.Add("$Name - $Detail")
    }
}

# ---------------------------------------------------------------------------------------------
# Load the tool behind stubs so a real run can be exercised without a tenant.
# ---------------------------------------------------------------------------------------------
$global:ExoRows = @()

function global:Get-MessageTraceV2 {
    [CmdletBinding()]
    param([datetime]$StartDate, [datetime]$EndDate, [object]$Status, [int]$ResultSize,
          [string]$StartingRecipientAddress, [object]$RecipientAddress, [object]$SenderAddress)
    process {
        if ($StartingRecipientAddress) { return @() }
        return @($global:ExoRows)
    }
}
function global:Get-ConnectionInformation {
    param([object]$ErrorAction)
    [pscustomobject]@{ Id = 1; State = 'Connected'; TokenStatus = 'Active'
                       UserPrincipalName = 'admin@contoso.onmicrosoft.com'; Organization = 'contoso.onmicrosoft.com' }
}
function global:Connect-ExchangeOnline { param([object]$ShowProgress, [object]$ErrorAction) throw 'must not connect' }

. $ToolScript

$videoText = [IO.File]::ReadAllText($VideoScript, [System.Text.Encoding]::UTF8)

Write-Host ''
Write-Host '1. Version on the slide footer' -ForegroundColor Cyan
$toolVersion = (Select-String -Path $ToolScript -Pattern "ExoQueueVersion\s*=\s*'([\d.]+)'").Matches[0].Groups[1].Value
if ($claimSource -eq 'builder') {
    $hardcoded = [regex]::Matches($videoText, "Get-ExoQueue (\d+\.\d+\.\d+)\s+-\s+approximation")
    if ($hardcoded.Count -gt 0) {
        Test-Claim -Name "footer version is generated, not typed" -Ok $false `
            -Detail ("slide footer hardcodes {0}; the tool is {1}" -f $hardcoded[0].Groups[1].Value, $toolVersion)
    }
    else {
        Test-Claim -Name "footer version is generated from the tool" -Ok ($videoText -match '\$script:ToolVersion')
    }
}
else {
    Write-Host "  SKIP  footer version (needs the builder, not in this folder)" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '2. Parameters the video names still exist' -ForegroundColor Cyan
$cmd = Get-Command Get-ExoQueue
$real = $cmd.Parameters.Keys

if ($claimSource -eq 'builder') {
    # Scoped to the $scenes block via the AST, not scraped from the whole file. A plain regex over
    # the source matched -AssemblyName, -Encoding, -LiteralPath and every other parameter of the
    # builder's OWN PowerShell, and reported 21 false positives. Only the strings a viewer reads or
    # hears count, so take the string literals inside the $scenes assignment and nothing else.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($VideoScript, [ref]$null, [ref]$null)
    $scenesAssign = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$scenes'
        }, $true) | Select-Object -First 1

    if (-not $scenesAssign) { throw "Could not locate the `$scenes block in $VideoScript." }

    $sceneText = ($scenesAssign.Right.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { $_.Value }) -join "`n"
}
else {
    # The transcript is already only viewer-facing text, so no scoping is needed.
    $sceneText = $videoText
}

$mentioned = [regex]::Matches($sceneText, '(?<![\w-])-([A-Z][A-Za-z]{2,})') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
# Parameters of OTHER cmdlets the slides legitimately show.
$foreign = @('UserPrincipalName', 'StartDate', 'EndDate', 'StartingRecipientAddress')
$mentioned = @($mentioned | Where-Object { $_ -notin $foreign })
$missing = @($mentioned | Where-Object { $_ -notin $real })
Test-Claim -Name ("all {0} parameters named on screen or in narration exist" -f $mentioned.Count) `
    -Ok ($missing.Count -eq 0) -Detail ("not on Get-ExoQueue: " + ($missing -join ', '))

Write-Host ''
Write-Host '3. Result properties the -PassThru scene shows' -ForegroundColor Cyan
$now = [datetime]::UtcNow
$global:ExoRows = 1..4 | ForEach-Object {
    [pscustomobject]@{
        Organization = 'contoso.onmicrosoft.com'; MessageId = "<m$_@contoso.com>"
        Received = $now.AddMinutes(-$_ * 30); SenderAddress = 's@contoso.com'
        RecipientAddress = "r$_@fabrikam.com"; Status = 'Pending'; Size = 1024; Subject = 'x'
    }
}
$tmp = Join-Path $env:TEMP ('exoq-drift-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    $result = Get-ExoQueue -Force -Quiet -PassThru -Output None -OutputPath $tmp `
        -AgeHours 6 -Status Pending -ThrottleDelayMilliseconds 0 -WarningAction SilentlyContinue

    # Exactly what scene 7's screenshot lists.
    $shown = 'MessageCount', 'RecipientRowCount', 'Truncated', 'TruncationReason', 'PagesQueried', 'EffectivePageSize'
    $absent = @($shown | Where-Object { $null -eq $result.PSObject.Properties[$_] })
    Test-Claim -Name ("all {0} displayed properties are still returned" -f $shown.Count) -Ok ($absent.Count -eq 0) `
        -Detail ("no longer on the result object: " + ($absent -join ', '))

    Write-Host ''
    Write-Host '4. Console phrases the screenshots show' -ForegroundColor Cyan
    $text = (Get-ExoQueue -Force -Output None -OutputPath $tmp -AgeHours 6 -Status Pending `
                -ThrottleDelayMilliseconds 0 -WarningAction SilentlyContinue 6>&1 |
             ForEach-Object {
                if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"

    # Each of these is legible in one of the five screenshots, so if the wording moves the image is
    # out of date even though the video still plays.
    $phrases = @(
        'DISCLAIMER'
        'Number of messages in the queue'
        'Queue age: oldest'
        'Queued by destination domain'
        'Recipient domain, not the actual next hop'
        'Files written:'
        'Trend log'
    )
    foreach ($p in $phrases) {
        Test-Claim -Name ("console still says '{0}'" -f $p) -Ok ($text -like "*$p*") -Detail 'wording changed; screenshots are stale'
    }

    # The empty-result explanation is its own scene.
    $global:ExoRows = @()
    $emptyText = (Get-ExoQueue -Force -Output None -OutputPath $tmp -AgeMinutes 30 `
                    -ThrottleDelayMilliseconds 0 -WarningAction SilentlyContinue 6>&1 |
                  ForEach-Object {
                    if ($_ -is [System.Management.Automation.InformationRecord]) { [string]$_.MessageData } else { [string]$_ } }) -join "`n"
    Test-Claim -Name "empty result still explains itself" `
        -Ok ($emptyText -like '*filter result, not necessarily an empty tenant*') `
        -Detail 'scene 8 shows this sentence'
    Test-Claim -Name "empty result still names the Pending-only default" `
        -Ok ($emptyText -like '*defaults to Pending only*') -Detail 'scene 8 shows this sentence'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '5. Screenshots the scenes reference' -ForegroundColor Cyan
# The builder names shots as  Shot = 'x.png' ; the transcript names them as  Screenshot: `x.png`
$shots = @(
    [regex]::Matches($videoText, "Shot\s*=\s*'([^']+\.png)'") | ForEach-Object { $_.Groups[1].Value }
    [regex]::Matches($videoText, 'Screenshot: `([^`]+\.png)`')  | ForEach-Object { $_.Groups[1].Value }
) | Sort-Object -Unique
foreach ($s in $shots) {
    Test-Claim -Name ("{0} exists" -f $s) -Ok (Test-Path (Join-Path $ShotDir $s)) -Detail "expected under $ShotDir"
}

Write-Host ''
Write-Host ('{0} checks, {1} drifted' -f $checks, $findings.Count) -ForegroundColor $(if ($findings.Count) { 'Red' } else { 'Green' })
if ($findings.Count -gt 0) {
    Write-Host ''
    Write-Host 'The video no longer matches the tool. Regenerate the screenshots, then the video:' -ForegroundColor Yellow
    Write-Host '  .\New-ExoQueueLabScreenshot.ps1' -ForegroundColor Cyan
    Write-Host '  .\New-ExoQueueHowToVideo.ps1' -ForegroundColor Cyan
}

'Get-MessageTraceV2', 'Get-ConnectionInformation', 'Connect-ExchangeOnline' |
    ForEach-Object { Remove-Item -Path "Function:$_" -ErrorAction SilentlyContinue }

exit ([Math]::Min($findings.Count, 255))
