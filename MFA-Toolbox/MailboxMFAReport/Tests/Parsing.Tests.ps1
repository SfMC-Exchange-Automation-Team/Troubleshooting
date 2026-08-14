#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Parsing.ps1')
}

Describe 'ConvertTo-MFAReportBoolean' {

    Context 'regression: v0.10 used unanchored -match ''true|1''' {

        It 'does not treat a timestamp containing 1 as true' {
            ConvertTo-MFAReportBoolean -Value '01/01/2024 08:15:00' | Should -BeNullOrEmpty
        }

        It 'does not treat "Untrue" as true' {
            ConvertTo-MFAReportBoolean -Value 'Untrue' | Should -BeNullOrEmpty
        }

        It 'does not treat "NotTrue" as true' {
            ConvertTo-MFAReportBoolean -Value 'NotTrue' | Should -BeNullOrEmpty
        }
    }

    Context 'whole-value matches' {
        It 'parses <Value> as <Expected>' -ForEach @(
            @{ Value = 'True';     Expected = $true }
            @{ Value = 'true';     Expected = $true }
            @{ Value = ' 1 ';      Expected = $true }
            @{ Value = 'Enabled';  Expected = $true }
            @{ Value = 'False';    Expected = $false }
            @{ Value = '0';        Expected = $false }
            @{ Value = 'Disabled'; Expected = $false }
        ) {
            ConvertTo-MFAReportBoolean -Value $Value | Should -Be $Expected
        }
    }

    Context 'undetermined is distinct from false' {
        It 'returns null for empty input' {
            ConvertTo-MFAReportBoolean -Value '' | Should -BeNullOrEmpty
        }

        It 'returns null rather than false so callers can tell absent from known-false' {
            $result = ConvertTo-MFAReportBoolean -Value 'Whatever'
            $result | Should -BeNullOrEmpty
            ($null -eq $result) | Should -BeTrue
        }
    }
}

Describe 'Convert-MFAReportSizeToBytes' {

    It 'reads the parenthesised byte count' {
        Convert-MFAReportSizeToBytes -SizeString '1.234 GB (1,325,400,064 bytes)' |
            Should -Be 1325400064
    }

    Context 'regression: v0.10 summed every match, enabling double counting' {
        It 'returns only the first size when several appear in one string' {
            # FolderAndSubfolderSize is cumulative, so a parent and its children
            # each carry overlapping totals. Summing them inflated the result.
            $joined = '12.0 MB (12,582,912 bytes) 4.0 MB (4,194,304 bytes)'
            Convert-MFAReportSizeToBytes -SizeString $joined | Should -Be 12582912
        }
    }

    Context 'unlimited must not read as zero' {
        It 'returns null for Unlimited' {
            Convert-MFAReportSizeToBytes -SizeString 'Unlimited' | Should -BeNullOrEmpty
        }

        It 'returns null for an unparseable value' {
            Convert-MFAReportSizeToBytes -SizeString 'not a size' | Should -BeNullOrEmpty
        }
    }

    Context 'unit-suffixed fallback' {
        It 'parses <Value> to <Expected> bytes' -ForEach @(
            @{ Value = '512 B';   Expected = 512 }
            @{ Value = '1 KB';    Expected = 1024 }
            @{ Value = '10 MB';   Expected = 10485760 }
            @{ Value = '1.5 GB';  Expected = 1610612736 }
        ) {
            Convert-MFAReportSizeToBytes -SizeString $Value | Should -Be $Expected
        }
    }
}

Describe 'ConvertTo-MFAReportTimeSpan' {

    It 'parses a duration' {
        (ConvertTo-MFAReportTimeSpan -Value '01:30:00').TotalMinutes | Should -Be 90
    }

    It 'parses a zero duration as zero rather than null' {
        $result = ConvertTo-MFAReportTimeSpan -Value '00:00:00'
        $result | Should -Not -BeNullOrEmpty
        $result.TotalSeconds | Should -Be 0
    }

    It 'refuses to guess units for a bare number' {
        ConvertTo-MFAReportTimeSpan -Value '5' | Should -BeNullOrEmpty
    }

    It 'returns null for empty input' {
        ConvertTo-MFAReportTimeSpan -Value '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-MFAReportCount' {

    It 'parses a plain integer' {
        ConvertTo-MFAReportCount -Value '4212' | Should -Be 4212
    }

    It 'parses a thousands-separated integer' {
        ConvertTo-MFAReportCount -Value '1,048,576' | Should -Be 1048576
    }

    It 'distinguishes zero from undetermined' {
        ConvertTo-MFAReportCount -Value '0' | Should -Be 0
        ConvertTo-MFAReportCount -Value ''  | Should -BeNullOrEmpty
    }
}

Describe 'Get-MFAReportPropertyValue' {

    It 'returns the value when the property exists' {
        $o = [PSCustomObject]@{ ElcProcessingDisabled = $true }
        Get-MFAReportPropertyValue -InputObject $o -Name 'ElcProcessingDisabled' | Should -BeTrue
    }

    It 'returns null for an absent property instead of throwing under StrictMode' {
        Set-StrictMode -Version 3.0
        $o = [PSCustomObject]@{ Name = 'x' }
        Get-MFAReportPropertyValue -InputObject $o -Name 'NotThere' | Should -BeNullOrEmpty
    }

    It 'returns null for a null input object' {
        Get-MFAReportPropertyValue -InputObject $null -Name 'Anything' | Should -BeNullOrEmpty
    }
}

Describe 'Select-MFAReportRegexFlag' {

    It 'extracts an XML-shaped flag value' {
        Select-MFAReportRegexFlag -Text '<DelayHoldApplied>True</DelayHoldApplied>' -Name 'DelayHoldApplied' |
            Should -Be 'True'
    }

    It 'extracts a key-value shaped flag' {
        Select-MFAReportRegexFlag -Text 'DelayHoldApplied: False;' -Name 'DelayHoldApplied' |
            Should -Be 'False'
    }

    It 'extracts a JSON-shaped flag' {
        Select-MFAReportRegexFlag -Text '"ELCItemCount":"512"' -Name 'ELCItemCount' |
            Should -Be '512'
    }

    It 'returns the value not a boolean, leaving interpretation to the caller' {
        $raw = Select-MFAReportRegexFlag -Text '<ResourceUnhealthy>False</ResourceUnhealthy>' -Name 'ResourceUnhealthy'
        $raw | Should -Be 'False'
        ConvertTo-MFAReportBoolean -Value $raw | Should -BeFalse
    }

    It 'returns null when the flag is absent' {
        Select-MFAReportRegexFlag -Text '<Other>1</Other>' -Name 'DelayHoldApplied' | Should -BeNullOrEmpty
    }
}
