#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'KB5130098.psd1')

function Get-KBSpecification {
    $script:Spec
}

function Test-KBAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-KBAdministrator {
    if (-not (Test-KBAdministrator)) {
        throw 'Use an elevated, 64-bit Windows PowerShell 5.1 session.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw '32-bit PowerShell is not supported. Use 64-bit Windows PowerShell.'
    }
}

function Get-KBElevationContext {
    $sender = $ExecutionContext.SessionState.PSVariable.Get('PSSenderInfo')
    $nonInteractive = $false
    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        $flag = $argument.TrimStart('-', '/')
        if ($argument -match '^[-/]' -and $flag.Length -ge 4 -and
            'noninteractive'.StartsWith($flag, [StringComparison]::OrdinalIgnoreCase)) {
            $nonInteractive = $true
        }
    }
    [pscustomobject]@{
        Administrator = Test-KBAdministrator
        Is64BitProcess = [Environment]::Is64BitProcess
        Is64BitOS = [Environment]::Is64BitOperatingSystem
        WindowsPowerShell51 = ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
        Remote = ($Host.Name -eq 'ServerRemoteHost' -or ($null -ne $sender -and $null -ne $sender.Value))
        Interactive = ([Environment]::UserInteractive -and
            [Diagnostics.Process]::GetCurrentProcess().SessionId -gt 0 -and
            -not $nonInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
    }
}

function New-KBElevationCommand {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [bool]$WaitForUser = $true,
        [bool]$PreviewPreference = $false,
        [ValidateSet('None', 'Low', 'Medium', 'High')][string]$ConfirmationPreference = 'High'
    )
    $parameters = @{}
    foreach ($key in $BoundParameters.Keys) {
        $value = $BoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            $parameters[$key] = $value.IsPresent
        } elseif ($value -is [string] -or $value -is [bool] -or $value -is [int]) {
            $parameters[$key] = $value
        } elseif ($value -is [Enum]) {
            $parameters[$key] = [string]$value
        } else {
            throw "Parameter '$key' cannot be forwarded safely. Start an elevated Windows PowerShell 5.1 session instead."
        }
    }
    $parameters.NoAutoElevate = $true
    $packet = @{
        ScriptPath = $ScriptPath
        WorkingDirectory = $WorkingDirectory
        Parameters = $parameters
        WaitForUser = $WaitForUser
        PreviewPreference = $PreviewPreference
        ConfirmationPreference = $ConfirmationPreference
    }
    $serialized = [System.Management.Automation.PSSerializer]::Serialize($packet)
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serialized))
    # Paths and parameter values remain data, not interpolated PowerShell source.
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$exitCode = 1
$request = $null
try {
    $request = [System.Management.Automation.PSSerializer]::Deserialize(
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PACKET__')))
    Set-Location -LiteralPath $request.WorkingDirectory
    $parameters = $request.Parameters
    $global:WhatIfPreference = [bool]$request.PreviewPreference
    $global:ConfirmPreference = [System.Management.Automation.ConfirmImpact]$request.ConfirmationPreference
    $global:LASTEXITCODE = 1
    & $request.ScriptPath @parameters
    $exitCode = $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
}
if ($null -ne $request -and $request.WaitForUser) {
    Write-Host ''
    Write-Host ('Operation exit code: {0}. Review the results above.' -f $exitCode)
    $null = Read-Host 'Press Enter to close this elevated window'
}
exit $exitCode
'@
    $bootstrap = $bootstrap.Replace('__PACKET__', $data)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
}

