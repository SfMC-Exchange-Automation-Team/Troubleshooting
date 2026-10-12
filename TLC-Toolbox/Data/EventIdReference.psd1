@{
    # Event IDs Microsoft documents, for channels the toolbox already collects. Nothing new is
    # gathered here: this turns a raw channel into an answer.
    #
    # EVERY entry below was verified against Microsoft documentation and carries the URL that
    # documents it. The first version of this file was written from memory and four of its
    # seven AAD entries were wrong - including 1084, which was the only id that matched on a
    # real collection, so eleven real events were annotated with a meaning that was not theirs.
    # A wrong annotation is worse than none: it reads with the same authority as a measured
    # fact. If a meaning cannot be cited, it does not belong here.
    #
    # Channel matters as much as the number. Microsoft states that for the CloudAP plug-in,
    # ERROR events go to the Operational log and INFORMATION events go to the Analytic log, so
    # several widely-quoted ids are Analytic and will never appear in an Operational capture.
    # They are listed under their real channel rather than silently mis-filed.
    Channels = @(
        @{
            Channel = 'Microsoft-Windows-AAD/Operational'
            Topic   = 'Entra authentication errors: PRT, WAM and token brokering'
            Source  = 'https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-primary-refresh-token'
            Events  = @(
                @{ Id = 1081; Meaning = 'Server error code and description returned by the Entra authentication service - the OAuth error and its AADSTS reason. The first place to read an authentication failure.' }
                @{ Id = 1084; Meaning = 'Network-stack suberror and the URL being reached, for connectivity failures such as timeout, name not resolved or cannot connect. A transport problem, not a verdict on the token itself.' }
                @{ Id = 1088; Meaning = 'Server error code and description returned by the WS-Trust endpoint. Federated sign-in only.' }
                # 1097 and 1098 are not on the page above. They were listed with a meaning taken
                # from ONE article - Enterprise State Roaming with MFA, where 1098 carried
                # 0xCAA2000C interaction_required - and generalised to "most often". A simulated
                # sign-in failure with the endpoints unreachable then carried 0xCAA70004 "The
                # server or proxy was not found", and the bundle annotated it as an MFA prompt.
                # Now: what Microsoft documents, and the pages that document it. Finding 307.
                @{ Id = 1097; Source = 'https://learn.microsoft.com/en-us/troubleshoot/entra/entra-id/mfa/esr-settings-not-sync-mfa-enabled'
                   Meaning = 'Token broker could not renew a token silently. The cause is the error code and description in the event itself.' }
                @{ Id = 1098; Source = 'https://learn.microsoft.com/en-us/troubleshoot/windows-client/user-profiles-and-logon/event-1098-error-0xcaa5001c'
                   Meaning = 'Token broker operation failed. The cause is the error code and description in the event itself; Microsoft documents it as interaction required (0xCAA2000C, MFA needed) in one case and as a token broker failure (0xCAA5001C) in another.' }
            )
        }
        @{
            # Collected only if this channel is enabled. Listed because these ids are quoted
            # constantly as though they were Operational, and filing them correctly is the
            # difference between "not present" and "silently never matched".
            Channel = 'Microsoft-Windows-AAD/Analytic'
            Topic   = 'Entra authentication flow, informational'
            Source  = 'https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-primary-refresh-token'
            Events  = @(
                @{ Id = 1006; Meaning = 'Start of the primary refresh token acquisition flow. Everything up to the matching 1007 belongs to that attempt.' }
                @{ Id = 1007; Meaning = 'End of the primary refresh token acquisition flow, carrying the final error code for the attempt.' }
                @{ Id = 1022; Meaning = 'The URL being accessed. The instance before an error event names the endpoint involved.' }
                @{ Id = 1144; Meaning = 'The user principal name supplied for sign-in. Used to spot a malformed UPN or an unknown domain.' }
            )
        }
        @{
            Channel = 'Microsoft-Windows-User Device Registration/Admin'
            Topic   = 'Device registration and join'
            Source  = 'https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-hybrid-join-windows-current'
            Events  = @(
                @{ Id = 201; Meaning = 'Discovery phase of registration, carrying the suberror behind a discovery failure - service connection point lookup, reaching enterpriseregistration.windows.net, or realm discovery.' }
                @{ Id = 204; Meaning = 'Join phase, carrying the error code, HTTP status and message returned by the device registration service.' }
                @{ Id = 220; Meaning = 'Windows could not read the computer object in Active Directory. An embedded logon-session or user error usually means on-premises replication.' }
                @{ Id = 304; Meaning = 'Automatic registration failed at the join phase, with the exit code and server error. Expected and ignorable on a machine that is not meant to be hybrid joined.' }
                @{ Id = 305; Meaning = 'Authentication phase of registration, carrying the error, suberror and the server error message.' }
                @{ Id = 307; Meaning = 'Automatic registration could not read the registration service information from Active Directory - the service connection point. Expected and ignorable when hybrid join is not intended.' }
            )
        }
        @{
            # Microsoft documents exactly one id for this channel. The ids circulated in blogs
            # and forums for install, staging and registration are NOT documented and are
            # deliberately absent. What Microsoft does document is the HRESULT inside the 404
            # message, which is where the actual cause is stated - see HResults below.
            Channel = 'Microsoft-Windows-AppXDeploymentServer/Operational'
            Topic   = 'MSIX/AppX deployment, which is how new Teams installs and updates'
            Source  = 'https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/modern-inbox-store-apps-troubleshooting-guidance'
            Events  = @(
                @{ Id = 404; Meaning = 'An AppX/MSIX deployment operation failed for a named package. The message carries the failing HRESULT and a specific error text that states the real cause.' }
            )
        }
    )

    # Error codes that appear inside the event text rather than as ids. Annotated because the
    # HRESULT is where an AppX failure actually says what went wrong, and because two of these
    # are the exact conditions Get-TlcLaunchEnvironmentFact checks the registry for.
    #
    # Source: https://learn.microsoft.com/en-us/windows/win32/appxpkg/troubleshooting
    HResults = @(
        @{ Code = '0x80073CF3'; Name = 'ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED'; Meaning = 'The package failed update, dependency or conflict validation.' }
        @{ Code = '0x80073CF5'; Name = 'ERROR_INSTALL_NETWORK_FAILURE'; Meaning = 'The package could not be downloaded.' }
        @{ Code = '0x80073CF6'; Name = 'ERROR_INSTALL_REGISTRATION_FAILURE'; Meaning = 'The package could not be registered.' }
        @{ Code = '0x80073CF9'; Name = 'ERROR_INSTALL_FAILED'; Meaning = 'Package install failed.' }
        @{ Code = '0x80073CFF'; Name = 'ERROR_INSTALL_POLICY_FAILURE'; Meaning = 'Sideloading is not enabled on this machine. This is the AllowAllTrustedApps case in the launch-environment check.' }
        @{ Code = '0x80073D01'; Name = 'ERROR_DEPLOYMENT_BLOCKED_BY_POLICY'; Meaning = 'Deployment was blocked by policy, such as application control.' }
        @{ Code = '0x80073D23'; Name = 'ERROR_DEPLOYMENT_BLOCKED_BY_PROFILE_POLICY'; Meaning = 'Deployment was blocked because special-profile deployment is not allowed.' }
    )
}
