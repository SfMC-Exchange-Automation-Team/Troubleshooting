BeforeAll {
    $script:root=Split-Path $PSScriptRoot -Parent
    $script:version=(Import-PowerShellDataFile -LiteralPath (Join-Path $script:root 'KoreanRules.psd1')).PackageVersion
}

Describe 'Current repository and historical archive separation' {
    It 'presents exactly the three recommended scripts at the tool root' {
        @(Get-ChildItem -LiteralPath $script:root -Filter '*.ps1' -File | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -Be @('Get-KoreanRulesState.ps1','Install-KoreanRules.ps1','Set-KoreanRulesState.ps1')
    }

    It 'keeps only the latest source ZIP and checksum in active downloads' {
        $name="Exchange-KoreanRules-$($script:version)-source.zip"
        @(Get-ChildItem -LiteralPath (Join-Path $script:root 'downloads') -File | Select-Object -ExpandProperty Name | Sort-Object) |
            Should -Be @($name,"$name.sha256")
    }

    It 'preserves a matching checksum alongside every current and archived ZIP' {
        foreach ($folder in @('downloads','archive\downloads')) {
            $archives=@(Get-ChildItem -LiteralPath (Join-Path $script:root $folder) -Filter '*.zip' -File)
            $archives.Count | Should -BeGreaterThan 0
            foreach ($archive in $archives) {
                $record=[IO.File]::ReadAllText("$($archive.FullName).sha256").Trim()
                $record | Should -Be ((Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash+'  '+$archive.Name)
            }
        }
    }

    It 'keeps the latest available recording active and previous recordings in the archive' {
        @(Get-ChildItem -LiteralPath (Join-Path $script:root 'docs') -Filter '*-Walkthrough.mp4' -File).Count | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $script:root 'docs') -Filter 'Exchange-KB5130098-*' -File).Count | Should -Be 0
        foreach($version in @('1.0.1','1.2.1')) {
            Test-Path -LiteralPath (Join-Path $script:root "archive\media\$version\Exchange-KB5130098-$version-Walkthrough.mp4") | Should -BeTrue
        }
    }

    It 'can import the compatibility module from its archived location' {
        $module=Join-Path $script:root 'archive\compatibility\KB5130098.psm1'
        $command='Import-Module ''{0}'' -Force -ErrorAction Stop; (Get-KBSpecification).PackageVersion' -f $module
        $native=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $output=& $native -NoProfile -NonInteractive -Command $command
        $LASTEXITCODE | Should -Be 0
        ($output -join '').Trim() | Should -Be $script:version
    }
}
