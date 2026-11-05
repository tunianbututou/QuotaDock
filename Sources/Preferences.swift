import Combine
import Foundation

extension Notification.Name {
    /// 刷新间隔改了（轮询任务据此换档）
    static let cadenceChanged = Notification.Name("com.quotadock.cadenceChanged")
    /// 全局快捷键开关改了（菜单栏控制器据此注册/注销）
    static let hotKeyPreferenceChanged = Notification.Name("com.quotadock.hotKeyChanged")
    /// 系统截图界面出现 / 消失（伴生窗口据此降级、回位）
    static let captureYieldChanged = Notification.Name("com.quotadock.captureYield")
    /// 「辅助窗口置顶」开关改了（设置页 / 趋势图据此换层级）
    static let companionLevelChanged = Notification.Name("com.quotadock.companionLevel")
}

@MainActor final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var showWidget: Bool {
        didSet { store.set(showWidget, forKey: Slot.showWidget) }
    }

    @Published var widgetOnEverySpace: Bool {
        didSet { store.set(widgetOnEverySpace, forKey: Slot.widgetOnEverySpace) }
    }

    @Published var badgeStyle: BadgeStyle {
        didSet { store.set(badgeStyle.rawValue, forKey: Slot.badgeStyle) }
    }

    @Published var hotKeyEnabled: Bool {
        didSet { store.set(hotKeyEnabled, forKey: Slot.hotKeyEnabled) }
    }

    @Published var alertsEnabled: Bool {
        didSet { store.set(alertsEnabled, forKey: Slot.alertsEnabled) }
    }

    @Published var warnBelowPercent: Int {
        didSet { store.set(warnBelowPercent, forKey: Slot.warnBelowPercent) }
    }

    @Published var announceResets: Bool {
        didSet { store.set(announceResets, forKey: Slot.announceResets) }
    }

    @Published var checkForUpdates: Bool {
        didSet { store.set(checkForUpdates, forKey: Slot.checkForUpdates) }
    }

    @Published var cadenceSeconds: Int {
        didSet { store.set(cadenceSeconds, forKey: Slot.cadenceSeconds) }
    }

    @Published var themeMode: ThemeMode {
        didSet { store.set(themeMode.rawValue, forKey: Slot.themeMode) }
    }

    /// 界面语言。改一次就广播，自绘窗口据此重画。
    @Published var language: AppLanguage {
        didSet {
            store.set(language.rawValue, forKey: Slot.language)
            Localization.apply(language)
        }
    }

    /// 悬浮窗是否允许被系统截图（⌘⇧4 → 空格）选中。
    /// 系统截图只列出普通层级的窗口，置顶浮窗选不中；打开后窗口会降到普通层级，
    /// 代价是会沉到其他 App 窗口后面。
    @Published var screenshotPickable: Bool {
        didSet { store.set(screenshotPickable, forKey: Slot.screenshotPickable) }
    }

    /// 设置页 / 趋势图是否强制浮在其他窗口之上。
    /// 默认关：这两个页面是普通窗口，能被别的 App 正常盖住。
    @Published var companionOnTop: Bool {
        didSet {
            store.set(companionOnTop, forKey: Slot.companionOnTop)
            NotificationCenter.default.post(name: .companionLevelChanged, object: nil)
        }
    }

    private let store: UserDefaults

    private enum Slot {
        static let showWidget = "showWidget"
        static let widgetOnEverySpace = "widgetOnEverySpace"
        static let badgeStyle = "badgeStyle"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let alertsEnabled = "alertsEnabled"
        static let warnBelowPercent = "warnBelowPercent"
        static let announceResets = "announceResets"
        static let checkForUpdates = "checkForUpdates"
        static let cadenceSeconds = "cadenceSeconds"
        static let themeMode = "themeMode"
        static let screenshotPickable = "screenshotPickable"
        static let language = Localization.Slot.language
        static let companionOnTop = "companionOnTop"
    }

    private init(backing: UserDefaults = .standard) {
        store = backing
        store.register(defaults: [
            Slot.showWidget: DefaultValues.showWidget,
            Slot.widgetOnEverySpace: DefaultValues.widgetOnEverySpace,
            Slot.badgeStyle: DefaultValues.badgeStyle.rawValue,
            Slot.hotKeyEnabled: DefaultValues.hotKeyEnabled,
            Slot.alertsEnabled: DefaultValues.alertsEnabled,
            Slot.warnBelowPercent: DefaultValues.warnBelowPercent,
            Slot.announceResets: DefaultValues.announceResets,
            Slot.checkForUpdates: DefaultValues.checkForUpdates,
            Slot.cadenceSeconds: DefaultValues.cadenceSeconds,
            Slot.themeMode: DefaultValues.themeMode.rawValue,
            Slot.screenshotPickable: DefaultValues.screenshotPickable,
            Slot.language: AppLanguage.fallback.rawValue,
            Slot.companionOnTop: DefaultValues.companionOnTop
        ])

        showWidget = store.bool(forKey: Slot.showWidget)
        widgetOnEverySpace = store.bool(forKey: Slot.widgetOnEverySpace)
        badgeStyle = BadgeStyle(
            rawValue: store.string(forKey: Slot.badgeStyle) ?? ""
        ) ?? DefaultValues.badgeStyle
        hotKeyEnabled = store.bool(forKey: Slot.hotKeyEnabled)
        alertsEnabled = store.bool(forKey: Slot.alertsEnabled)
        warnBelowPercent = store.integer(forKey: Slot.warnBelowPercent)
        announceResets = store.bool(forKey: Slot.announceResets)
        checkForUpdates = store.bool(forKey: Slot.checkForUpdates)
        let storedInterval = store.integer(forKey: Slot.cadenceSeconds)
        cadenceSeconds = DefaultValues.cadenceChoices.contains(storedInterval)
            ? storedInterval
            : DefaultValues.cadenceSeconds
        themeMode = ThemeMode(
            rawValue: store.string(forKey: Slot.themeMode) ?? ""
        ) ?? DefaultValues.themeMode
        screenshotPickable = store.bool(forKey: Slot.screenshotPickable)
        language = AppLanguage(
            rawValue: store.string(forKey: Slot.language) ?? ""
        ) ?? AppLanguage.fallback
        // 本地化层自己读的是 UserDefaults，这里把最终值同步过去（默认值刚注册完才有）
        Localization.apply(
            AppLanguage(rawValue: store.string(forKey: Slot.language) ?? "") ?? AppLanguage.fallback
        )
        companionOnTop = store.bool(forKey: Slot.companionOnTop)
    }
}
