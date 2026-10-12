#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
The privacy gate exists because Microsoft documents that a Teams client with multiple signed-in
accounts emits diagnostics for all of them, regardless of tenant or cloud. On a customer endpoint
that sweeps in identities from unrelated organisations.

The failure is one-way. Once a bundle has been handed over, an unnoticed foreign identity inside it
cannot be recalled - so an unrecognised account stops the run rather than warning about it.

Scanning three real MSTeams_*.log files returned zero matches for tenantId, orgid, a known tenant
GUID or any email address, so the gate is built on account ids from app_settings.json rather than
on tenant ids that are not present in the evidence.
#>

BeforeAll {
    $script:ToolboxRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Logging.psm1') -Force
    Import-Module (Join-Path $script:ToolboxRoot 'Modules\Tlc.Privacy.psm1') -Force

    # A gate decision is recorded as a blocker, which needs an active run.
    $script:NewRun = {
        param([string] $Name)
        Initialize-TlcRun -RunRoot (Join-Path $TestDrive $Name) -Scenario 'DesktopLaunchCrash' | Out-Null
    }

    $script:Inventory = {
        param([string[]] $AccountId)
        return [ordered]@{
            Accounts = @($AccountId | ForEach-Object {
                [ordered]@{ Id = $_; MaskedId = (Protect-TlcIdentifier -Value $_) }
            })
            AccountCount     = $AccountId.Count
            MultipleAccounts = ($AccountId.Count -gt 1)
            DistinctUpnCount = 0
            Guids            = @()
            ClientArchives   = @()
            FilesScanned     = 1
        }
    }
}

Describe 'Protect-TlcIdentifier' {

    It 'masks the local part of an address but keeps the domain' {
        Protect-TlcIdentifier -Value 'alice@example.test' | Should -Be 'al***@example.test'
    }

    It 'does not restate the middle of a GUID' {
        $masked = Protect-TlcIdentifier -Value 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $masked | Should -Not -BeLike '*bbbb*'
    }

    It 'is stable, so the same identity stays correlatable across a run' {
        $first = Protect-TlcIdentifier -Value 'user@contoso.com'
        $second = Protect-TlcIdentifier -Value 'user@contoso.com'
        $first | Should -Be $second
    }
}

Describe 'Test-TlcPrivacyGate' {

    It 'blocks an account that is not on the known list' {
        & $script:NewRun 'gate-unknown'
        $result = Test-TlcPrivacyGate `
            -Privacy @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                        BlockOnUnknownAccount = $true; RequireConsent = $false; ConsentGrantedBy = '' } `
            -Inventory (& $script:Inventory 'aaaaaaaa-0000-0000-0000-000000000001')

        $result.Blocked | Should -BeTrue
        $result.Status | Should -Be 'Blocked'
    }

    It 'names the offending account in masked form' {
        & $script:NewRun 'gate-named'
        $result = Test-TlcPrivacyGate `
            -Privacy @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                        BlockOnUnknownAccount = $true; RequireConsent = $false; ConsentGrantedBy = '' } `
            -Inventory (& $script:Inventory 'aaaaaaaa-0000-0000-0000-000000000001')

        # Enough to identify which account, without republishing it in a new file.
        $result.UnknownAccounts | Should -Not -BeNullOrEmpty
        $result.UnknownAccounts[0] | Should -Not -Be 'aaaaaaaa-0000-0000-0000-000000000001'
    }

    It 'passes a known account once consent is recorded' {
        & $script:NewRun 'gate-known'
        $result = Test-TlcPrivacyGate `
            -Privacy @{ KnownAccountIds = @('aaaaaaaa-0000-0000-0000-000000000001')
                        KnownTenantIds = @(); HomeTenantId = ''
                        BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = 'Test Operator' } `
            -Inventory (& $script:Inventory 'aaaaaaaa-0000-0000-0000-000000000001')

        $result.Blocked | Should -BeFalse
    }

    It 'blocks on missing consent even when every account is known' {
        & $script:NewRun 'gate-consent'
        $result = Test-TlcPrivacyGate `
            -Privacy @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                        BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = '' } `
            -Inventory (& $script:Inventory @())

        $result.Blocked | Should -BeTrue
    }

    It 'reports multiple signed-in accounts even when all are known' {
        & $script:NewRun 'gate-multi'
        $result = Test-TlcPrivacyGate `
            -Privacy @{ KnownAccountIds = @('aaaaaaaa-0000-0000-0000-000000000001',
                                            'bbbbbbbb-0000-0000-0000-000000000002')
                        KnownTenantIds = @(); HomeTenantId = ''
                        BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = 'Test Operator' } `
            -Inventory (& $script:Inventory @('aaaaaaaa-0000-0000-0000-000000000001',
                                              'bbbbbbbb-0000-0000-0000-000000000002'))

        $result.Blocked | Should -BeFalse
        ($result.Reasons -join ' ') | Should -BeLike '*2 accounts are signed in*'
    }

    It 'reports the known tenants it saw in masked form' {
        # Finding 296. This list went into Manifest.json raw - the last raw tenant id in a
        # default bundle - while UnknownAccounts beside it was already masked.
        & $script:NewRun 'gate-tenants'
        $tenant = 'cccccccc-1111-2222-3333-444444444444'
        $inventory = & $script:Inventory 'aaaaaaaa-0000-0000-0000-000000000001'
        $inventory.Guids = @($tenant)
        $result = Test-TlcPrivacyGate `
            -Privacy @{ KnownAccountIds = @('aaaaaaaa-0000-0000-0000-000000000001'); KnownTenantIds = @($tenant); HomeTenantId = ''
                        BlockOnUnknownAccount = $true; RequireConsent = $false; ConsentGrantedBy = '' } `
            -Inventory $inventory

        @($result.KnownTenantsSeen).Count | Should -Be 1 -Because 'the tenant was seen, so it has to be reported'
        @($result.KnownTenantsSeen)[0] | Should -Not -BeExactly $tenant
        @($result.KnownTenantsSeen)[0] | Should -Match '^cccccccc.*4444$'
    }
}

