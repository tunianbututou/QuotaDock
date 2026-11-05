import AppKit
import Foundation

/// 额度历史曲线。自绘，不依赖任何第三方库。
///
/// 交互：双指捏合缩放（以指针位置为锚点）、双指左右滑动平移时间轴、
/// 鼠标拖拽平移、双击触控板回到「全览」。
/// 坐标：Y 轴每 10% 一条主线（每 5% 一条细线），X 轴按可见跨度自适应刻度。
final class TimelinePlot: NSView {
    /// 一条要画的曲线
    struct Band {
        let title: String
        let color: NSColor
        let samples: [LedgerSample]
        /// 这一档的窗口长度（分钟），用来查「上次记住的消耗速度」
        var spanMinutes: Int = 0
        /// 这一档什么时候重置。预测线画到这里为止，别越过重置继续往下推。
        var resetAt: Date?
    }

    var tracks: [Band] = [] {
        didSet {
            let previous = projections
            projections = tracks.enumerated().map { index, band in
                let lastPercent = band.samples.last?.leftPercent ?? 100

                // 本档自己见底：没有预测可言
                guard lastPercent > 0.2 else { return nil }

                // 主档见底、消耗被拦期间，本档曲线是平的，拟合会失真：
                // 冻结上一次预测的速度，把见底点平移到主档重置之后（恒定时刻）
                if let blocked = blockedUntil,
                   let last = band.samples.last, last.at < blocked {
                    let rate = (index < previous.count ? previous[index]?.dropPerMinute : nil)
                        ?? RateMemory.recall(band.spanMinutes)
                        ?? QuotaForecast.recentRate(in: band.samples)
                    if let rate {
                        let base = ExhaustionForecast(
                            dropPerMinute: rate, secondsLeft: 0,
                            measuredFrom: last.at, measuredAt: last.at
                        )
                        return QuotaForecast.shifted(
                            base, remaining: lastPercent, blockedUntil: blocked, now: Date()
                        )
                    }
                }

                if case let .falling(forecast) = QuotaForecast.estimate(samples: band.samples) {
                    RateMemory.remember(forecast.dropPerMinute, spanMinutes: band.spanMinutes)
                    return forecast
                }
                // 没在消耗（steady / collecting）也给一条平的预测线：
                // 否则周额度这种「一小时才动一个点」的档位，速度一跌破阈值整条虚线就消失，
                // 看着像图表坏了。速度 0，见底时刻用一个足够远的哨兵。
                guard let last = band.samples.last else { return nil }
                return Self.flatForecast(at: last.at)
            }
            if followsLive { windowEnd = followEdge }
            needsDisplay = true
            publishViewport()
        }
    }

    /// 速度为 0 的「平预测」：见底时刻给一个足够远的哨兵，画出来就是一条水平虚线。
    private static func flatForecast(at moment: Date) -> ExhaustionForecast {
        ExhaustionForecast(
            dropPerMinute: 0,
            secondsLeft: 10 * 365 * 24 * 3_600,
            measuredFrom: moment,
            measuredAt: moment
        )
    }

    /// 主档见底（消耗被拦）的截止时刻＝主档重置时间。有值时其它档的预测冻结平移。
    var blockedUntil: Date?

    /// 检测到的重置时刻：画成亮黄色竖线，提醒「这一段是重置之后重新开始烧的」
    var resetMarkers: [ResetMark] = [] {
        didSet { needsDisplay = true }
    }

    /// 每条曲线对应的见底预测，与 `tracks` 同序；数据一变就重算
    private var projections: [ExhaustionForecast?] = []

    /// 可见窗口变化（用于窗口底部的区间说明）
    var onViewportMoved: ((Date, Date) -> Void)?

    // MARK: 视窗状态

    private var windowEnd: Date = Date().addingTimeInterval(30)
    private var windowSpan: TimeInterval = 4 * 3600
    private var followsLive = true
    /// 跟随的时候让「此刻」停在正中间（打开窗口的默认视角），而不是贴右边缘
    private var centersNow = false

    private var springWork: DispatchWorkItem?
    private var springTimer: Timer?

    private let minSpan: TimeInterval = 5 * 60
    private let maxSpan: TimeInterval = UsageLedger.keepDays.days

    private var visibleStart: Date { windowEnd.addingTimeInterval(-windowSpan) }

    /// 右边界：一般是「现在 + 30 秒」。有预测时再往后让一小段（最多当前跨度的四分之一），
    /// 好让虚线真的画到 0% 那一头，而不是刚出手就被裁掉。
    private var liveEdge: Date {
        let base = Date().addingTimeInterval(30)
        guard let projected = projections.compactMap({ $0?.zeroDate }).max() else { return base }
        let ahead = projected.timeIntervalSinceNow
        guard ahead > 0 else { return base }
        return base.addingTimeInterval(min(ahead + 120, max(600, windowSpan * 0.25)))
    }

    /// 跟随模式下右边界停在哪：贴右边缘，或者让「此刻」停在正中间
    private var followEdge: Date {
        guard centersNow else { return liveEdge }
        return Date().addingTimeInterval(windowSpan / 2)
    }

    // MARK: 布局

    private let insetLeft: CGFloat = 46
    private let insetRight: CGFloat = 16
    private let insetTop: CGFloat = 40
    private let insetBottom: CGFloat = 30

    /// 顶部图例与底部提示条共用同一对左右边距，这样上下两排文字边缘对齐
    static let headerInset: CGFloat = 4

    /// 100% 与绘图区顶边之间的余量：不留的话 100% 那条横线正好压在边框上看不见
    private static let headroom: CGFloat = 9

    /// 顶部图例那一排文字的矩形：顶边距绘图区顶边多少、整排多高。
    /// 时间轴的竖线要顶到这排文字的上沿，所以两边共用同一组数字。
    private static let headerRowTopGap: CGFloat = 11
    private static let headerRowHeight: CGFloat = 15

    private var plot: NSRect {
        NSRect(
            x: insetLeft,
            y: insetBottom,
            width: max(1, bounds.width - insetLeft - insetRight),
            height: max(1, bounds.height - insetTop - insetBottom)
        )
    }

