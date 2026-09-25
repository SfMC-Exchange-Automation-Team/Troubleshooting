BeforeAll {
    $script:packageRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:packageRoot 'KB5130098.psm1') -Force
}

Describe 'Management workstation builder' {
    BeforeEach {
        $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:rules = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:rules -ItemType Directory
        foreach ($name in @('ko.token.rule.bin', 'ko.complex.rule.bin')) {
            'Fixture only, not a Microsoft payload' | Set-Content -LiteralPath (Join-Path $script:rules $name)
        }
        Mock Import-Module {}
        Mock Assert-KBAdministrator {}
        Mock Assert-KBPayload {}
        Mock Test-Path { [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath) }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        Mock Start-Process { throw 'Tests must not launch installers' }
        Mock Invoke-WebRequest { throw 'Tests must not download software' }
    }

    It 'creates a small ZIP with only the named payload and runtime files' {
        $result = & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed
        (Test-Path -LiteralPath $result.Package) | Should -BeTrue
        $result.SHA256 | Should -Be (Get-FileHash -LiteralPath $result.Package -Algorithm SHA256).Hash
        $expanded = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Expand-Archive -LiteralPath $result.Package -DestinationPath $expanded
        $files = @(Get-ChildItem -LiteralPath $expanded -File -Recurse)
        $files.Count | Should -Be 8
        @($files | Where-Object Extension -in '.exe', '.msi', '.dll').Count | Should -Be 0
        @($files | Where-Object Name -like '*.bin').Count | Should -Be 2
        Should -Invoke Assert-KBPayload -Times 2 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'refuses an existing output directory' {
        $null = New-Item -Path $script:output -ItemType Directory
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*already exists*'
    }

    It 'refuses to extract on an Exchange machine' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -RuleSourceDirectory $script:rules -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*Exchange installation*'
    }

    It 'rejects untrusted Microsoft media before execution' {
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*valid Microsoft Authenticode*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'stops if extract-only reports a nonzero exit code' {
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } }
        }
        Mock Start-Process { [pscustomobject]@{ ExitCode = 42 } }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*extract-only failed*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -like '/q /x:*' }
    }

    It 'uses administrative extraction and rejects even reboot-success MSI codes' {
        $media = Join-Path $TestDrive 'fake-sql.exe'
        'Fixture only' | Set-Content -LiteralPath $media
        Mock Assert-KBIdentity {}
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' } }
        }
        Mock Start-Process {
            $extract = [regex]::Match(($ArgumentList -join ' '), '^/q /x:"([^"]+)"$')
            if ($extract.Success) {
                $setup = Join-Path $extract.Groups[1].Value 'x64\Setup'
                $null = New-Item -Path $setup -ItemType Directory -Force
                'MSI fixture only' | Set-Content -LiteralPath (Join-Path $setup 'SQL_FULLTEXT.MSI')
                return [pscustomobject]@{ ExitCode = 0 }
            }
            [pscustomobject]@{ ExitCode = 3010 }
        }
        { & (Join-Path $script:packageRoot 'Build-KB5130098Package.ps1') -SqlPackagePath $media -OutputDirectory $script:output -WorkRoot $script:work -ManagementWorkstationConfirmed } | Should -Throw '*administrative extraction failed*'
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like '*\msiexec.exe' -and $ArgumentList -like '/a *' -and $ArgumentList -like '* /qn /norestart /L*V *'
        }
    }
}