Describe 'The gate says how to fix what it refused, and only that' {
    <#
        Finding 336. Every refusal that was not a credential or an unreadable file got one
        sentence: "declare the account ids, give consent for this run, or remove the affected
        evidence". Read as three alternatives it told an operator held by an undeclared account
        that consent would clear it - measured on the 0.1.23 package, it does not - and it was
        written on a clean verdict too, and on only the first of several blocking causes.

        Each test reads the row the gate writes, which is what Blockers.csv and the transcript
        carry, not a helper.
    #>

    BeforeAll {
        $script:Unknown = 'aaaaaaaa-0000-0000-0000-000000000001'
        $script:GateRow = {
            param([string] $Name, [hashtable] $Privacy, $Inventory)
            & $script:NewRun $Name
            $verdict = Test-TlcPrivacyGate -Privacy $Privacy -Inventory $Inventory
            $row = Import-Csv (Join-Path (Get-TlcRun).RunPath 'Blockers.csv') | Where-Object { $_.Check -eq 'Privacy.Gate' } | Select-Object -Last 1
            return [pscustomobject]@{ Verdict = $verdict; Row = $row }
        }
    }

    It 'stays blocked on an undeclared account when consent is given, and does not offer consent as the fix' {
        $gate = & $script:GateRow 'fix-account' @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                                                  BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = 'Test Operator' } `
                                               (& $script:Inventory $script:Unknown)
        $gate.Verdict.Blocked | Should -BeTrue -Because 'consent does not clear an account block, which is what the remediation now says'
        $gate.Row.Remediation | Should -Match 'Declare these accounts'
        $gate.Row.Remediation | Should -Match 'Recording consent does not clear this'
        $gate.Row.Remediation | Should -Not -Match '-ConsentGrantedBy|Consent granted by' -Because 'consent is given and is not the fix'
        @($gate.Verdict.Fixes).Count | Should -Be 1
    }

    It 'names consent, and only consent, when consent is what is missing' {
        $gate = & $script:GateRow 'fix-consent' @{ KnownAccountIds = @($script:Unknown); KnownTenantIds = @(); HomeTenantId = ''
                                                  BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = '' } `
                                               (& $script:Inventory $script:Unknown)
        $gate.Verdict.Blocked | Should -BeTrue
        $gate.Row.Remediation | Should -Match 'Consent granted by'
        $gate.Row.Remediation | Should -Match '-ConsentGrantedBy'
        $gate.Row.Remediation | Should -Not -Match 'Declare' -Because 'every account is declared'
    }

    It 'gives a fix for every blocking cause at once, so one pass clears them all' {
        $inventory = & $script:Inventory $script:Unknown
        $inventory['CredentialFiles'] = @('teams.har')
        $gate = & $script:GateRow 'fix-all' @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                                              BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = '' } $inventory
        @($gate.Verdict.Fixes).Count | Should -Be 3
        $gate.Row.Remediation | Should -Match 'HAR'
        $gate.Row.Remediation | Should -Match 'Declare these accounts'
        $gate.Row.Remediation | Should -Match 'Consent granted by'
        $gate.Row.Remediation | Should -Match 'press Package again' -Because 'the closing step is said once, after every fix'
    }

    It 'writes each fix as a line the window can say in its own language' {
        <#
            Finding 338. The wizard shows a refused Package as the run printed it, and says the
            lines that tell the operator what to do in the window's language by recognising
            each one whole, against Get-TlcPackageRefusalText. A fix the gate wrote any other
            way would reach a Tamil window in English, and nothing would say so.
        #>
        $inventory = & $script:Inventory $script:Unknown
        $inventory['CredentialFiles'] = @('teams.har')
        $inventory['UnreadableFiles'] = @('locked.log')
        $gate = & $script:GateRow 'fix-said' @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                                               BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = '' } $inventory
        @($gate.Verdict.Fixes).Count | Should -Be 4 -Because 'every cause the gate can block on is present'

        $catalog = Get-TlcPackageRefusalText
        $sayable = @($catalog.Values | Where-Object { $_.Key } | ForEach-Object { [string]$_.English })
        foreach ($fix in @($gate.Verdict.Fixes)) {
            $sayable | Should -Contain $fix -Because 'the window recognises a fix by its exact English'
        }
        # And the row ends the way the catalog says, once.
        $gate.Row.Remediation | Should -Match ([regex]::Escape($catalog.Again.English) + '$')
    }
    It 'fills a refusal line the same way however its values are given, on either edition' {
        # Windows PowerShell 5.1 hands a lone array to a remaining-arguments parameter as one
        # value where PowerShell 7 unrolls it, and leaves an unbound one $null. Found by the 5.1
        # run of the window's tests in 0.1.29 (finding 339); the gate runs on both.
        $say = Get-TlcPackageRefusalText
        $expected = '2 file(s) are larger than the 100 MB scan limit and were only read in part: a.log, b.log.'
        Format-TlcRefusalText $say.ReasonPartial 2 100 'a.log, b.log' | Should -BeExactly $expected
        Format-TlcRefusalText $say.ReasonPartial @(2, 100, 'a.log, b.log') | Should -BeExactly $expected
        Format-TlcRefusalText $say.ReasonConsent | Should -BeExactly $say.ReasonConsent.English
        # Invariant culture: a size reads the same on a German machine.
        Format-TlcRefusalText $say.ReasonPartial 1 1.5 'x.log' | Should -Match '1\.5 MB'
    }
    It 'writes no remediation on a gate that passed' {
        $gate = & $script:GateRow 'fix-none' @{ KnownAccountIds = @($script:Unknown); KnownTenantIds = @(); HomeTenantId = ''
                                               BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = 'Test Operator' } `
                                            (& $script:Inventory $script:Unknown)
        $gate.Verdict.Status | Should -Be 'Success'
        $gate.Row.Remediation | Should -BeNullOrEmpty -Because 'a clean verdict has nothing to fix'
        @($gate.Verdict.Fixes).Count | Should -Be 0
    }

    It 'says what an unblocked undeclared account means when the configuration lets it through' {
        $gate = & $script:GateRow 'fix-warn' @{ KnownAccountIds = @(); KnownTenantIds = @(); HomeTenantId = ''
                                               BlockOnUnknownAccount = $false; RequireConsent = $true; ConsentGrantedBy = 'Test Operator' } `
                                            (& $script:Inventory $script:Unknown)
        $gate.Verdict.Blocked | Should -BeFalse
        $gate.Row.Remediation | Should -Match '^Not blocking, because BlockOnUnknownAccount is false'
        $gate.Row.Remediation | Should -Not -Match 'press Package again'
    }
}


