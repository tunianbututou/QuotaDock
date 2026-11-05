import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

/// 菜单栏那一格：图标 + 数字、右键菜单、以及 ⌥⌘B 全局快捷键。
/// 它不持有任何额度状态，读到的都是 QuotaStream / Preferences 的即时值。
@MainActor final class StatusBarHost: NSObject, NSMenuDelegate {

    /// 菜单里的一项：标题、动作、快捷键、勾选与可用状态都写在一处，省得下面几十行重复劳动
    private struct Entry {
        var title: String
        var action: Selector
        var key: String = ""
        var checked: Bool = false
        var enabled: Bool = true
    }

    private let slot = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stream = QuotaStream.shared
    private let widget: WidgetHost
    private var bag: Set<AnyCancellable> = []
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyTrap: EventHandlerRef?

    /// ⌥⌘B：菜单栏图标被系统折叠进「»」时，这是唯一可靠的唤出方式
    private static let hotKeyCode = UInt32(kVK_ANSI_B)
    private static let hotKeyModifiers = UInt32(optionKey | cmdKey)
    /// 'QDOK'
    private static let hotKeySignature = OSType(0x5144_4F4B)

    init(widget: WidgetHost) {
        self.widget = widget
        super.init()

        dress()
        watchState()
        repaint()
        applyHotKeyPreference()

        let onHotKeyChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotKeyPreference() }
        }
        NotificationCenter.default.addObserver(
            forName: .hotKeyPreferenceChanged, object: nil, queue: .main, using: onHotKeyChange
        )
    }

    /// 图标那格的固定装饰，装一次就够
    private func dress() {
        guard let face = slot.button else { return }
        face.target = self
        face.action = #selector(handleClick(_:))
        face.sendAction(on: [.leftMouseUp, .rightMouseUp])
        face.imagePosition = .imageLeading
        face.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        face.toolTip = "QuotaDock"
    }

    /// 额度或偏好一动就重画；`objectWillChange` 发在变更之前，绕一圈回到主 RunLoop 才是新值
    private func watchState() {
        for publisher in [stream.objectWillChange, Preferences.shared.objectWillChange] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.repaint() }
                .store(in: &bag)
        }
    }

    // MARK: 全局快捷键

    private func applyHotKeyPreference() {
        if Preferences.shared.hotKeyEnabled {
            armHotKey()
        } else {
            disarmHotKey()
        }
    }

    private func armHotKey() {
        guard hotKeyRef == nil else { return }

        let appTarget = GetApplicationEventTarget()

        if hotKeyTrap == nil {
            var spec = EventTypeSpec()
            spec.eventClass = OSType(kEventClassKeyboard)
            spec.eventKind = UInt32(kEventHotKeyPressed)
            let context = Unmanaged.passUnretained(self).toOpaque()
            // Carbon 的 C 回调固定在主线程，所以可以直接认领 MainActor
            let trampoline: EventHandlerUPP = { _, _, raw in
                guard let raw else { return OSStatus(eventNotHandledErr) }
                let host = Unmanaged<StatusBarHost>.fromOpaque(raw).takeUnretainedValue()
                MainActor.assumeIsolated { host.hotKeyFired() }
                return noErr
            }
            InstallEventHandler(appTarget, trampoline, 1, &spec, context, &hotKeyTrap)
        }

        var fresh: EventHotKeyRef?
        let ident = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let outcome = RegisterEventHotKey(
            Self.hotKeyCode, Self.hotKeyModifiers, ident, appTarget, 0, &fresh
        )
        if outcome == noErr { hotKeyRef = fresh }
    }

    private func disarmHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let hotKeyTrap {
            RemoveEventHandler(hotKeyTrap)
            self.hotKeyTrap = nil
        }
    }

    fileprivate func hotKeyFired() {
        widget.toggle()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let isSecondary = NSApp.currentEvent?.type == .rightMouseUp
        if isSecondary {
            popMenu(from: sender)
        } else {
            widget.toggle()
        }
    }

    // MARK: 右键菜单

    private func popMenu(from face: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        for group in menuLayout {
            menu.addItem(NSMenuItem.separator())
            for entry in group {
                menu.addItem(makeItem(entry))
            }
        }

        slot.menu = menu
        face.performClick(nil)
        slot.menu = nil
    }

    /// 菜单分四段：操作 / 账号 / 外观与截图 / 系统与退出
    private var menuLayout: [[Entry]] {
        let signedIn = stream.account.isSignedIn
        let widgetShown = widget.isVisible

        return [
            [
                Entry(
                    title: widgetShown
                        ? Localization.text(.menuCollapse)
                        : Localization.text(.menuExpand),
                    action: #selector(toggleWidget),
                    checked: widgetShown
                ),
                Entry(
                    title: Localization.text(.menuRefresh),
                    action: #selector(reloadNow),
                    key: "r",
                    enabled: signedIn && !stream.isPreviewing
                ),
                Entry(title: Localization.text(.menuUsagePage), action: #selector(openConsole)),
                Entry(title: Localization.text(.menuTrend), action: #selector(showTrend), key: "t")
            ],
            [
                Entry(
                    title: signedIn
                        ? Localization.text(.menuReSignIn)
                        : Localization.text(.menuSignIn),
                    action: #selector(signIn)
                ),
                Entry(
                    title: Localization.text(.menuAutoStart),
                    action: #selector(toggleAutostart),
                    checked: SMAppService.mainApp.status == .enabled
                )
            ],
            [
                // 置顶浮窗不会被 ⌘⇧4 的窗口选择列出；这一项临时降到普通层级，12 秒后自动恢复
                Entry(
                    title: Localization.text(.menuYieldForCapture),
                    action: #selector(yieldForScreenCapture),
                    enabled: widgetShown
                )
            ],
            [
                Entry(
                    title: Localization.text(.menuPreferences),
                    action: #selector(showPreferences),
                    key: ","
                ),
                Entry(title: Localization.text(.menuQuit), action: #selector(quitApp), key: "q")
            ]
        ]
    }

    private func makeItem(_ entry: Entry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: entry.key)
        item.target = self
        item.isEnabled = entry.enabled
        item.state = entry.checked ? .on : .off
        return item
    }

    // MARK: 菜单栏外观

    private func repaint() {
        guard let face = slot.button else { return }
        let remaining = stream.featuredRemaining
        let spec = Preferences.shared.badgeStyle.badge(for: remaining)

        face.title = spec.text
        face.image = spec.withIcon ? gaugeImage(for: remaining) : nil

        // 悬停显示两组额度，图标被折叠进「»」时也不用点开菜单
        face.toolTip = "QuotaDock · \(headline)"
    }

    private func gaugeImage(for remaining: Double?) -> NSImage? {
        let symbol: String
        if let remaining {
            switch remaining {
            case 67...: symbol = "gauge.with.dots.needle.67percent"
            case 34..<67: symbol = "gauge.with.dots.needle.50percent"
            default: symbol = "gauge.with.dots.needle.33percent"
            }
        } else {
            // 没拿到数据时不要画成「满格」，否则看起来像额度很充足
            symbol = "gauge"
        }
        let description = remaining.map {
            Localization.format(.gaugeRemaining, Int($0.rounded()))
        } ?? Localization.text(.gaugeUnknown)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    /// 「5h 85% · 周 23%」这种一行摘要，菜单首行与 tooltip 共用
    private var headline: String {
        guard let windows = stream.report?.mainGroup?.windows, !windows.isEmpty else {
            switch stream.phase {
            case .awaitingSignIn, .authorizing: return Localization.text(.statusNoAccount)
            case .stalled: return Localization.text(.statusReadFailed)
            default: return Localization.text(.statusReading)
            }
        }

        let joiner = " · "
        var pieces: [String] = []
        for window in windows.prefix(2) {
            pieces.append("\(window.rowLabel) \(Int(window.availablePercent.rounded()))%")
        }
        return pieces.joined(separator: joiner)
    }

    // MARK: 菜单动作

    @objc private func toggleWidget() {
        widget.toggle()
    }

    @objc private func reloadNow() {
        Task { await stream.pull() }
    }

    @objc private func openConsole() {
        stream.openUsagePage()
    }

    @objc private func signIn() {
        Task { await stream.beginSignIn() }
    }

    @objc private func toggleAutostart() {
        let turnOn = SMAppService.mainApp.status != .enabled
        do {
            try setAutostart(turnOn)
        } catch {
            let alert = NSAlert()
            alert.messageText = Localization.text(.launchAtLoginFailed)
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func setAutostart(_ wanted: Bool) throws {
        if wanted {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    @objc private func showPreferences() {
        PreferencesHost.shared.show()
    }

    @objc private func showTrend() {
        TimelineHost.shared.show()
    }

    @objc private func yieldForScreenCapture() {
        guard widget.isVisible else { return }
        widget.yieldForScreenCapture()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
