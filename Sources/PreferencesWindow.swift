import AppKit
import Combine
import ServiceManagement

/// 设置主页面：从 悬浮窗 的三道杠按钮或菜单栏「设置…」调出。
@MainActor final class PreferencesHost: NSObject, NSWindowDelegate {
    static let shared = PreferencesHost()

    /// 设置行内容宽度（窗口宽 = 该值 + 左右 20pt 内边距）。
    /// 拉丁语言一句话比中文长不少，按语种放宽，免得右侧控件被挤扁。
    /// 双列排布：整页宽度 ≈ 两列 + 中间空隙。
    /// 宁可页面宽一点，也要让说明文字少折行——折行太多看着像挤在一起。
    private static var contentWidth: CGFloat { Localization.current.isCompactScript ? 780 : 840 }
    /// 下拉框宽度同理：中文「跟随系统」很短，法语 «Suivre le système» 就长得多
    private static var controlWidth: CGFloat { Localization.current.isCompactScript ? 150 : 170 }
    /// 两列之间的空隙
    private static let columnGap: CGFloat = 24
    /// 单列宽度：两侧各占一半，行的文字列按它算换行宽度
    private static var columnWidth: CGFloat { (contentWidth - columnGap) / 2 }

    /// 从右往左写的语言（阿拉伯语等）。
    /// AppKit 对 NSStackView 的 RTL 镜像并不一致（外层镜像、内层不镜像），
    /// 所以这里一律自己算顺序：所有自建 stack 都固定 .leftToRight，方向由代码决定。
    private var isRTL: Bool { Localization.current.isRightToLeft }

    /// 文本框对齐：RTL 时贴右
    private func alignText(_ label: NSTextField) -> NSTextField {
        label.alignment = isRTL ? .right : .left
        return label
    }

    /// 由 AppShell 注入，用于控制悬浮窗显隐
    weak var widget: WidgetHost?

    private var window: NSWindow?
    private var bag: Set<AnyCancellable> = []
    /// 下拉项是按哪门语言灌的：换语言必须重灌，否则要重启才生效
    private var popupLanguage: AppLanguage?
    /// 重灌下拉项时忽略随之而来的 action：
    /// removeAllItems/addItems 会把选中项重置并**异步**发一次 action，
    /// 那时 target 已经挂回去了，于是"换语言"被误触发一次、语言被写坏。
    private var suppressingPopupAction = false
    private var statusStyleWidth: NSLayoutConstraint?
    private var appearanceWidth: NSLayoutConstraint?
    private var languageWidth: NSLayoutConstraint?
    private var refreshIntervalWidth: NSLayoutConstraint?

    var debugVisible: Bool { window?.isVisible ?? false }
    var debugFrame: String {
        guard let window else { return "nil" }
        let f = window.frame
        return String(format: "(%.0f, %.0f, %.0f, %.0f)", f.origin.x, f.origin.y, f.size.width, f.size.height)
    }

