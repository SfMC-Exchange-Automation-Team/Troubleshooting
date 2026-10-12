@{
    # Conditions Microsoft documents as stopping new Teams from installing or launching.
    #
    # Every entry is what Microsoft's own TeamsLaunchCheck.ps1 checks, or what the install
    # article names. The first version of this file was written from memory and got three
    # things wrong: it read the legacy Shell Folders key instead of the one Microsoft
    # designates, it added Local AppData to a list Microsoft limits to two folders, and it
    # invented a drive-mapping check that appears nowhere in the guidance.
    #
    # Sources, verified 2026-09-13:
    #   Launch:  learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/resolve-new-teams-launch-issues
    #   Install: learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/fix-new-teams-installation-issues
    #   Policy:  learn.microsoft.com/en-us/windows/msix/group-policy-msix

    # User Shell Folders, not Shell Folders. Microsoft's ValidateShellFolders reads the former;
    # the latter is the legacy pre-expanded cache. They agree on a healthy machine, which is
    # exactly why reading the wrong one is easy to get away with until the day they differ.
    ShellFolderKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

    # Exactly the two folders Microsoft checks. Local AppData was in this list and is not in
    # Microsoft's - a reparse point there is common and deliberate on managed machines, so
    # flagging it would have produced a finding on every redirected-profile estate.
    ShellFolders = @(
        @{ Value = 'Cookies'; Label = 'Cookies' }
        @{ Value = 'Cache';   Label = 'InternetCache' }
    )

    # Read from the environment, which is what Microsoft's check does and what the process
    # actually resolves. Reparse points only: Microsoft's article says nothing about mapped
    # drives or subst, and that claim has been removed rather than left as a plausible guess.
    TempVariables = @('TEMP', 'TMP')

    # Sideloading and package-install policy. Absent values are the normal, healthy case -
    # these only exist once something has set them - so absence is reported as "not set"
    # rather than as a finding.
    #
    # Microsoft checks both locations and treats ANY non-zero value as healthy, not
    # specifically 1.
    RegistryValues = @(
        @{
            Path    = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            Name    = 'AllowAllTrustedApps'
            Healthy = 'NonZero'
            # Microsoft only treats this as a problem below the build that fixed it, so the
            # check is gated on OS build. See BuildGate below.
            Gate    = 'AllowAllTrustedApps'
            Meaning = 'Sideloading trusted app packages. Disabled, the MSTeams MSIX package fails to install.'
        }
        @{
            Path    = 'HKLM:\Software\Policies\Microsoft\Windows\Appx'
            Name    = 'AllowAllTrustedApps'
            Healthy = 'NonZero'
            Gate    = 'AllowAllTrustedApps'
            Meaning = 'Group-policy form of the same control. A policy value of 0 overrides a healthy local one.'
        }
        @{
            Path    = 'HKLM:\Software\Policies\Microsoft\Windows\Appx'
            Name    = 'BlockNonAdminUserInstall'
            Healthy = 'Zero'
            Meaning = 'Blocks per-user package installs. Enabled, a standard user cannot install new Teams.'
        }
        @{
            Path    = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            Name    = 'AllowDevelopmentWithoutDevLicense'
            # Microsoft publishes no standalone healthy value - it only matters in combination
            # with AllowAllTrustedApps - so this is recorded and never judged.
            Healthy = $null
            Meaning = 'Developer mode without a licence. Only meaningful alongside AllowAllTrustedApps; reported for context, not judged.'
        }
    )

    # AllowAllTrustedApps stopped mattering once Windows shipped the fix, and Microsoft's own
    # script says so out loud above these builds. Without this gate the check reports a fault
    # on a patched machine that Microsoft's script passes - a false positive on the majority
    # of current estates.
    #
    # Fixed by KB5031445 (Windows 10 19045.3636) and KB5031455 (Windows 11 22621.2506).
    BuildGate = @{
        AllowAllTrustedApps = @{
            # Build -> the update revision at which the fix landed.
            Builds = @{
                '19044' = 4046
                '19045' = 3636
                '22000' = 2777
                '22621' = 2506
            }
            # Anything newer than the highest listed build has the fix by definition.
            AboveBuild = 22621
            Note = 'OS build is high enough that AllowAllTrustedApps is not the cause.'
        }
    }
}
