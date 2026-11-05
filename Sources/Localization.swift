import Foundation

// MARK: - 语言

/// 界面语言。切换后所有自绘文本、菜单、设置页一起换。
enum AppLanguage: String, CaseIterable, Hashable, Sendable {
    case simplified
    case traditional
    case english
    case french
    case korean
    case japanese
    case arabic
    case spanish
    case portuguese

    static let fallback: AppLanguage = .simplified

    /// 与 `Localization.table` 里每条译文数组的下标一一对应
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var localeID: String {
        switch self {
        case .simplified: return "zh-Hans"
        case .traditional: return "zh-Hant"
        case .english: return "en"
        case .french: return "fr"
        case .korean: return "ko"
        case .japanese: return "ja"
        case .arabic: return "ar"
        case .spanish: return "es"
        case .portuguese: return "pt"
        }
    }

    var isRightToLeft: Bool { self == .arabic }

    /// 方块字：同样一句话占的宽度小得多，排版参数按这个分档
    var isCompactScript: Bool {
        switch self {
        case .simplified, .traditional, .japanese, .korean: return true
        default: return false
        }
    }

    /// 用方块字排版（中文/日文/韩文）的日期写法是「3月5日」，拉丁语言写「03-05」
    var usesCJKDateFormat: Bool { isCompactScript }

    /// 坐标轴上的日期：中文/日文「10月30日」，韩文「10월 30일」，其余「10-30」
    var dayPattern: String {
        switch self {
        case .simplified, .traditional, .japanese: return "M月d日"
        case .korean: return "M월 d일"
        default: return "MM-dd"
        }
    }

    /// 日期 + 时刻（跨度大、一天里有好几个刻度时用）
    var dayTimePattern: String {
        switch self {
        case .simplified, .traditional, .japanese: return "M月d日 HH:mm"
        case .korean: return "M월 d일 HH:mm"
        default: return "MM-dd HH:mm"
        }
    }

    /// 悬停提示里的完整时刻
    var fullStampPattern: String {
        switch self {
        case .simplified, .traditional, .japanese: return "M月d日 HH:mm:ss"
        case .korean: return "M월 d일 HH:mm:ss"
        default: return "MM-dd HH:mm:ss"
        }
    }

    /// 语言在它自己里的写法：简体中文 / English / le français
    var nativeName: String {
        switch self {
        case .simplified: return "简体中文"
        case .traditional: return "繁體中文"
        case .english: return "English"
        case .french: return "le français"
        case .korean: return "한국어"
        case .japanese: return "日本語"
        case .arabic: return "العربية"
        case .spanish: return "español"
        case .portuguese: return "português"
        }
    }

    /// 在**当前界面语言**里的译名：切到中文看「le français（法语）」，切到英文看「le français（French）」
    var translatedName: String {
        let row = Self.nameTable[self] ?? []
        let slot = Localization.current.index
        return slot < row.count ? row[slot] : nativeName
    }

    /// 下拉项的样子：母语写法（当前语言里的译名）。
    /// 译名和母语写法一样时（就是当前这门语言本身）不再重复一遍括号。
    var menuTitle: String {
        let alias = translatedName
        return alias == nativeName ? nativeName : "\(nativeName)（\(alias)）"
    }

    /// 9×9：每种语言在 9 种界面语言下的叫法。顺序与 `allCases` 一致。
    private static let nameTable: [AppLanguage: [String]] = [
        .simplified: [
            "简体中文", "簡體中文", "Simplified Chinese", "chinois simplifié",
            "중국어 간체", "簡体中国語", "الصينية المبسطة", "chino simplificado", "chinês simplificado"
        ],
        .traditional: [
            "繁体中文", "繁體中文", "Traditional Chinese", "chinois traditionnel",
            "중국어 번체", "繁体中国語", "الصينية التقليدية", "chino tradicional", "chinês tradicional"
        ],
        .english: [
            "英语", "英語", "English", "anglais",
            "영어", "英語", "الإنجليزية", "inglés", "inglês"
        ],
        .french: [
            "法语", "法語", "French", "français",
            "프랑스어", "フランス語", "الفرنسية", "francés", "francês"
        ],
        .korean: [
            "韩语", "韓語", "Korean", "coréen",
            "한국어", "韓国語", "الكورية", "coreano", "coreano"
        ],
        .japanese: [
            "日语", "日語", "Japanese", "japonais",
            "일본어", "日本語", "اليابانية", "japonés", "japonês"
        ],
        .arabic: [
            "阿拉伯语", "阿拉伯語", "Arabic", "arabe",
            "아랍어", "アラビア語", "العربية", "árabe", "árabe"
        ],
        .spanish: [
            "西班牙语", "西班牙語", "Spanish", "espagnol",
            "스페인어", "スペイン語", "الإسبانية", "español", "espanhol"
        ],
        .portuguese: [
            "葡萄牙语", "葡萄牙語", "Portuguese", "portugais",
            "포르투갈어", "ポルトガル語", "البرتغالية", "portugués", "português"
        ]
    ]
}

// MARK: - 词条

/// 一句界面文案。译文按 `AppLanguage.allCases` 的顺序排成一条数组。
enum Phrase: Hashable {
    // 设置页
    case settingsTitle
    case sectionGeneral
    case sectionDisplay
    case sectionActions
    case languageRow
    case languageDetail
    case launchAtLogin
    case launchAtLoginFailed
    case widgetToggle
    case widgetToggleDetail
    case acrossSpaces
    case companionOnTop
    case companionOnTopDetail
    case screenshotPickable
    case screenshotPickableDetail
    case cadence
    case cadenceDetail
    case appearance
    case appearanceDetail
    case statusStyle
    case hotKey
    case hotKeyDetail
    case themeSystem
    case themeLight
    case themeDark
    case badgeGlyphAndNumber
    case badgeNumberOnly
    case badgeGlyphOnly
    case actionRefresh
    case actionTrend
    case actionUsagePage
    case actionRelogin
    case actionResetPosition
    case settingsFooter
    case settingsInactiveHint

    // 菜单栏菜单
    case menuCollapse
    case menuExpand
    case menuRefresh
    case menuUsagePage
    case menuTrend
    case menuSignIn
    case menuReSignIn
    case menuAutoStart
    case menuYieldForCapture
    case menuPreferences
    case menuQuit
    case statusNoAccount
    case statusReadFailed
    case statusReading
    case gaugeRemaining
    case gaugeUnknown

    // 悬浮窗
    case planPreview
    case emptyNoData
    case emptyRetryLater
    case wakingTitle
    case wakingDetail
    case signInTitle
    case signInDetail
    case primingTitle
    case primingDetail
    case failedTitle
    case failedDetail

    // 消耗预测
    case estimateCollecting
    case estimateSteady
    case estimateExhausted
    case estimateBeforeReset
    case estimateSharedExhaust
    case estimateFalling
    case footerAutoRefresh
    case footerOffline
    case footerPreview
    case lastReset
    case resetCountdown
    case resetImminent

