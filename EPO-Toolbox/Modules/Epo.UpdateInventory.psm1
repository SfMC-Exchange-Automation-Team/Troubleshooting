Set-StrictMode -Version 2.0

function ConvertTo-EpoInventoryDate {
    param([object] $Value)

    if ($null -eq $Value) { return $null }
    $Text = [string] $Value
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $Parsed = [datetime]::MinValue
    if ($Text -match '^\d{8}$' -and [datetime]::TryParseExact($Text, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $Parsed)) {
        return $Parsed.ToString('yyyy-MM-dd')
    }
    if ([datetime]::TryParse($Text, [ref] $Parsed)) {
        return $Parsed.ToString('yyyy-MM-dd')
    }
    return $Text
}

function Get-EpoUpdateType {
    param([string] $DisplayName)

    $Name = [string] $DisplayName
    if ($Name -match '(?i)\b(cumulative update|cu\d+|cu\s+\d+)\b') { return 'CU' }
    if ($Name -match '(?i)\b(hotfix update|hotfix|hu\d+|hu\s+\d+)\b') { return 'HU' }
    if ($Name -match '(?i)\b(security update|su\d+|su\s+\d+)\b') { return 'SU' }
    if ($Name -match '(?i)\bKB\d{6,}\b') { return 'SU' }
    return 'Product'
}

function Get-EpoKbId {
    param([string] $Text)

    $Match = [regex]::Match([string] $Text, '(?i)\bKB\d{6,}\b')
    if ($Match.Success) { return $Match.Value.ToUpperInvariant() }
    return ''
}

function Get-EpoObjectValue {
    param(
        [object] $InputObject,
        [string] $PropertyName,
        [object] $Default = ''
    )

    if ($null -eq $InputObject) { return $Default }
    $Property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $Property) { return $Default }
    if ($null -eq $Property.Value) { return $Default }
    return $Property.Value
}

