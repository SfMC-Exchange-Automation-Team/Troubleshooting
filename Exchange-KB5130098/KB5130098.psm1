#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'KB5130098.psd1')

function Get-KBSpecification {
    $script:Spec
}

function Assert-KBAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Use an elevated, 64-bit Windows PowerShell 5.1 session.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw '32-bit PowerShell is not supported. Use 64-bit Windows PowerShell.'
    }
}

function Assert-KBLocalWritePath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '^F:' -or $Path.Contains('"')) {
        throw "A local absolute path outside F: is required: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not permitted on write paths: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    $full
}

function Get-KBExchangePath {
    $key = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'
    if (-not (Test-Path -LiteralPath $key)) {
        throw 'Exchange v15 Setup registry key was not found. No changes made.'
    }
    $path = (Get-ItemProperty -LiteralPath $key -Name MsiInstallPath).MsiInstallPath
    if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '^[A-Za-z]:\\') {
        throw 'Exchange MsiInstallPath is absent or is not an absolute local directory.'
    }
    [IO.Path]::GetFullPath($path).TrimEnd('\')
}

function Get-KBIdentity {
    param([Parameter(Mandatory)][string]$Path, [switch]$ReadVersion)
    $file = Get-Item -LiteralPath $Path -Force
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a regular file: $Path"
    }
    $version = $null
    if ($ReadVersion) {
        $v = $file.VersionInfo
        $version = '{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart
    }
    [pscustomobject]@{
        Path = $file.FullName
        Bytes = $file.Length
        SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Version = $version
    }
}

function Assert-KBIdentity {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$Expected)
    $actual = Get-KBIdentity -Path $Path -ReadVersion:($Expected.Contains('Version'))
    if ($actual.Bytes -ne $Expected.Bytes -or $actual.SHA256 -ne $Expected.SHA256) {
        throw "Size or SHA256 mismatch: $Path. Stop and contact Microsoft Support."
    }
    if ($Expected.Contains('Version') -and $actual.Version -ne $Expected.Version) {
        throw "Version mismatch: $Path. Expected $($Expected.Version), found $($actual.Version)."
    }
}

function Assert-KBPayload {
    param([Parameter(Mandatory)][string]$Directory)
    foreach ($rule in $script:Spec.Rules) {
        Assert-KBIdentity -Path (Join-Path $Directory $rule.Name) -Expected $rule
    }
}

function Get-KBDetection {
    $exchange = Get-KBExchangePath
    $native = Join-Path $exchange 'Bin\Search\Ceres\Native'
    $setup = Get-KBIdentity -Path (Join-Path $exchange 'Bin\ExSetup.exe') -ReadVersion
    $dll = Get-KBIdentity -Path (Join-Path $native $script:Spec.Dll.Name) -ReadVersion
    $present = @($script:Spec.Rules | Where-Object { Test-Path -LiteralPath (Join-Path $native $_.Name) } | ForEach-Object { $_.Name })
    $eligible = $setup.Version -eq $script:Spec.ExchangeVersion -and
        $dll.Version -eq $script:Spec.Dll.Version -and
        $dll.Bytes -eq $script:Spec.Dll.Bytes -and
        $dll.SHA256 -eq $script:Spec.Dll.SHA256
    $status = 'EligibleMissingBothRules'
    if (-not $eligible) {
        $status = 'NotApplicableStop'
    } elseif ($present.Count -gt 0) {
        $status = 'RuleFilesPresentStop'
    }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Status = $status
        Eligible = ($status -eq 'EligibleMissingBothRules')
        ExchangePath = $exchange
        NativePath = $native
        ExchangeVersion = $setup.Version
        DllVersion = $dll.Version
        DllBytes = $dll.Bytes
        DllSHA256 = $dll.SHA256
        ExistingRules = $present
        Note = 'File eligibility only; not proof of a deadlock or workload recovery. Existing rules must not be overwritten.'
    }
}

