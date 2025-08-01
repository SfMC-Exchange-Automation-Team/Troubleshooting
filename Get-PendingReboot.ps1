function global:Get-PendingReboot{
    param(
        $Server = $env:COMPUTERNAME,
        [switch]$Prompt
    )
    if($Server -like $env:COMPUTERNAME){
        $PendingRebootReg = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager").PendingFileRenameOperations
        $PendingRebootXml = Get-Item C:\Windows\WinSxS\Pending.xml -ErrorAction SilentlyContinue
    }
    ### Broke the query into two types due to PowerShell remoting restrictions ###
    else{
        $PendingRebootReg = Invoke-Command $Server -ScriptBlock {(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager").PendingFileRenameOperations }
        $PendingRebootXml = Invoke-Command $Server -ScriptBlock {Get-Item C:\Windows\WinSxS\Pending.xml -ErrorAction SilentlyContinue}
    }

    # Determine which check(s) triggered the pending reboot state
    $regPending = $PendingRebootReg -ne $null
    $xmlPending = $PendingRebootXml -ne $null

    if ($regPending -and $xmlPending){
        Write-Warning "*** $($Server.ToUpper()) IS CURRENTLY PENDING A REBOOT. ***"
        Write-Host "Reason: Both registry (PendingFileRenameOperations) and pending.xml indicate a pending reboot." -ForegroundColor Yellow
        $global:RebootRequired = $true
        if ($Prompt) {
            $choice = Read-Host "Do you want to reboot now? (Y/N)"
            if ($choice -eq "Y" -or $choice -eq "y") {
                Restart-Computer -Force
            }
        }
    }
    elseif ($regPending) {
        Write-Warning "*** $($Server.ToUpper()) IS CURRENTLY PENDING A REBOOT. ***"
        Write-Host "Reason: Registry (PendingFileRenameOperations) indicates a pending reboot." -ForegroundColor Yellow
        $global:RebootRequired = $true
        if ($Prompt) {
            $choice = Read-Host "Do you want to reboot now? (Y/N)"
            if ($choice -eq "Y" -or $choice -eq "y") {
                Restart-Computer -Force
            }
        }
    }
    elseif ($xmlPending) {
        Write-Warning "*** $($Server.ToUpper()) IS CURRENTLY PENDING A REBOOT. ***"
        Write-Host "Reason: pending.xml indicates a pending reboot." -ForegroundColor Yellow
        $global:RebootRequired = $true
        if ($Prompt) {
            $choice = Read-Host "Do you want to reboot now? (Y/N)"
            if ($choice -eq "Y" -or $choice -eq "y") {
                Restart-Computer -Force
            }
        }
    }
    else{
        Write-Host "$($Server.ToUpper()) has no pending reboots!"
        $global:RebootRequired = $false
    }
}