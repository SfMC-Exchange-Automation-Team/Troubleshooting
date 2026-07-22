Set-StrictMode -Version 2.0

function ConvertTo-EpoBooleanLikeString {
    param([object] $Value)
    if ($null -eq $Value) { return 'Unknown' }
    return [string] $Value
}

function ConvertFrom-EpoDotNetRelease {
    param([Nullable[int]] $Release)

    if ($null -eq $Release) { return 'Unknown' }
    if ($Release -ge 533320) { return '4.8.1 or later' }
    if ($Release -ge 528040) { return '4.8' }
    if ($Release -ge 461808) { return '4.7.2' }
    if ($Release -ge 461308) { return '4.7.1' }
    if ($Release -ge 460798) { return '4.7' }
    if ($Release -ge 394802) { return '4.6.2' }
    if ($Release -ge 394254) { return '4.6.1' }
    if ($Release -ge 393295) { return '4.6' }
    if ($Release -ge 379893) { return '4.5.2' }
    if ($Release -ge 378675) { return '4.5.1' }
    if ($Release -ge 378389) { return '4.5' }
    return 'Earlier than 4.5 or not detected'
}

function Get-EpoLocalDotNetReadiness {
    [CmdletBinding()]
    param(
        [string] $ServerName = $env:COMPUTERNAME,
        [int] $MinimumRelease = 528040,
        [string] $MinimumVersion = '4.8',
        [bool] $EnableDotNetAcceleration = $false
    )

    $RegistryPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    $Release = $null
    $Install = $null
    $ErrorMessage = ''
    try {
        $Item = Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
        if ($Item.PSObject.Properties['Release']) { $Release = [int] $Item.Release }
        if ($Item.PSObject.Properties['Install']) { $Install = [int] $Item.Install }
    }
    catch {
        $ErrorMessage = $_.Exception.Message
    }

    $DetectedVersion = ConvertFrom-EpoDotNetRelease -Release $Release
    $IsInstalled = ($Install -eq 1) -or ($null -ne $Release)
    $IsCompatible = $IsInstalled -and ($null -ne $Release) -and ($Release -ge $MinimumRelease)
    $Status = if ($IsCompatible) { 'Pass' } elseif ($IsInstalled) { 'Blocked' } else { 'Blocked' }
    $Severity = if ($IsCompatible) { 'Info' } else { 'Critical' }

    [pscustomobject] @{
        Server = $ServerName
        Status = $Status
        Severity = $Severity
        IsInstalled = [bool] $IsInstalled
        IsCompatible = [bool] $IsCompatible
        Release = if ($null -eq $Release) { '' } else { [string] $Release }
        DetectedVersion = $DetectedVersion
        MinimumRelease = $MinimumRelease
        MinimumVersion = $MinimumVersion
        RegistryPath = $RegistryPath
        Error = $ErrorMessage
        Acceleration = [pscustomobject] @{
            Requested = [bool] $EnableDotNetAcceleration
            Status = 'Placeholder'
            Message = 'Future feature placeholder: accelerate .NET assembly compilation after setup readiness rules are finalized.'
        }
    }
}

function Get-EpoDotNetReadiness {
    [CmdletBinding()]
    param(
        [string] $ServerName = $env:COMPUTERNAME,
        [int] $MinimumRelease = 528040,
        [string] $MinimumVersion = '4.8',
        [bool] $EnableDotNetAcceleration = $false
    )

    if ($ServerName -in @($env:COMPUTERNAME, 'localhost', '.', $env:COMPUTERNAME.ToLowerInvariant())) {
        return Get-EpoLocalDotNetReadiness -ServerName $env:COMPUTERNAME -MinimumRelease $MinimumRelease -MinimumVersion $MinimumVersion -EnableDotNetAcceleration $EnableDotNetAcceleration
    }

    try {
        Invoke-Command -ComputerName $ServerName -ScriptBlock {
            param($RemoteServerName, $RemoteMinimumRelease, $RemoteMinimumVersion, $RemoteAcceleration, $FunctionText)
            Invoke-Expression $FunctionText
            Get-EpoLocalDotNetReadiness -ServerName $RemoteServerName -MinimumRelease $RemoteMinimumRelease -MinimumVersion $RemoteMinimumVersion -EnableDotNetAcceleration $RemoteAcceleration
        } -ArgumentList $ServerName, $MinimumRelease, $MinimumVersion, $EnableDotNetAcceleration, ((${function:ConvertFrom-EpoDotNetRelease}.ToString()) + "`n" + (${function:Get-EpoLocalDotNetReadiness}.ToString()))
    }
    catch {
        [pscustomobject] @{
            Server = $ServerName
            Status = 'Blocked'
            Severity = 'Critical'
            IsInstalled = $false
            IsCompatible = $false
            Release = ''
            DetectedVersion = 'Unknown'
            MinimumRelease = $MinimumRelease
            MinimumVersion = $MinimumVersion
            RegistryPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
            Error = $_.Exception.Message
            Acceleration = [pscustomobject] @{
                Requested = [bool] $EnableDotNetAcceleration
                Status = 'Placeholder'
                Message = 'Future feature placeholder: accelerate .NET assembly compilation after setup readiness rules are finalized.'
            }
        }
    }
}

