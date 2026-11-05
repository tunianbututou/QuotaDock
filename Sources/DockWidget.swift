import AppKit
import Foundation

// MARK: - 悬浮窗 视图

/// 悬浮窗形态：完整面板 / 横条贴边（贴上下边）/ 竖条贴边（贴左右边）
enum WidgetShape: String {
    case expanded
    case pill
    case rail

    var size: NSSize {
        switch self {
        // 280×168：比 300×176 收一圈，和同类工具的默认画布拉开一点
        case .expanded: return NSSize(width: 280, height: 168)
        case .pill: return NSSize(width: 152, height: 26)
        case .rail: return NSSize(width: 48, height: 124)
        }
    }

    var isCompact: Bool { self != .expanded }
}

final class DockWidget: NSView {
    static let contentSize = WidgetShape.expanded.size

    var onDismiss: (() -> Void)?
    var onSyncNow: (() -> Void)?
    var onFold: (() -> Void)?
    var onUnfold: (() -> Void)?
    var onOpenPreferences: (() -> Void)?
    /// 打开历史趋势
    var onOpenTimeline: (() -> Void)?
    /// 开始拖动（两种形态都走这里）：控制器据此在拖动期间关掉吸附
    var onDragStart: (() -> Void)?
    var onCompactDragEnd: ((Bool) -> Void)?
    /// 完整形态拖动结束：控制器据此做最后贴边并落盘
    var onDragEnd: (() -> Void)?

