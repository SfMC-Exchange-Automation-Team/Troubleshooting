#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '..\Private\Resilience.ps1')
}

Describe 'Test-MFAReportTransientError' {

    Context 'transient shapes are retried' {
        It 'recognises <Message>' -ForEach @(
            @{ Message = 'The server is busy. Please try again.' }
            @{ Message = 'Micro delay applied to this request' }
            @{ Message = 'Request limit exceeded for this tenant' }
            @{ Message = 'HTTP 429 Too Many Requests' }
            @{ Message = 'The service returned 503' }
            @{ Message = 'The operation has timed out' }
            @{ Message = 'The underlying connection was closed' }
            @{ Message = 'Cmdlet throttling is in effect' }
            @{ Message = 'The service is temporarily unavailable' }
        ) {
            Test-MFAReportTransientError -Message $Message | Should -BeTrue
        }
    }

    Context 'terminal errors must NOT be retried' {
        It 'does not retry <Message>' -ForEach @(
            @{ Message = "The operation couldn't be performed because object 'x@contoso.com' couldn't be found." }
            @{ Message = 'Access is denied.' }
            @{ Message = "A parameter cannot be found that matches parameter name 'Foo'." }
            @{ Message = 'The retention policy was not found.' }
        ) {
            # Retrying these would multiply the runtime of a run with a stale
            # identity list and change nothing about the outcome.
            Test-MFAReportTransientError -Message $Message | Should -BeFalse
        }

        It 'does not treat a digit run inside a larger token as an HTTP status' {
            Test-MFAReportTransientError -Message "Mailbox 'user4297@contoso.com' was not found" | Should -BeFalse
        }
    }

    It 'returns false for an empty message' {
        Test-MFAReportTransientError -Message '' | Should -BeFalse
    }
}

Describe 'Get-MFAReportRetryDelay' {

    It 'returns 0 when waiting is disabled' {
        Get-MFAReportRetryDelay -Attempt 3 -InitialDelaySeconds 0 | Should -Be 0
    }

    It 'never exceeds the cap' {
        1..8 | ForEach-Object {
            Get-MFAReportRetryDelay -Attempt $_ -InitialDelaySeconds 2 -MaxDelaySeconds 10 |
                Should -BeLessOrEqual 10
        }
    }

    It 'grows with the attempt number' {
        # Full jitter makes any single draw random, so compare distributions.
        $early = (1..40 | ForEach-Object { Get-MFAReportRetryDelay -Attempt 1 -InitialDelaySeconds 4 -MaxDelaySeconds 600 } |
            Measure-Object -Average).Average
        $late = (1..40 | ForEach-Object { Get-MFAReportRetryDelay -Attempt 5 -InitialDelaySeconds 4 -MaxDelaySeconds 600 } |
            Measure-Object -Average).Average
        $late | Should -BeGreaterThan $early
    }

    It 'applies jitter rather than a fixed delay' {
        $draws = 1..40 | ForEach-Object { Get-MFAReportRetryDelay -Attempt 6 -InitialDelaySeconds 2 -MaxDelaySeconds 60 }
        @($draws | Sort-Object -Unique).Count | Should -BeGreaterThan 1
    }
}

Describe 'Invoke-MFAReportRetry' {

    It 'returns the value on first success without retrying' {
        $script:calls = 0
        $result = Invoke-MFAReportRetry -Operation 'test' -InitialDelaySeconds 0 -ScriptBlock {
            $script:calls++
            'ok'
        }
        $result | Should -Be 'ok'
        $script:calls | Should -Be 1
    }

    It 'retries a transient failure and then succeeds' {
        $script:calls = 0
        $result = Invoke-MFAReportRetry -Operation 'test' -InitialDelaySeconds 0 -MaxAttempt 4 -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw 'The server is busy. Please try again.' }
            'recovered'
        }
        $result | Should -Be 'recovered'
        $script:calls | Should -Be 3
    }

    It 'gives up after MaxAttempt and rethrows' {
        $script:calls = 0
        {
            Invoke-MFAReportRetry -Operation 'test' -InitialDelaySeconds 0 -MaxAttempt 3 -ScriptBlock {
                $script:calls++
                throw 'Request limit exceeded'
            }
        } | Should -Throw
        $script:calls | Should -Be 3
    }

    It 'does not retry a terminal error' {
        $script:calls = 0
        {
            Invoke-MFAReportRetry -Operation 'test' -InitialDelaySeconds 0 -MaxAttempt 5 -ScriptBlock {
                $script:calls++
                throw "The object 'x@contoso.com' couldn't be found."
            }
        } | Should -Throw
        $script:calls | Should -Be 1
    }

    It 'preserves the original error message when it gives up' {
        {
            Invoke-MFAReportRetry -Operation 'test' -InitialDelaySeconds 0 -MaxAttempt 2 -ScriptBlock {
                throw 'The server is busy, distinctive marker 12345'
            }
        } | Should -Throw -ExpectedMessage '*distinctive marker 12345*'
    }
}
