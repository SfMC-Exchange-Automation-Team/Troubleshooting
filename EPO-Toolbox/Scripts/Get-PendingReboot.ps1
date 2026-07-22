function Get-PendingReboot {
<#
.SYNOPSIS
Checks Windows computers for pending reboot indicators and returns a structured result.

.DESCRIPTION
UNSUPPORTED SCRIPT DISCLAIMER:
PowerShell function provided is an unsupported script. It is not an official Microsoft product and is not covered by Microsoft Support.
Use at your own risk. Validate in a lab. Follow your change management and maintenance window processes before production use.

Core indicators checked:
- Registry value: HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations
- Registry key:   HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending
- Registry key:   HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired
- Registry values: pending computer name differs from active computer name
- File:           $env:windir\WinSxS\pending.xml

Remote checks rely on PowerShell Remoting (WinRM) by default.
Optional fallback checks can be enabled via -EnableFallback to attempt:
- Remote Registry (OpenRemoteBaseKey) for registry-based indicators
- ADMIN$ share for pending.xml

.PARAMETER ComputerName
Target computer name(s). Accepts pipeline input.
Aliases: Server, Name, Computer, CN.

.PARAMETER Restart
Restart computers when a pending reboot is detected. Supports -WhatIf and -Confirm.
Alias: Prompt.

.PARAMETER Detailed
Expand the default output view to include reboot indicators and connection failure details.

.PARAMETER EnableFallback
When WinRM fails, attempt fallback checks using Remote Registry and ADMIN$ share.

.PARAMETER IncludeSccm
Also query the Configuration Manager client reboot state when available. This is opt-in because many servers do not have the SCCM client namespace.

.PARAMETER SetGlobalStatus
Set legacy global variables $global:RebootRequired and $global:RemoteConnectionFailed after the command completes.

.OUTPUTS
[pscustomobject] with:
ComputerName
RebootRequired                (True|False|Unknown)
RegistryPending               (True|False|Unknown)
CbsRebootPending              (True|False|Unknown)
WindowsUpdateRebootRequired   (True|False|Unknown)
ComputerRenamePending         (True|False|Unknown)
PendingXmlPresent             (True|False|Unknown)
SccmClientRebootPending       (True|False|Unknown|NotChecked)
ConnectionMethod              (Local|WinRM|Fallback|None)
RemoteConnectionFailed        (bool)
RemoteConnectionFailureClass  (string|null)
RemoteConnectionFailureReason (string|null)

.EXAMPLE
Get-PendingReboot
Checks the local computer and shows ComputerName and RebootRequired.

.EXAMPLE
Get-PendingReboot -Detailed
Shows the indicator columns by default.

.EXAMPLE
'EXCH01' | Get-PendingReboot | Select-Object ComputerName, RebootRequired
Checks a computer via pipeline input and returns results.

.EXAMPLE
Get-PendingReboot -ComputerName EXCH01 -Restart -Confirm -Detailed
Expanded output and PowerShell-native restart confirmation when reboot is required.

.NOTES
Author: Cullen Haafke
Organization: Microsoft (SfMC)
Compatibility: Windows PowerShell 5.1
Version: 2.0.3-Scout
History:
01/28/2026 - 1.0.0 - Initial release (PendingFileRenameOperations + pending.xml)
01/29/2026 - 1.0.1 - Single remote hop + fallback option + tri-state propagation fixes
01/29/2026 - 1.0.2 - Treat Test-Path access denied as Unknown (terminating) + do not hard-fail DNS precheck
02/24/2026 - 1.0.3 - Rename Server to ComputerName + default view is root result, add -Detailed for expanded view
02/24/2026 - 1.1.0 - Remove -ShowStatus, and show RemoteConnectionDenied* fields only in default view when -Detailed is used
06/17/2026 - 2.0.0-Scout - Add broader indicators, safer restart semantics, improved local detection, fallback fixes, and opt-in legacy globals
07/22/2026 - 2.0.1-Scout - Fix ordered result updates so detected signals are returned instead of Unknown
07/22/2026 - 2.0.2-Scout - Show remote connection failure reason in the default output
07/22/2026 - 2.0.3-Scout - Split generic WinRM auth/trust/config failures into more specific reasons when exposed by WinRM
#>

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Computer','CN','Server','Name')]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [Alias('Prompt')]
        [switch]$Restart,

        [switch]$Detailed,
        [switch]$EnableFallback,
        [switch]$IncludeSccm,
        [switch]$SetGlobalStatus
    )

    begin {
        $script:anyRebootRequired = $false
        $script:anyRemoteFailed   = $false

        function Set-DefaultDisplay {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [psobject]$Object,

                [Parameter(Mandatory = $true)]
                [string[]]$PropertyNames
            )

            $displaySet = New-Object System.Management.Automation.PSPropertySet('DefaultDisplayPropertySet', $PropertyNames)
            $psStandard = New-Object System.Management.Automation.PSMemberInfo[] (1)
            $psStandard[0] = $displaySet

            Add-Member -InputObject $Object -MemberType MemberSet -Name PSStandardMembers -Value $psStandard -Force
            return $Object
        }

        function Finalize-ResultObject {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [System.Collections.IDictionary]$Result,

                [Parameter(Mandatory = $true)]
                [bool]$DetailedMode
            )

            $final = [pscustomobject]$Result
            $defaultProps = @('ComputerName','RebootRequired')

            if ($final.RemoteConnectionFailed -eq $true) {
                $defaultProps += @('RemoteConnectionFailed','RemoteConnectionFailureReason')
            }

            if ($DetailedMode) {
                $defaultProps += @(
                    'RegistryPending',
                    'CbsRebootPending',
                    'WindowsUpdateRebootRequired',
                    'ComputerRenamePending',
                    'PendingXmlPresent',
                    'SccmClientRebootPending',
                    'ConnectionMethod',
                    'RemoteConnectionFailureClass',
                    'RemoteConnectionFailureReason'
                )
            }

            return (Set-DefaultDisplay -Object $final -PropertyNames $defaultProps)
        }

        function Convert-ToTriStateString {
            param([object]$Value)

            if ($null -eq $Value) { return 'Unknown' }
            if ($Value -eq $true) { return 'True' }
            if ($Value -eq $false) { return 'False' }
            return [string]$Value
        }

        function Resolve-RebootRequiredTriState {
            param(
                [Parameter(Mandatory = $true)]
                [object[]]$Signals
            )

            $hasUnknown = $false

            foreach ($signal in $Signals) {
                if ($signal -eq $true) { return $true }
                if ($null -eq $signal) { $hasUnknown = $true }
            }

            if ($hasUnknown) { return $null }
            return $false
        }

        function Test-IsLocalTarget {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Target
            )

            if ([string]::IsNullOrWhiteSpace($Target)) { return $false }

            $normalizedTarget = $Target.Trim()
            if ($normalizedTarget -eq '.' -or $normalizedTarget -ieq 'localhost') { return $true }
            if ($normalizedTarget -ieq $env:COMPUTERNAME) { return $true }

            try {
                $localHost = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName())
                if ($normalizedTarget -ieq $localHost.HostName) { return $true }
                if (($localHost.Aliases | Where-Object { $_ -ieq $normalizedTarget }).Count -gt 0) { return $true }

                $localNames = @($env:COMPUTERNAME, $localHost.HostName)
                foreach ($name in $localNames) {
                    if ($name -and $name.Contains('.')) {
                        $shortName = $name.Split('.')[0]
                        if ($normalizedTarget -ieq $shortName) { return $true }
                    }
                }

                $targetHost = [System.Net.Dns]::GetHostEntry($normalizedTarget)
                if ($targetHost.HostName -ieq $localHost.HostName) { return $true }

                $localAddresses = @($localHost.AddressList | ForEach-Object { $_.IPAddressToString })
                foreach ($address in $targetHost.AddressList) {
                    if ([System.Net.IPAddress]::IsLoopback($address)) { return $true }
                    if ($localAddresses -contains $address.IPAddressToString) { return $true }
                }
            }
            catch {
                Write-Verbose ("Local target detection could not fully resolve {0}: {1}" -f $Target, $_.Exception.Message)
            }

            return $false
        }

        function Get-RemotingFailureInfo {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [System.Management.Automation.ErrorRecord]$ErrorRecord
            )

            $msg  = $ErrorRecord.Exception.Message
            $fqid = $ErrorRecord.FullyQualifiedErrorId
            $details = "{0}`n{1}" -f $msg, $fqid

            $info = [pscustomobject]@{
                Class  = 'Unknown'
                Reason = 'Remoting failed (unclassified)'
                FQID   = $fqid
                Raw    = (($ErrorRecord | Out-String).Trim())
            }

            if ($msg -match 'No such host is known|Name or service not known|network path was not found|computer name is not valid') {
                $info.Class  = 'NameResolutionOrBadTarget'
                $info.Reason = 'Name resolution failed or target invalid'
                return $info
            }

            if ($msg -match 'WinRM cannot complete the operation|2150859046') {
                $info.Class  = 'ConnectionBlocked'
                $info.Reason = 'WinRM unreachable (blocked firewall, service, or network)'
                return $info
            }

            if ($msg -match 'The connection to the remote host was refused') {
                $info.Class  = 'ConnectionRefused'
                $info.Reason = 'Remote host refused WSMan / WinRM connection'
                return $info
            }

            if ($details -match 'TrustedHosts|destination computer.*TrustedHosts|HTTPS transport must be used|client computer is not joined to a domain') {
                $info.Class  = 'ClientTrustConfiguration'
                $info.Reason = 'Client trust configuration issue (TrustedHosts or HTTPS required)'
                return $info
            }

            if ($details -match 'Kerberos|SPN|mutual authentication|target principal name is incorrect|0x80090322') {
                $info.Class  = 'KerberosAuthentication'
                $info.Reason = 'Kerberos authentication issue (SPN, target name, or domain trust)'
                return $info
            }

            if ($details -match '0x8009030e|logon session does not exist|credentials were not supplied|explicit credentials') {
                $info.Class  = 'CredentialAuthentication'
                $info.Reason = 'Credential authentication issue (missing, invalid, or non-delegable credentials)'
                return $info
            }

            if ($details -match 'Default authentication.*IP address|IP address.*TrustedHosts|cannot use IP address') {
                $info.Class  = 'ClientAuthConfiguration'
                $info.Reason = 'Client authentication configuration issue (IP targets require HTTPS or TrustedHosts)'
                return $info
            }

            if ($details -match 'Access is denied|Unauthorized|0x80070005') {
                $info.Class  = 'AccessDenied'
                $info.Reason = 'Access denied (permissions or authorization)'
                return $info
            }

            if ($details -match 'The WinRM client cannot process the request|authentication') {
                $info.Class  = 'WinRMClientConfiguration'
                $info.Reason = 'WinRM client configuration or authentication issue (specific cause not exposed by WinRM)'
                return $info
            }

            if ($msg -match 'timed out|timeout') {
                $info.Class  = 'Timeout'
                $info.Reason = 'WinRM connection timed out'
                return $info
            }

            if ($fqid -match 'PSSessionOpenFailed|CannotConnect|WsManError|WinRM') {
                $info.Class  = 'SessionOpenFailed'
                $info.Reason = 'Failed to open WSMan / WinRM session'
                return $info
            }

            return $info
        }

        function Test-PendingFileRenameOperations {
            [CmdletBinding()]
            param()

            try {
                $regValue = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop).PendingFileRenameOperations
                if ($null -eq $regValue) { return $false }
                return (@($regValue).Count -gt 0)
            }
            catch {
                Write-Verbose ("PendingFileRenameOperations check failed: {0}" -f $_.Exception.Message)
                return $null
            }
        }

        function Test-RegistryKeyExists {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Path,

                [Parameter(Mandatory = $true)]
                [string]$Name
            )

            try {
                return (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)
            }
            catch {
                Write-Verbose ("{0} check failed: {1}" -f $Name, $_.Exception.Message)
                return $null
            }
        }

        function Test-ComputerRenamePending {
            [CmdletBinding()]
            param()

            try {
                $active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
                $pending = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName

                if ([string]::IsNullOrWhiteSpace($active) -or [string]::IsNullOrWhiteSpace($pending)) {
                    return $null
                }

                return ($active -ine $pending)
            }
            catch {
                Write-Verbose ("Computer rename check failed: {0}" -f $_.Exception.Message)
                return $null
            }
        }

        function Test-PendingXmlPresent {
            [CmdletBinding()]
            param()

            try {
                $xmlPath = Join-Path -Path $env:windir -ChildPath 'WinSxS\pending.xml'
                return (Test-Path -LiteralPath $xmlPath -PathType Leaf -ErrorAction Stop)
            }
            catch {
                Write-Verbose ("pending.xml check failed: {0}" -f $_.Exception.Message)
                return $null
            }
        }

        function Test-SccmClientRebootPending {
            [CmdletBinding()]
            param()

            try {
                $result = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
                return (($result.RebootPending -eq $true) -or ($result.IsHardRebootPending -eq $true))
            }
            catch {
                Write-Verbose ("SCCM reboot check failed or SCCM client namespace is unavailable: {0}" -f $_.Exception.Message)
                return $null
            }
        }

        function Invoke-LocalPendingRebootSignals {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [bool]$IncludeSccmCheck
            )

            $registryPending = Test-PendingFileRenameOperations
            $cbsPending = Test-RegistryKeyExists -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -Name 'Component Based Servicing RebootPending'
            $wuPending = Test-RegistryKeyExists -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -Name 'Windows Update RebootRequired'
            $renamePending = Test-ComputerRenamePending
            $xmlPending = Test-PendingXmlPresent
            $sccmPending = 'NotChecked'

            $signals = @($registryPending, $cbsPending, $wuPending, $renamePending, $xmlPending)

            if ($IncludeSccmCheck) {
                $sccmPending = Test-SccmClientRebootPending
                $signals += $sccmPending
            }

            [pscustomobject]@{
                RegistryPending             = $registryPending
                CbsRebootPending            = $cbsPending
                WindowsUpdateRebootRequired = $wuPending
                ComputerRenamePending       = $renamePending
                PendingXmlPresent           = $xmlPending
                SccmClientRebootPending     = $sccmPending
                RebootRequired              = Resolve-RebootRequiredTriState -Signals $signals
            }
        }

        function Invoke-RestartIfRequested {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Target,

                [Parameter(Mandatory = $true)]
                [bool]$RestartRequested
            )

            if (-not $RestartRequested) { return }

            if ($PSCmdlet.ShouldProcess($Target, 'Restart-Computer -Force')) {
                Restart-Computer -ComputerName $Target -Force -ErrorAction Stop
            }
        }

        function New-BaseResult {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Target
            )

            [ordered]@{
                ComputerName                  = $Target
                RebootRequired                = 'Unknown'
                RegistryPending               = 'Unknown'
                CbsRebootPending              = 'Unknown'
                WindowsUpdateRebootRequired   = 'Unknown'
                ComputerRenamePending         = 'Unknown'
                PendingXmlPresent             = 'Unknown'
                SccmClientRebootPending       = 'NotChecked'
                ConnectionMethod              = 'None'
                RemoteConnectionFailed        = $false
                RemoteConnectionFailureClass  = $null
                RemoteConnectionFailureReason = $null
            }
        }

        function Set-SignalResult {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [System.Collections.IDictionary]$Result,

                [Parameter(Mandatory = $true)]
                [psobject]$Signals
            )

            $Result.RegistryPending             = Convert-ToTriStateString $Signals.RegistryPending
            $Result.CbsRebootPending            = Convert-ToTriStateString $Signals.CbsRebootPending
            $Result.WindowsUpdateRebootRequired = Convert-ToTriStateString $Signals.WindowsUpdateRebootRequired
            $Result.ComputerRenamePending       = Convert-ToTriStateString $Signals.ComputerRenamePending
            $Result.PendingXmlPresent           = Convert-ToTriStateString $Signals.PendingXmlPresent
            $Result.SccmClientRebootPending     = Convert-ToTriStateString $Signals.SccmClientRebootPending
            $Result.RebootRequired              = Convert-ToTriStateString $Signals.RebootRequired
        }

        function Invoke-FallbackPendingRebootSignals {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Target
            )

            $fallbackErrors = @()
            $base = $null
            $sessionManager = $null
            $activeComputerName = $null
            $pendingComputerName = $null

            $registryPending = $null
            $cbsPending = $null
            $wuPending = $null
            $renamePending = $null
            $xmlPending = $null

            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $Target)

                $sessionManager = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager')
                if ($null -eq $sessionManager) {
                    $fallbackErrors += 'RemoteRegistry: Session Manager key not accessible'
                }
                else {
                    $value = $sessionManager.GetValue('PendingFileRenameOperations', $null)
                    $registryPending = ($null -ne $value -and @($value).Count -gt 0)
                }

                $cbsKey = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
                $cbsPending = ($null -ne $cbsKey)
                if ($null -ne $cbsKey) { $cbsKey.Close() }

                $wuKey = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
                $wuPending = ($null -ne $wuKey)
                if ($null -ne $wuKey) { $wuKey.Close() }

                $activeComputerName = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName')
                $pendingComputerName = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName')
                if ($null -ne $activeComputerName -and $null -ne $pendingComputerName) {
                    $active = $activeComputerName.GetValue('ComputerName', $null)
                    $pending = $pendingComputerName.GetValue('ComputerName', $null)
                    if ($null -ne $active -and $null -ne $pending) {
                        $renamePending = ([string]$active -ine [string]$pending)
                    }
                }
                else {
                    $fallbackErrors += 'RemoteRegistry: ComputerName keys not accessible'
                }
            }
            catch {
                $fallbackErrors += ("RemoteRegistry: {0}" -f $_.Exception.Message)
            }
            finally {
                if ($null -ne $pendingComputerName) { $pendingComputerName.Close() }
                if ($null -ne $activeComputerName) { $activeComputerName.Close() }
                if ($null -ne $sessionManager) { $sessionManager.Close() }
                if ($null -ne $base) { $base.Close() }
            }

            try {
                $adminXml = "\\{0}\admin$\WinSxS\pending.xml" -f $Target
                $xmlPending = Test-Path -LiteralPath $adminXml -PathType Leaf -ErrorAction Stop
            }
            catch {
                $fallbackErrors += ("AdminShare: {0}" -f $_.Exception.Message)
            }

            $signals = @($registryPending, $cbsPending, $wuPending, $renamePending, $xmlPending)

            [pscustomobject]@{
                RegistryPending             = $registryPending
                CbsRebootPending            = $cbsPending
                WindowsUpdateRebootRequired = $wuPending
                ComputerRenamePending       = $renamePending
                PendingXmlPresent           = $xmlPending
                SccmClientRebootPending     = 'NotChecked'
                RebootRequired              = Resolve-RebootRequiredTriState -Signals $signals
                Succeeded                   = (($null -ne $registryPending) -or ($null -ne $cbsPending) -or ($null -ne $wuPending) -or ($null -ne $renamePending) -or ($null -ne $xmlPending))
                Errors                      = $fallbackErrors
            }
        }

        function Invoke-PendingRebootCheckSingle {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Target,

                [Parameter(Mandatory = $true)]
                [bool]$RestartInner,

                [Parameter(Mandatory = $true)]
                [bool]$EnableFallbackInner,

                [Parameter(Mandatory = $true)]
                [bool]$DetailedInner,

                [Parameter(Mandatory = $true)]
                [bool]$IncludeSccmInner
            )

            $result = New-BaseResult -Target $Target
            $isLocal = Test-IsLocalTarget -Target $Target

            if ($isLocal) {
                Write-Verbose ("Running local pending reboot checks on {0}" -f $Target)
                $signals = Invoke-LocalPendingRebootSignals -IncludeSccmCheck:$IncludeSccmInner
                Set-SignalResult -Result $result -Signals $signals
                $result.ConnectionMethod = 'Local'

                if ($signals.RebootRequired -eq $true) {
                    $script:anyRebootRequired = $true
                    Invoke-RestartIfRequested -Target $Target -RestartRequested:$RestartInner
                }

                return (Finalize-ResultObject -Result $result -DetailedMode:$DetailedInner)
            }

            try {
                Write-Verbose ("Running WinRM pending reboot checks on {0}" -f $Target)

                $payload = Invoke-Command -ComputerName $Target -ErrorAction Stop -ArgumentList $IncludeSccmInner -ScriptBlock {
                    param([bool]$IncludeSccmCheck)

                    function Convert-ToTriState {
                        param([object]$Value)
                        if ($null -eq $Value) { return $null }
                        if ($Value -eq $true) { return $true }
                        return $false
                    }

                    function Resolve-RebootState {
                        param([object[]]$Signals)
                        $hasUnknown = $false
                        foreach ($signal in $Signals) {
                            if ($signal -eq $true) { return $true }
                            if ($null -eq $signal) { $hasUnknown = $true }
                        }
                        if ($hasUnknown) { return $null }
                        return $false
                    }

                    function Test-Key {
                        param([string]$Path)
                        try {
                            return (Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)
                        }
                        catch {
                            return $null
                        }
                    }

                    try {
                        $regValue = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop).PendingFileRenameOperations
                        $registryPending = ($null -ne $regValue -and @($regValue).Count -gt 0)
                    }
                    catch {
                        $registryPending = $null
                    }

                    $cbsPending = Test-Key -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                    $wuPending = Test-Key -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

                    try {
                        $active = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
                        $pending = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
                        if ([string]::IsNullOrWhiteSpace($active) -or [string]::IsNullOrWhiteSpace($pending)) {
                            $renamePending = $null
                        }
                        else {
                            $renamePending = ($active -ine $pending)
                        }
                    }
                    catch {
                        $renamePending = $null
                    }

                    try {
                        $xmlPath = Join-Path -Path $env:windir -ChildPath 'WinSxS\pending.xml'
                        $xmlPending = Test-Path -LiteralPath $xmlPath -PathType Leaf -ErrorAction Stop
                    }
                    catch {
                        $xmlPending = $null
                    }

                    $sccmPending = 'NotChecked'
                    $signals = @($registryPending, $cbsPending, $wuPending, $renamePending, $xmlPending)

                    if ($IncludeSccmCheck) {
                        try {
                            $sccmResult = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
                            $sccmPending = (($sccmResult.RebootPending -eq $true) -or ($sccmResult.IsHardRebootPending -eq $true))
                        }
                        catch {
                            $sccmPending = $null
                        }

                        $signals += $sccmPending
                    }

                    [pscustomobject]@{
                        RegistryPending             = Convert-ToTriState $registryPending
                        CbsRebootPending            = Convert-ToTriState $cbsPending
                        WindowsUpdateRebootRequired = Convert-ToTriState $wuPending
                        ComputerRenamePending       = Convert-ToTriState $renamePending
                        PendingXmlPresent           = Convert-ToTriState $xmlPending
                        SccmClientRebootPending     = $sccmPending
                        RebootRequired              = Resolve-RebootState -Signals $signals
                    }
                }

                Set-SignalResult -Result $result -Signals $payload
                $result.ConnectionMethod = 'WinRM'

                if ($payload.RebootRequired -eq $true) {
                    $script:anyRebootRequired = $true
                    Invoke-RestartIfRequested -Target $Target -RestartRequested:$RestartInner
                }

                return (Finalize-ResultObject -Result $result -DetailedMode:$DetailedInner)
            }
            catch {
                $winrmError = $_
                $failureInfo = Get-RemotingFailureInfo -ErrorRecord $winrmError

                if (-not $EnableFallbackInner) {
                    $result.RemoteConnectionFailed        = $true
                    $result.RemoteConnectionFailureClass  = $failureInfo.Class
                    $result.RemoteConnectionFailureReason = $failureInfo.Reason
                    $script:anyRemoteFailed = $true

                    Write-Verbose ("WinRM failed for {0}. Class={1}. Reason={2}" -f $Target, $failureInfo.Class, $failureInfo.Reason)
                    Write-Debug ("FullyQualifiedErrorId: {0}" -f $failureInfo.FQID)
                    Write-Debug ("Raw error: {0}" -f $failureInfo.Raw)

                    return (Finalize-ResultObject -Result $result -DetailedMode:$DetailedInner)
                }

                Write-Verbose ("WinRM failed for {0} ({1}). Attempting fallback checks." -f $Target, $failureInfo.Class)

                $fallbackSignals = Invoke-FallbackPendingRebootSignals -Target $Target
                Set-SignalResult -Result $result -Signals $fallbackSignals

                if (-not $fallbackSignals.Succeeded) {
                    $result.RemoteConnectionFailed        = $true
                    $result.RemoteConnectionFailureClass  = 'FallbackFailed'
                    $result.RemoteConnectionFailureReason = ("WinRM failed ({0}). Fallback attempts failed: {1}" -f $failureInfo.Class, ($fallbackSignals.Errors -join ' | '))
                    $script:anyRemoteFailed = $true

                    Write-Verbose ("Fallback failed for {0}. {1}" -f $Target, $result.RemoteConnectionFailureReason)

                    return (Finalize-ResultObject -Result $result -DetailedMode:$DetailedInner)
                }

                $result.ConnectionMethod = 'Fallback'
                Write-Verbose ("Fallback succeeded for {0}. RegistryPending={1}, CbsRebootPending={2}, WindowsUpdateRebootRequired={3}, ComputerRenamePending={4}, PendingXmlPresent={5}" -f $Target, $result.RegistryPending, $result.CbsRebootPending, $result.WindowsUpdateRebootRequired, $result.ComputerRenamePending, $result.PendingXmlPresent)

                if ($fallbackSignals.RebootRequired -eq $true) {
                    $script:anyRebootRequired = $true
                    Invoke-RestartIfRequested -Target $Target -RestartRequested:$RestartInner
                }

                return (Finalize-ResultObject -Result $result -DetailedMode:$DetailedInner)
            }
        }
    }

    process {
        foreach ($c in $ComputerName) {
            if ([string]::IsNullOrWhiteSpace($c)) { continue }

            $obj = Invoke-PendingRebootCheckSingle `
                -Target $c `
                -RestartInner:$Restart `
                -EnableFallbackInner:$EnableFallback `
                -DetailedInner:$Detailed `
                -IncludeSccmInner:$IncludeSccm

            if ($obj.RebootRequired -eq 'True') {
                $script:anyRebootRequired = $true
            }

            if ($obj.RemoteConnectionFailed -eq $true) {
                $script:anyRemoteFailed = $true
            }

            $obj
        }
    }

    end {
        if ($SetGlobalStatus) {
            $global:RebootRequired         = $script:anyRebootRequired
            $global:RemoteConnectionFailed = $script:anyRemoteFailed
        }
    }
}
