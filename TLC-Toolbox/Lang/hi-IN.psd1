@{
    # Hindi (India). Machine translated, NOT reviewed by a native speaker - see the header
    # of Tlc.Localization.psm1. Safe for what it covers: field labels, buttons and hints.
    # Nothing that reaches a bundle is translated.
    #
    # Hindi was chosen as the first Indian language because it has the widest reach. India
    # has twenty-two scheduled languages and this framework takes more: adding one is a new
    # file here plus its line in Tlc.psd1's FileList, and the test gate then requires every key.
    #
    # Product names stay in Latin script on purpose. "Teams", "Teams Rooms", "PowerShell"
    # and "FQDN" are what the controls and documentation actually say, so transliterating
    # them would send an engineer looking for something that does not exist under that name.
    #
    # THIS FILE MUST BE SAVED AS UTF-8 WITH A BOM. Measured on 2026-09-15: without one,
    # Import-PowerShellDataFile on Windows PowerShell 5.1 reads the bytes as the ANSI
    # codepage and Devanagari is destroyed outright, while PowerShell 7 reads it correctly
    # either way. Tlc.Localization.Tests.ps1 asserts the BOM for that reason, because the
    # general rule elsewhere in this toolbox is the opposite.

    AdminCenterLink          = 'व्यवस्थापन केंद्र से लॉग कैसे एकत्र करें'
    ComparisonLink           = 'सुविधाओं की तुलना'
    ComparisonLinkTip        = 'यह टूलबॉक्स क्या एकत्र करता है जो दूरस्थ संग्रह नहीं करता, और इसके विपरीत'
    SettingsTip              = 'सेटिंग्स'

    WhatHappenedHeading      = 'क्या हुआ'
    ScenarioLabel            = 'परिदृश्य'
    ScenarioHint             = 'परिदृश्य चुनें। आपके चयन से तय होता है कि कौन से लॉग और निदान संबंधी डेटा एकत्र किए जाएंगे।'
    CaseNumberLabel          = 'केस नंबर'
    AffectedUserLabel        = 'प्रभावित उपयोगकर्ता'
    ConsentLabel             = 'सहमति देने वाला'
    ConsentHint              = 'पैकेज बनाने से पहले आवश्यक है।'
    ForgetButton             = 'भूल जाएं'
    ForgetTip                = 'इस मशीन से बॉक्स में दिया गया केस नंबर हटाएं। बॉक्स खाली होने पर, सभी सहेजे गए केस हटाने का विकल्प देता है।'

    PathChooserHeading       = 'क्या करना है'
    PathChooserCaption       = 'कार्य चुनें।'
    GatherPathButton         = 'मौजूदा लॉग पैकेज करें'
    GatherPathTip            = 'Teams ने जो लॉग पहले ही लिख दिए हैं उन्हें लेता है, उस समस्या के लिए जो हो चुकी है। कुछ सेकंड से कुछ मिनट। साफ़ करने के लिए फिर से क्लिक करें।'
    LivePathButton           = 'लाइव ट्रेस चलाएं'
    LivePathTip              = 'जब आप समस्या दोहराते हैं तब यह मशीन सैंपल करता है। तब उपयोग करें जब आप समस्या को इच्छानुसार दोहरा सकें। साफ़ करने के लिए फिर से क्लिक करें।'
    PathUnavailable          = 'लाइव ट्रेस इसी मशीन को सैंपल करता है, और यह परिदृश्य किसी अन्य जगह के डिवाइस से जुड़ा है।'

    GatherHeading            = 'यह कब हुआ'
    ImpactTimeLabel          = 'घटना का समय'
    ImpactAtLabel            = 'बजे'
    WindowLabel              = 'अवधि'
    BeforeLabel              = 'पहले'
    AfterLabel               = 'बाद'
    UnitMinutes              = 'मिनट'
    UnitHours                = 'घंटे'
    TimeHint                 = 'चुनता है कि पहले से लिखे गए कौन से लॉग लिए जाएं। 24-घंटे की घड़ी; AM/PM भी स्वीकार्य है।'
    TimeHintUnreadable       = 'समय समझ नहीं आया - मध्यरात्रि का उपयोग हो रहा है। 14:30 या 2:30 PM आज़माएं।'

    LiveHeading              = 'लाइव ट्रेस'
    LiveCaption              = 'सत्र ही अवधि है: रिकॉर्डिंग तब शुरू होती है जब आप ट्रेस शुरू करें दबाते हैं और तब समाप्त होती है जब आप रोकें दबाते हैं। बीच में समस्या दोहराएं।'
    SampleEveryLabel         = 'सैंपल अंतराल'
    DeepCaptureBox           = 'पैकेट कैप्चर भी चलाएँ'
    ElevateButton            = 'TLC Toolbox को व्यवस्थापक के रूप में फिर से खोलें'

    OptionsHeading           = 'विकल्प'
    RoomsDeviceLabel         = 'Teams Rooms डिवाइस'
    RoomsDeviceHintOn        = 'डिवाइस का होस्ट नाम या FQDN।'
    RoomsDeviceHintLocal     = 'यह मशीन एक Teams Rooms डिवाइस है। इसी से एकत्र करने के लिए खाली छोड़ें।'
    RoomsDeviceHintOff       = 'केवल Teams Rooms परिदृश्य के लिए।'
    EndpointsLabel           = 'इनसे भी एकत्र करें'
    OutputFolderLabel        = 'आउटपुट फ़ोल्डर'
    SkipPromptedBox          = 'उपयोगकर्ता की आवश्यकता वाले चरण छोड़ें (सपोर्ट फ़ाइलों की प्रतीक्षा न करें)'
    ValidationOnlyBox        = 'केवल सत्यापन (योजना बनाएं, कुछ एकत्र न करें)'

    LiveMemoryContext = 'कुल RAM: {0} GB | उपलब्ध: {1} GB | {2}% उपयोग'
    LiveMemoryUnavailable = 'कुल / उपलब्ध RAM: मापा नहीं गया'
ScenarioGroupCommon = 'आम परिदृश्य - लाइव ट्रेस उपलब्ध'
ScenarioGroupLive = 'और परिदृश्य - लाइव ट्रेस उपलब्ध'
ScenarioGroupRemote = 'अन्य डिवाइस या पोर्टल - स्थानीय लाइव ट्रेस नहीं'
StopFlowHeading = 'संग्रह पूरा किया जा रहा है'
StopFlowFinished = 'संग्रह पूरा हुआ'
StopFlowReview = 'संग्रह समाप्त - अधूरे या विफल चरण जाँचें'
StopStepSampling = '1. नमूना रोकें'
StopStepLogs = '2. लॉग लें'
StopStepSupport = '3. सहायता फ़ाइलें'
StopStepFinalize = '4. रन पूरा करें'
StopStatusPending = 'लंबित'
StopStatusRunning = 'चल रहा'
StopStatusComplete = 'पूर्ण'
StopStatusSkipped = 'छोड़ा गया'
StopStatusWarning = 'जाँचें'
StopStatusFailed = 'विफल'
StopDetailAcknowledging = 'नमूना रोकने की पुष्टि की प्रतीक्षा।'
StopDetailSamplingStopped = 'नमूना लेना रुका; सहेजे नमूने सुरक्षित हैं।'
StopDetailDeep = 'वैकल्पिक पैकेट संग्रह रोका जा रहा है।'
StopDetailSummary = 'सहेजे नमूने पढ़कर सारांश बनाया जा रहा है।'
StopDetailInventory = 'Teams और डिवाइस सूची पढ़ी जा रही है।'
StopDetailClientLogs = 'क्लाइंट लॉग कॉपी और सत्र समयरेखा बनाई जा रही है।'
StopDetailClientState = 'Teams क्लाइंट स्थिति कॉपी हो रही है।'
StopDetailEvents = 'सत्र के Windows इवेंट लॉग पढ़े जा रहे हैं।'
StopDetailVdi = 'वर्चुअल डेस्कटॉप के तथ्य एकत्र हो रहे हैं।'
StopDetailNetwork = 'अंतिम नेटवर्क और रिले जाँच चल रही है।'
StopDetailBrowser = 'ब्राउज़र साक्ष्य एकत्र हो रहे हैं।'
StopDetailLogsFinished = 'अंतिम लॉग संग्रह समाप्त हुआ।'
StopDetailSupport = 'Teams सहायता फ़ाइलें एकत्र हो रही हैं।'
StopDetailSupportSkipped = 'सहायता फ़ाइल संग्रह छोड़ा गया।'
StopDetailSupportTimeout = 'समय सीमा से पहले नई सहायता फ़ाइल नहीं मिली।'
StopDetailSupportCopied = 'सहायता फ़ाइलें रन में कॉपी हो गईं।'
StopDetailSupportPartial = 'संग्रह अधूरा या बाधित; मूल फ़ाइलें जाँचें।'
StopDetailFinalizing = 'साक्ष्य विश्लेषण और रन फ़ाइल लेखन हो रहा है।'
StopDetailFinished = 'रन फ़ाइलें लिख दी गईं।'
StopLastUpdate = 'संग्राहक अपडेट {0}s पहले'
StopAwaitingUpdate = 'संग्राहक पुष्टि की प्रतीक्षा'
StopSupportFacts = '{0} बंडल मिले | {1} फ़ाइलें देखी गईं | {2} MB'
StopSupportArrival = 'नई फ़ाइल मिलने के लिए {0}s शेष'
StopSupportQuiet = '{0}/{1}s से अपरिवर्तित; नया लेखन जाँच फिर शुरू करेगा'
StopSupportMarkers = '{0} फ़ोल्डर में समापन फ़ाइल की प्रतीक्षा'
StopSupportCopied = '{0}/{1} बंडल कॉपी | {2} कॉपी विफल'
StopSupportLastWrite = 'अंतिम फ़ाइल लेखन {0}s पहले'
StopLiveProgress = 'समापन {0} | {1} नमूने सहेजे (नमूना लेना रुका)'
LiveMetricLoading = 'रीडिंग लोड हो रही हैं...'
LiveMemoryLoading = 'कुल / उपलब्ध RAM पढ़ी जा रही है...'
LiveMemoryPreview = 'पहले सहेजे नमूने से पहले का पूर्वावलोकन'
LiveMemoryReadFailed = 'RAM रीडिंग उपलब्ध नहीं: {0}'
WaitArming = 'ट्रेस की तैयारी ({0}s)। संग्राहक लोड हो रहे हैं; रिकॉर्डिंग शुरू नहीं हुई।'
WaitFirstSample = 'पहले सहेजे नमूने की प्रतीक्षा ({0}s)। अभी कोई नमूना पुष्ट नहीं।'
WaitNextSample = 'अगले सहेजे नमूने की प्रतीक्षा (पिछले से {0}s)। नया डेटा पुष्ट नहीं।'
WaitStopping = 'ट्रेस रोकी जा रही है ({0}s)। वर्तमान परीक्षण पूरा होने की प्रतीक्षा।'
WaitCollecting = 'लॉग संग्रह और साक्ष्य अंतिम रूप देना ({0}s)। रन अभी पूरा नहीं।'
WaitWorking = 'डायग्नोस्टिक लोड या चल रहे हैं ({0}s)। वर्तमान चरण ट्रांसक्रिप्ट में देखें।'
WaitPackaging = 'गोपनीयता जाँच और साक्ष्य पैकेज बनाना ({0}s)। परिणाम की प्रतीक्षा।'
WaitSupportGenerating = 'Teams सहायता फ़ाइलें बन रही हैं ({0}s)। Teams सामने आ सकता है।'
WaitSupportWaiting = 'Teams सहायता फ़ाइलों की प्रतीक्षा ({0}s)। अभी फ़ाइलें पुष्ट नहीं।'
WaitSupportSettling = 'सहायता फ़ाइलें मिलीं; लेखन पूरा होने की प्रतीक्षा ({0}s)।'
WaitSupportCopying = 'Teams सहायता फ़ाइलें रन में कॉपी हो रही हैं ({0}s)।'
WaitSupportAction = 'Teams सहायता फ़ाइलों के लिए कार्रवाई आवश्यक ({0}s)। नीचे के नियंत्रण उपयोग करें।'
WaitTip = 'एनीमेशन और समय विंडो के उत्तर देने को दर्शाते हैं, प्रतिशत पूरा होने को नहीं। सहेजे नमूने और फ़ाइल स्थितियाँ वास्तविक प्रगति पुष्ट करते हैं।'
    LiveRttContext = 'रिले विलंब का संकेत, कॉल गुणवत्ता नहीं'
    LiveRttPassLegend = 'हरा: <200 ms'
    LiveRttWarningLegend = 'पीला: 200-500 ms'
    LiveRttBlockedLegend = 'लाल: >500 ms'
    LiveMemoryPassLegend = 'हरा: >=10% या >=4 GB'
    LiveMemoryWarningLegend = 'पीला: कम उपलब्ध'
    LiveMemoryBlockedLegend = 'लाल: <1% या <500 MB'
    LiveMemoryNeutralLegend = 'बैंगनी: मापा नहीं'
    LiveThresholdSources = 'Microsoft स्रोत:'
    LiveRttThresholdTip = 'संकेतक सीमाएँ: 200 ms से कम हरा (Teams कॉल स्वास्थ्य का सामान्य मान), 200-500 ms पीला, 500 ms से अधिक लाल (CQD ऑडियो RTT मानदंड)। ये कृत्रिम STUN परीक्षणों के लिए हैं, वास्तविक मीडिया या CQD वर्गीकरण नहीं। हर अंतराल नई सहेजी गई रीडिंग का उपयोग करता है; रंग संकेत नवीनतम सीमा दिखाता है। RTT न होने पर धूसर।'
    LiveMemoryThresholdTip = 'रंग उपलब्ध सिस्टम भौतिक RAM दर्शाते हैं, Teams की MB सीमा नहीं। लाल: उपलब्ध RAM 1% से कम या 500 MB से कम। अन्यथा पीला: 10% से कम और 4 GB से कम। अन्यथा हरा। गंभीर स्थिति को प्राथमिकता; ठीक 10% सामान्य है। Windows का संकेतक मार्गदर्शन, Teams प्रदर्शन का निदान नहीं। कुल RAM उपयोग योग्य भौतिक क्षमता है, कमिट/पेज फ़ाइल नहीं। हर अंतराल नई सहेजी गई रीडिंग उपयोग करता है; बैंगनी का अर्थ RAM मापा नहीं गया।'
    CancelButton             = 'रोकें'
    CancelTip                = 'संग्रह अभी रोकें। अब तक जो एकत्र हुआ है वह सुरक्षित रहेगा; पैकेज अधूरा रहेगा।'
    PackageButton            = 'पैकेज करें'
    PackageTip               = 'गोपनीयता जांच चलाता है और एकत्र किए गए साक्ष्य को सौंपने के लिए एक पैकेज में संकुचित करता है। सहमति दर्ज होने तक अस्वीकृत रहता है।'
    OpenButton               = 'रन फ़ोल्डर खोलें'
    OpenTip                  = 'इस रन का फ़ोल्डर File Explorer में खोलता है, जहां एकत्र की गई फ़ाइलें और टूल का अपना लॉग है।'
    ValidateButton           = 'सत्यापित करें'
    ValidateTip              = 'रन की योजना बनाता है और बताता है कि क्या उसे रोक सकता है। कुछ भी बदलता या एकत्र नहीं करता।'
    CollectButton            = 'एकत्र करें'
    CollectTip               = 'ऊपर चुना गया काम चलाएं।'
    StartTraceButton         = 'ट्रेस शुरू करें'

    SettingsHeading          = 'सेटिंग्स'
    SettingsLanguageLabel    = 'भाषा'
    SettingsLanguageHint     = 'केवल विंडो बदलती है। एकत्र किए गए साक्ष्य, पैकेज और टूल लॉग अंग्रेज़ी में ही रहते हैं ताकि केस पढ़ने वाला उन्हें पढ़ सके।'
    SettingsTranslationNote  = 'अंग्रेज़ी के अलावा सभी भाषाएँ मशीनी अनुवाद हैं और किसी मूल वक्ता द्वारा समीक्षित नहीं हैं।'
    SettingsThemeLabel       = 'रूप'
    SettingsThemeHint        = 'अगली बार विंडो खुलने पर लागू होगा। रंग लोड होते समय तय हो जाते हैं, इसलिए अभी बदलने पर केवल कुछ हिस्सा ही दोबारा रंगेगा।'
    ThemeSystem              = 'सिस्टम सेटिंग का पालन करें'
    ThemeLight               = 'हल्का'
    ThemeDark                = 'गहरा'
    SettingsClose            = 'बंद करें'

    # The Start menu row. The entry is called TLC Toolbox in every language; Start menu and
    # taskbar are what Windows itself calls them. {0} in the Elsewhere hint is a folder path,
    # and in ShortcutFailed it is the system's own message, which ends the sentence.
    SettingsShortcutLabel    = 'शॉर्टकट'
    ShortcutAddButton        = 'स्टार्ट मेनू में जोड़ें'
    ShortcutRemoveButton     = 'स्टार्ट मेनू से निकालें'
    ShortcutHintNone         = 'TLC Toolbox को अपने आइकन के साथ स्टार्ट मेनू में जोड़ता है। वहाँ से इसे टास्कबार पर पिन किया जा सकता है।'
    ShortcutHintHere         = 'स्टार्ट मेनू प्रविष्टि TLC Toolbox की यह प्रति खोलती है।'
    ShortcutHintElsewhere    = 'स्टार्ट मेनू प्रविष्टि {0} में दूसरी प्रति खोलती है। इसे फिर से जोड़ने पर यह इसी प्रति की ओर संकेत करेगी।'
    ShortcutFailed           = 'स्टार्ट मेनू प्रविष्टि बदली नहीं जा सकी: {0}'

    # --- Dashboard ----------------------------------------------------------------
    # The captions, and the values the tiles draw. A value is translated as it is drawn, by
    # Get-TlcTileText recognising which of these phrases a metric wrote; the metric itself stays
    # English. {0} and {1} are the numbers exactly as the metric formatted them.
    TileClient               = 'क्लाइंट'
    TileLogs                 = 'डिस्क पर लॉग'
    TileRetention            = 'लॉग अवधि'
    TileActivity             = 'आखिरी लॉग लेखन'
    TileCrash                = 'क्रैश (24 घं.)'
    TileCoverage             = 'अवधि'
    TileNetwork              = 'नेटवर्क पथ'
    TileUpdate               = 'क्लाइंट अपडेट'
    TileSignIn               = 'साइन इन'
    TileChecking             = 'जांच हो रही है...'
    MetricMeasuring          = 'मापा जा रहा है...'
    MetricMeasuredAt         = 'मापा गया {0:HH:mm:ss}'
    TileNotFound             = 'नहीं मिला'
    TileOrphaned             = 'अनाथ'
    TileNoLogFolder          = 'लॉग फ़ोल्डर नहीं'
    TileNone                 = 'कोई नहीं'
    TileNoLogs               = 'लॉग नहीं'
    TileNever                = 'कभी नहीं'
    TileJustNow              = 'अभी'
    TileInFuture             = 'भविष्य में'
    TileEndsInFuture         = 'भविष्य में खत्म'
    TileCovered              = 'कवर'
    TileOlderThanLogs        = 'लॉग से पुराना'
    TileInLogGap             = 'लॉग अंतराल में'
    TilePartlyCovered        = 'आंशिक कवर'
    TileUnavailable          = 'अनुपलब्ध'
    TileInspected            = 'जाँचा गया'
    TileDirect               = 'सीधा'
    TileUnknown              = 'अज्ञात'
    TileToday                = 'आज'
    TileYesterday            = 'कल'
    TileNoneFound            = 'कुछ नहीं मिला'
    TileOnePerson            = '1 व्यक्ति'
    TileOneIdToDeclare       = '1 घोषित करने योग्य ID'
    TilePickAJob             = 'काम चुनें'
    TileLiveTrace            = 'लाइव ट्रेस'
    TileTunnelled            = 'टनल के ज़रिए'
    TileFilesSize            = '{0} फ़ाइलें, {1} MB'
    TileMinutesAgo           = '{0} मि. पहले'
    TileHoursAgo             = '{0} घं. पहले'
    TileDaysAgo              = '{0} दिन पहले'
    TileMinutes              = '{0} मि'
    TileHours                = '{0} घं'
    TileDays                 = '{0} दिन'
    TileCountInHours         = '{1} घं. में {0}'
    TilePeople               = '{0} लोग'
    TileIdsToDeclare         = '{0} घोषित करने योग्य ID'
    TileWithTenants          = '{0}, {1} टेनेंट'

    # --- Banners ------------------------------------------------------------------
    # Which console to use, and the advisories about this machine. {0} in the first two is a
    # scenario name or a platform name, which stay as written.
    ToolChoiceCollectHere    = 'यहीं एकत्र करें'
    ToolChoiceAdminCenter    = 'व्यवस्थापन केंद्र इसमें से अधिकांश कर सकता है'
    ToolChoiceNotARoute      = 'व्यवस्थापन केंद्र का दूरस्थ क्लाइंट लॉग संग्रह {0} के लिए मार्ग नहीं है। उसका पैकेज क्लाइंट के अपने लॉग हैं; इस परिदृश्य को ऐसे साक्ष्य चाहिए जो वह नहीं जुटाता।'
    ToolChoiceVirtualDesktop = 'व्यवस्थापन केंद्र का दूरस्थ क्लाइंट लॉग संग्रह केवल Windows (non-VDI) के लिए समर्थित दस्तावेज़ित है, और यह {0} है। अनुरोध इस क्लाइंट तक नहीं पहुँचेगा।'
    ToolChoiceClientBlocked  = 'व्यवस्थापन केंद्र को चेक इन कर संग्रह करने के लिए Teams क्लाइंट चलते हुए चाहिए। यह मशीन उसे वह नहीं दे सकती, इसलिए अनुरोध समाप्त होने तक अधूरा रहेगा।'
    ToolChoiceSignInBlocked  = 'व्यवस्थापन केंद्र की डिवाइस सूची साइन-इन क्लाइंट टेलीमेट्री से बनती है, इसलिए जो क्लाइंट साइन इन नहीं कर सकता वह शायद उसमें दिखे ही नहीं।'
    ToolChoiceRetention      = 'व्यवस्थापन केंद्र को 8 घंटे तक लग सकते हैं और उसमें समय-अवधि पैरामीटर नहीं है, इसलिए चलते समय वह डिस्क पर मौजूद सब कुछ एकत्र करता है। यह क्लाइंट अपने लॉग उससे तेज़ी से घुमा रहा है, इसलिए प्रतीक्षा में साक्ष्य बच नहीं सकते।'
    ToolChoiceAdminCenterDetail = 'यहाँ किसी स्थानीय संदर्भ की ज़रूरत नहीं है, और {0} के लिए दूरस्थ क्लाइंट लॉग मार्ग है। वहाँ संग्रह शांत रहता है और मशीन पर किसी की ज़रूरत नहीं होती, हालांकि इसमें 8 घंटे तक लगते हैं और केवल क्लाइंट लॉग लौटते हैं - इवेंट लॉग, नेटवर्क पथ और नीति के लिए अब भी यहाँ संग्रह चाहिए।'
    ToolChoiceFleetNote      = 'यह मशीन दूरस्थ संग्रह भी खुद चला सकती है - नीचे "इनसे भी एकत्र करें" देखें - इसमें घंटों के बजाय मिनट लगते हैं और पूरा साक्ष्य सेट लौटता है, हालांकि लक्ष्य के लिए WinRM और क्रेडेंशियल चाहिए, जो व्यवस्थापन केंद्र को नहीं चाहिए।'
    DismissRecommendationTip = 'यह सिफारिश हटाएँ'
    DismissAdvisoryTip       = 'यह सलाह हटाएँ'
    AdvisoryVdiHeading       = 'वर्चुअल डेस्कटॉप'
    AdvisoryVdiSomewhere     = 'एक वर्चुअल डेस्कटॉप'
    AdvisoryVdiMediaLogs     = 'Teams {0} में चल रहा है, इसलिए मीडिया लॉग इस सत्र में नहीं बल्कि भौतिक एंडपॉइंट पर लिखे जाते हैं - यहाँ संग्रह करने पर सत्र के skylib लॉग मिलते हैं और मीडिया स्टैक में से कुछ नहीं।'
    AdvisoryVdiLogCap        = 'VDI क्लाइंट पर लॉग आकार डिफ़ॉल्ट रूप से सीमित है; समस्या दोहराने से पहले Teams गोपनीयता सेटिंग्स में Extended Logging चालू करें।'
    AdvisoryVdiProfile       = 'यदि प्रोफ़ाइल non-persistent है, तो लॉग फ़ोल्डर वह है जिसे FSLogix साइन-आउट पर हटाता है, इसलिए उपयोगकर्ता के साइन ऑफ़ करने से पहले एकत्र करें।'
    AdvisoryVdiCommunity     = 'यह प्लेटफ़ॉर्म ऐसे विक्रेता संकेत से पहचाना गया जिसे Microsoft दस्तावेज़ित नहीं करता, इसलिए इस पर निर्भर होने से पहले पुष्टि करें।'
    AdvisoryAudioHeading     = 'ऑडियो एंडपॉइंट'
    AdvisoryAudioNone        = 'कोई रिकॉर्डिंग उपकरण नहीं मिला।'
    AdvisoryAudioUnhealthy   = '{0} उपकरणों की जाँच आवश्यक है।'
    AdvisoryAudioOpen        = 'विवरण देखें'
    PathSelected             = 'चयनित'
    SkipSupportButton        = 'सहायता फ़ाइलें छोड़ें'
    GenerateSupportButton    = 'सहायता फ़ाइलें बनाएँ'
    SupportAutoGenerating    = 'Teams सहायता फ़ाइलें अपने आप बनाई जा रही हैं। Teams सामने आ सकता है। प्रक्रिया विफल होने पर ही शॉर्टकट आवश्यक है। फ़ाइलों में सभी साइन-इन खाते हो सकते हैं; यह चरण छोड़ा जा सकता है।'
    SupportAutoWaiting       = 'शॉर्टकट भेज दिया गया। Teams की फ़ाइलों की प्रतीक्षा है; कोई कार्रवाई आवश्यक नहीं। चरण छोड़ सकते हैं।'
    SupportAutoSettling      = 'फ़ाइलें मिलीं। संग्रह से पहले Teams द्वारा सभी फ़ाइलें लिखने के पूरा होने की प्रतीक्षा है।'
    SupportAutoCopying       = 'पूरी Teams सहायता फ़ाइलें इस संग्रह में कॉपी की जा रही हैं।'
    LiveRttTip               = 'STUN RTT, Teams रिले तक कृत्रिम UDP अनुरोध पहुँचने और जवाब लौटने का औसत समय है, मिलीसेकंड में। कम मान का अर्थ तेज़ जवाब है। यह रिले का संपर्क जाँचता है, कॉल की वास्तविक ऑडियो/वीडियो गुणवत्ता या सटीक नेटवर्क मार्ग नहीं।'
    LiveMemoryTip            = 'Teams / WebView2, Teams और उसके WebView2 प्रक्रियाओं की कार्यशील मेमोरी का योग है, MB में। WebView2, Teams का इंटरफ़ेस दिखाता है। यह मेमोरी उपयोग की प्रवृत्ति है, नेटवर्क गुणवत्ता नहीं; साझा मेमोरी एक से अधिक बार गिनी जा सकती है।'
    ShowLiveGraphBox         = 'लाइव ग्राफ़ दिखाएँ'
    LiveChartAnimationHint   = 'रेखाएँ एक नमूना अंतराल में बदलती हैं (अधिकतम 10 सेकंड); मान नवीनतम सहेजी गई रीडिंग हैं। यह दृश्य बदलाव प्रमाण नहीं बदलता।'
    LiveChartCaption         = 'लाइव संग्रह: नवीनतम 120 नमूने। STUN परीक्षण कॉल की मीडिया गुणवत्ता नहीं हैं। अलग पैमाने; खाली स्थान का अर्थ रीडिंग नहीं है।'
    SupportActionText        = 'कार्रवाई आवश्यक: नीचे फ़ाइलें बनाएँ (Teams सामने आएगा) या Teams में कंट्रोल, ऑल्ट, शिफ्ट और 1 दबाएँ। डाउनलोड सूचना हटने तक प्रतीक्षा करें। फ़ाइलों में सभी साइन-इन खातों की जानकारी हो सकती है। संग्रह नहीं करना हो तो छोड़ दें।'
    LiveProgressText         = 'समय {0} | {1} नमूने सहेजे | अंतिम नमूना {2} सेकंड पहले'
    AdvisoryAudioType        = 'Windows उपकरण का प्रकार'
    AdvisoryAudioDisplayNote = 'डिस्प्ले ऑडियो (HDMI / DisplayPort) डिस्प्ले कनेक्शन का आउटपुट है। इससे मॉनिटर में स्पीकर होने, स्पीकर जुड़े होने या Teams द्वारा उस आउटपुट के उपयोग की पुष्टि नहीं होती। प्रकार Windows के मेटाडेटा से आता है, नाम के अनुमान से नहीं।'
    AdvisoryAudioAdvice      = "Windows ने ऊपर दी गई स्थितियाँ बताई हैं। अज्ञात स्थिति से उपकरण की खराबी या कॉल में उसके उपयोग की पुष्टि नहीं होती। ऑडियो की समस्या नेटवर्क की समस्या जैसी लग सकती है।`n`nअगले चरण`n1. Teams में उपयोग किए जा रहे माइक्रोफ़ोन और स्पीकर की जाँच करें।`n2. Windows की ध्वनि सेटिंग में पुष्टि करें कि ये जुड़े और सक्षम हैं।`n3. कॉल की गुणवत्ता का कारण नेटवर्क मानने से पहले इन उपकरणों को परखें।"
    AdvisoryPowerHeading     = 'पावर स्थिति'
    AdvisoryPowerScheme      = 'सक्रिय पावर स्कीम {0} है, जो CPU को थ्रॉटल करती है।'
    AdvisoryPowerBattery     = 'मशीन मुख्य बिजली के बजाय बैटरी पर चल रही है।'
    AdvisoryPowerBatteryCharge = 'मशीन मुख्य बिजली के बजाय {0}% बैटरी पर चल रही है।'
    AdvisoryPowerVideo       = 'वीडियो एन्कोडिंग किसी और चीज़ से पहले खराब होती है, इसलिए इस स्थिति में मापी गई गुणवत्ता वह गुणवत्ता नहीं है जिस तक यह मशीन पहुँच सकती है।'
    AdvisoryCacheHeading     = 'Teams कैश आकार'
    AdvisoryCacheSize        = 'Teams कैश {0} GB है।'
    AdvisoryCacheLargest     = 'सबसे बड़ा फ़ोल्डर {0} है।'
    AdvisoryCacheAdvice      = 'इसे साफ़ करना धीमे स्टार्ट और साइन-इन समस्याओं के लिए एक मानक शुरुआती कदम है, इसलिए गहरे विश्लेषण से पहले इसे अलग करना उपयोगी है। कोई प्रकाशित आकार सीमा नहीं है और बड़ा कैश अपने आप में दोष नहीं है - यह जाँचने की चीज़ है, कारण नहीं।'

    # --- Form hints ---------------------------------------------------------------
    LaneCounts               = 'स्वचालित: {0}   उपयोगकर्ता: {1}   मैनुअल: {2}'
    CaseHintBlank            = 'खाली होने पर रन संदर्भ उपयोग होता है।'
    CaseHintRemembered       = '{0} इस मशीन पर याद रखा गया है।'
    CaseHintForgot           = '{0} भुला दिया गया।'
    CaseHintCleared          = 'इतिहास साफ़ किया गया।'
    ForgetAllPrompt          = 'इस मशीन पर याद रखे गए सभी {0} केस नंबर भूलें?'
    ConsentMeTip             = 'यदि आप, साइन-इन खाता, इस संग्रह को अधिकृत करते हैं तो टिक करें। पैकेज बनाने से पहले आवश्यक है। आपके लिए कभी टिक नहीं किया जाता और सत्रों के बीच कभी सहेजा नहीं जाता।'
    ConsentBoxTip            = 'जब यह साइन-इन खाता न हो, तो इस मशीन से इस एंगेजमेंट के लिए संग्रह किसने अधिकृत किया। पैकेज बनने से पहले आवश्यक है। सत्रों के बीच कभी सहेजा नहीं जाता।'
    ConsentPlaceholder       = 'इस संग्रह को अधिकृत करने वाले का नाम और भूमिका'
    ConsentPlaceholderOther  = 'या कोई और: नाम और भूमिका'
    ConsentNotRequired       = 'इस कॉन्फ़िगरेशन में आवश्यक नहीं।'
    ConsentConfigured        = 'कॉन्फ़िगर किया गया: {0}'
    ImpactWindowTip          = 'संग्रह डिस्क पर पहले से मौजूद लॉग पढ़ता है। यह चुनता है कि उनमें से कौन से लेने हैं - यह किसी चीज़ के होने की प्रतीक्षा नहीं करता, इसलिए अभी से आगे तक जाने वाली अवधि कुछ अतिरिक्त नहीं जुटाती। जिस दोष को आप अभी भी दोहरा सकते हैं उसे कैप्चर करने के लिए, पहले उसे दोहराएँ और फिर एकत्र करें।'
    SampleIntervalTip        = 'समस्या दोहराते समय मशीन को कितनी बार सैंपल किया जाता है।'
    SampleSeconds            = '{0} सेकंड'
    CaptureIntervalHint      = '3 s से कम अंतराल नहीं निभाया जा सकता: एक सैंपल में लगभग 2.2 s लगते हैं।'
    DeepCaptureCount         = 'इस मशीन पर गहरे कैप्चर - {1} में से {0} उपलब्ध'
    DeepCaptureManualCaption = 'टूलबॉक्स ने शुरू नहीं किया - कमांड Capture.json में हैं:'
    DeepOptionPacketCapture  = 'पैकेट कैप्चर'
    DeepOptionNetshTrace     = 'स्टैक संदर्भ वाला नेटवर्क ट्रेस'
    DeepOptionEtwSession     = 'ETW प्रदाता सत्र'
    DeepReasonNotAdmin       = 'उपलब्ध नहीं, क्योंकि TLC Toolbox व्यवस्थापक के रूप में नहीं चल रहा है।'
    DeepReasonNoTool         = 'उपलब्ध नहीं, क्योंकि इस मशीन पर {0} नहीं मिला।'
    DeepReasonNoToolNotAdmin = 'उपलब्ध नहीं, क्योंकि इस मशीन पर {0} नहीं मिला, और TLC Toolbox व्यवस्थापक के रूप में नहीं चल रहा है।'
    DeepReasonNoPacketTool   = 'उपलब्ध नहीं, क्योंकि इस मशीन पर न pktmon.exe मिला और न netsh.exe।'
    DeepReasonNoPacketToolNotAdmin = 'उपलब्ध नहीं, क्योंकि इस मशीन पर न pktmon.exe मिला और न netsh.exe, और TLC Toolbox व्यवस्थापक के रूप में नहीं चल रहा है।'
    ElevateTip               = 'यह विंडो बंद करता है और TLC Toolbox को फिर से व्यवस्थापक अधिकारों के साथ खोलता है, ताकि गहरे कैप्चर चल सकें। आपका कंप्यूटर पुनरारंभ नहीं होता। Windows आपसे पुष्टि करने को कहेगा, और फ़ॉर्म में पहले से टाइप की कोई चीज़ साथ नहीं जाएगी।'
    DeepCaptureTip           = 'केवल हेडर, आकार-सीमित, ट्रेस के साथ शुरू और उसी के साथ बंद। pktmon का उपयोग करता है, या जब pktmon का एकल सत्र पहले से पकड़ा हो - प्रबंधित मशीन पर Defender द्वारा - तब netsh trace ट्रेस का। मशीन-व्यापी, इसलिए इसे रिकॉर्ड किया जाता है और बाद में साफ़ किया जाता है।'
    OutputHintCreated        = 'मौजूद न हो तो बनाया जाता है।'
    OutputHintBlank          = 'खाली होने पर {0}'
    EndpointHintChecking     = 'जाँचा जा रहा है कि यह मशीन अन्य एंडपॉइंट तक पहुँच सकती है या नहीं...'
    EndpointHintReady        = 'उन मशीनों पर किसी के रहने की ज़रूरत नहीं। उसी रन में, एक ही पैकेज में एकत्र किया गया। कॉमा या पंक्ति से अलग करें।'

    # --- While a run goes ---------------------------------------------------------
    SummaryScenarioLabel     = 'परिदृश्य'
    SummaryCaseLabel         = 'केस'
    SummaryUserLabel         = 'उपयोगकर्ता'
    SummaryWindowLabel       = 'अवधि'
    SummaryNone              = '(कोई नहीं)'
    SummaryWindowLive        = 'लाइव कैप्चर  -  सैंपलिंग जब तक आप रोकें दबाएँ'
    SummaryWindowNone        = '(कोई अवधि नहीं)'
    SummaryWindowSpan        = '{0}  -{1} / +{2} मि'
    SummaryConsentPlaceholder = 'इस संग्रह से सहमत व्यक्ति का नाम'
    SummaryConsentPlaceholderOther = 'या कोई और'
    RecordButton             = 'दर्ज करें'
    RecordConsentTitle       = 'सहमति'
    RecordConsentPrompt      = 'अपने खाते पर टिक करें, या इस संग्रह से सहमत व्यक्ति का नाम लिखें, फिर दर्ज करें दबाएँ।'
    RunConsentMissing        = 'सहमति दर्ज नहीं की गई है। यह संग्रह चलेगा, और आप इसे बिना रोके नीचे दर्ज कर सकते हैं।'
    PackageConsentMissing    = 'सहमति दर्ज नहीं की गई है, इसलिए यहाँ चुने गए हर रन के लिए पैकेजिंग अस्वीकृत होगी। इसे बंद करें, फ़ॉर्म पर "सहमति देने वाला" के पास अपने खाते पर टिक करें या किसने अधिकृत किया वह लिखें, और फिर पैकेज करें दबाएँ।'
    DeepSummaryAll           = 'गहरे कैप्चर: सभी {0} उपलब्ध।'
    DeepSummaryNone          = 'गहरे कैप्चर: {0} में से कोई नहीं चल रहा। {1} सैंपलिंग सत्र अप्रभावित है।'
    DeepSummarySome          = 'गहरे कैप्चर: {1} में से {0} चल रहे। नहीं चल रहे: {2}. {3}'
    ProgressHeading          = 'प्रगति'
    PhaseArm                 = '1. तैयार करें'
    PhaseReproduce           = '2. दोहराएँ'
    PhaseCollect             = '3. एकत्र करें'
    PhaseDetailArm           = 'तैयार हो रहा है। अभी कुछ रिकॉर्ड नहीं हो रहा - समस्या पैदा करने से पहले अगले चरण की प्रतीक्षा करें।'
    PhaseDetailReproduce     = 'रिकॉर्डिंग चल रही है। समस्या पैदा करें, फिर रोकें दबाएँ।'
    PhaseDetailCollect       = 'रिकॉर्डिंग पूरी हुई। सैंपल और सारांश लिखे जा रहे हैं - फिर Teams आपसे अपनी सपोर्ट फ़ाइलें माँग सकता है, इसलिए नीचे का लॉग देखें।'
    RunStarting              = 'शुरू हो रहा है: मॉड्यूल लोड हो रहे हैं ({0} s)'
    RunRecordingOne          = 'रिकॉर्डिंग - {0:mm\:ss}, {1} सैंपल। पूरा होने पर रोकें दबाएँ।'
    RunRecordingMany         = 'रिकॉर्डिंग - {0:mm\:ss}, {1} सैंपल। पूरा होने पर रोकें दबाएँ।'
    RunStopping              = 'रुक रहा है...'
    RunSamplingStopped       = 'सैंपलिंग रुक गई। सत्र के दौरान लिखे गए लॉग एकत्र किए जा रहे हैं...'
    RunStoppingBeforeClose   = 'बंद करने से पहले ट्रेस रोका जा रहा है...'
    RunFailedToStart         = 'शुरू करने में विफल।'
    RunStopped               = 'रुक गया।'
    RunBlocked               = 'अवरुद्ध - ऊपर का ट्रांसक्रिप्ट कारण बताता है।'
    RunExitCode              = 'निकास कोड {0} के साथ समाप्त हुआ।'
    RunFinished              = 'समाप्त।'
    RunPackagedZipped        = '{0} रन पैकेज कर zip किए गए।'
    RunPackagedSomeRefused   = '{0} रन पैकेज कर zip किए गए; {1} सील नहीं हो सके।'
    RunNothingSealed         = 'कोई रन सील नहीं हो सका, इसलिए कुछ भी zip नहीं हुआ।'
    RunProgressFailed        = 'प्रगति रिपोर्टिंग विफल: {0}'
    CloseDuringTraceState    = 'लाइव ट्रेस अभी भी रिकॉर्ड कर रहा है।'
    CloseDuringTraceEffect   = 'अभी बंद करने से यह रुक जाता है: सैंपल और सारांश रखे जाते हैं, लेकिन बाद में एकत्र होने वाले लॉग और Teams की सपोर्ट फ़ाइलें छोड़ी जाती हैं।'
    CloseDuringTraceAsk      = 'ट्रेस रोककर बंद करें?'
    CloseDuringRunState      = 'एक रन अभी भी चल रहा है।'
    CloseDuringRunEffect     = 'यदि आप विंडो बंद करते हैं तो यह अपने आप चलता और समाप्त होता रहेगा, और इसका रन फ़ोल्डर दर्ज करेगा कि यह कैसे समाप्त हुआ, लेकिन आप उसे यहाँ नहीं देखेंगे। पैकेज होने की प्रतीक्षा कर रही रनों की कतार इसके बाद रुक जाती है।'
    CloseDuringRunAsk        = 'फिर भी बंद करें?'

    # --- Scenario names ---------------------------------------------------------
    # Shown in the scenario list and the summaries. The run, the command and the bundle record the
    # scenario's Id and its English name, so these change the window only. Each English entry is the
    # catalog's own name, which the gate holds them to; each must fit the scenario box, measured.
    ScenarioNameDesktopLaunchCrash       = 'Teams Desktop: क्लाइंट लॉन्च, क्रैश या प्रदर्शन समस्या'
    ScenarioNameDesktopSignIn            = 'Teams Desktop: साइन-इन या प्रमाणीकरण विफलता'
    ScenarioNameWebClient                = 'Teams Web: ब्राउज़र या वेब क्लाइंट समस्या'
    ScenarioNameCallQuality              = 'मीटिंग और कॉल: खराब गुणवत्ता'
    ScenarioNameMeetingJoin              = 'मीटिंग और कॉल: मीटिंग जॉइन/सेटअप विफलता'
    ScenarioNameFiles                    = 'Teams फ़ाइलें: अपलोड, खोलना, शेयर या पहुँच समस्या'
    ScenarioNameMobile                   = 'Teams Mobile: मोबाइल क्लाइंट समस्या'
    ScenarioNameRooms                    = 'Teams Rooms: डिवाइस समस्या'
    ScenarioNameVdi                      = 'VDI में Teams समस्या'
    ScenarioNameTenantService            = 'टेनेंट-व्यापी या सेवा उपलब्धता प्रभाव'
    ScenarioNameNetwork                  = 'नेटवर्क, फ़ायरवॉल, प्रॉक्सी या VPN समस्या'
    ScenarioNameRoomsAndroid             = 'Teams Rooms on Android: डिवाइस समस्या'
    ScenarioNameCviRoomSegment           = 'Cloud Video Interop: रूम सेगमेंट तुलना'

    # --- Tile hover text -------------------------------------------------------
    TileDetailPending                    = 'यह जाँच अभी पूरी नहीं हुई है।'

    # --- Tile detail windows ---------------------------------------------------
    DetailLogFolderLabel                 = 'लॉग फ़ोल्डर'
    DetailNoLogFolder                    = 'कोई लॉग फ़ोल्डर कॉन्फ़िगर नहीं है।'
    DetailOpenLogFolder                  = 'लॉग फ़ोल्डर खोलें'
    DetailLowDisk                        = 'खाली जगह इतनी कम है कि Teams लॉग लिखना बंद कर सकता है और संग्रह बीच में विफल हो सकता है।'
    FactFiles                            = 'फ़ाइलें'
    FactFilesMatching                    = '{1} से मेल खाती {0}'
    FactSize                             = 'आकार'
    FactOldest                           = 'सबसे पुराना'
    FactNewest                           = 'सबसे नया'
    FactFreeDisk                         = 'खाली डिस्क'
    FactFreeDiskValue                    = '{2} पर {1} GB में से {0} GB खाली'
    FactYes                              = 'हाँ'
    FactNo                               = 'नहीं'
    DetailActivityBody                   = 'सबसे नई लॉग फ़ाइल वही है जिसे यह पढ़ता है। घंटों से अनछुआ फ़ोल्डर मतलब Teams चल नहीं रहा, इसलिए अभी कैप्चर की गई क्लाइंट स्थिति वह क्लाइंट नहीं है जो विफल हुआ था।'
    DetailHeadingCrash                   = 'पिछले 24 घंटों में क्रैश'
    FactWebViewCrashes                   = 'WebView2 क्रैश'
    FactWebViewNotMeasurable             = 'मापने योग्य नहीं - इस प्रोफ़ाइल पर Crashpad रिपोर्ट फ़ोल्डर नहीं है'
    FactNoneRecorded                     = 'कुछ दर्ज नहीं'
    FactWebViewReports                   = '{0} रिपोर्ट, नवीनतम {1}'
    FactReportFolder                     = 'रिपोर्ट फ़ोल्डर'
    DetailCrashWebViewBody               = 'New Teams WebView2 में चलता है, और रेंडरर क्रैश - विंडो खाली होना या ऐप का खुद फिर लोड होना - भरोसेमंद ढंग से अनुप्रयोग लॉग तक नहीं पहुँचता। डंप जानबूझकर मशीन पर छोड़े जाते हैं: मिनिडंप में प्रक्रिया मेमोरी होती है, जो साइन-इन क्लाइंट के लिए टोकन और संदेश सामग्री का मतलब है।'
    CrashDetailNone                      = 'पिछले {0} घंटों में अनुप्रयोग लॉग में Teams क्रैश ईवेंट नहीं हैं।'
    CrashDetailUnreadable                = 'अनुप्रयोग लॉग पढ़ा नहीं जा सका: {0}'
    CrashDetailHeader                    = '{0}   {1}, ईवेंट {2}'
    CrashDetailApplication               = 'दोषी अनुप्रयोग: {0} {1}'
    CrashDetailModule                    = 'दोषी मॉड्यूल: {0} {1}'
    DetailHeadingClient                  = 'Teams क्लाइंट'
    DetailClientBody                     = 'पैकेज तथ्य साइन-इन उपयोगकर्ता के लिए Get-AppxPackage से आते हैं।'
    DetailClientNotRegistered            = 'MSTeams पैकेज इस उपयोगकर्ता के लिए पंजीकृत नहीं है।'
    DetailClientUnreadable               = 'पैकेज पढ़ा नहीं जा सका: {0}'
    FactVersion                          = 'संस्करण'
    FactStatus                           = 'स्थिति'
    FactSignature                        = 'हस्ताक्षर'
    FactInstallPath                      = 'इंस्टॉल पथ'
    FactPresentOnDisk                    = 'डिस्क पर मौजूद'
    FactAudioPlayback                    = 'ऑडियो प्लेबैक'
    FactAudioNoPlayback                  = 'कोई नहीं - यहाँ कुछ भी कॉल चला नहीं सकता था'
    FactAudioRecording                   = 'ऑडियो रिकॉर्डिंग'
    FactAudioNoRecording                 = 'कोई नहीं - यहाँ कुछ भी माइक्रोफ़ोन ले नहीं सकता था'
    FactAudioFaults                      = 'ऑडियो दोष'
    FactCacheSize                        = 'कैश आकार'
    FactLargestCacheFolder               = 'सबसे बड़ा कैश फ़ोल्डर'
    FactPowerScheme                      = 'पावर स्कीम'
    FactPowerSource                      = 'पावर स्रोत'
    FactBattery                          = 'बैटरी'
    FactBatteryAt                        = '{0}% पर बैटरी'
    FactMains                            = 'मुख्य बिजली'
    DetailRetentionBody                  = 'रिटेंशन सबसे पुराने अभी भी डिस्क पर मौजूद लॉग से मापा जाता है, नीति से नहीं। Teams अपने लॉग खुद घुमाता है, इसलिए संग्रह वास्तव में इतनी दूर तक पहुँच सकता है।'
    DetailRetentionRolling               = 'केवल रोलिंग क्लाइंट लॉग यह सीमा तय करते हैं। कलेक्टर autostarter लॉग जैसे विरल परिवार भी लेता है, जिसे Teams केवल स्टार्टअप पर लिखता है और बहुत अधिक समय तक रखता है - उन्हें गिनने से एक साल की पहुँच दिखेगी जबकि साक्ष्य खुद यहीं रुकता है।'
    FactMeasuredFrom                     = 'इससे मापा गया'
    FactMeasuredFromValue                = '{1} के {0} रोलिंग क्लाइंट लॉग एकत्र'
    DetailHeadingCoverage                = 'चुनी गई अवधि'
    DetailCoverageBodyPick               = 'पहले "क्या करना है" के तहत काम चुनें। यह टाइल केवल तब उत्तर देती है जब आप मौजूदा लॉग पैकेज कर रहे हों, क्योंकि यह आपके मांगे गए समय को डिस्क पर अभी भी मौजूद लॉग से मिलाती है।'
    DetailCoverageBodyLive               = 'लाइव ट्रेस शुरू करते ही रिकॉर्ड करता है, इसलिए रखे गए लॉग से मिलाने के लिए कोई अवधि नहीं होती। जिन समयों को उसने कवर किया उन्हें चलते समय मापा जाता है और Capture.json में लिखा जाता है।'
    DetailCoverageBodyGather             = 'यह एकमात्र टाइल है जो आपके टाइप करते ही फिर मूल्यांकन करती है। बाकी हर टाइल हरी हो सकती है जबकि आपकी टाइप की अवधि रखे गए लॉग से बाहर हो।'
    FactBefore                           = 'पहले'
    FactAfter                            = 'बाद'
    FactMinutes                          = '{0} मिनट'
    DetailNetworkBody                    = 'सेवाओं से पता लगाया गया, मार्ग या एडाप्टर से नहीं: SASE क्लाइंट कोई VPN कनेक्शन ऑब्जेक्ट और कोई दिखने वाला एडाप्टर नहीं बनाता।'
    DetailNetworkUnreadableBody          = 'नेटवर्क पथ पढ़ा नहीं जा सका: {0}'
    DetailDnsResolves                    = '{0}, {2} हॉप के ऊपर {1} पर हल होता है'
    FactPath                             = 'पथ'
    FactTlsChain                         = 'TLS शृंखला'
    FactTlsNoHandshake                   = '{0} से हैंडशेक पूरा नहीं हुआ, इसलिए इंटरसेप्शन को सिद्ध या खारिज नहीं किया जा सकता'
    FactTlsPublicRoot                    = 'सार्वजनिक रूट ({0}) पर समाप्त'
    FactTlsNotPublic                     = '''{0}'' पर समाप्त, जो सार्वजनिक रूट नहीं है - ब्रेक-एंड-इंस्पेक्ट ऐसा दिखता है'
    FactTlsProtocol                      = 'TLS प्रोटोकॉल'
    FactTunnelState                      = '{0}, चल रहा: {1}'
    FactWifi                             = 'वाई-फ़ाई'
    FactWifiNone                         = '802.11 एडाप्टर नहीं है, इसलिए वाई-फ़ाई कारक नहीं है'
    FactWifiDisconnected                 = 'एडाप्टर मौजूद है लेकिन जुड़ा नहीं है - मीडिया किसी और रास्ते से गया'
    FactWifiSignal                       = '{0}% सिग्नल'
    FactWifiReceive                      = '{0} Mbps प्राप्त'
    FactWifiNoDetail                     = 'जुड़ा है, रेडियो विवरण पढ़ने योग्य नहीं'
    DetailUpdateBody                     = 'लॉन्चर लॉग से निकाला गया, जो चल रहा बिल्ड और पिछले सत्र में चले बिल्ड को दर्ज करते हैं। जहाँ वे अलग हों, वह अपडेट है।'
    DetailUpdateHistory                  = 'अपडेट इतिहास, सबसे पुराना पहले:'
    DetailUpdateRetention                = 'यहाँ केवल लॉन्चर लॉग की अपनी रिटेंशन के भीतर के अपडेट दिखते हैं, इसलिए पुराना इतिहास न होना यह प्रमाण नहीं है कि कोई नहीं हुआ।'
    DetailUpdateNoChange                 = 'डिस्क पर लॉन्चर लॉग में कोई संस्करण बदलाव दर्ज नहीं है।'
    DetailUpdateNotLoaded                = 'अपडेट इतिहास लोड होना पूरा नहीं हुआ है, या लॉग फ़ोल्डर पढ़ा नहीं जा सका।'
    FactCurrentVersion                   = 'मौजूदा संस्करण'
    FactBuildStaged                      = 'स्टेज किया गया बिल्ड'
    FactLauncherLogs                     = 'लॉन्चर लॉग'
    FactScanned                          = '{0} स्कैन किए गए'
    DetailHeadingSignIn                  = 'साइन-इन खाते'
    FactIdentity                         = 'पहचान {0}'
    FactIdentityValue                    = '{0} - ID {1} - {2}'
    FactIdentityExpected                 = 'यहाँ अपेक्षित'
    FactIdentityUndeclared               = 'आपकी सूची में नहीं - नीचे देखें'
    FactTenantUnresolved                 = 'अनसुलझा'
    FactStateFolder                      = 'स्थिति फ़ोल्डर'
    FactAccountsExpected                 = 'अपेक्षित खाते'
    FactRefuseUnexpected                 = 'अनपेक्षित हों तो अस्वीकार'
    DetailSignInDeclared                 = '"घोषित" का अर्थ क्या है। यह टूलबॉक्स आपको बंडल देने से पहले, इस मशीन पर मिले हर खाते को उन खातों की छोटी सूची से मिलाता है जिन्हें आपने अपेक्षित बताया है। उस सूची में मौजूद खाता "घोषित" है। जो नहीं है वह बंडल पैकेज होने से रोकता है।'
    DetailSignInWhy                      = 'यह जाँच इसलिए है क्योंकि सपोर्ट बंडल आपके हाथों से बाहर जाता है। New Teams इस मशीन में साइन इन हर खाते के लिए निदान लिखता है, इसलिए साझा या बहु-टेनेंट मशीन पर संग्रह किसी ऐसे व्यक्ति को भी समेट सकता है जिसका केस से कोई संबंध नहीं है। अंदाज़ा लगाने के बजाय, टूलबॉक्स मना करता है और आपसे पुष्टि करने को कहता है कि यहाँ कौन होना चाहिए।'
    DetailSignInNothingSent              = 'इस जाँच से कहीं कुछ नहीं भेजा जाता, और खाता घोषित करने से Teams या आपका साइन-इन नहीं बदलता। यह केवल स्थानीय फ़ाइल में दर्ज करता है कि आप इस खाते के दिखने की अपेक्षा रखते हैं।'
    DetailSignInHowHeading               = 'उन्हें कैसे घोषित करें'
    DetailSignInPress                    = 'इस विंडो के नीचे "{0}" दबाएँ। यह आपके लिए ids लिखता है, किसी मौजूदा फ़ाइल की तारीख वाली बैकअप प्रति रखता है, और कुछ और नहीं बदलता।'
    DetailSignInByHand                   = 'या हाथ से करें:'
    DetailSignInStep1                    = '1. नीचे दी गई फ़ाइल को नोटपैड में खोलें। यदि यह अभी मौजूद नहीं है, तो उसे बनाएँ।'
    DetailSignInStep2                    = '2. ऊपर के हर खाते की पूरी ऑब्जेक्ट ID Privacy.KnownAccountIds में इस आकार में जोड़ें:'
    DetailSignInStep3                    = '3. टूलबॉक्स फिर खोलें। यह टाइल हरी हो जाती है।'
    DetailSignInShortIds                 = 'ऊपर की ids स्क्रीन के लिए छोटी की गई हैं। पूरी मान app_settings.json में, ऊपर सूचीबद्ध स्थिति फ़ोल्डर में, "active_users" के तहत हैं।'
    DetailSignInOptOut                   = 'यदि आप सूची बनाए रखना नहीं चाहते, तो उसी फ़ाइल में Privacy.BlockOnUnknownAccount को false पर सेट करें। तब टूलबॉक्स अपरिचित खातों को पैकेजिंग से मना करने के बजाय रिपोर्ट करेगा - यह सोचकर लेने वाला विकल्प है, डिफ़ॉल्ट की तरह बहकर नहीं।'
    DetailSignInAboutHeading             = 'ऊपर दिखे विवरण के बारे में'
    DetailSignInDomain                   = 'हर पहचान को उसके खाते के डोमेन से नाम दिया जाता है, क्योंकि वही किसी डायरेक्टरी को व्यक्ति के लिए पहचानता है। उसके पास टेनेंट GUID छोटा किया गया है और केवल दो टेनेंट को अलग बताने के लिए है जब वे डोमेन साझा करते हैं। खाते का नाम खुद कभी नहीं दिखाया जाता, क्योंकि यह विंडो ऐसी मशीन पर खुलती है जिसे कोई साझा कर रहा हो सकता है।'
    DetailSignInSource                   = 'खाते app_settings.json -> active_users से आते हैं, जो वही स्रोत है जिसे गोपनीयता गेट रन के बाद पढ़ता है, इसलिए जो आप यहाँ देखते हैं वही गेट परखा जाएगा।'
    DetailSignInTwoTenants               = 'एक व्यक्ति का दो टेनेंट में साइन इन होना दो प्रविष्टियाँ बनाता है; यह सामान्य है और किसी गड़बड़ी का संकेत नहीं है।'
    DetailSignInGreen                    = 'हरा मतलब यह खाता जाँच पास होगा। यह वादा नहीं है कि पैकेजिंग सफल होगी: सहमति और बेयरर-टोकन स्कैन उस साक्ष्य के विरुद्ध जाँचे जाते हैं जो अभी मौजूद नहीं है।'
    DeclareButton                        = 'ये खाते घोषित करें'
    DeclareTitle                         = 'खाते घोषित करें'
    DeclareNoIds                         = 'app_settings.json से कोई साइन-इन खाता ID पढ़ी नहीं जा सकी, इसलिए कुछ नहीं लिखा गया।'
    DeclareDone                          = '{0} खाता ID यहाँ घोषित की गईं:'
    DeclareBackup                        = 'पिछली फ़ाइल यहाँ कॉपी की गई:'
    DeclareReopen                        = '"{0}" टाइल को हरा करने के लिए टूलबॉक्स फिर खोलें।'
    DeclareNothing                       = 'जोड़ने के लिए कुछ नहीं - हर साइन-इन खाता पहले से यहाँ घोषित है:'
    DeclareFailed                        = 'खाते घोषित नहीं किए जा सके:'

    # --- Problems with what was filled in ---------------------------------------
    # Worded for the window. The command line prints its own English, which names switches rather than controls.
    RunCannotStart                       = 'शुरू नहीं हो सकता:'
    ProblemCaseNumber                    = 'यह टूलबॉक्स केस नंबर आवश्यक करने के लिए सेट है। संग्रह करने के लिए एक दर्ज करें, या "{0}" पर टिक करें।'
    ProblemScenarioMissing               = 'शुरू करने से पहले "{0}" के तहत कोई परिदृश्य चुनें।'
    ProblemScenarioUnknown               = '"{0}" ऐसा परिदृश्य नहीं है जिसे यह टूलबॉक्स जानता है। सूची से एक चुनें।'

    # --- Run transcript ----------------------------------------------------------
    TranscriptRunning                    = 'चल रहा है:'
    TranscriptWarning                    = 'चेतावनी:'
    RunCoverageWarning                   = 'अवधि कवरेज: {0}. {1}'

    # --- Tile explanations -------------------------------------------------------
    # The hover text and the summary line of each detail window. The metric functions write each
    # sentence with New-TlcMetricText, naming its key and its English; the gate holds every English
    # entry here to that literal, word for word, so the window and the logs say the same thing.
    DetailCoveragePickAJob               = 'यह मापता है कि डिस्क पर अभी भी मौजूद लॉग आपकी मांगी अवधि को कवर करते हैं या नहीं, जो केवल मौजूदा लॉग पैकेज करते समय लागू होता है। "क्या करना है" के तहत काम चुनें और यह उत्तर देगा।'
    DetailCoverageLive                   = 'लाइव ट्रेस उसे शुरू करने के क्षण से लेकर रोकें दबाने तक रिकॉर्ड करता है, इसलिए रखे गए लॉग की कवरेज लागू नहीं होती। यदि दोष पहले ही हो चुका है तो इसके बजाय मौजूदा लॉग पैकेज करें।'
    DetailLogsUninspected                = 'लॉग फ़ोल्डर का निरीक्षण नहीं हो सका, इसलिए ये शून्य नहीं बल्कि अज्ञात हैं। {0}'
    DetailCheckNoResult                  = 'पृष्ठभूमि जाँच ने कोई परिणाम नहीं लौटाया।'
    DetailCheckFailed                    = 'पृष्ठभूमि जाँच विफल हुआ: {0}'
    DetailCoverageFailed                 = 'कवरेज निकाली नहीं जा सकी: {0}'
    NetworkPathVpn                       = 'VPN: {0}'
    NetworkPathVpnAdapter                = 'VPN एडाप्टर: {0}'
    NetworkPathInstalled                 = '{0} (इंस्टॉल है, चल नहीं रहा)'
    NetworkPathDirect                    = 'सीधा'
    DetailClientNotFound                 = 'MSTeams पैकेज इस उपयोगकर्ता के लिए पंजीकृत नहीं है, इसलिए डेस्कटॉप संग्रह कुछ नहीं जुटाएगा। प्रभावित उपयोगकर्ता सत्र में चलाएँ।'
    DetailClientBadStatus                = 'MSTeams {0} पंजीकृत है लेकिन स्थिति ''{1}'' बताता है, इसलिए Windows उसे सक्रियण पर रोक देगा। इसे Teams दोष मानने से पहले पैकेज मरम्मत या फिर पंजीकृत करें।'
    DetailClientOrphaned                 = 'पैकेज {0} के रूप में पंजीकृत है लेकिन उसका इंस्टॉल स्थान गायब है: {1}. पंजीकरण अनाथ है; इस उपयोगकर्ता के लिए पैकेज फिर पंजीकृत करें।'
    DetailClientOk                       = 'MSTeams {0} इस उपयोगकर्ता के लिए इंस्टॉल है, स्थिति ठीक बताता है, और उसका इंस्टॉल स्थान मौजूद है।'
    DetailLogsNoFolder                   = 'Teams लॉग फ़ोल्डर इस उपयोगकर्ता के लिए मौजूद नहीं है।'
    DetailLogsEmpty                      = 'Teams लॉग फ़ोल्डर मौजूद है लेकिन उसमें क्लाइंट लॉग नहीं हैं।'
    DetailLogsCount                      = '{0} क्लाइंट लॉग फ़ाइलें, कुल {1} MB।'
    DetailRetentionNone                  = 'कुछ भी रखा नहीं है।'
    DetailRetentionLive                  = 'मुख्य Teams लॉग {0} तक लगातार है।'
    DetailRetentionIdle                  = 'Teams अभी अपना मुख्य लॉग नहीं लिख रहा। उसके पिछले सत्र का लॉग {0} से {1} तक चलता है।'
    DetailRetentionRotation              = 'चल रहे क्लाइंट के लिए Teams केवल अपनी सबसे हाल की सात MSTeams_*.log लॉग फ़ाइलें, और हर पिछले सत्र की आखिरी सात रखता है, इसलिए इससे पुरानी कोई चीज़ केवल टुकड़ों में बचती है; सबसे पुराना {0} पर शुरू होता है। अवधि टाइल बताती है कि आपका चुना समय कवर है या नहीं।'
    DetailRetentionOldest                = 'सबसे पुराना रखा गया लॉग {0} पर शुरू होता है।'
    DetailActivityNever                  = 'यहाँ कभी कोई लॉग नहीं लिखा गया।'
    DetailActivityNewest                 = 'सबसे हाल का लॉग लेखन {0}।'
    DetailCoverageNoLogs                 = 'इसे कवर करने के लिए कुछ भी रखा नहीं है।'
    DetailCoverageFuture                 = 'अवधि अभी से बाद में शुरू होती है, इसलिए उसके लिए अभी कोई लॉग मौजूद नहीं हो सकता।'
    DetailCoverageEndsAhead              = 'अवधि अभी से {0} मिनट आगे तक चलती है। संग्रह वे लॉग पढ़ता है जो पहले से मौजूद हैं और प्रतीक्षा नहीं करता, इसलिए वह हिस्सा कुछ नहीं जोड़ता। उसे कवर करने के लिए बाद में फिर संग्रह करें, या प्रभाव समय को उस समय पर सेट करें जब दोष सचमुच हुआ था।'
    DetailCoverageRange                  = '{0} से {1}'
    DetailCoverageWhy                    = 'चल रहे क्लाइंट के लिए Teams केवल अपनी सबसे हाल की सात MSTeams_*.log फ़ाइलें रखता है, इसलिए लंबे सत्र का पहला हिस्सा लॉग लिखते-लिखते हट जाता है, और रीस्टार्ट से एक छोटा अंतराल रह जाता है।'
    DetailCoverageMainSpans              = 'मुख्य Teams लॉग पूरी चुनी गई अवधि तक फैला है: {2} को {0} से {1} तक। मौजूदा लॉग उसी दायरा से चुने जाते हैं - प्रतीक्षा करते समय कुछ रिकॉर्ड नहीं होता।'
    DetailCoverageBeforeMain             = 'अवधि सबसे पुराने रखे गए मुख्य लॉग ({0}) से पहले समाप्त होती है।'
    DetailCoverageGap                    = 'मुख्य Teams लॉग में {1} को {0} से कुछ नहीं है।'
    DetailCoverageGapRest                = 'दूसरे लॉग फिर भी एकत्र किए जाते हैं, लेकिन इस समय का क्लाइंट लॉग जा चुका है।'
    DetailCoveragePartial                = 'मुख्य Teams लॉग में अवधि के {1} मिनटों में से {0} गायब हैं: {2}।'
    DetailCoverageBeforeOldest           = 'अवधि सबसे पुराने रखे गए लॉग ({0}) से पहले समाप्त होती है।'
    DetailCoverageStartMissing           = 'लॉग केवल {0} तक पीछे जाते हैं, इसलिए अवधि की शुरुआत गायब है।'
    DetailCoverageRetained               = 'रखे गए लॉग पूरी चुनी गई अवधि तक फैले हैं: {2} को {0} से {1} तक। मौजूदा लॉग उसी दायरा से चुने जाते हैं - प्रतीक्षा करते समय कुछ रिकॉर्ड नहीं होता।'
    DetailCrashWebView                   = '{0} WebView2 रेंडरर क्रैश रिपोर्ट भी मौजूद हैं, जिन्हें अनुप्रयोग लॉग दर्ज नहीं करता।'
    DetailCrashCount                     = 'पिछले {1} घंटों में अनुप्रयोग लॉग में {0} Teams-संबंधित क्रैश ईवेंट हैं।'
    DetailCrashNone                      = 'पिछले {0} घंटों में कोई क्रैश ईवेंट नहीं।'
    DetailCrashUnreadable                = 'अनुप्रयोग लॉग पढ़ा नहीं जा सका: {0}'
    DetailNetworkInspected               = '{0} के लिए TLS शृंखला सार्वजनिक रूट के बजाय ''{1}'' पर समाप्त होती है, जो ब्रेक-एंड-इंस्पेक्ट जैसा दिखता है - Microsoft इसे Teams अपडेट और मीडिया विफलताएँ का कारण बताता है।'
    DetailNetworkNotUntouched            = 'कोई टनलिंग क्लाइंट या जुड़ा VPN नहीं मिला, लेकिन ट्रैफ़िक Microsoft तक अनछुआ नहीं पहुँच रहा।'
    DetailNetworkIdle                    = '{0}. इंस्टॉल है लेकिन चल नहीं रहा, इसलिए ट्रैफ़िक सीधे बाहर जा रहा है।'
    DetailNetworkDirect                  = 'कोई टनलिंग क्लाइंट या जुड़ा VPN नहीं मिला, इसलिए नेटवर्क जाँच सीधा पथ को मापते हैं।'
    DetailNetworkCarried                 = 'Teams ट्रैफ़िक {0} से होकर जाता है। अपने आप में दोष नहीं, लेकिन इस बंडल में पहुँच और मीडिया-पथ परिणाम सीधे नहीं बल्कि इसी रास्ते से मापे गए - नेटवर्क परिणाम को ग्राहक समस्या कहने से पहले इस पथ से बाहर की मशीन से तुलना करें।'
    DetailNetworkUnreadable              = 'नेटवर्क पथ निर्धारित नहीं हो सका: {0}'
    DetailUpdateNone                     = 'अपडेट इतिहास पढ़ी नहीं जा सकी।'
    DetailUpdateStaged                   = 'बिल्ड {0} स्टेज था {1}। लॉन्चर लॉग में कोई संस्करण बदलाव दर्ज नहीं है, इसलिए यह क्लाइंट उनकी रिटेंशन में अपडेट नहीं हुआ है।'
    DetailUpdateUnknown                  = 'डिस्क पर {0} लॉन्चर लॉग में कोई संस्करण बदलाव दर्ज नहीं है, और इंस्टॉल स्थान पढ़ा नहीं जा सका।'
    DetailUpdateWhen                     = '{1} से {2} पर {0} अपडेट हुआ।'
    DetailUpdateInWindow                 = 'यह एकत्र की जा रही अवधि के अंदर है, इसलिए लॉग दो अलग क्लाइंट बिल्ड तक फैले हैं - अपेक्षा करें कि व्यवहार बीच में बदलेगा, और बंडल सौंपते समय ऐसा बताएँ।'
    DetailUpdateUnreadable               = 'अपडेट इतिहास पढ़ी नहीं जा सकी: {0}'
    DetailSignInNoState                  = 'कोई क्लाइंट स्थिति फ़ोल्डर कॉन्फ़िगर नहीं है।'
    DetailSignInNoSettings               = 'app_settings.json {0} के तहत नहीं मिला, इसलिए साइन-इन खाते पढ़े नहीं जा सके।'
    DetailSignInNone                     = 'app_settings.json में कोई साइन-इन खाता दर्ज नहीं है। चलते क्लाइंट पर यह असामान्य है और शायद मतलब है कि फ़ाइल अभी लिखी नहीं गई है।'
    DetailSignInShapeTenants             = '{0} साइन-इन पहचानें, {2} टेनेंट में {1} अलग व्यक्ति तक हल हो रही हैं। एक व्यक्ति का एक से अधिक टेनेंट में साइन इन होना हर टेनेंट के लिए एक प्रविष्टि बनाता है, जो सामान्य है।'
    DetailSignInShape                    = '{0} साइन-इन पहचानें, {1} अलग व्यक्ति तक हल हो रही हैं।'
    DetailSignInAllDeclared              = 'सभी ids Privacy.KnownAccountIds में सूचीबद्ध हैं, इसलिए खाता जाँच पैकेजिंग को अवरुद्ध नहीं करेगा। सहमति और टोकन जाँच अभी भी लागू हैं और साक्ष्य आने से पहले जाँचे नहीं हो सकते।'
    DetailSignInNothingWrong             = 'Teams या इस मशीन में कुछ गलत नहीं है। टूलबॉक्स को बस यह नहीं बताया गया है कि यहाँ कौन से खाते अपेक्षित हैं, और गोपनीयता गेट ऐसे खाते के साक्ष्य को पैकेज करने से मना करता है जिसे वह पहचानता नहीं।'
    DetailSignInUndeclared               = '{1} में से {0} id को Privacy.KnownAccountIds में घोषित करने की जरूरत है: {2}।'
    DetailSignInOnePerson                = 'वे सभी एक ही व्यक्ति तक हल होते हैं, इसलिए यह साझा मशीन के बजाय एक उपयोगकर्ता है जो {0} टेनेंट में साइन इन है।'
    DetailSignInManyPeople               = 'ये {0} अलग लोग तक हल होते हैं, इसलिए संग्रह करने से पहले जाँचें कि और कौन साइन इन है - बंडल उन सबके लिए साक्ष्य ले जाएगा।'
    DetailSignInAllIdentities            = 'New Teams टेनेंट से परे हर साइन-इन पहचान के लिए निदान लिखता है, इसलिए साक्ष्य उन सभी तक फैलेगा।'
    DetailSignInWillRefuse               = 'पैकेजिंग इस बंडल को तब तक अस्वीकार करेगी जब तक वे घोषित न हों।'
    DetailSignInReportedOnly             = 'BlockOnUnknownAccount false है, इसलिए यह अवरुद्ध के बजाय रिपोर्ट है।'
    DetailSignInUnreadable               = 'साइन-इन खाते पढ़े नहीं जा सके: {0}'

    # --- Admin center steps --------------------------------------------------------
    # The portal's menus, tabs and buttons, the role names and the cmdlets are passed in as {0}, {1}: they are what the operator finds on screen or types, so they are never translated.
    AdminHeading                         = 'Teams व्यवस्थापन केंद्र से संग्रह'
    AdminSummary                         = 'दूरस्थ क्लाइंट लॉग संग्रह: शांत, मशीन पर किसी की जरूरत नहीं, 8 घंटे तक।'
    AdminFromDocs                        = 'ये Microsoft के दस्तावेज़ित चरण हैं, स्मृति से पोर्टल का वर्णन नहीं - मेनू नाम बदलते हैं, और आधा याद पथ आपको बदले नाम वाले बटन की खोज में भेजता है।'
    AdminBeforeStart                     = 'शुरू करने से पहले। इनमें से हर एक बिल्कुल भी बंडल नहीं बनाता, और आपको 8 घंटे तक पता नहीं चलेगा:'
    AdminNotContainHeading               = 'इसमें क्या नहीं होगा'
    AdminDocsButtonNote                  = 'नीचे का बटन इसके लिए Microsoft का दस्तावेज़ खोलता है, यही पृष्ठ पोर्टल बदलने पर भी सही रहता है। ऊपर {0} में पोर्टल पता खुद है।'
    AdminDocsButton                      = 'Microsoft दस्तावेज़ खोलें'
    FactStep                             = 'चरण {0}'
    FactRolesNeeded                      = 'आवश्यक भूमिकाएँ'

    # --- Feature comparison --------------------------------------------------------
    CompareWindowTitle                   = 'हर टूल क्या एकत्र करता है'
    CompareHeading                       = 'हर टूल सच में क्या एकत्र करता है'
    CompareSharedHeading                 = 'दोनों यह एकत्र करते हैं'
    CompareFactColumn                    = 'तथ्य'
    CompareSidesColumn                   = 'दूरस्थ बंडल  /  यह टूलबॉक्स'
    CompareToolboxOnlyHeading            = 'केवल यह टूलबॉक्स इसे एकत्र करता है'
    CompareRemoteOnlyHeading             = 'केवल दूरस्थ संग्रह इसे देता है'
    CompareConclusion                    = 'कोई भी टूल दूसरे का सुपरसेट नहीं है। वे लगभग पूरी तरह अलग आर्टिफ़ैक्ट एकत्र करते हैं: दूरस्थ संग्रह सेवा से बात करते Teams वेब अनुप्रयोग को कैप्चर करता है, और यह टूलबॉक्स नेटिव क्लाइंट और उसके नीचे की मशीन को कैप्चर करता है।'

    # --- A refused Package, in the log box ------------------------------------------
    # The run prints these in English, naming switches, for the command line and Blockers.csv (Get-TlcPackageRefusalText). The window recognises each line and shows these instead, naming the controls it has: {0}, {1} are filled with their labels from this table.
    TranscriptToFix                      = 'ठीक करने के लिए:'
    PackageFixCredential                 = 'HAR में क्रेडेंशियल इस जाँच से पहले अपने-आप हटाए जाते हैं, इसलिए जो बचा है वह किसी और फ़ाइल में है या ऐसे आकार में है जिसे रिडैक्शन नहीं जानता। नामित फ़ाइलों को रन फ़ोल्डर से हटाएँ। HAR को स्वच्छ किए गए रूप में फिर निर्यात करने से मदद नहीं मिलती: स्वच्छ करना केवल हेडर हटाता है, और टोकन प्रतिक्रिया बॉडी में हैं।'
    PackageFixUnreadable                 = 'जिसने नामित फ़ाइलों को खुला रखा है उसे बंद करें, या उन्हें रन फ़ोल्डर से हटाएँ।'
    PackageFixAccounts                   = 'इस संग्रह से जुड़े खाता IDs घोषित करें: {0} टाइल खोलें और "{1}" दबाएँ। किसी और के खाते को घोषित न करें: उसे Teams से साइन आउट करें और फिर संग्रह करें, या उसे नाम देने वाली फ़ाइलों को रन फ़ोल्डर से हटाएँ; IdentityInventory.json बताता है कि हर एक कहाँ मिला। सहमति दर्ज करने से यह साफ़ नहीं होता।'
    PackageFixConsent                    = 'इस संग्रह को किसने अधिकृत किया वह दर्ज करें: अपने खाते पर टिक करें या "{0}" के पास नाम टाइप करें।'
    PackageFixFleet                      = 'यह एंडपॉइंट पहुँच में आने के बाद इसके लिए संग्रह फिर चलाएँ, या उस मशीन पर सीधे संग्रह करें।'
    PackageExcluded                      = 'बंडल से बाहर रखा गया।'
    PackageAllRefused                    = 'अवरुद्ध: हर एंडपॉइंट अस्वीकार हुआ, इसलिए बंडल पैकेज नहीं हुआ।'
    PackageFixClosing                    = 'ऊपर सूचीबद्ध चीजें ठीक करें, फिर "{0}" फिर दबाएँ।'

    # Why an endpoint was refused, under its name. The run fills in the counts, ids and file names; the window reads them back out of the line and puts them into these, unchanged.
    PackageReasonUnknownAccounts         = '{0} साइन-इन खाते घोषित नहीं हैं: {1}'
    PackageReasonManyAccounts            = '{0} खाते साइन इन हैं; क्लाइंट निदान उन सभी तक फैले हैं।'
    PackageReasonArchives                = '{0} क्लाइंट-निर्मित आर्काइव शामिल हैं; सामग्री हर साइन-इन खाते तक फैली है।'
    PackageReasonAddresses               = 'पाठ साक्ष्य में {0} अलग पते मिले।'
    PackageReasonCredentials             = '{0} फ़ाइलों में एक्सेस टोकन मिले: {1}।'
    PackageReasonUnreadable              = '{0} फ़ाइलों को गोपनीयता स्कैन नहीं पढ़ सका, इसलिए उनकी सामग्री अज्ञात है: {1}।'
    PackageReasonPartial                 = '{0} फ़ाइलें {1} MB स्कैन सीमा से बड़ी हैं और केवल आंशिक रूप से पढ़ी गईं: {2}।'
    PackageReasonConsent                 = 'सहमति आवश्यक है, और "{0}" के पास कोई दर्ज नहीं है।'
    PackageReasonFleetFailed             = '{0} से संग्रह विफल हुआ, इसलिए उसका फ़ोल्डर आंशिक है और रोका गया है; Blockers.csv में Fleet पंक्ति देखें।'

    # --- What the window writes into the log box -------------------------------------
    LogFailedToRun                       = 'चलाने में विफल: {0}'
    LogExitCode                          = '(निकास कोड {0})'
    LogSessionArchive                    = 'सत्र आर्काइव: {0}'
    LogSessionArchiveCounts              = '{0} रन, {1} फ़ाइलें, {2} MB'
    LogZipFailed                         = 'बंडल पैकेज हो गए, लेकिन सत्र ज़िप लिखी नहीं जा सकी। हर रन फ़ोल्डर फिर भी अपने-आप भेजा जा सकता है।'
    LogNotZipped                         = 'ज़िप में नहीं, क्योंकि वे सील नहीं हुए थे: {0}. ऊपर का ट्रांसक्रिप्ट हर एक का कारण बताता है; जो सील नहीं है वह कभी ज़िप नहीं होता।'
    LogStopAsked                         = 'कैप्चर सत्र से सैंपलिंग रोकने को कहा जा रहा है...'
    LogSamplingStopped                   = 'सैंपलिंग रुक गई। रन अब सत्र के दौरान लिखे गए लॉग एकत्र करता है, फिर Teams की सपोर्ट फ़ाइलें माँगता है, और अपने-आप समाप्त होता है। सपोर्ट फ़ाइलें छोड़ने के लिए {0} फिर दबाएँ।'
    LogSkippingSupport                   = 'सपोर्ट फ़ाइलें छोड़ी जा रही हैं और रन समाप्त हो रहा है...'
    LogFinishedAfterStop                 = 'रन समाप्त हुआ। सैंपल, सारांश और लॉग सभी लिखे गए हैं।'
    LogSessionUnanswered                 = 'सत्र ने उत्तर नहीं दिया, इसलिए उसे समाप्त किया जा रहा है। पहले से लिखे गए सैंपल रखे जाते हैं।'
    LogStoppedKept                       = 'रुक गया। रन फ़ोल्डर में पहले से लिखी हर चीज रखी जाती है - बंडल बस अधूरा है। कुछ भी फेंका नहीं गया।'
    LogConsentRecorded                   = 'सहमति दर्ज: {0}'

    # --- Admin center steps and feature comparison, as the metrics write them ------
    # New-TlcMetricText in Tlc.Ui.Metrics.psm1 names each key with its English; the gate holds them equal.
    AdminStepSignIn                      = '{0} पर Teams व्यवस्थापन केंद्र में साइन इन करें'
    AdminStepUsers                       = '{0} पर जाएँ, फिर {1}, और प्रभावित उपयोगकर्ता खोलें।'
    AdminStepTab                         = '{0} टैब खोलें।'
    AdminStepRequest                     = '{0} चुनें। उपयोगकर्ता से कुछ नहीं पूछा जाता और उसे कुछ नहीं दिखता।'
    AdminStepWait                        = 'प्रतीक्षा करें। Microsoft दस्तावेज़ित करता है कि बंडल डाउनलोड होने से पहले 8 घंटे तक लग सकते हैं, और अनुरोध 3 दिन बाद समाप्त हो जाता है।'
    AdminStepDownload                    = 'उसी {0} टैब पर लौटें और इसे डाउनलोड करने के लिए {1} चुनें।'
    AdminRoles                           = '{0}, {1}, {2} या {3}।'
    AdminNeedsRunning                    = 'Teams क्लाइंट मशीन पर चल रहा होना चाहिए। जो क्लाइंट शुरू नहीं हो सकता वह कभी चेक इन नहीं करता, और अनुरोध बस समाप्त हो जाता है।'
    AdminNeedsPlatform                   = 'केवल Windows non-VDI और Mac। VDI स्पष्ट रूप से बाहर है, जैसे वेब, मोबाइल और Linux।'
    AdminNeedsOneCloud                   = 'व्यावसायिक और सरकारी दोनों खातों में साइन इन क्लाइंट पात्र नहीं है - सुविधा उसके लिए उपलब्ध नहीं है।'
    AdminNotCollected                    = 'Windows ईवेंट लॉग, {0} ट्रेस, स्क्रीनशॉट और हीप डंप स्पष्ट रूप से एकत्र नहीं किए जाने के रूप में दस्तावेज़ित हैं। समय-अवधि पैरामीटर भी नहीं है: चलते समय डिस्क पर जो है वही लेता है।'
    AdminRetention                       = 'बंडल Microsoft संग्रहण में 30 दिन रखे जाते हैं।'
    AdminPowerShell                      = 'वही स्टोर PowerShell से पहुँच में है: {0}, {1} बटन है, {2}, {3} पृष्ठ है, और {4}, {5} है।'
    CompareBasis                         = '{0} को कैप्चर किए गए दूरस्थ-श्रेणी बंडल (74 प्रविष्टियाँ, 5.5 MB) की वास्तविक संग्रह रन के टूलबॉक्स बंडल (33 फ़ाइलें) से तुलना करके मापा गया। दस्तावेज़ित चिह्नित पंक्तियाँ किसी आर्टिफ़ैक्ट में नहीं देखी गईं।'
    CompareConfigFact                    = 'क्लाइंट कॉन्फ़िगरेशन'
    CompareConfigRemote                  = '{0}, 3.4 MB - वेब क्लाइंट वृक्ष'
    CompareConfigToolbox                 = '{0}, {1} - डेस्कटॉप क्लाइंट स्थिति'
    CompareFlightFact                    = 'फ़्लाइट रिंग, टेनेंट, लाइसेंस'
    CompareIdentityFact                  = 'साइन-इन खाता पहचान'
    CompareIdentityRemote                = 'हर खाते के लिए एक फ़ोल्डर'
    CompareIdentityToolbox               = '{0}, साथ में गोपनीयता इन्वेंटरी'
    CompareSignallingFact                = 'कॉल सिग्नलिंग'
    CompareSignallingRemote              = '{0} ({1} स्थिति)'
    CompareSignallingToolbox             = '{0} लॉग - उसी कहानी की अलग परत'
    CompareMediaFact                     = 'मीडिया आँकड़े'
    CompareMediaRemote                   = '{0} - कॉल न होने पर 0 बाइट मापा गया'
    CompareMediaToolbox                  = 'कोई नहीं - वास्तविक कॉल से 0 बाइट'
    CompareNativeLogsName                = 'नेटिव डेस्कटॉप क्लाइंट लॉग'
    CompareNativeLogsDetail              = '{0}. यहाँ 7 फ़ाइलें, दूरस्थ बंडल में 0'
    CompareMediaStackName                = 'मीडिया-स्टैक लॉग'
    CompareMediaStackDetail              = '{0}. स्थानीय रूप से मौजूद, कैप्चर किए गए दूरस्थ बंडल से अनुपस्थित'
    CompareUpdateLogsName                = 'अपडेट और लॉन्चर लॉग'
    CompareUpdateLogsDetail              = 'जो क्लाइंट अपडेट होने में विफल हुआ वह अपना कारण यहाँ बताता है और कहीं नहीं'
    CompareEventLogsName                 = 'Windows ईवेंट लॉग'
    CompareEventLogsDetail               = 'छह चैनल। व्यवस्थापन केंद्र इन्हें स्पष्ट रूप से एकत्र नहीं किए जाने के रूप में दस्तावेज़ित करता है'
    CompareInventoryName                 = 'मशीन इन्वेंटरी'
    CompareInventoryDetail               = 'OS बिल्ड, हार्डवेयर, बूट समय, समय क्षेत्र और ऑफ़सेट, {0}, पैकेज स्वास्थ्य, कैश फ़ुटप्रिंट'
    CompareJoinName                      = 'डिवाइस जॉइन स्थिति'
    CompareJoinDetail                    = '{0}, डोमेन और कार्यस्थल जॉइन - दूरस्थ रूप से बराबर कुछ नहीं'
    CompareVdiName                       = 'VDI पहचान'
    CompareVdiDetail                     = 'प्लैटफ़ॉर्म और {0} स्थिति। व्यवस्थापन केंद्र VDI पर असमर्थित के रूप में दस्तावेज़ित है'
    CompareNetworkName                   = 'पूरा नेटवर्क पथ'
    CompareNetworkDetail                 = 'DNS शृंखला, TLS इंटरसेप्शन, {0} और {1} प्रॉक्सी, UDP और STUN पहुँच। दूरस्थ बंडल नेटवर्क के बारे में कुछ नहीं कहता'
    CompareUpdateHistoryName             = 'अपडेट इतिहास'
    CompareUpdateHistoryDetail           = 'कौन सा बिल्ड, और वह कब बदला'
    CompareRendererName                  = 'रेंडरर क्रैश रिकॉर्ड'
    CompareRendererDetail                = '{0} क्रैश गणना और समय'
    CompareScopingName                   = 'पुनरुत्पादन-अवधि दायरा'
    CompareScopingDetail                 = 'दूरस्थ पथ में समय-अवधि पैरामीटर नहीं है और चलते समय डिस्क पर जो हो वही लेता है'
    CompareChronologyName                = 'मर्ज की गई कालक्रम'
    CompareChronologyDetail              = 'हर लॉग परिवार में एक समय-क्रमित स्ट्रीम'
    CompareExitReasonName                = 'क्रैश और निकास कारण'
    CompareFailuresName                  = 'क्या प्रयास हुआ और विफल रहा'
    CompareFailuresDetail                = 'ब्लॉकर और ईवेंट। दूरस्थ बंडल बताता है कि उसने क्या जुटाया, कभी नहीं कि वह क्या नहीं जुटा सका'
    CompareConsentName                   = 'सहमति रिकॉर्ड और गोपनीयता गेट'
    CompareConsentDetail                 = 'बंडल के साथ सहमति दर्ज, पहचानकर्ता मास्क किए गए जब तक कच्चा न माँगा जाए, अपरिचित खाते पर पैकेजिंग अस्वीकार'
    CompareTamperName                    = 'छेड़छाड़-स्पष्ट बंडल'
    CompareTamperDetail                  = 'प्रति फ़ाइल {0}, सौंपने के बाद सत्यापनीय'
    CompareRoomsName                     = '{0} और {1} सहसंबंध'
    CompareRoomsDetail                   = 'एक हेडर जिस पर Microsoft और भागीदार दोनों कुंजी बना सकते हैं'
    CompareUnattendedName                = 'मशीन पर किसी को होना जरूरी नहीं'
    CompareUnattendedDetail              = 'संरचनात्मक। यह टूलबॉक्स जो भी करता है उसके लिए मशीन पर साइन-इन सत्र चाहिए'
    CompareNoScriptName                  = 'एंडपॉइंट पर कोई स्क्रिप्ट निष्पादन नहीं'
    CompareNoScriptDetail                = '{0} या {1} एस्टेट पर यह टूलबॉक्स बिल्कुल नहीं चल सकता'
    CompareWebLogsName                   = 'वेब अनुप्रयोग के अपने लॉग'
    CompareWebLogsDetail                 = '{0}, 39 MB। टूलबॉक्स बंडल से पूरी तरह अनुपस्थित'
    CompareDataLayerName                 = 'केंद्रीय डेटा परत'
    CompareDataLayerDetail               = '{0} फ़ाइलें। दूरस्थ बंडल में 10, स्थानीय रूप से 0'
    CompareSyncName                      = 'लगभग तीस सिंक उपप्रणालियाँ'
    CompareSyncDetail                    = 'संदेश, कैलेंडर, लोग, उपस्थिति, नीतियाँ, फ़ाइलें, कॉल इतिहास। 0 के मुकाबले 31 फ़ाइलें। जहाँ गायब चैट या पुराना कैलेंडर उत्तर पाता है'
    CompareStorageName                   = 'स्थानीय संग्रहण उपयोग'
    CompareEveryAccountName              = 'हर साइन-इन खाता'
    CompareEveryAccountDetail            = 'बनावट से। कवरेज के लिए शक्ति, और वही उजागरपन जिसके लिए गोपनीयता गेट है'
    CompareFleetName                     = 'बेड़े का पैमाना और 28-दिन रुझान'
    CompareFleetDetail                   = 'दस्तावेज़ित। स्थानीय बंडल कभी नहीं बता सकता कि एस्टेट वही समस्या साझा करता है या नहीं'
    CompareMacName                       = '{0}, और 30-दिन क्लाउड रिटेंशन'
    CompareDocumented                    = 'दस्तावेज़ित'
    CompareShellName                     = 'डेस्कटॉप शेल और {0} लॉग'
    CompareShellDetail                   = 'दस्तावेज़ित पर कैप्चर किए गए आर्टिफ़ैक्ट में देखा नहीं गया। असत्यापित'
}
