#Requires -Version 5.1
<#
.SYNOPSIS
Prepares verified Korean Rules installation files and a portable runtime package.
.DESCRIPTION
Supply either the exact Microsoft SQL Express package or the two previously
extracted rule files. -Download explicitly authorizes a 749 MB Microsoft download.
SQL media is extracted only; SQL Setup and MSI product installation are never run.
A management workstation remains recommended to avoid extraction load on Exchange.
ManagementWorkstationConfirmed is optional and retained for older command lines.
This prepares files only. Use Get-KoreanRulesState to inspect Exchange and
Set-KoreanRulesState to apply the workaround. The returned PayloadDirectory
identifies the prepared files; the original source folder is not populated.
#>
[CmdletBinding(DefaultParameterSetName = 'ExistingMedia')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ExistingMedia')][string]$SqlPackagePath,
    [Parameter(Mandatory, ParameterSetName = 'Download')][switch]$Download,
    [Parameter(Mandatory, ParameterSetName = 'ExistingRules')][string]$RuleSourceDirectory,
    [ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [switch]$ManagementWorkstationConfirmed,
    [string]$WorkRoot = 'C:\Temp\KoreanRules-Build'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'KoreanRules.psm1') -Force
Assert-KBAdministrator
if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup') {
    Write-Warning 'Exchange installation detected. Building here uses local disk and CPU; a management workstation is recommended. This builder only extracts and packages files; it does not apply the workaround or restart Exchange.'
}
$spec = Get-KBSpecification
if (-not $PSBoundParameters.ContainsKey('OutputDirectory')) {
    $OutputDirectory = Join-Path 'C:\Temp\KoreanRules-Ready' ([guid]::NewGuid().ToString('N'))
}
$output = Assert-KBLocalWritePath $OutputDirectory
$work = Assert-KBLocalWritePath $WorkRoot
if (Test-Path -LiteralPath $output) { throw "Output directory already exists; use a new directory: $output" }
$null = New-Item -Path $work -ItemType Directory -Force
$runDirectory = Join-Path $work ([guid]::NewGuid().ToString('N'))
$null = New-Item -Path $runDirectory -ItemType Directory

if ($PSCmdlet.ParameterSetName -ne 'ExistingRules') {
    if ($Download) {
        $SqlPackagePath = Join-Path $runDirectory $spec.SqlPackage.Name
        $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $spec.SqlPackage.Url -OutFile $SqlPackagePath -UseBasicParsing
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
        }
    }
    $SqlPackagePath = (Get-Item -LiteralPath $SqlPackagePath).FullName
    if ($SqlPackagePath -notmatch '^[A-Za-z]:\\' -or $SqlPackagePath.Contains('"')) {
        throw 'Copy the SQL package to a local directory before extraction.'
    }
    Assert-KBIdentity -Path $SqlPackagePath -Expected $spec.SqlPackage
    $signature = Get-AuthenticodeSignature -LiteralPath $SqlPackagePath
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw 'The package must have a valid Microsoft Authenticode signature. Stop; do not extract.'
    }
    $media = Join-Path $runDirectory 'Media'
    $files = Join-Path $runDirectory 'Files'
    $process = Start-Process -FilePath $SqlPackagePath -ArgumentList ('/q /x:"{0}"' -f $media) -Wait -PassThru
    $msi = Join-Path $media 'x64\Setup\SQL_FULLTEXT.MSI'
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $msi -PathType Leaf)) {
        throw "SQL extract-only failed (exit $($process.ExitCode)). Keep $runDirectory for troubleshooting."
    }
    $log = Join-Path $runDirectory 'extract.log'
    $arguments = '/a "{0}" TARGETDIR="{1}" /qn /norestart /L*V "{2}"' -f $msi, $files, $log
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "MSI administrative extraction failed (exit $($process.ExitCode)). Keep $log for troubleshooting."
    }
    $RuleSourceDirectory = Join-Path $files 'Program Files\Microsoft SQL Server\MSSQL.X\MSSQL\Binn\ftcomponents\wordbreakers'
}
Assert-KBPayload -Directory $RuleSourceDirectory
$null = New-Item -Path $output -ItemType Directory
$package = Join-Path $output 'Exchange-KoreanRules'
$payload = Join-Path $package 'payload'
$null = New-Item -Path $payload -ItemType Directory -Force
foreach ($name in @('KoreanRules.psd1', 'KoreanRules.psm1', 'Install-KoreanRules.ps1', 'Get-KoreanRulesState.ps1', 'Set-KoreanRulesState.ps1', 'README.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $package $name)
}
$private = Join-Path $package 'private'
$null = New-Item -Path $private -ItemType Directory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'private\Invoke-KoreanRulesOperation.ps1') -Destination $private
$examples = Join-Path $package 'examples'
$null = New-Item -Path $examples -ItemType Directory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'examples\servers.csv') -Destination (Join-Path $examples 'servers.csv')
$docs = Join-Path $package 'docs'
$null = New-Item -Path $docs -ItemType Directory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\Reporting-and-Splunk.md') -Destination (Join-Path $docs 'Reporting-and-Splunk.md')
foreach ($rule in $spec.Rules) {
    Copy-Item -LiteralPath (Join-Path $RuleSourceDirectory $rule.Name) -Destination (Join-Path $payload $rule.Name)
}
Assert-KBPayload -Directory $payload
$manifest = @(Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($package.Length + 1)
})
$manifest | Set-Content -LiteralPath (Join-Path $package 'SHA256SUMS.txt') -Encoding ASCII
$zip = Join-Path $output ('Exchange-KoreanRules-{0}-deploy.zip' -f $spec.PackageVersion)
Compress-Archive -LiteralPath $package -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
"$zipHash  $([IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII
Write-Host "Korean Rules installation files prepared: $payload" -ForegroundColor Green
Write-Host 'No Exchange installation files were changed and no services were restarted.'
Write-Host 'Use the returned PayloadDirectory with Set-KoreanRulesState, or run the state scripts from ExpandedPackage.'
[pscustomobject]@{
    Package = $zip
    SHA256 = $zipHash
    ExpandedPackage = $package
    PayloadDirectory = $payload
    ExtractionArtifacts = $runDirectory
    Note = 'No SQL installation performed. Retain extraction logs as needed, then delete the build work directory manually.'
}
