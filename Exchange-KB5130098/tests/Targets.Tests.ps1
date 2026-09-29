BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KB5130098.psm1') -Force
}

Describe 'Strict ordered CSV and direct target validation' {
    InModuleScope KB5130098 {
        BeforeEach {
            $script:csv = Join-Path $TestDrive (([guid]::NewGuid().ToString('N')) + '.csv')
        }

        It 'reads a UTF8 CSV with quoted fields, a BOM and extra metadata columns' {
            '"ComputerName","Site","Notes"', '" EX02.example.com ","A","contains, comma"', '"EX01.example.com","B","second"' |
                Set-Content -LiteralPath $script:csv -Encoding UTF8
            $names = @(Resolve-KBTargets -CsvPath $script:csv)
            $names | Should -Be @('EX02.example.com', 'EX01.example.com')
        }

        It 'accepts a one-column, one-server file without collapsing the name to characters' {
            "ComputerName`r`nEX01" | Set-Content -LiteralPath $script:csv -Encoding UTF8
            $names = @(Resolve-KBTargets -CsvPath $script:csv)
            $names.Count | Should -Be 1
            $names[0] | Should -Be 'EX01'
        }

        It 'accepts case-insensitive headers and preserves input order' {
            " computername ,Notes`r`nEX03,first`r`nEX01,second" | Set-Content -LiteralPath $script:csv
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX03', 'EX01')
        }

        It 'handles quoted multiline metadata without treating it as another target' {
            "ComputerName,Notes`r`nEX01,`"line one`r`nline two`"`r`nEX02,last" | Set-Content -LiteralPath $script:csv
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX01', 'EX02')
        }

        It 'accepts the native Exchange server column <Header>' -ForEach @(
            @{ Header='Name' }, @{ Header='Fqdn' }, @{ Header=' fqDN ' }
        ) {
            "$Header,Site`r`nEX02.example.com,A`r`nEX01.example.com,B" | Set-Content -LiteralPath $script:csv
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX02.example.com','EX01.example.com')
        }

        It 'prefers Fqdn over Name regardless of column order' -ForEach @(
            @{ Content="Name,Fqdn`r`nEX01,EX01.example.com" }
            @{ Content="Fqdn,Name`r`nEX01.example.com,EX01" }
        ) {
            $Content | Set-Content -LiteralPath $script:csv
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX01.example.com')
        }

        It 'preserves explicit ComputerName precedence over Exchange inventory columns' {
            "Name,Fqdn,ComputerName`r`nEX01,EX01.example.com,EX02.example.com" | Set-Content -LiteralPath $script:csv
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX02.example.com')
        }

        It 'does not fall back per row when the selected column is blank or invalid' -ForEach @(
            @{ Content="Name,Fqdn`r`nEX01,"; Expected='*column Fqdn*blank Fqdn*' }
            @{ Content="Name,Fqdn`r`nEX01,EX*"; Expected='*column Fqdn*explicit DNS/NetBIOS*' }
            @{ Content="ComputerName,Fqdn`r`n,EX01.example.com"; Expected='*column ComputerName*blank ComputerName*' }
        ) {
            $Content | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw $Expected
        }

        It 'accepts ordinary Export-Csv output with its optional PowerShell type-information line' -ForEach @(
            @{ IncludeType=$true }, @{ IncludeType=$false }
        ) {
            $inventory = @(
                [pscustomobject]@{Name='EX02';Fqdn='EX02.example.com';ServerRole='Mailbox';Site='SiteA'}
                [pscustomobject]@{Name='EX01';Fqdn='EX01.example.com';ServerRole='Mailbox';Site='SiteB'}
            )
            $inventory | Export-Csv -LiteralPath $script:csv -NoTypeInformation:(-not $IncludeType) -Encoding UTF8
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX02.example.com','EX01.example.com')
        }

        It 'accepts Exchange remoting type metadata and ignores PSComputerName' {
            '#TYPE Deserialized.Microsoft.Exchange.Data.Directory.Management.ExchangeServer',
                '"PSComputerName","Name","Fqdn"',
                '"management.example.com","EX01","EX01.example.com"' |
                Set-Content -LiteralPath $script:csv -Encoding UTF8
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX01.example.com')
        }

        It 'does not infer targets from unrelated properties or remoting origin' {
            "PSComputerName,Site`r`nEX01,A" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*ComputerName, Fqdn or Name column*'
        }

        It 'rejects a type-information line without any header or records' {
            '#TYPE Microsoft.Exchange.Data.Directory.Management.ExchangeServer' | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*no header or servers*'
        }

        It 'rejects type-looking rows after the header rather than silently skipping them' {
            "Name`r`nEX01`r`n#TYPE fake" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*CSV record 3*explicit DNS/NetBIOS*'
        }

        It 'retains duplicate-target validation for Exchange inventory columns' -ForEach @(
            @{ Header='Name' }, @{ Header='Fqdn' }
        ) {
            "$Header`r`nEX01.example.com`r`n ex01.EXAMPLE.com " | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*Duplicate target*'
        }

        It 'rejects duplicate Exchange inventory headers' {
            "Name,Fqdn,FQDN`r`nEX01,EX01.example.com,EX02.example.com" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*headers*unique*'
        }

        It 'rejects empty and header-only inputs' {
            '' | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*empty*'
            'ComputerName' | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*no servers*'
        }

        It 'rejects blank target cells instead of silently skipping rows' {
            "ComputerName,Site`r`nEX01,A`r`n ,B" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*record 3*blank*'
        }

        It 'rejects duplicate names ignoring case and surrounding whitespace' {
            "ComputerName`r`nEX01.example.com`r`n ex01.EXAMPLE.com " | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*Duplicate target*'
            { Resolve-KBTargets -ComputerName @('EX01', 'ex01') } | Should -Throw '*Duplicate target*'
        }

        It 'rejects duplicate or empty header names' {
            "ComputerName,computername`r`nEX01,EX02" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*headers*unique*'
            "ComputerName,`r`nEX01,A" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*headers*nonempty*'
        }

        It 'rejects inconsistent field counts instead of dropping extra fields' {
            "ComputerName,Site`r`nEX01,A,extra" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*record 2*3 fields*2*'
            "ComputerName,Site`r`nEX01" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*record 2*1 fields*2*'
        }

        It 'rejects malformed quoted CSV' {
            "ComputerName,Notes`r`nEX01,`"never closed" | Set-Content -LiteralPath $script:csv
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw '*Malformed CSV*'
        }

        It 'rejects invalid target <Name> before any remote work' -ForEach @(
            @{ Name = 'EX*' }, @{ Name = '192.0.2.1' }, @{ Name = '::1' },
            @{ Name = 'https://EX01' }, @{ Name = 'EX01,EX02' }, @{ Name = 'EX01..example.com' },
            @{ Name = '-EX01' }, @{ Name = 'EX01-.example.com' }, @{ Name = 'EX_01' },
            @{ Name = 'EX01;Write-Host bad' }, @{ Name = 'EX01.example.com:5985' }
        ) {
            { Resolve-KBTargets -ComputerName @($Name) } | Should -Throw '*explicit DNS/NetBIOS*'
        }

        It 'rejects empty direct target lists and whitespace-only entries' {
            { Resolve-KBTargets -ComputerName @() } | Should -Throw '*no servers*'
            { Resolve-KBTargets -ComputerName @(' ') } | Should -Throw '*blank ComputerName*'
        }

        It 'rejects names with labels longer than 63 characters' {
            { Resolve-KBTargets -ComputerName @(('a' * 64) + '.example.com') } | Should -Throw '*explicit DNS/NetBIOS*'
        }

        It 'supports 2500 targets without truncation or reordering' {
            $names = @(1..2500 | ForEach-Object { 'EX{0:D4}.example.com' -f $_ })
            @('ComputerName') + $names | Set-Content -LiteralPath $script:csv -Encoding UTF8
            $actual = @(Resolve-KBTargets -CsvPath $script:csv)
            $actual.Count | Should -Be 2500
            $actual | Should -Be $names
        }

        It 'does not interpret metadata such as Enabled as an implicit target filter' {
            "ComputerName,Enabled`r`nEX01,false`r`nEX02,true" | Set-Content -LiteralPath $script:csv
            @(Resolve-KBTargets -CsvPath $script:csv) | Should -Be @('EX01', 'EX02')
        }

        It 'rejects a non-CSV file and a missing input file' {
            { Resolve-KBTargets -CsvPath (Join-Path $TestDrive 'servers.txt') } | Should -Throw '*.csv*'
            { Resolve-KBTargets -CsvPath $script:csv } | Should -Throw
        }
    }
}