    var shape: WidgetShape = .expanded {
        didSet {
            guard shape != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private let stream = QuotaStream.shared

    /// 每秒重绘都要用，所以只建一次：格式化器创建一次比算一次时间贵得多
    private static let clockStamp: DateFormatter = {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        return stamp
    }()
    /// 头部按钮位置随计划标签宽度动态计算（避免挤在屏幕角落被系统浮层遮挡）
    private var closeRect = NSRect(x: 216, y: 9, width: 20, height: 20)
    private var refreshRect = NSRect(x: 194, y: 9, width: 20, height: 20)
    private var foldRect = NSRect(x: 172, y: 9, width: 20, height: 20)
    private var prefsRect = NSRect(x: 152, y: 9, width: 20, height: 20)
    private var timelineRect = NSRect(x: 132, y: 9, width: 18, height: 18)
    private var ticker: Timer?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    /// 悬浮窗是常驻置顶的，别的 App 在前台时第一下点击也要直接生效，
    /// 不能被"先激活窗口"吃掉（否则要连点两下才能拖动/展开）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            // 只有完整形态有倒计时需要每秒刷新；缩略条没有秒级内容，靠数据变化驱动重绘即可
            guard self.shape == .expanded else { return }
            self.needsDisplay = true
        }
        RunLoop.main.add(ticker!, forMode: .common)

        // 浅色/深色切换：自绘内容全部要重画（标准控件会自己跟着 NSApp.appearance 走）
        let onThemeChange: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: ThemeCenter.didChange, object: nil, queue: .main, using: onThemeChange
        )
    }

    private var appearanceObserver: NSObjectProtocol?

    required init?(coder: NSCoder) { fatalError() }

    deinit { ticker?.invalidate() }

    // MARK: 排版方向

    /// 阿拉伯语等从右往左的语言：整块面板左右翻转
    private var mirrored: Bool { Localization.current.isRightToLeft }

    /// 从「起始边」算起的 x：正常语言是左边，RTL 时是右边
    private func leading(_ inset: CGFloat, span width: CGFloat) -> CGFloat {
        mirrored ? bounds.width - inset - width : inset
    }

    /// 从「结束边」算起的 x：正常语言是右边，RTL 时是左边
    private func trailing(_ inset: CGFloat, span width: CGFloat) -> CGFloat {
        mirrored ? inset : bounds.width - inset - width
    }

    /// 靠起始边 / 靠结束边的文字对齐
    private var nearAlignment: NSTextAlignment { mirrored ? .right : .left }
    private var farAlignment: NSTextAlignment { mirrored ? .left : .right }

    private func width(of text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// 在固定宽度的框里画一行字：放不下就逐级缩字号，缩到底还放不下就按最小号截断画。
    /// 各语言长短差很多（法语比中文长一倍），不缩就只能把右边截掉。
    private func paintFitting(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        floor: CGFloat = 8,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        var size = font.pointSize
        while size > floor {
            let probe = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
            if width(of: text, font: probe) <= rect.width {
                paintLabel(text, in: rect, font: probe, color: color, alignment: alignment)
                return
            }
            size -= 0.5
        }
        let smallest = NSFont(descriptor: font.fontDescriptor, size: floor) ?? font
        paintLabel(text, in: rect, font: smallest, color: color, alignment: alignment)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = shape.isCompact ? 15 : 12
        NSGraphicsContext.saveGraphicsState()

        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: outer, xRadius: radius, yRadius: radius)
        path.addClip()

        // 底色：深灰渐变，不用 material，保证在任何壁纸上都够黑
        let gradient = NSGradient(starting: DockStyle.surfaceTop, ending: DockStyle.surfaceBottom)
        gradient?.draw(in: path, angle: -90)

        switch shape {
        case .expanded:
            paintHeaderBar()
            paintGauges()
            paintFootline()
        case .pill:
            drawPill()
        case .rail:
            drawRail()
        }

        NSGraphicsContext.restoreGraphicsState()

        // 1pt 内描边：亮底上一圈极淡的白线，勾出边界
        DockStyle.edgeFaint.setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
        )
        border.lineWidth = 1
        border.stroke()
    }

    private func paintHeaderBar() {
        let y: CGFloat = 8
        let remaining = stream.featuredRemaining
        let dotColor = DockStyle.statusColor(remaining: remaining)

        // 状态点 + 微光
        let dotRect = NSRect(x: leading(13, span: 6), y: y + 6.5, width: 6, height: 6)
        let dot = NSBezierPath(ovalIn: dotRect)
        dotColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -2.5, dy: -2.5)).fill()
        dotColor.setFill()
        dot.fill()

        paintLabel(
            "QuotaDock",
            in: NSRect(x: leading(25, span: 120), y: y + 1, width: 120, height: 16),
            font: .systemFont(ofSize: 11.5, weight: .semibold),
            color: DockStyle.inkPrimary,
            alignment: nearAlignment,
            kern: 0.2
        )

        // 计划标签胶囊（贴结束边），两个按钮排在它内侧
        let planText = stream.isPreviewing ? Localization.text(.planPreview) : stream.planTag
        let planFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let planWidth = width(of: planText, font: planFont) + 12
        let chipRect = NSRect(x: trailing(12, span: planWidth), y: y + 2, width: planWidth, height: 16)
        // 按钮从胶囊内侧往起始边排；RTL 时方向反过来，间距不变
        func button(offset: CGFloat) -> NSRect {
            let size: CGFloat = 18
            let edge = mirrored ? chipRect.maxX : chipRect.minX
            let originX = mirrored ? edge + 8 + offset : edge - 8 - offset - size
            return NSRect(x: originX, y: y, width: size, height: size)
        }
        closeRect = button(offset: 0)
        refreshRect = button(offset: 20)
        foldRect = button(offset: 40)
        prefsRect = button(offset: 60)
        timelineRect = button(offset: 80)
        let chip = NSBezierPath(roundedRect: chipRect, xRadius: 8, yRadius: 8)
        planAccent.withAlphaComponent(0.22).setFill()
        chip.fill()
        planAccent.withAlphaComponent(0.55).setStroke()
        chip.lineWidth = 0.8
        chip.stroke()
        paintLabel(
            planText,
            in: NSRect(x: chipRect.minX, y: chipRect.minY + 3, width: chipRect.width, height: 12),
            font: planFont,
            color: planAccent,
            alignment: .center,
            kern: 0.5
        )

        // 五个功能按钮同一个亮色：以前刷新/关闭各用各的灰，看着像有两套状态
        let glyphColor = DockStyle.toolbarGlyph
        paintGlyph("arrow.clockwise", in: refreshRect, color: glyphColor)
        paintGlyph("xmark", in: closeRect, color: glyphColor)
        paintGlyph(
            "arrow.down.right.and.arrow.up.left",
            in: foldRect,
            color: glyphColor,
            pointSize: 9.5
        )
        paintGlyph(
            "slider.horizontal.3",
            in: prefsRect,
            color: glyphColor,
            pointSize: 10
        )
        paintGlyph(
            "chart.xyaxis.line",
            in: timelineRect,
            color: glyphColor,
            pointSize: 10
        )
    }

    /// 套餐胶囊的配色：Plus 绿、Pro 金，其它走中性亮色
    private var planAccent: NSColor {
        DockStyle.planColor(for: stream.isPreviewing ? "CHATGPT" : stream.planTag)
    }

    private func paintGauges() {
        switch stream.phase {
        case .live:
            if let report = stream.report {
                paintGaugeRows(report)
            } else {
                paintPlaceholder(
                    symbol: "hourglass",
                    title: Localization.text(.emptyNoData),
                    detail: Localization.text(.emptyRetryLater)
                )
            }
        case .waking:
            paintPlaceholder(
                symbol: "bolt.horizontal",
                title: Localization.text(.wakingTitle),
                detail: Localization.text(.wakingDetail)
            )
        case .awaitingSignIn, .authorizing:
            paintPlaceholder(
                symbol: "person.crop.circle",
                title: Localization.text(.signInTitle),
                detail: Localization.text(.signInDetail)
            )
        case .priming:
            paintPlaceholder(
                symbol: "arrow.triangle.2.circlepath",
                title: Localization.text(.primingTitle),
                detail: Localization.text(.primingDetail)
            )
        case .stalled:
            // 失败时不要丢掉上一次的好数据：网络抖一下就把额度抹掉体验很差，
            // 有旧数据就继续显示，只在页脚标「离线」。
            if let report = stream.report {
                paintGaugeRows(report)
            } else {
                paintPlaceholder(
                    symbol: "exclamationmark.triangle",
                    title: Localization.text(.failedTitle),
                    detail: Localization.text(.failedDetail)
                )
            }
        }
    }

    private func paintGaugeRows(_ report: QuotaReport) {
        let windows = Array((report.mainGroup?.windows ?? []).prefix(2))
        var y: CGFloat = 40
        for window in windows {
            paintGaugeRow(window: window, top: y)
            y += 46
        }
    }

    private func paintGaugeRow(window: QuotaWindow, top: CGFloat) {
        let accent = DockStyle.accent(for: window)
        let rowFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

        paintLabel(
            window.rowLabel,
            in: NSRect(x: leading(12, span: 50), y: top, width: 50, height: 14),
            font: rowFont,
            color: DockStyle.inkSecondary,
            alignment: nearAlignment,
            kern: 0.3
        )

        // 消耗速度预估：跟在窗口名后面，同号小字，别另起一行
        paintFitting(
            estimateText(for: window),
            in: NSRect(x: leading(60, span: 108), y: top, width: 108, height: 14),
            font: rowFont,
            floor: 8.5,
            color: DockStyle.inkTertiary,
            alignment: nearAlignment
        )

        // 细线进度条（RTL 时从结束边开始填充）
        let barRect = NSRect(x: leading(12, span: 138), y: top + 19, width: 138, height: 3)
        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
        DockStyle.groove.setFill()
        trackPath.fill()

        let fraction = min(1, max(0, window.availablePercent / 100))
        let fillWidth = max(3, barRect.width * fraction)
        let fillX = mirrored ? barRect.maxX - fillWidth : barRect.minX
        let fillRect = NSRect(x: fillX, y: barRect.minY, width: fillWidth, height: 3)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = accent.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.set()
        accent.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.restoreGraphicsState()

        // 大号百分比
        paintLabel(
            "\(Int(window.availablePercent.rounded()))%",
            in: NSRect(x: trailing(12, span: 86), y: top - 4, width: 86, height: 20),
            font: .monospacedDigitSystemFont(ofSize: 16.5, weight: .semibold),
            color: DockStyle.inkPrimary,
            alignment: farAlignment
        )

        // 重置倒计时：与进度条同高，读起来是一行。法语/西语比中文长得多，放不下就缩字号
        paintFitting(
            resetText(for: window),
            in: NSRect(x: trailing(12, span: 86), y: top + 15, width: 86, height: 12),
            font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            floor: 7.5,
            color: DockStyle.inkTertiary,
            alignment: farAlignment
        )
    }

    /// 进度条上方那行右侧小字：预计多久见底
    private func estimateText(for window: QuotaWindow) -> String {
        // 已经见底就别再预测了
        if window.availablePercent <= 0.4 {
            return Localization.text(.estimateExhausted)
        }
        guard let estimate = stream.estimates[window.spanMinutes] else {
            return Localization.text(.estimateCollecting)
        }
        // 别的档位（通常是周额度）先归零的话，这一档也会跟着归零：
        // 按它来算耗尽时间，而不是说「重置前不会耗尽」
        if let binding = bindingExhaustion(for: window) {
            return Localization.format(
                .estimateSharedExhaust,
                Localization.spellCountdown(binding.date.timeIntervalSinceNow),
                binding.other.rowLabel
            )
        }
        return estimate.caption(resetAt: window.resetsOn)
    }

    /// 哪一档会**先于**这档归零、并且真的会连带把它清零。
    /// 只有更长的窗口才具备这种"连带"关系：周额度到 0 时 5 小时额度也用不了了；
    /// 反过来 5 小时先耗尽只是被限流，周额度并不会跟着归零。
    private func bindingExhaustion(for window: QuotaWindow) -> (other: QuotaWindow, date: Date)? {
        guard let windows = stream.report?.mainGroup?.windows else { return nil }
        let own = stream.estimates[window.spanMinutes]?.forecast?.zeroDate
        var binding: (other: QuotaWindow, date: Date)?

        for other in windows where other.spanMinutes > window.spanMinutes {
            guard let date = stream.estimates[other.spanMinutes]?.forecast?.zeroDate else { continue }
            // 它自己这一轮都撑不到见底（中途会重置），就谈不上连带
            guard date < other.resetsOn else { continue }
            // 本档先重置就轮不到它
            guard date < window.resetsOn else { continue }
            // 自己本来就比它更早见底
            if let own, date >= own { continue }
            if let current = binding, current.date <= date { continue }
            binding = (other, date)
        }
        return binding
    }

    private func paintPlaceholder(symbol: String, title: String, detail: String) {
        let iconRect = NSRect(x: bounds.midX - 9, y: 58, width: 18, height: 18)
        paintGlyph(symbol, in: iconRect, color: DockStyle.inkTertiary, pointSize: 16)

        paintLabel(
            title,
            in: NSRect(x: 12, y: 84, width: bounds.width - 24, height: 16),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: DockStyle.inkPrimary,
            alignment: .center
        )
        paintLabel(
            detail,
            in: NSRect(x: 12, y: 102, width: bounds.width - 24, height: 14),
            font: .systemFont(ofSize: 10),
            color: DockStyle.inkTertiary,
            alignment: .center
        )
    }

    private func paintFootline() {
        DockStyle.edgeFaint.setFill()
        NSRect(x: 12, y: 136, width: bounds.width - 24, height: 1).fill()

        let body = NSFont.systemFont(ofSize: 9.5)
        let status = footerStatusText
        let statusWidth = min(112, width(of: status, font: body))
        paintLabel(
            status,
            in: NSRect(x: leading(12, span: statusWidth), y: 144, width: statusWidth, height: 12),
            font: body,
            color: stream.phase == .stalled ? DockStyle.caution : DockStyle.inkTertiary,
            alignment: nearAlignment
        )

        let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        let clockText = stream.refreshedAt.map { Self.clockStamp.string(from: $0) } ?? ""
        let clockWidth = width(of: clockText, font: clockFont)
        if !clockText.isEmpty {
            paintLabel(
                clockText,
                in: NSRect(x: trailing(12, span: clockWidth), y: 144, width: clockWidth, height: 12),
                font: clockFont,
                color: DockStyle.inkTertiary,
                alignment: farAlignment
            )
        }

        // 中间：上一次重置多久以前（用周额度倒计时倒推一个周期）。
        // 空档放不下就降一号字；再放不下就不画，免得和左右两边叠在一起。
        guard let lastReset = lastResetText else { return }
        let nearTake = 12 + (mirrored ? clockWidth : statusWidth) + 8
        let farTake = 12 + (mirrored ? statusWidth : clockWidth) + 8
        let gap = bounds.width - nearTake - farTake
        var bodyFont = body
        var resetWidth = width(of: lastReset, font: bodyFont)
        if resetWidth > gap {
            let smaller = NSFont.systemFont(ofSize: 8.5)
            let shrunk = width(of: lastReset, font: smaller)
            guard shrunk <= gap else { return }
            bodyFont = smaller
            resetWidth = shrunk
        }
        let boxX = (mirrored ? farTake : nearTake) + (gap - resetWidth) / 2
        paintLabel(
            lastReset,
            in: NSRect(x: boxX, y: 144, width: resetWidth, height: 12),
            font: bodyFont,
            color: DockStyle.inkTertiary,
            alignment: .center
        )
    }

    /// 「上次重置：1 天 9 小时前」。
    /// 周额度一个周期 7×24 小时，减去「还有多久重置」就是距离上次重置多久。
    /// 不到一天只说小时，不到一小时只说分钟 —— 那一栏本来就不宽。
    private var lastResetText: String? {
        guard let windows = stream.report?.mainGroup?.windows,
              let longest = windows.max(by: { $0.spanMinutes < $1.spanMinutes }),
              longest.spanMinutes >= 1_440 else { return nil }

        let cycle = TimeInterval(longest.spanMinutes) * 60
        let elapsed = cycle - longest.resetsOn.timeIntervalSinceNow
        guard elapsed >= 0 else { return nil }
        return Localization.format(.lastReset, Localization.spellElapsed(elapsed))
    }

    /// 页脚起始边状态：演示 / 离线 / 自动刷新间隔
    private var footerStatusText: String {
        if stream.isPreviewing { return Localization.text(.footerPreview) }
        if stream.phase == .stalled { return Localization.text(.footerOffline) }
        return Localization.format(.footerAutoRefresh, Preferences.shared.cadenceSeconds)
    }

    // MARK: 文本与图标工具

    private func paintLabel(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        kern: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kern
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func paintGlyph(
        _ name: String,
        in rect: NSRect,
        color: NSColor,
        pointSize: CGFloat = 10.5
    ) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let image = base.withSymbolConfiguration(config) else { return }
        let size = image.size
        let target = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: target)
    }

    /// 展开态的行标题统一走 `QuotaWindow.rowLabel`，各语言一套措辞

    private func resetText(for window: QuotaWindow) -> String {
        let remaining = window.resetsOn.timeIntervalSinceNow
        guard remaining > 0 else { return Localization.text(.resetImminent) }
        let total = Int(remaining)
        let days = total / 86_400
        if days >= 1 {
            return Localization.format(
                .resetCountdown,
                Localization.spellCountdown(remaining)
            )
        }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        let clock = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        return Localization.format(.resetCountdown, clock)
    }

    // MARK: 折叠态（贴边缩略：只留 5 小时与周额度两组关键数字）

    /// 一条缩略指标。拿不到数据的窗口直接不进列表 —— Pro 账户没有 5 小时限制时就不画那一组。
    private struct CompactMetric {
        let short: String
        let text: String
        let accent: NSColor
        let fraction: Double
    }

    private var compactMetrics: [CompactMetric] {
        guard let windows = stream.report?.mainGroup?.windows else { return [] }
        return windows.prefix(2).map { window in
            return CompactMetric(
                short: window.shortCaption,
                text: "\(Int(window.availablePercent.rounded()))%",
                accent: DockStyle.accent(for: window),
                fraction: min(1, max(0, window.availablePercent / 100))
            )
        }
    }

    private func paintStatusDot(center: NSPoint, remaining: Double?) {
        let color = DockStyle.statusColor(remaining: remaining)
        let rect = NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        color.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5)).fill()
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// 细进度线，带一点辉光
    private func paintMicroBar(rect: NSRect, fraction: Double, accent: NSColor) {
        DockStyle.groove.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        guard fraction > 0 else { return }
        let width = max(2, rect.width * fraction)
        let fill = NSRect(
            x: mirrored ? rect.maxX - width : rect.minX,
            y: rect.minY,
            width: width,
            height: rect.height
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = accent.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        accent.setFill()
        NSBezierPath(roundedRect: fill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 横条：贴上下边时用。两组指标并排，各带一条细线。
    private func drawPill() {
        let metrics = compactMetrics
        paintStatusDot(
            center: NSPoint(x: mirrored ? bounds.width - 11 : 11, y: bounds.midY),
            remaining: stream.featuredRemaining
        )

        guard !metrics.isEmpty else {
            paintLabel(
                "--",
                in: NSRect(x: 22, y: (bounds.height - 16) / 2, width: bounds.width - 33, height: 16),
                font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                color: DockStyle.inkTertiary,
                alignment: .center
            )
            return
        }

        // 细横条：标签与百分比同排（"5h 38%"），文字宽度即进度线宽度
        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)

        let blocks: [(attr: NSAttributedString, width: CGFloat)] = metrics.map { metric in
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(
                string: metric.short,
                attributes: [.font: labelFont, .foregroundColor: DockStyle.inkTertiary, .kern: 0.2]
            ))
            line.append(NSAttributedString(string: " ", attributes: [.font: labelFont]))
            line.append(NSAttributedString(
                string: metric.text,
                attributes: [.font: valueFont, .foregroundColor: DockStyle.inkPrimary]
            ))
            return (line, ceil(line.size().width))
        }

        let gap: CGFloat = 13
        let contentWidth = blocks.reduce(0) { $0 + $1.width }
            + gap * CGFloat(max(0, blocks.count - 1))
        let leftBound: CGFloat = 22
        let rightBound = bounds.width - 11
        let slack = max(0, rightBound - leftBound - contentWidth)
        var x = leftBound + slack / 2

        // RTL 时两组指标也从结束边往起始边排
        var pairs = Array(zip(blocks, metrics))
        if mirrored { pairs.reverse() }

        for (block, metric) in pairs {
            let textHeight = block.attr.size().height
            let top = max(1.5, (bounds.height - 3 - textHeight) / 2)
            block.attr.draw(at: NSPoint(x: x, y: top))
            paintMicroBar(
                rect: NSRect(x: x, y: bounds.height - 6, width: block.width, height: 2),
                fraction: metric.fraction,
                accent: metric.accent
            )
            x += block.width + gap
        }
    }

    /// 竖条：贴左右边时用。两组指标上下排，各带一条细线。
    private func drawRail() {
        let metrics = compactMetrics
        paintStatusDot(center: NSPoint(x: bounds.midX, y: 11), remaining: stream.featuredRemaining)

        guard !metrics.isEmpty else {
            paintLabel(
                "--",
                in: NSRect(x: 0, y: 26, width: bounds.width, height: 18),
                font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                color: DockStyle.inkTertiary,
                alignment: .center
            )
            return
        }

        let groupHeight: CGFloat = 46
        let top: CGFloat = 24
        let totalHeight = groupHeight * CGFloat(metrics.count)
        let offset = (bounds.height - top - totalHeight) / 2

        for (index, metric) in metrics.enumerated() {
            let y = top + offset + CGFloat(index) * groupHeight

            paintLabel(
                metric.short,
                in: NSRect(x: 0, y: y, width: bounds.width, height: 10),
                font: .systemFont(ofSize: 8.5, weight: .medium),
                color: DockStyle.inkTertiary,
                alignment: .center,
                kern: 0.3
            )
            paintLabel(
                metric.text,
                in: NSRect(x: 0, y: y + 10, width: bounds.width, height: 17),
                font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
                color: DockStyle.inkPrimary,
                alignment: .center
            )
            paintMicroBar(
                rect: NSRect(x: 12, y: y + 30, width: bounds.width - 24, height: 2.5),
                fraction: metric.fraction,
                accent: metric.accent
            )
        }
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        // 截图界面开着的时候，鼠标归它，别在这里抢
        guard !Self.captureUIActive() else { return }
        let point = convert(event.locationInWindow, from: nil)

        guard shape.isCompact else {
            if closeRect.contains(point) { onDismiss?(); return }
            if refreshRect.contains(point) {
                if stream.account.isSignedIn && !stream.isPreviewing {
                    onSyncNow?()
                }
                return
            }
            if foldRect.contains(point) { onFold?(); return }
            if prefsRect.contains(point) { onOpenPreferences?(); return }
            if timelineRect.contains(point) { onOpenTimeline?(); return }
            // 其余区域：整块可拖（手动拖动，见 runDragLoop 的说明）
            if runDragLoop(from: event) != .abandoned {
                onDragEnd?()
            }
            return
        }

        // 折叠态：拖动 = 移动（松手后由控制器贴边/换向），单击 = 展开。
        switch runDragLoop(from: event) {
        case .moved:
            onCompactDragEnd?(true)
        case .still:
            onCompactDragEnd?(false)
            onUnfold?()
        case .abandoned:
            onCompactDragEnd?(false)
        }
    }

    /// 手动拖动窗口。
    ///
    /// 为什么不用 `performDrag(with:)` / `isMovableByWindowBackground`：
    /// 在非激活的 borderless 面板上，这两条路都会在**松手后**把窗口用缓出动画
    /// 送回拖动前的位置（实测 macOS 27：轨迹是 `(549,154) → (444,196) → … → (0,370)`），
    /// 相当于白拖。自己跑事件循环反而稳定，且折叠条与完整面板行为一致。
    ///
    /// 位置按「起点 + 光标总位移」算，不按增量累加：`setFrameOrigin` 会把坐标取整到点，
    /// 每次只挪 2.5pt 的斜向拖动会被逐帧截断（实测 100pt 的路程只走了 80pt）。
    /// 拖动期间吸附是关掉的（`onDragStart`），所以这个绝对坐标不会被吸附改乱。
    /// 拖动收尾的三种结果：没动（当单击处理）、动过、被打断（按返回键一样处理，不再贴边）
    private enum DragOutcome {
        case still
        case moved
        case abandoned
    }

    @discardableResult
    private func runDragLoop(from event: NSEvent) -> DragOutcome {
        guard let window else { return .still }
        let downTime = event.timestamp
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        var moved = false

        // 拖动期间必须关掉吸附：把绝对定位和实时吸附放在一起会互相打架——
        // 贴着边的窗口每次只挪 9pt（< 10pt 阈值）时会被吸附反复拉回，永远挪不出来。
        onDragStart?()
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }

        while true {
            // 带超时地取事件，好让循环有机会发现「鼠标已经不归我了」
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking,
                dequeue: true
            ) else {
                // 两种「拖动作废」：截图界面接管了鼠标（⌘⇧4 是松手前按下的），
                // 或者松手事件被别的进程拿走、按键其实已经松开。
                // 两种情况都把窗口退回起点，否则它会一直跟着光标横穿屏幕。
                if Self.captureUIActive() || NSEvent.pressedMouseButtons & 1 == 0 {
                    window.setFrameOrigin(startOrigin)
                    return .abandoned
                }
                continue
            }

            // 丢掉按下之前就排队的老拖动事件，否则「点一下」会被当成拖动挪走
            if next.timestamp < downTime { continue }
            let current = NSEvent.mouseLocation
            if !moved, abs(current.x - startMouse.x) > 4 || abs(current.y - startMouse.y) > 4 {
                moved = true
            }
            if moved {
                window.setFrameOrigin(NSPoint(x: startOrigin.x + (current.x - startMouse.x),
                                              y: startOrigin.y + (current.y - startMouse.y)))
            }
            if next.type == .leftMouseUp { break }
        }
        return moved ? .moved : .still
    }

    /// 系统截图界面（⌘⇧4 / ⌘⇧5 / 截图 App / 微信 QQ 截图）是否正开着。
    /// 这类界面都会在最上层铺一张全屏遮罩：要么是 screencaptureui 进程，
    /// 要么是一张盖住大半块屏幕、层级高于普通窗口的窗口（微信 27、系统压暗 24、
    /// 事件挡板 1498……）。此时鼠标和画面都归它，悬浮窗不该再插手。
    static func captureUIActive() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.screencaptureui" && !$0.isTerminated
        }) {
            return true
        }

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        guard let screen = NSScreen.main?.frame else { return false }
        let screenArea = screen.width * screen.height

        for info in windows {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= 24 else { continue }                       // 普通窗口在 0
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double else { continue }
            // 盖住大半块屏幕的高层级窗口：截图遮罩 / 事件挡板
            if width * height >= screenArea * 0.85 { return true }
        }
        return false
    }

    /// 右键菜单：折叠成细条后没有头部图标，用右键仍然能进设置。
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if shape.isCompact {
            let expand = NSMenuItem(
                title: Localization.text(.menuExpand),
                action: #selector(menuExpand),
                keyEquivalent: ""
            )
            expand.target = self
            menu.addItem(expand)
            menu.addItem(NSMenuItem.separator())
        }
        let settings = NSMenuItem(
            title: Localization.text(.menuPreferences),
            action: #selector(menuSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let trend = NSMenuItem(
            title: Localization.text(.menuTrend),
            action: #selector(menuTrend),
            keyEquivalent: ""
        )
        trend.target = self
        menu.addItem(trend)

        let refresh = NSMenuItem(
            title: Localization.text(.menuRefresh),
            action: #selector(menuRefresh),
            keyEquivalent: ""
        )
        refresh.target = self
        refresh.isEnabled = stream.account.isSignedIn && !stream.isPreviewing
        menu.addItem(refresh)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuExpand() { onUnfold?() }
    @objc private func menuSettings() { onOpenPreferences?() }
    @objc private func menuTrend() { TimelineHost.shared.show() }
    @objc private func menuRefresh() {
        if stream.account.isSignedIn && !stream.isPreviewing { onSyncNow?() }
    }

    override func resetCursorRects() {
        if shape.isCompact {
            addCursorRect(bounds, cursor: .openHand)
            return
        }
        // 先加大范围、再覆盖按钮：后加的 rect 优先，否则按钮上的手型光标会被盖掉
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(closeRect, cursor: .pointingHand)
        addCursorRect(refreshRect, cursor: .pointingHand)
        addCursorRect(foldRect, cursor: .pointingHand)
        addCursorRect(prefsRect, cursor: .pointingHand)
        addCursorRect(timelineRect, cursor: .pointingHand)
    }
}
