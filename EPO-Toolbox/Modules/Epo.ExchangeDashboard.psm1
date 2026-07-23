Set-StrictMode -Version 2.0

function ConvertTo-EpoExchangeCuName {
    [CmdletBinding()]
    param([string] $Build)

    $Text = [string] $Build
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'Unknown' }

    $Map = @{
        '15.2.1748' = 'Exchange Server 2019 CU15'
        '15.2.1544' = 'Exchange Server 2019 CU14'
        '15.2.1258' = 'Exchange Server 2019 CU13'
        '15.2.1118' = 'Exchange Server 2019 CU12'
        '15.2.986'  = 'Exchange Server 2019 CU11'
        '15.2.922'  = 'Exchange Server 2019 CU10'
        '15.2.858'  = 'Exchange Server 2019 CU9'
        '15.2.792'  = 'Exchange Server 2019 CU8'
        '15.2.721'  = 'Exchange Server 2019 CU7'
        '15.2.659'  = 'Exchange Server 2019 CU6'
        '15.2.595'  = 'Exchange Server 2019 CU5'
        '15.2.529'  = 'Exchange Server 2019 CU4'
        '15.2.464'  = 'Exchange Server 2019 CU3'
        '15.2.397'  = 'Exchange Server 2019 CU2'
        '15.2.330'  = 'Exchange Server 2019 CU1'
        '15.2.221'  = 'Exchange Server 2019 RTM'
    }

    foreach ($Key in ($Map.Keys | Sort-Object { $_.Length } -Descending)) {
        if ($Text.StartsWith($Key)) { return $Map[$Key] }
    }

    if ($Text -match '^15\.2\.') { return "Exchange Server 2019 build $Text" }
    if ($Text -match '^15\.1\.') { return "Exchange Server 2016 build $Text" }
    return "Exchange build $Text"
}

