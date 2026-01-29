
<#
.SYNOPSIS
Checks one or more Windows computers for common "pending reboot" indicators and returns a structured result.

.DESCRIPTION
UNSUPPORTED SCRIPT DISCLAIMER:
This PowerShell function is provided "as-is" as an unsupported script. It is not an official Microsoft product,
and it is not covered by Microsoft Support. Use at your own risk. Validate in a lab and follow your change
management and maintenance window processes before using in production.

Core indicators checked by this function (minimum set):
- Registry: HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations
- File: %windir%\WinSxS\pending.xml
Remote checks rely on PowerShell Remoting (WinRM). The function may preflight WinRM using Test-WSMan.

If -Prompt is used and a reboot is detected, the function can optionally initiate a reboot (Restart-Computer).

.PARAMETER Server
One or more target computer names.
Aliases: ComputerName, CN
Accepts pipeline input.

.PARAMETER Prompt
If set and a reboot is required, prompts to reboot the target.

.PARAMETER ShowStatus
If set, emits console status lines (Write-Host). Useful for interactive runs.
When running against multiple targets or via pipeline input, you may suppress status output to avoid noisy pipelines.

.OUTPUTS
System.Management.Automation.PSCustomObject
Typical fields:
- Server
- RebootRequired (True/False/Unknown)
- RegistryPending (True/False/Unknown)
- PendingXmlPresent (True/False/Unknown)
- RemoteConnectionDenied (True/False)
- RemoteConnectionDeniedReason (nullable)

.EXAMPLE
Get-PendingReboot
Checks the local computer.

.EXAMPLE
'EXCH01','EXCH02' | Get-PendingReboot | Select Server,RebootRequired
Checks multiple computers using pipeline input and returns summarized results.

.EXAMPLE
Get-PendingReboot -Server EXCH01 -ShowStatus -Prompt
Interactive mode with status and optional reboot prompt.

.NOTES
Author: Cullen Haafke 
Organization: Microsoft (SfMC)
Compatibility: Windows PowerShell 5.1

Version: 1.0.0

Version History:
  •  01/28/2026 - 1.0.0  |  Initial release (basic checks: PendingFileRenameOperations + pending.xml).

.LINK
Test-WSMan documentation (WinRM preflight). 

.LINK
Restart-Computer documentation (reboot behavior). 
#>