    // 额度窗口叫法
    case quotaPlain
    case quotaWeekly
    case quotaWeeks
    case quotaHours
    case quotaMinutes
    case rowWeekly
    case rowHours
    case rowMinutes
    case shortWeekly
    case shortHours
    case shortMinutes

    // 趋势图
    case trendTitle
    case trendHint
    case trendFitAll
    case trendBackToNow
    case trendDataFolder
    case plotEmptyTitle
    case plotEmptyDetail
    case plotSparseHint
    case plotBottomOut
    case plotSpan
    case plotForecast
    case plotResetMoment
    case plotLastReset
    case plotNextReset

    // 系统通知
    case notifyLowTitle
    case notifyLowBody
    case notifyResetTitle
    case notifyResetBody
    case notifyPermissionOff
    case notifyNotGranted
    case notifyFailed
    case notifyFailedByPolicy

    // 数据解析
    case decodeInvalid
    case decodeEmpty
}

// MARK: - 取词

enum Localization {
    static let didChange = Notification.Name("com.quotadock.languageChanged")

    /// 当前语言。自绘代码随时会读，所以自己存一份，不依赖 Preferences 的初始化时机。
    private static var active: AppLanguage = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: Slot.language) ?? ""
    ) ?? .fallback
    private static let gate = NSLock()

    static var current: AppLanguage {
        gate.lock()
        let value = active
        gate.unlock()
        return value
    }

    static func apply(_ language: AppLanguage) {
        gate.lock()
        let changed = active != language
        active = language
        gate.unlock()
        guard changed else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 用户默认值键名。Preferences 也用同一个键，避免两边写偏。
    /// 改过一次名：早期调试时误写过一次语言值，换个键就等于回到默认（简体中文）。
    enum Slot {
        static let language = "uiLanguage"
    }

    static func text(_ phrase: Phrase) -> String {
        let row = table[phrase] ?? []
        let slot = current.index
        if slot < row.count { return row[slot] }
        // 译文漏了就退回中文，再漏就给空串，绝不把占位符露给用户
        return row.first ?? ""
    }

    /// 带参数的文案：`String(format: Localization.text(.estimateFalling), spell)`
    static func format(_ phrase: Phrase, _ args: CVarArg...) -> String {
        String(format: text(phrase), arguments: args)
    }
}

// MARK: - 时长与数字

extension Localization {
    /// 时间单位的写法：中文「3 小时」，英文「3h」，法文「3 h」
    private struct Units {
        let day: String
        let hour: String
        let minute: String
        let second: String
        /// 数字与单位之间要不要空格
        let gap: String
    }

    private static var units: Units {
        switch current {
        case .simplified: return Units(day: "天", hour: "小时", minute: "分钟", second: "秒", gap: " ")
        case .traditional: return Units(day: "天", hour: "小時", minute: "分鐘", second: "秒", gap: " ")
        case .english: return Units(day: "d", hour: "h", minute: "m", second: "s", gap: "")
        case .french: return Units(day: "j", hour: "h", minute: "min", second: "s", gap: " ")
        case .korean: return Units(day: "일", hour: "시간", minute: "분", second: "초", gap: "")
        case .japanese: return Units(day: "日", hour: "時間", minute: "分", second: "秒", gap: "")
        case .arabic: return Units(day: "ي", hour: "س", minute: "د", second: "ث", gap: " ")
        case .spanish: return Units(day: "d", hour: "h", minute: "min", second: "s", gap: " ")
        case .portuguese: return Units(day: "d", hour: "h", minute: "min", second: "s", gap: " ")
        }
    }

    private static func part(_ value: Int, _ unit: String) -> String {
        "\(value)\(units.gap)\(unit)"
    }

    /// 「上次重置」那种**已经过去多久**：超过一天才带「天」，不到一天只说小时，不到一小时说分钟。
    static func spellElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            let head = part(days, units.day)
            return hours > 0 ? "\(head) \(part(hours, units.hour))" : head
        }
        if hours > 0 { return part(hours, units.hour) }
        return part(minutes, units.minute)
    }

    /// 倒计时那种**还要多久**：26 小时内用 3:12:45，更长才换成「2 天 3 小时」
    static func spellCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 93_600 {
            let days = total / 86_400
            let hours = (total % 86_400) / 3_600
            let head = part(days, units.day)
            if hours > 0 { return "\(head) \(part(hours, units.hour))" }
            return head
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// 刷新间隔那种整段时长：「60 秒」/「5 分钟」/「1.0 小时」
    static func spellInterval(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return spellSpan(seconds) }
        if seconds >= 60 { return part(Int(seconds / 60), units.minute) }
        return part(Int(seconds), units.second)
    }

    /// 跨度那种带小数的时长：「3.5 小时」
    static func spellSpan(_ seconds: TimeInterval) -> String {
        if seconds < 3_600 {
            return String(format: "%d%@%@", Int(seconds / 60), units.gap, units.minute)
        }
        if seconds < 86_400 {
            return String(format: "%.1f%@%@", seconds / 3_600, units.gap, units.hour)
        }
        return String(format: "%.1f%@%@", seconds / 86_400, units.gap, units.day)
    }

    /// 悬停提示里落在预测段上的那一行：「5 小时额度 预测 42%」
    static func forecastRow(caption: String, percent: Int) -> String {
        switch current {
        case .simplified: return "\(caption) 预测 \(percent)%"
        case .traditional: return "\(caption) 預測 \(percent)%"
        case .english: return "\(caption) \(percent)% (forecast)"
        case .french: return "\(caption) \(percent)% (prévision)"
        case .korean: return "\(caption) 예측 \(percent)%"
        case .japanese: return "\(caption) 予測 \(percent)%"
        case .arabic: return "\(caption) \(percent)% (توقع)"
        case .spanish: return "\(caption) \(percent)% (previsión)"
        case .portuguese: return "\(caption) \(percent)% (previsão)"
        }
    }

    /// 重置时刻那条竖线的标注：中文「5 小时额度重置时刻」，英文「5-hour quota reset」
    static func resetMomentLabel(caption: String) -> String {
        switch current {
        case .simplified, .traditional:
            return "\(caption)重置时刻"
        case .english:
            return "\(caption) reset"
        case .french:
            return "Réinitialisation : \(caption)"
        case .korean:
            return "\(caption) 재설정 시점"
        case .japanese:
            return "\(caption)リセット時刻"
        case .arabic:
            return "لحظة إعادة تعيين \(caption)"
        case .spanish:
            return "Restablecimiento de \(caption)"
        case .portuguese:
            return "Redefinição de \(caption)"
        }
    }
}

// MARK: - 译文表

