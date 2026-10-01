#Requires -Version 5.1
<#
.SYNOPSIS
Prepares verified Korean Rules files without installing SQL or modifying Exchange.
.DESCRIPTION
Run without arguments to verify the bundled payload, or show examples if absent.
No implicit downloads are performed. Position 0 is an
existing EXE or source folder; position 1 is an optional NEW output directory.
A source folder must directly contain the expected EXE or the rule BIN files.
Download requires explicit -Download. Paired pasted path quotes are accepted.
Default failures print one concise message and return exit 1; -ErrorAction Stop
rethrows the error for callers that need a catchable PowerShell error record.
ManagementWorkstationConfirmed is an optional compatibility switch, not a gate.
A successful build also prepares the verified payload beside this script, which
Set-KoreanRulesState uses by default. Existing matching files are reused, never
overwritten. A second portable kit/ZIP is created only with -OutputDirectory.
#>
[CmdletBinding(DefaultParameterSetName='ExistingMedia', PositionalBinding=$false)]
param(
    [Parameter(Position=0, ParameterSetName='ExistingMedia')][Alias('Path')][string]$SqlPackagePath,
    [Parameter(Mandatory, ParameterSetName='Download')][switch]$Download,
    [Parameter(Mandatory, ParameterSetName='ExistingRules')][string]$RuleSourceDirectory,
    [Parameter(Position=1)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [switch]$ManagementWorkstationConfirmed,
    [string]$WorkRoot='C:\Temp\KoreanRules-Build'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$runDirectory=$null
try {
    $useBundledPayload = $PSCmdlet.ParameterSetName -eq 'ExistingMedia' -and -not $PSBoundParameters.ContainsKey('SqlPackagePath')
    $adjacentPayload = Join-Path $PSScriptRoot 'payload'
    if ($useBundledPayload -and -not (Test-Path -LiteralPath $adjacentPayload)) {
        if ($PSBoundParameters.ContainsKey('OutputDirectory')) {
            throw 'REQUIRED INSTALLATION FILES MISSING: no bundled payload to export. Use -Download, an existing SQL media path, or -RuleSourceDirectory with -OutputDirectory.'
        }
        Write-Host @'
KOREAN RULES - PREPARE INSTALLATION FILES
No source selected and no bundled payload found. Nothing downloaded, extracted
or changed. Choose ONE:

  .\Install-KoreanRules.ps1 -Download
  .\Install-KoreanRules.ps1 'C:\Temp\SQLEXPR_x64_ENU.exe'
  .\Install-KoreanRules.ps1 'C:\Temp\Folder containing the EXE or BIN files'
  .\Install-KoreanRules.ps1 -RuleSourceDirectory 'C:\Temp\VerifiedRules'

Optional second positional argument: a NEW output directory.
  .\Install-KoreanRules.ps1 'C:\Temp\SQLEXPR_x64_ENU.exe' 'C:\Temp\PreparedRules'

Download is explicit (about 749 MB). An existing folder is an INPUT, not a
download destination. Preparation fills only this kit's adjacent payload folder.
Use -OutputDirectory only when you want an additional portable kit and ZIP.
If payload is already bundled, no arguments verifies it without writing files.
Use elevated 64-bit Windows PowerShell 5.1 to prepare files.
Get-KoreanRulesState inspects servers. Set-KoreanRulesState applies the rules.
'@ -ForegroundColor Cyan
        exit 0
    }
    if ($PSCmdlet.ParameterSetName -eq 'Download' -and -not $Download) {
        throw '-Download:$false does not select a source. Supply -Download, an existing EXE/folder, or -RuleSourceDirectory.'
    }
    Import-Module (Join-Path $PSScriptRoot 'KoreanRules.psm1') -Force
    $spec=Get-KBSpecification
    $sourceKind='Media'
    if ($PSCmdlet.ParameterSetName -ne 'Download') {
        $inputParameters=@{Path=$SqlPackagePath}
        if ($PSCmdlet.ParameterSetName -eq 'ExistingRules') {
            $inputParameters.Path=$RuleSourceDirectory
            $inputParameters.RulesOnly=$true
        } elseif ($useBundledPayload) {
            $inputParameters.Path=$adjacentPayload
            $inputParameters.RulesOnly=$true
        }
        $inputSource=Resolve-KBPreparationInput @inputParameters
        $sourceKind=$inputSource.Kind
        if ($sourceKind -eq 'Rules') {
            $RuleSourceDirectory=$inputSource.Path
            Assert-KBPayload -Directory $RuleSourceDirectory
        } else { $SqlPackagePath=$inputSource.Path }
    }
    $output=$null
    if ($PSBoundParameters.ContainsKey('OutputDirectory')) {
        $output=Assert-KBLocalWritePath (ConvertTo-KBInputPath $OutputDirectory)
        if (Test-Path -LiteralPath $output) { throw "Output directory already exists: $output. Choose a NEW -OutputDirectory, or omit it to prepare only this kit. Existing files were not replaced." }
    }
    if (-not $useBundledPayload -or $output) { Assert-KBAdministrator }
    if ($sourceKind -eq 'Media') {
        $work=Assert-KBLocalWritePath (ConvertTo-KBInputPath $WorkRoot)
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup') {
            Write-Warning 'Exchange installation detected. Extraction uses local disk and CPU; a management workstation is recommended. This prepares files only, not Exchange remediation.'
        }
        if ($Download) {
            $null=New-Item -Path $work -ItemType Directory -Force
            $runDirectory=Join-Path $work ([guid]::NewGuid().ToString('N'))
            $null=New-Item -Path $runDirectory -ItemType Directory
            $SqlPackagePath=Join-Path $runDirectory 'SQLEXPR_x64_ENU.partial.exe'
            Write-Host "Downloading Microsoft media. Required complete size: $($spec.SqlPackage.Bytes) bytes."
            Write-Host "Temporary download: $SqlPackagePath"
            $oldProtocol=[Net.ServicePointManager]::SecurityProtocol
            try {
                [Net.ServicePointManager]::SecurityProtocol=$oldProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $spec.SqlPackage.Url -OutFile $SqlPackagePath -UseBasicParsing
            } finally { [Net.ServicePointManager]::SecurityProtocol=$oldProtocol }
        }
        if ($SqlPackagePath -notmatch '^[A-Za-z]:\\') { throw 'Copy the SQL media to a local drive before extraction; UNC/provider paths are not accepted.' }
        Write-Host "Verifying media: $SqlPackagePath"
        Assert-KBIdentity -Path $SqlPackagePath -Expected $spec.SqlPackage
        $signature=Get-AuthenticodeSignature -LiteralPath $SqlPackagePath
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
            throw "Microsoft signature verification failed (status: $($signature.Status)). The package must have a valid Microsoft Authenticode signature. Do not extract. Obtain a fresh copy from the approved Microsoft source; if a complete matching file still fails, check certificate trust, system time and network access."
        }
        if ($Download) {
            $complete=Join-Path $runDirectory $spec.SqlPackage.Name
            Move-Item -LiteralPath $SqlPackagePath -Destination $complete
            $SqlPackagePath=$complete
        }
    }
    if ($sourceKind -eq 'Media' -and $null -eq $runDirectory) {
        $null=New-Item -Path $work -ItemType Directory -Force
        $runDirectory=Join-Path $work ([guid]::NewGuid().ToString('N'))
        $null=New-Item -Path $runDirectory -ItemType Directory
    }
    if ($sourceKind -eq 'Media') {
        $media=Join-Path $runDirectory 'Media'
        $files=Join-Path $runDirectory 'Files'
        Write-Host 'Extracting verified media only; SQL Setup/product installation is not run.'
        $process=Start-Process -FilePath $SqlPackagePath -ArgumentList ('/q /x:"{0}"' -f $media) -Wait -PassThru
        $msi=Join-Path $media 'x64\Setup\SQL_FULLTEXT.MSI'
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $msi -PathType Leaf)) {
            throw "SQL extract-only failed (exit $($process.ExitCode)); expected $msi. Check disk space, permissions and extraction diagnostics. Do not continue with partial media."
        }
        $log=Join-Path $runDirectory 'extract.log'
        $arguments='/a "{0}" TARGETDIR="{1}" /qn /norestart /L*V "{2}"' -f $msi,$files,$log
        $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "MSI administrative extraction failed (exit $($process.ExitCode)). Inspect $log; check disk space, permissions and the profile-loaded elevated session." }
        $RuleSourceDirectory=Join-Path $files 'Program Files\Microsoft SQL Server\MSSQL.X\MSSQL\Binn\ftcomponents\wordbreakers'
        Assert-KBPayload -Directory $RuleSourceDirectory
    }
    $zip=$null
    $zipHash=$null
    $package=$PSScriptRoot
    $payload=$RuleSourceDirectory
    if ($output) {
        $null=New-Item -Path $output -ItemType Directory
        $package=Join-Path $output 'Exchange-KoreanRules'
        $payload=Join-Path $package 'payload'
        $null=New-Item -Path $payload -ItemType Directory -Force
        foreach ($name in @('KoreanRules.psd1','KoreanRules.psm1','Install-KoreanRules.ps1','Get-KoreanRulesState.ps1','Set-KoreanRulesState.ps1','README.txt')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $package $name)
        }
        foreach ($directory in @('private','examples','docs')) { $null=New-Item -Path (Join-Path $package $directory) -ItemType Directory }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'private\Invoke-KoreanRulesOperation.ps1') -Destination (Join-Path $package 'private')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'examples\servers.csv') -Destination (Join-Path $package 'examples')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\Reporting-and-Splunk.md') -Destination (Join-Path $package 'docs')
        foreach ($rule in $spec.Rules) { Copy-Item -LiteralPath (Join-Path $RuleSourceDirectory $rule.Name) -Destination (Join-Path $payload $rule.Name) }
        Assert-KBPayload -Directory $payload
        $manifest=@(Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName | ForEach-Object {
            '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash,$_.FullName.Substring($package.Length+1)
        })
        $manifest | Set-Content -LiteralPath (Join-Path $package 'SHA256SUMS.txt') -Encoding ASCII
        $zip=Join-Path $output ('Exchange-KoreanRules-{0}-deploy.zip' -f $spec.PackageVersion)
        Compress-Archive -LiteralPath $package -DestinationPath $zip -CompressionLevel Optimal
        $zipHash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        "$zipHash  $([IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII
    }
    $defaultPayload = if ($useBundledPayload -and -not $output) { $adjacentPayload } else {
        Initialize-KBDefaultPayload -SourceDirectory $payload -PackageDirectory $PSScriptRoot
    }
    if (-not $output) { $payload=$defaultPayload }
    if ($zip) { Write-Host "Optional portable package created: $zip" -ForegroundColor Green }
    Write-Host "Default payload ready for this kit: $defaultPayload" -ForegroundColor Green
    Write-Host 'No Exchange installation files were changed and no services were restarted.'
    Write-Host 'Next, from this same folder: .\Set-KoreanRulesState.ps1 -WhatIf'
    [pscustomobject]@{Package=$zip;SHA256=$zipHash;ExpandedPackage=$package;PayloadDirectory=$payload;DefaultPayloadDirectory=$defaultPayload;ExtractionArtifacts=$runDirectory;Note='Preparation only; default payload is ready for Set from this kit.'}
    exit 0
} catch {
    if ($PSBoundParameters.ContainsKey('ErrorAction') -and [string]$PSBoundParameters.ErrorAction -eq 'Stop') { throw }
    [Console]::Error.WriteLine("Korean Rules preparation did not complete.`n$($_.Exception.Message)")
    if ($runDirectory) { [Console]::Error.WriteLine("Diagnostics/download retained at: $runDirectory. Files named *.partial.exe are not verified media.") }
    [Console]::Error.WriteLine('No Exchange files or services were changed. Do not bypass the verification checks.')
    exit 1
}
