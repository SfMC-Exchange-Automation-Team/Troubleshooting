[CmdletBinding()]
param(
    [string] $ToolboxRoot = (Split-Path -Parent $PSScriptRoot)
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is not available.' }
$source = Join-Path $PSScriptRoot 'Launcher\Tlc.Launcher.cs'
$manifest = Join-Path $PSScriptRoot 'Launcher\Tlc.Launcher.manifest'
$icon = Join-Path $ToolboxRoot 'Assets\TLC-Toolbox.ico'
$output = Join-Path $ToolboxRoot 'TLC-Toolbox.exe'
foreach ($path in $source, $manifest, $icon) { if (-not (Test-Path -LiteralPath $path)) { throw "Launcher build input is missing: $path" } }
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /warn:4 /warnaserror+ `
    "/out:$output" "/win32icon:$icon" "/win32manifest:$manifest" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll $source
if ($LASTEXITCODE -ne 0) { throw 'The native toolbox launcher did not compile.' }
Get-Item -LiteralPath $output