function Assert-KBInheritedRead {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $explicit = @($rules | Where-Object { -not $_.IsInherited })
    $read = @($rules | Where-Object {
        $_.IsInherited -and $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData)
    })
    if ($acl.AreAccessRulesProtected -or $explicit.Count -gt 0 -or $read.Count -eq 0) {
        throw "Normal inherited read permissions could not be confirmed: $Path. Do not restart; contact Microsoft Support."
    }
}

function Copy-KBRuleNew {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    # CreateNew prevents a concurrent deployment from overwriting an existing file.
    # A newly created file inherits its DACL from the Native directory, not staging.
    $inputStream = [IO.File]::OpenRead($Source)
    try {
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $inputStream.CopyTo($outputStream)
            $outputStream.Flush($true)
        } finally {
            $outputStream.Dispose()
        }
    } finally {
        $inputStream.Dispose()
    }
}

function New-KBStateDirectory {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = Assert-KBLocalWritePath $Root
    if (-not (Test-Path -LiteralPath $rootPath)) {
        New-Item -Path $rootPath -ItemType Directory -ErrorAction Stop | Out-Null
    }
    $directory = Join-Path $rootPath ([guid]::NewGuid().ToString('N'))
    New-Item -Path $directory -ItemType Directory -ErrorAction Stop | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier $sid
        $rule = New-Object Security.AccessControl.FileSystemAccessRule (
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
    $directory
}

function Write-KBRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)
    $temp = "$Path.new"
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Write-KBEvent {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Event, [Parameter(Mandatory)][string]$Detail)
    [ordered]@{ UTC = [DateTime]::UtcNow.ToString('o'); Event = $Event; Detail = $Detail } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $Directory 'events.jsonl') -Encoding UTF8
}

function Get-KBContentEngine {
    param([Parameter(Mandatory)][string]$ExchangePath)
    $expected = Join-Path $ExchangePath 'Bin\Search\Ceres\Runtime\1.0\ResourceProfile\contentengine\NodeRunner.exe'
    @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'NodeRunner.exe'" | Where-Object {
        $_.ExecutablePath -ieq $expected -and
        $_.CommandLine -match '(?i)--noderoot(?:\s+|=)(?:"[^"]*\\ContentEngineNode1(?:\\[^"]*)?"|[^\s"]*\\ContentEngineNode1(?:\\[^\s"]*)?)(?=\s|$)'
    } | ForEach-Object { $_.ProcessId })
}

function Restart-KBHostController {
    param(
        [Parameter(Mandatory)][string]$ExchangePath,
        [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
        [ValidateRange(15, 300)][int]$StabilitySeconds = 30
    )
    $service = Get-Service -Name HostControllerService -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        throw 'HostControllerService is not Running. Stop and investigate before restarting.'
    }
    if (@($service.DependentServices | Where-Object Status -ne 'Stopped').Count -gt 0) {
        throw 'HostControllerService has running dependent services. No force stop is permitted; contact Microsoft Support.'
    }
    # ServiceController.Stop is non-forcing; WaitForStatus puts a bound on the wait.
    $service.Stop()
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds($TimeoutSeconds))
    $service.Start()
    $service.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds($TimeoutSeconds))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $seen = @()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $seen = @(Get-KBContentEngine -ExchangePath $ExchangePath)
        if ($seen.Count -eq 1) { break }
        Start-Sleep -Seconds 2
    }
    if ($seen.Count -ne 1) {
        throw 'Exactly one ContentEngineNode1 process was not found before timeout. Stop rollout; contact Microsoft Support.'
    }
    $processId = $seen[0]
    $timer.Restart()
    while ($timer.Elapsed.TotalSeconds -lt $StabilitySeconds) {
        Start-Sleep -Seconds 2
        $service.Refresh()
        $seen = @(Get-KBContentEngine -ExchangePath $ExchangePath)
        if ($service.Status -ne 'Running' -or $seen.Count -ne 1 -or $seen[0] -ne $processId) {
            throw 'ContentEngineNode1 exited/restarted or HostControllerService stopped. Stop rollout; contact Microsoft Support.'
        }
    }
    $processId
}

