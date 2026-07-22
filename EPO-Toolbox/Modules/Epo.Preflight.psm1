Set-StrictMode -Version 2.0

function ConvertTo-EpoBooleanLikeString {
    param([object] $Value)
    if ($null -eq $Value) { return 'Unknown' }
    return [string] $Value
}

function Invoke-EpoPreflightCheck {
    [CmdletBinding()]
    param(
        [string[]] $ServerName = @($env:COMPUTERNAME),
        [Parameter(Mandatory)] [string] $PendingRebootScriptPath,
        [switch] $EnablePendingRebootFallback,
        [switch] $IncludeSccmRebootState,
        [bool] $BlockOnPendingReboot = $true,
        [bool] $BlockOnUnknownRebootState = $true
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
            $Severity = if ($Blocked) { 'Critical' } elseif ($RebootRequired -eq 'False') { 'Info' } else { 'Warning' }
            $Status = if ($Blocked) { 'Blocked' } elseif ($RebootRequired -eq 'False') { 'Pass' } else { 'Warning' }

            $Servers.Add([pscustomobject] @{
                Server = $Target
                Status = $Status
                Severity = $Severity
                Blocked = [bool] $Blocked
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
        Checks = @('PendingReboot')
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
        }
    }
    $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

Export-ModuleMember -Function Invoke-EpoPreflightCheck, Export-EpoPreflightCsv