extension Localization {
    /// 顺序固定为：简体中文、繁体中文、英语、法语、韩语、日语、阿拉伯语、西班牙语、葡萄牙语
    static let table: [Phrase: [String]] = [
        // MARK 设置页
        .settingsTitle: [
            "QuotaDock 设置", "QuotaDock 設定", "QuotaDock Settings",
            "Réglages de QuotaDock", "QuotaDock 설정", "QuotaDock 設定",
            "إعدادات QuotaDock", "Ajustes de QuotaDock", "Ajustes do QuotaDock"
        ],
        .sectionGeneral: [
            "通用", "通用", "General",
            "Général", "일반", "一般",
            "عام", "General", "Geral"
        ],
        .sectionDisplay: [
            "显示", "顯示", "Display",
            "Affichage", "표시", "表示",
            "العرض", "Pantalla", "Exibição"
        ],
        .sectionActions: [
            "操作", "操作", "Actions",
            "Actions", "동작", "操作",
            "إجراءات", "Acciones", "Ações"
        ],
        .languageRow: [
            "语言", "語言", "Language",
            "Langue", "언어", "言語",
            "اللغة", "Idioma", "Idioma"
        ],
        .languageDetail: [
            "切换后设置页、悬浮窗与趋势图会立刻换语言",
            "切換後設定頁、懸浮窗與趨勢圖會立刻換語言",
            "The panel, widget and trend chart switch language right away",
            "Le panneau, le widget et le graphique changent de langue immédiatement",
            "변경하면 패널·위젯·추세 그래프가 즉시 바뀝니다",
            "パネル・ウィジェット・推移グラフはすぐに切り替わります",
            "تتغير لغة اللوحة والنافذة العائمة والرسم البياني فورًا",
            "El panel, el widget y el gráfico cambian de idioma al instante",
            "O painel, o widget e o gráfico mudam de idioma na hora"
        ],
        .launchAtLogin: [
            "开机自动运行", "開機自動執行", "Launch at login",
            "Ouvrir au démarrage", "로그인 시 실행", "ログイン時に起動",
            "التشغيل عند تسجيل الدخول", "Iniciar al iniciar sesión", "Iniciar ao entrar"
        ],
        .launchAtLoginFailed: [
            "无法修改开机启动", "無法修改開機啟動", "Could not change Launch at Login",
            "Impossible de modifier l’ouverture au démarrage", "로그인 시 실행을 변경할 수 없습니다",
            "ログイン時起動を変更できません", "لا يمكن تغيير التشغيل عند تسجيل الدخول",
            "No se pudo cambiar el inicio automático", "Não foi possível alterar a inicialização"
        ],
        .widgetToggle: [
            "悬浮窗", "懸浮窗", "Floating widget",
            "Widget flottant", "플로팅 위젯", "フローティングウィジェット",
            "النافذة العائمة", "Widget flotante", "Widget flutuante"
        ],
        .widgetToggleDetail: [
            "关掉后可用 ⌥⌘B 或右键菜单栏图标重新打开",
            "關閉後可用 ⌥⌘B 或右鍵選單列圖示重新開啟",
            "Turn it back on with ⌥⌘B or the menu bar icon",
            "Réactivez-le avec ⌥⌘B ou l’icône de la barre de menus",
            "⌥⌘B 또는 메뉴 막대 아이콘으로 다시 켤 수 있습니다",
            "⌥⌘B またはメニューバーアイコンで再表示できます",
            "يمكن إعادتها بـ ⌥⌘B أو عبر أيقونة شريط القوائم",
            "Vuelve a activarlo con ⌥⌘B o el icono de la barra de menús",
            "Reative com ⌥⌘B ou o ícone da barra de menus"
        ],
        .acrossSpaces: [
            "跟随所有桌面显示", "跟隨所有桌面顯示", "Show on every desktop",
            "Afficher sur tous les bureaux", "모든 데스크톱에 표시",
            "すべてのデスクトップに表示", "العرض على كل أسطح المكتب",
            "Mostrar en todos los escritorios", "Mostrar em todas as áreas de trabalho"
        ],
        .companionOnTop: [
            "设置页与趋势图置顶", "設定頁與趨勢圖置頂", "Keep panels on top",
            "Garder les panneaux au premier plan", "설정/추세 창을 항상 위에",
            "設定と推移ウィンドウを最前面に", "إبقاء النوافذ في الأعلى",
            "Mantener paneles siempre encima", "Manter painéis sempre no topo"
        ],
        .companionOnTopDetail: [
            "默认关闭：这两个页面是普通窗口，会被别的 App 盖住。打开后它们才常驻最上层（悬浮窗不受影响）",
            "預設關閉：這兩個頁面是一般視窗，會被別的 App 蓋住。開啟後它們才常駐最上層（懸浮窗不受影響）",
            "Off by default: these are ordinary windows that other apps can cover. Turn on to keep them above everything (the widget is unaffected)",
            "Désactivé par défaut : ce sont des fenêtres ordinaires que d’autres apps peuvent recouvrir. Activez pour qu’elles restent au-dessus (le widget n’est pas concerné)",
            "기본 꺼짐: 다른 앱이 덮을 수 있는 일반 창입니다. 켜면 항상 위에 표시됩니다(위젯은 영향 없음)",
            "既定オフ: 他のアプリに覆われる通常ウィンドウです。オンにすると常に最前面になります（ウィジェットは影響なし）",
            "معطل افتراضيًا: نوافذ عادية يمكن لتطبيقات أخرى تغطيتها. فعّله لإبقائها في الأعلى (النافذة العائمة لا تتأثر)",
            "Desactivado por defecto: son ventanas normales que otras apps pueden tapar. Actívalo para mantenerlas encima (el widget no se ve afectado)",
            "Desativado por padrão: são janelas normais que outros apps podem cobrir. Ative para mantê-las no topo (o widget não é afetado)"
        ],
        .screenshotPickable: [
            "允许系统截图选中悬浮窗", "允許系統截圖選取懸浮窗",
            "Let screenshots capture the widget",
            "Autoriser la capture du widget",
            "스크린샷에서 위젯 선택 허용",
            "スクリーンショットでウィジェットを選択",
            "السماح للقطات الشاشة بالتقاط النافذة العائمة",
            "Permitir que las capturas incluyan el widget",
            "Permitir capturas incluírem o widget"
        ],
        .screenshotPickableDetail: [
            "打开后窗口会沉到其他窗口后面；只截一次可用菜单栏的「为截图让路」",
            "開啟後視窗會沉到其他視窗後面；只截一次可用選單列的「為截圖讓路」",
            "The window then sits behind others; for a one-off use “Yield for screenshot”",
            "La fenêtre passe alors derrière les autres ; pour une fois, utilisez « Laisser passer la capture »",
            "켜면 창이 다른 창 뒤로 갑니다. 한 번만은 메뉴 막대의 '스크린샷 양보'를 쓰세요",
            "オンにするとウィンドウは他の後ろに下がります。一度だけならメニューバーの「スクリーンショットに譲る」を使ってください",
            "ستصبح النافذة خلف النوافذ الأخرى؛ للاستخدام لمرة واحدة استخدم «إفساح المجال للقطة الشاشة»",
            "La ventana queda detrás de las demás; para una sola vez usa «Ceder el paso a la captura»",
            "A janela fica atrás das outras; para uso único use «Dar passagem à captura»"
        ],
        .cadence: [
            "自动刷新间隔", "自動重新整理間隔", "Auto-refresh interval",
            "Intervalle d’actualisation", "자동 새로고침 간격", "自動更新の間隔",
            "فاصل التحديث التلقائي", "Intervalo de actualización", "Intervalo de atualização"
        ],
        .cadenceDetail: [
            "额度按分钟级变化，拉长可以省电",
            "額度以分鐘為單位變化，拉長可以省電",
            "Quota moves minute by minute; a longer interval saves power",
            "Le quota évolue minute par minute ; un intervalle plus long économise la batterie",
            "사용량은 분 단위로 바뀝니다. 간격을 늘리면 전력을 아낄 수 있습니다",
            "利用量は分単位で動きます。間隔を延ばすと省電力になります",
            "يتغير الحصة كل دقيقة؛ وزيادة الفاصل توفر الطاقة",
            "La cuota cambia cada minuto; un intervalo mayor ahorra energía",
            "A cota muda a cada minuto; um intervalo maior economiza energia"
        ],
        .appearance: [
            "外观", "外觀", "Appearance",
            "Apparence", "외형", "外観",
            "المظهر", "Apariencia", "Aparência"
        ],
        .appearanceDetail: [
            "跟随系统时会随 macOS 深色/浅色自动切换",
            "跟隨系統時會隨 macOS 深色/淺色自動切換",
            "Follows macOS light/dark appearance automatically",
            "Suit automatiquement le thème clair/sombre de macOS",
            "시스템 설정에 따라 밝은/어두운 모드로 자동 전환됩니다",
            "システムに合わせてライト/ダークを自動で切り替えます",
            "يتبع تلقائيًا المظهر الفاتح/الداكن في macOS",
            "Sigue automáticamente el modo claro/oscuro de macOS",
            "Segue automaticamente o modo claro/escuro do macOS"
        ],
        .statusStyle: [
            "菜单栏外观", "選單列外觀", "Menu bar style",
            "Style de la barre de menus", "메뉴 막대 스타일", "メニューバーのスタイル",
            "نمط شريط القوائم", "Estilo de la barra de menús", "Estilo da barra de menus"
        ],
        .hotKey: [
            "全局快捷键 ⌥⌘B", "全域快捷鍵 ⌥⌘B", "Global shortcut ⌥⌘B",
            "Raccourci global ⌥⌘B", "전체 단축키 ⌥⌘B", "グローバルショートカット ⌥⌘B",
            "اختصار عام ⌥⌘B", "Atajo global ⌥⌘B", "Atalho global ⌥⌘B"
        ],
        .hotKeyDetail: [
            "菜单栏图标被系统折叠时也能唤出悬浮窗",
            "選單列圖示被系統折疊時也能喚出懸浮窗",
            "Summons the widget even when the menu bar icon is hidden",
            "Rappelle le widget même si l’icône du menu est masquée",
            "메뉴 막대 아이콘이 숨겨져도 위젯을 불러올 수 있습니다",
            "メニューバーアイコンが隠れていてもウィジェットを呼び出せます",
            "يستدعي النافذة العائمة حتى عند إخفاء أيقونة شريط القوائم",
            "Abre el widget aunque el icono de la barra esté oculto",
            "Abre o widget mesmo com o ícone da barra oculto"
        ],
        .themeSystem: [
            "跟随系统", "跟隨系統", "Follow system",
            "Suivre le système", "시스템 따르기", "システムに合わせる",
            "اتباع النظام", "Seguir al sistema", "Seguir o sistema"
        ],
        .themeLight: ["浅色", "淺色", "Light", "Clair", "밝은 모드", "ライト", "فاتح", "Claro", "Claro"],
        .themeDark: ["深色", "深色", "Dark", "Sombre", "어두운 모드", "ダーク", "داكن", "Oscuro", "Escuro"],
        .badgeGlyphAndNumber: [
            "图标加数值", "圖示加數值", "Icon and number",
            "Icône et nombre", "아이콘 + 숫자", "アイコンと数値",
            "أيقونة ورقم", "Icono y número", "Ícone e número"
        ],
        .badgeNumberOnly: [
            "只显示数值", "只顯示數值", "Number only",
            "Nombre seulement", "숫자만", "数値のみ",
            "رقم فقط", "Solo número", "Somente número"
        ],
        .badgeGlyphOnly: [
            "只显示图标", "只顯示圖示", "Icon only",
            "Icône seulement", "아이콘만", "アイコンのみ",
            "أيقونة فقط", "Solo icono", "Somente ícone"
        ],
        .actionRefresh: [
            "马上读取", "馬上讀取", "Read now",
            "Lire maintenant", "지금 읽기", "今すぐ読み込む",
            "اقرأ الآن", "Leer ahora", "Ler agora"
        ],
        .actionTrend: [
            "历史趋势…", "歷史趨勢…", "History…",
            "Historique…", "추세 기록…", "履歴の推移…",
            "السجل…", "Historial…", "Histórico…"
        ],
        .actionUsagePage: [
            "打开用量网页", "開啟用量網頁", "Open usage page",
            "Ouvrir la page d’utilisation", "사용량 페이지 열기", "使用量ページを開く",
            "فتح صفحة الاستخدام", "Abrir página de uso", "Abrir página de uso"
        ],
        .actionRelogin: [
            "重新登录 ChatGPT", "重新登入 ChatGPT", "Sign in to ChatGPT again",
            "Se reconnecter à ChatGPT", "ChatGPT 다시 로그인", "ChatGPT に再ログイン",
            "تسجيل الدخول إلى ChatGPT مرة أخرى", "Volver a iniciar sesión en ChatGPT",
            "Iniciar sessão no ChatGPT novamente"
        ],
        .actionResetPosition: [
            "重置悬浮窗位置", "重置懸浮窗位置", "Reset widget position",
            "Réinitialiser la position du widget", "위젯 위치 초기화", "ウィジェット位置をリセット",
            "إعادة تعيين موضع النافذة العائمة", "Restablecer posición del widget",
            "Redefinir posição do widget"
        ],
        .settingsFooter: [
            "QuotaDock %@ · 本地读取额度，不上传账号信息",
            "QuotaDock %@ · 本機讀取額度，不上傳帳號資訊",
            "QuotaDock %@ · reads quota locally, never uploads account data",
            "QuotaDock %@ · lit le quota en local, aucune donnée de compte envoyée",
            "QuotaDock %@ · 사용량은 로컬에서 읽으며 계정 정보는 업로드하지 않습니다",
            "QuotaDock %@ · 利用量はローカルで読み取り、アカウント情報は送信しません",
            "QuotaDock %@ · يقرأ الحصة محليًا ولا يرفع بيانات الحساب",
            "QuotaDock %@ · lee la cuota localmente y no sube datos de la cuenta",
            "QuotaDock %@ · lê a cota localmente e não envia dados da conta"
        ],
        // 非激活窗口的控件会被系统去饱和渲染，容易被当成"状态丢了"
        .settingsInactiveHint: [
            "窗口未激活时控件会变灰，这是 macOS 的正常渲染，点一下窗口即可恢复",
            "視窗未啟用時控制項會變灰，這是 macOS 的正常呈現，點一下視窗即可恢復",
            "Controls turn grey while the window is inactive: that's normal macOS behaviour. Click the window to restore.",
            "Les contrôles grisent quand la fenêtre est inactive : c’est normal sous macOS. Cliquez dans la fenêtre.",
            "창이 비활성일 때 컨트롤이 회색으로 보이는 것은 macOS의 정상 동작입니다. 창을 클릭하면 돌아옵니다.",
            "ウインドウが非アクティブのときコントロールが灰色になるのは macOS の正常な表示です。クリックで戻ります。",
            "تبهت عناصر التحكم عندما تكون النافذة غير نشطة، وهذا سلوك macOS الطبيعي. انقر النافذة لتعود.",
            "Los controles se ven grises cuando la ventana no está activa: es normal en macOS. Haz clic en la ventana.",
            "Os controles ficam acinzentados quando a janela não está ativa: é normal no macOS. Clique na janela."
        ],

        // MARK 菜单栏
        .menuCollapse: [
            "收起悬浮窗", "收起懸浮窗", "Hide floating widget",
            "Masquer le widget flottant", "플로팅 위젯 숨기기", "フローティングウィジェットを隠す",
            "إخفاء النافذة العائمة", "Ocultar widget flotante", "Ocultar widget flutuante"
        ],
        .menuExpand: [
            "展开悬浮窗", "展開懸浮窗", "Show floating widget",
            "Afficher le widget flottant", "플로팅 위젯 보이기", "フローティングウィジェットを表示",
            "إظهار النافذة العائمة", "Mostrar widget flotante", "Mostrar widget flutuante"
        ],
        .menuRefresh: [
            "马上读取", "馬上讀取", "Read now",
            "Lire maintenant", "지금 읽기", "今すぐ読み込む",
            "اقرأ الآن", "Leer ahora", "Ler agora"
        ],
        .menuUsagePage: [
            "打开用量网页", "開啟用量網頁", "Open usage page",
            "Ouvrir la page d’utilisation", "사용량 페이지 열기", "使用量ページを開く",
            "فتح صفحة الاستخدام", "Abrir página de uso", "Abrir página de uso"
        ],
        .menuTrend: [
            "历史趋势…", "歷史趨勢…", "History…",
            "Historique…", "추세 기록…", "履歴の推移…",
            "السجل…", "Historial…", "Histórico…"
        ],
        .menuSignIn: [
            "登录 ChatGPT…", "登入 ChatGPT…", "Sign in to ChatGPT…",
            "Se connecter à ChatGPT…", "ChatGPT 로그인…", "ChatGPT にログイン…",
            "تسجيل الدخول إلى ChatGPT…", "Iniciar sesión en ChatGPT…", "Iniciar sessão no ChatGPT…"
        ],
        .menuReSignIn: [
            "重新登录 ChatGPT…", "重新登入 ChatGPT…", "Sign in to ChatGPT again…",
            "Se reconnecter à ChatGPT…", "ChatGPT 다시 로그인…", "ChatGPT に再ログイン…",
            "تسجيل الدخول إلى ChatGPT مرة أخرى…", "Volver a iniciar sesión en ChatGPT…",
            "Iniciar sessão no ChatGPT novamente…"
        ],
        .menuAutoStart: [
            "开机自动运行", "開機自動執行", "Launch at login",
            "Ouvrir au démarrage", "로그인 시 실행", "ログイン時に起動",
            "التشغيل عند تسجيل الدخول", "Iniciar al iniciar sesión", "Iniciar ao entrar"
        ],
        .menuYieldForCapture: [
            "为截图让路（12 秒）", "為截圖讓路（12 秒）", "Yield for screenshot (12s)",
            "Laisser passer la capture (12 s)", "스크린샷에 양보(12초)",
            "スクリーンショットに譲る（12 秒）", "إفساح المجال للقطة الشاشة (١٢ ثانية)",
            "Ceder el paso a la captura (12 s)", "Dar passagem à captura (12 s)"
        ],
        .menuPreferences: [
            "设置…", "設定…", "Settings…",
            "Réglages…", "설정…", "設定…",
            "الإعدادات…", "Ajustes…", "Ajustes…"
        ],
        .menuQuit: [
            "退出 QuotaDock", "退出 QuotaDock", "Quit QuotaDock",
            "Quitter QuotaDock", "QuotaDock 종료", "QuotaDock を終了",
            "إنهاء QuotaDock", "Salir de QuotaDock", "Sair do QuotaDock"
        ],
        .statusNoAccount: [
            "还没有连接账号", "還沒有連接帳號", "No account connected",
            "Aucun compte connecté", "계정이 연결되지 않았습니다", "アカウント未接続",
            "لا حساب متصل", "Sin cuenta conectada", "Nenhuma conta conectada"
        ],
        .statusReadFailed: [
            "额度读取失败", "額度讀取失敗", "Could not read quota",
            "Lecture du quota impossible", "사용량을 읽을 수 없습니다", "利用量を読み取れません",
            "تعذرت قراءة الحصة", "No se pudo leer la cuota", "Não foi possível ler a cota"
        ],
        .statusReading: [
            "正在读取额度", "正在讀取額度", "Reading quota",
            "Lecture du quota…", "사용량 읽는 중", "利用量を読み込み中",
            "جارٍ قراءة الحصة", "Leyendo la cuota", "Lendo a cota"
        ],
        .gaugeRemaining: [
            "剩余 %d%%", "剩餘 %d%%", "%d%% left",
            "%d%% restants", "%d%% 남음", "残り %d%%",
            "المتبقي %d%%", "Queda %d%%", "Restam %d%%"
        ],
        .gaugeUnknown: [
            "用量未知", "用量未知", "Usage unknown",
            "Utilisation inconnue", "사용량 알 수 없음", "使用量不明",
            "استخدام غير معروف", "Uso desconocido", "Uso desconhecido"
        ],

        // MARK 悬浮窗
        .planPreview: [
            "演示", "演示", "Demo",
            "Démo", "데모", "デモ",
            "تجريبي", "Demo", "Demo"
        ],
        .emptyNoData: [
            "还没有额度数据", "還沒有額度資料", "No quota data yet",
            "Pas encore de quota", "아직 사용량 데이터가 없습니다", "利用量データがありません",
            "لا توجد بيانات حصة بعد", "Aún sin datos de cuota", "Sem dados de cota ainda"
        ],
        .emptyRetryLater: [
            "下一轮会自动重试", "下一輪會自動重試", "Will retry on the next cycle",
            "Nouvelle tentative au prochain cycle", "다음 주기에 다시 시도합니다",
            "次の周期で再試行します", "ستتم إعادة المحاولة في الدورة التالية",
            "Se reintentará en el siguiente ciclo", "Tentará novamente no próximo ciclo"
        ],
        .wakingTitle: [
            "正在连接额度服务", "正在連接額度服務", "Connecting to quota service",
            "Connexion au service de quota", "사용량 서비스에 연결 중", "利用量サービスに接続中",
            "جارٍ الاتصال بخدمة الحصة", "Conectando al servicio de cuota", "Conectando ao serviço de cota"
        ],
        .wakingDetail: [
            "账号凭据只留在本机", "帳號憑證只留在本機", "Credentials stay on this Mac",
            "Les identifiants restent sur ce Mac", "자격 증명은 이 Mac에만 보관됩니다",
            "認証情報はこの Mac だけに保存されます", "تبقى بيانات الحساب على هذا الجهاز فقط",
            "Las credenciales se quedan en este Mac", "As credenciais ficam neste Mac"
        ],
        .signInTitle: [
            "先连接 ChatGPT", "先連接 ChatGPT", "Connect ChatGPT first",
            "Connectez d’abord ChatGPT", "먼저 ChatGPT를 연결하세요", "先に ChatGPT を接続",
            "اربط ChatGPT أولاً", "Conecta primero ChatGPT", "Conecte primeiro o ChatGPT"
        ],
        .signInDetail: [
            "右键菜单栏图标继续", "右鍵選單列圖示繼續",
            "Right-click the menu bar icon to continue",
            "Clic droit sur l’icône du menu pour continuer",
            "메뉴 막대 아이콘을 오른쪽 클릭해 계속하세요",
            "メニューバーアイコンを右クリックして続行",
            "انقر بزر الماوس الأيمن على أيقونة الشريط للمتابعة",
            "Haz clic derecho en el icono de la barra para continuar",
            "Clique com o botão direito no ícone da barra para continuar"
        ],
        .primingTitle: [
            "正在取额度", "正在取額度", "Fetching quota",
            "Récupération du quota", "사용량 가져오는 중", "利用量を取得中",
            "جارٍ جلب الحصة", "Obteniendo la cuota", "Obtendo a cota"
        ],
        .primingDetail: [
            "第一次会慢几秒", "第一次會慢幾秒", "First run takes a few seconds",
            "La première fois prend quelques secondes", "처음에는 몇 초 걸립니다",
            "初回は数秒かかります", "أول مرة تستغرق ثوانٍ قليلة",
            "La primera vez tarda unos segundos", "A primeiro vez leva alguns segundos"
        ],
        .failedTitle: [
            "额度读取失败", "額度讀取失敗", "Could not read quota",
            "Lecture du quota impossible", "사용량을 읽을 수 없습니다", "利用量を読み取れません",
            "تعذرت قراءة الحصة", "No se pudo leer la cuota", "Não foi possível ler a cota"
        ],
        .failedDetail: [
            "右键菜单可重试", "右鍵選單可重試", "Right-click menu to retry",
            "Menu clic droit pour réessayer", "오른쪽 클릭 메뉴에서 다시 시도",
            "右クリックメニューで再試行", "قائمة النقر الأيمن لإعادة المحاولة",
            "Menú contextual para reintentar", "Menu de contexto para tentar de novo"
        ],

        // MARK 消耗预测
        .estimateCollecting: [
            "正在积累采样", "正在累積取樣", "Collecting samples",
            "Collecte d’échantillons", "샘플 수집 중", "サンプル収集中",
            "جارٍ جمع العينات", "Recopilando muestras", "Coletando amostras"
        ],
        .estimateSteady: [
            "这段没怎么消耗", "這段沒怎麼消耗", "Barely moving",
            "Peu de consommation", "거의 소진되지 않음", "ほとんど消費なし",
            "لا استهلاك يُذكر", "Apenas se consume", "Quase sem consumo"
        ],
        .estimateExhausted: [
            "额度已耗尽", "額度已耗盡", "Quota exhausted",
            "Quota épuisé", "사용량 소진", "利用量を使い切りました",
            "انتهت الحصة", "Cuota agotada", "Cota esgotada"
        ],
        .estimateBeforeReset: [
            "重置前不会耗尽", "重置前不會耗盡", "Safe until reset",
            "OK jusqu’à la réinit.", "재설정 전 소진 없음",
            "リセット前は枯渇なし", "لن ينفد قبل إعادة التعيين",
            "No se agota antes", "Não esgota antes"
        ],
        // 别的档位先归零（通常是周额度），这一档会跟着一起归零：时间以它为准
        .estimateSharedExhaust: [
            "%@ 后随%@耗尽", "%@ 後隨%@耗盡", "%@ · %@ empties first",
            "%@ · %@ à sec d’abord", "%@ 후 %@ 소진", "%@ 後 %@ も枯渇",
            "%@ · نفاد %@ أولاً", "%@ · %@ se agota antes", "%@ · %@ esgota antes"
        ],
        .estimateFalling: [
            "预计 %@ 后耗尽", "預計 %@ 後耗盡", "Runs out in %@",
            "Épuisé dans %@", "%@ 후 소진", "あと%@で枯渇",
            "ينفد بعد %@", "Se agota en %@", "Esgota em %@"
        ],
        .footerAutoRefresh: [
            "自动刷新 %ds", "自動重新整理 %ds", "Auto-refresh %ds",
            "Actualisation %d s", "자동 새로고침 %d초", "自動更新 %d秒",
            "تحديث تلقائي %d ث", "Actualización %d s", "Atualização %d s"
        ],
        .footerOffline: [
            "离线 · 上次数据", "離線 · 上次資料", "Offline · last data",
            "Hors ligne · dernières données", "오프라인 · 마지막 데이터",
            "オフライン · 前回のデータ", "غير متصل · آخر بيانات",
            "Sin conexión · últimos datos", "Offline · últimos dados"
        ],
        .footerPreview: [
            "示例数据", "範例資料", "Sample data",
            "Données d’exemple", "샘플 데이터", "サンプルデータ",
            "بيانات تجريبية", "Datos de ejemplo", "Dados de exemplo"
        ],
        .lastReset: [
            "上次重置：%@前", "上次重置：%@前", "Last reset: %@ ago",
            "Dernière réinit. il y a %@", "마지막 재설정: %@ 전",
            "最終リセット：%@前", "آخر إعادة تعيين: قبل %@",
            "Último restablecimiento: hace %@", "Última redefinição: há %@"
        ],
        .resetCountdown: [
            "%@ 后重置", "%@ 後重置", "resets in %@",
            "réinit. dans %@", "%@ 후 재설정", "あと%@でリセット",
            "إعادة التعيين بعد %@", "reinicia en %@", "redefine em %@"
        ],
        .resetImminent: [
            "马上重置", "馬上重置", "resetting now",
            "réinitialisation immédiate", "곧 재설정", "すぐリセット",
            "إعادة التعيين الآن", "se restablece ahora", "redefinindo agora"
        ],

        // MARK 额度窗口
        .quotaPlain: [
            "额度", "額度", "Quota",
            "Quota", "사용량", "利用量",
            "الحصة", "Cuota", "Cota"
        ],
        .quotaWeekly: [
            "周额度", "週額度", "Weekly quota",
            "Quota hebdomadaire", "주간 사용량", "週あたり利用量",
            "الحصة الأسبوعية", "Cuota semanal", "Cota semanal"
        ],
        .quotaWeeks: [
            "%d 周额度", "%d 週額度", "%d-week quota",
            "Quota de %d semaines", "%d주 사용량", "%d週あたり利用量",
            "حصة %d أسابيع", "Cuota de %d semanas", "Cota de %d semanas"
        ],
        .quotaHours: [
            "%d 小时额度", "%d 小時額度", "%d-hour quota",
            "Quota de %d heures", "%d시간 사용량", "%d時間あたり利用量",
            "حصة %d ساعات", "Cuota de %d horas", "Cota de %d horas"
        ],
        .quotaMinutes: [
            "%d 分钟额度", "%d 分鐘額度", "%d-minute quota",
            "Quota de %d minutes", "%d분 사용량", "%d分あたり利用量",
            "حصة %d دقائق", "Cuota de %d minutos", "Cota de %d minutos"
        ],
        .rowWeekly: [
            "周额度", "週額度", "Weekly",
            "Hebdo", "주간", "週あたり",
            "أسبوعي", "Semanal", "Semanal"
        ],
        .rowHours: [
            "%d 小时", "%d 小時", "%dh",
            "%d h", "%d시간", "%d時間",
            "%d س", "%d h", "%d h"
        ],
        .rowMinutes: [
            "%d 分钟", "%d 分鐘", "%dm",
            "%d min", "%d분", "%d分",
            "%d د", "%d min", "%d min"
        ],
        .shortWeekly: [
            "周", "週", "W",
            "S", "주", "週",
            "أ", "S", "S"
        ],
        .shortHours: ["%dh", "%dh", "%dh", "%dh", "%dh", "%dh", "%dh", "%dh", "%dh"],
        .shortMinutes: ["%dm", "%dm", "%dm", "%dm", "%dm", "%dm", "%dm", "%dm", "%dm"],

        // MARK 趋势图
        .trendTitle: [
            "额度历史趋势", "額度歷史趨勢", "Quota history",
            "Historique du quota", "사용량 추세", "利用量の推移",
            "سجل الحصة", "Historial de cuota", "Histórico da cota"
        ],
        .trendHint: [
            "双指左右滑 / ←→ 平移 · 双指捏合 / ⌥滚轮 缩放 · 双击触控板全览",
            "雙指左右滑 / ←→ 平移 · 雙指捏合 / ⌥滾輪 縮放 · 雙擊觸控板全覽",
            "Swipe or ←→ to pan · pinch or ⌥-scroll to zoom · double-tap to fit all",
            "Glissez ou ←→ pour déplacer · pincez ou ⌥-molette pour zoomer · double-clic pour tout voir",
            "스와이프 또는 ←→ 이동 · 핀치 또는 ⌥ 스크롤 확대 · 트랙패드 두 번 탭으로 전체 보기",
            "スワイプ/←→で移動・ピンチ/⌥スクロールで拡大・ダブルタップで全体表示",
            "اسحب أو ←→ للتنقل · اقرص أو ⌥ مع العجلة للتكبير · انقر نقرًا مزدوجًا لعرض الكل",
            "Desliza o ←→ para mover · pinza o ⌥-rueda para zoom · doble toque para ver todo",
            "Arraste ou ←→ para mover · pinça ou ⌥-roda para zoom · toque duplo para ver tudo"
        ],
        .trendFitAll: [
            "全览", "全覽", "Fit all",
            "Tout voir", "전체 보기", "全体表示",
            "عرض الكل", "Ver todo", "Ver tudo"
        ],
        .trendBackToNow: [
            "回到现在", "回到現在", "Back to now",
            "Revenir à maintenant", "지금으로", "現在に戻る",
            "العودة إلى الآن", "Volver al presente", "Voltar para agora"
        ],
        .trendDataFolder: [
            "数据文件夹", "資料檔案夾", "Data folder",
            "Dossier de données", "데이터 폴더", "データフォルダ",
            "مجلد البيانات", "Carpeta de datos", "Pasta de dados"
        ],
        .plotEmptyTitle: [
            "正在读取历史数据…", "正在讀取歷史資料…", "Loading history…",
            "Chargement de l’historique…", "기록을 불러오는 중…", "履歴を読み込み中…",
            "جارٍ تحميل السجل…", "Cargando historial…", "Carregando histórico…"
        ],
        .plotEmptyDetail: [
            "程序每分钟记录一次额度，数据只保存在本机",
            "程式每分鐘記錄一次額度，資料只儲存在本機",
            "Quota is sampled every minute and stored only on this Mac",
            "Le quota est relevé chaque minute et stocké uniquement sur ce Mac",
            "사용량은 1분마다 기록되며 이 Mac에만 저장됩니다",
            "利用量は毎分記録され、この Mac だけに保存されます",
            "تُسجّل الحصة كل دقيقة وتُخزَّن على هذا الجهاز فقط",
            "La cuota se registra cada minuto y se guarda solo en este Mac",
            "A cota é registrada a cada minuto e salva só neste Mac"
        ],
        .plotSparseHint: [
            "已记录 %d 个采样点，程序每分钟记一次，连起来就有了曲线",
            "已記錄 %d 個取樣點，程式每分鐘記一次，連起來就有了曲線",
            "%d samples so far — one per minute; the curve grows from here",
            "%d relevés pour l’instant — un par minute ; la courbe se dessine ensuite",
            "%d개 샘플 기록됨 — 1분에 한 번, 곧 곡선이 이어집니다",
            "%d 件のサンプルを記録 — 1 分ごとに 1 件、つながると曲線になります",
            "تم تسجيل %d عينة — واحدة كل دقيقة؛ سيتشكل المنحنى تدريجيًا",
            "%d muestras hasta ahora — una por minuto; la curva crecerá",
            "%d amostras até agora — uma por minuto; a curva vai se formar"
        ],
        .plotBottomOut: [
            "见底 %@", "見底 %@", "empty %@",
            "à sec %@", "소진 %@", "枯渇 %@",
            "نفاد %@", "agota %@", "esgota %@"
        ],
        .plotSpan: [
            "跨度 %@", "跨度 %@", "Span %@",
            "Portée %@", "범위 %@", "範囲 %@",
            "المدى %@", "Rango %@", "Intervalo %@"
        ],
        .plotForecast: [
            "预测", "預測", "forecast",
            "prévision", "예측", "予測",
            "توقع", "previsión", "previsão"
        ],
        .plotResetMoment: [
            "重置时刻", "重置時刻", "reset",
            "réinitialisation", "재설정", "リセット",
            "إعادة تعيين", "restablecimiento", "redefinição"
        ],
        .plotNextReset: [
            "距重置 %@", "距重置 %@", "%@ to reset",
            "réinit. dans %@", "재설정까지 %@", "リセットまで %@",
            "إعادة التعيين بعد %@", "reinicia en %@", "redefine em %@"
        ],
        .plotLastReset: [
            "上次重置：%@前", "上次重置：%@前", "Last reset: %@ ago",
            "Dernière réinit. : il y a %@", "마지막 재설정: %@ 전",
            "最終リセット：%@前", "آخر إعادة تعيين: قبل %@",
            "Último restablecimiento: hace %@", "Última redefinição: há %@"
        ],

        // MARK 通知
        .notifyLowTitle: [
            "%@偏低", "%@偏低", "%@ running low",
            "%@ presque épuisé", "%@ 부족", "%@ が低下",
            "%@ منخفض", "%@ casi agotado", "%@ quase esgotado"
        ],
        .notifyLowBody: [
            "只剩 %d%%，%@ 重置。", "只剩 %d%%，%@ 重置。",
            "Only %d%% left, resets at %@.",
            "Plus que %d %%, réinitialisation à %@.",
            "%d%%만 남음, %@에 재설정됩니다.",
            "残り %d%%、%@ にリセットされます。",
            "المتبقي %d%% فقط، وإعادة التعيين %@.",
            "Solo queda %d%%, se restablece a las %@.",
            "Restam apenas %d%%, redefine às %@."
        ],
        .notifyResetTitle: [
            "%@已重置", "%@已重置", "%@ renewed",
            "%@ réinitialisé", "%@ 재설정됨", "%@ がリセットされました",
            "تمت إعادة تعيين %@", "%@ restablecido", "%@ redefinido"
        ],
        .notifyResetBody: [
            "已恢复，当前 %d%%。", "已恢復，目前 %d%%。",
            "Restored, now at %d%.",
            "Rétabli, à %d %% actuellement.",
            "복구됨, 현재 %d%%.",
            "回復しました。現在 %d%% です。",
            "تمت الاستعادة، والحصة الآن %d%%.",
            "Restaurado, ahora %d%%.",
            "Restaurado, agora %d%%."
        ],
        .notifyPermissionOff: [
            "通知权限已关闭，请在系统设置中重新允许 QuotaDock 通知。",
            "通知權限已關閉，請在系統設定中重新允許 QuotaDock 通知。",
            "Notifications are off. Allow QuotaDock again in System Settings.",
            "Les notifications sont désactivées. Réautorisez QuotaDock dans les Réglages système.",
            "알림 권한이 꺼져 있습니다. 시스템 설정에서 QuotaDock 알림을 다시 허용하세요.",
            "通知権限がオフです。システム設定で QuotaDock の通知を再許可してください。",
            "أشعار QuotaDock معطلة. أعد السماح بها في إعدادات النظام.",
            "Las notificaciones están desactivadas. Vuelve a permitir QuotaDock en Ajustes del Sistema.",
            "As notificações estão desativadas. Permita o QuotaDock novamente em Ajustes do Sistema."
        ],
        .notifyNotGranted: [
            "通知权限未开启，QuotaDock 不会发送额度提醒。",
            "通知權限未開啟，QuotaDock 不會發送額度提醒。",
            "Notification permission not granted — QuotaDock won’t send alerts.",
            "Autorisation non accordée — QuotaDock n’enverra pas d’alertes.",
            "알림 권한이 없어 사용량 알림을 보내지 않습니다.",
            "通知が許可されていないため、利用量アラートは送信されません。",
            "لم يُمنح إذن الإشعارات، لن يرسل QuotaDock تنبيهات.",
            "Permiso de notificaciones no concedido: QuotaDock no enviará avisos.",
            "Permissão de notificações não concedida: o QuotaDock não enviará avisos."
        ],
        .notifyFailed: [
            "无法启用系统通知。请打开系统通知设置，允许 QuotaDock 通知后再试。",
            "無法啟用系統通知。請開啟系統通知設定，允許 QuotaDock 通知後再試。",
            "Could not enable notifications. Allow QuotaDock in System Settings, then try again.",
            "Impossible d’activer les notifications. Autorisez QuotaDock dans les Réglages système.",
            "알림을 켤 수 없습니다. 시스템 설정에서 QuotaDock 알림을 허용한 뒤 다시 시도하세요.",
            "通知を有効にできません。システム設定で QuotaDock の通知を許可してから再試行してください。",
            "تعذر تمكين الإشعارات. اسمح بـ QuotaDock في إعدادات النظام ثم أعد المحاولة.",
            "No se pudieron activar las notificaciones. Permite QuotaDock en Ajustes del Sistema.",
            "Não foi possível ativar notificações. Permita o QuotaDock em Ajustes do Sistema."
        ],
        .notifyFailedByPolicy: [
            "macOS 当前未允许 QuotaDock 请求通知权限。请打开系统通知设置，允许 QuotaDock 通知后再试。",
            "macOS 目前未允許 QuotaDock 請求通知權限。請開啟系統通知設定，允許 QuotaDock 通知後再試。",
            "macOS is not allowing QuotaDock to request notification permission. Allow it in System Settings, then try again.",
            "macOS n’autorise pas QuotaDock à demander l’autorisation. Autorisez-le dans les Réglages système.",
            "macOS가 QuotaDock의 알림 권한 요청을 허용하지 않습니다. 시스템 설정에서 허용한 뒤 다시 시도하세요.",
            "macOS が QuotaDock の通知権限要求を許可していません。システム設定で許可してから再試行してください。",
            "لا يسمح macOS لـ QuotaDock بطلب إذن الإشعارات. اسمح به في إعدادات النظام ثم أعد المحاولة.",
            "macOS no permite que QuotaDock pida permiso de notificaciones. Permítelo en Ajustes del Sistema.",
            "O macOS não permite que o QuotaDock peça permissão de notificações. Permita em Ajustes do Sistema."
        ],

        // MARK 解析
        .decodeInvalid: [
            "额度数据格式无法识别。", "額度資料格式無法辨識。",
            "The quota payload could not be recognised.",
            "Le format des données de quota est méconnu.",
            "사용량 데이터 형식을 인식할 수 없습니다.",
            "利用量データの形式を判別できません。",
            "تعذر التعرف على تنسيق بيانات الحصة.",
            "No se reconoció el formato de los datos de cuota.",
            "Não foi possível reconhecer o formato dos dados de cota."
        ],
        .decodeEmpty: [
            "当前账户没有返回可显示的额度。", "目前帳號沒有回傳可顯示的額度。",
            "This account returned no quota to display.",
            "Ce compte n’a renvoyé aucun quota affichable.",
            "이 계정에는 표시할 사용량이 없습니다.",
            "このアカウントは表示できる利用量を返しませんでした。",
            "لم يُرجع هذا الحساب أي حصة قابلة للعرض.",
            "Esta cuenta no devolvió ninguna cuota para mostrar.",
            "Esta conta não retornou nenhuma cota para exibir."
        ]
    ]
}

extension Notification.Name {
    static let languageChanged = Localization.didChange
}