function Invoke-KBAutoElevation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters,
        [switch]$NoAutoElevate,
        [switch]$AsJson,
        [switch]$InPipeline,
        [bool]$PreviewPreference = $false,
        [ValidateSet('None', 'Low', 'Medium', 'High')][string]$ConfirmationPreference = 'High'
    )
    $context = Get-KBElevationContext
    if ($context.Administrator -and $context.Is64BitProcess -and $context.WindowsPowerShell51) { return }
    if (-not $context.Is64BitOS) { throw '64-bit Windows is required. No operation was started.' }
    if ($NoAutoElevate -or $AsJson -or $InPipeline -or $context.Remote -or -not $context.Interactive) {
        throw 'This invocation requires an elevated, 64-bit Windows PowerShell 5.1 session. Automatic UAC is only available for local interactive human output, not -AsJson, pipelines, remoting, noninteractive hosts, or -NoAutoElevate.'
    }
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        throw 'Change to a local filesystem directory before requesting automatic elevation.'
    }
    $system = if ($context.Is64BitProcess) { 'System32' } else { 'Sysnative' }
    $exe = Join-Path $env:WINDIR "$system\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "64-bit Windows PowerShell was not found at $exe."
    }
    $encoded = New-KBElevationCommand -ScriptPath $ScriptPath -BoundParameters $BoundParameters `
        -WorkingDirectory $location.ProviderPath -PreviewPreference $PreviewPreference -ConfirmationPreference $ConfirmationPreference
    Write-Host 'Administrator access is required. Approve the Windows UAC prompt to continue in an elevated window.' -ForegroundColor Yellow
    Write-Host 'The elevated window will show the results and wait for Enter before closing.'
    try {
        # Start-Process has no WhatIf/Confirm parameters in Windows PowerShell 5.1.
        # Scope these preferences to the launcher; the original values are already serialized for the child.
        $WhatIfPreference = $false
        $ConfirmPreference = 'None'
        $child = Start-Process -FilePath $exe -ArgumentList "-NoLogo -NoProfile -EncodedCommand $encoded" `
            -WorkingDirectory $location.ProviderPath -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        throw "Administrator elevation was declined or could not be started: $($_.Exception.Message)"
    }
    if ($null -eq $child -or $null -eq $child.ExitCode) {
        throw 'The elevated process did not return an exit code. Review its window and receipts; do not assume success or retry blindly.'
    }
    [pscustomobject]@{ ExitCode = [int]$child.ExitCode }
}

