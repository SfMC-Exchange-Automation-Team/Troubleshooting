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

function New-KBReportRelay {
    $root = Assert-KBLocalWritePath ([IO.Path]::GetTempPath().TrimEnd('\'))
    $directory = Join-Path $root ('KB5130098-report-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $directory) { throw 'The temporary report handoff directory already exists.' }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier $sid
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $null = [IO.Directory]::CreateDirectory($directory, $acl)
    $path = Join-Path $directory 'report.clixml'
    try {
        # Keep the file open without FileShare.Delete so the child writes the reserved file.
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        [pscustomobject]@{ Directory=$directory; Path=$path; Stream=$stream }
    } catch {
        [IO.Directory]::Delete($directory, $false)
        throw
    }
}

function Read-KBReportRelay {
    param([Parameter(Mandatory)]$Relay, [int]$ExpectedExitCode)
    if ($Relay.Stream.Length -eq 0 -or $Relay.Stream.Length -gt 1MB) {
        throw 'The elevated result handoff is missing or invalid. Inspect the elevated window and saved reports; do not rerun a modifying command blindly.'
    }
    $Relay.Stream.Position = 0
    $reader = New-Object IO.StreamReader($Relay.Stream, [Text.Encoding]::UTF8, $true, 4096, $true)
    try { $packet = [System.Management.Automation.PSSerializer]::Deserialize($reader.ReadToEnd()) }
    finally { $reader.Dispose() }
    if ($packet.Schema -ne 1 -or $packet.ExitCode -ne $ExpectedExitCode) { throw 'The elevated result handoff does not match the completed process.' }
    $packet.ReportData = @($packet.ReportData | Where-Object { $null -ne $_ })
    if ($packet.ReportData.Count -eq 0 -and $ExpectedExitCode -ne 1) { throw 'The elevated operation returned no report data.' }
    $packet
}

function Remove-KBReportRelay {
    param([Parameter(Mandatory)]$Relay)
    $Relay.Stream.Dispose()
    [IO.File]::Delete($Relay.Path)
    [IO.Directory]::Delete($Relay.Directory, $false)
}

function New-KBElevationCommand {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BoundParameters,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [bool]$WaitForUser = $true,
        [bool]$PreviewPreference = $false,
        [ValidateSet('None', 'Low', 'Medium', 'High')][string]$ConfirmationPreference = 'High',
        [string]$ReportRelayPath
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
        ReportRelayPath = $ReportRelayPath
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
if ($null -ne $request -and $request.ReportRelayPath) {
    try {
        $reportVariable = $ExecutionContext.SessionState.PSVariable.Get('report')
        $filesVariable = $ExecutionContext.SessionState.PSVariable.Get('reportFiles')
        $handoff = @{
            Schema = 1
            ExitCode = $exitCode
            ReportData = $(if ($null -ne $reportVariable) { @($reportVariable.Value) } else { @() })
            ExportFiles = $(if ($null -ne $filesVariable) { $filesVariable.Value } else { $null })
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes([System.Management.Automation.PSSerializer]::Serialize($handoff, 8))
        if ($bytes.Length -gt 1MB) { throw 'The report is too large for the temporary elevation handoff. Read the saved exports instead.' }
        $stream = [IO.File]::Open($request.ReportRelayPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -ne 0) { throw 'The reserved report handoff file is not empty.' }
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
    } catch {
        [Console]::Error.WriteLine('The elevated report could not be returned: ' + $_.Exception.Message)
        $exitCode = 1
    }
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
    $relay = New-KBReportRelay
    try {
        $encoded = New-KBElevationCommand -ScriptPath $ScriptPath -BoundParameters $BoundParameters `
            -WorkingDirectory $location.ProviderPath -PreviewPreference $PreviewPreference `
            -ConfirmationPreference $ConfirmationPreference -ReportRelayPath $relay.Path
        Write-Host 'Administrator access is required. Approve the Windows UAC prompt to continue in an elevated window.' -ForegroundColor Yellow
        Write-Host 'The elevated window will show the results and wait for Enter before closing; $report then returns to this session.'
        try {
            # Launcher-only preferences do not replace the operation preferences serialized above.
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
        $packet = Read-KBReportRelay -Relay $relay -ExpectedExitCode $child.ExitCode
        [pscustomobject]@{ ExitCode=[int]$child.ExitCode; ReportData=@($packet.ReportData); ExportFiles=$packet.ExportFiles }
    } finally { Remove-KBReportRelay -Relay $relay }
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
        [int]$StabilitySeconds = 30,
        [string]$ComputerName = $env:COMPUTERNAME
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
            if ($State.Status -in @('EligibleMissingBothRules', 'RuleFilesPresentStop')) { return 'Yes' }
            return 'Not observed'
        }
        [string]$State.$Property
    }
    $writeState = {
        param([string]$Value, [int]$Width, [switch]$NoNewline, [string]$IdentityMatch)
        $text = if ($Width -gt 0) { $Value.PadRight($Width) } else { $Value }
        $color = $null
        switch ($Value) {
            'Present' { $color = 'Green' }
            'Yes' { $color = 'Green' }
            'No - stop' { $color = 'Red' }
            'Missing' {
                if ($IdentityMatch -eq 'Yes') { $color = 'Green' }
                elseif ($IdentityMatch -eq 'No - stop') { $color = 'Yellow' }
            }
        }
        if ($color) {
            Write-Host $text -ForegroundColor $color -NoNewline:$NoNewline
        } else {
            Write-Host $text -NoNewline:$NoNewline
        }
    }
    $compareStates = $Mode -eq 'Apply'
    Write-Host ''
    Write-Host ("KB5130098 | {0} | {1}" -f $Mode.ToUpperInvariant(), $ComputerName) -ForegroundColor Cyan
    if ($compareStates) {
        Write-Host 'Before and current state refer to this invocation, not earlier history.'
    }
    Write-Host ''
    if ($compareStates) {
        Write-Host ('{0,-26} {1,-24} {2}' -f 'CHECK', 'BEFORE', 'CURRENT') -ForegroundColor Cyan
    } else {
        Write-Host ('{0,-26} {1}' -f 'CHECK', 'STATUS') -ForegroundColor Cyan
    }
    foreach ($row in @(
        @{ Label = 'Exchange build'; Property = 'ExchangeVersion'; Rule = '' },
        @{ Label = 'Korean DLL version'; Property = 'DllVersion'; Rule = '' },
        @{ Label = 'Pinned build/DLL match'; Property = 'IdentityMatch'; Rule = '' },
        @{ Label = 'ko.token.rule.bin'; Property = ''; Rule = 'ko.token.rule.bin' },
        @{ Label = 'ko.complex.rule.bin'; Property = ''; Rule = 'ko.complex.rule.bin' }
    )) {
        Write-Host ('{0,-26} ' -f $row.Label) -NoNewline
        if ($compareStates) {
            $beforeIdentity = & $readState $Before 'IdentityMatch' ''
            $beforeValue = & $readState $Before $row.Property $row.Rule
            & $writeState -Value $beforeValue -Width 25 -NoNewline -IdentityMatch $beforeIdentity
        }
        $afterIdentity = & $readState $After 'IdentityMatch' ''
        $afterValue = & $readState $After $row.Property $row.Rule
        & $writeState -Value $afterValue -IdentityMatch $afterIdentity
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

function Resolve-KBTargets {
    [CmdletBinding(DefaultParameterSetName = 'Names')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Names')][AllowEmptyCollection()][string[]]$ComputerName,
        [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$CsvPath
    )
    $rows = New-Object Collections.Generic.List[object]
    $targetColumn = 'ComputerName'
    if ($PSCmdlet.ParameterSetName -eq 'Csv') {
        if ([IO.Path]::GetExtension($CsvPath) -ine '.csv') { throw 'Use a .csv file with a ComputerName, Fqdn or Name header.' }
        $file = Get-Item -LiteralPath $CsvPath -ErrorAction Stop
        if ($file.PSIsContainer) { throw 'CsvPath must identify a CSV file, not a directory.' }
        Add-Type -AssemblyName Microsoft.VisualBasic
        $reader = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser (
            $file.FullName, (New-Object Text.UTF8Encoding($false, $true)), $true)
        try {
            $reader.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
            $reader.SetDelimiters(',')
            $reader.HasFieldsEnclosedInQuotes = $true
            $reader.TrimWhiteSpace = $true
            if ($reader.EndOfData) { throw 'The CSV is empty. Supply a ComputerName, Fqdn or Name header and at least one server.' }
            $header = $reader.ReadFields()
            $rowNumber = 1
            if ($header.Count -eq 1 -and $header[0] -match '^#TYPE\s+.+$') {
                if ($reader.EndOfData) { throw 'The CSV contains type information but no header or servers.' }
                $header = $reader.ReadFields()
                $rowNumber++
            }
            $headers = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $targetColumns = @{}
            $column = -1
            for ($index = 0; $index -lt $header.Count; $index++) {
                $name = $header[$index].Trim()
                if ([string]::IsNullOrWhiteSpace($name) -or -not $headers.Add($name)) {
                    throw 'CSV headers must be nonempty and unique, ignoring case.'
                }
                if ($name -in @('ComputerName','Fqdn','Name')) { $targetColumns[$name] = $index }
            }
            foreach ($candidate in @('ComputerName','Fqdn','Name')) {
                if ($targetColumns.ContainsKey($candidate)) {
                    $column = $targetColumns[$candidate]
                    $targetColumn = $candidate
                    break
                }
            }
            if ($column -lt 0) { throw 'The CSV must contain a ComputerName, Fqdn or Name column. Export Name and Fqdn from Get-ExchangeServer; no calculated property is required.' }
            while (-not $reader.EndOfData) {
                $rowNumber++
                $fields = $reader.ReadFields()
                if ($fields.Count -ne $header.Count) {
                    throw "CSV record $rowNumber has $($fields.Count) fields; expected $($header.Count)."
                }
                $rows.Add([pscustomobject]@{ Value = $fields[$column]; Location = "CSV record $rowNumber (column $targetColumn)" })
            }
        } catch [Microsoft.VisualBasic.FileIO.MalformedLineException] {
            throw "Malformed CSV near line $($reader.ErrorLineNumber): $($_.Exception.Message)"
        } finally { $reader.Dispose() }
    } else {
        for ($index = 0; $index -lt $ComputerName.Count; $index++) {
            $rows.Add([pscustomobject]@{ Value = $ComputerName[$index]; Location = "ComputerName entry $($index + 1)" })
        }
    }
    if ($rows.Count -eq 0) { throw 'The target list contains no servers.' }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $targets = New-Object Collections.Generic.List[string]
    foreach ($row in $rows) {
        $name = ([string]$row.Value).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { throw "$($row.Location) has a blank $targetColumn." }
        $address = $null
        if ($name.Length -gt 253 -or [Net.IPAddress]::TryParse($name, [ref]$address) -or
            @($name.Split('.') | Where-Object { $_ -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' }).Count -gt 0) {
            throw "$($row.Location): use explicit DNS/NetBIOS names, not IP addresses, wildcards or URLs: $name"
        }
        if (-not $seen.Add($name)) { throw "Duplicate target '$name' at $($row.Location). Target names are case-insensitive." }
        $targets.Add($name)
    }
    $targets.ToArray()
}

function Get-KBReportValue {
    param($InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value }
}

function New-KBReportContext {
    param(
        [ValidateNotNullOrEmpty()][string]$ReportDirectory = 'C:\Temp\KB5130098-Reports',
        [switch]$NoWrite
    )
    $root = Assert-KBLocalWritePath $ReportDirectory
    $runId = [guid]::NewGuid().ToString('N')
    $directory = Join-Path $root $runId
    if (-not $NoWrite) {
        $null = New-Item -Path $root -ItemType Directory -Force
        $null = New-Item -Path $directory -ItemType Directory
    }
    [pscustomobject]@{
        Root=$root; RunId=$runId; Directory=$directory
        JsonPath=Join-Path $directory 'rollout.json'
        NoWrite=$NoWrite.IsPresent
    }
}

function ConvertTo-KBReportRows {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$RunId,
        [string]$DetailReportPath,
        [string]$TimestampUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    )
    foreach ($record in $Records) {
        $target = [string](Get-KBReportValue $record 'Target')
        $mode = [string](Get-KBReportValue $record 'Mode')
        $status = [string](Get-KBReportValue $record 'Status')
        if (-not $target -or -not $mode -or -not $status) { throw 'A report record is missing Target, Mode or Status.' }
        $before = Get-KBReportValue $record 'Detection'
        $current = Get-KBReportValue $record 'Current'
        $operation = Get-KBReportValue $record 'Result'
        $operationStatus = [string](Get-KBReportValue $operation 'Status')
        $ruleState = {
            param($State, [string]$Name)
            if ($null -eq $State) { return 'Not observed' }
            if (@(Get-KBReportValue $State 'ExistingRules') -contains $Name) { return 'Present' }
            'Missing'
        }
        $action = switch ($operationStatus) {
            'FilesStagedRestartRequired' { 'Added verified rules; Search not restarted' }
            'RestartedWorkloadValidationRequired' { 'Added verified rules; restarted HostControllerService' }
            'RolledBackRestartRequired' { 'Backed up and removed owned rules; Search not restarted' }
            'RolledBackWorkloadValidationRequired' { 'Backed up and removed owned rules; restarted HostControllerService' }
            default {
                if ($status -eq 'NotRun') { 'Not contacted' }
                elseif ($status -eq 'NoChanges') { 'No changes; preview or declined operation' }
                elseif ($status -eq 'FailedStop') { 'Stopped; inspect error and any receipt' }
                elseif ($mode -eq 'Detect') { 'Detection only; no Exchange changes' }
                else { 'No completed modifying operation recorded' }
            }
        }
        if ($status -eq 'FailedStop' -and $operationStatus -in @(
            'FilesStagedRestartRequired','RestartedWorkloadValidationRequired',
            'RolledBackRestartRequired','RolledBackWorkloadValidationRequired')) {
            $action += '; rollout stopped'
        }
        $validation = Get-KBReportValue $operation 'WorkloadValidationRequired'
        [pscustomobject][ordered]@{
            SchemaVersion = 1
            RunId = $RunId
            TimestampUtc = $TimestampUtc
            PackageVersion = [string]$script:Spec.PackageVersion
            ComputerName = $target
            Mode = $mode
            Status = $status
            ActionTaken = $action
            ExchangeVersion = Get-KBReportValue $current 'ExchangeVersion'
            DllVersion = Get-KBReportValue $current 'DllVersion'
            DllSHA256 = Get-KBReportValue $current 'DllSHA256'
            BeforeTokenRule = & $ruleState $before 'ko.token.rule.bin'
            BeforeComplexRule = & $ruleState $before 'ko.complex.rule.bin'
            TokenRule = & $ruleState $current 'ko.token.rule.bin'
            ComplexRule = & $ruleState $current 'ko.complex.rule.bin'
            RestartRequested = [bool](Get-KBReportValue $record 'RestartSearch')
            RestartCompleted = ($operationStatus -in 'RestartedWorkloadValidationRequired','RolledBackWorkloadValidationRequired')
            WorkloadValidationRequired = $(if ($null -eq $validation) { $null } else { [bool]$validation })
            RecoveryAttested = ($null -ne (Get-KBReportValue $record 'RecoveryAttestation'))
            ReceiptPath = Get-KBReportValue $operation 'ReceiptPath'
            Error = Get-KBReportValue $record 'Error'
            ObservationError = Get-KBReportValue $record 'ObservationError'
            DetailReportPath = $DetailReportPath
        }
    }
}

function Save-KBReportExports {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [switch]$NoCsv
    )
    $paths = [pscustomobject]@{ Json=$null; Csv=$null; JsonLines=$null }
    if ($Context.NoWrite) { return $paths }
    $paths.Json = $Context.JsonPath
    $paths.JsonLines = Join-Path $Context.Directory 'results.jsonl'
    if (-not $NoCsv) { $paths.Csv = Join-Path $Context.Directory 'results.csv' }
    try {
        if ((Test-Path -LiteralPath $paths.JsonLines) -or
            ($paths.Csv -and (Test-Path -LiteralPath $paths.Csv))) {
            throw 'Final result exports already exist. Do not rewrite events that may have been ingested.'
        }
        Write-KBFleetReport -Path $paths.Json -Records $Records
        if (-not $NoCsv) {
            $csvRows = foreach ($row in $Rows) {
                $values = [ordered]@{}
                foreach ($property in $row.PSObject.Properties) {
                    $value = $property.Value
                    # Spreadsheet clients can evaluate formula-like strings even in quoted CSV fields.
                    if ($value -is [string] -and $value -match '^[=+\-@\t\r]') { $value = "'" + $value }
                    $values[$property.Name] = $value
                }
                [pscustomobject]$values
            }
            $csvRows | Export-Csv -LiteralPath "$($paths.Csv).new" -NoTypeInformation -Encoding UTF8
            Move-Item -LiteralPath "$($paths.Csv).new" -Destination $paths.Csv
        }
        $lines = @($Rows | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress })
        [IO.File]::WriteAllLines("$($paths.JsonLines).new", [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath "$($paths.JsonLines).new" -Destination $paths.JsonLines
        $paths
    } catch {
        foreach ($name in @('Json','Csv','JsonLines')) {
            if ($paths.$name -and -not (Test-Path -LiteralPath $paths.$name -PathType Leaf)) { $paths.$name=$null }
        }
        $_.Exception.Data['KB5130098ReportRows'] = @($Rows)
        $_.Exception.Data['KB5130098ReportFiles'] = $paths
        $_.Exception.Data['KB5130098FleetReport'] = $paths.Json
        throw
    }
}

function Write-KBReportSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, $Files)
    Write-Host ''
    Write-Host ('$report contains {0} structured server result(s).' -f $Rows.Count) -ForegroundColor Cyan
    if ($Rows.Count -gt 0) {
        $Rows | Format-Table ComputerName,Mode,Status,ActionTaken -AutoSize -Wrap | Out-Host
    }
    if ($null -ne $Files -and $Files.Json) {
        Write-Host "Detailed JSON: $($Files.Json)"
        if ($Files.Csv) { Write-Host "CSV:           $($Files.Csv)" }
        Write-Host "JSON Lines:    $($Files.JsonLines)"
        Write-Host 'Use $report to filter/export the objects; $reportFiles contains the output paths.'
    } else {
        Write-Host 'No persistent report exports were written for this invocation.'
    }
}

function Write-KBFleetReport {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Records)
    $temporary = "$Path.new"
    ConvertTo-Json -InputObject $Records -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Invoke-KBFleet {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Names')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Names')][AllowEmptyCollection()][string[]]$ComputerName,
        [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$CsvPath,
        [ValidateSet('Detect', 'Apply')][string]$Mode = 'Detect',
        [Parameter(Mandatory)][string]$PackageDirectory,
        [string]$PayloadDirectory,
        [ValidateNotNullOrEmpty()][string]$ReportDirectory,
        [switch]$RestartSearch,
        [switch]$MaintenanceWindowApproved,
        [switch]$Quiet,
        [switch]$NoCsv,
        [ValidateRange(30, 600)][int]$TimeoutSeconds = 120,
        [ValidateRange(15, 300)][int]$StabilitySeconds = 30
    )
    if ($PSCmdlet.ParameterSetName -eq 'Csv') { $targets = @(Resolve-KBTargets -CsvPath $CsvPath) }
    else { $targets = @(Resolve-KBTargets -ComputerName $ComputerName) }
    $contextParameters = @{ NoWrite=$true }
    if ($PSBoundParameters.ContainsKey('ReportDirectory')) { $contextParameters.ReportDirectory=$ReportDirectory }
    $context = New-KBReportContext @contextParameters
    $reportRoot = $context.Root
    if ($RestartSearch -and $Mode -ne 'Apply') { throw 'RestartSearch is valid only with remote Apply.' }
    if ($RestartSearch -and -not $MaintenanceWindowApproved) { throw 'Restart requires an agreed window and -MaintenanceWindowApproved.' }
    if ($RestartSearch -and $Quiet -and -not $WhatIfPreference) {
        throw 'Remote restart requires interactive human recovery attestation. Omit -AsJson and read rollout.json for structured results.'
    }
    if ($RestartSearch -and -not $WhatIfPreference) {
        $consoleContext = Get-KBElevationContext
        if ($consoleContext.Remote -or -not $consoleContext.Interactive) {
            throw 'Remote restart rollout requires a local interactive console for recovery attestation. No target has been contacted.'
        }
    }
    if (-not $PSBoundParameters.ContainsKey('PayloadDirectory')) { $PayloadDirectory = Join-Path $PackageDirectory 'payload' }
    if ($Mode -eq 'Apply') { Assert-KBPayload -Directory $PayloadDirectory }
    $codeFiles = @('KB5130098.psd1', 'KB5130098.psm1')
    foreach ($name in $codeFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageDirectory $name) -PathType Leaf)) { throw "Missing package file: $name" }
    }
    $intent = "$Mode KB5130098 serially on $($targets.Count) server(s)"
    if ($RestartSearch) { $intent += '; restart Search and attest recovery after EACH server' }
    if ($WhatIfPreference) {
        if (-not $Quiet) {
            Write-Host "What if: $intent. No remote connections, staged files or reports."
            foreach ($server in $targets) { Write-Host "  $server" }
        }
        $plan = @($targets | ForEach-Object { [pscustomobject]@{Target=$_; Mode=$Mode; Status='NoChanges'; RestartSearch=$RestartSearch.IsPresent} })
        $rows = @(ConvertTo-KBReportRows -Records $plan -RunId $context.RunId)
        return [pscustomobject]@{ Mode=$Mode; Status='NoChanges'; ExitCode=0; Report=$null; Servers=0; TargetCount=$targets.Count; Targets=$targets; Results=@(); ReportData=$rows; ExportFiles=$null }
    }
    if (-not $PSCmdlet.ShouldProcess(($targets -join ', '), $intent)) {
        $plan = @($targets | ForEach-Object { [pscustomobject]@{Target=$_; Mode=$Mode; Status='NoChanges'; RestartSearch=$RestartSearch.IsPresent} })
        $rows = @(ConvertTo-KBReportRows -Records $plan -RunId $context.RunId)
        return [pscustomobject]@{ Mode=$Mode; Status='NoChanges'; ExitCode=0; Report=$null; Servers=0; TargetCount=$targets.Count; Targets=$targets; Results=@(); ReportData=$rows; ExportFiles=$null }
    }
    $null = New-Item -Path $reportRoot -ItemType Directory -Force
    $reportRun = $context.Directory
    $null = New-Item -Path $reportRun -ItemType Directory
    $context.NoWrite = $false
    $summaryFile = $context.JsonPath
    $results = New-Object Collections.Generic.List[object]
    foreach ($server in $targets) {
        $results.Add([ordered]@{
            Target=$server; Mode=$Mode; UTC=$null; Status='NotRun'; RemoteStage=$null; RestartSearch=$RestartSearch.IsPresent
            Detection=$null; Current=$null; Result=$null; RecoveryAttestation=$null
            Error=$null; ObservationError=$null
        })
    }
    Write-KBFleetReport -Path $summaryFile -Records @($results.ToArray())
    $seenMachines = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $results) {
        $server = $record.Target
        $session = $null
        $record.UTC = [DateTime]::UtcNow.ToString('o')
        $record.Status = 'Started'
        try {
            if (-not $Quiet) { Write-Host ("[{0}/{1}] {2}" -f ($seenMachines.Count + 1), $targets.Count, $server) -ForegroundColor Cyan }
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
                    if ((Test-Path -LiteralPath $current) -and
                        ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        throw "Staging path cannot use reparse points: $current"
                    }
                    $current = [IO.Path]::GetDirectoryName($current)
                }
                $path = Join-Path $root ([guid]::NewGuid().ToString('N'))
                $null = New-Item -Path $path -ItemType Directory -Force
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                    $identity = New-Object Security.Principal.SecurityIdentifier $sid
                    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                        $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
                }
                Set-Acl -LiteralPath $path -AclObject $acl
                [pscustomobject]@{ Path=$path; ComputerName=$env:COMPUTERNAME }
            }
            $record.RemoteStage = $stage.Path
            if (-not $seenMachines.Add($stage.ComputerName)) { throw 'Two targets resolved to the same machine. Stop; do not apply twice using aliases.' }
            foreach ($name in $codeFiles) {
                $source = Join-Path $PackageDirectory $name
                $destination = Join-Path $stage.Path $name
                Copy-Item -LiteralPath $source -Destination $destination -ToSession $session
                $expected = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
                Invoke-Command -Session $session -ArgumentList $destination, $expected -ScriptBlock {
                    param($Path, $Expected)
                    $ErrorActionPreference = 'Stop'
                    if ((Get-FileHash -LiteralPath $Path).Hash -ne $Expected) { throw "Code transfer hash mismatch: $Path" }
                }
            }
            $record.Detection = Invoke-Command -Session $session -ArgumentList $stage.Path -ScriptBlock {
                param($Stage)
                $ErrorActionPreference = 'Stop'
                Import-Module (Join-Path $Stage 'KB5130098.psm1') -Force
                Invoke-KBLocal -Mode Detect
            }
            $record.Status = $record.Detection.Status
            if ($Mode -eq 'Apply') {
                if (-not $record.Detection.Eligible) { throw "Server $server is not eligible: $($record.Detection.Status). Stop and contact Microsoft Support." }
                $remotePayload = Invoke-Command -Session $session -ArgumentList $stage.Path -ScriptBlock {
                    param($Stage)
                    (New-Item -Path (Join-Path $Stage 'payload') -ItemType Directory -ErrorAction Stop).FullName
                }
                foreach ($rule in $script:Spec.Rules) {
                    Copy-Item -LiteralPath (Join-Path $PayloadDirectory $rule.Name) -Destination (Join-Path $remotePayload $rule.Name) -ToSession $session
                }
                $record.Result = Invoke-Command -Session $session `
                    -ArgumentList $stage.Path, $TimeoutSeconds, $StabilitySeconds, $RestartSearch.IsPresent, $MaintenanceWindowApproved.IsPresent `
                    -ScriptBlock {
                    param($Stage, $Timeout, $Stability, $Restart, $Approved)
                    $ErrorActionPreference = 'Stop'
                    Invoke-KBLocal -Mode Apply -PayloadDirectory (Join-Path $Stage 'payload') `
                        -RestartSearch:$Restart -MaintenanceWindowApproved:$Approved -TimeoutSeconds $Timeout -StabilitySeconds $Stability -Confirm:$false
                }
                $expectedStatus = if ($RestartSearch) { 'RestartedWorkloadValidationRequired' } else { 'FilesStagedRestartRequired' }
                if ($record.Result.Status -ne $expectedStatus) { throw 'Unexpected deployment result. Do not proceed to another server.' }
                $record.Status = $record.Result.Status
            }
            $record.Current = Invoke-Command -Session $session -ScriptBlock { Invoke-KBLocal -Mode Detect }
            if ($Mode -eq 'Detect') { $record.Status = $record.Current.Status }
            if (-not $Quiet) {
                $display = if ($Mode -eq 'Detect') { $record.Current } else { $record.Result }
                Write-KBConsoleResult -ComputerName $server -Mode $Mode -Result $display `
                    -Before $record.Detection -After $record.Current -StabilitySeconds $StabilitySeconds
            }
            if ($RestartSearch) {
                $record.Status = 'AwaitingWorkloadValidation'
                Write-KBFleetReport -Path $summaryFile -Records @($results.ToArray())
                Write-Host "STOP: Validate $server before proceeding." -ForegroundColor Yellow
                Write-Host 'Use a mailbox whose ACTIVE database is on this server: new ordinary AND Korean messages must deliver and be searchable.'
                Write-Host 'Verify the original affected workload and check the existing indexing backlog separately. A running process alone is insufficient.'
                $required = "RECOVERED $server"
                if ((Read-Host "Type exactly '$required' after all workload checks pass; anything else stops rollout") -cne $required) {
                    throw 'Recovery was not confirmed. No subsequent server will be changed.'
                }
                $record.RecoveryAttestation = [ordered]@{
                    Operator=[Security.Principal.WindowsIdentity]::GetCurrent().Name
                    UTC=[DateTime]::UtcNow.ToString('o'); Statement=$required
                }
                $record.Status = 'OperatorConfirmedRecovery'
            }
        } catch {
            $failure = $_
            $record.Status = 'FailedStop'
            $record.Error = $failure.Exception.Message
            if ($null -ne $record.Detection -and $null -ne $session -and $null -eq $record.Current) {
                try { $record.Current = Invoke-Command -Session $session -ScriptBlock { Invoke-KBLocal -Mode Detect } }
                catch { $record.ObservationError = $_.Exception.Message }
            }
            if (-not $Quiet) {
                Write-KBConsoleResult -ComputerName $server -Mode $Mode -Result $record.Result `
                    -Before $record.Detection -After $record.Current -ErrorMessage $record.Error -ObservationError $record.ObservationError
            }
            $failure.Exception.Data['KB5130098FleetReport'] = $summaryFile
            $rows = @(ConvertTo-KBReportRows -Records @($results.ToArray()) -RunId $context.RunId -DetailReportPath $summaryFile)
            $failure.Exception.Data['KB5130098ReportRows'] = $rows
            $files = Save-KBReportExports -Context $context -Records @($results.ToArray()) -Rows $rows -NoCsv:$NoCsv
            $failure.Exception.Data['KB5130098ReportFiles'] = $files
            throw $failure
        } finally {
            try { Write-KBFleetReport -Path $summaryFile -Records @($results.ToArray()) }
            finally { if ($null -ne $session) { Remove-PSSession -Session $session } }
        }
    }
    $exitCode = 0
    $status = 'Completed'
    if ($Mode -eq 'Apply' -and -not $RestartSearch) { $exitCode=10; $status='FilesStagedRestartRequired' }
    elseif (@($results | Where-Object { $_.Current.Status -in 'NotApplicableStop', 'RuleFilesPresentStop' }).Count -gt 0 -and $Mode -eq 'Detect') {
        $exitCode=20; $status='ReviewRequired'
    }
    $rows = @(ConvertTo-KBReportRows -Records @($results.ToArray()) -RunId $context.RunId -DetailReportPath $summaryFile)
    $files = Save-KBReportExports -Context $context -Records @($results.ToArray()) -Rows $rows -NoCsv:$NoCsv
    [pscustomobject]@{
        Mode=$Mode; Status=$status; ExitCode=$exitCode; Report=$summaryFile
        Servers=$results.Count; TargetCount=$targets.Count; Targets=$targets; Results=@($results.ToArray())
        ReportData=$rows; ExportFiles=$files
    }
}

Export-ModuleMember -Function Get-KBSpecification, Assert-KBAdministrator, Assert-KBLocalWritePath, Assert-KBIdentity, Assert-KBPayload, Invoke-KBLocal, Invoke-KBAutoElevation, Write-KBConsoleResult, Invoke-KBFleet, New-KBReportContext, ConvertTo-KBReportRows, Save-KBReportExports, Write-KBReportSummary
