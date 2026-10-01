BeforeAll {
    $script:root=Split-Path $PSScriptRoot -Parent
    $script:spec=Import-PowerShellDataFile -LiteralPath (Join-Path $script:root 'KoreanRules.psd1')
    $script:native=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Import-Module (Join-Path $script:root 'KoreanRules.psm1') -Force
}

Describe 'Published ready-to-use payload' {
    It 'includes exactly the two pinned Microsoft rule files' {
        $directory=Join-Path $script:root 'payload'
        @(Get-ChildItem -LiteralPath $directory -File | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -Be @('ko.complex.rule.bin','ko.token.rule.bin')
        foreach ($rule in $script:spec.Rules) {
            $path=Join-Path $directory $rule.Name
            (Get-Item -LiteralPath $path).Length | Should -Be $rule.Bytes
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $rule.SHA256
        }
        { Assert-KBPayload -Directory $directory } | Should -Not -Throw
    }

    It 'verifies the actual bundled kit from a different directory without creating files' {
        $before=@(Get-ChildItem -LiteralPath $script:root -Recurse -File |
            Sort-Object FullName | Select-Object FullName,Length,LastWriteTimeUtc) | ConvertTo-Json
        Push-Location $TestDrive
        try {
            $output=& $script:native -NoProfile -NonInteractive -File (Join-Path $script:root 'Install-KoreanRules.ps1')
            $LASTEXITCODE | Should -Be 0
            ($output -join "`n") | Should -Match 'Default payload ready for this kit'
            ($output -join "`n") | Should -Not -Match 'Downloading|Extracting|portable package created|No source selected'
        } finally { Pop-Location }
        $after=@(Get-ChildItem -LiteralPath $script:root -Recurse -File |
            Sort-Object FullName | Select-Object FullName,Length,LastWriteTimeUtc) | ConvertTo-Json
        $after | Should -BeExactly $before
    }

    It 'uses the actual bundled default for a remote restart preview without contacting targets' {
        $output=& $script:native -NoProfile -NonInteractive -File (Join-Path $script:root 'Set-KoreanRulesState.ps1') `
            -ComputerName example.invalid -RestartSearch -WhatIf -AsJson
        $LASTEXITCODE | Should -Be 0
        $plan=($output -join "`n") | ConvertFrom-Json
        $plan.Servers | Should -Be 0
        $plan.Targets | Should -Be @('example.invalid')
    }
}