function Invoke-KBLocal {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [ValidateSet('Detect', 'Apply', 'Rollback')][string]$Mode = 'Detect',
        [string]$PayloadDirectory = (Join-Path $PSScriptRoot 'payload'),
        [string]$StateRoot = (Join-Path $env:ProgramData 'Exchange-KB5130098'),
        [string]$ReceiptPath,
        [switch]$RestartSearch,
        [switch]$MaintenanceWindowApproved,
        [switch]$MicrosoftSupportApprovedRollback,
        [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
        [ValidateRange(15, 300)][int]$StabilitySeconds = 30
    )
    Assert-KBAdministrator
    if ($Mode -eq 'Detect') {
        return Get-KBDetection
    }
    if ($RestartSearch -and -not $MaintenanceWindowApproved) {
        throw 'Restart requires -MaintenanceWindowApproved and an agreed maintenance window.'
    }
    if ($Mode -eq 'Rollback' -and (-not $MicrosoftSupportApprovedRollback -or -not $MaintenanceWindowApproved)) {
        throw 'Rollback is not a KB-prescribed repair. Require Microsoft Support approval and a maintenance window.'
    }
    $null = Assert-KBLocalWritePath $StateRoot
    $mutex = New-Object Threading.Mutex $false, 'Global\Exchange-KB5130098'
    $locked = $false
    $stateDirectory = $null
    $receipt = $null
    $receiptFile = $null
    try {
        try {
            $locked = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $locked = $true
            throw 'A previous operation terminated unexpectedly. Inspect its receipt and contact Microsoft Support before retrying.'
        }
        if (-not $locked) { throw 'Another KB5130098 operation is running on this server.' }
        $detection = Get-KBDetection
        $null = Assert-KBLocalWritePath $detection.NativePath
        $service = Get-Service -Name HostControllerService -ErrorAction Stop
        if ($service.Status -ne 'Running') {
            throw 'HostControllerService must be Running before changes. Investigate the stopped service first.'
        }
        if ($Mode -eq 'Apply') {
            if (-not $detection.Eligible) {
                throw "Applicability check stopped the operation: $($detection.Status). Do not overwrite rules; contact Microsoft Support."
            }
            Assert-KBPayload -Directory $PayloadDirectory
        } else {
            if ([string]::IsNullOrWhiteSpace($ReceiptPath)) { throw 'Rollback requires the original apply -ReceiptPath.' }
            $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
            if ($receipt.Schema -ne 1 -or $receipt.Mode -ne 'Apply' -or
                $receipt.ComputerName -ine $env:COMPUTERNAME -or
                $receipt.NativePath -ine $detection.NativePath -or
                $receipt.ExchangeVersion -ne $script:Spec.ExchangeVersion -or
                $detection.Status -eq 'NotApplicableStop' -or
                $receipt.OriginalRulesAbsent -ne $true -or
                @($receipt.CreatedFiles).Count -ne 2 -or
                $receipt.Status -notin @('FilesStagedRestartRequired', 'RestartedWorkloadValidationRequired') -or
                @($receipt.CreatedFiles | Where-Object { $_ -notin $script:Spec.Rules.Name }).Count -gt 0 -or
                @($receipt.CreatedFiles | Select-Object -Unique).Count -ne 2) {
                throw 'Receipt does not prove a completed, owned deployment on this unchanged installation. Contact Microsoft Support.'
            }
            Assert-KBPayload -Directory $detection.NativePath
        }
        $action = "$Mode KB5130098 rule files"
        if ($RestartSearch) { $action += ' and restart HostControllerService' }
        if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
            return [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; Status = 'NoChanges'; Mode = $Mode }
        }
        $stateDirectory = New-KBStateDirectory -Root $StateRoot
        $receiptFile = Join-Path $stateDirectory 'receipt.json'
        $receipt = [ordered]@{
            Schema = 1
            PackageVersion = $script:Spec.PackageVersion
            OperationId = [IO.Path]::GetFileName($stateDirectory)
            ComputerName = $env:COMPUTERNAME
            Mode = $Mode
            UTC = [DateTime]::UtcNow.ToString('o')
            ExchangeVersion = $detection.ExchangeVersion
            NativePath = $detection.NativePath
            OriginalRulesAbsent = ($Mode -eq 'Apply')
            CreatedFiles = @()
            RemovedFiles = @()
            OriginalApplyReceipt = $ReceiptPath
            Status = 'Started'
            Error = $null
        }
        Write-KBRecord -Path $receiptFile -Record $receipt
        Write-KBEvent -Directory $stateDirectory -Event 'Started' -Detail $action
        if ($Mode -eq 'Apply') {
            # Recheck immediately before copying; never rely on a prior fleet inventory.
            $fresh = Get-KBDetection
            if (-not $fresh.Eligible -or $fresh.NativePath -ine $detection.NativePath) {
                throw 'Installation changed after preflight. No further changes are permitted.'
            }
            foreach ($rule in $script:Spec.Rules) {
                $destination = Join-Path $detection.NativePath $rule.Name
                Copy-KBRuleNew -Source (Join-Path $PayloadDirectory $rule.Name) -Destination $destination
                $receipt.CreatedFiles += $rule.Name
                Write-KBRecord -Path $receiptFile -Record $receipt
                Assert-KBIdentity -Path $destination -Expected $rule
                Assert-KBInheritedRead -Path $destination
                Write-KBEvent -Directory $stateDirectory -Event 'CopiedVerified' -Detail $rule.Name
            }
            $receipt.Status = 'FilesStagedRestartRequired'
        } else {
            # Rollback never deletes by arbitrary path from a receipt.
            foreach ($rule in $script:Spec.Rules) {
                $source = Join-Path $detection.NativePath $rule.Name
                Assert-KBIdentity -Path $source -Expected $rule
                Copy-KBRuleNew -Source $source -Destination (Join-Path $stateDirectory $rule.Name)
                Assert-KBIdentity -Path (Join-Path $stateDirectory $rule.Name) -Expected $rule
                Remove-Item -LiteralPath $source -ErrorAction Stop
                $receipt.RemovedFiles += $rule.Name
                Write-KBRecord -Path $receiptFile -Record $receipt
                Write-KBEvent -Directory $stateDirectory -Event 'RemovedOwnedRule' -Detail $rule.Name
            }
            $receipt.Status = 'RolledBackRestartRequired'
        }
        Write-KBRecord -Path $receiptFile -Record $receipt
        if ($RestartSearch) {
            Write-KBEvent -Directory $stateDirectory -Event 'RestartRequested' -Detail 'Graceful stop/start only; no force termination.'
            $nodeId = Restart-KBHostController -ExchangePath $detection.ExchangePath -TimeoutSeconds $TimeoutSeconds -StabilitySeconds $StabilitySeconds
            $receipt.Status = if ($Mode -eq 'Apply') { 'RestartedWorkloadValidationRequired' } else { 'RolledBackWorkloadValidationRequired' }
            Write-KBRecord -Path $receiptFile -Record $receipt
            Write-KBEvent -Directory $stateDirectory -Event 'ProcessStable' -Detail "ContentEngineNode1 PID $nodeId. Workload checks still required."
        }
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Status = $receipt.Status
            ReceiptPath = $receiptFile
            LogDirectory = $stateDirectory
            WorkloadValidationRequired = $true
        }
    } catch {
        $failure = $_
        if ($null -ne $stateDirectory -and $null -ne $receipt -and $null -ne $receiptFile) {
            $receipt.Status = 'FailedStopAndContactSupport'
            $receipt.Error = $failure.Exception.Message
            Write-KBRecord -Path $receiptFile -Record $receipt
            Write-KBEvent -Directory $stateDirectory -Event 'Failed' -Detail $failure.Exception.Message
        }
        # Keep partial evidence/files intact; no silent cleanup, force stop, or retry.
        throw $failure
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function Get-KBSpecification, Assert-KBAdministrator, Assert-KBLocalWritePath, Assert-KBIdentity, Assert-KBPayload, Invoke-KBLocal
