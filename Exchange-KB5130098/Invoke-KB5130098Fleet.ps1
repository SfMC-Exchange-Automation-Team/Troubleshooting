#Requires -Version 5.1
<#
.SYNOPSIS
Inventories explicit WinRM targets or performs a gated, serial workaround rollout.
.DESCRIPTION
Uses existing WinRM/Kerberos configuration. Does not change TrustedHosts, enable
remoting, store credentials or use the constrained Exchange remote-shell endpoint.
Apply requires an interactive recovery attestation after EACH server, including
the last. -Confirm:$false suppresses change confirmation, not recovery attestation.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ComputerName,
    [ValidateSet('Detect', 'Apply')][string]$Mode = 'Detect',
    [string]$PackageDirectory,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [switch]$MaintenanceWindowApproved,
    [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(15, 300)][int]$StabilitySeconds = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $PSBoundParameters.ContainsKey('PackageDirectory')) {
    $PackageDirectory = $PSScriptRoot
}
Import-Module (Join-Path $PSScriptRoot 'KB5130098.psm1') -Force
$reportRoot = Assert-KBLocalWritePath $ReportDirectory
foreach ($server in $ComputerName) {
    if ($server -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -or
        $server -match '\.\.' -or $server -match '^\d+\.\d+\.\d+\.\d+$') {
        throw "Use explicit DNS/NetBIOS names, not wildcards, IPs or URLs: $server"
    }
}
if (@($ComputerName | Select-Object -Unique).Count -ne $ComputerName.Count) {
    throw 'Duplicate targets are not permitted.'
}
if ($Mode -eq 'Apply') {
    if (-not $MaintenanceWindowApproved) { throw 'Apply requires an agreed window and -MaintenanceWindowApproved.' }
    Assert-KBPayload -Directory (Join-Path $PackageDirectory 'payload')
}
$codeFiles = @('KB5130098.psd1', 'KB5130098.psm1')
foreach ($name in $codeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageDirectory $name) -PathType Leaf)) {
        throw "Missing package file: $name"
    }
}
if (-not $PSCmdlet.ShouldProcess(($ComputerName -join ', '), "$Mode KB5130098 sequentially; stage code and save reports")) {
    return
}
$null = New-Item -Path $reportRoot -ItemType Directory -Force
$reportRun = Join-Path $reportRoot ([guid]::NewGuid().ToString('N'))
$null = New-Item -Path $reportRun -ItemType Directory
$summaryFile = Join-Path $reportRun 'rollout.json'
$results = New-Object Collections.Generic.List[object]
$seenMachines = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($server in $ComputerName) {
    $session = $null
    $record = [ordered]@{
        Target = $server
        Mode = $Mode
        UTC = [DateTime]::UtcNow.ToString('o')
        Status = 'Started'
        RemoteStage = $null
        Detection = $null
        Result = $null
        RecoveryAttestation = $null
        Error = $null
    }
    $results.Add($record)
    try {
        $options = New-PSSessionOption -OpenTimeout 60000 -OperationTimeout 900000
        $session = New-PSSession -ComputerName $server -Authentication Kerberos -ConfigurationName Microsoft.PowerShell -SessionOption $options
        $stage = Invoke-Command -Session $session -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or -not [Environment]::Is64BitProcess) {
                throw 'Remote session must be elevated and 64-bit.'
            }
            $root = 'C:\ProgramData\Exchange-KB5130098-Staging'
            $current = $root
            while ($current) {
                if (Test-Path -LiteralPath $current) {
                    if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        throw "Staging path cannot use reparse points: $current"
                    }
                }
                $current = [IO.Path]::GetDirectoryName($current)
            }
            $path = Join-Path $root ([guid]::NewGuid().ToString('N'))
            $null = New-Item -Path $path -ItemType Directory -Force
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $identity = New-Object Security.Principal.SecurityIdentifier $sid
                $rule = New-Object Security.AccessControl.FileSystemAccessRule (
                    $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $path -AclObject $acl
            [pscustomobject]@{ Path = $path; ComputerName = $env:COMPUTERNAME }
        }
        $record.RemoteStage = $stage.Path
        if (-not $seenMachines.Add($stage.ComputerName)) {
            throw 'Two targets resolved to the same machine. Stop; do not apply twice using aliases.'
        }
        foreach ($name in $codeFiles) {
            $source = Join-Path $PackageDirectory $name
            $destination = Join-Path $stage.Path $name
            Copy-Item -LiteralPath $source -Destination $destination -ToSession $session
            $expected = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            Invoke-Command -Session $session -ArgumentList $destination, $expected -ScriptBlock {
                param($Path, $Expected)
                $ErrorActionPreference = 'Stop'
                if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
                    throw "Code transfer hash mismatch: $Path"
                }
            }
        }
        $detection = Invoke-Command -Session $session -ArgumentList $stage.Path -ScriptBlock {
            param($Stage)
            $ErrorActionPreference = 'Stop'
            Import-Module (Join-Path $Stage 'KB5130098.psm1') -Force
            Invoke-KBLocal -Mode Detect
        }
        $record.Detection = $detection
        $record.Status = $detection.Status
        if ($Mode -eq 'Apply') {
            if (-not $detection.Eligible) {
                throw "Server $server is not eligible: $($detection.Status). Stop and contact Microsoft Support."
            }
            $remotePayload = Invoke-Command -Session $session -ArgumentList $stage.Path -ScriptBlock {
                param($Stage)
                (New-Item -Path (Join-Path $Stage 'payload') -ItemType Directory -ErrorAction Stop).FullName
            }
            foreach ($rule in (Get-KBSpecification).Rules) {
                Copy-Item -LiteralPath (Join-Path (Join-Path $PackageDirectory 'payload') $rule.Name) -Destination (Join-Path $remotePayload $rule.Name) -ToSession $session
            }
            $record.Result = Invoke-Command -Session $session -ArgumentList $stage.Path, $TimeoutSeconds, $StabilitySeconds -ScriptBlock {
                param($Stage, $Timeout, $Stability)
                $ErrorActionPreference = 'Stop'
                Invoke-KBLocal -Mode Apply -PayloadDirectory (Join-Path $Stage 'payload') -RestartSearch -MaintenanceWindowApproved -TimeoutSeconds $Timeout -StabilitySeconds $Stability -Confirm:$false
            }
            if ($record.Result.Status -ne 'RestartedWorkloadValidationRequired') {
                throw 'Unexpected deployment result. Do not proceed to another server.'
            }
            $record.Status = 'AwaitingWorkloadValidation'
            ConvertTo-Json -InputObject @($results.ToArray()) -Depth 12 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
            Write-Host "STOP: Validate $server before proceeding." -ForegroundColor Yellow
            Write-Host 'Use an OWA mailbox whose ACTIVE database is on this server: new ordinary AND Korean messages must deliver and be searchable.'
            Write-Host 'Confirm the original delivery/Outlook symptoms recovered. Check the existing indexing backlog separately.'
            Write-Host 'A running service/process is not proof of recovery. If any check fails or is unavailable, stop.'
            $required = "RECOVERED $server"
            $answer = Read-Host "Type exactly '$required' after all workload checks pass; anything else stops rollout"
            if ($answer -cne $required) {
                throw 'Recovery was not confirmed. No subsequent server will be changed.'
            }
            $record.RecoveryAttestation = [ordered]@{
                Operator = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                UTC = [DateTime]::UtcNow.ToString('o')
                Statement = $required
            }
            $record.Status = 'OperatorConfirmedRecovery'
        }
    } catch {
        $record.Status = 'FailedStop'
        $record.Error = $_.Exception.Message
        ConvertTo-Json -InputObject @($results.ToArray()) -Depth 12 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
        throw
    } finally {
        ConvertTo-Json -InputObject @($results.ToArray()) -Depth 12 | Set-Content -LiteralPath $summaryFile -Encoding UTF8
        if ($null -ne $session) { Remove-PSSession -Session $session }
    }
}
[pscustomobject]@{ Report = $summaryFile; Servers = $results.Count; Mode = $Mode }