Describe 'Find-TlcUpn' {
    <#
    Searching for UPNs with the bare pattern cost 4,986 ms on a real 9.8 MB collection and returned
    nothing, because the pattern starts with a character class and Teams logs are long alphanumeric
    runs - the engine consumed a run at every position before finding no '@' after it.

    The search now anchors on '@' via String.IndexOf and applies the pattern only to the substring
    around each hit. That is a different algorithm reaching the same answer, so these cases pin the
    answer rather than the speed.
    #>

    It 'finds a plain address' {
        Find-TlcUpn -Text 'user@contoso.com' | Should -Be @('user@contoso.com')
    }

    It 'finds an address embedded in JSON' {
        Find-TlcUpn -Text '"upn":"adele.vance@fabrikam.com","x":1' |
            Should -Be @('adele.vance@fabrikam.com')
    }

    It 'keeps the local-part punctuation the pattern allows' {
        Find-TlcUpn -Text "a.b+tag_1%o'brien@sub.domain.co.uk end" |
            Should -Be @("a.b+tag_1%o'brien@sub.domain.co.uk")
    }

    It 'drops a sentence-ending full stop rather than rejecting the address' {
        # Widening right over domain characters swallows the stop; without the trim the whole
        # candidate would fail the anchored pattern and a real UPN would go unreported.
        Find-TlcUpn -Text 'signed in as user@contoso.com. Retrying.' | Should -Be @('user@contoso.com')
    }

    It 'finds every address when they are packed together' {
        Find-TlcUpn -Text 'one@two.io,three@four.io' | Should -Be @('one@two.io', 'three@four.io')
    }

    It 'ignores an @ that is not part of an address' {
        Find-TlcUpn -Text 'see https://x.com/@handle/path' | Should -BeNullOrEmpty
        Find-TlcUpn -Text 'bad@ nope' | Should -BeNullOrEmpty
        Find-TlcUpn -Text '@leading.com' | Should -BeNullOrEmpty
    }

    It 'ignores a bare IPv4 host, which has no alphabetic TLD' {
        Find-TlcUpn -Text 'host@10.20.30.40' | Should -BeNullOrEmpty
    }

    It 'returns nothing for text with no @ at all' {
        Find-TlcUpn -Text 'MSTeams 2026-08-21T19:23:53.355634-05:00 info nothing here' |
            Should -BeNullOrEmpty
    }

    It 'tolerates empty input' {
        Find-TlcUpn -Text '' | Should -BeNullOrEmpty
    }

    It 'agrees with the original pattern across a mixed corpus' {
        # The guard on the optimisation: same input, same set of addresses, either way of looking.
        $reference = [regex]::new("[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
        $corpus = @(
            'user@contoso.com'
            '"upn":"cullen.haafke@microsoft.com"'
            'mail=BOB@CONTOSO.COM;'
            'trailing user@contoso.com. more'
            '[adele.vance@fabrikam.onmicrosoft.com]'
            'two a@b.com and c@d.org'
            'no at sign here at all'
            'https://x.com/@handle/path'
            'host@10.20.30.40'
        )

        # A loop is the only assertion here, so an empty collection would pass by doing nothing.
        @($corpus).Count | Should -BeGreaterThan 0 -Because 'the loop below carries the only assertions'
        foreach ($text in $corpus) {
            $expected = @($reference.Matches($text) | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $actual = @(Find-TlcUpn -Text $text | Sort-Object -Unique)
            ($actual -join '|') | Should -Be ($expected -join '|') -Because "input was '$text'"
        }
    }
}


Describe 'Web capture evidence and the identity scan' {
    <#
    The Web lane prints instructions telling the operator to export a HAR into the bundle, and the
    identity scan read '.log', '.json', '.txt', '.csv' and '.md'. A HAR is JSON under a different
    extension, so it was skipped entirely - while being the single richest source of identity in
    any bundle this toolbox produces.

    Demonstrated with identical bytes written twice, once as .har and once as .json: only the
    .json was scanned. With only the .har present the gate reported no addresses at all, on a file
    containing a foreign UPN, a tenant GUID and a live bearer token.
    #>

    BeforeAll {
        $script:SampleJwt = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJ1cG4iOiJhZGVsZS52YW5jZUBmYWJyaWthbS5jb20ifQ.c2ln'

        $script:NewHar = {
            param([string] $Path, [switch] $WithoutToken)
            $auth = if ($WithoutToken) { 'REDACTED' } else { "Bearer $script:SampleJwt" }
            $har = @{ log = @{ version = '1.2'; entries = @(@{
                request = @{ url = 'https://teams.microsoft.com/api/v1/me'
                             headers = @(@{ name = 'Authorization'; value = $auth }) }
                response = @{ content = @{ text = '{"userPrincipalName":"adele.vance@fabrikam.com"}' } }
            }) } } | ConvertTo-Json -Depth 12
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            Set-Content -LiteralPath $Path -Value $har -Encoding utf8
        }
    }

    It 'scans a .har, which the web lane explicitly asks the operator to add' {
        $endpoint = Join-Path $TestDrive 'har-scan'
        & $script:NewHar (Join-Path $endpoint 'WebCapture\teams.har')

        $inventory = Get-TlcIdentityInventory -EndpointPath $endpoint
        $inventory.FilesScanned | Should -Be 1
        $inventory.DistinctUpnCount | Should -Be 1
        $inventory.MaskedUpns | Should -Contain (Protect-TlcIdentifier -Value 'adele.vance@fabrikam.com')
    }

    It 'finds the same identities whether the file is named .har or .json' {
        # The regression in one line: extension decided whether the content was looked at.
        $asHar = Join-Path $TestDrive 'har-parity-a'
        $asJson = Join-Path $TestDrive 'har-parity-b'
        & $script:NewHar (Join-Path $asHar 'WebCapture\capture.har')
        & $script:NewHar (Join-Path $asJson 'WebCapture\capture.json')

        (Get-TlcIdentityInventory -EndpointPath $asHar).DistinctUpnCount |
            Should -Be (Get-TlcIdentityInventory -EndpointPath $asJson).DistinctUpnCount
    }

    It 'names a file carrying a bearer token' {
        $endpoint = Join-Path $TestDrive 'har-token'
        & $script:NewHar (Join-Path $endpoint 'WebCapture\teams.har')

        $inventory = Get-TlcIdentityInventory -EndpointPath $endpoint
        $inventory.CredentialFiles | Should -Contain 'teams.har'
    }

    It 'does not cry wolf over a capture that was redacted before export' {
        $endpoint = Join-Path $TestDrive 'har-clean'
        & $script:NewHar (Join-Path $endpoint 'WebCapture\teams.har') -WithoutToken

        (Get-TlcIdentityInventory -EndpointPath $endpoint).CredentialFiles | Should -BeNullOrEmpty
    }

    It 'does not mistake an ordinary GUID-heavy log for a credential' {
        # Teams evidence is full of long opaque strings. Only the JWT shape counts.
        $endpoint = Join-Path $TestDrive 'har-noise'
        New-Item -ItemType Directory -Path $endpoint -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $endpoint 'noise.log') -Encoding utf8 -Value @(
            '2026-08-21T19:00:00.000000-05:00 correlation aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            'sessionId=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        )

        (Get-TlcIdentityInventory -EndpointPath $endpoint).CredentialFiles | Should -BeNullOrEmpty
    }
}

Describe 'Test-TlcPrivacyGate and credential material' {

    It 'blocks on a bearer token even when everything else is approved' {
        <#
        Not governed by BlockOnUnknownAccount. That switch is about whose identities are in the
        bundle; this is about a live credential being in it. A token is not information about an
        account, it is access to one, and it keeps working for its remaining lifetime regardless
        of who ends up holding the file. There is no configuration under which shipping one is
        intended, so there is no configuration that permits it.
        #>
        & $script:NewRun 'gate-token'
        $inventory = & $script:Inventory @('known-account')
        $inventory['CredentialFiles'] = @('teams.har')

        $result = Test-TlcPrivacyGate -Inventory $inventory -Privacy @{
            KnownAccountIds       = @('known-account')
            BlockOnUnknownAccount = $false
            RequireConsent        = $false
            ConsentGrantedBy      = 'engineer@contoso.com'
            KnownTenantIds        = @()
            HomeTenantId          = ''
        }

        $result.Blocked | Should -BeTrue
        $result.Status | Should -Be 'Blocked'
        $result.CredentialFiles | Should -Contain 'teams.har'
        ($result.Reasons -join ' ') | Should -BeLike '*teams.har*'
    }

    It 'tells the operator how to fix it rather than only that it is broken' {
        & $script:NewRun 'gate-token-remediation'
        $inventory = & $script:Inventory @('known-account')
        $inventory['CredentialFiles'] = @('teams.har')

        Test-TlcPrivacyGate -Inventory $inventory -Privacy @{
            KnownAccountIds = @('known-account'); BlockOnUnknownAccount = $false
            RequireConsent = $false; ConsentGrantedBy = 'engineer@contoso.com'
            KnownTenantIds = @(); HomeTenantId = ''
        } | Out-Null

        $row = Import-Csv (Join-Path (Get-TlcRun).RunPath 'Blockers.csv') |
            Where-Object { $_.Check -eq 'Privacy.Gate' } | Select-Object -Last 1
        $row.Remediation | Should -BeLike '*HAR*'
    }

    It 'stays clean when no credential material is present' {
        & $script:NewRun 'gate-no-token'
        $result = Test-TlcPrivacyGate -Inventory (& $script:Inventory @('known-account')) -Privacy @{
            KnownAccountIds = @('known-account'); BlockOnUnknownAccount = $true
            RequireConsent = $false; ConsentGrantedBy = 'engineer@contoso.com'
            KnownTenantIds = @(); HomeTenantId = ''
        }
        $result.Blocked | Should -BeFalse
    }
}

Describe 'New-TlcConsentRecord reads its own parameter' {
    <#
        Found by running -Stage Package, not by reading code. The function referenced
        $requireConsent and $consentGrantedBy directly - the LOCALS OF Test-TlcPrivacyGate, a
        different function - while its own mandatory $Privacy parameter went unread.

        PowerShell's dynamic scoping is why it survived: a function can see its caller's
        variables, so it worked whenever it was called from a scope where those names happened
        to exist, which is what every test that exercised the gate first did. From the entry
        point they do not exist and Set-StrictMode turns the reference into a terminating
        error, so Package failed outright and produced no bundle - the stage that makes the
        deliverable, broken, with the tests green.

        These tests pass values through $Privacy and assert they come back. A function reading
        someone else's locals cannot satisfy that no matter what scope it is called from.
    #>

    It 'takes ConsentGrantedBy from the Privacy dictionary it was given' {
        $record = New-TlcConsentRecord -Privacy @{ RequireConsent = $true; ConsentGrantedBy = 'Ada Lovelace' } `
                                       -Scope @{ ScenarioName = 'Test'; WindowStart = @{ UtcTime = 'a' }; WindowEnd = @{ UtcTime = 'b' } } `
                                       -Endpoint 'HOST1'

        $record.ConsentGrantedBy | Should -Be 'Ada Lovelace'
        $record.ConsentRequired | Should -BeTrue
        $record.Endpoint | Should -Be 'HOST1'
    }

    It 'reflects a different Privacy dictionary rather than a value from anywhere else' {
        # The second call must not return the first call's answer, which is what reading an
        # outer-scope variable would produce.
        $record = New-TlcConsentRecord -Privacy @{ RequireConsent = $false; ConsentGrantedBy = 'Grace Hopper' } `
                                       -Scope @{ ScenarioName = 'Test'; WindowStart = @{ UtcTime = 'a' }; WindowEnd = @{ UtcTime = 'b' } }

        $record.ConsentGrantedBy | Should -Be 'Grace Hopper'
        $record.ConsentRequired | Should -BeFalse
    }

    It 'defaults to requiring consent when the setting is absent' {
        # Same safe direction as the gate: a config that forgot to say must not produce a
        # record asserting consent nobody gave.
        $record = New-TlcConsentRecord -Privacy @{} `
                                       -Scope @{ ScenarioName = 'Test'; WindowStart = @{ UtcTime = 'a' }; WindowEnd = @{ UtcTime = 'b' } }

        $record.ConsentRequired | Should -BeTrue
        $record.ConsentGrantedBy | Should -Be ''
    }

    It 'states the live fork rather than a window nothing was collected against' {
        # A consent record says what evidence was authorised, so its window has to be the one
        # the evidence came from. A live trace has none - it is bounded by when the operator
        # started and stopped it, which the capture session measures into Capture.json.
        #
        # Reaching for .UtcTime on the nulls a live scope carries is a terminating error under
        # Set-StrictMode -Version Latest in both editions, so this is the difference between a
        # named mode and Package failing outright on a capture bundle.
        $record = New-TlcConsentRecord -Privacy @{ ConsentGrantedBy = 'Ada Lovelace' } `
                                       -Scope @{ ScenarioName = 'Test'; WindowStart = $null; WindowEnd = $null } `
                                       -Endpoint 'HOST1'

        $record.WindowMode | Should -Be 'Live'
        $record.WindowStartUtc | Should -Be ''
        $record.WindowEndUtc | Should -Be ''
        $record.ConsentGrantedBy | Should -Be 'Ada Lovelace' -Because 'only the window is unknown, not who authorised it'
    }

    It 'names the retrospective fork when there is a real window' {
        $record = New-TlcConsentRecord -Privacy @{} `
                                       -Scope @{ ScenarioName = 'Test'; WindowStart = @{ UtcTime = 'a' }; WindowEnd = @{ UtcTime = 'b' } }

        $record.WindowMode | Should -Be 'Retrospective'
        $record.WindowStartUtc | Should -Be 'a'
        $record.WindowEndUtc | Should -Be 'b'
    }
}

Describe 'The affected user is seeded, and the seed never outranks a real answer' {
    <#
        In most collections the person at the keyboard IS the affected user, and a field that
        starts empty is one that gets left empty - which costs the bundle its subject.

        Seeding it interacts with the case-history restore, which brings back the user recorded
        against a remembered case. That restore used to fire only into an EMPTY box, so seeding
        would have silently switched it off and a remembered case would come back labelled for
        whoever happened to be at the keyboard. That is the precise mislabelling the restore
        exists to prevent, which is why the condition tests against the SEED rather than
        against emptiness.
    #>
    BeforeAll {
        $script:UserSource = Get-Content -LiteralPath (Join-Path $script:ToolboxRoot 'Modules\Tlc.Ui.Wizard.psm1') -Raw
    }

    It 'seeds the box from the current user' {
        [bool]($script:UserSource -match '\$defaultUser = Get-TlcCurrentUserUpn') | Should -BeTrue
        [bool]($script:UserSource -match 'if \(\$defaultUser\) \{ \$element\.UserBox\.Text = \$defaultUser \}') | Should -BeTrue
    }

    It 'lets a remembered case overwrite the seeded default' {
        [bool]($script:UserSource -match "if \(-not \`$current -or \`$current -eq \`$defaultUser\) \{") |
            Should -BeTrue -Because 'the restore must still fire into a box holding only the default'
    }

    It 'never overwrites something the operator typed' {
        # The condition is "empty OR still the default" - so anything else, which by definition
        # came from the operator, is left alone.
        $block = [regex]::Match($script:UserSource, '(?s)\$match = @\(Get-TlcCaseHistory.*?\n        \}')
        $block.Success | Should -BeTrue
        $block.Value | Should -Match '\$current = \[string\]\$element\.UserBox\.Text'
    }

    It 'does not fail the window open when the UPN cannot be read' {
        # A convenience feature must never be the reason the tool does not start.
        [bool]($script:UserSource -match '(?s)try \{ \$defaultUser = Get-TlcCurrentUserUpn \} catch \{') | Should -BeTrue
    }
}

Describe 'Accounts inside a client archive' {
    <#
        The identity scan used to skip .zip, .cab and .7z entirely, on the stated grounds that
        "media and signaling content is encrypted and only Microsoft Support can read it".
        That holds for the encrypted support bundle. It does not hold for the web log archive
        the toolbox now triggers itself.

        Measured 2026-09-10 from a capture taken during a live meeting: calling-debug.txt
        inside that archive is 100% printable JSON carrying a Members block, ipv4, mac and the
        tenant's PSTN and emergency-services policy. The archive was flagged as a risk, which
        was right, but the account ids inside it were never inventoried - so
        BlockOnUnknownAccount could not judge them and the masking never saw them. Before this
        change the endpoint folder yielded 0 accounts; it now yields 2.

        The archive is still never extracted. Only the entry names are read.
    #>

    It 'inventories the accounts inside an archive instead of skipping past them' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $staging = Join-Path $TestDrive 'weblogs'
        foreach ($folder in @(
            'User (Primary; 11111111-1111-1111-1111-111111111111)',
            'User (22222222-2222-2222-2222-222222222222)',
            'Core')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $staging $folder) -Force
            Set-Content -LiteralPath (Join-Path $staging "$folder\calling-debug.txt") -Value 'x' -Encoding UTF8
        }
        $endpoint = Join-Path $TestDrive 'endpoint'
        $null = New-Item -ItemType Directory -Path $endpoint -Force
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, (Join-Path $endpoint 'PROD-WebLogs-test.zip'))

        $inventory = Get-TlcIdentityInventory -EndpointPath $endpoint

        @($inventory.ClientArchives).Count | Should -Be 1 -Because 'the archive is still recorded as a risk'
        @($inventory.Accounts).Count | Should -Be 2 -Because 'the ids inside it must be judged like any other'
        @($inventory.Accounts | ForEach-Object { $_.Id }) | Should -Contain '11111111-1111-1111-1111-111111111111'
        @($inventory.Accounts | ForEach-Object { $_.Id }) | Should -Contain '22222222-2222-2222-2222-222222222222'
    }

    It 'masks an archive account like any other, and says where it came from' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $staging = Join-Path $TestDrive 'weblogs2'
        $null = New-Item -ItemType Directory -Path (Join-Path $staging 'User (Primary; 33333333-3333-3333-3333-333333333333)') -Force
        Set-Content -LiteralPath (Join-Path $staging 'User (Primary; 33333333-3333-3333-3333-333333333333)\x.txt') -Value 'x' -Encoding UTF8
        $endpoint = Join-Path $TestDrive 'endpoint2'
        $null = New-Item -ItemType Directory -Path $endpoint -Force
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, (Join-Path $endpoint 'PROD-WebLogs-test2.zip'))

        $account = @((Get-TlcIdentityInventory -EndpointPath $endpoint).Accounts)[0]

        $account.MaskedId | Should -Not -BeNullOrEmpty
        $account.MaskedId | Should -Not -Be $account.Id -Because 'a raw id must not be the thing that gets displayed'
        [string]$account.Source | Should -Match 'archive:' -Because 'the reader has to know the id came from inside a bundle'
    }

    It 'does not extract the archive to read it' {
        # Extracting a customer archive into the evidence folder would double the identifiers
        # on disk and change what gets packaged.
        $source = Get-Content -LiteralPath (Join-Path $script:ToolboxRoot 'Modules\Tlc.Privacy.psm1') -Raw
        $source | Should -Not -BeNullOrEmpty -Because 'a read that failed leaves this empty, and an empty string satisfies every absence assertion below'
        $source | Should -Not -Match 'ExtractToDirectory'
    }
}

Describe 'Accounts named in the files themselves' {
    <#
        Review 2026-09-30, finding 331. The support-file lane copies Teams' Support Logs FOLDER,
        not an archive, and in a real one (602 entries, measured on the development machine)
        the account object ids are in the file names: CS_logs\CS_8#3Aorgid#3A<id>.conf and
        sc-tfw\skylib-users\user_orgid#3A<id>-0-<n>.blog. Only file contents were scanned, so
        those ids reached the zip's entry names and Manifest.json without BlockOnUnknownAccount
        judging them: the same ids that block when they arrive inside the web log archive.
    #>

    BeforeAll {
        $script:NamedRoot = Join-Path $TestDrive 'named'
        $support = Join-Path $script:NamedRoot 'SupportFiles\MSTeams Support Logs 2026-09-30_01-00-00'
        foreach ($relative in @(
            'CS_logs\CS_8#3Aorgid#3A44444444-4444-4444-4444-444444444444.conf',
            'sc-tfw\skylib-users\user_orgid#3A55555555-5555-5555-5555-555555555555-0-2601533197.blog',
            'Crashpad\reports\66666666-6666-6666-6666-666666666666.dmp',
            'exports\trace-alice@contoso-tlc-test.com.bin')) {
            $path = Join-Path $support $relative
            $null = [System.IO.Directory]::CreateDirectory('\\?\' + (Split-Path -Parent $path))
            [System.IO.File]::WriteAllBytes('\\?\' + $path, [byte[]](1, 2, 3))
        }
        $script:NamedPrivacy = {
            param([string[]] $Known)
            @{ KnownAccountIds = @($Known); KnownTenantIds = @(); HomeTenantId = ''
               BlockOnUnknownAccount = $true; RequireConsent = $false; ConsentGrantedBy = '' }
        }
    }
    AfterAll {
        if ([System.IO.Directory]::Exists('\\?\' + $script:NamedRoot)) {
            [System.IO.Directory]::Delete('\\?\' + $script:NamedRoot, $true)
        }
    }

    It 'inventories account ids found in file names, and only account ids' {
        $inventory = Get-TlcIdentityInventory -EndpointPath $script:NamedRoot -ThrottleLimit 1 6>$null
        $ids = @($inventory.Accounts | ForEach-Object { [string]$_.Id })
        $ids | Should -Contain '44444444-4444-4444-4444-444444444444'
        $ids | Should -Contain '55555555-5555-5555-5555-555555555555'
        $ids | Should -Not -Contain '66666666-6666-6666-6666-666666666666' -Because 'a crash report id is not an account'

        $sources = @($inventory.Accounts | ForEach-Object { [string]$_.Source })
        $sources | Should -Contain 'name:SupportFiles'
        ($sources -join ' ') | Should -Not -Match '4444|5555' -Because 'the source says where, never the id'
        $inventory.DistinctUpnCount | Should -BeGreaterThan 0 -Because 'an address in a file name is still an address in the bundle'
    }

    It 'blocks on them like any other undeclared account, and passes once they are declared' {
        $inventory = Get-TlcIdentityInventory -EndpointPath $script:NamedRoot -ThrottleLimit 1 6>$null

        & $script:NewRun 'gate-names-unknown'
        (Test-TlcPrivacyGate -Privacy (& $script:NamedPrivacy @()) -Inventory $inventory -Endpoint 'NAMES').Blocked | Should -BeTrue

        & $script:NewRun 'gate-names-known'
        $declared = & $script:NamedPrivacy @('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555')
        (Test-TlcPrivacyGate -Privacy $declared -Inventory $inventory -Endpoint 'NAMES').Blocked | Should -BeFalse
    }
}

Describe 'Get-TlcCurrentUserUpn' {
    <#
        Seeds the affected-user field, because in most collections the person at the keyboard
        IS the affected user - and a field that starts empty is one that gets left empty, which
        costs the bundle its subject.

        The risk runs the other way too: a wrong default puts the operator's identity on a
        bundle about somebody else, silently. So the function returns '' rather than a guess,
        and the value is shape-checked before it is trusted.
    #>

    It 'returns a UPN or nothing, never a fragment' {
        $upn = Get-TlcCurrentUserUpn
        if ($upn) {
            $upn | Should -Match '^[^@\s]+@[^@\s]+\.[^@\s]+$' -Because 'anything else would go straight into the bundle'
        } else {
            # A machine with no work account is a legitimate answer, and the empty string is
            # how it says so.
            $upn | Should -BeExactly ''
        }
    }

    It 'never returns whoami error text' {
        # whoami prints "Unable to get user claims information" on a machine with no work
        # account, and on some builds it goes to stdout - where an unchecked read would put it
        # in the affected-user field and then in the evidence.
        $upn = Get-TlcCurrentUserUpn
        $upn | Should -Not -Match 'ERROR|Unable|claims'
    }

    It 'goes through the native command wrapper rather than calling whoami directly' {
        # Windows PowerShell 5.1 turns a redirected native command's stderr into a terminating
        # error, and whoami writes to stderr in exactly the no-work-account case this has to
        # survive.
        $source = Get-Content -LiteralPath (Join-Path $script:ToolboxRoot 'Modules\Tlc.Privacy.psm1') -Raw
        $block = [regex]::Match($source, '(?s)function Get-TlcCurrentUserUpn \{.*?\n\}')
        $block.Success | Should -BeTrue
        $block.Value | Should -Match 'Invoke-TlcNativeCommand'
        $block.Value | Should -Not -Match '(?m)^\s*&\s*whoami'
    }
}

    <#
        Seeding the field interacts with the case-history restore, which brings back the user
        recorded against a remembered case. That restore used to fire only into an EMPTY box -
        so seeding would have silently switched it off, and a remembered case would come back
        labelled for whoever happened to be at the keyboard. That is the precise mislabelling
        the restore exists to prevent.
    #>

Describe 'The identity inventory that is written is masked' {
    <#
        Owner decision 2026-09-24, finding 296. The gate needs raw account ids to compare against
        KnownAccountIds, and it works from the in-memory inventory. What it wrote to
        IdentityInventory.json used to be that same object: every account id raw beside its mask,
        and every GUID found anywhere in the text evidence, raw. The written copy is masked unless
        raw was asked for.
    #>
    BeforeAll {
        $script:RawAccount = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $script:RawGuid = '11111111-2222-3333-4444-555555555555'
        $script:Inventory = [ordered]@{
            Accounts          = @([ordered]@{ Id = $script:RawAccount; MaskedId = (Protect-TlcIdentifier -Value $script:RawAccount); CloudType = 'prod'; State = 'active' })
            AccountCount      = 1
            DistinctGuidCount = 1
            Guids             = @($script:RawGuid)
        }
    }

    It 'writes no raw account id or GUID by default' {
        $shareable = ConvertTo-TlcShareableIdentityInventory -Inventory $script:Inventory
        $json = $shareable | ConvertTo-Json -Depth 6

        # Positive first, so an empty result cannot pass the absence checks below.
        @($shareable.Accounts).Count | Should -Be 1
        @($shareable.Guids).Count | Should -Be 1
        $shareable.AccountCount | Should -Be 1 -Because 'the counts the gate reasoned about are kept'

        $json | Should -Not -Match $script:RawAccount
        $json | Should -Not -Match $script:RawGuid
        @($shareable.Accounts)[0].Keys | Should -Not -Contain 'Id'
        @($shareable.Accounts)[0].MaskedId | Should -Match '^aaaaaaaa.*eeee$'
        $shareable.RawIdentifiersIncluded | Should -BeFalse
    }

    It 'leaves the in-memory inventory untouched for the gate' {
        $null = ConvertTo-TlcShareableIdentityInventory -Inventory $script:Inventory
        @($script:Inventory.Accounts)[0].Id | Should -BeExactly $script:RawAccount -Because 'the gate compares raw ids against KnownAccountIds'
        @($script:Inventory.Guids)[0] | Should -BeExactly $script:RawGuid
    }

    It 'keeps raw values only when asked' {
        $shareable = ConvertTo-TlcShareableIdentityInventory -Inventory $script:Inventory -IncludeRawIdentifiers
        @($shareable.Accounts)[0].Id | Should -BeExactly $script:RawAccount
        @($shareable.Guids)[0] | Should -BeExactly $script:RawGuid
        $shareable.RawIdentifiersIncluded | Should -BeTrue
    }

    It 'is what the Package stage writes, not the raw inventory' {
        $entry = Get-Content -LiteralPath (Join-Path $script:ToolboxRoot 'TLC-Toolbox.ps1') -Raw
        $entry | Should -Match "Export-TlcEvidence -Name 'IdentityInventory\.json' -InputObject \`$shareable"
        $entry | Should -Match 'ConvertTo-TlcShareableIdentityInventory -Inventory \$inventory -IncludeRawIdentifiers:\$IncludeRawIdentifiers'
    }
}
Describe 'The identity scan reads every file, in parallel, the same way' {
    <#
        Finding 304. Packaging a 650 MB endpoint carrying a Teams support bundle spent 658 s of
        716 in this scan on PowerShell 7. The scan now splits the files across a runspace pool,
        so these hold the parallel path to the serial one, and hold the pool worker's inline
        address search to Find-TlcUpn, which it restates.

        The UTF-16 case was found by the same profiling. tma_addin_msi.log in the support bundle
        is UTF-16, and it was decoded as UTF-8: every other character a NUL, nothing matchable,
        and still counted as scanned.
    #>

    BeforeAll {
        $script:ScanRoot = Join-Path $TestDrive 'parallel-scan'
        $null = New-Item -ItemType Directory -Path $script:ScanRoot -Force
        for ($i = 0; $i -lt 12; $i++) {
            $guid = '{0:x8}-1111-2222-3333-{1:x12}' -f (0x10000000 + $i), (0x100000000000 + $i)
            Set-Content -LiteralPath (Join-Path $script:ScanRoot "log$i.log") -Encoding utf8 `
                -Value "2026-09-25T03:48:56Z <INFO> user$i@contoso.com joined $guid"
        }
    }

    It 'finds the same identities with one worker and with several' {
        $serial = Get-TlcIdentityInventory -EndpointPath $script:ScanRoot -ThrottleLimit 1 6>$null
        $parallel = Get-TlcIdentityInventory -EndpointPath $script:ScanRoot -ThrottleLimit 4 6>$null

        $serial.FilesScanned | Should -Be 12
        $parallel.FilesScanned | Should -Be $serial.FilesScanned -Because 'every file has to reach a worker'
        $parallel.DistinctGuidCount | Should -Be 12
        (@($parallel.Guids | Sort-Object) -join ',') | Should -Be (@($serial.Guids | Sort-Object) -join ',')
        $parallel.DistinctUpnCount | Should -Be 12
    }

    It 'decodes a UTF-16 file by its byte-order mark' {
        $dir = Join-Path $TestDrive 'utf16'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $text = 'MSI (s) Property(S): USER = installer@fabrikam.com ProductCode = 9f8e7d6c-5b4a-3928-1706-f5e4d3c2b1a0'
        [System.IO.File]::WriteAllText((Join-Path $dir 'tma_addin_msi.log'), $text, [System.Text.Encoding]::Unicode)

        $inventory = Get-TlcIdentityInventory -EndpointPath $dir -ThrottleLimit 1 6>$null
        $inventory.Guids | Should -Contain '9f8e7d6c-5b4a-3928-1706-f5e4d3c2b1a0' -Because 'read as UTF-8 this is every other character a NUL'
        $inventory.DistinctUpnCount | Should -Be 1
    }

    It 'keeps the worker address search identical to Find-TlcUpn' {
        $dir = Join-Path $TestDrive 'upn-agree'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $text = 'mail a.b@contoso.com, o''brien@fabrikam.co.uk. then @ alone, x@y, trailing c-d@sub.example.org- done'
        Set-Content -LiteralPath (Join-Path $dir 'a.log') -Value $text -Encoding utf8

        $expected = @(Find-TlcUpn -Text $text | Sort-Object -Unique)
        $inventory = Get-TlcIdentityInventory -EndpointPath $dir -ThrottleLimit 1 6>$null
        $inventory.DistinctUpnCount | Should -Be $expected.Count
        $expected.Count | Should -BeGreaterThan 2 -Because 'the fixture has to exercise the search'
    }
}
Describe 'The gate never implies a scan it did not do' {
    <#
        Finding 306. A file the scan could not open was skipped without a word, and the gate
        passed: measured with a token-bearing file under an exclusive lock during the scan,
        released before the zip step would read it. Files over the scan limit were read in part,
        also without a word.
    #>

    BeforeAll {
        $null = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-gate-honest') -Scenario 'DesktopLaunchCrash'
        $script:GateRoot = Join-Path $TestDrive 'gate-honest'
        $null = New-Item -ItemType Directory -Path $script:GateRoot -Force
        $script:Privacy = @{ KnownAccountIds = @(); BlockOnUnknownAccount = $true; RequireConsent = $true; ConsentGrantedBy = 'Test' }
    }

    It 'blocks when a file could not be read' {
        $dir = Join-Path $script:GateRoot 'locked'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'open.log') -Value 'nothing here' -Encoding utf8
        $held = Join-Path $dir 'held.log'
        Set-Content -LiteralPath $held -Value 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl' -Encoding utf8

        $lock = [System.IO.File]::Open($held, 'Open', 'Read', 'None')
        try {
            $inventory = Get-TlcIdentityInventory -EndpointPath $dir -ThrottleLimit 1 6>$null
        } finally {
            $lock.Dispose()
        }
        @($inventory.UnreadableFiles) | Should -Contain 'held.log'

        $verdict = Test-TlcPrivacyGate -Privacy $script:Privacy -Inventory $inventory -Endpoint 'TESTPC'
        $verdict.Blocked | Should -BeTrue -Because 'an unread file can hold anything, and here it held a token'
        ($verdict.Reasons -join ' ') | Should -Match 'could not be read.*held\.log'
    }

    It 'says when a file was only read in part' {
        $dir = Join-Path $script:GateRoot 'large'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'big.log') -Value ('x' * 4096) -Encoding ascii

        $inventory = Get-TlcIdentityInventory -EndpointPath $dir -MaxScanBytesPerFile 1024 -ThrottleLimit 1 6>$null
        @($inventory.PartiallyScanned) | Should -Contain 'big.log'
        $verdict = Test-TlcPrivacyGate -Privacy $script:Privacy -Inventory $inventory -Endpoint 'TESTPC'
        ($verdict.Reasons -join ' ') | Should -Match 'only read in part: big\.log'
        $verdict.Blocked | Should -BeFalse -Because 'the limit is a stated design choice, not a failure to read'
    }

    It 'still judges an older inventory that has neither field' {
        $older = [ordered]@{ Accounts = @(); AccountCount = 0; MultipleAccounts = $false; DistinctUpnCount = 0; Guids = @(); ClientArchives = @() }
        (Test-TlcPrivacyGate -Privacy $script:Privacy -Inventory $older -Endpoint 'TESTPC').Blocked | Should -BeFalse
    }
}
Describe 'The identity scan reads every file whole, in chunks' {
    <#
        Finding 308. The scan read the first 8 MB of each file and ignored the rest, and HAR
        exports are routinely larger. It now streams each file in 4-million-character chunks
        with an overlap. This file puts an address across the first chunk boundary and a token
        past 8 MB, the two places the old reader and a careless chunked one would each miss.
    #>

    BeforeAll {
        $null = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-chunked') -Scenario 'WebClient'
        $script:ChunkDir = Join-Path $TestDrive 'chunked'
        $null = New-Item -ItemType Directory -Path $script:ChunkDir -Force
        $path = Join-Path $script:ChunkDir 'large.har'
        $writer = [System.IO.StreamWriter]::new($path, $false, [System.Text.UTF8Encoding]::new($false))
        try {
            $line = ('x' * 1023) + "`n"
            $written = 0
            while ($written + $line.Length -le 4194304 - 12) { $writer.Write($line); $written += $line.Length }
            # '@' is the last character of the first chunk: neither chunk alone holds a valid address,
            # so only the overlap can find it.
            $writer.Write(' ' * (4194293 - $written)); $written = 4194293
            $writer.Write('straddle.u@fabrikam.com '); $written += 24
            while ($written -lt 9MB) { $writer.Write($line); $written += $line.Length }
            $writer.Write('Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl')
        } finally { $writer.Dispose() }
    }

    It 'finds an address across a chunk boundary and a token past 8 MB by default' {
        $inventory = Get-TlcIdentityInventory -EndpointPath $script:ChunkDir -ThrottleLimit 1 6>$null
        $inventory.DistinctUpnCount | Should -Be 1 -Because 'the address straddles the first chunk boundary'
        @($inventory.CredentialFiles) | Should -Contain 'large.har' -Because 'the token sits past the old 8 MB limit'
        @($inventory.PartiallyScanned).Count | Should -Be 0
    }

    It 'still honours an explicit cap, and says so' {
        $inventory = Get-TlcIdentityInventory -EndpointPath $script:ChunkDir -MaxScanBytesPerFile 8388608 -ThrottleLimit 1 6>$null
        @($inventory.CredentialFiles).Count | Should -Be 0
        $inventory.DistinctUpnCount | Should -Be 1 -Because 'the address is inside the first 8 MB, so a cap must read that far'
        @($inventory.PartiallyScanned) | Should -Contain 'large.har'
    }
}
Describe 'Sign-in credentials in a sanitized HAR' {
    <#
        Finding 312, from a real "Export HAR (sanitized)" of Teams on the web driven through Edge
        DevTools: no Cookie or Authorization header, and still the token endpoint's response held
        access_token, id_token and refresh_token, its request held refresh_token=..., and two
        SharePoint responses held access tokens. The shape below is that one: JSON inside a HAR
        string, so the quotes are escaped.
    #>

    BeforeAll {
        $null = Initialize-TlcRun -RunRoot (Join-Path $TestDrive 'runs-har-creds') -Scenario 'Files'
        $script:Jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl'
        $script:Refresh = '1.ARoAv4j5cvGGr0GRqy180BHbR' + ('x' * 40)
        $script:NewHar = {
            param([string] $Dir, [switch] $RefreshOnly)
            $null = New-Item -ItemType Directory -Path $Dir -Force
            $body = if ($RefreshOnly) { "{\`"refresh_token\`":\`"$($script:Refresh)\`",\`"token_type\`":\`"Bearer\`"}" }
                    else { "{\`"token_type\`":\`"Bearer\`",\`"access_token\`":\`"$($script:Jwt)\`",\`"refresh_token\`":\`"$($script:Refresh)\`"}" }
            $har = '{"log":{"version":"1.2","creator":{"name":"WebInspector","version":"537.36"},"entries":[' +
                   '{"request":{"method":"POST","url":"https://login.microsoftonline.com/x/oauth2/v2.0/token","headers":[],"postData":{"mimeType":"application/x-www-form-urlencoded","text":"grant_type=refresh_token&refresh_token=' + $script:Refresh + '&client_id=abc"}},' +
                   '"response":{"status":200,"headers":[],"content":{"mimeType":"application/json","text":"' + $body + '"}},"time":378}]}}'
            $path = Join-Path $Dir 'teams.har'
            [System.IO.File]::WriteAllText($path, $har, [System.Text.UTF8Encoding]::new($false))
            return $path
        }
    }

    It 'detects a refresh token even when no JWT is present' {
        $dir = Join-Path $TestDrive 'refresh-only'
        $null = & $script:NewHar $dir -RefreshOnly
        # The request body carries the refresh token too, so strip the one JWT-free file down to it.
        $inventory = Get-TlcIdentityInventory -EndpointPath $dir -ThrottleLimit 1 6>$null
        @($inventory.CredentialFiles) | Should -Contain 'teams.har' -Because 'a refresh token is the longest-lived credential in a HAR and is not JWT-shaped'
    }

    It 'removes every credential, keeps the HAR valid, and keeps the request that carried them' {
        $dir = Join-Path $TestDrive 'redact'
        $path = & $script:NewHar $dir
        $removed = @(Protect-TlcHarCredential -EndpointPath $dir)
        $removed.Count | Should -Be 1
        $removed[0].JwtCount | Should -Be 1
        $removed[0].RefreshCount | Should -Be 2 -Because 'one in the response body, one in the form-encoded request'

        $text = [System.IO.File]::ReadAllText($path)
        $text | Should -Not -Match 'eyJhbGci'
        $text | Should -Not -Match '1\.ARoAv4j5'
        $parsed = $text | ConvertFrom-Json
        @($parsed.log.entries).Count | Should -Be 1
        $parsed.log.entries[0].response.status | Should -Be 200
        (($parsed.log.entries[0].response.content.text) | ConvertFrom-Json).access_token | Should -Be 'REDACTED-BY-TLC-TOOLBOX' -Because 'the inner JSON must still parse too'
    }

    It 'does not mistake its own marker for a credential' {
        $dir = Join-Path $TestDrive 'marker'
        $null = & $script:NewHar $dir
        $null = Protect-TlcHarCredential -EndpointPath $dir
        @((Get-TlcIdentityInventory -EndpointPath $dir -ThrottleLimit 1 6>$null).CredentialFiles).Count | Should -Be 0
        @(Protect-TlcHarCredential -EndpointPath $dir).Count | Should -Be 0 -Because 'a second pass finds nothing left to remove'
    }
}
Describe 'Long-path HAR evidence is still inspected and redacted' {
    It 'scans and removes fixture credentials and addresses when the containing directory exceeds 260 characters' {
        $root = Join-Path $TestDrive 'long-har'
        $nested = Join-Path $root (('x' * 125) + '\' + ('y' * 125))
        $path = Join-Path $nested 'fixture.har'
        $native = '\\?\' + $path
        try {
            $null = [IO.Directory]::CreateDirectory('\\?\' + $nested)
            $response = @{ refresh_token = 'fixture-only-not-a-live-token-' + ('x' * 40); owner = 'other@example.test' } |
                ConvertTo-Json -Compress
            $har = @{ log = @{ version = '1.2'; entries = @(@{
                request = @{ url = 'https://example.test/diagnostic' }
                response = @{ status = 200; content = @{ text = $response } }
                time = 123
            }) } } | ConvertTo-Json -Depth 8
            [IO.File]::WriteAllText($native, $har)
            $nested.Length | Should -BeGreaterThan 260
            $before = Get-TlcIdentityInventory -EndpointPath $root -ThrottleLimit 1 6>$null
            $before.FilesScanned | Should -Be 1
            $before.UnreadableFiles | Should -BeNullOrEmpty
            $before.CredentialFiles | Should -Contain 'fixture.har'
            $removed = @(Protect-TlcHarCredential -EndpointPath $root)
            $removed.Count | Should -Be 1
            $removed[0].RefreshCount | Should -Be 1
            $masked = @(Protect-TlcHarAddress -EndpointPath $root)
            $masked.Count | Should -Be 1
            $masked[0].MaskedCount | Should -Be 1
            $after = Get-TlcIdentityInventory -EndpointPath $root -ThrottleLimit 1 6>$null
            $after.FilesScanned | Should -Be 1
            $after.CredentialFiles | Should -BeNullOrEmpty
            $after.UnreadableFiles | Should -BeNullOrEmpty
            $parsed = [IO.File]::ReadAllText($native) | ConvertFrom-Json
            $parsed.log.entries[0].response.status | Should -Be 200
            $content = $parsed.log.entries[0].response.content.text | ConvertFrom-Json
            $content.refresh_token | Should -BeExactly 'REDACTED-BY-TLC-TOOLBOX'
            $content.owner | Should -BeExactly 'ot***@example.test'
        } finally {
            if ([IO.Directory]::Exists('\\?\' + $root)) { [IO.Directory]::Delete('\\?\' + $root, $true) }
        }
    }
}

Describe 'Third-party addresses in a HAR are masked' {
    <#
        Finding 313: one OneDrive listing in a real HAR carried 7,397 addresses - everyone the files
        were shared with. Privacy.ScrubUpn now masks them in HAR files, keeping the affected user
        and the operator.
    #>

    It 'masks every address the gate would find, the same way the rest of the bundle does, and keeps the named ones' {
        $dir = Join-Path $TestDrive 'har-addr'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $body = 'shared with a.b@contoso.com, o''brien@fabrikam.co.uk. Owner jane.doe@contoso.com; x@y; c-d@sub.example.org- end'
        $har = '{"log":{"entries":[{"request":{"url":"https://contoso-my.sharepoint.com/"},"response":{"content":{"text":"' + $body + '"}}}]}}'
        $path = Join-Path $dir 'teams.har'
        [System.IO.File]::WriteAllText($path, $har, [System.Text.UTF8Encoding]::new($false))
        $expectedFound = @(Find-TlcUpn -Text $body | Sort-Object -Unique)

        $result = @(Protect-TlcHarAddress -EndpointPath $dir -Keep 'JANE.DOE@contoso.com')
        $result[0].KeptCount | Should -Be 1 -Because 'the keep list is case-insensitive, like an address'
        $result[0].MaskedCount | Should -Be ($expectedFound.Count - 1) -Because 'every address Find-TlcUpn finds, except the kept one'

        $after = [System.IO.File]::ReadAllText($path)
        $null = $after | ConvertFrom-Json
        $after | Should -Match 'jane\.doe@contoso\.com'
        foreach ($address in $expectedFound | Where-Object { $_ -ne 'jane.doe@contoso.com' }) {
            $after | Should -Not -Match ([regex]::Escape($address))
            $after | Should -Match ([regex]::Escape((Protect-TlcIdentifier -Value $address)))
        }
        @(Find-TlcUpn -Text $after) | Should -Be @('jane.doe@contoso.com') -Because 'the gate must see only the kept address afterwards'
    }
}