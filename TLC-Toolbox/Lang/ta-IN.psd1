@{
    # Tamil (India). Machine translated, NOT reviewed by a native speaker - see the header
    # of Tlc.Localization.psm1. Safe for what it covers: field labels, buttons and hints.
    # Nothing that reaches a bundle is translated. Added 2026-10-01 on request, as the second
    # Indian language after Hindi.
    #
    # The same conventions as hi-IN.psd1, so the two Indian tables read the same way:
    #
    # - Product names stay in Latin script. "Teams", "Teams Rooms", "PowerShell", "FQDN",
    #   "File Explorer" and "TLC Toolbox" are what the controls and documentation say. A Tamil
    #   case ending attaches with a hyphen, as in "File Explorer-இல்".
    # - The two nouns the window turns on are transliterated, not translated: லாக் for log and
    #   ட்ரேஸ் for trace, so they stay recognisable against the English documentation an
    #   engineer reads alongside the window. The gate requires each to be rendered one way
    #   throughout. பதிவு is kept for the recording a live trace makes and never used for a log,
    #   so the two do not read as one thing.
    # - Buttons take the short imperative Windows uses in Tamil (சேகரி, திற, மூடு). Tooltips say
    #   what a control does. Instructions to the operator take the polite -கவும் form.
    #
    # THIS FILE MUST BE SAVED AS UTF-8 WITH A BOM, for the reason hi-IN.psd1 gives: without one,
    # Windows PowerShell 5.1 reads it through the ANSI codepage and the Tamil is destroyed.
    # Tlc.Localization.Tests.ps1 asserts the BOM.
    #
    # The time row reads [date] அன்று [time], on the date at the time, and the units are the
    # short forms நிமி and மணி. The unit box leaves 52px for its text and the full words measure
    # 79px, so they were cut off; மணி then cannot also be the date-to-time word.

    AdminCenterLink          = 'நிர்வாக மையத்திலிருந்து லாக்குகளைச் சேகரிப்பது எப்படி'
    ComparisonLink           = 'அம்சங்களின் ஒப்பீடு'
    ComparisonLinkTip        = 'இந்தக் கருவிப்பெட்டி சேகரிப்பவற்றில் தொலைநிலைச் சேகரிப்பு சேகரிக்காதவை, அதன் நேர்மாறும்'
    SettingsTip              = 'அமைப்புகள்'

    WhatHappenedHeading      = 'என்ன நடந்தது'
    ScenarioLabel            = 'சூழ்நிலை'
    ScenarioHint             = 'ஒரு சூழ்நிலையைத் தேர்ந்தெடுக்கவும். உங்கள் தேர்வைப் பொறுத்து சேகரிக்கப்படும் லாக்குகளும் கண்டறியும் தரவுகளும் மாறும்.'
    CaseNumberLabel          = 'கேஸ் எண்'
    AffectedUserLabel        = 'பாதிக்கப்பட்ட பயனர்'
    ConsentLabel             = 'ஒப்புதல் அளித்தவர்'
    ConsentHint              = 'தொகுப்பை உருவாக்கும் முன் இது தேவை.'
    ForgetButton             = 'மறந்துவிடு'
    ForgetTip                = 'பெட்டியில் உள்ள கேஸ் எண்ணை இந்தக் கணினியிலிருந்து நீக்கும். பெட்டி காலியாக இருந்தால், நினைவில் உள்ள எல்லா கேஸ்களையும் மறக்க வாய்ப்பளிக்கும்.'

    PathChooserHeading       = 'என்ன செய்ய வேண்டும்'
    PathChooserCaption       = 'ஒரு பணியைத் தேர்ந்தெடுக்கவும்.'
    GatherPathButton         = 'இருக்கும் லாக்குகளைத் தொகுப்பாக்கு'
    GatherPathTip            = 'ஏற்கெனவே நடந்த ஒரு சிக்கலுக்கு, Teams ஏற்கெனவே எழுதிய லாக்குகளை எடுக்கும். சில வினாடிகள் முதல் சில நிமிடங்கள் வரை ஆகும். தேர்வை நீக்க மீண்டும் கிளிக் செய்யவும்.'
    LivePathButton           = 'நேரடி ட்ரேஸை இயக்கு'
    LivePathTip              = 'நீங்கள் சிக்கலை மீண்டும் நிகழ்த்தும்போது இந்தக் கணினியை இடைவெளிகளில் அளவிடும். சிக்கலை நினைத்தபோது நிகழ்த்த முடிந்தால் இதைப் பயன்படுத்தவும். தேர்வை நீக்க மீண்டும் கிளிக் செய்யவும்.'
    PathUnavailable          = 'நேரடி ட்ரேஸ் இந்தக் கணினியை மட்டுமே அளவிடும்; இந்தச் சூழ்நிலையோ வேறு இடத்தில் உள்ள ஒரு சாதனம் பற்றியது.'

    GatherHeading            = 'எப்போது நடந்தது'
    ImpactTimeLabel          = 'பாதிப்பு நேரம்'
    ImpactAtLabel            = 'அன்று'
    WindowLabel              = 'கால அளவு'
    BeforeLabel              = 'முன்'
    AfterLabel               = 'பின்'
    UnitMinutes              = 'நிமி'
    UnitHours                = 'மணி'
    TimeHint                 = 'ஏற்கெனவே எழுதப்பட்ட லாக்குகளில் எவற்றை எடுப்பது என்பதைத் தேர்ந்தெடுக்கும். 24 மணிநேரக் கடிகாரம்; AM/PM ஏற்கப்படும்.'
    TimeHintUnreadable       = 'நேரம் புரியவில்லை - நள்ளிரவு பயன்படுத்தப்படுகிறது. 14:30 அல்லது 2:30 PM என முயற்சிக்கவும்.'

    LiveHeading              = 'நேரடி ட்ரேஸ்'
    LiveCaption              = 'அமர்வே கால அளவு: ட்ரேஸைத் தொடங்கு என்பதை அழுத்தும்போது பதிவு தொடங்கி, இயக்கத்தை நிறுத்து என்பதை அழுத்தும்போது முடியும். இடையில் சிக்கலை மீண்டும் நிகழ்த்தவும்.'
    SampleEveryLabel         = 'அளவிடும் இடைவெளி'
    DeepCaptureBox           = 'பாக்கெட் கேப்சரையும் இயக்கு'
    ElevateButton            = 'TLC Toolbox-ஐ நிர்வாகியாக மீண்டும் திற'

    OptionsHeading           = 'விருப்பங்கள்'
    RoomsDeviceLabel         = 'Teams Rooms சாதனம்'
    RoomsDeviceHintOn        = 'சாதனத்தின் ஹோஸ்ட் பெயர் அல்லது FQDN.'
    RoomsDeviceHintLocal     = 'இந்தக் கணினி ஒரு Teams Rooms சாதனம். இதிலிருந்தே சேகரிக்க, காலியாக விடவும்.'
    RoomsDeviceHintOff       = 'Teams Rooms சூழ்நிலைக்கு மட்டும்.'
    EndpointsLabel           = 'இவற்றிலிருந்தும் சேகரி'
    OutputFolderLabel        = 'வெளியீட்டுக் கோப்புறை'
    SkipPromptedBox          = 'பயனர் தேவைப்படும் படிகளைத் தவிர் (ஆதரவுக் கோப்புகளுக்குக் காத்திருக்காது)'
    ValidationOnlyBox        = 'சரிபார்ப்பு மட்டும் (இயக்கத்தைத் திட்டமிடும், எதையும் சேகரிக்காது)'

    LiveMemoryContext = 'மொத்த RAM: {0} GB | கிடைப்பது: {1} GB | {2}% பயன்பாடு'
    LiveMemoryUnavailable = 'மொத்த / கிடைக்கும் RAM: அளவிடப்படவில்லை'
ScenarioGroupCommon = 'பொதுவான சூழல்கள் - நேரடி ட்ரேஸ் கிடைக்கும்'
ScenarioGroupLive = 'மேலும் சூழல்கள் - நேரடி ட்ரேஸ் கிடைக்கும்'
ScenarioGroupRemote = 'பிற சாதனங்கள் அல்லது போர்டல்கள் - உள்ளூர் ட்ரேஸ் இல்லை'
StopFlowHeading = 'சேகரிப்பு முடிக்கப்படுகிறது'
StopFlowFinished = 'சேகரிப்பு முடிந்தது'
StopFlowReview = 'சேகரிப்பு முடிவு - முடிக்காத அல்லது தோல்வியுற்ற படிகளைச் சரிபார்க்கவும்'
StopStepSampling = '1. மாதிரியை நிறுத்து'
StopStepLogs = '2. லாக்களைச் சேகரி'
StopStepSupport = '3. ஆதரவுக் கோப்புகள்'
StopStepFinalize = '4. இயக்கத்தை முடி'
StopStatusPending = 'நிலுவை'
StopStatusRunning = 'செயலில்'
StopStatusComplete = 'முடிந்தது'
StopStatusSkipped = 'தவிர்க்கப்பட்டது'
StopStatusWarning = 'சரிபார்க்கவும்'
StopStatusFailed = 'தோல்வி'
StopDetailAcknowledging = 'மாதிரி நிறுத்த உறுதிக்குக் காத்திருக்கிறது.'
StopDetailSamplingStopped = 'மாதிரி நிறுத்தப்பட்டது; சேமித்த மாதிரிகள் பாதுகாப்பாக உள்ளன.'
StopDetailDeep = 'விருப்பப் பாக்கெட் சேகரிப்பு நிறுத்தப்படுகிறது.'
StopDetailSummary = 'சேமித்த மாதிரிகள் படித்து சுருக்கம் உருவாக்கப்படுகிறது.'
StopDetailInventory = 'Teams மற்றும் சாதன விவரங்கள் படிக்கப்படுகின்றன.'
StopDetailClientLogs = 'லாக்கள் நகலாகி அமர்வு காலவரிசை உருவாகிறது.'
StopDetailClientState = 'Teams கிளையன்ட் நிலை நகலாகிறது.'
StopDetailEvents = 'அமர்வின் Windows நிகழ்வு லாக்கள் படிக்கப்படுகின்றன.'
StopDetailVdi = 'மெய்நிகர் டெஸ்க்டாப் விவரங்கள் சேகரிக்கப்படுகின்றன.'
StopDetailNetwork = 'இறுதி நெட்வொர்க் மற்றும் ரிலே சோதனை நடக்கிறது.'
StopDetailBrowser = 'உலாவி ஆதாரங்கள் சேகரிக்கப்படுகின்றன.'
StopDetailLogsFinished = 'இறுதி லாக் சேகரிப்பு முடிந்தது.'
StopDetailSupport = 'Teams ஆதரவுக் கோப்புகள் சேகரிக்கப்படுகின்றன.'
StopDetailSupportSkipped = 'ஆதரவுக் கோப்பு சேகரிப்பு தவிர்க்கப்பட்டது.'
StopDetailSupportTimeout = 'காலக்கெடுவுக்குள் புதிய கோப்புகள் கிடைக்கவில்லை.'
StopDetailSupportCopied = 'ஆதரவுக் கோப்புகள் இயக்கத்தில் நகலாயின.'
StopDetailSupportPartial = 'பகுதி சேகரிப்பு அல்லது இடையூறு; அசல் கோப்புகளைச் சரிபார்க்கவும்.'
StopDetailFinalizing = 'ஆதாரங்கள் ஆய்வு செய்து இயக்கக் கோப்புகள் எழுதப்படுகின்றன.'
StopDetailFinished = 'இயக்கக் கோப்புகள் எழுதப்பட்டன.'
StopLastUpdate = 'சேகரிப்பியின் புதுப்பிப்பு {0}s முன்பு'
StopAwaitingUpdate = 'சேகரிப்பியின் உறுதிக்குக் காத்திருக்கிறது'
StopSupportFacts = '{0} தொகுப்புகள் கிடைத்தன | {1} கோப்புகள் காணப்பட்டன | {2} MB'
StopSupportArrival = 'புதிய கோப்புகள் வர {0}s மீதம்'
StopSupportQuiet = '{0}/{1}s மாற்றமில்லை; புதிய எழுதுதல் சோதனையை மீண்டும் தொடங்கும்'
StopSupportMarkers = '{0} கோப்புறைகளில் இறுதிக் கோப்புகளுக்குக் காத்திருக்கிறது'
StopSupportCopied = '{0}/{1} தொகுப்புகள் நகலாயின | {2} நகல் தோல்விகள்'
StopSupportLastWrite = 'கடைசிக் கோப்பு எழுதுதல் {0}s முன்பு'
StopLiveProgress = 'முடிவு {0} | {1} மாதிரிகள் சேமித்தன (மாதிரி நிறுத்தப்பட்டது)'
LiveMetricLoading = 'அளவீடுகள் ஏற்றப்படுகின்றன...'
LiveMemoryLoading = 'மொத்த / கிடைக்கும் RAM படிக்கப்படுகிறது...'
LiveMemoryPreview = 'முதல் சேமித்த மாதிரிக்கு முன் முன்னோட்டம்'
LiveMemoryReadFailed = 'RAM அளவீடு கிடைக்கவில்லை: {0}'
WaitArming = 'ட்ரேஸ் தயாராகிறது ({0}s). சேகரிப்பிகள் ஏற்றப்படுகின்றன; பதிவு தொடங்கவில்லை.'
WaitFirstSample = 'முதல் சேமித்த மாதிரிக்குக் காத்திருக்கிறது ({0}s). மாதிரி இன்னும் உறுதியாகவில்லை.'
WaitNextSample = 'அடுத்த மாதிரிக்குக் காத்திருக்கிறது (கடைசியிலிருந்து {0}s). புதிய தரவு உறுதியாகவில்லை.'
WaitStopping = 'ட்ரேஸ் நிறுத்தப்படுகிறது ({0}s). தற்போதைய சோதனை முடிவுக்குக் காத்திருக்கிறது.'
WaitCollecting = 'லாக்கள் சேகரித்து ஆதாரங்கள் முடிக்கப்படுகின்றன ({0}s). இயக்கம் இன்னும் முடியவில்லை.'
WaitWorking = 'கண்டறிதல் ஏற்றம் அல்லது இயக்கம் ({0}s). தற்போதைய படி உரைப் பதிவில் உள்ளது.'
WaitPackaging = 'தனியுரிமை சரிபார்த்து ஆதாரங்களைப் பொட்டலமாக்குகிறது ({0}s). முடிவுக்குக் காத்திருக்கிறது.'
WaitSupportGenerating = 'Teams ஆதரவுக் கோப்புகள் உருவாகின்றன ({0}s). Teams முன்புறம் வரலாம்.'
WaitSupportWaiting = 'Teams ஆதரவுக் கோப்புகளுக்குக் காத்திருக்கிறது ({0}s). கோப்புகள் இன்னும் உறுதியாகவில்லை.'
WaitSupportSettling = 'கோப்புகள் கிடைத்தன; எழுதுதல் முடிவுக்குக் காத்திருக்கிறது ({0}s).'
WaitSupportCopying = 'Teams ஆதரவுக் கோப்புகள் இயக்கத்தில் நகலாகின்றன ({0}s).'
WaitSupportAction = 'Teams கோப்புகளுக்குச் செயல் தேவை ({0}s). கீழுள்ள கட்டுப்பாடுகளைப் பயன்படுத்தவும்.'
WaitTip = 'அசைவும் நேரமும் சாளரம் பதிலளிப்பதைக் காட்டும்; முடிந்த சதவீதம் அல்ல. சேமித்த மாதிரிகளும் கோப்பு நிலைகளும் உண்மையான முன்னேற்றத்தை உறுதிப்படுத்தும்.'
    LiveRttContext = 'ரிலே தாமதக் குறிப்பு, அழைப்புத் தரம் அல்ல'
    LiveRttPassLegend = 'பச்சை: <200 ms'
    LiveRttWarningLegend = 'மஞ்சள்: 200-500 ms'
    LiveRttBlockedLegend = 'சிவப்பு: >500 ms'
    LiveMemoryPassLegend = 'பச்சை: >=10% அல்லது >=4 GB'
    LiveMemoryWarningLegend = 'மஞ்சள்: குறைந்த இருப்பு'
    LiveMemoryBlockedLegend = 'சிவப்பு: <1% அல்லது <500 MB'
    LiveMemoryNeutralLegend = 'ஊதா: அளவிடப்படவில்லை'
    LiveThresholdSources = 'Microsoft ஆதாரங்கள்:'
    LiveRttThresholdTip = 'குறிப்பு வரம்புகள்: 200 ms கீழ் பச்சை (Teams அழைப்பு நிலையின் வழக்கமான மதிப்பு), 200-500 ms மஞ்சள், 500 ms மேல் சிவப்பு (CQD ஆடியோ RTT விதி). செயற்கை STUN சோதனைகளுக்கு மட்டும்; உண்மை ஊடகத் தரம் அல்லது CQD வகைப்பாடு அல்ல. ஒவ்வொரு இடைவெளியும் புதிய சேமித்த அளவீட்டைப் பயன்படுத்தும்; நிறக் குறி கடைசி வரம்பைக் காட்டும். RTT இல்லாதபோது சாம்பல்.'
    LiveMemoryThresholdTip = 'நிறம் கிடைக்கும் கணினியின் இயற்பியல் RAM குறிக்கும்; Teams MB வரம்பு அல்ல. சிவப்பு: கிடைப்பது 1% கீழ் அல்லது 500 MB கீழ். இல்லையெனில் மஞ்சள்: 10% கீழ் மற்றும் 4 GB கீழ். இல்லையெனில் பச்சை. தீவிர நிலைக்கு முன்னுரிமை; சரியாக 10% இயல்பானது. Windows வழிகாட்டுதல், Teams செயல்திறன் தீர்மானம் அல்ல. மொத்த RAM பயன்படும் இயற்பியல் அளவு; கமிட்/பக்கக் கோப்பு அல்ல. இடைவெளி புதிய சேமித்த மதிப்பைப் பயன்படுத்தும்; ஊதா என்பது RAM அளவிடப்படவில்லை.'
    CancelButton             = 'இயக்கத்தை நிறுத்து'
    CancelTip                = 'இப்போதே சேகரிப்பதை நிறுத்து. இதுவரை சேகரித்த அனைத்தும் வைக்கப்படும்; தொகுப்பு மட்டும் முழுமையடையாது.'
    PackageButton            = 'தொகுப்பாக்கு'
    PackageTip               = 'தனியுரிமைச் சரிபார்ப்பை இயக்கி, சேகரித்த சான்றுகளை ஒப்படைப்பதற்கான ஒரே தொகுப்பாக zip செய்யும். ஒப்புதல் பதிவாகும் வரை மறுக்கப்படும்.'
    OpenButton               = 'இயக்கக் கோப்புறையைத் திற'
    OpenTip                  = 'இந்த இயக்கத்தின் கோப்புறையை File Explorer-இல் திறக்கும்; சேகரித்த கோப்புகளும் கருவியின் சொந்த லாக்கும் அங்கே உள்ளன.'
    ValidateButton           = 'சரிபார்'
    ValidateTip              = 'இயக்கத்தைத் திட்டமிட்டு, அதைத் தடுக்கக்கூடிய எதையும் தெரிவிக்கும். எதையும் மாற்றாது, எதையும் சேகரிக்காது.'
    CollectButton            = 'சேகரி'
    CollectTip               = 'மேலே தேர்ந்தெடுத்த பணியை இயக்கும்.'
    StartTraceButton         = 'ட்ரேஸைத் தொடங்கு'

    SettingsHeading          = 'அமைப்புகள்'
    SettingsLanguageLabel    = 'மொழி'
    SettingsLanguageHint     = 'சாளரத்தை மட்டுமே மாற்றும். சேகரித்த சான்றுகள், தொகுப்பு, கருவியின் லாக் ஆகியவை ஆங்கிலத்திலேயே இருக்கும், அதனால் கேஸைப் படிப்பவர் யாராயினும் அவற்றைப் படிக்க முடியும்.'
    SettingsTranslationNote  = 'ஆங்கிலம் தவிர மற்ற எல்லா மொழிகளும் இயந்திர மொழிபெயர்ப்பு; தாய்மொழியாகப் பேசுபவர் யாரும் இவற்றைச் சரிபார்க்கவில்லை.'
    SettingsThemeLabel       = 'தோற்றம்'
    SettingsThemeHint        = 'அடுத்த முறை சாளரம் திறக்கும்போது பொருந்தும். சாளரம் ஏற்றப்படும்போதே வண்ணங்கள் நிலைபெறுவதால், இப்போது மாற்றினால் அதன் ஒரு பகுதி மட்டுமே மீண்டும் வண்ணம் பெறும்.'
    ThemeSystem              = 'கணினி அமைப்பைப் பின்பற்று'
    ThemeLight               = 'வெளிர்'
    ThemeDark                = 'அடர்'
    SettingsClose            = 'மூடு'

    # The Start menu row. The entry is called TLC Toolbox in every language; Start menu and
    # taskbar are what Windows itself calls them. {0} in the Elsewhere hint is a folder path,
    # and in ShortcutFailed it is the system's own message, which ends the sentence.
    SettingsShortcutLabel    = 'குறுக்குவழி'
    ShortcutAddButton        = 'தொடக்க மெனுவில் சேர்'
    ShortcutRemoveButton     = 'தொடக்க மெனுவிலிருந்து அகற்று'
    ShortcutHintNone         = 'TLC Toolbox-ஐ அதன் சொந்த ஐகானுடன் தொடக்க மெனுவில் சேர்க்கும். அங்கிருந்து அதை டாஸ்க்பாரில் பின் செய்யலாம்.'
    ShortcutHintHere         = 'தொடக்க மெனு பதிவு TLC Toolbox-இன் இந்த நகலைத் திறக்கும்.'
    ShortcutHintElsewhere    = 'தொடக்க மெனு பதிவு {0} இல் உள்ள மற்றொரு நகலைத் திறக்கும். அதை மீண்டும் சேர்த்தால் இது இந்த நகலைச் சுட்டும்.'
    ShortcutFailed           = 'தொடக்க மெனு பதிவை மாற்ற முடியவில்லை: {0}'

    # --- Dashboard ----------------------------------------------------------------
    # The captions, and the values the tiles draw. A value is translated as it is drawn, by
    # Get-TlcTileText recognising which of these phrases a metric wrote; the metric itself stays
    # English. {0} and {1} are the numbers exactly as the metric formatted them.
    TileClient               = 'கிளையன்ட்'
    TileLogs                 = 'டிஸ்க் லாக்'
    TileRetention            = 'லாக் காலம்'
    TileActivity             = 'கடைசி லாக்'
    TileCrash                = 'கிராஷ் (24 மணி)'
    TileCoverage             = 'காலம்'
    TileNetwork              = 'நெட்வொர்க் பாதை'
    TileUpdate               = 'கிளையன்ட் புதுப்பிப்பு'
    TileSignIn               = 'உள்நுழைந்தது'
    TileChecking             = 'சரிபார்க்கிறது...'
    MetricMeasuring          = 'அளவிடுகிறது...'
    MetricMeasuredAt         = 'அளந்தது {0:HH:mm:ss}'
    TileNotFound             = 'கிடைக்கவில்லை'
    TileOrphaned             = 'தனியாக'
    TileNoLogFolder          = 'லாக் கோப்புறை இல்லை'
    TileNone                 = 'இல்லை'
    TileNoLogs               = 'லாக் இல்லை'
    TileNever                = 'ஒருபோதும் இல்லை'
    TileJustNow              = 'இப்போது'
    TileInFuture             = 'எதிர்காலத்தில்'
    TileEndsInFuture         = 'எதிர்காலத்தில் முடியும்'
    TileCovered              = 'மூடப்பட்டது'
    TileOlderThanLogs        = 'லாக்கைவிட பழையது'
    TileInLogGap             = 'லாக் இடைவெளியில்'
    TilePartlyCovered        = 'பகுதி மூடல்'
    TileUnavailable          = 'கிடைக்காது'
    TileInspected            = 'சோதிக்கப்பட்டது'
    TileDirect               = 'நேரடி'
    TileUnknown              = 'தெரியாது'
    TileToday                = 'இன்று'
    TileYesterday            = 'நேற்று'
    TileNoneFound            = 'எதுவும் இல்லை'
    TileOnePerson            = '1 நபர்'
    TileOneIdToDeclare       = '1 ID அறிவிக்க'
    TilePickAJob             = 'பணி தேர்வு'
    TileLiveTrace            = 'நேரடி ட்ரேஸ்'
    TileTunnelled            = 'டனல் வழியாக'
    TileFilesSize            = '{0} கோப்புகள், {1} MB'
    TileMinutesAgo           = '{0} நிமி முன்'
    TileHoursAgo             = '{0} மணி முன்'
    TileDaysAgo              = '{0} நாள் முன்'
    TileMinutes              = '{0} நிமி'
    TileHours                = '{0} மணி'
    TileDays                 = '{0} நாள்'
    TileCountInHours         = '{1} மணியில் {0}'
    TilePeople               = '{0} நபர்கள்'
    TileIdsToDeclare         = '{0} ID அறிவிக்க'
    TileWithTenants          = '{0}, {1} டெனன்ட்'

    # --- Banners ------------------------------------------------------------------
    # Which console to use, and the advisories about this machine. {0} in the first two is a
    # scenario name or a platform name, which stay as written.
    ToolChoiceCollectHere    = 'இங்கே சேகரி'
    ToolChoiceAdminCenter    = 'நிர்வாக மையம் இதில் பெரும்பகுதியைச் செய்ய முடியும்'
    ToolChoiceNotARoute      = 'நிர்வாக மையத்தின் தொலைநிலை கிளையன்ட் லாக் சேகரிப்பு {0}-க்கான வழி அல்ல. அதன் தொகுப்பு கிளையன்டின் சொந்த லாக்குகள்; இந்தச் சூழ்நிலைக்கு அது சேகரிக்காத சான்றுகள் தேவை.'
    ToolChoiceVirtualDesktop = 'நிர்வாக மையத்தின் தொலைநிலை கிளையன்ட் லாக் சேகரிப்பு Windows (non-VDI)-க்கு மட்டும் ஆதரிக்கப்படுகிறது என ஆவணப்படுத்தப்பட்டுள்ளது; இது {0}. கோரிக்கை இந்த கிளையன்டை அடையாது.'
    ToolChoiceClientBlocked  = 'சரிபார்த்து சேகரிக்க நிர்வாக மையத்திற்கு Teams கிளையன்ட் இயங்கிக் கொண்டிருக்க வேண்டும். இந்தக் கணினி அதை வழங்க முடியாது, எனவே கோரிக்கை காலாவதியாகும் வரை நிறைவேறாமல் இருக்கும்.'
    ToolChoiceSignInBlocked  = 'நிர்வாக மையத்தின் சாதனப் பட்டியல் உள்நுழைந்த கிளையன்ட் டெலிமெட்ரியிலிருந்து உருவாகிறது, அதனால் உள்நுழைய முடியாத கிளையன்ட் அதில் தோன்றவே வாய்ப்பில்லை.'
    ToolChoiceRetention      = 'நிர்வாக மையத்திற்கு 8 மணி வரை ஆகலாம், மேலும் அதில் நேர-சாளர அளவுரு இல்லை; ஆகவே அது இயங்கும்போது டிஸ்கில் இருப்பதை எல்லாம் சேகரிக்கும். இந்த கிளையன்ட் அதன் லாக்குகளை அதைவிட வேகமாக சுழற்றுகிறது, எனவே காத்திருக்கும் நேரத்தில் சான்றுகள் நீங்கிவிடலாம்.'
    ToolChoiceAdminCenterDetail = 'இங்கே உள்ளூர் சூழல் எதுவும் தேவையில்லை, மேலும் {0}-க்கு தொலைநிலை கிளையன்ட் லாக் வழி உள்ளது. அங்கே சேகரிப்பது அமைதியாக நடக்கும், கணினியருகில் யாரும் தேவையில்லை; ஆனால் 8 மணி வரை ஆகலாம் மற்றும் கிளையன்ட் லாக்குகள் மட்டுமே திரும்பும் - நிகழ்வு லாக், நெட்வொர்க் பாதை, கொள்கை ஆகியவற்றுக்கு இன்னும் இங்கே சேகரிப்பு தேவை.'
    ToolChoiceFleetNote      = 'இந்தக் கணினி தானாகவே தொலைநிலை சேகரிப்பையும் இயக்க முடியும் - கீழே உள்ள இவற்றிலிருந்தும் சேகரி என்பதைப் பார்க்கவும் - இது மணிநேரங்களுக்கு பதிலாக நிமிடங்களில் முடிந்து முழு சான்றுத் தொகுப்பைத் தரும்; ஆனால் இலக்குக்கு WinRM மற்றும் சான்றுகள் தேவை, நிர்வாக மையத்திற்கு அவை தேவையில்லை.'
    DismissRecommendationTip = 'இந்த பரிந்துரையை நிராகரி'
    DismissAdvisoryTip       = 'இந்த ஆலோசனையை நிராகரி'
    AdvisoryVdiHeading       = 'மெய்நிகர் டெஸ்க்டாப்'
    AdvisoryVdiSomewhere     = 'ஒரு மெய்நிகர் டெஸ்க்டாப்'
    AdvisoryVdiMediaLogs     = 'Teams {0}-இல் இயங்குகிறது, எனவே மீடியா லாக்குகள் இந்த அமர்வில் அல்லாமல் உடல் எண்ட்பாயிண்டில் எழுதப்படுகின்றன - இங்கே சேகரிப்பதால் அமர்வின் skylib லாக்குகள் கிடைக்கும், மீடியா அடுக்கு எதுவும் கிடைக்காது.'
    AdvisoryVdiLogCap        = 'VDI கிளையன்ட்களில் லாக் அளவு இயல்பாக வரம்பிடப்பட்டுள்ளது; சிக்கலை மீண்டும் நிகழ்த்தும் முன் Teams தனியுரிமை அமைப்புகளில் Extended Logging-ஐ இயக்கவும்.'
    AdvisoryVdiProfile       = 'புரொஃபைல் non-persistent ஆக இருந்தால், லாக் கோப்புறை FSLogix சைன்-அவுட் செய்யும்போது நீக்கும் கோப்புறை, எனவே பயனர் சைன் ஆஃப் செய்வதற்கு முன் சேகரிக்கவும்.'
    AdvisoryVdiCommunity     = 'இந்த தளம் Microsoft ஆவணப்படுத்தாத விற்பனையாளர் சிக்னலில் இருந்து அடையாளம் காணப்பட்டது, எனவே அதைப் பயன்படுத்தி நம்புவதற்கு முன் உறுதிப்படுத்தவும்.'
    AdvisoryAudioHeading     = 'ஆடியோ எண்ட்பாயிண்ட்கள்'
    AdvisoryAudioNone        = 'பதிவு சாதனம் எதுவும் தெரிவிக்கப்படவில்லை.'
    AdvisoryAudioUnhealthy   = '{0} சாதனங்களைச் சரிபார்க்க வேண்டும்.'
    AdvisoryAudioOpen        = 'விவரங்களைப் பார்க்கவும்'
    PathSelected             = 'தேர்ந்தெடுக்கப்பட்டது'
    SkipSupportButton        = 'ஆதரவு கோப்புகளைத் தவிர்'
    GenerateSupportButton    = 'ஆதரவு கோப்புகளை உருவாக்கு'
    SupportAutoGenerating    = 'Teams ஆதரவு கோப்புகள் தானாக உருவாக்கப்படுகின்றன. Teams முன்னிலைக்கு வரலாம். தானியக்கம் தோல்வியடைந்தால் மட்டுமே குறுக்குவழி தேவை. உள்நுழைந்த எல்லாக் கணக்குகளும் கோப்புகளில் இருக்கலாம்; இந்தப் படியைத் தவிர்க்கலாம்.'
    SupportAutoWaiting       = 'குறுக்குவழி அனுப்பப்பட்டது. Teams கோப்புகளுக்காகக் காத்திருக்கிறது; செயல் தேவையில்லை. படியைத் தவிர்க்கலாம்.'
    SupportAutoSettling      = 'கோப்புகள் கண்டறியப்பட்டன. சேகரிக்கும் முன் Teams எல்லாக் கோப்புகளையும் எழுதி முடிக்கக் காத்திருக்கிறது.'
    SupportAutoCopying       = 'முழுமையான Teams ஆதரவு கோப்புகள் இந்தச் சேகரிப்பில் நகலெடுக்கப்படுகின்றன.'
    LiveRttTip               = 'STUN RTT என்பது Teams இடைமாற்றிக்கு செயற்கை UDP கோரிக்கை சென்று பதில் திரும்புவதற்கான சராசரி நேரம், மில்லிநொடிகளில். குறைந்த மதிப்பு வேகமான பதிலைக் குறிக்கும். இது இடைமாற்றியின் இணைப்பைச் சோதிக்கிறது; அழைப்பின் உண்மையான ஆடியோ/வீடியோ தரத்தையோ சரியான நெட்வொர்க் பாதையையோ அல்ல.'
    LiveMemoryTip            = 'Teams / WebView2 என்பது Teams மற்றும் அதன் WebView2 செயல்முறைகளின் செயலில் உள்ள நினைவகத்தின் மொத்தம், MB அளவில். WebView2, Teams இடைமுகத்தைக் காட்டுகிறது. இது நினைவகப் பயன்பாட்டின் போக்கைக் காட்டும்; நெட்வொர்க் தரம் அல்ல. பகிரப்பட்ட நினைவகம் பலமுறை கணக்கிடப்படலாம்.'
    ShowLiveGraphBox         = 'நேரடி வரைபடங்களைக் காட்டு'
    LiveChartAnimationHint   = 'கோடுகள் ஒரு மாதிரி இடைவெளியில் மாறும் (அதிகபட்சம் 10 நொடிகள்); எண்கள் சமீபத்திய சேமித்த அளவீடுகள். காட்சியை மென்மையாக்குவது ஆதாரத்தை மாற்றாது.'
    LiveChartCaption         = 'நேரடி சேகரிப்பு: சமீபத்திய 120 மாதிரிகள். STUN சோதனைகள் அழைப்பின் ஊடகத் தரம் அல்ல. தனித்தனி அளவுகோல்கள்; இடைவெளி என்பது அளவீடு இல்லை.'
    SupportActionText        = 'செயல் தேவை: கீழே கோப்புகளை உருவாக்கவும் (Teams முன்னிலைக்கு வரும்) அல்லது Teams இல் கன்ட்ரோல், ஆல்ட், ஷிஃப்ட் மற்றும் 1 அழுத்தவும். பதிவிறக்க அறிவிப்பு மறையும் வரை காத்திருக்கவும். கோப்புகளில் உள்நுழைந்த எல்லாக் கணக்குகளின் தகவலும் இருக்கலாம். சேகரிக்க விரும்பாவிட்டால் தவிர்க்கவும்.'
    LiveProgressText         = 'நேரம் {0} | {1} மாதிரிகள் சேமிக்கப்பட்டன | கடைசி மாதிரி {2} நொடிகளுக்கு முன்'
    AdvisoryAudioType        = 'Windows சாதன வகை'
    AdvisoryAudioDisplayNote = 'திரை ஆடியோ (HDMI / DisplayPort) என்பது திரை இணைப்பின் வெளியீடு. திரையில் ஒலிபெருக்கிகள் உள்ளன, அவை இணைக்கப்பட்டுள்ளன அல்லது Teams அந்த வெளியீட்டைப் பயன்படுத்தியது என்பதை இது உறுதிப்படுத்தாது. வகை Windows மெட்டாடேட்டாவிலிருந்து வருகிறது; பெயரை வைத்து ஊகிக்கப்படுவதில்லை.'
    AdvisoryAudioAdvice      = "மேலே உள்ள நிலைகளை Windows தெரிவித்துள்ளது. தெரியாத நிலை என்பது சாதனம் பழுதானது அல்லது அழைப்பில் பயன்படுத்தப்பட்டது என்பதற்கான ஆதாரம் அல்ல. ஆடியோ சிக்கல் நெட்வொர்க் சிக்கல் போலத் தோன்றலாம்.`n`nஅடுத்த படிகள்`n1. Teams பயன்படுத்தும் மைக்ரோஃபோனையும் ஒலிபெருக்கியையும் சரிபார்க்கவும்.`n2. Windows ஒலி அமைப்புகளில் அவை இணைக்கப்பட்டும் இயக்கப்பட்டும் உள்ளதை உறுதிசெய்யவும்.`n3. அழைப்புத் தரத்திற்கு நெட்வொர்க்கைக் காரணமாகக் கருதும் முன் அந்தச் சாதனங்களைச் சோதிக்கவும்."
    AdvisoryPowerHeading     = 'மின்சார நிலை'
    AdvisoryPowerScheme      = 'செயலில் உள்ள மின் திட்டம் {0}; இது CPU-வை மந்தமாக்குகிறது.'
    AdvisoryPowerBattery     = 'கணினி முதன்மை மின்சாரத்திற்கு பதிலாக பேட்டரியில் இயங்குகிறது.'
    AdvisoryPowerBatteryCharge = 'கணினி முதன்மை மின்சாரத்திற்கு பதிலாக {0}% பேட்டரியில் இயங்குகிறது.'
    AdvisoryPowerVideo       = 'மற்ற எதற்கும் முன் வீடியோ குறியாக்கம் பாதிக்கப்படும்; எனவே இந்த நிலையில் அளந்த தரம், இந்தக் கணினி அடையக்கூடிய தரம் அல்ல.'
    AdvisoryCacheHeading     = 'Teams கேச் அளவு'
    AdvisoryCacheSize        = 'Teams கேச் {0} GB.'
    AdvisoryCacheLargest     = 'மிகப் பெரிய கோப்புறை {0}.'
    AdvisoryCacheAdvice      = 'மந்த தொடக்கம் மற்றும் உள்நுழைவு சிக்கல்களுக்கு இதை அழிப்பது வழக்கமான ஆரம்ப படி, எனவே ஆழமான பகுப்பாய்வுக்கு முன் அதை நீக்கிப் பார்க்குவது நல்லது. வெளியிடப்பட்ட அளவு வரம்பு இல்லை, பெரிய கேச் தனியே கோளாறு அல்ல - இது சரிபார்க்க வேண்டியது, காரணம் அல்ல.'

    # --- Form hints ---------------------------------------------------------------
    LaneCounts               = 'தானியங்கு: {0}   பயனர்: {1}   கைமுறை: {2}'
    CaseHintBlank            = 'காலியாக இருந்தால் இயக்கக் குறிப்பு பயன்படுத்தப்படும்.'
    CaseHintRemembered       = '{0} இந்தக் கணினியில் நினைவில் உள்ளது.'
    CaseHintForgot           = '{0} மறக்கப்பட்டது.'
    CaseHintCleared          = 'வரலாறு நீக்கப்பட்டது.'
    ForgetAllPrompt          = 'இந்தக் கணினியில் நினைவில் உள்ள {0} கேஸ் எண்களையும் மறக்கவா?'
    ConsentMeTip             = 'உள்நுழைந்த கணக்கான நீங்கள் இந்த சேகரிப்பை அங்கீகரித்திருந்தால் டிக் செய்யவும். தொகுப்பு உருவாக முன் அவசியம். உங்களுக்காக ஒருபோதும் டிக் செய்யப்படாது, அமர்வுகளுக்கு இடையில் சேமிக்கப்படாது.'
    ConsentBoxTip            = 'உள்நுழைந்த கணக்கு அல்லாதவர் இந்த ஆதரவு ஈடுபாட்டுக்கு இந்தக் கணினியிலிருந்து சேகரிப்பை அங்கீகரித்தவர் யார். தொகுப்பு உருவாக முன் அவசியம். அமர்வுகளுக்கு இடையில் சேமிக்கப்படாது.'
    ConsentPlaceholder       = 'இந்த சேகரிப்பை அங்கீகரித்தவரின் பெயர் மற்றும் பங்கு'
    ConsentPlaceholderOther  = 'வேறு ஒருவர்: பெயர், பங்கு'
    ConsentNotRequired       = 'இந்த உள்ளமைப்பில் தேவையில்லை.'
    ConsentConfigured        = 'உள்ளமைக்கப்பட்டது: {0}'
    ImpactWindowTip          = 'சேகரிப்பு டிஸ்கில் ஏற்கெனவே உள்ள லாக்குகளைப் படிக்கும். அவற்றில் எவற்றை எடுக்க வேண்டும் என்பதை இது தேர்ந்தெடுக்கும் - எதுவும் நடக்க காத்திருக்காது, எனவே இப்போதைக் கடக்கும் கால அளவு கூடுதல் எதையும் சேகரிக்காது. இன்னும் மீண்டும் நிகழ்த்தக்கூடிய கோளாறைப் பிடிக்க, முதலில் அதை மீண்டும் நிகழ்த்தி பின்னர் சேகரிக்கவும்.'
    SampleIntervalTip        = 'சிக்கலை மீண்டும் நிகழ்த்தும்போது கணினி எவ்வளவு அடிக்கடி அளவிடப்படும்.'
    SampleSeconds            = '{0} வினாடி'
    CaptureIntervalHint      = '3 s-ஐ விட நுணுக்கமாகச் செய்ய முடியாது: ஒரு அளவீடு சுமார் 2.2 s ஆகும்.'
    DeepCaptureCount         = 'இந்தக் கணினியில் ஆழமான கேப்சர்கள் - {1}-இல் {0} கிடைக்கும்'
    DeepCaptureManualCaption = 'கருவிப்பெட்டி தொடங்கவில்லை - கட்டளைகள் Capture.json-இல் உள்ளன:'
    DeepOptionPacketCapture  = 'பாக்கெட் கேப்சர்'
    DeepOptionNetshTrace     = 'ஸ்டாக் சூழலுடன் நெட்வொர்க் ட்ரேஸ்'
    DeepOptionEtwSession     = 'ETW வழங்குநர் அமர்வு'
    DeepReasonNotAdmin       = 'கிடைக்கவில்லை: TLC Toolbox நிர்வாகியாக இயங்கவில்லை.'
    DeepReasonNoTool         = 'கிடைக்கவில்லை: இந்தக் கணினியில் {0} இல்லை.'
    DeepReasonNoToolNotAdmin = 'கிடைக்கவில்லை: இந்தக் கணினியில் {0} இல்லை, மேலும் TLC Toolbox நிர்வாகியாக இயங்கவில்லை.'
    DeepReasonNoPacketTool   = 'கிடைக்கவில்லை: இந்தக் கணினியில் pktmon.exe, netsh.exe இரண்டும் இல்லை.'
    DeepReasonNoPacketToolNotAdmin = 'கிடைக்கவில்லை: இந்தக் கணினியில் pktmon.exe, netsh.exe இரண்டும் இல்லை, மேலும் TLC Toolbox நிர்வாகியாக இயங்கவில்லை.'
    ElevateTip               = 'இந்தச் சாளரத்தை மூடி, ஆழமான கேப்சர்கள் இயங்க TLC Toolbox-ஐ மீண்டும் நிர்வாகி உரிமைகளுடன் திறக்கும். உங்கள் கணினி மீள்தொடங்காது. Windows உறுதிப்படுத்தச் சொல்லும், மேலும் படிவத்தில் ஏற்கெனவே தட்டச்சிட்டவை எடுத்துச் செல்லப்படாது.'
    DeepCaptureTip           = 'ஹெடர்கள் மட்டும், அளவு வரம்புடன், ட்ரேஸுடன் தொடங்கி அதனுடன் நிறுத்தப்படும். pktmon-ஐ பயன்படுத்தும், அல்லது pktmon-ன் ஒற்றை அமர்வு ஏற்கெனவே பிடித்துக் கொண்டிருந்தால் - நிர்வகிக்கப்படும் கணினியில் Defender மூலம் - netsh trace ட்ரேஸை பயன்படுத்தும். முழுக் கணினி அளவில், எனவே அது பதிவாகி பின்னர் சுத்தம் செய்யப்படும்.'
    OutputHintCreated        = 'இல்லையெனில் உருவாக்கப்படும்.'
    OutputHintBlank          = 'காலியாக இருந்தால் {0}'
    EndpointHintChecking     = 'இந்தக் கணினி பிற எண்ட்பாயிண்ட்களை அடையுமா என்று சரிபார்க்கிறது...'
    EndpointHintReady        = 'அந்தக் கணினிகளருகில் யாரும் தேவையில்லை. அதே இயக்கத்தில், ஒரு தொகுப்பிற்குள் சேகரிக்கப்படும். கமா அல்லது வரியாகப் பிரிக்கவும்.'

    # --- While a run goes ---------------------------------------------------------
    SummaryScenarioLabel     = 'சூழ்நிலை'
    SummaryCaseLabel         = 'கேஸ்'
    SummaryUserLabel         = 'பயனர்'
    SummaryWindowLabel       = 'கால அளவு'
    SummaryNone              = '(இல்லை)'
    SummaryWindowLive        = 'நேரடி கேப்சர்  -  இயக்கத்தை நிறுத்து அழுத்தும் வரை அளவீடு'
    SummaryWindowNone        = '(கால அளவு இல்லை)'
    SummaryWindowSpan        = '{0}  -{1} / +{2} நிமி'
    SummaryConsentPlaceholder = 'இந்த சேகரிப்புக்கு ஒப்புக்கொண்டவரின் பெயர்'
    SummaryConsentPlaceholderOther = 'அல்லது வேறு ஒருவர்'
    RecordButton             = 'பதிவு செய்'
    RecordConsentTitle       = 'ஒப்புதல்'
    RecordConsentPrompt      = 'உங்கள் கணக்கைத் டிக் செய்யவும், அல்லது இந்த சேகரிப்புக்கு ஒப்புக்கொண்டவரின் பெயரை உள்ளிடவும், பின்னர் பதிவு செய் என்பதை அழுத்தவும்.'
    RunConsentMissing        = 'ஒப்புதல் பதிவு செய்யப்படவில்லை. இந்த சேகரிப்பு இயங்கும், அதை நிறுத்தாமல் கீழே பதிவு செய்யலாம்.'
    PackageConsentMissing    = 'ஒப்புதல் பதிவு செய்யப்படவில்லை, எனவே இங்கே தேர்ந்தெடுத்த ஒவ்வொரு இயக்கத்திற்கும் தொகுப்பாக்குதல் மறுக்கப்படும். இதை மூடி, படிவத்தில் "ஒப்புதல் அளித்தவர்" அருகில் உங்கள் கணக்கை டிக் செய்யவும் அல்லது யார் அங்கீகரித்தார் என்பதை உள்ளிடவும், பின்னர் தொகுப்பாக்கு என்பதை மீண்டும் அழுத்தவும்.'
    DeepSummaryAll           = 'ஆழமான கேப்சர்கள்: {0} அனைத்தும் கிடைக்கும்.'
    DeepSummaryNone          = 'ஆழமான கேப்சர்கள்: {0}-இல் எதுவும் இயங்கவில்லை. {1} அளவீட்டு அமர்வு பாதிக்கப்படாது.'
    DeepSummarySome          = 'ஆழமான கேப்சர்கள்: {1}-இல் {0} இயங்குகின்றன. இயங்காதவை: {2}. {3}'
    ProgressHeading          = 'முன்னேற்றம்'
    PhaseArm                 = '1. தயார்'
    PhaseReproduce           = '2. மீண்டும் நிகழ்த்து'
    PhaseCollect             = '3. சேகரி'
    PhaseDetailArm           = 'தயார் செய்கிறது. இன்னும் எதுவும் பதிவு செய்யப்படவில்லை - சிக்கலை நிகழ்த்துவதற்கு முன் அடுத்த படி வரை காத்திருக்கவும்.'
    PhaseDetailReproduce     = 'இப்போது பதிவு செய்கிறது. சிக்கலை நிகழ்த்தி, பின்னர் இயக்கத்தை நிறுத்து என்பதை அழுத்தவும்.'
    PhaseDetailCollect       = 'பதிவு முடிந்தது. அளவீடுகளும் சுருக்கமும் எழுதப்படுகின்றன - பின்னர் Teams அதன் ஆதரவுக் கோப்புகளைக் கேட்கலாம், எனவே கீழே உள்ள லாக்கைப் பாருங்கள்.'
    RunStarting              = 'தொடங்குகிறது: மாட்யூல்கள் ஏற்றப்படுகின்றன ({0} s)'
    RunRecordingOne          = 'பதிவு செய்கிறது - {0:mm\:ss}, {1} அளவீடு. முடிந்ததும் இயக்கத்தை நிறுத்து என்பதை அழுத்தவும்.'
    RunRecordingMany         = 'பதிவு செய்கிறது - {0:mm\:ss}, {1} அளவீடுகள். முடிந்ததும் இயக்கத்தை நிறுத்து என்பதை அழுத்தவும்.'
    RunStopping              = 'நிறுத்துகிறது...'
    RunSamplingStopped       = 'அளவீடு நிறுத்தப்பட்டது. அமர்வின்போது எழுதப்பட்ட லாக்குகள் சேகரிக்கப்படுகின்றன...'
    RunStoppingBeforeClose   = 'மூடும் முன் ட்ரேஸை நிறுத்துகிறது...'
    RunFailedToStart         = 'தொடங்க முடியவில்லை.'
    RunStopped               = 'நிறுத்தப்பட்டது.'
    RunBlocked               = 'தடுக்கப்பட்டது - காரணத்தை மேலுள்ள டிரான்ஸ்கிரிப்ட் சொல்கிறது.'
    RunExitCode              = 'வெளியேறு குறியீடு {0} உடன் முடிந்தது.'
    RunFinished              = 'முடிந்தது.'
    RunPackagedZipped        = '{0} இயக்கங்கள் தொகுப்பாக்கப்பட்டு zip செய்யப்பட்டன.'
    RunPackagedSomeRefused   = '{0} இயக்கங்கள் தொகுப்பாக்கப்பட்டு zip செய்யப்பட்டன; {1} சீல் செய்யப்படவில்லை.'
    RunNothingSealed         = 'எந்த இயக்கத்தையும் சீல் செய்ய முடியவில்லை, எனவே எதுவும் zip செய்யப்படவில்லை.'
    RunProgressFailed        = 'முன்னேற்ற அறிக்கை தோல்வி: {0}'
    CloseDuringTraceState    = 'ஒரு நேரடி ட்ரேஸ் இன்னும் பதிவு செய்கிறது.'
    CloseDuringTraceEffect   = 'இப்போது மூடினால் அது நிற்கும்: அளவீடுகளும் சுருக்கமும் வைக்கப்படும், ஆனால் அது பின்னர் சேகரிக்கும் லாக்குகளும் Teams ஆதரவுக் கோப்புகளும் தவிர்க்கப்படும்.'
    CloseDuringTraceAsk      = 'ட்ரேஸை நிறுத்தி மூடவா?'
    CloseDuringRunState      = 'ஒரு இயக்கம் இன்னும் நடக்கிறது.'
    CloseDuringRunEffect     = 'சாளரத்தை மூடினால் அது தனியாகத் தொடர்ந்து முடியும், அதன் இயக்கக் கோப்புறை அது எப்படி முடிந்தது என்பதை பதிவு செய்யும், ஆனால் அதை நீங்கள் இங்கே பார்க்க முடியாது. தொகுப்பாக்க காத்திருக்கும் இயக்க வரிசை இதன் பிறகு நிற்கும்.'
    CloseDuringRunAsk        = 'இன்னும் மூடவா?'

    # --- Scenario names ---------------------------------------------------------
    # Shown in the scenario list and the summaries. The run, the command and the bundle record the
    # scenario's Id and its English name, so these change the window only. Each English entry is the
    # catalog's own name, which the gate holds them to; each must fit the scenario box, measured.
    ScenarioNameDesktopLaunchCrash       = 'Teams Desktop: தொடக்கம், கிராஷ், செயல்திறன் சிக்கல்'
    ScenarioNameDesktopSignIn            = 'Teams Desktop: உள்நுழைவு அல்லது அங்கீகார தோல்வி'
    ScenarioNameWebClient                = 'Teams Web: உலாவி/Web கிளையன்ட் சிக்கல்'
    ScenarioNameCallQuality              = 'கூட்டம்/அழைப்பு: தரம் குறைவு'
    ScenarioNameMeetingJoin              = 'கூட்டம்/அழைப்பு: சேரல் அல்லது அமைப்பு தோல்வி'
    ScenarioNameFiles                    = 'Teams கோப்புகள்: ஏற்றல், திறப்பு, பகிர்வு, அணுகல் சிக்கல்'
    ScenarioNameMobile                   = 'Teams Mobile: மொபைல் கிளையன்ட் சிக்கல்'
    ScenarioNameRooms                    = 'Teams Rooms: சாதன சிக்கல்'
    ScenarioNameVdi                      = 'VDI-இல் Teams சிக்கல்'
    ScenarioNameTenantService            = 'டெனன்ட் முழுவதும் அல்லது சேவை கிடைப்பில் பாதிப்பு'
    ScenarioNameNetwork                  = 'நெட்வொர்க், ஃபயர்வால், ப்ராக்ஸி அல்லது VPN சிக்கல்'
    ScenarioNameRoomsAndroid             = 'Teams Rooms on Android: சாதன சிக்கல்'
    ScenarioNameCviRoomSegment           = 'Cloud Video Interop: அறை பகுதி ஒப்பீடு'

    # --- Tile hover text -------------------------------------------------------
    TileDetailPending                    = 'இந்தச் சரிபார்ப்பு இன்னும் முடிவடையவில்லை.'

    # --- Tile detail windows ---------------------------------------------------
    DetailLogFolderLabel                 = 'லாக் கோப்புறை'
    DetailNoLogFolder                    = 'லாக் கோப்புறை உள்ளமைக்கப்படவில்லை.'
    DetailOpenLogFolder                  = 'லாக் கோப்புறையைத் திற'
    DetailLowDisk                        = 'காலியிடம் குறைவாக இருப்பதால் Teams லாக்குகளை எழுதாமல் நிற்கலாம், சேகரிப்பு நடுவில் தோல்வியடையலாம்.'
    FactFiles                            = 'கோப்புகள்'
    FactFilesMatching                    = '{1}-க்கு பொருந்தும் {0}'
    FactSize                             = 'அளவு'
    FactOldest                           = 'பழையது'
    FactNewest                           = 'புதியது'
    FactFreeDisk                         = 'காலி டிஸ்க்'
    FactFreeDiskValue                    = '{2}-இல் {1} GB-இல் {0} GB காலி'
    FactYes                              = 'ஆம்'
    FactNo                               = 'இல்லை'
    DetailActivityBody                   = 'புதிய லாக் கோப்புதான் இது படிப்பது. பல மணிநேரமாகத் தொடப்படாத கோப்புறை Teams இயங்கவில்லை என்று பொருள், எனவே இப்போது பிடிக்கப்பட்ட கிளையன்ட் நிலை தோல்வியடைந்த கிளையன்ட் அல்ல.'
    DetailHeadingCrash                   = 'கடந்த 24 மணியில் கிராஷ்கள்'
    FactWebViewCrashes                   = 'WebView2 கிராஷ்கள்'
    FactWebViewNotMeasurable             = 'அளவிட முடியாது - இந்தப் புரொஃபைலில் Crashpad ரிப்போர்ட் கோப்புறை இல்லை'
    FactNoneRecorded                     = 'எதுவும் பதிவாகவில்லை'
    FactWebViewReports                   = '{0} ரிப்போர்ட், புதியது {1}'
    FactReportFolder                     = 'ரிப்போர்ட் கோப்புறை'
    DetailCrashWebViewBody               = 'New Teams WebView2-இல் இயங்குகிறது, மேலும் ரெண்டரர் கிராஷ் - சாளரம் வெறுமையாகுதல் அல்லது செயலி தானே மீண்டும் ஏறுதல் - பயன்பாடு நிகழ்வு லாக்கை நம்பகமாக அடையாது. டம்ப்கள் திட்டமிட்டே கணினியில் விடப்படுகின்றன: மினிடம்ப்-ல் செயல்முறை நினைவகம் இருக்கும், உள்நுழைந்த கிளையன்ட் என்றால் அதில் டோக்கன்கள் மற்றும் செய்தி உள்ளடக்கம் இருக்கும்.'
    CrashDetailNone                      = 'கடந்த {0} மணியில் பயன்பாடு லாக்கில் Teams கிராஷ் நிகழ்வுகள் இல்லை.'
    CrashDetailUnreadable                = 'பயன்பாடு லாக்கைப் படிக்க முடியவில்லை: {0}'
    CrashDetailHeader                    = '{0}   {1}, நிகழ்வு {2}'
    CrashDetailApplication               = 'கோளாறான பயன்பாடு: {0} {1}'
    CrashDetailModule                    = 'கோளாறான மாட்யூல்: {0} {1}'
    DetailHeadingClient                  = 'Teams கிளையன்ட்'
    DetailClientBody                     = 'உள்நுழைந்த பயனர்-க்கான தொகுப்பு தகவல்கள் Get-AppxPackage-இலிருந்து வருகின்றன.'
    DetailClientNotRegistered            = 'MSTeams தொகுப்பு இந்தப் பயனருக்குப் பதிவு செய்யப்படவில்லை.'
    DetailClientUnreadable               = 'தொகுப்பு-ஐ படிக்க முடியவில்லை: {0}'
    FactVersion                          = 'பதிப்பு'
    FactStatus                           = 'நிலை'
    FactSignature                        = 'கையொப்பம்'
    FactInstallPath                      = 'நிறுவல் பாதை'
    FactPresentOnDisk                    = 'டிஸ்கில் உள்ளது'
    FactAudioPlayback                    = 'ஆடியோ பிளேபேக்'
    FactAudioNoPlayback                  = 'இல்லை - இங்கே எதுவும் அழைப்பு-ஐ ஒலிக்கவைக்க முடியாது'
    FactAudioRecording                   = 'ஆடியோ பதிவு'
    FactAudioNoRecording                 = 'இல்லை - இங்கே எதுவும் மைக்ரோஃபோனை எடுத்திருக்க முடியாது'
    FactAudioFaults                      = 'ஆடியோ கோளாறுகள்'
    FactCacheSize                        = 'கேச் அளவு'
    FactLargestCacheFolder               = 'பெரிய கேச் கோப்புறை'
    FactPowerScheme                      = 'மின் திட்டம்'
    FactPowerSource                      = 'மின்சார மூலம்'
    FactBattery                          = 'பேட்டரி'
    FactBatteryAt                        = 'பேட்டரி {0}%'
    FactMains                            = 'முதன்மை மின்சாரம்'
    DetailRetentionBody                  = 'வைத்திருப்பு என்பது டிஸ்கில் இன்னும் உள்ள பழைய லாக்கிலிருந்து அளவிடப்படுகிறது, கொள்கை-இலிருந்து அல்ல. Teams அதன் லாக்குகளைத் தானே சுழற்றுவதால், சேகரிப்பு உண்மையில் இவ்வளவு தூரம் மட்டுமே செல்ல முடியும்.'
    DetailRetentionRolling               = 'சுழலும் கிளையன்ட் லாக்குகள் மட்டுமே இந்த எல்லையை நிர்ணயிக்கும். சேகரிப்பான் autostarter லாக் போன்ற அடர்த்தியற்ற குடும்பங்கள்-ஐயும் எடுக்கும்; அதை Teams தொடக்கத்தில் மட்டும் எழுதி நீண்ட காலம் வைத்திருக்கும் - அவற்றை எண்ணினால் செல்லுமிடம் ஒரு வருடம் என்று காட்டும், ஆனால் சான்று இங்கேயே நிற்கும்.'
    FactMeasuredFrom                     = 'இதிலிருந்து அளந்தது'
    FactMeasuredFromValue                = '{1}-இல் {0} சுழலும் கிளையன்ட் லாக்குகள் சேகரிக்கப்பட்டன'
    DetailHeadingCoverage                = 'தேர்ந்தெடுத்த கால அளவு'
    DetailCoverageBodyPick               = 'முதலில் "என்ன செய்ய வேண்டும்" என்பதின் கீழ் பணியைத் தேர்ந்தெடுக்கவும். இருக்கும் லாக்குகளைத் தொகுப்பாக்கும்போது மட்டுமே இந்த டைல் பதில் தரும், ஏனெனில் நீங்கள் கேட்ட கால அளவை டிஸ்கில் இன்னும் உள்ள லாக்குகளுடன் ஒப்பிடுகிறது.'
    DetailCoverageBodyLive               = 'நேரடி ட்ரேஸ் அதைத் தொடங்கும் தருணத்திலிருந்து பதிவு செய்கிறது, எனவே வைத்திருக்கும் லாக்குகளுடன் ஒப்பிட எந்த கால அளவும் இல்லை. அது மூடிய நேரங்கள் இயங்கும்போது அளவிடப்பட்டு Capture.json-இல் எழுதப்படும்.'
    DetailCoverageBodyGather             = 'நீங்கள் தட்டச்சிடும் போதே மீண்டும் மதிப்பிடும் ஒரே டைல் இது. நீங்கள் தட்டச்சிட்ட கால அளவு வைத்திருக்கும் லாக்குகளுக்கு வெளியே இருந்தாலும் மற்ற எல்லா டைல்கள்-ம் பச்சையாக இருக்கலாம்.'
    FactBefore                           = 'முன்'
    FactAfter                            = 'பின்'
    FactMinutes                          = '{0} நிமிடம்'
    DetailNetworkBody                    = 'சேவைகளிலிருந்து கண்டறியப்பட்டது, வழிகள் அல்லது அடாப்டர்கள்-இலிருந்து அல்ல: SASE கிளையன்ட் எந்த VPN இணைப்பு ஆப்ஜெக்ட்-ஐயும், தெரியும் அடாப்டர்-ஐயும் உருவாக்காது.'
    DetailNetworkUnreadableBody          = 'நெட்வொர்க் பாதையைப் படிக்க முடியவில்லை: {0}'
    DetailDnsResolves                    = '{0}, {2} ஹாப் வழியாக {1} ஆக தீர்க்கப்படுகின்றன ஆகிறது'
    FactPath                             = 'பாதை'
    FactTlsChain                         = 'TLS சங்கிலி'
    FactTlsNoHandshake                   = '{0}-க்கு ஹேண்ட்ஷேக் முடிவடையவில்லை, எனவே இடைமறிப்பு உள்ளதா இல்லையா தீர்மானிக்க முடியாது'
    FactTlsPublicRoot                    = 'பொது ரூட் ({0})-இல் முடிகிறது'
    FactTlsNotPublic                     = '''{0}''-இல் முடிகிறது, அது பொது ரூட் அல்ல - பிரேக்-அண்ட்-இன்ஸ்பெக்ட் இப்படித்தான் தெரியும்'
    FactTlsProtocol                      = 'TLS நெறிமுறை'
    FactTunnelState                      = '{0}, இயங்குகிறது: {1}'
    FactWifi                             = 'வைஃபை'
    FactWifiNone                         = '802.11 அடாப்டர் இல்லை, எனவே வைஃபை காரணம் அல்ல'
    FactWifiDisconnected                 = 'அடாப்டர் உள்ளது ஆனால் இணைக்கப்படவில்லை - மீடியா வேறு வழியாக சென்றது'
    FactWifiSignal                       = '{0}% சிக்னல்'
    FactWifiReceive                      = '{0} Mbps பெறல்'
    FactWifiNoDetail                     = 'இணைந்துள்ளது, ரேடியோ விவரம் படிக்க முடியவில்லை'
    DetailUpdateBody                     = 'இயங்கும் பில்ட் மற்றும் முந்தைய அமர்வு இயக்கிய பில்ட்-ஐ பதிவு செய்யும் லாஞ்சர் லாக்குகளிலிருந்து மீட்கப்பட்டது. அவை வேறுபடும் வரி புதுப்பிப்பு ஆகும்.'
    DetailUpdateHistory                  = 'புதுப்பிப்பு வரலாறு, பழையது முதலில்:'
    DetailUpdateRetention                = 'லாஞ்சர் லாக்குகளின் சொந்த வைத்திருப்பு-க்குள் உள்ள புதுப்பிப்புகள் மட்டும் இங்கே தோன்றும்; எனவே அதற்கு முந்தைய வரலாறு இல்லை என்பதே எதுவும் நடக்கவில்லை என்ற சான்று அல்ல.'
    DetailUpdateNoChange                 = 'டிஸ்கில் உள்ள லாஞ்சர் லாக்குகளில் பதிப்பு மாற்றம் எதுவும் பதிவு செய்யப்படவில்லை.'
    DetailUpdateNotLoaded                = 'புதுப்பிப்பு வரலாறு ஏற்றம் முடிவடையவில்லை, அல்லது லாக் கோப்புறையைப் படிக்க முடியவில்லை.'
    FactCurrentVersion                   = 'தற்போதைய பதிப்பு'
    FactBuildStaged                      = 'பில்ட் தயார்'
    FactLauncherLogs                     = 'லாஞ்சர் லாக்குகள்'
    FactScanned                          = '{0} சோதிக்கப்பட்டன'
    DetailHeadingSignIn                  = 'உள்நுழைந்த கணக்குகள்'
    FactIdentity                         = 'அடையாளம் {0}'
    FactIdentityValue                    = '{0} - ID {1} - {2}'
    FactIdentityExpected                 = 'இங்கே எதிர்பார்க்கப்பட்டது'
    FactIdentityUndeclared               = 'உங்கள் பட்டியலில் இல்லை - கீழே பார்க்கவும்'
    FactTenantUnresolved                 = 'தீர்க்கப்படவில்லை'
    FactStateFolder                      = 'நிலை கோப்புறை'
    FactAccountsExpected                 = 'எதிர்பார்க்கும் கணக்குகள்'
    FactRefuseUnexpected                 = 'எதிர்பாராதவை இருந்தால் மறுத்து'
    DetailSignInDeclared                 = '"அறிவிக்கப்பட்டது" என்பதன் பொருள். இந்தக் கருவிப்பெட்டி உங்களுக்கு தொகுப்பு கொடுக்கும் முன், இந்தக் கணினியில் கண்ட ஒவ்வொரு கணக்கையும் நீங்கள் எதிர்பார்ப்பதாகச் சொன்ன கணக்குகளின் சுருக்கமான பட்டியலுடன் ஒப்பிடுகிறது. அந்தப் பட்டியலில் உள்ள கணக்கு "அறிவிக்கப்பட்டது". இல்லாதது தொகுப்பு தொகுப்பாக்கப்படுவதை நிறுத்தும்.'
    DetailSignInWhy                      = 'ஆதரவு தொகுப்பு உங்கள் கைகளிலிருந்து வெளியேறுவதால் இந்தச் சரிபார்ப்பு உள்ளது. New Teams இந்தக் கணினியில் உள்நுழைந்த ஒவ்வொரு கணக்கிற்கும் நிதானத் தரவு எழுதுகிறது; எனவே பகிரப்பட்ட அல்லது பல-டெனன்ட் கணினியில், கேஸுடன் சம்பந்தமில்லாத ஒருவரையும் சேகரிப்பு எடுத்துக்கொள்ளலாம். ஊகிக்காமல், கருவிப்பெட்டி மறுத்து இங்கே யார் சேர வேண்டும் என்பதை உறுதிப்படுத்தச் சொல்லும்.'
    DetailSignInNothingSent              = 'இந்தச் சரிபார்ப்பால் எதுவும் எங்கும் அனுப்பப்படாது; கணக்கை அறிவிப்பது Teams-ஐயும் உங்கள் உள்நுழைவு-இல்-ஐயும் மாற்றாது. இந்தக் கணக்கு தோன்ற வேண்டும் என்று நீங்கள் எதிர்பார்க்கிறீர்கள் என்பதை உள்ளூர் கோப்பு-இல் மட்டும் பதிவு செய்கிறது.'
    DetailSignInHowHeading               = 'அவற்றை எப்படி அறிவிப்பது'
    DetailSignInPress                    = 'இந்தச் சாளரத்தின் கீழே உள்ள "{0}" என்பதை அழுத்தவும். அது ids-ஐ உங்களுக்காக எழுதும், ஏற்கெனவே இருக்கும் கோப்பு-க்கு தேதியிட்ட பேக்கப் வைத்துக் கொள்ளும், வேறு எதையும் மாற்றாது.'
    DetailSignInByHand                   = 'அல்லது கையால் செய்யவும்:'
    DetailSignInStep1                    = '1. கீழே உள்ள கோப்பை நோட்பேடு-இல் திறக்கவும். அது இன்னும் இல்லையெனில், உருவாக்கவும்.'
    DetailSignInStep2                    = '2. மேலுள்ள ஒவ்வொரு கணக்கின் முழு ஆப்ஜெக்ட் ID-ஐ Privacy.KnownAccountIds-இல் இந்த வடிவில் சேர்க்கவும்:'
    DetailSignInStep3                    = '3. கருவிப்பெட்டியை மீண்டும் திறக்கவும். இந்த டைல் பச்சையாகும்.'
    DetailSignInShortIds                 = 'மேலுள்ள ids திரைக்காகச் சுருக்கப்பட்டவை. முழு மதிப்புகள் செயலி_settings.json-இல், மேலே பட்டியலிட்ட நிலை கோப்புறை-இல், "active_users" கீழ் உள்ளன.'
    DetailSignInOptOut                   = 'பட்டியலை பராமரிக்க விரும்பவில்லை என்றால், அதே கோப்பில் Privacy.BlockOnUnknownAccount-ஐ false ஆக அமைக்கவும். அப்போது கருவிப்பெட்டி அறியப்படாத கணக்குகளை தொகுப்பாக்க மறுப்பதற்குப் பதிலாக ரிப்போர்ட் செய்யும் - இது நினைத்து எடுக்க வேண்டிய தேர்வு, இயல்புநிலை ஆக மாறிவிட வேண்டியது அல்ல.'
    DetailSignInAboutHeading             = 'மேலே காட்டியவை பற்றி'
    DetailSignInDomain                   = 'ஒவ்வொரு அடையாளமும் அதன் கணக்கின் டொமைன் மூலம் பெயரிடப்படுகிறது; ஏனெனில் ஒரு அடைவு-ஐ ஒருவருக்குத் தெரியப்படுத்துவது அதுவே. அருகிலுள்ள டெனன்ட் GUID சுருக்கப்பட்டதாகும்; ஒரு டொமைன்-ஐ பகிரும் இரண்டு டெனன்ட்கள்-ஐ வேறுபடுத்தவே அது உள்ளது. கணக்கு பெயர் தானாக ஒருபோதும் காட்டப்படாது, ஏனெனில் இந்தச் சாளரம் யாரோ பகிர்ந்து பயன்படுத்தும் கணினியில் திறக்கப்படலாம்.'
    DetailSignInSource                   = 'கணக்குகள் செயலி_settings.json -> active_users இலிருந்து வருகின்றன; இயக்கம் பிறகு தனியுரிமை வாயில் படிக்கும் மூலம் அதுவே, எனவே இங்கே நீங்கள் காண்பதையே வாயில் மதிப்பிடும்.'
    DetailSignInTwoTenants               = 'ஒருவர் இரண்டு டெனன்ட்கள்-இல் உள்நுழைந்தால் இரண்டு உள்ளீடுகள் உருவாகும்; இது சாதாரணம், ஏதாவது தவறு என்ற அறிகுறி அல்ல.'
    DetailSignInGreen                    = 'பச்சை என்றால் இந்த கணக்கு சரிபார்ப்பு கடக்கும் ஆகும். தொகுப்பாக்குதல் வெற்றியடையும் என்ற வாக்குறுதி அல்ல: ஒப்புதல் மற்றும் பேரர்-டோக்கன் ஸ்கேன் இன்னும் இல்லாத சான்று-க்கு எதிராக மதிப்பிடப்படும்.'
    DeclareButton                        = 'இந்தக் கணக்குகளை அறிவி'
    DeclareTitle                         = 'கணக்குகளை அறிவி'
    DeclareNoIds                         = 'செயலி_settings.json-இலிருந்து உள்நுழைந்த கணக்கு IDs எதையும் படிக்க முடியவில்லை, எனவே எதுவும் எழுதப்படவில்லை.'
    DeclareDone                          = '{0} கணக்கு ID-கள் இங்கே அறிவிக்கப்பட்டன:'
    DeclareBackup                        = 'முந்தைய கோப்பு இங்கே நகல் செய்யப்பட்டது:'
    DeclareReopen                        = '"{0}" டைல் பச்சையாக மாற கருவிப்பெட்டியை மீண்டும் திறக்கவும்.'
    DeclareNothing                       = 'சேர்க்க எதுவும் இல்லை - எல்லா உள்நுழைந்த கணக்குகளும் ஏற்கெனவே இங்கே அறிவிக்கப்பட்டுள்ளன:'
    DeclareFailed                        = 'கணக்குகளை அறிவிக்க முடியவில்லை:'

    # --- Problems with what was filled in ---------------------------------------
    # Worded for the window. The command line prints its own English, which names switches rather than controls.
    RunCannotStart                       = 'தொடங்க முடியாது:'
    ProblemCaseNumber                    = 'இந்தக் கருவிப்பெட்டி கேஸ் எண் தேவைப்படும்படி அமைக்கப்பட்டுள்ளது. சேகரிக்க ஒன்றை உள்ளிடவும், அல்லது "{0}" என்பதை டிக் செய்யவும்.'
    ProblemScenarioMissing               = 'தொடங்குவதற்கு முன் "{0}" கீழ் ஒரு சூழ்நிலையைத் தேர்ந்தெடுக்கவும்.'
    ProblemScenarioUnknown               = '"{0}" இந்தக் கருவிப்பெட்டி அறிந்த சூழ்நிலை அல்ல. பட்டியலில் ஒன்றைத் தேர்ந்தெடுக்கவும்.'

    # --- Run transcript ----------------------------------------------------------
    TranscriptRunning                    = 'இயங்குகிறது:'
    TranscriptWarning                    = 'எச்சரிக்கை:'
    RunCoverageWarning                   = 'கால அளவு மூடல்: {0}. {1}'

    # --- Tile explanations -------------------------------------------------------
    # The hover text and the summary line of each detail window. The metric functions write each
    # sentence with New-TlcMetricText, naming its key and its English; the gate holds every English
    # entry here to that literal, word for word, so the window and the logs say the same thing.
    DetailCoveragePickAJob               = 'டிஸ்கில் இன்னும் உள்ள லாக்குகள் நீங்கள் கேட்கும் கால அளவை மூடுகிறதா என்பதை இது அளக்கும்; இது இருக்கும் லாக்குகளைத் தொகுப்பாக்கும்போது மட்டும் பொருந்தும். "என்ன செய்ய வேண்டும்" கீழ் ஒரு பணியைத் தேர்ந்தெடுக்கவும், அது பதில் தரும்.'
    DetailCoverageLive                   = 'நேரடி ட்ரேஸ் நீங்கள் தொடங்கும் தருணத்திலிருந்து "இயக்கத்தை நிறுத்து" என்பதை அழுத்தும் வரை பதிவு செய்கிறது, எனவே வைத்திருக்கும் லாக் மூடல் பொருந்தாது. கோளாறு ஏற்கெனவே நடந்திருந்தால் அதன் பதிலாக இருக்கும் லாக்குகளைத் தொகுப்பாக்கவும்.'
    DetailLogsUninspected                = 'லாக் கோப்புறையைச் சோதிக்க முடியவில்லை, எனவே இவை பூஜ்யம் அல்ல, தெரியாதவை. {0}'
    DetailCheckNoResult                  = 'பின்னணி சரிபார்ப்பு முடிவைத் தரவில்லை.'
    DetailCheckFailed                    = 'பின்னணி சரிபார்ப்பு தோல்வியடைந்தது: {0}'
    DetailCoverageFailed                 = 'மூடல் கணிக்க முடியவில்லை: {0}'
    NetworkPathVpn                       = 'VPN: {0}'
    NetworkPathVpnAdapter                = 'VPN அடாப்டர்: {0}'
    NetworkPathInstalled                 = '{0} (நிறுவப்பட்டது, இயங்கவில்லை)'
    NetworkPathDirect                    = 'நேரடி'
    DetailClientNotFound                 = 'MSTeams தொகுப்பு இந்தப் பயனருக்குப் பதிவு செய்யப்படவில்லை, எனவே டெஸ்க்டாப் சேகரிப்பு எதையும் சேகரிக்காது. பாதிக்கப்பட்ட பயனர் அமர்வு-இல் இயக்கவும்.'
    DetailClientBadStatus                = 'MSTeams {0} பதிவு செய்யப்பட்டிருக்கிறது, ஆனால் நிலை ''{1}'' என தெரிவிக்கிறது, எனவே Windows செயலாக்கம்-இல் அதைத் தடுக்கும். இதை Teams கோளாறு ஆக கருதும் முன் தொகுப்பு-ஐ சரிசெய்யவும் செய்யவும் அல்லது மீண்டும் பதிவு செய்யவும் செய்யவும்.'
    DetailClientOrphaned                 = 'தொகுப்பு {0} ஆக பதிவு செய்யப்பட்டுள்ளது, ஆனால் அதன் நிறுவல் இடம் காணவில்லை: {1}. பதிவு தனியாக ஆக உள்ளது; இந்தப் பயனருக்காக தொகுப்பு-ஐ மீண்டும் பதிவு செய்யவும் செய்யவும்.'
    DetailClientOk                       = 'MSTeams {0} இந்தப் பயனருக்காக நிறுவப்பட்டுள்ளது, நிலை சரி என தெரிவிக்கிறது, அதன் நிறுவல் இடம் உள்ளது.'
    DetailLogsNoFolder                   = 'Teams லாக் கோப்புறை இந்தப் பயனருக்கு இல்லை.'
    DetailLogsEmpty                      = 'Teams லாக் கோப்புறை உள்ளது, ஆனால் கிளையன்ட் லாக்குகள் இல்லை.'
    DetailLogsCount                      = '{0} கிளையன்ட் லாக் கோப்புகள் மொத்தம் {1} MB.'
    DetailRetentionNone                  = 'எதுவும் வைத்திருக்கப்படவில்லை.'
    DetailRetentionLive                  = 'முக்கிய Teams லாக் {0} வரை தொடர்ச்சியாக உள்ளது.'
    DetailRetentionIdle                  = 'Teams இப்போது அதன் முக்கிய லாக்கை எழுதவில்லை. அதன் கடைசி அமர்வு-இன் லாக் {0} முதல் {1} வரை ஓடுகிறது.'
    DetailRetentionRotation              = 'இயங்கும் கிளையன்ட்-க்கு Teams அதன் சமீபத்திய ஏழு MSTeams_*.log லாக் கோப்புகளையும், முந்தைய ஒவ்வொரு அமர்வு-இன் கடைசி ஏழையும் மட்டும் வைத்திருக்கும்; அதைவிட பழையவை துண்டுகளாக மட்டுமே இருக்கும். பழையது {0}-இல் தொடங்குகிறது. கால அளவு டைல் நீங்கள் தேர்ந்தெடுத்த நேரம் மூடப்பட்டுள்ளதா என்று சொல்கிறது.'
    DetailRetentionOldest                = 'வைத்திருக்கும் பழைய லாக் {0}-இல் தொடங்குகிறது.'
    DetailActivityNever                  = 'இங்கே எந்த லாக்கும் ஒருபோதும் எழுதப்படவில்லை.'
    DetailActivityNewest                 = 'சமீபத்திய லாக் எழுத்து {0}.'
    DetailCoverageNoLogs                 = 'அதை மூட வைத்திருப்பது எதுவும் இல்லை.'
    DetailCoverageFuture                 = 'கால அளவு இப்போதிற்குப் பிறகு தொடங்குகிறது, எனவே அதற்கான லாக் இன்னும் இருக்க முடியாது.'
    DetailCoverageEndsAhead              = 'கால அளவு இப்போதைக் கடந்து {0} நிமிடங்கள் செல்கிறது. சேகரிப்பு ஏற்கெனவே உள்ள லாக்குகளைப் படிக்கும், காத்திருக்காது; எனவே அந்தப் பகுதி எதையும் சேர்க்காது. அதை மூட பின்னர் மீண்டும் சேகரிக்கவும், அல்லது பாதிப்பு நேரம்-ஐ கோளாறு உண்மையில் நடந்த நேரத்துக்கு அமைக்கவும்.'
    DetailCoverageRange                  = '{0} முதல் {1} வரை'
    DetailCoverageWhy                    = 'இயங்கும் கிளையன்ட்-க்கு Teams அதன் சமீபத்திய ஏழு MSTeams_*.log கோப்புகளை மட்டும் வைத்திருக்கும்; எனவே நீண்ட அமர்வு-இன் முன்னைய பகுதி லாக் எழுதும்போதே நீக்கப்படும், மீள்தொடக்கம் ஒரு சிறிய இடைவெளி-ஐ விடும்.'
    DetailCoverageMainSpans              = 'முக்கிய Teams லாக் தேர்ந்தெடுத்த முழு கால அளவையும் மூடுகிறது: {2} அன்று {0} முதல் {1} வரை. இருக்கும் லாக்குகள் அந்த பரப்பு-இலிருந்து தேர்ந்தெடுக்கப்படுகின்றன - நீங்கள் காத்திருக்கும்போது எதுவும் பதிவு செய்யப்படாது.'
    DetailCoverageBeforeMain             = 'கால அளவு பழைய வைத்திருக்கும் முக்கிய லாக் ({0})-க்கு முன் முடிகிறது.'
    DetailCoverageGap                    = 'முக்கிய Teams லாக்கில் {1} அன்று {0} முதல் எதுவும் இல்லை.'
    DetailCoverageGapRest                = 'மற்ற லாக்குகள் இன்னும் சேகரிக்கப்படுகின்றன, ஆனால் இந்த நேரத்துக்கான கிளையன்ட் லாக் போய்விட்டது.'
    DetailCoveragePartial                = 'முக்கிய Teams லாக்கில் கால அளவின் {1} நிமிடங்களில் {0} இல்லை: {2}.'
    DetailCoverageBeforeOldest           = 'கால அளவு பழைய வைத்திருக்கும் லாக் ({0})-க்கு முன் முடிகிறது.'
    DetailCoverageStartMissing           = 'லாக்குகள் {0} வரை மட்டுமே பின்னோக்கிச் செல்கின்றன, எனவே கால அளவின் தொடக்கம் இல்லை.'
    DetailCoverageRetained               = 'வைத்திருக்கும் லாக்குகள் தேர்ந்தெடுத்த முழு கால அளவையும் மூடுகின்றன: {2} அன்று {0} முதல் {1} வரை. இருக்கும் லாக்குகள் அந்த பரப்பு-இலிருந்து தேர்ந்தெடுக்கப்படுகின்றன - நீங்கள் காத்திருக்கும்போது எதுவும் பதிவு செய்யப்படாது.'
    DetailCrashWebView                   = '{0} WebView2 ரெண்டரர் கிராஷ் ரிப்போர்ட்கள்-உம் உள்ளன; அவற்றை பயன்பாடு லாக் பதிவு செய்யாது.'
    DetailCrashCount                     = 'கடந்த {1} மணியில் பயன்பாடு லாக்கில் {0} Teams தொடர்பான கிராஷ் நிகழ்வுகள்.'
    DetailCrashNone                      = 'கடந்த {0} மணியில் கிராஷ் நிகழ்வுகள் இல்லை.'
    DetailCrashUnreadable                = 'பயன்பாடு லாக்கைப் படிக்க முடியவில்லை: {0}'
    DetailNetworkInspected               = '{0}-க்கான TLS சங்கிலி பொது ரூட்-க்கு பதிலாக ''{1}''-இல் முடிகிறது; பிரேக்-அண்ட்-இன்ஸ்பெக்ட் இப்படித்தான் தெரியும் - Teams புதுப்பிப்பு மற்றும் மீடியா தோல்விகள்-க்கு காரணமாக Microsoft இதை ஆவணப்படுத்துகிறது.'
    DetailNetworkNotUntouched            = 'டனலிங் கிளையன்ட் அல்லது இணைந்த VPN எதுவும் கிடைக்கவில்லை, ஆனால் போக்குவரத்து Microsoft-ஐ தொடப்படாமல் ஆக அடையவில்லை.'
    DetailNetworkIdle                    = '{0}. நிறுவப்பட்டுள்ளது ஆனால் இயங்கவில்லை, எனவே போக்குவரத்து நேரடியாக வெளியே செல்கிறது.'
    DetailNetworkDirect                  = 'டனலிங் கிளையன்ட் அல்லது இணைந்த VPN எதுவும் கிடைக்கவில்லை, எனவே நெட்வொர்க் சரிபார்ப்புகள் நேரடி பாதை-ஐ அளக்கின்றன.'
    DetailNetworkCarried                 = 'Teams போக்குவரத்து {0} வழியாக எடுத்துச் செல்லப்படுகிறது. இதுவே கோளாறு அல்ல, ஆனால் இந்த தொகுப்பு-இல் அடைவு திறன் மற்றும் மீடியா பாதை முடிவுகள் நேரடியாக அல்லாமல் இதன் வழியே அளக்கப்பட்டவை - நெட்வொர்க் முடிவு-ஐ வாடிக்கையாளர் சிக்கல் என்று கூறுவதற்கு முன் இந்த பாதை-க்கு வெளியே உள்ள கணினி-இன் முடிவுடன் ஒப்பிடவும்.'
    DetailNetworkUnreadable              = 'நெட்வொர்க் பாதையைத் தீர்மானிக்க முடியவில்லை: {0}'
    DetailUpdateNone                     = 'புதுப்பிப்பு வரலாறு-ஐ படிக்க முடியவில்லை.'
    DetailUpdateStaged                   = 'பில்ட் {0} {1} அன்று தயாராக்கப்பட்டது செய்யப்பட்டது. லாஞ்சர் லாக்குகளில் பதிப்பு மாற்றம் எதுவும் பதிவு செய்யப்படவில்லை, எனவே இந்த கிளையன்ட் அவற்றின் வைத்திருப்பு-க்குள் புதுப்பிப்பு ஆகவில்லை.'
    DetailUpdateUnknown                  = 'டிஸ்கில் உள்ள {0} லாஞ்சர் லாக்குகளில் பதிப்பு மாற்றம் எதுவும் பதிவு செய்யப்படவில்லை, மேலும் நிறுவல் இடம்-ஐ படிக்க முடியவில்லை.'
    DetailUpdateWhen                     = '{0} அன்று {1}-இலிருந்து {2}-க்கு புதுப்பிப்பு செய்யப்பட்டது.'
    DetailUpdateInWindow                 = 'அது சேகரிக்கப்படும் கால அளவுக்குள் உள்ளது, எனவே லாக்குகள் இரண்டு வேறு கிளையன்ட் பில்ட்கள்-ஐ மூடும் - நடுவில் நடத்தை மாறலாம் என்று எதிர்பார்க்கவும், தொகுப்பு-ஐ ஒப்படைக்கும் போது அதைச் சொல்லவும்.'
    DetailUpdateUnreadable               = 'புதுப்பிப்பு வரலாறு-ஐ படிக்க முடியவில்லை: {0}'
    DetailSignInNoState                  = 'கிளையன்ட் நிலை கோப்புறை உள்ளமைக்கப்படவில்லை.'
    DetailSignInNoSettings               = 'செயலி_settings.json {0} கீழ் காணப்படவில்லை, எனவே உள்நுழைந்த கணக்குகள்-ஐ படிக்க முடியவில்லை.'
    DetailSignInNone                     = 'செயலி_settings.json-இல் உள்நுழைந்த கணக்கு எதுவும் பதிவு செய்யப்படவில்லை. வேலை செய்கிற கிளையன்ட்-இல் இது வழக்கமல்ல; கோப்பு இன்னும் எழுதப்படவில்லை என்பதாக இருக்கலாம்.'
    DetailSignInShapeTenants             = '{0} உள்நுழைந்த அடையாளங்கள், {2} டெனன்ட்கள்-ல் {1} தனித்த நபர்கள்-ஆக தீர்க்கப்படுகின்றன ஆகின்றன. ஒரே நபர் ஒன்றுக்கு மேற்பட்ட டெனன்ட்-இல் உள்நுழைந்த இருந்தால் டெனன்ட் ஒன்றுக்கு ஒரு உள்ளீடு உருவாகும்; இது சாதாரணம்.'
    DetailSignInShape                    = '{0} உள்நுழைந்த அடையாளங்கள், {1} தனித்த நபர்கள்-ஆக தீர்க்கப்படுகின்றன ஆகின்றன.'
    DetailSignInAllDeclared              = 'அனைத்து IDs-மும் Privacy.KnownAccountIds-இல் பட்டியலிடப்பட்டுள்ளன, எனவே கணக்கு சரிபார்ப்பு தொகுப்பாக்குதலைத் தடுக்காது. ஒப்புதல் மற்றும் டோக்கன் சரிபார்ப்புகள் இன்னும் பொருந்தும்; சான்று உருவாகும் முன் அவற்றை மதிப்பிட முடியாது.'
    DetailSignInNothingWrong             = 'Teams-இலும் இந்தக் கணினியிலும் தவறு எதுவும் இல்லை. இங்கே எந்தக் கணக்குகள் எதிர்பார்க்கப்படுகின்றன என்பதை கருவிப்பெட்டிக்கு சொல்லப்படவில்லை; அது அடையாளம் காணாத கணக்குக்கான சான்று-ஐ தொகுப்பு செய்வதை தனியுரிமை வாயில் மறுக்கிறது.'
    DetailSignInUndeclared               = '{1} id-களில் {0} Privacy.KnownAccountIds-இல் அறிவிக்கப்பட வேண்டும்: {2}.'
    DetailSignInOnePerson                = 'அவை அனைத்தும் ஒரே நபருக்குத் தீர்க்கப்படுகின்றன ஆகின்றன, எனவே இது பகிரப்பட்ட கணினி அல்ல; {0} டெனன்ட்கள்-இல் உள்நுழைந்த செய்த ஒரே பயனர்.'
    DetailSignInManyPeople               = 'இவை {0} வேறு நபர்களுக்குத் தீர்க்கப்படுகின்றன ஆகின்றன, எனவே சேகரிப்பதற்கு முன் வேறு யார் உள்நுழைந்த உள்ளனர் என்று சரிபார்க்கவும் - தொகுப்பு அவர்களெல்லாருக்கான சான்று-ஐ கொண்டுசெல்லும்.'
    DetailSignInAllIdentities            = 'New Teams டெனன்ட் எதுவாக இருந்தாலும் ஒவ்வொரு உள்நுழைந்த அடையாளம்-க்கும் நிதானத் தரவு எழுதுகிறது, எனவே சான்று அவை அனைத்தையும் மூடும்.'
    DetailSignInWillRefuse               = 'தொகுப்பாக்குதல் இந்த தொகுப்பு-ஐ அவை அறிவிக்கப்படும் வரை மறுக்கும்.'
    DetailSignInReportedOnly             = 'BlockOnUnknownAccount false ஆக உள்ளது, எனவே இது தடுக்கப்பட்டது ஆகாது, ரிப்போர்ட் செய்யப்பட்டது ஆகும்.'
    DetailSignInUnreadable               = 'உள்நுழைந்த கணக்குகள்-ஐ படிக்க முடியவில்லை: {0}'

    # --- Admin center steps --------------------------------------------------------
    # The portal's menus, tabs and buttons, the role names and the cmdlets are passed in as {0}, {1}: they are what the operator finds on screen or types, so they are never translated.
    AdminHeading                         = 'Teams நிர்வாக மையத்திலிருந்து சேகரித்தல்'
    AdminSummary                         = 'தொலைநிலை கிளையன்ட் லாக் சேகரிப்பு: அமைதியானது, கணினியருகில் யாரும் தேவையில்லை, 8 மணி வரை ஆகலாம்.'
    AdminFromDocs                        = 'இவை Microsoft ஆவணப்படுத்திய படிகள்; நினைவில் இருந்து சொல்லப்பட்ட போர்டல் விளக்கம் அல்ல - மெனு பெயர்கள் மாறும், பாதி நினைவில் உள்ள பாதை பெயர் மாறிய பொத்தானைத் தேடச் செய்யும்.'
    AdminBeforeStart                     = 'தொடங்கும் முன். இவற்றில் ஒவ்வொன்றும் எந்தத் தொகுப்பையும் உருவாக்காது, மேலும் 8 மணி வரை உங்களுக்கு தெரியாது:'
    AdminNotContainHeading               = 'இதில் என்ன இருக்காது'
    AdminDocsButtonNote                  = 'கீழே உள்ள பொத்தான் இதற்கான Microsoft ஆவணத்தைத் திறக்கும்; போர்டல் மாறும்போதும் சரியாக இருக்கும் பக்கம் அதுவே. மேலுள்ள {0} போர்டல் முகவரியையே கொண்டுள்ளது.'
    AdminDocsButton                      = 'Microsoft ஆவணத்தைத் திற'
    FactStep                             = 'படி {0}'
    FactRolesNeeded                      = 'தேவையான பங்குகள்'

    # --- Feature comparison --------------------------------------------------------
    CompareWindowTitle                   = 'ஒவ்வொரு கருவியும் சேகரிப்பவை'
    CompareHeading                       = 'ஒவ்வொரு கருவியும் உண்மையில் சேகரிப்பவை'
    CompareSharedHeading                 = 'இரண்டும் இதை சேகரிக்கும்'
    CompareFactColumn                    = 'தகவல்'
    CompareSidesColumn                   = 'தொலைநிலை தொகுப்பு  /  இந்தக் கருவிப்பெட்டி'
    CompareToolboxOnlyHeading            = 'இந்தக் கருவிப்பெட்டி மட்டும் இதை சேகரிக்கும்'
    CompareRemoteOnlyHeading             = 'தொலைநிலை சேகரிப்பு மட்டும் இதை வழங்கும்'
    CompareConclusion                    = 'எந்தக் கருவியும் மற்றொன்றின் சூப்பர்செட் அல்ல. அவை கிட்டத்தட்ட முற்றிலும் வேறு ஆர்டிஃபாக்ட்களை சேகரிக்கின்றன: தொலைநிலை சேகரிப்பு சேவையுடன் பேசும் Teams வெப் பயன்பாட்டைப் பிடிக்கும், இந்தக் கருவிப்பெட்டி நேட்டிவ் கிளையன்டையும் அதன் கீழிருக்கும் கணினியையும் பிடிக்கும்.'

    # --- A refused Package, in the log box ------------------------------------------
    # The run prints these in English, naming switches, for the command line and Blockers.csv (Get-TlcPackageRefusalText). The window recognises each line and shows these instead, naming the controls it has: {0}, {1} are filled with their labels from this table.
    TranscriptToFix                      = 'சரிசெய்ய:'
    PackageFixCredential                 = 'HAR-இல் உள்ள சான்றுகள் இந்தச் சரிபார்ப்புக்கு முன் தானாக நீக்கப்படும்; எனவே மீதமுள்ளது வேறு கோப்பில் இருக்கிறது அல்லது மறைப்பு அறியாத வடிவில் இருக்கிறது. பெயரிட்ட கோப்புகளை இயக்கக் கோப்புறையிலிருந்து அகற்றவும். HAR-ஐ சுத்தப்படுத்தப்பட்டதாக மீண்டும் ஏற்றுமதி செய்வது உதவாது: சுத்தப்படுத்தல் ஹெடர்களை மட்டும் நீக்கும், டோக்கன்கள் பதில் உடல்களில் உள்ளன.'
    PackageFixUnreadable                 = 'பெயரிட்ட கோப்புகளை திறந்து வைத்திருப்பதை மூடவும், அல்லது அவற்றை இயக்கக் கோப்புறையிலிருந்து அகற்றவும்.'
    PackageFixAccounts                   = 'இந்த சேகரிப்புக்குச் சேர்ந்த கணக்கு IDs-ஐ அறிவிக்கவும்: {0} டைலைத் திறந்து "{1}" அழுத்தவும். வேறு ஒருவருக்குச் சேர்ந்த கணக்கை அறிவிக்க வேண்டாம்: அதை Teams-இலிருந்து வெளியேறச் செய்து மீண்டும் சேகரிக்கவும், அல்லது அதை பெயரிடும் கோப்புகளை இயக்கக் கோப்புறையிலிருந்து அகற்றவும்; ஒவ்வொன்றும் எங்கே கண்டுபிடிக்கப்பட்டது என்பதை IdentityInventory.json சொல்கிறது. ஒப்புதலை பதிவு செய்வது இதைத் தெளிவாக்காது.'
    PackageFixConsent                    = 'இந்த சேகரிப்பை யார் அங்கீகரித்தார் என்பதை பதிவு செய்யவும்: உங்கள் கணக்கை டிக் செய்யவும் அல்லது "{0}" அருகில் பெயரைத் தட்டச்சிடவும்.'
    PackageFixFleet                      = 'இந்த எண்ட்பாயிண்ட் அடையக்கூடியதாக ஆன பிறகு அதற்காக சேகரிப்பை மீண்டும் இயக்கவும், அல்லது அந்தக் கணினியில் நேரடியாக சேகரிக்கவும்.'
    PackageExcluded                      = 'தொகுப்பிலிருந்து விலக்கப்பட்டது.'
    PackageAllRefused                    = 'தடுக்கப்பட்டது: ஒவ்வொரு எண்ட்பாயிண்டும் மறுக்கப்பட்டது, எனவே தொகுப்பு தொகுப்பாக்கப்படவில்லை.'
    PackageFixClosing                    = 'மேலே பட்டியலிட்டதைச் சரிசெய்து, பிறகு "{0}" மீண்டும் அழுத்தவும்.'

    # Why an endpoint was refused, under its name. The run fills in the counts, ids and file names; the window reads them back out of the line and puts them into these, unchanged.
    PackageReasonUnknownAccounts         = '{0} உள்நுழைந்த கணக்குகள் அறிவிக்கப்படவில்லை: {1}'
    PackageReasonManyAccounts            = '{0} கணக்குகள் உள்நுழைந்துள்ளன; கிளையன்ட் நிதானத் தரவு அவை அனைத்தையும் மூடும்.'
    PackageReasonArchives                = '{0} கிளையன்ட் உருவாக்கிய காப்பகங்கள் சேர்க்கப்பட்டுள்ளன; உள்ளடக்கம் ஒவ்வொரு உள்நுழைந்த கணக்கையும் மூடும்.'
    PackageReasonAddresses               = 'உரைச் சான்றில் {0} தனித்த முகவரிகள் கண்டுபிடிக்கப்பட்டன.'
    PackageReasonCredentials             = '{0} கோப்புகளில் அணுகல் டோக்கன்கள் கண்டுபிடிக்கப்பட்டன: {1}.'
    PackageReasonUnreadable              = '{0} கோப்புகளை தனியுரிமை ஸ்கேன் படிக்க முடியவில்லை, எனவே அவற்றின் உள்ளடக்கம் தெரியவில்லை: {1}.'
    PackageReasonPartial                 = '{0} கோப்புகள் {1} MB ஸ்கேன் வரம்பை விட பெரியவை, எனவே பகுதியளவு மட்டும் படிக்கப்பட்டன: {2}.'
    PackageReasonConsent                 = 'ஒப்புதல் தேவை, மேலும் "{0}" அருகில் யாரும் பதிவு செய்யப்படவில்லை.'
    PackageReasonFleetFailed             = '{0} இலிருந்து சேகரிப்பு தோல்வியடைந்தது, எனவே அதன் கோப்புறை பகுதியளவு மட்டுமே உள்ளது மற்றும் தடுக்கப்பட்டுள்ளது; Blockers.csv-இல் Fleet வரியைப் பார்க்கவும்.'

    # --- What the window writes into the log box -------------------------------------
    LogFailedToRun                       = 'இயக்கத் தோல்வி: {0}'
    LogExitCode                          = '(வெளியேறு குறியீடு {0})'
    LogSessionArchive                    = 'அமர்வு காப்பகம்: {0}'
    LogSessionArchiveCounts              = '{0} இயக்கங்கள், {1} கோப்புகள், {2} MB'
    LogZipFailed                         = 'தொகுப்புகள் தொகுப்பாக்கப்பட்டன, ஆனால் அமர்வு ஜிப் எழுத முடியவில்லை. ஒவ்வொரு இயக்கக் கோப்புறையும் தனியாகவே அனுப்பலாம்.'
    LogNotZipped                         = 'ஜிப்பில் இல்லை, ஏனெனில் அவை சீல் செய்யப்படவில்லை: {0}. மேலுள்ள டிரான்ஸ்கிரிப்ட் ஒவ்வொன்றுக்கும் ஏன் என்று சொல்கிறது; சீல் செய்யப்படாத எதுவும் ஒருபோதும் ஜிப் செய்யப்படாது.'
    LogStopAsked                         = 'கேப்சர் அமர்வை அளவீட்டை நிறுத்தச் சொல்லப்படுகிறது...'
    LogSamplingStopped                   = 'அளவீடு நிறுத்தப்பட்டது. இயக்கம் இப்போது அமர்வின்போது எழுதப்பட்ட லாக்குகளை சேகரித்து, பின்னர் Teams ஆதரவுக் கோப்புகளை கேட்டு, தானாக முடியும். ஆதரவுக் கோப்புகளைத் தவிர்க்க {0} மீண்டும் அழுத்தவும்.'
    LogSkippingSupport                   = 'ஆதரவுக் கோப்புகளைத் தவிர்த்து இயக்கத்தை முடிக்கிறது...'
    LogFinishedAfterStop                 = 'இயக்கம் முடிந்தது. அளவீடுகள், சுருக்கம், லாக்குகள் அனைத்தும் எழுதப்பட்டுள்ளன.'
    LogSessionUnanswered                 = 'அமர்வு பதிலளிக்கவில்லை, எனவே அது முடிக்கப்படுகிறது. ஏற்கெனவே எழுதப்பட்ட அளவீடுகள் வைக்கப்படுகின்றன.'
    LogStoppedKept                       = 'நிறுத்தப்பட்டது. இயக்கக் கோப்புறையில் ஏற்கெனவே எழுதப்பட்ட அனைத்தும் வைக்கப்படும் - தொகுப்பு முழுமையற்றது மட்டுமே. எதுவும் கைவிடப்படவில்லை.'
    LogConsentRecorded                   = 'ஒப்புதல் பதிவு செய்யப்பட்டது: {0}'

    # --- Admin center steps and feature comparison, as the metrics write them ------
    # New-TlcMetricText in Tlc.Ui.Metrics.psm1 names each key with its English; the gate holds them equal.
    AdminStepSignIn                      = '{0} இல் Teams நிர்வாக மையத்தில் உள்நுழையவும்'
    AdminStepUsers                       = '{0} சென்று, பின்னர் {1} சென்று, பாதிக்கப்பட்ட பயனரைத் திறக்கவும்.'
    AdminStepTab                         = '{0} தாவலைத் திறக்கவும்.'
    AdminStepRequest                     = '{0} தேர்ந்தெடுக்கவும். பயனரிடம் கேட்கப்படாது, எதுவும் தெரியாது.'
    AdminStepWait                        = 'காத்திருக்கவும். தொகுப்பு பதிவிறக்கத் தயாராகும் முன் 8 மணி வரை ஆகலாம் என்று Microsoft ஆவணப்படுத்துகிறது, மேலும் கோரிக்கை 3 நாட்களுக்கு பிறகு காலாவதியாகும்.'
    AdminStepDownload                    = 'அதே {0} தாவலுக்குத் திரும்பி, அதை பதிவிறக்க {1} தேர்ந்தெடுக்கவும்.'
    AdminRoles                           = '{0}, {1}, {2} அல்லது {3}.'
    AdminNeedsRunning                    = 'Teams கிளையன்ட் கணினியில் இயங்கிக் கொண்டிருக்க வேண்டும். தொடங்க முடியாத கிளையன்ட் ஒருபோதும் செக் இன் செய்யாது, கோரிக்கை வெறுமனே காலாவதியாகும்.'
    AdminNeedsPlatform                   = 'Windows non-VDI மற்றும் Mac மட்டும். VDI தெளிவாக விலக்கப்பட்டுள்ளது; வெப், மொபைல், Linux ஆகியனவும் அப்படியே.'
    AdminNeedsOneCloud                   = 'வணிக மற்றும் அரசாங்க கணக்குகளில் இரண்டிலும் உள்நுழைந்த கிளையன்ட் தகுதியற்றது - இந்த அம்சம் அதற்கு கிடைக்காது.'
    AdminNotCollected                    = 'Windows நிகழ்வு லாக்குகள், {0} ட்ரேஸ்கள், திரைப்பிடிப்புகள், ஹீப் டம்ப்கள் ஆகியவை தெளிவாக சேகரிக்கப்படாதவை என ஆவணப்படுத்தப்பட்டுள்ளன. நேர-சாளர அளவுருவும் இல்லை: அது இயங்கும் போது டிஸ்கில் உள்ளதை எடுக்கும்.'
    AdminRetention                       = 'தொகுப்புகள் Microsoft சேமிப்பகத்தில் 30 நாட்கள் வைக்கப்படும்.'
    AdminPowerShell                      = 'அதே சேமிப்பகம் PowerShell-இலிருந்து அடையக்கூடியது: {0} என்பது {1} பொத்தான், {2} என்பது {3} பக்கம், மேலும் {4} என்பது {5}.'
    CompareBasis                         = '{0} அளவிடப்பட்டது, பிடிக்கப்பட்ட தொலைநிலை-வகை தொகுப்பை (74 உள்ளீடுகள், 5.5 MB) உண்மையான சேகரிப்பு இயக்கத்திலிருந்து வந்த கருவிப்பெட்டி தொகுப்புடன் (33 கோப்புகள்) ஒப்பிட்டு. ஆவணப்படுத்தப்பட்டது எனக் குறிக்கப்பட்ட வரிகள் எந்த ஆர்டிஃபாக்டிலும் காணப்படவில்லை.'
    CompareConfigFact                    = 'கிளையன்ட் உள்ளமைப்பு'
    CompareConfigRemote                  = '{0}, 3.4 MB - வெப் கிளையன்ட் மரம்'
    CompareConfigToolbox                 = '{0}, {1} - டெஸ்க்டாப் கிளையன்ட் நிலை'
    CompareFlightFact                    = 'ஃப்லைட் ரிங், டெனன்ட், உரிமம்'
    CompareIdentityFact                  = 'உள்நுழைந்த கணக்கு அடையாளம்'
    CompareIdentityRemote                = 'ஒவ்வொரு கணக்குக்கும் ஒரு கோப்புறை'
    CompareIdentityToolbox               = '{0}, மேலும் தனியுரிமை இருப்புப்பட்டியல்'
    CompareSignallingFact                = 'அழைப்பு சிக்னலிங்'
    CompareSignallingRemote              = '{0} ({1} நிலை)'
    CompareSignallingToolbox             = '{0} லாக்குகள் - அதே கதையின் வேறு அடுக்கு'
    CompareMediaFact                     = 'மீடியா புள்ளிவிவரங்கள்'
    CompareMediaRemote                   = '{0} - அழைப்பு இல்லாமல் 0 பைட் அளந்தது'
    CompareMediaToolbox                  = 'இல்லை - உண்மையான அழைப்பில் 0 பைட்'
    CompareNativeLogsName                = 'நேட்டிவ் டெஸ்க்டாப் கிளையன்ட் லாக்குகள்'
    CompareNativeLogsDetail              = '{0}. இங்கே 7 கோப்புகள், தொலைநிலை தொகுப்பில் 0'
    CompareMediaStackName                = 'மீடியா-ஸ்டாக் லாக்குகள்'
    CompareMediaStackDetail              = '{0}. உள்ளூரில் உள்ளது, பிடிக்கப்பட்ட தொலைநிலை தொகுப்பில் இல்லை'
    CompareUpdateLogsName                = 'புதுப்பிப்பு மற்றும் லாஞ்சர் லாக்குகள்'
    CompareUpdateLogsDetail              = 'புதுப்பிக்கத் தோல்வியடைந்த கிளையன்ட் தன் காரணத்தை இங்கேதான் விளக்குகிறது, வேறு எங்கும் இல்லை'
    CompareEventLogsName                 = 'Windows நிகழ்வு லாக்குகள்'
    CompareEventLogsDetail               = 'ஆறு சேனல்கள். நிர்வாக மையம் இவை தெளிவாக சேகரிக்கப்படாதவை என்று ஆவணப்படுத்துகிறது'
    CompareInventoryName                 = 'கணினி இருப்புப்பட்டியல்'
    CompareInventoryDetail               = 'OS பில்ட், வன்பொருள், பூட் நேரம், நேர மண்டலம் மற்றும் ஆஃப்செட், {0}, தொகுப்பு நலம், கேச் தடம்'
    CompareJoinName                      = 'சாதன இணைப்பு நிலை'
    CompareJoinDetail                    = '{0}, டொமைன் மற்றும் பணியிட இணைப்பு - தொலைநிலையில் இணையானது எதுவும் இல்லை'
    CompareVdiName                       = 'VDI கண்டறிதல்'
    CompareVdiDetail                     = 'தளம் மற்றும் {0} நிலை. நிர்வாக மையம் VDI-இல் ஆதரிக்கப்படாதது என ஆவணப்படுத்தப்பட்டுள்ளது'
    CompareNetworkName                   = 'முழு நெட்வொர்க் பாதை'
    CompareNetworkDetail                 = 'DNS சங்கிலி, TLS இடைமறிப்பு, {0} மற்றும் {1} ப்ராக்ஸி, UDP மற்றும் STUN அடைவு திறன். தொலைநிலை தொகுப்பு நெட்வொர்க் பற்றி எதுவும் சொல்லாது'
    CompareUpdateHistoryName             = 'புதுப்பிப்பு வரலாறு'
    CompareUpdateHistoryDetail           = 'எந்த பில்ட், எப்போது மாறியது'
    CompareRendererName                  = 'ரெண்டரர் கிராஷ் பதிவுகள்'
    CompareRendererDetail                = '{0} கிராஷ் எண்ணிக்கைகள் மற்றும் நேரங்கள்'
    CompareScopingName                   = 'மீள்நிகழ்த்தல்-சாளர வரம்பு'
    CompareScopingDetail                 = 'தொலைநிலை பாதையில் நேர-சாளர அளவுரு இல்லை, அது இயங்கும் போது டிஸ்கில் உள்ளதை எடுக்கும்'
    CompareChronologyName                = 'இணைக்கப்பட்ட காலவரிசை'
    CompareChronologyDetail              = 'ஒவ்வொரு லாக் குடும்பத்தையும் கடக்கும் ஒரே நேர-வரிசை ஓட்டம்'
    CompareExitReasonName                = 'கிராஷ் மற்றும் வெளியேறு காரணம்'
    CompareFailuresName                  = 'முயன்றதும் தோல்வியுற்றதும்'
    CompareFailuresDetail                = 'தடுப்புகள் மற்றும் நிகழ்வுகள். தொலைநிலை தொகுப்பு அது சேகரித்ததைச் சொல்கிறது, எதைச் சேகரிக்க முடியவில்லை என்பதை ஒருபோதும் சொல்லாது'
    CompareConsentName                   = 'ஒப்புதல் பதிவு மற்றும் தனியுரிமை வாயில்'
    CompareConsentDetail                 = 'தொகுப்புடன் ஒப்புதல் பதிவு செய்யப்பட்டது, மூல வடிவம் கேட்கப்படாவிட்டால் அடையாளிகள் மறைக்கப்படும், அறியப்படாத கணக்கில் தொகுப்பாக்குதல் மறுக்கப்படும்'
    CompareTamperName                    = 'மாற்றம்-தெரியும் தொகுப்பு'
    CompareTamperDetail                  = 'ஒவ்வொரு கோப்பிற்கும் {0}, ஒப்படைத்த பிறகு சரிபார்க்கக்கூடியது'
    CompareRoomsName                     = '{0} மற்றும் {1} தொடர்புபடுத்தல்'
    CompareRoomsDetail                   = 'Microsoft மற்றும் கூட்டாளர் இருவரும் விசையாகப் பயன்படுத்தக்கூடிய ஒரு ஹெடர்'
    CompareUnattendedName                = 'கணினியருகில் யாரும் இருக்க தேவையில்லை'
    CompareUnattendedDetail              = 'கட்டமைப்புச் சார்ந்தது. இந்தக் கருவிப்பெட்டி செய்யும் அனைத்துக்கும் கணினியில் உள்நுழைந்த அமர்வு தேவை'
    CompareNoScriptName                  = 'எண்ட்பாயிண்டில் ஸ்கிரிப்ட் இயக்கம் இல்லை'
    CompareNoScriptDetail                = '{0} அல்லது {1} சூழலில் இந்தக் கருவிப்பெட்டி இயங்கவே முடியாது'
    CompareWebLogsName                   = 'வெப் பயன்பாட்டின் சொந்த லாக்குகள்'
    CompareWebLogsDetail                 = '{0}, 39 MB. கருவிப்பெட்டி தொகுப்பில் முழுவதும் இல்லை'
    CompareDataLayerName                 = 'மைய தரவு அடுக்கு'
    CompareDataLayerDetail               = '{0} கோப்புகள். தொலைநிலை தொகுப்பில் 10, உள்ளூரில் 0'
    CompareSyncName                      = 'சுமார் முப்பது ஒத்திசைவு துணைஅமைப்புகள்'
    CompareSyncDetail                    = 'செய்திகள், நாட்காட்டி, நபர்கள், இருப்பு, கொள்கைகள், கோப்புகள், அழைப்பு வரலாறு. 0க்கு எதிராக 31 கோப்புகள். காணாமல் போன உரையாடல் அல்லது பழைய நாட்காட்டி பதில் பெறும் இடம்'
    CompareStorageName                   = 'உள்ளூர் சேமிப்பக பயன்பாடு'
    CompareEveryAccountName              = 'ஒவ்வொரு உள்நுழைந்த கணக்கும்'
    CompareEveryAccountDetail            = 'வடிவமைப்பிலேயே. மூடலுக்கான பலம், மேலும் தனியுரிமை வாயில் இருப்பதற்கான வெளிப்பாடு'
    CompareFleetName                     = 'படை அளவு மற்றும் 28-நாள் போக்குகள்'
    CompareFleetDetail                   = 'ஆவணப்படுத்தப்பட்டது. உள்ளூர் தொகுப்பு, சூழல் அதே சிக்கலை பகிர்கிறதா என்பதை ஒருபோதும் சொல்ல முடியாது'
    CompareMacName                       = '{0}, மற்றும் 30-நாள் கிளவுட் வைத்திருப்பு'
    CompareDocumented                    = 'ஆவணப்படுத்தப்பட்டது'
    CompareShellName                     = 'டெஸ்க்டாப் ஷெல் மற்றும் {0} லாக்குகள்'
    CompareShellDetail                   = 'ஆவணப்படுத்தப்பட்டது ஆனால் பிடிக்கப்பட்ட ஆர்டிஃபாக்டில் காணப்படவில்லை. சரிபார்க்கப்படவில்லை'
}
