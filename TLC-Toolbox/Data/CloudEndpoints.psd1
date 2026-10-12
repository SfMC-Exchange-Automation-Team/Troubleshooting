@{
    # Per-cloud Teams endpoints.
    #
    # The toolbox tested the worldwide names on every machine, which is right for almost every
    # customer and wrong for the ones who most need a correct answer: on a GCC High or DoD
    # tenant those hosts are not the ones the client uses, so a reachability check against them
    # reports a problem that is not there, or health that is not real.
    #
    # EVERY host below is published by Microsoft, and the ones that are not published are
    # ABSENT rather than guessed. The first version of this file was written from memory and
    # three of its government host names were outside Microsoft's published namespaces
    # entirely - they would not have resolved, so the network lane would have reported a DNS
    # failure on exactly the tenants that can least afford a wrong answer.
    #
    # Sources, verified 2026-09-13:
    #   Worldwide (and GCC): learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges
    #   GCC High:            learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-u-s-government-gcc-high-endpoints
    #   DoD:                 learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-u-s-government-dod-endpoints
    #   21Vianet:            learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges-21vianet
    #   Relay test target:   learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-vpn-securing-teams
    Default = 'Worldwide'

    # There is no GCC instance. Microsoft's endpoint page is titled "Worldwide (+GCC)" and the
    # IP/URL web service accepts only Worldwide, China, USGovDoD and USGovGCCHigh - so GCC
    # signs in at login.microsoftonline.com and uses commercial endpoints. Verified; it is the
    # single easiest thing to get wrong here.
    #
    # MediaRelay is a HOST NAME and only the worldwide cloud has one published. Microsoft
    # publishes government and China relay reachability as IP subnets plus UDP 3478-3481, not
    # as names, so those entries are empty and the relay check is skipped with a reason rather
    # than aimed at an invented host. RelayPorts carries what Microsoft does publish.
    Clouds = @(
        @{
            Instance   = 'Worldwide'
            Aliases    = @('Public', 'Commercial', 'AzureCloud', 'GCC')
            Teams      = 'teams.microsoft.com'
            # Not named individually by Microsoft; covered by the published wildcard
            # *.teams.microsoft.com in the Allow row.
            Config     = 'config.teams.microsoft.com'
            Login      = 'login.microsoftonline.com'
            # Documented verbatim as a split-tunnel trace target. Microsoft also uses
            # world.tr.teams.microsoft.com on another page; both spellings are published.
            MediaRelay = 'worldaz.tr.teams.microsoft.com'
            RelayPorts = @(3478, 3479, 3480, 3481)
        }
        @{
            Instance   = 'USGovGCCHigh'
            Aliases    = @('GCCHigh', 'AzureUSGovernment', 'USGovVirginia')
            Teams      = 'gov.teams.microsoft.us'
            # The published namespace is *.gov.teams.microsoft.us - label order matters.
            # config.teams.microsoft.us, which this file used to carry, is outside it and
            # would not resolve. This is the real host Microsoft names in the Whiteboard
            # GCC High guidance.
            Config     = 'config.ecs.gov.teams.microsoft.us'
            Login      = 'login.microsoftonline.us'
            MediaRelay = ''
            RelayPorts = @(3478, 3479, 3480, 3481)
        }
        @{
            Instance   = 'USGovDoD'
            Aliases    = @('DoD', 'DOD')
            Teams      = 'dod.teams.microsoft.us'
            # Not named by Microsoft. config.dod.teams.microsoft.us, which this file used to
            # carry, does not resolve at all. This name follows the shape Microsoft publishes
            # for GCC High (config.ecs.gov.teams.microsoft.us) and resolves to 195.134.241.50,
            # inside Microsoft's own published DoD subnet 195.134.240.0/22 - measured
            # 2026-09-13, with a commercial host checked against the same subnets as a control
            # to prove the test discriminates. That is evidence, not documentation, and it is
            # recorded as such.
            Config     = 'config.ecs.dod.teams.microsoft.us'
            Login      = 'login.microsoftonline.us'
            MediaRelay = ''
            RelayPorts = @(3478, 3479, 3480, 3481)
        }
        @{
            Instance   = 'China'
            Aliases    = @('Gallatin', 'AzureChinaCloud', '21Vianet')
            Teams      = 'teams.microsoftonline.cn'
            # Not named individually, but inside the published *.teams.microsoftonline.cn.
            Config     = 'config.teams.microsoftonline.cn'
            Login      = 'login.partner.microsoftonline.cn'
            MediaRelay = ''
            RelayPorts = @(3478, 3479, 3480, 3481)
        }
    )
}