function Get-EpoLocalExchangeUpdateInventory {
    [CmdletBinding()]
    param([string] $ServerName = $env:COMPUTERNAME)

    $CollectedAtUtc = [datetime]::UtcNow.ToString('o')
    $Evidence = [ordered] @{
        RegistryPaths = @()
        FilePaths = @()
        SetupLogPaths = @()
        Notes = @()
    }

    $Setup = [ordered] @{
        InstallPath = ''
        MsiProductMajor = ''
        MsiProductMinor = ''
        MsiBuildMajor = ''
        MsiBuildMinor = ''
        ConfiguredVersion = ''
        FileVersion = ''
        ProductVersion = ''
        ExSetupPath = ''
    }

    $SetupRegistryPath = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup'
    $Evidence.RegistryPaths += $SetupRegistryPath
    try {
        $SetupReg = Get-ItemProperty -LiteralPath $SetupRegistryPath -ErrorAction Stop
        $Setup.InstallPath = [string] $SetupReg.MsiInstallPath
        $Setup.MsiProductMajor = [string] $SetupReg.MsiProductMajor
        $Setup.MsiProductMinor = [string] $SetupReg.MsiProductMinor
        $Setup.MsiBuildMajor = [string] $SetupReg.MsiBuildMajor
        $Setup.MsiBuildMinor = [string] $SetupReg.MsiBuildMinor
        $Setup.ConfiguredVersion = [string] $SetupReg.ConfiguredVersion
    }
    catch {
        $Evidence.Notes += "Exchange setup registry was not available: $($_.Exception.Message)"
    }

    $CandidateInstallPaths = @($Setup.InstallPath, $env:ExchangeInstallPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $CandidateExSetupPaths = foreach ($InstallPath in $CandidateInstallPaths) {
        Join-Path $InstallPath 'bin\ExSetup.exe'
        Join-Path $InstallPath 'Bin\ExSetup.exe'
    }
    $ExSetupPath = @($CandidateExSetupPaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($ExSetupPath) {
        $File = Get-Item -LiteralPath $ExSetupPath
        $Setup.ExSetupPath = $File.FullName
        $Setup.FileVersion = [string] $File.VersionInfo.FileVersion
        $Setup.ProductVersion = [string] $File.VersionInfo.ProductVersion
        $Evidence.FilePaths += $File.FullName
    }
    else {
        $Evidence.Notes += 'ExSetup.exe was not found from the detected Exchange install path.'
    }

    $InstalledUpdates = New-Object System.Collections.Generic.List[object]
    $UninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($Root in $UninstallRoots) {
        $Evidence.RegistryPaths += $Root
        $Items = @(Get-ChildItem -LiteralPath $Root -ErrorAction SilentlyContinue)
        foreach ($Item in $Items) {
            $Properties = Get-ItemProperty -LiteralPath $Item.PSPath -ErrorAction SilentlyContinue
            $DisplayName = [string] (Get-EpoObjectValue -InputObject $Properties -PropertyName 'DisplayName')
            if ([string]::IsNullOrWhiteSpace($DisplayName)) { continue }
            if ($DisplayName -notmatch '(?i)Exchange') { continue }

            $Type = Get-EpoUpdateType -DisplayName $DisplayName
            $InstalledUpdates.Add([pscustomobject] @{
                Type = $Type
                DisplayName = $DisplayName
                KB = Get-EpoKbId -Text $DisplayName
                InstalledOn = ConvertTo-EpoInventoryDate -Value (Get-EpoObjectValue -InputObject $Properties -PropertyName 'InstallDate')
                DisplayVersion = [string] (Get-EpoObjectValue -InputObject $Properties -PropertyName 'DisplayVersion')
                Publisher = [string] (Get-EpoObjectValue -InputObject $Properties -PropertyName 'Publisher')
                Source = 'UninstallRegistry'
                EvidencePath = $Item.Name
            })
        }
    }

    try {
        $HotFixes = @(Get-HotFix -ErrorAction Stop | Where-Object {
            $_.Description -match '(?i)security|hotfix|update' -or $_.HotFixID -match '(?i)^KB'
        })
        foreach ($HotFix in $HotFixes) {
            $Name = "$($HotFix.Description) $($HotFix.HotFixID)"
            if ($Name -notmatch '(?i)Exchange') { continue }
            $InstalledUpdates.Add([pscustomobject] @{
                Type = Get-EpoUpdateType -DisplayName $Name
                DisplayName = $Name
                KB = [string] $HotFix.HotFixID
                InstalledOn = ConvertTo-EpoInventoryDate -Value $HotFix.InstalledOn
                DisplayVersion = ''
                Publisher = ''
                Source = 'GetHotFix'
                EvidencePath = ''
            })
        }
    }
    catch {
        $Evidence.Notes += "Get-HotFix inventory failed: $($_.Exception.Message)"
    }

    $SetupLogRoot = 'C:\ExchangeSetupLogs'
    if (Test-Path -LiteralPath $SetupLogRoot) {
        $LogFiles = @(Get-ChildItem -LiteralPath $SetupLogRoot -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('ExchangeSetup.log','ServiceControl.log') -or $_.Name -match '(?i)setup|update|patch'
        } | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
        foreach ($Log in $LogFiles) {
            $Evidence.SetupLogPaths += [pscustomobject] @{
                Path = $Log.FullName
                LastWriteTime = $Log.LastWriteTime.ToString('o')
                Length = $Log.Length
            }
        }
    }
    else {
        $Evidence.Notes += 'C:\ExchangeSetupLogs was not found.'
    }

    $OrderedUpdates = @($InstalledUpdates.ToArray() | Sort-Object @{ Expression = { $_.InstalledOn }; Descending = $true }, @{ Expression = { $_.DisplayName }; Descending = $false })
    $Status = if ($Setup.FileVersion -or $OrderedUpdates.Count) { 'Success' } else { 'Warning' }

    [pscustomobject] @{
        Server = $ServerName
        CollectedAtUtc = $CollectedAtUtc
        Status = $Status
        ExchangeSetup = [pscustomobject] $Setup
        InstalledUpdates = $OrderedUpdates
        Evidence = [pscustomobject] $Evidence
    }
}

function Get-EpoExchangeUpdateInventory {
    [CmdletBinding()]
    param([string[]] $ServerName = @($env:COMPUTERNAME))

    $Servers = New-Object System.Collections.Generic.List[object]
    $RemoteDefinitions = @(
        ${function:ConvertTo-EpoInventoryDate}.ToString(),
        ${function:Get-EpoUpdateType}.ToString(),
        ${function:Get-EpoKbId}.ToString(),
        ${function:Get-EpoObjectValue}.ToString(),
        ${function:Get-EpoLocalExchangeUpdateInventory}.ToString()
    ) -join "`n"

    foreach ($Server in $ServerName) {
        $Target = if ([string]::IsNullOrWhiteSpace($Server)) { $env:COMPUTERNAME } else { $Server }
        try {
            if ($Target -in @($env:COMPUTERNAME, 'localhost', '.', $env:COMPUTERNAME.ToLowerInvariant())) {
                $Servers.Add((Get-EpoLocalExchangeUpdateInventory -ServerName $env:COMPUTERNAME))
            }
            else {
                $RemoteResult = Invoke-Command -ComputerName $Target -ScriptBlock {
                    param($RemoteServerName, $FunctionDefinitions)
                    Invoke-Expression $FunctionDefinitions
                    Get-EpoLocalExchangeUpdateInventory -ServerName $RemoteServerName
                } -ArgumentList $Target, $RemoteDefinitions
                $Servers.Add($RemoteResult)
            }
        }
        catch {
            $Servers.Add([pscustomobject] @{
                Server = $Target
                CollectedAtUtc = [datetime]::UtcNow.ToString('o')
                Status = 'Failed'
                ExchangeSetup = [pscustomobject] @{
                    InstallPath = ''
                    MsiProductMajor = ''
                    MsiProductMinor = ''
                    MsiBuildMajor = ''
                    MsiBuildMinor = ''
                    ConfiguredVersion = ''
                    FileVersion = ''
                    ProductVersion = ''
                    ExSetupPath = ''
                }
                InstalledUpdates = @()
                Evidence = [pscustomobject] @{
                    RegistryPaths = @()
                    FilePaths = @()
                    SetupLogPaths = @()
                    Notes = @("Inventory failed: $($_.Exception.Message)")
                }
            })
        }
    }

    [pscustomobject] @{
        InventorySchemaVersion = '1.0'
        CollectedAtUtc = [datetime]::UtcNow.ToString('o')
        Servers = @($Servers.ToArray())
    }
}

function Export-EpoUpdateInventoryCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [pscustomobject] $RunContext,
        [Parameter(Mandatory)] [pscustomobject] $Inventory
    )

    $Path = Join-Path $RunContext.EvidencePath 'UpdateInventory.csv'
    $Rows = foreach ($ServerInventory in $Inventory.Servers) {
        if (@($ServerInventory.InstalledUpdates).Count -eq 0) {
            [pscustomobject] @{
                CorrelationId = $RunContext.CorrelationId
                Server = $ServerInventory.Server
                Status = $ServerInventory.Status
                CurrentBuild = Get-EpoObjectValue -InputObject $ServerInventory.ExchangeSetup -PropertyName 'FileVersion'
                Type = ''
                DisplayName = ''
                KB = ''
                InstalledOn = ''
                DisplayVersion = ''
                Source = ''
            }
            continue
        }
        foreach ($Update in $ServerInventory.InstalledUpdates) {
            [pscustomobject] @{
                CorrelationId = $RunContext.CorrelationId
                Server = $ServerInventory.Server
                Status = $ServerInventory.Status
                CurrentBuild = Get-EpoObjectValue -InputObject $ServerInventory.ExchangeSetup -PropertyName 'FileVersion'
                Type = $Update.Type
                DisplayName = $Update.DisplayName
                KB = $Update.KB
                InstalledOn = $Update.InstalledOn
                DisplayVersion = $Update.DisplayVersion
                Source = $Update.Source
            }
        }
    }
    $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

Export-ModuleMember -Function Get-EpoExchangeUpdateInventory, Export-EpoUpdateInventoryCsv
