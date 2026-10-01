BeforeDiscovery {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'KoreanRules.psm1') -Force
}

Describe 'Install and Set share the adjacent payload default' {
    InModuleScope KoreanRules {
        BeforeEach {
            $script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path (Get-Module KoreanRules).ModuleBase 'KoreanRules.psd1')
            $script:caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:source = Join-Path $script:caseRoot 'prepared'
            $script:kit = Join-Path $script:caseRoot 'operator kit'
            $null = New-Item -Path $script:source,$script:kit -ItemType Directory -Force
            foreach ($rule in $script:Spec.Rules) {
                $path = Join-Path $script:source $rule.Name
                "Fixture $($rule.Name)" | Set-Content -LiteralPath $path -Encoding ASCII
                $rule.Bytes = (Get-Item -LiteralPath $path).Length
                $rule.SHA256 = (Get-FileHash -LiteralPath $path).Hash
            }
        }
        AfterAll {
            $script:Spec = Import-PowerShellDataFile -LiteralPath (Join-Path (Get-Module KoreanRules).ModuleBase 'KoreanRules.psd1')
        }

        It 'prepares the folder consumed by the default Set payload path' {
            $path = Initialize-KBDefaultPayload -SourceDirectory $script:source -PackageDirectory $script:kit
            $path | Should -Be (Join-Path $script:kit 'payload')
            Assert-KBPayload -Directory $path
            @(Get-ChildItem -LiteralPath $path -File).Count | Should -Be 2
        }

        It 'reuses matching existing files without rewriting them or unrelated files' {
            $path = Initialize-KBDefaultPayload -SourceDirectory $script:source -PackageDirectory $script:kit
            $original = Get-Item -LiteralPath (Join-Path $path 'ko.token.rule.bin')
            $original.LastWriteTimeUtc = [datetime]'2020-01-01'
            'Keep me' | Set-Content -LiteralPath (Join-Path $path 'operator.txt')
            $null = Initialize-KBDefaultPayload -SourceDirectory $path -PackageDirectory $script:kit
            (Get-Item -LiteralPath $original.FullName).LastWriteTimeUtc | Should -Be ([datetime]'2020-01-01')
            [IO.File]::ReadAllText((Join-Path $path 'operator.txt')).Trim() | Should -Be 'Keep me'
        }

        It 'fills a missing sibling only after verifying the existing prepared file' {
            $path = Join-Path $script:kit 'payload'
            $null = New-Item -Path $path -ItemType Directory
            Copy-Item -LiteralPath (Join-Path $script:source 'ko.token.rule.bin') -Destination $path
            $null = Initialize-KBDefaultPayload -SourceDirectory $script:source -PackageDirectory $script:kit
            Assert-KBPayload -Directory $path
        }

        It 'does not overwrite mismatching existing payload or add its missing sibling' {
            $path = Join-Path $script:kit 'payload'
            $null = New-Item -Path $path -ItemType Directory
            'Different operator file' | Set-Content -LiteralPath (Join-Path $path 'ko.token.rule.bin')
            { Initialize-KBDefaultPayload -SourceDirectory $script:source -PackageDirectory $script:kit } |
                Should -Throw '*IDENTITY MISMATCH*'
            [IO.File]::ReadAllText((Join-Path $path 'ko.token.rule.bin')).Trim() | Should -Be 'Different operator file'
            Test-Path -LiteralPath (Join-Path $path 'ko.complex.rule.bin') | Should -BeFalse
        }

        It 'rejects an invalid source before creating the default folder' {
            'Corrupt source' | Set-Content -LiteralPath (Join-Path $script:source 'ko.complex.rule.bin')
            { Initialize-KBDefaultPayload -SourceDirectory $script:source -PackageDirectory $script:kit } | Should -Throw '*mismatch*'
            Test-Path -LiteralPath (Join-Path $script:kit 'payload') | Should -BeFalse
        }

        It 'surfaces default-folder write failures rather than reporting a usable handoff' {
            Mock Copy-KBRuleNew { throw 'Injected write denial' }
            { Initialize-KBDefaultPayload -SourceDirectory $script:source -PackageDirectory $script:kit } |
                Should -Throw '*Default payload preparation failed*Injected write denial*'
        }
    }
}