function Test-EpoCommandAvailable {
    param([string] $Name)
    return [bool] (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-EpoExchangeTopology {
    [CmdletBinding()]
    param(
        [ValidateSet('CurrentDag','CurrentAdSite','AllExchangeServers')]
        [string] $Scope = 'CurrentDag',
        [string[]] $TargetServers
    )

    $LocalName = $env:COMPUTERNAME
    $ExchangeServers = @()
    $CurrentServer = $null
    $CurrentDagName = ''
    $CurrentSite = ''
    $DiscoveryNotes = New-Object System.Collections.Generic.List[string]

    if (Test-EpoCommandAvailable -Name 'Get-ExchangeServer') {
        try {
            $ExchangeServers = @(Get-ExchangeServer -ErrorAction Stop)
            $CurrentServer = @($ExchangeServers | Where-Object {
                $_.Name -ieq $LocalName -or $_.Fqdn -ieq $LocalName -or ([string]$_.Fqdn).Split('.')[0] -ieq $LocalName
            } | Select-Object -First 1)
            if ($CurrentServer) {
                $CurrentSite = [string] $CurrentServer.Site
            }
        }
        catch {
            $DiscoveryNotes.Add("Get-ExchangeServer failed: $($_.Exception.Message)")
        }
    }
    else {
        $DiscoveryNotes.Add('Get-ExchangeServer is not available in this session.')
    }

    if (Test-EpoCommandAvailable -Name 'Get-DatabaseAvailabilityGroup') {
        try {
            $Dags = @(Get-DatabaseAvailabilityGroup -Status -ErrorAction Stop)
            foreach ($Dag in $Dags) {
                $DagServers = @($Dag.Servers | ForEach-Object { ([string]$_).Split('.')[0] })
                if ($DagServers -contains $LocalName -or ($CurrentServer -and $DagServers -contains $CurrentServer.Name)) {
                    $CurrentDagName = [string] $Dag.Name
                    break
                }
            }
        }
        catch {
            $DiscoveryNotes.Add("Get-DatabaseAvailabilityGroup failed: $($_.Exception.Message)")
        }
    }
    else {
        $DiscoveryNotes.Add('Get-DatabaseAvailabilityGroup is not available in this session.')
    }

    $SelectedServers = @()
    if ($TargetServers -and $TargetServers.Count) {
        $SelectedServers = @($TargetServers | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
    elseif ($ExchangeServers.Count -gt 0) {
        switch ($Scope) {
            'CurrentDag' {
                if ($CurrentDagName -and (Test-EpoCommandAvailable -Name 'Get-DatabaseAvailabilityGroup')) {
                    $Dag = Get-DatabaseAvailabilityGroup -Identity $CurrentDagName -Status -ErrorAction SilentlyContinue
                    $SelectedServers = @($Dag.Servers | ForEach-Object { ([string]$_).Split('.')[0] } | Where-Object { $_ } | Select-Object -Unique)
                }
                if (-not $SelectedServers.Count -and $CurrentServer) { $SelectedServers = @($CurrentServer.Name) }
            }
            'CurrentAdSite' {
                if ($CurrentSite) {
                    $SelectedServers = @($ExchangeServers | Where-Object { [string]$_.Site -eq $CurrentSite } | Select-Object -ExpandProperty Name)
                }
                if (-not $SelectedServers.Count -and $CurrentServer) { $SelectedServers = @($CurrentServer.Name) }
            }
            'AllExchangeServers' {
                $SelectedServers = @($ExchangeServers | Select-Object -ExpandProperty Name)
            }
        }
    }

    if (-not $SelectedServers.Count) {
        $SelectedServers = @($LocalName)
        $DiscoveryNotes.Add('Falling back to local computer because Exchange topology could not be discovered.')
    }

    [pscustomobject] @{
        Scope = $Scope
        LocalServer = $LocalName
        CurrentDag = $CurrentDagName
        CurrentAdSite = $CurrentSite
        Servers = @($SelectedServers | Select-Object -Unique)
        Notes = @($DiscoveryNotes.ToArray())
    }
}

function Test-EpoServerConnectivity {
    [CmdletBinding()]
    param([string] $ServerName)

    $Ping = $false
    $Rdp = 'Unknown'
    $WinRM = 'Unknown'

    try { $Ping = [bool] (Test-Connection -ComputerName $ServerName -Count 1 -Quiet -ErrorAction Stop) } catch { $Ping = $false }
    try {
        $Client = New-Object System.Net.Sockets.TcpClient
        $Async = $Client.BeginConnect($ServerName, 3389, $null, $null)
        $Connected = $Async.AsyncWaitHandle.WaitOne(1500, $false)
        if ($Connected) {
            $Client.EndConnect($Async)
            $Rdp = 'True'
        }
        else {
            $Rdp = 'False'
        }
        $Client.Close()
    }
    catch { $Rdp = 'Unknown' }
    try {
        Test-WSMan -ComputerName $ServerName -ErrorAction Stop | Out-Null
        $WinRM = 'True'
    }
    catch { $WinRM = 'False' }

    [pscustomobject] @{
        Ping = [string] $Ping
        Rdp = $Rdp
        WinRM = $WinRM
        Note = 'RDP is currently a TCP 3389 probe placeholder; a richer RDP validation can be added later.'
    }
}

function Get-EpoMscorsvwState {
    [CmdletBinding()]
    param([string] $ServerName)

    try {
        if ($ServerName -in @($env:COMPUTERNAME, 'localhost', '.', $env:COMPUTERNAME.ToLowerInvariant())) {
            $Processes = @(Get-Process -Name mscorsvw -ErrorAction SilentlyContinue)
        }
        else {
            $Processes = @(Invoke-Command -ComputerName $ServerName -ScriptBlock { Get-Process -Name mscorsvw -ErrorAction SilentlyContinue } -ErrorAction Stop)
        }
        [pscustomobject] @{
            Running = [bool] ($Processes.Count -gt 0)
            Count = $Processes.Count
            Status = if ($Processes.Count -gt 0) { 'Running' } else { 'NotRunning' }
        }
    }
    catch {
        [pscustomobject] @{
            Running = $false
            Count = 0
            Status = 'Unknown'
        }
    }
}

function Get-EpoMaintenanceState {
    [CmdletBinding()]
    param([string] $ServerName)

    if (-not (Test-EpoCommandAvailable -Name 'Get-ServerComponentState')) {
        return [pscustomobject] @{
            InMaintenance = 'Unknown'
            ServerWideOffline = 'Unknown'
            HubTransport = 'Unknown'
            Note = 'Get-ServerComponentState is not available.'
        }
    }

    try {
        $States = @(Get-ServerComponentState -Identity $ServerName -ErrorAction Stop)
        $ServerWideOffline = @($States | Where-Object Component -eq 'ServerWideOffline' | Select-Object -First 1)
        $HubTransport = @($States | Where-Object Component -eq 'HubTransport' | Select-Object -First 1)
        $OfflineState = if ($ServerWideOffline.Count) { [string] $ServerWideOffline[0].State } else { 'Unknown' }
        $TransportState = if ($HubTransport.Count) { [string] $HubTransport[0].State } else { 'Unknown' }
        [pscustomobject] @{
            InMaintenance = [string] ($OfflineState -eq 'Inactive' -or $TransportState -eq 'Draining')
            ServerWideOffline = $OfflineState
            HubTransport = $TransportState
            Note = ''
        }
    }
    catch {
        [pscustomobject] @{
            InMaintenance = 'Unknown'
            ServerWideOffline = 'Unknown'
            HubTransport = 'Unknown'
            Note = $_.Exception.Message
        }
    }
}

function Get-EpoExchangeServerDashboardStatus {
    [CmdletBinding()]
    param(
        [string[]] $ServerName,
        [string] $PendingRebootScriptPath,
        [int] $DotNetMinimumRelease = 528040,
        [string] $DotNetMinimumVersion = '4.8'
    )

    Import-Module (Join-Path $PSScriptRoot 'Epo.UpdateInventory.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Epo.Preflight.psm1') -Force

    $Rows = New-Object System.Collections.Generic.List[object]
    foreach ($Server in $ServerName) {
        $Inventory = Get-EpoExchangeUpdateInventory -ServerName @($Server)
        $Preflight = Invoke-EpoPreflightCheck -ServerName @($Server) -PendingRebootScriptPath $PendingRebootScriptPath -EnablePendingRebootFallback -BlockOnPendingReboot $true -BlockOnUnknownRebootState $true -DotNetMinimumRelease $DotNetMinimumRelease -DotNetMinimumVersion $DotNetMinimumVersion -BlockOnIncompatibleDotNet $true
        $InventoryServer = @($Inventory.Servers | Select-Object -First 1)
        $PreflightServer = @($Preflight.Servers | Select-Object -First 1)
        $Build = ''
        if ($InventoryServer.Count -and $InventoryServer[0].ExchangeSetup -and $InventoryServer[0].ExchangeSetup.PSObject.Properties['FileVersion']) {
            $Build = [string] $InventoryServer[0].ExchangeSetup.FileVersion
        }
        $CuUpdate = @($InventoryServer[0].InstalledUpdates | Where-Object Type -eq 'CU' | Select-Object -First 1)
        $CuName = if ($CuUpdate.Count) { [string] $CuUpdate[0].DisplayName } else { ConvertTo-EpoExchangeCuName -Build $Build }
        $Connectivity = Test-EpoServerConnectivity -ServerName $Server
        $Maintenance = Get-EpoMaintenanceState -ServerName $Server
        $Mscorsvw = Get-EpoMscorsvwState -ServerName $Server

        $Rows.Add([pscustomobject] @{
            Server = $Server
            Dag = ''
            AdSite = ''
            PatchLevel = $Build
            CuName = $CuName
            PendingReboot = if ($PreflightServer.Count) { [string] $PreflightServer[0].PendingReboot.RebootRequired } else { 'Unknown' }
            DotNet = if ($PreflightServer.Count) { [string] $PreflightServer[0].DotNet.DetectedVersion } else { 'Unknown' }
            Mscorsvw = $Mscorsvw.Status
            Maintenance = $Maintenance.InMaintenance
            Ping = $Connectivity.Ping
            Rdp = $Connectivity.Rdp
            WinRM = $Connectivity.WinRM
        })
    }

    @($Rows.ToArray())
}

function Get-EpoVirtualDirectoryHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ServerName)

    $Cmdlets = @(
        'Get-OwaVirtualDirectory',
        'Get-EcpVirtualDirectory',
        'Get-WebServicesVirtualDirectory',
        'Get-MapiVirtualDirectory',
        'Get-ActiveSyncVirtualDirectory',
        'Get-OabVirtualDirectory',
        'Get-PowerShellVirtualDirectory'
    )
    $Rows = New-Object System.Collections.Generic.List[object]

    foreach ($Cmdlet in $Cmdlets) {
        if (-not (Test-EpoCommandAvailable -Name $Cmdlet)) {
            $Rows.Add([pscustomobject] @{
                Server = $ServerName
                VirtualDirectory = $Cmdlet
                Url = ''
                StatusCode = ''
                Status = 'NotAvailable'
                Note = "$Cmdlet is not available."
            })
            continue
        }

        try {
            $Directories = @(& $Cmdlet -Server $ServerName -ErrorAction Stop)
            foreach ($Directory in $Directories) {
                foreach ($PropertyName in @('InternalUrl','ExternalUrl')) {
                    $Url = [string] $Directory.$PropertyName
                    if ([string]::IsNullOrWhiteSpace($Url)) { continue }
                    try {
                        $Response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                        $StatusCode = [int] $Response.StatusCode
                        $Status = if ($StatusCode -lt 500) { 'Pass' } else { 'Warning' }
                        $Note = ''
                    }
                    catch {
                        $WebResponse = $_.Exception.Response
                        if ($WebResponse -and $WebResponse.StatusCode) {
                            $StatusCode = [int] $WebResponse.StatusCode
                            $Status = if ($StatusCode -in @(401,403)) { 'Pass' } elseif ($StatusCode -lt 500) { 'Pass' } else { 'Warning' }
                            $Note = $_.Exception.Message
                        }
                        else {
                            $StatusCode = ''
                            $Status = 'Failed'
                            $Note = $_.Exception.Message
                        }
                    }

                    $Rows.Add([pscustomobject] @{
                        Server = $ServerName
                        VirtualDirectory = "$Cmdlet.$PropertyName"
                        Url = $Url
                        StatusCode = [string] $StatusCode
                        Status = $Status
                        Note = $Note
                    })
                }
            }
        }
        catch {
            $Rows.Add([pscustomobject] @{
                Server = $ServerName
                VirtualDirectory = $Cmdlet
                Url = ''
                StatusCode = ''
                Status = 'Failed'
                Note = $_.Exception.Message
            })
        }
    }

    @($Rows.ToArray())
}

Export-ModuleMember -Function Get-EpoExchangeTopology, Get-EpoExchangeServerDashboardStatus, Get-EpoVirtualDirectoryHealth, ConvertTo-EpoExchangeCuName