    private func x(for date: Date) -> CGFloat {
        let fraction = date.timeIntervalSince(visibleStart) / max(1, windowSpan)
        return plot.minX + plot.width * CGFloat(fraction)
    }

    private func date(atX px: CGFloat) -> Date {
        let fraction = Double((px - plot.minX) / max(1, plot.width))
        return visibleStart.addingTimeInterval(windowSpan * fraction)
    }

    private func y(for remaining: Double) -> CGFloat {
        let clamped = max(0, min(100, remaining))
        // 100% 那条线如果贴着绘图区顶边，就被边框压住了：上面留一点余量
        return plot.minY + (plot.height - Self.headroom) * CGFloat(clamped / 100)
    }

    // MARK: 悬停 / 拖拽

    private var hoverX: CGFloat?
    private var isPanning = false
    private var panStartX: CGFloat = 0
    private var panStartEnd: Date = .distantPast
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(plot, cursor: .openHand)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoverX = plot.contains(point) ? point.x : nil
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard plot.contains(point) else { return }
        isPanning = true
        panStartX = point.x
        panStartEnd = windowEnd
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - panStartX
        followsLive = false
        windowEnd = panStartEnd.addingTimeInterval(-Double(dx / max(1, plot.width)) * windowSpan)
        clampElastic()
        hoverX = point.x
        needsDisplay = true
        publishViewport()
    }

    override func mouseUp(with event: NSEvent) {
        guard isPanning else { return }
        isPanning = false
        NSCursor.pop()
        needsDisplay = true
        scheduleSpringBack(after: 0.05)
    }

    // MARK: 手势

    override func magnify(with event: NSEvent) {
        guard windowSpan > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let anchorX = min(max(point.x, plot.minX), plot.maxX)
        let anchorDate = date(atX: anchorX)
        let factor = 1 + event.magnification
        guard factor > 0.01 else { return }

        followsLive = false
        setSpan(windowSpan / factor, anchoring: anchorDate, at: anchorX)
    }

    override func smartMagnify(with event: NSEvent) {
        showEverything()
    }

    override func scrollWheel(with event: NSEvent) {
        traceScroll(event)
        // ⌥ + 滚轮/双指上下 = 缩放（以指针为锚点）
        if event.modifierFlags.contains(.option) {
            let dy = event.scrollingDeltaY
            guard abs(dy) > 0.01 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let anchorX = min(max(point.x, plot.minX), plot.maxX)
            followsLive = false
            setSpan(
                windowSpan / exp(Double(dy) * 0.01),
                anchoring: date(atX: anchorX),
                at: anchorX
            )
            return
        }

        // 只吃横向分量：两指左右滑 = 平移时间轴；纵向留给系统。
        // 触控板/妙控鼠标是"精确增量"（点），滚轮是"行"，行要放大才对得上手感。
        let precise = event.hasPreciseScrollingDeltas
        var dx = event.scrollingDeltaX
        if !precise { dx *= 12 }
        // 少数设备把横向量塞在 deltaX 里（scrollingDeltaX 为 0）
        if abs(dx) < 0.01, !precise { dx = event.deltaX * 12 }
        guard abs(dx) > 0.01 else {
            super.scrollWheel(with: event)
            return
        }
        followsLive = false
        let delta = Double(dx / max(1, plot.width)) * windowSpan
        windowEnd = windowEnd.addingTimeInterval(delta)
        clampElastic()
        needsDisplay = true
        publishViewport()

        // 触控板的惯性扫动会在 phase 结束后继续以 momentum 事件到达，
        // 所以要等惯性也结束（或两三百毫秒没有新事件）再回弹
        springWork?.cancel()
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
        if ended || event.phase.isEmpty {
            scheduleSpringBack(after: ended ? 0.05 : 0.3)
        }
    }

    // MARK: 键盘平移（手势之外的兜底）

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: pan(by: -0.2)   // ←
        case 124: pan(by: 0.2)    // →
        case 36: snapToLiveEdge()      // ↩ 回到现在
        default: super.keyDown(with: event)
        }
    }

    private func pan(by fraction: CGFloat) {
        followsLive = false
        windowEnd = windowEnd.addingTimeInterval(Double(fraction) * windowSpan)
        clampViewport()
        needsDisplay = true
        publishViewport()
    }

    /// 临时诊断（默认关闭；`defaults write com.quotadock.app QuotaDock.traceScroll -bool true` 打开）
    private func traceScroll(_ event: NSEvent) {
        guard UserDefaults.standard.bool(forKey: "QuotaDock.traceScroll") else { return }
        let line = String(
            format: "dx=%.2f dy=%.2f precise=%d phase=%lu mom=%lu span=%.0f",
            event.scrollingDeltaX, event.scrollingDeltaY,
            event.hasPreciseScrollingDeltas ? 1 : 0,
            event.phase.rawValue, event.momentumPhase.rawValue,
            windowSpan
        )
        var list = UserDefaults.standard.stringArray(forKey: "QuotaDock.scrollTrace") ?? []
        list.append(line)
        if list.count > 20 { list.removeFirst(list.count - 20) }
        UserDefaults.standard.set(list, forKey: "QuotaDock.scrollTrace")
    }

    // MARK: 外部控制

    /// 打开窗口时的默认视角：跨 4 小时，「此刻」落在图表正中间，
    /// 既能看清刚过去的一段时间，也能给"接下来两小时"留出位置。
    func showDefaultView() {
        springWork?.cancel()
        springTimer?.invalidate()
        followsLive = true
        centersNow = true
        windowSpan = 4 * 3600
        windowEnd = followEdge
        clampViewport()
        needsDisplay = true
        publishViewport()
    }

    /// 显示全部历史（不放大到小于 5 分钟）
    func showEverything() {
        springWork?.cancel()
        springTimer?.invalidate()
        centersNow = false
        let oldest = tracks.compactMap { $0.samples.first?.at }.min()
        guard let oldest else {
            followsLive = true
            windowSpan = 4 * 3600
            windowEnd = liveEdge
            needsDisplay = true
            publishViewport()
            return
        }
        let span = max(minSpan, Date().timeIntervalSince(oldest) + 180)
        followsLive = true
        windowSpan = min(maxSpan, span)
        windowEnd = liveEdge
        clampViewport()
        needsDisplay = true
        publishViewport()
    }

    /// 「回到现在」：和打开窗口时完全一样——4 小时跨度、此刻停在正中间。
    /// 与其只把右边界推回现在（跨度还是乱的话看着还是别扭），不如直接回到默认视角。
    func snapToLiveEdge() {
        showDefaultView()
    }

    /// 自动跟随模式下把窗口右边界推到「现在」（由窗口的定时器驱动）
    func followIfPinned() {
        guard followsLive else { return }
        windowEnd = followEdge
        clampViewport()
        needsDisplay = true
        publishViewport()
    }

    /// 当前可见区间（给窗口底部文案用）
    var viewport: (start: Date, end: Date, span: TimeInterval) {
        (visibleStart, windowEnd, windowSpan)
    }

    private func setSpan(_ span: TimeInterval, anchoring anchorDate: Date, at anchorX: CGFloat) {
        springWork?.cancel()
        let newSpan = min(maxSpan, max(minSpan, span))
        let fraction = Double((anchorX - plot.minX) / max(1, plot.width))
        windowSpan = newSpan
        windowEnd = anchorDate.addingTimeInterval(newSpan * (1 - fraction))
        clampViewport()
        needsDisplay = true
        publishViewport()
    }

    /// 硬边界：最早的数据点再往左留 10 分钟，最右就是「现在」。
    /// 滑到边界还继续滑时，用弹性越界 + 松手回弹给出反馈，
    /// 否则停在全览 / 停在「现在」时两指滑动会像完全没反应。
    private func hardBounds() -> (minEnd: Date, maxEnd: Date) {
        // 右侧允许再往前滑半个可视宽度：能空出「接下来一段」的位置，
        // 不然滑到当前时刻就顶死了，看不到前面的余量
        let forward = Date().addingTimeInterval(windowSpan * 0.5)
        let maxEnd = max(liveEdge, forward)
        guard let oldest = tracks.compactMap({ $0.samples.first?.at }).min() else {
            return (maxEnd, maxEnd)
        }
        let minEnd = oldest.addingTimeInterval(windowSpan - 600)
        return (min(minEnd, maxEnd), maxEnd)
    }

    private func clampViewport() {
        let bounds = hardBounds()
        if windowEnd < bounds.minEnd { windowEnd = bounds.minEnd }
        if windowEnd > bounds.maxEnd { windowEnd = bounds.maxEnd }
    }

    /// 手势进行中的夹取：允许滑出去 40% 跨度，松手再弹回来
    private func clampElastic() {
        let bounds = hardBounds()
        let slack = windowSpan * 0.4
        if windowEnd < bounds.minEnd.addingTimeInterval(-slack) {
            windowEnd = bounds.minEnd.addingTimeInterval(-slack)
        }
        if windowEnd > bounds.maxEnd.addingTimeInterval(slack) {
            windowEnd = bounds.maxEnd.addingTimeInterval(slack)
        }
    }

    /// 手势结束后把越界的视口弹回边界内
    private func scheduleSpringBack(after delay: TimeInterval = 0.25) {
        springWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.animateSpringBack() }
        }
        springWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func animateSpringBack() {
        let bounds = hardBounds()
        var target = windowEnd
        if target < bounds.minEnd { target = bounds.minEnd }
        if target > bounds.maxEnd { target = bounds.maxEnd }
        let distance = target.timeIntervalSince(windowEnd)
        guard abs(distance) > 0.5 else { return }

        let start = windowEnd
        let steps = 12
        var step = 0
        springTimer?.invalidate()
        springTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                step += 1
                let t = min(1.0, Double(step) / Double(steps))
                let eased = 1 - pow(1 - t, 3)
                self.windowEnd = start.addingTimeInterval(distance * eased)
                self.needsDisplay = true
                self.publishViewport()
                if t >= 1 { timer.invalidate(); self.springTimer = nil }
            }
        }
        if let springTimer { RunLoop.main.add(springTimer, forMode: .common) }
    }

    private func publishViewport() {
        onViewportMoved?(visibleStart, windowEnd)
    }

    // MARK: 绘制

    override var isFlipped: Bool { false }

    /// 窗口不是当前激活窗口时，第一次点按也要能直接拖图 / 双击全览；
    /// 否则那一下只会用来激活 App，手势像丢了一样。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let gradient = NSGradient(starting: DockStyle.surfaceTop, ending: DockStyle.surfaceBottom)
        gradient?.draw(in: path, angle: -90)

        if tracks.isEmpty {
            drawEmptyState()
        } else {
            drawGrid()
            drawSeries()
            drawLiveEdge()
            drawHover()
            paintHeaderBar()
            drawSparseHint()
        }
        NSGraphicsContext.restoreGraphicsState()

        DockStyle.edgeFaint.setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()
    }

    /// 刚装好、只有寥寥几个采样点时，别让用户以为图挂了
    private func drawSparseHint() {
        let total = tracks.reduce(0) { $0 + $1.samples.count }
        guard total <= 1 else { return }
        paintLabel(
            Localization.format(.plotSparseHint, total),
            in: NSRect(x: plot.minX, y: plot.midY - 6, width: plot.width, height: 14),
            font: .systemFont(ofSize: 10),
            color: DockStyle.inkTertiary,
            alignment: .center
        )
    }

    private func drawEmptyState() {
        paintLabel(
            Localization.text(.plotEmptyTitle),
            in: NSRect(x: 0, y: bounds.midY + 6, width: bounds.width, height: 16),
            font: .systemFont(ofSize: 12, weight: .medium),
            color: DockStyle.inkSecondary,
            alignment: .center
        )
        paintLabel(
            Localization.text(.plotEmptyDetail),
            in: NSRect(x: 0, y: bounds.midY - 14, width: bounds.width, height: 14),
            font: .systemFont(ofSize: 10),
            color: DockStyle.inkTertiary,
            alignment: .center
        )
    }

    // MARK: 网格与坐标

    private func drawGrid() {
        let plotPath = NSBezierPath(rect: plot)
        DockStyle.edgeFaint.setStroke()
        plotPath.lineWidth = 1
        plotPath.stroke()

        drawValueAxis()
        drawTimeAxis()
    }

    private func drawValueAxis() {
        // 主刻度每 10%，细线每 5% —— 比只画 25%/50% 更细
        for step in stride(from: 0, through: 20, by: 1) {
            let percent = Double(step) * 5
            let lineY = y(for: percent)
            let isMajor = step % 2 == 0

            let color = isMajor ? DockStyle.gridMajor : DockStyle.gridMinor
            color.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: lineY))
            line.line(to: NSPoint(x: plot.maxX, y: lineY))
            line.lineWidth = 1
            line.stroke()

            guard isMajor else { continue }
            paintLabel(
                "\(Int(percent))%",
                in: NSRect(x: 4, y: lineY - 6.5, width: insetLeft - 10, height: 13),
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                color: DockStyle.inkTertiary,
                alignment: .right
            )
        }
    }

    private func drawTimeAxis() {
        let step = Self.tickStep(for: windowSpan, width: plot.width)
        let showDate = windowSpan > 36 * 3600
        let dayFormatter = Self.stamps.day
        let clockFormatter = Self.stamps.clock
        let dayTimeFormatter = Self.stamps.dayTime
        let calendar = Calendar(identifier: .gregorian)

        // 刻度必须对齐到**本地时间**的整点，不能拿 epoch 取整：
        // 3 小时的步长在 UTC+8 下会落在 08:00 / 11:00 …，永远碰不到本地 0 点，
        // 日期标注就跟着消失了。以「当天 0 点」为锚点往后数，步长多大都能落在 0 点上。
        let anchor = calendar.startOfDay(for: visibleStart)
        let offset = max(0, visibleStart.timeIntervalSince(anchor))
        var tick = anchor.addingTimeInterval((offset / step).rounded(.up) * step)

        var ticks: [Date] = []
        while tick <= windowEnd, ticks.count < 400 {
            ticks.append(tick)
            tick = tick.addingTimeInterval(step)
        }

        // 这一屏里有没有 0 点刻度：没有的话，给第一个刻度补上日期，
        // 否则整排都是 "14:00" 这种看不出是哪天的写法
        let hasMidnight = ticks.contains {
            calendar.component(.hour, from: $0) == 0
                && calendar.component(.minute, from: $0) == 0
        }
        var dateDrawn = false
        // 竖线要"顶天立地"：上沿顶到顶部图例文字的上沿，下沿落到底部时间文字的下沿，
        // 只在绘图区里画的话，刻度看着像被框住了
        let gridTop = plot.maxY + Self.headerRowTopGap + Self.headerRowHeight
        let gridBottom = plot.minY - 15

        for date in ticks {
            let px = x(for: date)

            DockStyle.gridTick.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: px, y: gridBottom))
            line.line(to: NSPoint(x: px, y: gridTop))
            line.lineWidth = 1
            line.stroke()

            let isMidnight = calendar.component(.hour, from: date) == 0
                && calendar.component(.minute, from: date) == 0
            let label: String
            if isMidnight {
                label = dayFormatter.string(from: date)
                dateDrawn = true
            } else if showDate || (!hasMidnight && !dateDrawn) {
                label = dayTimeFormatter.string(from: date)
                dateDrawn = true
            } else {
                label = clockFormatter.string(from: date)
            }

            paintLabel(
                label,
                in: NSRect(x: px - 46, y: plot.minY - 15, width: 92, height: 12),
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                color: DockStyle.inkTertiary,
                alignment: .center
            )
        }

        // 次刻度：只在底部画短竖线，帮助定位
        let minorStep = step / 5
        if minorStep >= 30 {
            var minor = anchor.addingTimeInterval((offset / minorStep).rounded(.up) * minorStep)
            var minorCount = 0
            while minor <= windowEnd, minorCount < 2000 {
                minorCount += 1
                let px = x(for: minor)
                DockStyle.gridMinorTick.setStroke()
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: px, y: plot.minY))
                mark.line(to: NSPoint(x: px, y: plot.minY + 3))
                mark.lineWidth = 1
                mark.stroke()
                minor = minor.addingTimeInterval(minorStep)
            }
        }
    }

    private static let tickSteps: [TimeInterval] = [
        60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600,
        43200, 86400, 172_800, 432_000, 604_800
    ]

    /// 选一个让标签之间至少隔 76pt 的刻度步长
    private static func tickStep(for span: TimeInterval, width: CGFloat) -> TimeInterval {
        let minSpacing: CGFloat = 76
        for step in tickSteps {
            let count = span / step
            if count <= 0 { return step }
            if width / CGFloat(count) >= minSpacing { return step }
        }
        return tickSteps[tickSteps.count - 1]
    }

    /// 坐标轴与悬停提示的时间写法。格式化器建一次缓存起来，语言变了才重建。
    private struct Stamps {
        let clock: DateFormatter
        let day: DateFormatter
        let full: DateFormatter
        let dayTime: DateFormatter
    }

    private static var stampCache: (locale: String, stamps: Stamps)?

    private static var stamps: Stamps {
        let wanted = Localization.current.localeID
        if let cached = stampCache, cached.locale == wanted { return cached.stamps }
        let language = Localization.current
        let built = Stamps(
            clock: axisFormatter("HH:mm"),
            day: axisFormatter(language.dayPattern),
            full: axisFormatter(language.fullStampPattern),
            dayTime: axisFormatter(language.dayTimePattern)
        )
        stampCache = (wanted, built)
        return built
    }

    private static func axisFormatter(_ pattern: String) -> DateFormatter {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: Localization.current.localeID)
        // 阿拉伯语等地区的系统日历不是公历，不钉死会算出别的年份
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = pattern
        return stamp
    }

    // MARK: 曲线

    private func drawSeries() {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()

        drawThresholdLine()

        // 两条预测的「见底」文字很容易撞在一起，画的时候记下占位，撞了就只留小圈
        var labelZones: [ClosedRange<CGFloat>] = []

        for (index, item) in tracks.enumerated() {
            let runs = buildRuns(samples: item.samples, start: visibleStart, end: windowEnd)
            guard !runs.isEmpty else { continue }

            for run in runs {
                guard run.count > 1 else {
                    // 单点：画个小圆，避免"什么都没画"
                    let dot = NSRect(x: run[0].x - 2.5, y: run[0].y - 2.5, width: 5, height: 5)
                    item.color.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                    continue
                }
                let line = NSBezierPath()
                line.move(to: run[0])
                for point in run.dropFirst() { line.line(to: point) }
                line.lineWidth = 1.6
                line.lineJoinStyle = .round
                line.lineCapStyle = .round
                item.color.setStroke()
                line.stroke()
            }

            // 面积：淡淡一层，帮助看出趋势。
            // 一次填满整条曲线（跨过断档），否则断档处会留下一个黑色矩形缺口，
            // 看着就像曲线"断了一截"。
            let points = runs.flatMap { $0 }
            if points.count > 1, let head = points.first, let tail = points.last {
                let area = NSBezierPath()
                area.move(to: NSPoint(x: head.x, y: plot.minY))
                for point in points { area.line(to: point) }
                area.line(to: NSPoint(x: tail.x, y: plot.minY))
                area.close()
                item.color.withAlphaComponent(0.10).setFill()
                area.fill()
            }

            // 断档（程序退出 / 睡眠导致没采到数据）：前后两端直接用红线连上，
            // 一眼能看出「这段是空的，不是真的掉到 0」
            for index in 1..<max(1, runs.count) {
                guard let previous = runs[index - 1].last, let head = runs[index].first else { continue }
                let bridge = NSBezierPath()
                bridge.move(to: previous)
                bridge.line(to: head)
                bridge.lineWidth = 1.3
                bridge.lineCapStyle = .round
                DockStyle.gapBridge.setStroke()
                bridge.stroke()
            }

            drawProjection(
                for: item,
                index: index,
                forecast: index < projections.count ? projections[index] : nil,
                labelZones: &labelZones
            )
        }

        // 画在曲线之上：重置那一刻曲线本身是竖直向上的，压在下面等于看不见
        drawResetMarkers()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 预测线：沿最后一段的速度往外推。
    /// 重置先到的话，趋势线照样画，只是截在重置那一刻（不标"见底"）——
    /// 整条都不画会让人以为预测失效了。
    private func drawProjection(
        for band: Band,
        index: Int,
        forecast: ExhaustionForecast?,
        labelZones: inout [ClosedRange<CGFloat>]
    ) {
        guard let forecast, let last = band.samples.last,
              forecast.zeroDate > last.at else { return }

        // 更长的窗口（例如周额度）当前就已经见底：本档（5 小时额度）即便刚重置到 100%
        // 也只是名义值，实际被连坐清零，没有「还能烧多久」可言。
        // 预测线平铺在 0%，不再按自身速度往下推。
        if longerBandFlooredNow(for: band, index: index) {
            drawFlooredProjection(for: band, last: last)
            return
        }

        // 主档见底后本档不消耗，预测是从「拦截结束」才开始掉
        let holdDate = max(blockedUntil ?? last.at, last.at)
        func remaining(at moment: Date) -> Double {
            let minutes = max(0, moment.timeIntervalSince(holdDate)) / 60
            return max(0, last.leftPercent - forecast.dropPerMinute * minutes)
        }

        // 三种情形：
        // 1) 自己就会见底 → 趋势线一路降到 0
        // 2) 重置先到 → 趋势线画到重置那一刻就停，不归零
        // 3) 更长的窗口（周额度）先归零 → 趋势线**按自己的速度**外推到那一刻，
        //    然后在那里垂直掉到 0（不能把两个点直接连一条斜线，那和真实趋势无关）
        var zeroAt: Date?
        var trendEndDate: Date
        var cliffs = false

        if let cut = accountCutoff(for: band, index: index),
           cut > last.at, cut < forecast.zeroDate {
            zeroAt = cut
            cliffs = true
            trendEndDate = cut
        } else if let resetAt = band.resetAt, forecast.zeroDate >= resetAt {
            zeroAt = nil
            trendEndDate = resetAt
        } else {
            zeroAt = forecast.zeroDate
            trendEndDate = forecast.zeroDate
        }
        // 终点必须落在「按真实速度算出来的剩余量」上：
        // 重置先到时是重置那一刻的预测值（不是 0），自身耗尽/连带归零时才是 0。
        // 之前这里对非 cliffs 一律写 0，直接把线变成了「当前点连重置点」的假趋势。
        let trendEnd = NSPoint(
            x: x(for: trendEndDate),
            y: y(for: remaining(at: trendEndDate))
        )

        let start = NSPoint(x: x(for: last.at), y: y(for: last.leftPercent))

        let line = NSBezierPath()
        line.move(to: start)
        // 主档拦截期间本档一格不掉：先画平线扛到主档重置，再从那里按速度降
        if let blocked = blockedUntil, blocked > last.at, blocked < trendEndDate {
            line.line(to: NSPoint(x: x(for: blocked), y: y(for: last.leftPercent)))
        }
        line.line(to: trendEnd)
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.lineWidth = 1.3
        line.lineCapStyle = .round
        band.color.withAlphaComponent(0.6).setStroke()
        line.stroke()

        // 被更长的窗口连坐清零：趋势走到那一刻，再垂直归零
        if cliffs, let zeroAt {
            let cliff = NSBezierPath()
            cliff.move(to: trendEnd)
            cliff.line(to: NSPoint(x: x(for: zeroAt), y: y(for: 0)))
            cliff.lineWidth = 1.6
            cliff.lineCapStyle = .round
            band.color.withAlphaComponent(0.85).setStroke()
            cliff.stroke()
        }

        // 到不了 0（重置先到）：线画到重置线为止就够了，不画圈不写字
        guard let zeroAt else { return }
        let end = NSPoint(x: x(for: zeroAt), y: y(for: 0))

        // 只有落在这段视窗里才标节点，否则等于画在屏幕外
        guard zeroAt >= visibleStart, zeroAt <= windowEnd else { return }
        let ring = NSBezierPath(ovalIn: NSRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
        ring.lineWidth = 1.2
        band.color.setStroke()
        band.color.withAlphaComponent(0.2).setFill()
        ring.fill()
        ring.stroke()

        let caption = Localization.format(
            .plotBottomOut, Self.stamps.clock.string(from: zeroAt)
        )
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let width = ceil((caption as NSString).size(withAttributes: [.font: font]).width) + 4
        let flipped = end.x + 6 + width > plot.maxX
        let originX = flipped ? end.x - 6 - width : end.x + 6
        let zone = originX...(originX + width)
        // 两条曲线的见底时刻挨得近时，后一条不写字，只留圈，免得叠成一团
        guard !labelZones.contains(where: { $0.overlaps(zone) }) else { return }
        labelZones.append(zone)
        paintLabel(
            caption,
            in: NSRect(x: originX, y: plot.minY + 4, width: width, height: 12),
            font: font,
            color: band.color.withAlphaComponent(0.85)
        )
    }

    /// 更长的那一档先归零的时刻：本档到那一刻会被一起清零，预测时间以它为准。
    /// （周额度到 0，5 小时额度也直接用不了；反过来只是限流，不会把周额度清零。）
    private func accountCutoff(for band: Band, index: Int) -> Date? {
        var cut: Date?
        for (otherIndex, other) in tracks.enumerated() where other.spanMinutes > band.spanMinutes {
            guard otherIndex < projections.count, let forecast = projections[otherIndex] else { continue }
            // 它自己这一轮撑不到见底（中途会重置）就谈不上连带
            if let otherReset = other.resetAt, forecast.zeroDate >= otherReset { continue }
            if cut == nil || forecast.zeroDate < cut! { cut = forecast.zeroDate }
        }
        return cut
    }

    /// 是否存在「更长的窗口」当前已经见底（剩余≈0）。
    /// 例如周额度已经归零，那么 5 小时额度即便刚重置到 100% 也只是名义上的——
    /// 实际可用被周额度连坐清零，预测线应当平铺在 0，而不是按自己的速度继续往下烧。
    /// 注意这里和 `accountCutoff` 互补：后者只在更长档「还有预测」时给出未来归零时刻，
    /// 更长档一旦已经跌到 0，它的 projection 是 nil，必须由这里单独兜住。
    private func longerBandFlooredNow(for band: Band, index: Int) -> Bool {
        for (otherIndex, other) in tracks.enumerated()
        where otherIndex != index && other.spanMinutes > band.spanMinutes {
            if let last = other.samples.last, last.leftPercent <= 0.2 { return true }
        }
        return false
    }

    /// 更长窗口已经见底：本档预测线平铺在 0%——
    /// 从当前点垂直落到 0，之后一直水平延伸，不再画任何消耗趋势。
    private func drawFlooredProjection(for band: Band, last: LedgerSample) {
        let nowX = x(for: last.at)
        let baseY = y(for: last.leftPercent)
        let zeroY = y(for: 0)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: nowX, y: baseY))
        line.line(to: NSPoint(x: nowX, y: zeroY))      // 此刻垂直归零
        line.line(to: NSPoint(x: plot.maxX, y: zeroY)) // 之后平铺在 0%
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.lineWidth = 1.3
        line.lineCapStyle = .round
        band.color.withAlphaComponent(0.6).setStroke()
        line.stroke()
    }

    /// 重置时刻：一条贯穿绘图区的亮黄色竖线，顶上写明是哪一档额度重置、
    /// 以及「上次重置多久前」或「距下次重置还有多久」。
    private func drawResetMarkers() {
        // 过去检测到的重置 + 每一档「下一次」重置（服务端给的重置时刻），
        // 后者常常落在数据右侧的空白区，不画出来的话看着就像少了一条线
        var marks = resetMarkers
        let now = Date()
        for band in tracks {
            guard let resetAt = band.resetAt, resetAt > now else { continue }
            let duplicated = marks.contains { abs($0.at.timeIntervalSince(resetAt)) <= 120 }
            guard !duplicated else { continue }
            marks.append(ResetMark(at: resetAt, caption: band.title))
        }
        guard !marks.isEmpty else { return }
        let titleFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let agoFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        // 「上次重置」只给已经发生过的那条写，未来的重置写「距重置」
        let newestPast = marks.filter { $0.at <= now }.map(\.at).max()
        // 几条竖线的标注挨得近时会叠成一团：记下已占的矩形，第一排撞了就往下挪一排
        var taken: [NSRect] = []

        for mark in marks.sorted(by: { $0.at < $1.at }) where mark.at >= visibleStart && mark.at <= windowEnd {
            let px = x(for: mark.at)
            // 浅黄虚线：既是参照又不抢曲线；底下垫一条极淡的窄带，竖直跳变处也看得见
            DockStyle.resetMark.withAlphaComponent(0.10).setFill()
            NSRect(x: px - 2, y: plot.minY, width: 4, height: plot.height).fill()

            let line = NSBezierPath()
            line.move(to: NSPoint(x: px, y: plot.minY))
            line.line(to: NSPoint(x: px, y: plot.maxY))
            line.setLineDash([5, 3], count: 2, phase: 0)
            line.lineWidth = 1.4
            line.lineCapStyle = .butt
            DockStyle.resetMark.withAlphaComponent(0.55).setStroke()
            line.stroke()

            // 已发生的：写「上次重置：x 小时前」；还没到的：写「距重置 x」
            var lines = [Localization.resetMomentLabel(caption: mark.caption)]
            if mark.at == newestPast {
                lines.append(
                    Localization.format(
                        .plotLastReset,
                        Localization.spellElapsed(now.timeIntervalSince(mark.at))
                    )
                )
            } else if mark.at > now {
                lines.append(
                    Localization.format(
                        .plotNextReset,
                        Localization.spellCountdown(mark.at.timeIntervalSince(now))
                    )
                )
            }

            var widest: CGFloat = 0
            for text in lines {
                let used = text == lines[0] ? titleFont : agoFont
                widest = max(widest, ceil((text as NSString).size(withAttributes: [.font: used]).width))
            }
            let boxWidth = widest + 12
            let boxHeight = CGFloat(lines.count) * 12 + 6
            // 右边放不下就翻到线的左边
            let originX = px + 6 + boxWidth > plot.maxX ? px - 6 - boxWidth : px + 6

            // 从上往下找第一处不撞的空位；两排都撞就不写字，只留线
            let topY = plot.maxY - boxHeight - 5
            let candidates = [topY, topY - boxHeight - 4]
            guard let boxY = candidates.first(where: { y in
                let probe = NSRect(x: originX, y: y, width: boxWidth, height: boxHeight)
                return !taken.contains { $0.intersects(probe) }
            }) else { continue }

            let box = NSRect(x: originX, y: boxY, width: boxWidth, height: boxHeight)
            taken.append(box)
            DockStyle.tooltipBg.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()

            for (index, text) in lines.enumerated() {
                let used = index == 0 ? titleFont : agoFont
                paintLabel(
                    text,
                    in: NSRect(
                        x: box.minX + 6,
                        y: box.maxY - 15 - CGFloat(index) * 12,
                        width: widest + 2,
                        height: 12
                    ),
                    font: used,
                    color: DockStyle.resetMark.withAlphaComponent(index == 0 ? 0.95 : 0.75)
                )
            }
        }
    }

    /// 低额度警戒线（用设置里的阈值，默认 20%）
    private func drawThresholdLine() {        let threshold = Double(Preferences.shared.warnBelowPercent)
        guard threshold > 0, threshold < 100 else { return }
        let lineY = y(for: threshold)
        let line = NSBezierPath()
        line.move(to: NSPoint(x: plot.minX, y: lineY))
        line.line(to: NSPoint(x: plot.maxX, y: lineY))
        line.setLineDash([3, 3], count: 2, phase: 0)
        line.lineWidth = 1
        DockStyle.caution.withAlphaComponent(0.35).setStroke()
        line.stroke()
    }

    /// 把点序列切成"连续段"：中间缺了一段（程序退出 / 睡眠）就断开，
    /// 前后两端改用红线直连，一眼能看出「这段没采到数据」。
    /// 阈值 5 分钟起：正常轮询就 60 秒一条，超过 5 分钟没数据才算真缺。
    private func buildRuns(samples: [LedgerSample], start: Date, end: Date) -> [[NSPoint]] {
        guard !samples.isEmpty else { return [] }
        let gap = max(300, windowSpan / 120)
        let lower = max(0, Self.firstIndex(in: samples, atOrAfter: start) - 1)
        var upper = Self.firstIndex(in: samples, atOrAfter: end)
        if upper < samples.count { upper += 1 }
        guard lower < min(upper, samples.count) else { return [] }

        var runs: [[NSPoint]] = []
        var run: [NSPoint] = []
        var lastX: CGFloat = -.greatestFiniteMagnitude
        var previousDate: Date?

        for index in lower..<min(upper, samples.count) {
            let point = samples[index]
            if let previousDate, point.at.timeIntervalSince(previousDate) > gap {
                if !run.isEmpty { runs.append(run) }
                run = []
                lastX = -.greatestFiniteMagnitude
            }
            previousDate = point.at

            let px = x(for: point.at)
            let inside = point.at >= start && point.at <= end
            // 像素级抽稀：同一像素列只留一个点，几万个点也能流畅画
            if inside, px - lastX < 0.4, !run.isEmpty { continue }
            if inside { lastX = px }
            run.append(NSPoint(x: px, y: y(for: point.leftPercent)))
        }
        if run.count > 1 { runs.append(run) }
        // 只有单个孤立采样点时也保留：画成一个圆点，而不是什么都不画
        else if run.count == 1 { runs.append(run) }
        return runs
    }

    private static func firstIndex(in samples: [LedgerSample], atOrAfter date: Date) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].at < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// 现在时刻：一条灰色竖线，底下挂一个跟着当前时间走的刻度。
    /// 时间轴上的刻度是整点对齐的，看不出「现在」在哪，所以单独补一条。
    private func drawLiveEdge() {
        let now = Date()
        guard now >= visibleStart, now <= windowEnd else { return }
        let px = x(for: now)

        // 先铺一层宽一点的柔光，让它从一堆淡网格里跳出来
        let glow = NSBezierPath()
        glow.move(to: NSPoint(x: px, y: plot.minY))
        glow.line(to: NSPoint(x: px, y: plot.maxY))
        glow.lineWidth = 6
        DockStyle.nowLine.withAlphaComponent(0.16).setStroke()
        glow.stroke()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: px, y: plot.minY))
        line.line(to: NSPoint(x: px, y: plot.maxY))
        line.lineWidth = 2.2
        DockStyle.nowLine.setStroke()
        line.stroke()

        // 顶端一个小三角，指针一样指住「现在」
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: px - 4, y: plot.maxY + 1))
        pointer.line(to: NSPoint(x: px + 4, y: plot.maxY + 1))
        pointer.line(to: NSPoint(x: px, y: plot.maxY - 5))
        pointer.close()
        DockStyle.nowLine.setFill()
        pointer.fill()

        // 底部刻度：跟着当前时间走，压在时间轴刻度上面。实心灰底比一圈细边显眼得多
        let text = Self.stamps.clock.string(from: now)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 11
        let originX = min(max(px - width / 2, plot.minX), plot.maxX - width)
        let box = NSRect(x: originX, y: plot.minY - 16, width: width, height: 14)
        let pill = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
        DockStyle.nowLine.setFill()
        pill.fill()
        paintLabel(
            text,
            in: NSRect(x: box.minX, y: box.minY + 3, width: box.width, height: 10),
            font: font,
            color: .white,
            alignment: .center
        )
    }

    // MARK: 十字准线

    private func drawHover() {
        guard let hoverX, hoverX >= plot.minX, hoverX <= plot.maxX else { return }
        let hoverDate = date(atX: hoverX)

        DockStyle.hoverLine.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: hoverX, y: plot.minY))
        line.line(to: NSPoint(x: hoverX, y: plot.maxY))
        line.lineWidth = 1
        line.stroke()

        var rows: [String] = []
        for (index, item) in tracks.enumerated() {
            // 指针落在「最后一条采样之后」＝预测段，按拟合速度外推，并在文案里标出来
            if let last = item.samples.last, hoverDate > last.at,
               let forecast = index < projections.count ? projections[index] : nil,
               hoverDate <= forecast.zeroDate {
                // 更长窗口已见底：本档被连坐清零，预测段一律显示 0，不按自身速度外推
                let predicted: Double
                if longerBandFlooredNow(for: item, index: index) {
                    predicted = 0
                } else {
                    let holdDate = max(blockedUntil ?? last.at, last.at)
                    let minutes = max(0, hoverDate.timeIntervalSince(holdDate)) / 60
                    predicted = max(0, last.leftPercent - forecast.dropPerMinute * minutes)
                }
                let dot = NSRect(x: hoverX - 2.5, y: y(for: predicted) - 2.5, width: 5, height: 5)
                item.color.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: dot).fill()
                DockStyle.dotRing.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1))
                ring.lineWidth = 1
                ring.stroke()
                rows.append(Localization.forecastRow(caption: item.title, percent: Int(predicted.rounded())))
                continue
            }

            guard let point = value(at: hoverDate, in: item.samples) else { continue }
            let dot = NSRect(x: hoverX - 2.5, y: y(for: point.leftPercent) - 2.5, width: 5, height: 5)
            item.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            DockStyle.dotRing.setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1))
            ring.lineWidth = 1
            ring.stroke()
            rows.append("\(item.title) \(Int(point.leftPercent.rounded()))%")
        }
        guard !rows.isEmpty else { return }

        let title = Self.stamps.full.string(from: hoverDate)
        let lines = [title] + rows

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        var width: CGFloat = 0
        for (index, text) in lines.enumerated() {
            let used = index == 0 ? titleFont : font
            width = max(width, ceil((text as NSString).size(withAttributes: [.font: used]).width))
        }
        let boxWidth = width + 18
        let boxHeight = CGFloat(lines.count) * 14 + 10

        var boxX = hoverX + 12
        if boxX + boxWidth > bounds.maxX - 4 { boxX = hoverX - 12 - boxWidth }
        var boxY = plot.midY - boxHeight / 2
        boxY = min(max(boxY, plot.minY + 4), plot.maxY - boxHeight - 4)

        let box = NSRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        DockStyle.tooltipBg.setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        path.fill()
        DockStyle.tooltipBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        for (index, text) in lines.enumerated() {
            let used = index == 0 ? titleFont : font
            let color = index == 0 ? DockStyle.inkTertiary : DockStyle.inkPrimary
            let rect = NSRect(
                x: box.minX + 9,
                y: box.maxY - 16 - CGFloat(index) * 14,
                width: width + 2,
                height: 13
            )
            paintLabel(text, in: rect, font: used, color: color)
        }
    }

    /// 找最接近该时刻的采样点
    private func value(at date: Date, in samples: [LedgerSample]) -> LedgerSample? {
        guard !samples.isEmpty else { return nil }
        let index = Self.firstIndex(in: samples, atOrAfter: date)
        let candidates = [index - 1, index].filter { $0 >= 0 && $0 < samples.count }
        return candidates.min {
            abs(samples[$0].at.timeIntervalSince(date)) < abs(samples[$1].at.timeIntervalSince(date))
        }.map { samples[$0] }
    }

    // MARK: 顶部图例

    private func paintHeaderBar() {
        var cursorX: CGFloat = Self.headerInset
        let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let hintFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        // 「整排共用一条中线」：NSString.draw(in:) 是把文字在给定矩形里**垂直居中**的，
        // 不是按基线摆的 —— 给不同字号各自算 rect（baseline - ascender）反而对不齐。
        // 所以这一排三四种字号共用一个矩形：同一顶边、同一高度，墨迹中线自然重合。
        let rowTop = plot.maxY + Self.headerRowTopGap
        let rowHeight = Self.headerRowHeight
        // 实测：墨迹中心落在矩形中心再往上约 1pt，圆点照这个位置摆才跟文字同心
        let rowCenter = rowTop + rowHeight / 2 + 1

        func drawOnRow(_ text: String, font: NSFont, color: NSColor, at x: CGFloat) -> CGFloat {
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            paintLabel(
                text,
                in: NSRect(x: x, y: rowTop, width: width + 2, height: rowHeight),
                font: font,
                color: color
            )
            return x + width
        }

        for (index, item) in tracks.enumerated() {
            let latest = item.samples.last
            let valueText = latest.map { "\(Int($0.leftPercent.rounded()))%" } ?? "--"

            // 圆点与文字共用 `rowCenter`，高度不再各对各的
            let dotSize: CGFloat = 6
            let dot = NSRect(
                x: cursorX,
                y: rowCenter - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            item.color.setFill()
            NSBezierPath(ovalIn: dot).fill()

            cursorX = drawOnRow(item.title, font: chipFont, color: DockStyle.inkTertiary, at: cursorX + 10)
            cursorX = drawOnRow(valueText, font: valueFont, color: DockStyle.inkPrimary, at: cursorX + 5)

            // 预测见底时间：图上看不到交叉点时，至少这里有句话
            if let hint = projectionHint(at: index) {
                cursorX = drawOnRow(hint, font: hintFont, color: item.color.withAlphaComponent(0.85), at: cursorX + 6)
            }
            cursorX += 18
        }

        let span = Self.spanText(windowSpan)
        let spanFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        let spanWidth = ceil((span as NSString).size(withAttributes: [.font: spanFont]).width)
        _ = drawOnRow(
            span,
            font: spanFont,
            color: DockStyle.inkTertiary,
            at: bounds.maxX - Self.headerInset - spanWidth
        )
    }

    /// 图例里那半句「见底 21:34」；这轮不会见底时返回 nil
    private func projectionHint(at index: Int) -> String? {
        guard index < projections.count, let forecast = projections[index],
              forecast.dropPerMinute > 0 else { return nil }
        if index < tracks.count, let resetAt = tracks[index].resetAt, forecast.zeroDate >= resetAt {
            return nil
        }
        // 更长窗口已见底：本档被连坐清零，不写「见底」时间（那条时间本来就不准）
        if index < tracks.count, longerBandFlooredNow(for: tracks[index], index: index) { return nil }
        let far = forecast.zeroDate.timeIntervalSinceNow > 12 * 3_600
        let stamp = far ? Self.stamps.dayTime : Self.stamps.clock
        return Localization.format(.plotBottomOut, stamp.string(from: forecast.zeroDate))
    }

    private static func spanText(_ span: TimeInterval) -> String {
        Localization.format(.plotSpan, Localization.spellSpan(span))
    }

    // MARK: 工具

    private func paintLabel(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

private extension Int {
    var days: TimeInterval { TimeInterval(self) * 86_400 }
}
