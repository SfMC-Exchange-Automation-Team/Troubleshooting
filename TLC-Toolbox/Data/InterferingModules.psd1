@{
    # Applications and DLLs Microsoft documents as known to block Teams or make it stop
    # responding, plus a second list of DLLs known to affect the Teams desktop client and
    # Edge WebView2.
    #
    # Source, verbatim:
    #   learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/
    #   include-exclude-teams-from-antivirus-dlp
    # Captured 2026-09-10.
    #
    # WHY THIS IS A TABLE AND NOT A JUDGEMENT. Microsoft's own guidance for the same page is
    # "verify the presence of the DLLs, and also verify the ownership and integrity of the
    # DLLs" - presence is a fact, fault is not. Several of these are ordinary security products
    # doing exactly what the customer bought them to do, and a collector that reports
    # "CrowdStrike is injecting into Teams" as a defect will be wrong most of the time and
    # insulting the rest. What the bundle should say is that a documented interaction exists,
    # name it, and let an engineer decide.
    #
    # The Application column is the value: turning "ms-teams.exe has cymemdef64.dll loaded"
    # into "Cylance Desktop Security is hooked into Teams" is the difference between a line an
    # engineer can act on and a line they have to go and search for.
    #
    # Entries where Microsoft names an application but no DLL (Aternity, BeyondTrust,
    # ControlUp, McAfee, Trellix, Zscaler, Forcepoint, TenxGuard64) are deliberately absent:
    # there is nothing to match on, and inventing a filename to fill the row would be exactly
    # the kind of plausible fabrication this project keeps finding.

    # Processes whose loaded modules are worth inspecting. Microsoft names these four as the
    # ones to exclude from antivirus, which makes them the ones third-party software hooks.
    Processes = @(
        'ms-teams'
        'msedgewebview2'
        'ms-teamsupdate'
        'msteams_autostarter'
    )

    # Application -> the DLLs Microsoft associates with it. Wildcards are Microsoft's own.
    KnownApplications = @(
        @{ Application = '360 Safe Security';                          Modules = @('safewrapper.dll') }
        @{ Application = 'ASUS Sonic Suite 3';                         Modules = @('ss3devprops.dll') }
        @{ Application = 'Avast Antivirus';                            Modules = @('aswhook.dll') }
        @{ Application = 'Avecto (now BeyondTrust)';                   Modules = @('PGHook.dll') }
        @{ Application = 'Citrix Workspace app - App Protection';      Modules = @('ctxapclient64.dll', 'epclient64.dll') }
        @{ Application = 'Citrix ICA Service in the VDA';              Modules = @('ctxdodhook64.dll') }
        @{ Application = 'CrowdStrike Falcon Sensor';                  Modules = @('Umppc*.dll') }
        @{ Application = 'Cylance Desktop Security';                   Modules = @('cymemdef64.dll') }
        @{ Application = 'DataClasys User Client';                     Modules = @('CLSCBase.dll', 'CLSUInject.dll') }
        @{ Application = 'Encourage Technologies ESS Rec Agent';       Modules = @('etraldr.dll') }
        @{ Application = 'Esafenet Cobra DocGuard';                    Modules = @('dynamicdll64.dll') }
        @{ Application = 'Fasoo DRM';                                  Modules = @('f_nxa.dll') }
        @{ Application = 'Frontier Technology DRM Agent';              Modules = @('ftagtctr.dll', 'detoured.dll') }
        @{ Application = 'Keyman Engine';                              Modules = @('keyman64.dll') }
        @{ Application = 'Konica Minolta copier explorer plugin';      Modules = @('PSDPUIHandler.dll') }
        @{ Application = 'ManageEngine UEMS Agent';                    Modules = @('DragDrophook.dll') }
        @{ Application = 'Manufacturer Endpoint Agent';                Modules = @('clpbm64.dll', 'prntm64.dll') }
        @{ Application = 'Max Software Keylogger';                     Modules = @('skgsec64.dll') }
        @{ Application = 'Nahimic';                                    Modules = @('NahimicOSD.dll', 'Nahimic2OSD.dll', 'AudioDevProps2.dll', 'NahimicVRDevProps.dll') }
        @{ Application = 'NetRatings NetSight';                        Modules = @('n64hooks.dll') }
        @{ Application = 'Netrix Agent';                               Modules = @('nxgrdh64.dll', 'nxipc64.dll') }
        @{ Application = 'Nuance NaturallySpeaking';                   Modules = @('nlutmgrhook_x64.dll') }
        @{ Application = 'NVIDIA ShadowPlay';                          Modules = @('nvspcap64.dll') }
        @{ Application = 'Ocular Agent';                               Modules = @('winhafnt64.dll') }
        @{ Application = 'PC Matic SuperShield';                       Modules = @('SuperShieldHookCpy64.dll') }
        @{ Application = 'QiAnXin Tianqing DLP';                       Modules = @('qmdlphook64.dll') }
        @{ Application = 'QiAnXin Tianqing HookBase';                  Modules = @('ghijt64*.dll') }
        @{ Application = 'QiAnXin Tianqing Watermark';                 Modules = @('watermarkhook64.dll') }
        @{ Application = 'Quality ISMC Client';                        Modules = @('ismcfilehook64.dll') }
        @{ Application = 'SkyGuard Endpoint Security';                 Modules = @('sgephook.dll') }
        @{ Application = 'Symantec Endpoint Protection';               Modules = @('sysfer.dll') }
        @{ Application = 'Thycotic Application Control';               Modules = @('ArelliaACActioni64.dll') }
        @{ Application = 'TightVNC';                                   Modules = @('screenhooks64.dll') }
        @{ Application = 'Ztsment Data Protection';                    Modules = @('injumon64.dll') }
        @{ Application = 'Action1';                                    Modules = @('k1agentdeploycse_*.dll') }
        @{ Application = 'Lenovo ThinkVantage Active Protection';      Modules = @('Sensor64.dll') }
    )

    # "Other DLLs that might affect Teams desktop client and Edge WebView2" - Microsoft names
    # no owning application for these, so a match reports the filename and nothing more.
    OtherModules = @(
        'bsijt64.dll'
        'core64.dll'
        'cptlwa64.dll'
        'cryptacl.dll'
        'csprnthk.dll'
        'cssguard64.dll'
        'ctiuser.dll'
        'dgapia64.dll'
        'dsefilesystemext64.dll'
        'dsloaderinj.x64.dll'
        'emcnt64.dll'
        'encappctrl64.dll'
        'estoutgo64.dll'
        'f_lph.dll'
        'guard64.dll'
        'hkapi.x64.dll'
        'hookcreateprocessinternal64.dll'
        'imfph64.dll'
        'ldgetprintcontent64.dll'
        'ldprintmonitor64.dll'
        'ldsmartenc64.dll'
        'ldwatermarkhook64.dll'
        'ldxghijt64.dll'
        'lpghijt64.dll'
        'monfileop64.dll'
        'mozartbreathprotect.dll'
        'oeareader64.dll'
        'printhk64.dll'
        'sbieoutside.dll'
        'sdckern.dll'
        'sdwhf2130.dll'
        'tmailhook64.dll'
        'tsafedoc64.dll'
        'uhk64.dll'
        'vozokopot.dll'
        'winahframe64.dll'
        'wincept64.dll'
        'winncap364.dll'
        'xpspntdll64_6016.dll'
    )
}