function Write-KBConsoleResult {
    param(
        [Parameter(Mandatory)][string]$Mode,
        $Result,
        $Before,
        $After,
        [switch]$Preview,
        [string]$ErrorMessage,
        [string]$ObservationError,
        [int]$StabilitySeconds = 30
    )
    $readState = {
        param($State, [string]$Property, [string]$Rule)
        if ($null -eq $State) { return 'Not observed' }
        if ($Rule) {
            if ($State.ExistingRules -contains $Rule) { return 'Present' }
            return 'Missing'
        }
        if ($Property -eq 'IdentityMatch') {
            if ($State.Status -eq 'NotApplicableStop') { return 'No - stop' }
            return 'Yes'
        }
        [string]$State.$Property
    }
    Write-Host ''
    Write-Host ("KB5130098 | {0} | {1}" -f $Mode.ToUpperInvariant(), $env:COMPUTERNAME) -ForegroundColor Cyan
    Write-Host 'Before and current state refer to this invocation, not earlier history.'
    Write-Host ''
    Write-Host ('{0,-26} {1,-24} {2}' -f 'CHECK', 'BEFORE', 'CURRENT') -ForegroundColor Cyan
    foreach ($row in @(
        @{ Label = 'Exchange build'; Property = 'ExchangeVersion'; Rule = '' },
        @{ Label = 'Korean DLL version'; Property = 'DllVersion'; Rule = '' },
        @{ Label = 'Pinned build/DLL match'; Property = 'IdentityMatch'; Rule = '' },
        @{ Label = 'ko.token.rule.bin'; Property = ''; Rule = 'ko.token.rule.bin' },
        @{ Label = 'ko.complex.rule.bin'; Property = ''; Rule = 'ko.complex.rule.bin' }
    )) {
        Write-Host ('{0,-26} {1,-24} {2}' -f $row.Label,
            (& $readState $Before $row.Property $row.Rule), (& $readState $After $row.Property $row.Rule))
    }
    Write-Host ''
    Write-Host 'ACTION TAKEN' -ForegroundColor Cyan
    if ($ErrorMessage) {
        Write-Host "  STOPPED: $ErrorMessage" -ForegroundColor Red
        Write-Host '  No successful completion is being claimed. Check current file state and any receipt before retrying.'
    } else {
        switch ($Result.Status) {
            'EligibleMissingBothRules' { Write-Host '  Checked eligibility only. No files copied or removed. No services restarted.' }
            'NotApplicableStop' { Write-Host '  Checked eligibility only. This installation does not match the pinned requirements; no changes made.' -ForegroundColor Yellow }
            'RuleFilesPresentStop' { Write-Host '  Checked eligibility only. Existing rules were not overwritten and no service was restarted.' -ForegroundColor Yellow }
            'NoChanges' {
                if ($Preview) { Write-Host '  Preview only. No files copied or removed. No services restarted.' }
                else { Write-Host '  The change was not approved. No files copied or removed. No services restarted.' }
            }
            'FilesStagedRestartRequired' { Write-Host '  Added and verified both rule files and their inherited read permissions. Search was NOT restarted.' }
            'RestartedWorkloadValidationRequired' {
                Write-Host '  Added and verified both rule files and their inherited read permissions. Restarted HostControllerService.'
                Write-Host "  ContentEngine passed the $StabilitySeconds-second startup observation. Workload recovery is NOT yet proven."
            }
            'RolledBackRestartRequired' { Write-Host '  Backed up and removed the two owned rule files. Search was NOT restarted.' }
            'RolledBackWorkloadValidationRequired' { Write-Host '  Backed up and removed the two owned rule files and restarted HostControllerService. Workload checks remain required.' }
            default { throw "Unrecognized operation result: $($Result.Status)" }
        }
    }
    if ($ObservationError) { Write-Host "  Current state could not be fully observed: $ObservationError" -ForegroundColor Yellow }
    if ($null -ne $Result) {
        $receipt = $Result.PSObject.Properties['ReceiptPath']
        if ($null -ne $receipt -and $receipt.Value) { Write-Host "  Receipt: $($receipt.Value)" }
        $created = $Result.PSObject.Properties['CreatedFiles']
        if ($ErrorMessage -and $null -ne $created -and @($created.Value).Count -gt 0) {
            Write-Host ("  Failure receipt records file creation: {0}" -f ($created.Value -join ', ')) -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host 'NEXT STEP' -ForegroundColor Cyan
    if ($ErrorMessage) {
        Write-Host '  Stop, retain diagnostics, and investigate with Microsoft Support. Do not overwrite, force-stop, or retry blindly.'
    } elseif ($Result.Status -eq 'EligibleMissingBothRules') {
        Write-Host '  Eligible for staging, but NOT applied. Start with: .\Invoke-KB5130098.ps1 -Mode Apply -WhatIf'
    } elseif ($Result.Status -in 'NotApplicableStop', 'RuleFilesPresentStop') {
        Write-Host '  Stop and reassess with Microsoft Support. Do not relax identity checks or rerun Apply over existing files.'
    } elseif ($Result.Status -eq 'NoChanges') {
        Write-Host '  Nothing was applied. Review the plan; perform the intended operation only with the required approvals.'
    } elseif ($Result.Status -in 'FilesStagedRestartRequired', 'RolledBackRestartRequired') {
        Write-Host '  Verify the receipt and follow the approved manual Search restart/recovery procedure. Do not rerun Apply.'
    } else {
        Write-Host '  Verify new ordinary and Korean delivery/search and the original affected workload before changing another server.'
    }
    Write-Host ''
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
        if ($WhatIfPreference -or -not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, $action)) {
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
            $failure.Exception.Data['KB5130098ReceiptPath'] = $receiptFile
            $failure.Exception.Data['KB5130098CreatedFiles'] = @($receipt.CreatedFiles)
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

Export-ModuleMember -Function Get-KBSpecification, Assert-KBAdministrator, Assert-KBLocalWritePath, Assert-KBIdentity, Assert-KBPayload, Invoke-KBLocal, Invoke-KBAutoElevation, Write-KBConsoleResult