function Invoke-EpoPreflightCheck {
    [CmdletBinding()]
    param(
        [string[]] $ServerName = @($env:COMPUTERNAME),
        [Parameter(Mandatory)] [string] $PendingRebootScriptPath,
        [switch] $EnablePendingRebootFallback,
        [switch] $IncludeSccmRebootState,
        [bool] $BlockOnPendingReboot = $true,
        [bool] $BlockOnUnknownRebootState = $true,
        [int] $DotNetMinimumRelease = 528040,
        [string] $DotNetMinimumVersion = '4.8',
        [bool] $BlockOnIncompatibleDotNet = $true,
        [bool] $EnableDotNetAcceleration = $false
    )

    if (-not (Test-Path -LiteralPath $PendingRebootScriptPath)) {
        throw "Pending reboot script was not found: $PendingRebootScriptPath"
    }

    . $PendingRebootScriptPath
    if (-not (Get-Command Get-PendingReboot -ErrorAction SilentlyContinue)) {
        throw "Get-PendingReboot was not loaded from $PendingRebootScriptPath"
    }

    $Servers = New-Object System.Collections.Generic.List[object]
    foreach ($Server in $ServerName) {
        $Target = if ([string]::IsNullOrWhiteSpace($Server)) { $env:COMPUTERNAME } else { $Server }
        try {
            $Args = @{
                ComputerName = $Target
                Detailed = $true
            }
            if ($EnablePendingRebootFallback) { $Args.EnableFallback = $true }
            if ($IncludeSccmRebootState) { $Args.IncludeSccm = $true }

            $Pending = Get-PendingReboot @Args | Select-Object -First 1
            $RebootRequired = ConvertTo-EpoBooleanLikeString -Value $Pending.RebootRequired
            $Blocked = ($BlockOnPendingReboot -and $RebootRequired -eq 'True') -or ($BlockOnUnknownRebootState -and $RebootRequired -eq 'Unknown')
            $DotNet = Get-EpoDotNetReadiness -ServerName $Target -MinimumRelease $DotNetMinimumRelease -MinimumVersion $DotNetMinimumVersion -EnableDotNetAcceleration $EnableDotNetAcceleration
            $DotNetBlocked = $BlockOnIncompatibleDotNet -and -not [bool] $DotNet.IsCompatible
            $ServerBlocked = $Blocked -or $DotNetBlocked
            $Severity = if ($ServerBlocked) { 'Critical' } elseif ($RebootRequired -eq 'False') { 'Info' } else { 'Warning' }
            $Status = if ($ServerBlocked) { 'Blocked' } elseif ($RebootRequired -eq 'False') { 'Pass' } else { 'Warning' }

            $Servers.Add([pscustomobject] @{
                Server = $Target
                Status = $Status
                Severity = $Severity
                Blocked = [bool] $ServerBlocked
                PendingReboot = [pscustomobject] @{
                    ComputerName = [string] $Pending.ComputerName
                    RebootRequired = $RebootRequired
                    RegistryPending = ConvertTo-EpoBooleanLikeString -Value $Pending.RegistryPending
                    CbsRebootPending = ConvertTo-EpoBooleanLikeString -Value $Pending.CbsRebootPending
                    WindowsUpdateRebootRequired = ConvertTo-EpoBooleanLikeString -Value $Pending.WindowsUpdateRebootRequired
                    ComputerRenamePending = ConvertTo-EpoBooleanLikeString -Value $Pending.ComputerRenamePending
                    PendingXmlPresent = ConvertTo-EpoBooleanLikeString -Value $Pending.PendingXmlPresent
                    SccmClientRebootPending = ConvertTo-EpoBooleanLikeString -Value $Pending.SccmClientRebootPending
                    ConnectionMethod = [string] $Pending.ConnectionMethod
                    RemoteConnectionFailed = [bool] $Pending.RemoteConnectionFailed
                    RemoteConnectionFailureClass = [string] $Pending.RemoteConnectionFailureClass
                    RemoteConnectionFailureReason = [string] $Pending.RemoteConnectionFailureReason
                }
                DotNet = $DotNet
            })
        }
        catch {
            $Servers.Add([pscustomobject] @{
                Server = $Target
                Status = 'Blocked'
                Severity = 'Critical'
                Blocked = $true
                PendingReboot = [pscustomobject] @{
                    ComputerName = $Target
                    RebootRequired = 'Unknown'
                    RegistryPending = 'Unknown'
                    CbsRebootPending = 'Unknown'
                    WindowsUpdateRebootRequired = 'Unknown'
                    ComputerRenamePending = 'Unknown'
                    PendingXmlPresent = 'Unknown'
                    SccmClientRebootPending = 'Unknown'
                    ConnectionMethod = 'None'
                    RemoteConnectionFailed = $true
                    RemoteConnectionFailureClass = 'PreflightException'
                    RemoteConnectionFailureReason = $_.Exception.Message
                }
                DotNet = [pscustomobject] @{
                    Status = 'Blocked'
                    Severity = 'Critical'
                    IsInstalled = $false
                    IsCompatible = $false
                    Release = ''
                    DetectedVersion = 'Unknown'
                    MinimumRelease = $DotNetMinimumRelease
                    MinimumVersion = $DotNetMinimumVersion
                    Error = $_.Exception.Message
                    Acceleration = [pscustomobject] @{
                        Requested = [bool] $EnableDotNetAcceleration
                        Status = 'Placeholder'
                        Message = 'Future feature placeholder: accelerate .NET assembly compilation after setup readiness rules are finalized.'
                    }
                }
            })
        }
    }

    $BlockedServers = @($Servers.ToArray() | Where-Object { $_.Blocked })
    $WarningServers = @($Servers.ToArray() | Where-Object { $_.Status -eq 'Warning' })
    [pscustomobject] @{
        PreflightSchemaVersion = '1.0'
        CollectedAtUtc = [datetime]::UtcNow.ToString('o')
        Status = if ($BlockedServers.Count) { 'Blocked' } elseif ($WarningServers.Count) { 'Warning' } else { 'Pass' }
        Severity = if ($BlockedServers.Count) { 'Critical' } elseif ($WarningServers.Count) { 'Warning' } else { 'Info' }
        Checks = @('PendingReboot', 'DotNetReadiness', 'DotNetAccelerationPlaceholder')
        Servers = @($Servers.ToArray())
    }
}