    func show() {
        let isNew = window == nil
        if isNew {
            window = makeWindow()
            // 悬浮窗可能被 ⌥⌘B 或菜单栏切掉，设置页开着时开关状态要跟着变
            Preferences.shared.objectWillChange
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.refreshControls() }
                }
                .store(in: &bag)
            // 截图界面出现时降到普通层级，别浮在截图画面上
            NotificationCenter.default.addObserver(
                forName: .captureYieldChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyWindowLevel() }
            }
            // 「设置页与趋势图置顶」开关改了
            NotificationCenter.default.addObserver(
                forName: .companionLevelChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyWindowLevel() }
            }
        }
        guard let window else { return }
        // 偏好可能在窗口建好之后才改（「允许系统截图选中」），每次打开都对一次层级
        window.level = WindowStrata.companion
        refreshControls()
        NSApplication.shared.activate(ignoringOtherApps: true)
        // 只在第一次居中出现，之后尊重用户挪过的位置
        if isNew { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func applyWindowLevel() {
        window?.level = WindowStrata.companion
    }

    // MARK: 构建窗口

    private func makeWindow() -> NSWindow {
        let content = NSStackView()
        content.orientation = .vertical
        // 双列：每列宽度固定，整页宽度 = 两列 + 中间空隙（见 contentWidth）
        content.alignment = isRTL ? .trailing : .leading
        content.spacing = 10
        // 内边距交给外层容器：NSStackView 的 edgeInsets 在 RTL 下不生效，
        // 右边距会被吃掉，内容直接贴到窗口边缘。
        content.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        content.addArrangedSubview(sectionTitle(Localization.text(.sectionGeneral)))
        // 左列全是开关，右列全是下拉：同一类控件纵向对齐，扫起来顺手
        content.addArrangedSubview(columns(
            [
                row(
                    title: Localization.text(.launchAtLogin),
                    detail: nil,
                    control: launchAtLoginSwitch
                )
            ],
            [
                row(
                    title: Localization.text(.languageRow),
                    detail: Localization.text(.languageDetail),
                    control: languagePopup
                )
            ]
        ))

        content.addArrangedSubview(divider())
        content.addArrangedSubview(sectionTitle(Localization.text(.sectionDisplay)))
        // 右列比左列短，正好把「操作」的按钮塞进这块空档，不留白
        content.addArrangedSubview(columns(
            [
                row(
                    title: Localization.text(.widgetToggle),
                    detail: Localization.text(.widgetToggleDetail),
                    control: showWidgetSwitch
                ),
                row(
                    title: Localization.text(.acrossSpaces),
                    detail: nil,
                    control: acrossSpacesSwitch
                ),
                row(
                    title: Localization.text(.companionOnTop),
                    detail: Localization.text(.companionOnTopDetail),
                    control: companionOnTopSwitch
                ),
                row(
                    title: Localization.text(.screenshotPickable),
                    detail: Localization.text(.screenshotPickableDetail),
                    control: windowPickingSwitch
                ),
                row(
                    title: Localization.text(.hotKey),
                    detail: Localization.text(.hotKeyDetail),
                    control: hotKeySwitch
                )
            ],
            [
                row(
                    title: Localization.text(.cadence),
                    detail: Localization.text(.cadenceDetail),
                    control: refreshIntervalPopup
                ),
                row(
                    title: Localization.text(.appearance),
                    detail: Localization.text(.appearanceDetail),
                    control: appearancePopup
                ),
                row(
                    title: Localization.text(.statusStyle),
                    detail: nil,
                    control: statusStylePopup
                ),
                actionBlock()
            ]
        ))

        content.addArrangedSubview(divider())
        content.addArrangedSubview(footerRow())

        let container = NSView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Localization.text(.settingsTitle)
        window.contentView = container
        window.delegate = self
        window.isReleasedWhenClosed = false
        // 方向一律交给上面手工处理，避免 AppKit 在嵌套 stack 里时mirroring 时有时无
        content.userInterfaceLayoutDirection = .leftToRight
        // 比悬浮 悬浮窗(28) 高一层，避免设置页被自己的悬浮窗压住；
        // 允许截图选中时两者都回到普通层级
        window.level = WindowStrata.companion
        window.collectionBehavior = [.moveToActiveSpace]

        container.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        window.setContentSize(NSSize(width: max(400, fitting.width), height: max(320, fitting.height)))
        return window
    }

    // MARK: 控件

    private lazy var launchAtLoginSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleLaunchAtLogin(_:))
        return control
    }()

    private lazy var showWidgetSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleWidget(_:))
        return control
    }()

    private lazy var acrossSpacesSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleAcrossSpaces(_:))
        return control
    }()

    private lazy var companionOnTopSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleCompanionOnTop(_:))
        return control
    }()

    private lazy var windowPickingSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleWindowPicking(_:))
        return control
    }()

    private lazy var statusStylePopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: BadgeStyle.allCases.map(\.title))
        popup.target = self
        popup.action = #selector(changeStatusStyle(_:))
        let constraint = popup.widthAnchor.constraint(equalToConstant: Self.controlWidth)
        constraint.isActive = true
        statusStyleWidth = constraint
        return popup
    }()

    private lazy var appearancePopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ThemeMode.allCases.map(\.title))
        popup.target = self
        popup.action = #selector(changeAppearance(_:))
        let constraint = popup.widthAnchor.constraint(equalToConstant: Self.controlWidth)
        constraint.isActive = true
        appearanceWidth = constraint
        return popup
    }()

    /// 语言下拉：每一项都是「母语写法（当前语言里的译名）」。
    /// 宽度按最长那一项算，否则「简体中文（Simplified Chinese）」这种会被截断。
    private lazy var languagePopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: AppLanguage.allCases.map(\.menuTitle))
        popup.target = self
        popup.action = #selector(changeLanguage(_:))
        let constraint = popup.widthAnchor.constraint(equalToConstant: Self.languagePopupWidth)
        constraint.isActive = true
        languageWidth = constraint
        return popup
    }()

    private lazy var refreshIntervalPopup: NSPopUpButton = {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: DefaultValues.cadenceChoices.map {
            Localization.spellInterval(TimeInterval($0))
        })
        popup.target = self
        popup.action = #selector(changeRefreshInterval(_:))
        let constraint = popup.widthAnchor.constraint(equalToConstant: Self.controlWidth)
        constraint.isActive = true
        refreshIntervalWidth = constraint
        return popup
    }()

    private lazy var hotKeySwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleHotKey(_:))
        return control
    }()

    private func refreshControls() {
        relocalizePopups()
        launchAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        showWidgetSwitch.state = (widget?.isVisible ?? false) ? .on : .off
        acrossSpacesSwitch.state = Preferences.shared.widgetOnEverySpace ? .on : .off
        companionOnTopSwitch.state = Preferences.shared.companionOnTop ? .on : .off
        windowPickingSwitch.state = Preferences.shared.screenshotPickable ? .on : .off
        hotKeySwitch.state = Preferences.shared.hotKeyEnabled ? .on : .off

        if let index = DefaultValues.cadenceChoices
            .firstIndex(of: Preferences.shared.cadenceSeconds) {
            refreshIntervalPopup.selectItem(at: index)
        }

        if let index = ThemeMode.allCases.firstIndex(of: Preferences.shared.themeMode) {
            appearancePopup.selectItem(at: index)
        }

        if let index = BadgeStyle.allCases.firstIndex(of: Preferences.shared.badgeStyle) {
            statusStylePopup.selectItem(at: index)
        }

        if let index = AppLanguage.allCases.firstIndex(of: Preferences.shared.language) {
            languagePopup.selectItem(at: index)
        }
    }

    /// 语言下拉需要多宽：按最长那一项算，否则「简体中文（Simplified Chinese）」会被截断
    private static var languagePopupWidth: CGFloat {
        let widest = AppLanguage.allCases.reduce(CGFloat(0)) { widest, language in
            max(widest, ceil((language.menuTitle as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
            ).width))
        }
        return max(controlWidth, widest + 36)
    }

    /// 下拉项里带译名，是建窗时定死的：换语言必须重灌，
    /// 否则只有重启才变（切中文后「跟随系统」还写着阿拉伯语就是这么来的）。
    private func relocalizePopups() {
        let language = Localization.current
        guard popupLanguage != language else { return }
        popupLanguage = language

        // 重灌会改变选中项，进而把 action 发出去、误改设置（语言会被拽回第一项）。
        // 先把 target 摘掉，灌完再挂回来。
        let popups = [statusStylePopup, appearancePopup, refreshIntervalPopup, languagePopup]
        let targets = popups.map(\.target)
        for popup in popups { popup.target = nil }
        defer {
            for (popup, target) in zip(popups, targets) { popup.target = target }
        }
        suppressingPopupAction = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressingPopupAction = false
        }

        statusStylePopup.removeAllItems()
        statusStylePopup.addItems(withTitles: BadgeStyle.allCases.map(\.title))
        appearancePopup.removeAllItems()
        appearancePopup.addItems(withTitles: ThemeMode.allCases.map(\.title))
        refreshIntervalPopup.removeAllItems()
        refreshIntervalPopup.addItems(withTitles: DefaultValues.cadenceChoices.map {
            Localization.spellInterval(TimeInterval($0))
        })
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: AppLanguage.allCases.map(\.menuTitle))

        // 控件宽度也随语种走：中文 180，拉丁语系 190
        statusStyleWidth?.constant = Self.controlWidth
        appearanceWidth?.constant = Self.controlWidth
        refreshIntervalWidth?.constant = Self.controlWidth
        languageWidth?.constant = Self.languagePopupWidth
    }

    /// 换语言：整页重建最省心（下拉项的译名、说明文字、行宽都要跟着变）。
    /// 先记下窗口位置，重建后放回去，不让窗口跳到屏幕中间。
    private func rebuild() {
        guard let old = window else { return }
        let origin = old.frame.origin
        old.close()
        window = nil
        bag.removeAll()
        show()
        window?.setFrameOrigin(origin)
    }

    // MARK: 布局工具

    private func sectionTitle(_ text: String) -> NSView {
        let label = alignText(NSTextField(labelWithString: text))
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return line
    }

    /// 一行设置：标题和控件同一行、控件紧贴标题，说明文字另起一行占满整列。
    /// 这样控件不用被推到列尾（标题与控件之间不会隔一大片空），
    /// 说明文字也能吃满整列宽度，不必绕着控件折行。
    private func row(title: String, detail: String?, control: NSView) -> NSView {
        let titleLabel = alignText(NSTextField(labelWithString: title))
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        // 标题和控件同一行，控件靠列尾对齐（同一列里上下对齐成一竖排），
        // 中间的弹性空隙把控件推到边上；说明文字另起一行，占满整列宽度，
        // 不用绕着控件折行。RTL 时整行反过来：控件在左、标题在右。
        let header = NSStackView(views: isRTL
            ? [control, NSView(), titleLabel]
            : [titleLabel, NSView(), control])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 12
        header.userInterfaceLayoutDirection = .leftToRight
        header.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = isRTL ? .trailing : .leading
        stack.spacing = 2
        stack.userInterfaceLayoutDirection = .leftToRight
        stack.addArrangedSubview(header)

        if let detail {
            let detailLabel = alignText(NSTextField(labelWithString: detail))
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .tertiaryLabelColor
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.maximumNumberOfLines = 4
            detailLabel.preferredMaxLayoutWidth = Self.columnWidth
            stack.addArrangedSubview(detailLabel)
        }

        stack.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return stack
    }

    /// 两列并排：左边一列放开关，右边一列放选项（下拉），同类控件纵向对齐
    private func columns(_ switches: [NSView], _ options: [NSView]) -> NSView {
        func column(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = isRTL ? .trailing : .leading
            stack.spacing = 10
            stack.userInterfaceLayoutDirection = .leftToRight
            stack.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
            return stack
        }
        // 从右往左读：第一列要落在右边，所以把两个列的先后倒过来
        let ordered = isRTL ? [column(options), column(switches)] : [column(switches), column(options)]
        let pair = NSStackView(views: ordered)
        pair.orientation = .horizontal
        pair.alignment = .top
        pair.distribution = .fill
        pair.spacing = Self.columnGap
        pair.userInterfaceLayoutDirection = .leftToRight
        return pair
    }

    /// 操作区：塞在右侧那一列的空档里，标题 + 两行按钮
    private func actionBlock() -> NSView {
        func button(_ phrase: Phrase, _ action: Selector) -> NSButton {
            let control = NSButton(title: Localization.text(phrase), target: self, action: action)
            control.bezelStyle = .rounded
            return control
        }

        // 和上面的下拉框拉开一点，别让「操作」看着像「显示」的小弟
        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 18).isActive = true

        // RTL：第一个按钮要排在最右边，所以整排倒过来
        var firstButtons = [
            button(.actionRefresh, #selector(refreshNow)),
            button(.actionTrend, #selector(openTrend)),
            button(.actionUsagePage, #selector(openUsagePage))
        ]
        var secondButtons = [
            button(.actionRelogin, #selector(relogin)),
            button(.actionResetPosition, #selector(resetWidgetPosition))
        ]
        if isRTL {
            firstButtons.reverse()
            secondButtons.reverse()
        }
        let first = NSStackView(views: firstButtons)
        let second = NSStackView(views: secondButtons)
        for row in [first, second] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.userInterfaceLayoutDirection = .leftToRight
        }

        let stack = NSStackView(views: [
            gap,
            sectionTitle(Localization.text(.sectionActions)),
            first,
            second
        ])
        stack.orientation = .vertical
        stack.alignment = isRTL ? .trailing : .leading
        stack.spacing = 8
        stack.userInterfaceLayoutDirection = .leftToRight
        stack.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return stack
    }

    private func footerRow() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

        // 非激活窗口的开关/下拉会被系统去饱和渲染，容易被当成"设置丢了"。
        // 在页脚上方留一句说明，省得每次都要解释一遍。
        let hint = alignText(NSTextField(wrappingLabelWithString: Localization.text(.settingsInactiveHint)))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 3
        hint.preferredMaxLayoutWidth = Self.contentWidth

        let footer = alignText(NSTextField(
            labelWithString: Localization.format(.settingsFooter, version)
        ))
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [hint, footer])
        stack.orientation = .vertical
        stack.alignment = isRTL ? .trailing : .leading
        stack.userInterfaceLayoutDirection = .leftToRight
        stack.spacing = 7
        return stack
    }

    // MARK: 动作

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = Localization.text(.launchAtLoginFailed)
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleWidget(_ sender: NSSwitch) {
        if sender.state == .on {
            widget?.show()
        } else {
            widget?.hide()
        }
    }

    @objc private func toggleAcrossSpaces(_ sender: NSSwitch) {
        Preferences.shared.widgetOnEverySpace = sender.state == .on
        widget?.applySpaceBehaviour(sender.state == .on)
    }

    @objc private func toggleCompanionOnTop(_ sender: NSSwitch) {
        Preferences.shared.companionOnTop = sender.state == .on
    }

    @objc private func toggleWindowPicking(_ sender: NSSwitch) {
        Preferences.shared.screenshotPickable = sender.state == .on
        widget?.refreshWindowLevel()
    }

    @objc private func changeStatusStyle(_ sender: NSPopUpButton) {
        let styles = BadgeStyle.allCases
        let index = min(max(sender.indexOfSelectedItem, 0), styles.count - 1)
        Preferences.shared.badgeStyle = styles[index]
    }

    @objc private func changeAppearance(_ sender: NSPopUpButton) {
        let modes = ThemeMode.allCases
        let index = min(max(sender.indexOfSelectedItem, 0), modes.count - 1)
        Preferences.shared.themeMode = modes[index]
        ThemeCenter.shared.apply(modes[index])
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard !suppressingPopupAction else { return }
        let languages = AppLanguage.allCases
        let index = min(max(sender.indexOfSelectedItem, 0), languages.count - 1)
        guard languages[index] != Preferences.shared.language else { return }
        Preferences.shared.language = languages[index]
        rebuild()
    }

    @objc private func changeRefreshInterval(_ sender: NSPopUpButton) {
        let choices = DefaultValues.cadenceChoices
        let index = min(max(sender.indexOfSelectedItem, 0), choices.count - 1)
        Preferences.shared.cadenceSeconds = choices[index]
        NotificationCenter.default.post(name: .cadenceChanged, object: nil)
    }

    @objc private func toggleHotKey(_ sender: NSSwitch) {
        Preferences.shared.hotKeyEnabled = sender.state == .on
        NotificationCenter.default.post(name: .hotKeyPreferenceChanged, object: nil)
    }

    @objc private func refreshNow() {
        Task { await QuotaStream.shared.pull() }
    }

    @objc private func openUsagePage() {
        QuotaStream.shared.openUsagePage()
    }

    @objc private func openTrend() {
        TimelineHost.shared.show()
    }

    @objc private func relogin() {
        Task { await QuotaStream.shared.beginSignIn() }
    }

    @objc private func resetWidgetPosition() {
        widget?.resetPosition()
    }
}
