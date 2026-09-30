BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KoreanRules.psm1') -Force
}

Describe 'Literal installer source selection' {
    InModuleScope KoreanRules {
        BeforeEach {
            $script:inputRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ' New folder')
            $null=New-Item -Path $script:inputRoot -ItemType Directory
        }

        It 'accepts an exact file and a folder containing that file with <Quote> quotes' -ForEach @(
            @{Quote='None'},@{Quote='Single'},@{Quote='Double'}
        ) {
            $exe=Join-Path $script:inputRoot 'SQLEXPR_x64_ENU.exe'
            'Fixture only' | Set-Content -LiteralPath $exe
            foreach($path in @($exe,($script:inputRoot+'\'))) {
                $inputPath=switch($Quote){'Single'{" '$path' "};'Double'{' "'+$path+'" '};default{$path}}
                $result=Resolve-KBPreparationInput -Path $inputPath
                $result.Kind | Should -Be 'Media'
                $result.Path | Should -Be $exe
            }
        }

        It 'resolves a relative path without expanding embedded PowerShell expressions' {
            $name='rules $(Write-Error unexpected)'
            $folder=Join-Path $script:inputRoot $name
            $null=New-Item -Path $folder -ItemType Directory
            'Fixture only' | Set-Content -LiteralPath (Join-Path $folder 'ko.token.rule.bin')
            Push-Location $script:inputRoot
            try {
                $result=Resolve-KBPreparationInput -Path ('.\' + $name)
                $result.Kind | Should -Be 'Rules'
                $result.Path | Should -Be $folder
            } finally {Pop-Location}
        }

        It 'does not search child folders or treat an empty folder as a download destination' {
            $child=Join-Path $script:inputRoot 'child'
            $null=New-Item -Path $child -ItemType Directory
            'Fixture only' | Set-Content -LiteralPath (Join-Path $child 'SQLEXPR_x64_ENU.exe')
            {Resolve-KBPreparationInput -Path $script:inputRoot} | Should -Throw '*NO INSTALLATION SOURCE IN FOLDER*Subfolders are not searched*-OutputDirectory*'
        }

        It 'requires explicit selection when media and rules coexist' {
            foreach($name in @('SQLEXPR_x64_ENU.exe','ko.token.rule.bin','ko.complex.rule.bin')) {
                'Fixture only' | Set-Content -LiteralPath (Join-Path $script:inputRoot $name)
            }
            {Resolve-KBPreparationInput -Path $script:inputRoot} | Should -Throw '*AMBIGUOUS SOURCE FOLDER*'
            (Resolve-KBPreparationInput -Path $script:inputRoot -RulesOnly).Kind | Should -Be 'Rules'
            (Resolve-KBPreparationInput -Path (Join-Path $script:inputRoot 'SQLEXPR_x64_ENU.exe')).Kind | Should -Be 'Media'
        }

        It 'routes partial rule folders to the missing-payload check instead of guessing media' {
            'Fixture only' | Set-Content -LiteralPath (Join-Path $script:inputRoot 'ko.token.rule.bin')
            $source=Resolve-KBPreparationInput -Path $script:inputRoot
            $source.Kind | Should -Be 'Rules'
            {Assert-KBPayload -Directory $source.Path} | Should -Throw '*ko.complex.rule.bin*'
        }

        It 'rejects an empty or unmatched quoted path' -ForEach @(
            @{Value=' '},@{Value='""'},@{Value='"C:\missing'},@{Value="'C:\missing"}
        ) {
            {ConvertTo-KBInputPath -Path $Value} | Should -Throw
        }

        It 'rejects a file passed as a rule-source directory and a non-EXE input' {
            $file=Join-Path $script:inputRoot 'ko.token.rule.bin'
            'Fixture only' | Set-Content -LiteralPath $file
            {Resolve-KBPreparationInput -Path $file -RulesOnly} | Should -Throw '*needs a folder*'
            {Resolve-KBPreparationInput -Path $file} | Should -Throw '*Expected a SQL media .exe*'
        }

        It 'shows observed and required identity without requiring a Support case' {
            Mock Get-KBIdentity { [pscustomobject]@{Bytes=9018790;SHA256='INCOMPLETE';Version='17.0.1000.7'} }
            $failure=$null
            try {Assert-KBIdentity -Path 'C:\Fixture\SQLEXPR_x64_ENU.exe' -Expected $script:Spec.SqlPackage} catch {$failure=$_}
            $failure.Exception.Message | Should -Match 'Bytes: found 9018790; required 748772024'
            $failure.Exception.Message | Should -Match 'SHA256: found INCOMPLETE; required 74AA90'
            $failure.Exception.Message | Should -Match 'interrupted download'
            $failure.Exception.Message | Should -Match 'Version: found 17.0.1000.7; required 17.0.1000.7'
            $failure.Exception.Message | Should -Not -Match 'contact Microsoft Support'
        }
    }
}