function Export-EpoPreflightCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $RunContext,
        [Parameter(Mandatory)] [pscustomobject] $Preflight
    )

    $Path = Join-Path $RunContext.EvidencePath 'Preflight.csv'
    $Rows = foreach ($ServerPreflight in $Preflight.Servers) {
        [pscustomobject] @{
            CorrelationId = $RunContext.CorrelationId
            Server = $ServerPreflight.Server
            Status = $ServerPreflight.Status
            Severity = $ServerPreflight.Severity
            Blocked = $ServerPreflight.Blocked
            RebootRequired = $ServerPreflight.PendingReboot.RebootRequired
            RegistryPending = $ServerPreflight.PendingReboot.RegistryPending
            CbsRebootPending = $ServerPreflight.PendingReboot.CbsRebootPending
            WindowsUpdateRebootRequired = $ServerPreflight.PendingReboot.WindowsUpdateRebootRequired
            ComputerRenamePending = $ServerPreflight.PendingReboot.ComputerRenamePending
            PendingXmlPresent = $ServerPreflight.PendingReboot.PendingXmlPresent
            SccmClientRebootPending = $ServerPreflight.PendingReboot.SccmClientRebootPending
            ConnectionMethod = $ServerPreflight.PendingReboot.ConnectionMethod
            RemoteConnectionFailed = $ServerPreflight.PendingReboot.RemoteConnectionFailed
            RemoteConnectionFailureReason = $ServerPreflight.PendingReboot.RemoteConnectionFailureReason
            DotNetStatus = $ServerPreflight.DotNet.Status
            DotNetCompatible = $ServerPreflight.DotNet.IsCompatible
            DotNetRelease = $ServerPreflight.DotNet.Release
            DotNetVersion = $ServerPreflight.DotNet.DetectedVersion
            DotNetMinimumVersion = $ServerPreflight.DotNet.MinimumVersion
            DotNetAccelerationStatus = $ServerPreflight.DotNet.Acceleration.Status
        }
    }
    $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

Export-ModuleMember -Function Invoke-EpoPreflightCheck, Export-EpoPreflightCsv
