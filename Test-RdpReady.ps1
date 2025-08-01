# function to test if a server is ready for RDP connections
# function will have param for looping until available

function global:Test-RdpReady {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ComputerName,
        [switch]$Loop = $false
        )
    
    # Get all network connection profiles
    $networkConnections = Get-NetConnectionProfile
    
    # Filter for VPN connections by looking at the connection profile names and interface aliases
    $vpnConnections = $networkConnections | Where-Object {
        $_.InterfaceAlias -like '*VPN*' -or $_.Name -like '*VPN*'
    }
    #Wait-Debugger
    # Output the results
    if ($vpnConnections -notlike $null) {
        Write-Host "Active VPN connection(s) found. This may interfere with your results:" -ForegroundColor Yellow
        foreach ($vpnConnection in $vpnConnections) {
            Write-Host "Interface Alias: $($vpnConnection.InterfaceAlias) | Connection Name: $($vpnConnection.Name)"
        }
    } 

    Write-Verbose "Validating $ComputerName is a valid computer name.."
    try {
        # Attempt to ping the computer once to check network connectivity
        $Resolves = Test-Connection -ComputerName $ComputerName -Count 1 -ErrorAction Stop
    }
    catch {
        # Check if the error message contains 'lack of resources'
        #Wait-Debugger
        if ($_.Exception.Message -match 'Error due to lack of resources') {
            Write-Error "Testing connection to computer '$ComputerName' failed due to lack of system resources. This can be a result of being connected to a VPN."
        } else {
            Write-Error "Failed to test connection to computer '$ComputerName': $($_.Exception.Message)"
        }
        return
    }

    if($Resolves -eq $null) {
        Write-Error "$ComputerName does not resolve to an IP address. Exiting.."
        return
    }
    else {
        #Wait-Debugger
        Write-Host "Valid Hostname" -ForegroundColor Green -NoNewline 
        Write-Host " - $ComputerName resolves to $($Resolves.IPV4Address)"
    }
    
    Write " "
    Write-Host "Getting RDP status for $ComputerName. Please wait.." -ForegroundColor Cyan
    $RdpReady = $false
    # first check if the server will answer on port 3389
    $RdpPort = Test-NetConnection -ComputerName $ComputerName -Port 3389 -WarningAction SilentlyContinue
    if ($RdpPort.TcpTestSucceeded -eq $true) {
        Write-Host "Port Test     :  TCP port 3389 is open   |  " -NoNewline 
        Write-Host "Success" -ForegroundColor Green
        # if the port is open, check if the service is running. Also make sure the remote computer is allowing the test
        $RdpService = Get-Service -Name TermService -ComputerName $ComputerName -erroraction SilentlyContinue
        #Wait-Debugger
        if ($RdpService.Status -eq "Running") {
            Write-Host "Service Test  :  RDP service is running  |  " -NoNewline
            Write-Host "Success" -ForegroundColor Green
            $RdpReady = $true
        }
        elseif($RdpService -eq $null) {
            Write-Host "Service Test  :  Unable to query Service |  " -NoNewline
            Write-Host "Unknown" -ForegroundColor Yellow
        }
        else {
            Write-Host "Service Test  :  RDP service is not running  |  " -NoNewline
            Write-Host "Failed" -ForegroundColor Red
            $RdpReady = $false
        }
    }
    else {
        Write-Host "Port Test     :  TCP port 3389 is not available  |  " -NoNewline
        Write-Host "Failed" -ForegroundColor Red
    }
    Write " "
    # if 3389 responds, check if the service is running
    if ($RdpReady -eq $true) {
        Write-Host "$ComputerName is ready for RDP connections" -ForegroundColor Green
    }
    elseif ($RdpReady -eq $false) {
        Write-Host "$ComputerName is not ready for RDP connections" -ForegroundColor Red
    }
    else {
        Write-Warning "Unable to contact RDP service. $ComputerName may not ready for RDP connections."
    }
    # if loop is true, loop until the server is ready
    if ($Loop -eq $true) {
        while ($RdpReady -eq $false) {
            Write-Host "Checking again in 5 seconds..."
            Write " "
            Start-Sleep -Seconds 5
            Test-RdpReady -ComputerName $ComputerName
        }
    }
}