function global:Get-PendingReboot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('ComputerName','CN','Computer')]
        [string[]]$Server = @($env:COMPUTERNAME),

        [switch]$Prompt,

        [switch]$ShowStatus
    )

    begin {
        # Aggregate globals (kept for backwards compatibility with your existing usage pattern)
        $script:anyRebootRequired = $false
        $script:anyRemoteDenied   = $false

        $global:RebootRequired         = $false
        $global:RemoteConnectionDenied = $false

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
                Reason = 'Remoting failed (unclassified).'
                FQID   = $fqid
                Raw    = ($ErrorRecord | Out-String).Trim()
            }

            # Soft failures (Yellow)
            if ($msg -match 'No host is known|Name or service not known|could not be resolved|network path was not found|specified computer name is not valid') {
                $info.Class  = 'NameResolutionOrBadTarget'
                $info.Reason = 'Name resolution failed or target invalid.'
                return $info
            }

            # Blocked failures (Red)
            if ($msg -match 'WinRM cannot complete the operation|2150859046') {
                $info.Class  = 'ConnectionBlocked'
                $info.Reason = 'WinRM unreachable or blocked (firewall / service / network).'
                return $info
            }

            if ($msg -match 'connection to the specified remote host was refused') {
                $info.Class  = 'ConnectionRefused'
                $info.Reason = 'Remote host refused WSMan / WinRM connection.'
                return $info
            }

            if ($msg -match 'WinRM client cannot process the request') {
                $info.Class  = 'WinRMClientCannotProcess'
                $info.Reason = 'WinRM client cannot process the request (auth / trust / config).'
                return $info
            }

            if ($msg -match 'Access is denied|Unauthorized|0x80070005') {
                $info.Class  = 'AccessDenied'
                $info.Reason = 'Access denied (permissions / authorization).'
                return $info
            }

            if ($msg -match 'Kerberos|TrustedHosts|0x8009030e|logon session does not exist|authentication') {
                $info.Class  = 'AuthOrTrustConfig'
                $info.Reason = 'Authentication / trust configuration issue (Kerberos / TrustedHosts / HTTPS).'
                return $info
            }

            if ($msg -match 'timed out|timeout') {
                $info.Class  = 'Timeout'
                $info.Reason = 'WinRM connection timed out.'
                return $info
            }

            if ($fqid -match 'PSSessionOpenFailed|CannotConnect|WsManError|WinRM') {
                $info.Class  = 'SessionOpenFailed'
                $info.Reason = 'Failed to open WSMan / WinRM session.'
                return $info
            }

            return $info
        }

        function Write-StatusLine {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)] [string]$ServerName,
                [Parameter(Mandatory = $true)] [string]$StateClass,
                [Parameter(Mandatory = $true)] [string]$Message,
                [Parameter(Mandatory = $true)] [bool]$Suppress
            )

            if ($Suppress) { return }

            $isSoft = ($StateClass -eq 'NameResolutionOrBadTarget')
            $color  = if ($isSoft) { 'Yellow' } else { 'Red' }

            Write-Host ("{0} Remoting unavailable ({1}) - {2}" -f $ServerName.ToUpper(), $StateClass, $Message) -ForegroundColor $color
        }

        function Set-RemoteDeniedState {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)] [string]$ServerName,
                [Parameter(Mandatory = $true)] $FailureInfo,
                [Parameter(Mandatory = $true)] [bool]$SuppressStatus
            )

            $global:RemoteConnectionDenied = $true
            $script:anyRemoteDenied        = $true

            Write-StatusLine -ServerName $ServerName -StateClass $FailureInfo.Class -Message $FailureInfo.Reason -Suppress $SuppressStatus

            Write-Verbose ("Remoting failure classification: {0}" -f $FailureInfo.Class)
            Write-Verbose ("FullyQualifiedErrorId: {0}" -f $FailureInfo.FQID)
            Write-Verbose ("Raw error: {0}" -f $FailureInfo.Raw)
        }

        function Invoke-PendingRebootCheckSingle {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)] [string]$Target,
                [switch]$PromptInner,
                [Parameter(Mandatory = $true)] [bool]$SuppressStatus
            )

            # Tri-state defaults
            $result = [ordered]@{
                Server                       = $Target
                RebootRequired               = 'Unknown'
                RegistryPending              = 'Unknown'
                PendingXmlPresent            = 'Unknown'
                RemoteConnectionDenied       = $false
                RemoteConnectionDeniedClass  = $null
                RemoteConnectionDeniedReason = $null
            }

            $isLocal = ($Target -ieq $env:COMPUTERNAME)

            try {
                if (-not $isLocal) {
                    # DNS precheck for remote targets
                    try {
                        [void][System.Net.Dns]::GetHostEntry($Target)
                        Write-Verbose ("Name resolution succeeded: {0}" -f $Target)
                    } catch {
                        $fi = Get-RemotingFailureInfo -ErrorRecord $_
                        $result.RemoteConnectionDenied       = $true
                        $result.RemoteConnectionDeniedClass  = $fi.Class
                        $result.RemoteConnectionDeniedReason = $fi.Reason
                        Set-RemoteDeniedState -ServerName $Target -FailureInfo $fi -SuppressStatus $SuppressStatus
                        return [pscustomobject]$result
                    }

                    # WSMan preflight
                    try {
                        Test-WSMan -ComputerName $Target -ErrorAction Stop | Out-Null
                        Write-Verbose ("Test-WSMan succeeded: {0}" -f $Target)
                    } catch {
                        $fi = Get-RemotingFailureInfo -ErrorRecord $_
                        $result.RemoteConnectionDenied       = $true
                        $result.RemoteConnectionDeniedClass  = $fi.Class
                        $result.RemoteConnectionDeniedReason = $fi.Reason
                        Set-RemoteDeniedState -ServerName $Target -FailureInfo $fi -SuppressStatus $SuppressStatus
                        return [pscustomobject]$result
                    }
                }

                # Pending reboot signals
                $regPending = $false
                $xmlPending = $false

                if ($isLocal) {
                    $regValue = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop |
                        Select-Object -ExpandProperty PendingFileRenameOperations -ErrorAction SilentlyContinue
                    $xmlItem  = Get-Item -LiteralPath (Join-Path $env:windir 'WinSxS\pending.xml') -ErrorAction SilentlyContinue
                } else {
                    $regValue = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
                        Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop |
                            Select-Object -ExpandProperty PendingFileRenameOperations -ErrorAction SilentlyContinue
                    }
                    $xmlItem = Invoke-Command -ComputerName $Target -ErrorAction Stop -ScriptBlock {
                        $p = Join-Path $env:windir 'WinSxS\pending.xml'
                        Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
                    }
                }

                if ($regValue) { $regPending = $true }
                if ($xmlItem)   { $xmlPending = $true }

                $rebootReq = ($regPending -or $xmlPending)

                $result.RegistryPending   = if ($regPending) { 'True' } else { 'False' }
                $result.PendingXmlPresent = if ($xmlPending) { 'True' } else { 'False' }
                $result.RebootRequired    = if ($rebootReq)  { 'True' } else { 'False' }

                if ($rebootReq) {
                    $script:anyRebootRequired = $true
                    $global:RebootRequired    = $true

                    if (-not $SuppressStatus) {
                        if ($regPending -and $xmlPending) {
                            Write-Host ("{0} Pending reboot detected (Registry + pending.xml)" -f $Target.ToUpper()) -ForegroundColor Yellow
                        } elseif ($regPending) {
                            Write-Host ("{0} Pending reboot detected (Registry)" -f $Target.ToUpper()) -ForegroundColor Yellow
                        } else {
                            Write-Host ("{0} Pending reboot detected (pending.xml)" -f $Target.ToUpper()) -ForegroundColor Yellow
                        }
                    }

                    if ($PromptInner) {
                        $choice = Read-Host ("Reboot {0}? (Y/N)" -f $Target)
                        if ($choice -match '^(Y|y)$') {
                            Restart-Computer -ComputerName $Target -Force
                        }
                    }
                } else {
                    if (-not $SuppressStatus) {
                        Write-Host ("{0} No pending reboot detected" -f $Target.ToUpper()) -ForegroundColor Green
                    }
                }

                return [pscustomobject]$result
            }
            catch {
                # If Invoke-Command fails after WSMan passed, treat as remote denied
                if (-not $isLocal) {
                    $fi = Get-RemotingFailureInfo -ErrorRecord $_
                    $result.RemoteConnectionDenied       = $true
                    $result.RemoteConnectionDeniedClass  = $fi.Class
                    $result.RemoteConnectionDeniedReason = $fi.Reason
                    Set-RemoteDeniedState -ServerName $Target -FailureInfo $fi -SuppressStatus $SuppressStatus
                    return [pscustomobject]$result
                }

                Write-Verbose ("Unexpected local failure: {0}" -f ($_ | Out-String))
                Write-Host ("{0} Pending reboot check failed" -f $Target.ToUpper()) -ForegroundColor Red
                return [pscustomobject]$result
            }
        }
    }

    process {
        # Suppress status lines when:
        # - piped input is driving the function, OR
        # - multiple targets were provided
        $suppressStatus = $false
        if (-not $ShowStatus) {
            if ($MyInvocation.ExpectingInput -or ($Server.Count -gt 1)) {
                $suppressStatus = $true
            }
        }

        foreach ($s in $Server) {
            if ([string]::IsNullOrWhiteSpace($s)) { continue }

            $obj = Invoke-PendingRebootCheckSingle -Target $s -PromptInner:$Prompt -SuppressStatus $suppressStatus

            # Maintain aggregate globals
            if ($script:anyRemoteDenied)   { $global:RemoteConnectionDenied = $true }
            if ($script:anyRebootRequired) { $global:RebootRequired = $true }

            $obj
        }
    }
}
