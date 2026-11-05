import AppKit
import Foundation

/// 历史趋势窗口：一个图表 + 底部工具条。

/// 让整个窗口都能接手势：滑在图表外面（标题栏、底栏上方）也交给图表处理。
/// 注意：指针已经在图上时不转发 —— 图表处理不了的事件会沿响应链冒泡到这里，
/// 再转发回去就会栈溢出。
private final class PlotBackdrop: NSView {
    weak var chart: TimelinePlot?

    private func pointerIsOnChart(_ event: NSEvent) -> Bool {
        guard let chart else { return true }
        return chart.frame.contains(convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let chart, !pointerIsOnChart(event) else {
            super.scrollWheel(with: event)
            return
        }
        chart.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let chart, !pointerIsOnChart(event) else {
            super.magnify(with: event)
            return
        }
        chart.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        guard let chart, !pointerIsOnChart(event) else {
            super.smartMagnify(with: event)
            return
        }
        chart.smartMagnify(with: event)
    }
}

@MainActor final class TimelineHost: NSObject, NSWindowDelegate {
    static let shared = TimelineHost()

    private var window: NSWindow?
    private let chart = TimelinePlot()
    private let rangeLabel = NSTextField(labelWithString: "")
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    /// 语言切换时要改标题的几处控件
    private weak var hintLabel: NSTextField?
    private weak var fitAllButton: NSButton?
    private weak var backToNowButton: NSButton?
    private weak var dataFolderButton: NSButton?

    private static let seriesColors: [NSColor] = [
        DockStyle.brand,
        DockStyle.positive,
        NSColor(srgbRed: 0.62, green: 0.48, blue: 0.95, alpha: 1),
        DockStyle.caution
    ]

    func show() {
        let isNew = window == nil
        if isNew {
            window = makeWindow()
            subscribe()
        }
        guard let window else { return }
        window.level = WindowStrata.companion

        // 打开时重读一遍磁盘：程序可能中途重启过，也方便直接看外部生成的样本
        UsageLedger.shared.syncFromDisk()
        syncFromDisk()
        if isNew {
            window.center()
        }
        // 每次打开都给同一个可预期的视角：跨 4 小时，「此刻」停在正中间
        chart.showDefaultView()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(chart)
        startTicker()
    }

    // MARK: 构建

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Localization.text(.trendTitle)
        window.backgroundColor = DockStyle.windowBackground
        window.minSize = NSSize(width: 560, height: 340)
        window.isReleasedWhenClosed = false
        window.level = WindowStrata.companion
        window.collectionBehavior = [.moveToActiveSpace]
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        let content = PlotBackdrop()
        content.chart = chart
        chart.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: Localization.text(.trendHint))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hintLabel = hint

        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor

        let fitButton = NSButton(
            title: Localization.text(.trendFitAll), target: self, action: #selector(showEverything)
        )
        fitButton.bezelStyle = .rounded
        fitButton.controlSize = .small
        fitAllButton = fitButton

        let nowButton = NSButton(
            title: Localization.text(.trendBackToNow), target: self, action: #selector(snapToLiveEdge)
        )
        nowButton.bezelStyle = .rounded
        nowButton.controlSize = .small
        backToNowButton = nowButton

        let folderButton = NSButton(
            title: Localization.text(.trendDataFolder), target: self, action: #selector(revealData)
        )
        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small
        dataFolderButton = folderButton