Describe 'Serial fleet rollout with mocked remoting' {
    BeforeEach {
        $script:reports = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:KB5130098TestContext = @{
            Events = (New-Object Collections.Generic.List[string])
            Target = ''
            Eligible = $true
        }
        Mock Import-Module {}
        Mock Assert-KBPayload {}
        Mock New-PSSession {
            $global:KB5130098TestContext.Target = $ComputerName
            $global:KB5130098TestContext.Events.Add("Connect $ComputerName")
            New-MockObject -Type System.Management.Automation.Runspaces.PSSession
        }
        Mock Remove-PSSession {}
        Mock Copy-Item {}
        Mock Invoke-Command {
            $text = $ScriptBlock.ToString()
            $context = $global:KB5130098TestContext
            if ($text.Contains('WindowsPrincipal')) {
                return [pscustomobject]@{ Path = "C:\ProgramData\Fixture\$($context.Target)"; ComputerName = $context.Target }
            }
            if ($text.Contains('Get-FileHash')) { return }
            if ($text.Contains('Invoke-KBLocal -Mode Detect')) {
                return [pscustomobject]@{ Eligible = $context.Eligible; Status = $(if ($context.Eligible) { 'EligibleMissingBothRules' } else { 'NotApplicableStop' }) }
            }
            if ($text.Contains('Invoke-KBLocal -Mode Apply')) {
                $context.Events.Add("Apply $($context.Target)")
                return [pscustomobject]@{ Status = 'RestartedWorkloadValidationRequired'; ReceiptPath = 'C:\ProgramData\Fixture\receipt.json' }
            }
            if ($text.Contains('New-Item -Path (Join-Path')) {
                return "C:\ProgramData\Fixture\$($context.Target)\payload"
            }
            throw "Unexpected remoting request in test: $text"
        }
        Mock Read-Host {
            $global:KB5130098TestContext.Events.Add("Attest $($global:KB5130098TestContext.Target)")
            "RECOVERED $($global:KB5130098TestContext.Target)"
        }
    }
    AfterEach {
        Remove-Variable -Name KB5130098TestContext -Scope Global
    }

    It 'never connects to the second server before recovery attestation on the first' {
        $result = & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -MaintenanceWindowApproved -Confirm:$false
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com|Attest EX01.example.com|Connect EX02.example.com|Apply EX02.example.com|Attest EX02.example.com'
        $report = Get-Content -LiteralPath $result.Report -Raw | ConvertFrom-Json
        $report.Count | Should -Be 2
        $report[1].Status | Should -Be 'OperatorConfirmedRecovery'
        Should -Invoke Remove-PSSession -Times 2 -Exactly
    }

    It 'stops rollout immediately if recovery is not confirmed' {
        Mock Read-Host { 'STOP' }
        { & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*Recovery was not confirmed*'
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Apply EX01.example.com'
        Should -Invoke Remove-PSSession -Times 1 -Exactly
    }

    It 'stops rollout immediately on a nonapplicable installation' {
        $global:KB5130098TestContext.Eligible = $false
        { & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -MaintenanceWindowApproved -Confirm:$false } | Should -Throw '*not eligible*'
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com'
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Detect never applies or requests a recovery attestation' {
        $result = & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Detect -ComputerName EX01.example.com,EX02.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -Confirm:$false
        ($global:KB5130098TestContext.Events -join '|') | Should -Be 'Connect EX01.example.com|Connect EX02.example.com'
        $result.Servers | Should -Be 2
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'WhatIf makes no connections and writes no report' {
        & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply -ComputerName EX01.example.com -PackageDirectory $script:packageRoot -ReportDirectory $script:reports -MaintenanceWindowApproved -WhatIf
        Should -Invoke New-PSSession -Times 0 -Exactly
        (Test-Path -LiteralPath $script:reports) | Should -BeFalse
    }

    It 'requires maintenance approval and explicit unique host names' {
        { & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -Mode Apply -ComputerName EX01.example.com -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*MaintenanceWindowApproved*'
        { & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -ComputerName 'EX*' -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*explicit DNS*'
        { & (Join-Path $script:packageRoot 'Invoke-KB5130098Fleet.ps1') -ComputerName EX01,EX01 -ReportDirectory $script:reports -Confirm:$false } | Should -Throw '*Duplicate*'
        Should -Invoke New-PSSession -Times 0 -Exactly
    }
}
