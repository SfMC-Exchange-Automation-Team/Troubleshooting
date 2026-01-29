function global:Get-PendingReboot {
<#
.SYNOPSIS
Checks Windows computers for pending reboot indicators and returns a structured result.

.DESCRIPTION
UNSUPPORTED SCRIPT DISCLAIMER:
PowerShell function provided is an unsupported script. It is not an official Microsoft product and is not covered by Microsoft Support.
Use at your own risk. Validate in a lab. Follow your change management and maintenance window processes before production use.

Core indicators checked:
- Registry: HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations
- File:    $env:windir\WinSxS\pending.xml

Remote checks rely on PowerShell Remoting (WinRM) by default.
Optional fallback checks can be enabled via -EnableFallback to attempt:
- Remote Registry (OpenRemoteBaseKey) for PendingFileRenameOperations
- ADMIN$ share for pending.xml

.PARAMETER Server
Target computer name(s). Accepts pipeline input.

.PARAMETER Prompt
If reboot is detected, prompt to initiate reboot.

.PARAMETER ShowStatus
Emit console status lines using Write-Host. When running against multiple targets or pipeline input, status output is suppressed to avoid noisy pipelines.

.PARAMETER EnableFallback
When WinRM preflight fails, attempt fallback checks using Remote Registry and ADMIN$ share.

.OUTPUTS
[pscustomobject] with:
Server
RebootRequired              (True|False|Unknown)
RegistryPending             (True|False|Unknown)
PendingXmlPresent           (True|False|Unknown)
RemoteConnectionDenied      (bool)
RemoteConnectionDeniedClass (string|null)
RemoteConnectionDeniedReason(string|null)

.EXAMPLE
Get-PendingReboot
Checks the local computer.

.EXAMPLE
'EXCH01' | Get-PendingReboot | Select Server, RebootRequired
Checks a computer via pipeline input and returns results.

.EXAMPLE
Get-PendingReboot -Server EXCH01 -ShowStatus -Prompt
Interactive mode with status output and optional reboot prompt.

.NOTES
Author: Cullen Haafke
Organization: Microsoft (SfMC)
Compatibility: Windows PowerShell 5.1
Version: 1.0.2
History:
01/28/2026 - 1.0.0 - Initial release (PendingFileRenameOperations + pending.xml)
01/29/2026 - 1.0.1 - Single remote hop + fallback option + tri-state propagation fixes
01/29/2026 - 1.0.2 - Treat Test-Path access denied as Unknown (terminating) + do not hard-fail DNS precheck + gate Write-Host behind -ShowStatus

.LINK
Test-WSMan documentation (WinRM preflight)
Restart-Computer documentation (reboot behavior)
#>

    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('ComputerName','CN','Computer')]
        [string[]]$Server = @($env:COMPUTERNAME),

        [switch]$Prompt,
        [switch]$ShowStatus,
        [switch]$EnableFallback
    )

    begin {
        # Aggregate globals (optional convenience for interactive usage)
        $script:anyRebootRequired = $false
        $script:anyRemoteDenied   = $false

        function Get-RemotingFailureInfo {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [System.Management.Automation.ErrorRecord]$ErrorRecord
            )

            $msg  = $ErrorRecord.Exception.Message
            $fqid = $ErrorRecord.FullyQualifiedErrorId

            $info = [pscustomobject]@{
                Class  = 'Unknown'
                Reason = 'Remoting failed (unclassified)'
                FQID   = $fqid
                Raw    = (($ErrorRecord | Out-String).Trim())
            }

            # Soft failures (Yellow)
            if ($msg -match 'No such host is known|Name or service not known|network path was not found|computer name is not valid') {
                $info.Class  = 'NameResolutionOrBadTarget'
                $info.Reason = 'Name resolution failed or target invalid'
                return $info
            }

            # Blocked failures (Red)
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

            if ($msg -match 'The WinRM client cannot process the request') {
                $info.Class  = 'WinRMClientCannotProcess'
                $info.Reason = 'WinRM client cannot process request (auth, trust, config)'
                return $info
            }

            if ($msg -match 'Access is denied|Unauthorized|0x80070005') {
                $info.Class  = 'AccessDenied'
                $info.Reason = 'Access denied (permissions or authorization)'
                return $info
            }

            if ($msg -match 'Kerberos|TrustedHosts|0x8009030e|logon session does not exist|authentication') {
                $info.Class  = 'AuthOrTrustConfig'
                $info.Reason = 'Authentication or trust configuration issue (Kerberos, TrustedHosts, HTTPS)'
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

        function Write-StatusLine {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$ServerName,

                [Parameter(Mandatory = $true)]
                [string]$StateClass,

                [Parameter(Mandatory = $true)]
                [string]$Message,

                [switch]$Suppress
            )

            if ($Suppress) { return }

            $isSoft = ($StateClass -eq 'NameResolutionOrBadTarget')
            $color  = if ($isSoft) { 'Yellow' } else { 'Red' }

            Write-Host ("Remoting {0} {1} {2}" -f $ServerName.ToUpper(), $StateClass, $Message) -ForegroundColor $color
        }

        function Set-RemoteDeniedState {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$ServerName,

                [Parameter(Mandatory = $true)]
                $FailureInfo,

                [switch]$SuppressStatus
            )

            $script:anyRemoteDenied = $true

            Write-StatusLine -ServerName $ServerName -StateClass $FailureInfo.Class -Message $FailureInfo.Reason -Suppress:$SuppressStatus

            Write-Verbose ("Remoting failure classification: {0}" -f $FailureInfo.Class)
            Write-Verbose ("FullyQualifiedErrorId: {0}" -f $FailureInfo.FQID)
            Write-Verbose ("Raw error: {0}" -f $FailureInfo.Raw)
        }

        function Convert-ToTriStateString {
            param([Nullable[bool]]$Value)
            if ($null -eq $Value) { return 'Unknown' }
            if ($Value) { return 'True' }
            return 'False'
        }

        function Resolve-RebootRequiredTriState {
            param(
                [Nullable[bool]]$RegistryPending,
                [Nullable[bool]]$PendingXmlPresent
            )

            # Rule:
            # - If any known signal is True => True
            # - Else if all signals are known and False => False
            # - Else => Unknown
            if ($RegistryPending -eq $true -or $PendingXmlPresent -eq $true) { return $true }

            $allKnown = ($null -ne $RegistryPending) -and ($null -ne $PendingXmlPresent)
            if ($allKnown -and $RegistryPending -eq $false -and $PendingXmlPresent -eq $false) { return $false }

            return $null
        }

        function Invoke-PendingRebootCheckSingle {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [string]$Target,

                [Parameter(Mandatory = $true)]
                [bool]$PromptInner,

                [Parameter(Mandatory = $true)]
                [bool]$SuppressStatus,

                [Parameter(Mandatory = $true)]
                [bool]$EnableFallbackInner,

                [Parameter(Mandatory = $true)]
                [bool]$ShowStatusInner
            )

            $result = [ordered]@{
                Server                      = $Target
                RebootRequired              = 'Unknown'
                RegistryPending             = 'Unknown'
                PendingXmlPresent           = 'Unknown'
                RemoteConnectionDenied      = $false
                RemoteConnectionDeniedClass = $null
                RemoteConnectionDeniedReason= $null
            }

            $isLocal = ($Target -ieq $env:COMPUTERNAME)

            # DNS precheck for remote targets
            # Do NOT hard fail on DNS, because WSMan may still succeed via NetBIOS/WINS or alternate resolution paths.
            if (-not $isLocal) {
                try {
                    [void][System.Net.Dns]::GetHostEntry($Target)
                    Write-Verbose ("Name resolution succeeded: {0}" -f $Target)
                }
                catch {
                    Write-Verbose ("Name resolution precheck failed for {0}. Continuing to attempt WinRM/fallback. Error: {1}" -f $Target, $_.Exception.Message)
                }
            }

            # Local check
            if ($isLocal) {
                Write-Verbose ("Running local pending reboot checks on {0}" -f $Target)

                $regPending = $null
                $xmlPending = $null

                try {
                    $regValue = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop).PendingFileRenameOperations
                    $regPending = [bool]($null -ne $regValue)
                }
                catch {
                    Write-Verbose ("Local registry check failed: {0}" -f $_.Exception.Message)
                    $regPending = $null
                }

                try {
                    $xmlPath = Join-Path -Path $env:windir -ChildPath 'WinSxS\pending.xml'
                    $xmlPending = [bool](Test-Path -LiteralPath $xmlPath -PathType Leaf -ErrorAction Stop)
                }
                catch {
                    Write-Verbose ("Local pending.xml check failed: {0}" -f $_.Exception.Message)
                    $xmlPending = $null
                }

                $rebootReq = Resolve-RebootRequiredTriState -RegistryPending $regPending -PendingXmlPresent $xmlPending

                $result.RegistryPending   = Convert-ToTriStateString $regPending
                $result.PendingXmlPresent = Convert-ToTriStateString $xmlPending
                $result.RebootRequired    = Convert-ToTriStateString $rebootReq

                if ($rebootReq -eq $true) {
                    $script:anyRebootRequired = $true

                    if ($ShowStatusInner -and -not $SuppressStatus) {
                        Write-Host ("Pending reboot detected on {0} (Registry: {1}, pending.xml: {2})" -f $Target.ToUpper(), $result.RegistryPending, $result.PendingXmlPresent) -ForegroundColor Yellow
                    }

                    if ($PromptInner -and $PSCmdlet.ShouldProcess($Target, 'Restart-Computer')) {
                        $choice = Read-Host ("Reboot {0}? Y/N" -f $Target)
                        if ($choice -match '^[Yy]$') {
                            Restart-Computer -ComputerName $Target -Force
                        }
                    }
                }
                else {
                    if ($ShowStatusInner -and -not $SuppressStatus) {
                        if ($rebootReq -eq $false) {
                            Write-Host ("No pending reboot detected on {0}" -f $Target.ToUpper()) -ForegroundColor Green
                        }
                        else {
                            Write-Host ("Pending reboot state is Unknown on {0} (insufficient signal data)" -f $Target.ToUpper()) -ForegroundColor Yellow
                        }
                    }
                }

                return [pscustomobject]$result
            }

            # Remote check (1): WinRM preflight + single remote hop for both signals
            try {
                Test-WSMan -ComputerName $Target -ErrorAction Stop | Out-Null
                Write-Verbose ("Test-WSMan succeeded: {0}" -f $Target)

                $payload = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
                    $out = [ordered]@{
                        RegValue         = $null
                        RegError         = $null
                        PendingXmlExists = $null
                        XmlError         = $null
                    }

                    try {
                        $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop).PendingFileRenameOperations
                        $out.RegValue = $v
                    }
                    catch {
                        $out.RegError = $_.Exception.Message
                    }

                    try {
                        $p = Join-Path -Path $env:windir -ChildPath 'WinSxS\pending.xml'
                        $out.PendingXmlExists = [bool](Test-Path -LiteralPath $p -PathType Leaf -ErrorAction Stop)
                    }
                    catch {
                        $out.XmlError = $_.Exception.Message
                    }

                    [pscustomobject]$out
                }

                $regPending = $null
                $xmlPending = $null

                if ($null -ne $payload.RegError -and $payload.RegError) {
                    Write-Verbose ("Remote registry check failed on {0}: {1}" -f $Target, $payload.RegError)
                    $regPending = $null
                }
                else {
                    $regPending = [bool]($null -ne $payload.RegValue)
                }

                if ($null -ne $payload.XmlError -and $payload.XmlError) {
                    Write-Verbose ("Remote pending.xml check failed on {0}: {1}" -f $Target, $payload.XmlError)
                    $xmlPending = $null
                }
                else {
                    $xmlPending = [Nullable[bool]]$payload.PendingXmlExists
                }

                $rebootReq = Resolve-RebootRequiredTriState -RegistryPending $regPending -PendingXmlPresent $xmlPending

                $result.RegistryPending   = Convert-ToTriStateString $regPending
                $result.PendingXmlPresent = Convert-ToTriStateString $xmlPending
                $result.RebootRequired    = Convert-ToTriStateString $rebootReq

                if ($rebootReq -eq $true) {
                    $script:anyRebootRequired = $true

                    if ($ShowStatusInner -and -not $SuppressStatus) {
                        Write-Host ("Pending reboot detected on {0} (Registry: {1}, pending.xml: {2})" -f $Target.ToUpper(), $result.RegistryPending, $result.PendingXmlPresent) -ForegroundColor Yellow
                    }

                    if ($PromptInner -and $PSCmdlet.ShouldProcess($Target, 'Restart-Computer')) {
                        $choice = Read-Host ("Reboot {0}? Y/N" -f $Target)
                        if ($choice -match '^[Yy]$') {
                            Restart-Computer -ComputerName $Target -Force
                        }
                    }
                }
                else {
                    if ($ShowStatusInner -and -not $SuppressStatus) {
                        if ($rebootReq -eq $false) {
                            Write-Host ("No pending reboot detected on {0}" -f $Target.ToUpper()) -ForegroundColor Green
                        }
                        else {
                            Write-Host ("Pending reboot state is Unknown on {0} (insufficient signal data)" -f $Target.ToUpper()) -ForegroundColor Yellow
                        }
                    }
                }

                return [pscustomobject]$result
            }
            catch {
                # WinRM failed. Optional fallback path
                $winrmError = $_
                $fi = Get-RemotingFailureInfo -ErrorRecord $winrmError

                if (-not $EnableFallbackInner) {
                    $result.RemoteConnectionDenied       = $true
                    $result.RemoteConnectionDeniedClass  = $fi.Class
                    $result.RemoteConnectionDeniedReason = $fi.Reason
                    if ($ShowStatusInner) {
                        Set-RemoteDeniedState -ServerName $Target -FailureInfo $fi -SuppressStatus:$SuppressStatus
                    }
                    return [pscustomobject]$result
                }

                Write-Verbose ("WinRM failed for {0} ({1}). Attempting fallback checks." -f $Target, $fi.Class)

                $fallbackRegPending = $null
                $fallbackXmlPending = $null
                $fallbackErrors     = @()

                # Fallback 1: Remote Registry for PendingFileRenameOperations
                try {
                    $hklm  = [Microsoft.Win32.RegistryHive]::LocalMachine
                    $base  = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($hklm, $Target)
                    $sub   = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager')
                    if ($null -eq $sub) {
                        $fallbackRegPending = $null
                        $fallbackErrors += 'RemoteRegistry: Session Manager key not accessible'
                    }
                    else {
                        $val = $sub.GetValue('PendingFileRenameOperations', $null)
                        $fallbackRegPending = [bool]($null -ne $val)
                    }

                    if ($null -ne $base) { $base.Close() }
                }
                catch {
                    $fallbackRegPending = $null
                    $fallbackErrors += ("RemoteRegistry: {0}" -f $_.Exception.Message)
                }

                # Fallback 2: ADMIN$ share for pending.xml (uses remote windir)
                # IMPORTANT: Test-Path emits non-terminating errors by default.
                # Use -ErrorAction Stop so access denied is caught and tri-state becomes Unknown.
                try {
                    $adminXml = "\\{0}\admin$\WinSxS\pending.xml" -f $Target
                    $fallbackXmlPending = [Nullable[bool]](Test-Path -LiteralPath $adminXml -PathType Leaf -ErrorAction Stop)
                }
                catch {
                    $fallbackXmlPending = $null
                    $fallbackErrors += ("AdminShare: {0}" -f $_.Exception.Message)
                }

                $rebootReq = Resolve-RebootRequiredTriState -RegistryPending $fallbackRegPending -PendingXmlPresent $fallbackXmlPending

                $result.RegistryPending   = Convert-ToTriStateString $fallbackRegPending
                $result.PendingXmlPresent = Convert-ToTriStateString $fallbackXmlPending
                $result.RebootRequired    = Convert-ToTriStateString $rebootReq

                $fallbackSucceeded = ($null -ne $fallbackRegPending) -or ($null -ne $fallbackXmlPending)

                if (-not $fallbackSucceeded) {
                    $result.RemoteConnectionDenied       = $true
                    $result.RemoteConnectionDeniedClass  = 'FallbackFailed'
                    $result.RemoteConnectionDeniedReason = ("WinRM failed ({0}). Fallback attempts failed: {1}" -f $fi.Class, ($fallbackErrors -join ' | '))

                    $fi2 = [pscustomobject]@{
                        Class  = $result.RemoteConnectionDeniedClass
                        Reason = $result.RemoteConnectionDeniedReason
                        FQID   = $fi.FQID
                        Raw    = $fi.Raw
                    }

                    if ($ShowStatusInner) {
                        Set-RemoteDeniedState -ServerName $Target -FailureInfo $fi2 -SuppressStatus:$SuppressStatus
                    }

                    return [pscustomobject]$result
                }

                # Fallback yielded at least one signal, so do NOT treat as RemoteConnectionDenied.
                Write-Verbose ("Fallback succeeded for {0}. RegistryPending={1}, PendingXmlPresent={2}" -f $Target, $result.RegistryPending, $result.PendingXmlPresent)

                if ($rebootReq -eq $true) {
                    $script:anyRebootRequired = $true

                    if ($ShowStatusInner -and -not $SuppressStatus) {
                        Write-Host ("Pending reboot detected on {0} (Fallback) (Registry: {1}, pending.xml: {2})" -f $Target.ToUpper(), $result.RegistryPending, $result.PendingXmlPresent) -ForegroundColor Yellow
                    }

                    if ($PromptInner -and $PSCmdlet.ShouldProcess($Target, 'Restart-Computer')) {
                        $choice = Read-Host ("Reboot {0}? Y/N" -f $Target)
                        if ($choice -match '^[Yy]$') {
                            Restart-Computer -ComputerName $Target -Force
                        }
                    }
                }
                else {
                    if ($ShowStatusInner -and -not $SuppressStatus) {
                        if ($rebootReq -eq $false) {
                            Write-Host ("No pending reboot detected on {0} (Fallback)" -f $Target.ToUpper()) -ForegroundColor Green
                        }
                        else {
                            Write-Host ("Pending reboot state is Unknown on {0} (Fallback) (insufficient signal data)" -f $Target.ToUpper()) -ForegroundColor Yellow
                        }
                    }
                }

                return [pscustomobject]$result
            }
        }
    }

    process {
        # Suppress status lines when running against multiple targets or pipeline input
        $suppressStatus = $false
        $serverCount = if ($null -ne $Server) { $Server.Count } else { 0 }

        if ($ShowStatus) {
            if ($MyInvocation.ExpectingInput -or $serverCount -gt 1) {
                $suppressStatus = $true
            }
        }

        foreach ($s in $Server) {
            if ([string]::IsNullOrWhiteSpace($s)) { continue }

            $obj = Invoke-PendingRebootCheckSingle `
                -Target $s `
                -PromptInner:$Prompt `
                -SuppressStatus:$suppressStatus `
                -EnableFallbackInner:$EnableFallback `
                -ShowStatusInner:$ShowStatus

            if ($obj.RebootRequired -eq 'True') {
                $script:anyRebootRequired = $true
            }

            if ($obj.RemoteConnectionDenied) {
                $script:anyRemoteDenied = $true
            }

            $obj
        }
    }

    end {
        # Keep globals for backwards compatibility with your earlier pattern
        $global:RebootRequired         = $script:anyRebootRequired
        $global:RemoteConnectionDenied = $script:anyRemoteDenied
    }
}