        let footer = NSStackView(views: [hint, NSView(), rangeLabel, folderButton, fitButton, nowButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(chart)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            chart.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            chart.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            chart.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            footer.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 22)
        ])

        chart.onViewportMoved = { [weak self] start, end in
            self?.updateRangeLabel(start: start, end: end)
        }

        window.contentView = content
        return window
    }

    // MARK: 数据

    private func subscribe() {
        let onLedgerChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromDisk() }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UsageLedger.didChange, object: nil, queue: .main, using: onLedgerChange
            )
        )

        let onThemeChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: ThemeCenter.didChange, object: nil, queue: .main, using: onThemeChange
            )
        )

        // 截图界面出现时降到普通层级，别浮在截图画面上
        let onCaptureYield: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCaptureYield() }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .captureYieldChanged, object: nil, queue: .main, using: onCaptureYield
            )
        )

        // 语言切换：标题、按钮、图表里的文字都要跟着换
        let onLanguageChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLanguage() }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .languageChanged, object: nil, queue: .main, using: onLanguageChange
            )
        )

        // 「设置页与趋势图置顶」开关改了
        let onLevelChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.level = WindowStrata.companion }
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .companionLevelChanged, object: nil, queue: .main, using: onLevelChange
            )
        )
    }

    /// 换语言后把能直接改的文案改掉，曲线区重画一遍
    private func applyLanguage() {
        window?.title = Localization.text(.trendTitle)
        hintLabel?.stringValue = Localization.text(.trendHint)
        fitAllButton?.title = Localization.text(.trendFitAll)
        backToNowButton?.title = Localization.text(.trendBackToNow)
        dataFolderButton?.title = Localization.text(.trendDataFolder)
        syncFromDisk()
        chart.needsDisplay = true
    }

    private func applyCaptureYield() {
        window?.level = WindowStrata.companion
    }

    /// 深浅色切换：窗口底色重算，图表重画
    private func applyAppearance() {
        window?.backgroundColor = DockStyle.windowBackground
        chart.needsDisplay = true
    }

    private func syncFromDisk() {
        let all = UsageLedger.shared.tracks()
        let resets = resetMoments()
        // 主档（最短的）见底 = 消耗被拦：其它档的预测平移到它的重置之后
        chart.blockedUntil = all
            .filter { ($0.samples.last?.leftPercent ?? 100) <= 0.2 }
            .min(by: { $0.spanMinutes < $1.spanMinutes })
            .flatMap { resets[$0.spanMinutes] }
        chart.resetMarkers = ResetMoments.merged(all.map { (samples: $0.samples, caption: $0.title) })
        chart.tracks = all.enumerated().map { index, item in
            TimelinePlot.Band(
                title: item.title,
                color: Self.seriesColors[index % Self.seriesColors.count],
                samples: item.samples,
                spanMinutes: item.spanMinutes,
                resetAt: resets[item.spanMinutes]
            )
        }
        updateRangeLabel(start: chart.viewport.start, end: chart.viewport.end)

        // 只有几条数据时先给全览，否则 3 小时窗口里只剩右边缘一个点
        if let oldest = all.compactMap({ $0.samples.first?.at }).min(),
           Date().timeIntervalSince(oldest) < 600 {
            chart.showEverything()
        }
    }

    /// 各档额度的重置时刻：预测线不能画过重置点，否则会把"归零"算到下一轮头上
    private func resetMoments() -> [Int: Date] {
        guard let windows = QuotaStream.shared.report?.mainGroup?.windows else { return [:] }
        var moments: [Int: Date] = [:]
        for window in windows {
            moments[window.spanMinutes] = window.resetsOn
        }
        return moments
    }

    /// 坐标轴上「几月几日 时:分」。按当前语言重建，语言变了才换新的。
    private static var rangeStamp: DateFormatter {
        let wanted = Localization.current.localeID
        if let cached = stampCache, cached.locale == wanted { return cached.stamp }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: wanted)
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = Localization.current.dayTimePattern
        stampCache = (wanted, stamp)
        return stamp
    }

    private static var stampCache: (locale: String, stamp: DateFormatter)?

    private func updateRangeLabel(start: Date, end: Date) {
        let head = Self.rangeStamp.string(from: start)
        let tail = Self.rangeStamp.string(from: end)
        rangeLabel.stringValue = "\(head) → \(tail)"
    }

    // MARK: 自动跟随

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.chart.followIfPinned() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: 动作

    @objc private func showEverything() { chart.showEverything() }
    @objc private func snapToLiveEdge() { chart.snapToLiveEdge() }

    @objc private func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([UsageLedger.shared.vaultURL])
    }
}
