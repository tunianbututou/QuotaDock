import AppKit
import Combine

/// 窗口层级策略。
/// 置顶浮窗（28）不会被系统截图（⌘⇧4 → 空格）的窗口选择列出，因为它不是普通层级；
/// 用户打开「允许系统截图选中」后，所有窗口统一回到普通层级。
@MainActor enum WindowStrata {
    /// 截图界面正开着（WidgetHost 的看门定时器负责刷新）。此时所有窗口都退到普通层级。
    static var captureYield = false

    static var widget: NSWindow.Level {
        (captureYield || Preferences.shared.screenshotPickable) ? .normal : NSWindow.Level(rawValue: 28)
    }
    /// 设置页 / 趋势图：默认是普通层级，能被别的窗口正常盖住；
    /// 只有当用户在设置里打开「辅助窗口置顶」，或者截图让路被关掉时才浮起来。
    static var companion: NSWindow.Level {
        guard !captureYield, !Preferences.shared.screenshotPickable else { return .normal }
        return Preferences.shared.companionOnTop ? NSWindow.Level(rawValue: 29) : .normal
    }
}

/// 悬浮窗：无边框、常驻置顶、整块可拖、松手贴边吸附；支持折叠成贴边缩略条。
@MainActor final class WidgetHost: NSObject, NSWindowDelegate {
    /// 吸附距离（pt）。太大就会出现「离边还有一截就贴上去」的手感，
    /// 10pt 约等于光标贴近边缘的视觉距离；越过边界时仍然吸得住（单侧比较）。
    private static let grabDistance: CGFloat = 10

    private enum Key {
        static let expandedFrame = "dock.frame.expanded"
        static let compactFrame = "dock.frame.compact"
        static let compactActive = "dock.compact.active"
        static let compactHorizontal = "dock.compact.horizontal"
    }

    /// 缩略条贴的是哪条边。决定收缩/展开时用哪个角当锚点。
    private enum DockEdge {
        case top, bottom, left, right
    }

    private let surface: NSPanel
    private let canvas: DockWidget
    private let defaults = UserDefaults.standard
    private var snapMuted = false
    /// 折叠条手动拖动期间暂停吸附/换向，避免和拖动本身互相打架
    private var dragInFlight = false
    private var bag: Set<AnyCancellable> = []
    /// 「为截图让路」的定时恢复任务
    private var yieldTimer: Timer?
    /// 盯着截图界面的看门定时器
    private var captureWatch: Timer?
    private(set) var shape: WidgetShape = .expanded

    var isVisible: Bool { surface.isVisible }

    override init() {
        canvas = DockWidget(frame: NSRect(origin: .zero, size: WidgetShape.expanded.size))
        surface = NSPanel(
            contentRect: NSRect(origin: .zero, size: WidgetShape.expanded.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        surface.title = "QuotaDock 悬浮窗"
        surface.isFloatingPanel = true
        // 注意：必须在 isFloatingPanel 之后再设 level，否则会被重置回 floating。
        refreshWindowLevel()
        surface.becomesKeyOnlyIfNeeded = true
        surface.hidesOnDeactivate = false
        surface.isReleasedWhenClosed = false
        surface.isOpaque = false
        surface.backgroundColor = .clear
        surface.hasShadow = true
        // 拖动全部由 DockWidget 自己处理（原生拖动在非激活面板上松手会弹回原位）
        surface.isMovableByWindowBackground = false
        surface.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.delegate = self
        surface.contentView = canvas

        wireCanvas()
        restoreLayout()
        startCaptureWatch()

        // 数据变化后重绘
        QuotaStream.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.canvas.needsDisplay = true }
            }
            .store(in: &bag)

        // 换语言：自绘的悬浮窗要立刻重画
        NotificationCenter.default.addObserver(
            forName: .languageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvas.needsDisplay = true }
        }
    }

    /// 画布上的手势回调统一在这里接线
    private func wireCanvas() {
        canvas.onDismiss = { [weak self] in self?.hide() }
        canvas.onSyncNow = { Task { await QuotaStream.shared.pull() } }
        canvas.onFold = { [weak self] in self?.fold() }
        canvas.onUnfold = { [weak self] in self?.unfold() }
        canvas.onOpenPreferences = { PreferencesHost.shared.show() }
        canvas.onOpenTimeline = { TimelineHost.shared.show() }
        canvas.onDragStart = { [weak self] in self?.dragInFlight = true }
        canvas.onCompactDragEnd = { [weak self] shouldSnap in
            guard let self else { return }
            self.dragInFlight = false
            if shouldSnap { self.dockCompactToEdge() }
            self.persistFrame()
        }
        canvas.onDragEnd = { [weak self] in
            guard let self else { return }
            self.dragInFlight = false
            self.dockToNearestEdge()
            self.persistFrame()
        }
    }

    // MARK: 屏幕可用区域

    /// 浮窗所在屏幕去掉菜单栏与 Dock 之后的那块地
    private var liveBounds: NSRect? {
        (surface.screen ?? NSScreen.main)?.visibleFrame
    }

    /// 把矩形整体挪进可用区域，尺寸不变。窗口哪怕整块在屏幕外，也只是被拉回来。
    private func clamp(_ rect: NSRect, into bounds: NSRect) -> NSRect {
        var out = rect
        out.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        out.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return out
    }

    /// 静默改框：吸附、复位这类位置修正，不该再触发一轮 windowDidMove
    private func commitQuietly(_ rect: NSRect, display: Bool = true) {
        guard rect != surface.frame else { return }
        snapMuted = true
        surface.setFrame(rect, display: display)
        snapMuted = false
    }

    /// 让窗口重新上屏。AppKit 只在重新显示时才会应用新改的 level / collectionBehavior。
    private func relist() {
        guard surface.isVisible else { return }
        surface.orderOut(nil)
        surface.orderFrontRegardless()
    }

    // MARK: 窗口层级 / 截图

    /// 系统截图（⌘⇧4 → 空格）的窗口选择只认普通层级的窗口，
    /// 置顶浮窗（layer > 0）不会出现在候选里。这里按偏好决定是否降到普通层级。
    func refreshWindowLevel() {
        yieldTimer?.invalidate()
        yieldTimer = nil
        applyWindowLevel()
    }

    /// 层级的唯一出口：截图让路（手动 12 秒）或截图界面开着时都用普通层级
    private func applyWindowLevel() {
        surface.level = (yieldTimer != nil || WindowStrata.captureYield) ? .normal : WindowStrata.widget
        if surface.isVisible { surface.orderFrontRegardless() }
    }

    /// 临时让路：把窗口降到普通层级，`seconds` 秒后自动恢复置顶。
    /// 用于「我只想截一张悬浮窗的图」这种一次性场景，不必改偏好。
    func yieldForScreenCapture(seconds: TimeInterval = 12) {
        yieldTimer?.invalidate()
        applyWindowLevel()

        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.yieldTimer = nil
                self.refreshWindowLevel()
            }
        }
        yieldTimer = timer
    }

    var isYieldedForScreenCapture: Bool {
        surface.level.rawValue == NSWindow.Level.normal.rawValue
    }

    // MARK: 截图界面自动让路

    /// 截图界面（⌘⇧4 / ⌘⇧5 / screencapture -i）的压暗遮罩在 layer 24，
    /// 比悬浮窗（28）和趋势窗（29）都低——不退位的话它们会浮在截图画面上，
    /// 既刺眼又框选不到。这里每半秒看一眼，界面一出现全体降到普通层级，结束自动回位。
    private func startCaptureWatch() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCaptureYield() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureWatch = timer
    }

    private func syncCaptureYield() {
        let active = DockWidget.captureUIActive()
        guard active != WindowStrata.captureYield else { return }
        WindowStrata.captureYield = active
        applyWindowLevel()
        // 伴生窗口（趋势图 / 设置页）听到广播后自己降级 / 回位
        NotificationCenter.default.post(name: .captureYieldChanged, object: nil)
    }

    // MARK: 显隐

    func show() {
        keepOnScreen()
        surface.orderFrontRegardless()
        Preferences.shared.showWidget = true
    }

    func hide() {
        surface.orderOut(nil)
        Preferences.shared.showWidget = false
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// 设置页里的「重置悬浮窗位置」：回到右上角完整形态
    func resetPosition() {
        if shape.isCompact {
            shape = .expanded
            canvas.shape = .expanded
            surface.minSize = .zero
            defaults.set(false, forKey: Key.compactActive)
        }
        let target = defaultExpandedFrame(near: NSScreen.main?.visibleFrame ?? .zero)
        commitFrame(target, animated: true)
        persistFrame()
        show()
    }

    /// 「跟随所有桌面显示」开关
    func applySpaceBehaviour(_ on: Bool) {
        let everywhere: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        surface.collectionBehavior = on ? everywhere : [.managed]
        relist()
    }

    // MARK: 折叠 / 展开

    func fold() {
        guard shape == .expanded else { return }
        persistFrame()

        guard let bounds = liveBounds else { return }
        let expanded = surface.frame

        // 离哪条边最近就贴哪条：上下 → 横条；左右 → 竖条
        let (edge, _) = closestEdge(of: expanded, in: bounds)
        let target: WidgetShape = (edge == .top || edge == .bottom) ? .pill : .rail

        morphToCompact(shape: target, edge: edge, anchoredAt: expanded, visible: bounds)
    }

    /// 展开：以缩略条**当前位置**为准，而不是收缩前的旧位置。
    /// 锚点规则与收缩对称——贴上边/左右边用左上角，贴下边用左下角。
    func unfold() {
        guard shape.isCompact else { return }

        let compact = surface.frame
        let bounds = visibleFrame(for: compact)
        let edge = restingEdge(of: compact, in: bounds)
        shape = .expanded
        canvas.shape = .expanded
        surface.minSize = .zero

        let size = WidgetShape.expanded.size
        var origin = NSPoint.zero
        origin.x = (edge == .right) ? compact.maxX - size.width : compact.minX
        origin.y = (edge == .bottom) ? compact.minY : compact.maxY - size.height

        let settled = clamp(NSRect(origin: origin, size: size), into: bounds)
        commitFrame(settled, animated: true)

        defaults.set(false, forKey: Key.compactActive)
        persistFrame()
        keepOnScreen()
    }

    /// 统一的尺寸/位置切换入口。
    /// 动画必须「整段」压住吸附：`setFrame(animate:)` 是异步返回的，
    /// 只要一个动画帧里 windowDidMove 跑进来，dockCompactToEdge 就会把缩略条
    /// 钉在半路（顶边对不齐）。所以动画结束前 snapMuted 不能松手，
    /// 结束后再补一次强制对齐。
    private func commitFrame(_ rect: NSRect, animated: Bool) {
        guard animated, animationsAllowed else {
            commitQuietly(rect)
            return
        }

        snapMuted = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            surface.animator().setFrame(rect, display: true, animate: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapMuted = false
                if self.surface.frame != rect {
                    self.commitQuietly(rect)
                }
                self.persistFrame()
            }
        })
    }

    /// 统一的缩略形态切换（含尺寸、贴边定位、方向记忆）
    /// 水平方向保留完整窗的**左**边缘、垂直方向保留**上**边缘，
    /// 所以左对齐的窗口收缩后仍然左对齐，不会变成居中。
    private func morphToCompact(
        shape target: WidgetShape,
        edge: DockEdge,
        anchoredAt source: NSRect,
        visible: NSRect,
        animated: Bool = true
    ) {
        self.shape = target
        canvas.shape = target

        let size = target.size
        var origin = NSPoint.zero
        let t = Self.grabDistance

        switch target {
        case .pill:
            // 水平方向：默认保留完整窗的左边缘（左对齐 → 收缩后仍左对齐）；
            // 但若完整窗本来就贴着右边缘，则改保留右边缘，避免缩略条从右上角"缩回中间"。
            let rightFlush = abs(source.maxX - visible.maxX) <= t
            let leftFlush = abs(source.minX - visible.minX) <= t
            if rightFlush, !leftFlush {
                origin.x = visible.maxX - size.width
            } else {
                origin.x = min(max(source.minX, visible.minX), visible.maxX - size.width)
            }
            origin.y = (edge == .bottom) ? visible.minY : visible.maxY - size.height
        case .rail:
            // 垂直方向同理：贴上边保留上边缘、贴下边保留下边缘，其余按左上角锚点。
            let topFlush = abs(source.maxY - visible.maxY) <= t
            let bottomFlush = abs(source.minY - visible.minY) <= t
            if topFlush, !bottomFlush {
                origin.y = visible.maxY - size.height
            } else if bottomFlush, !topFlush {
                origin.y = visible.minY
            } else {
                origin.y = min(max(source.maxY - size.height, visible.minY),
                               visible.maxY - size.height)
            }
            origin.x = (edge == .left) ? visible.minX : visible.maxX - size.width
        case .expanded:
            break
        }

        commitFrame(NSRect(origin: origin, size: size), animated: animated)

        defaults.set(true, forKey: Key.compactActive)
        defaults.set(target == .pill, forKey: Key.compactHorizontal)
        defaults.set(NSStringFromRect(surface.frame), forKey: Key.compactFrame)
    }

    // MARK: 拖动 / 贴边

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !snapMuted, !dragInFlight else { return }
            if shape.isCompact {
                dockCompactToEdge()
            } else {
                dockToNearestEdge()
            }
            persistFrame()
        }
    }

    nonisolated func windowDidChangeScreen(_ notification: Notification) {
        MainActor.assumeIsolated { keepOnScreen() }
    }

    private func dockToNearestEdge() {
        guard let bounds = liveBounds else { return }
        var moved = surface.frame
        let t = Self.grabDistance

        if moved.minX < bounds.minX + t {
            moved.origin.x = bounds.minX
        } else if moved.maxX > bounds.maxX - t {
            moved.origin.x = bounds.maxX - moved.width
        }

        if moved.maxY > bounds.maxY - t {
            moved.origin.y = bounds.maxY - moved.height
        } else if moved.minY < bounds.minY + t {
            moved.origin.y = bounds.minY
        }

        commitQuietly(moved)
    }

    /// 缩略条拖完：贴最近的一条边，并据此决定横/竖形态
    private func dockCompactToEdge() {
        guard let bounds = liveBounds else { return }
        let original = surface.frame
        let frame = clamp(original, into: bounds)
        let wasClamped = frame != original

        let (edge, distance) = closestEdge(of: frame, in: bounds)
        let wantHorizontal = (edge == .top || edge == .bottom)
        let wantMode: WidgetShape = wantHorizontal ? .pill : .rail

        if wantMode != shape {
            // 换向不做动画：发生在光标底下，动画会显得拖沓
            morphToCompact(shape: wantMode, edge: edge, anchoredAt: frame, visible: bounds, animated: false)
            return
        }

        var target = frame
        if distance <= Self.grabDistance {
            switch shape {
            case .pill:
                target.origin.y = (edge == .bottom) ? bounds.minY : bounds.maxY - frame.height
                target.origin.x = min(max(frame.origin.x, bounds.minX),
                                      bounds.maxX - frame.width)
            case .rail:
                target.origin.x = (edge == .left) ? bounds.minX : bounds.maxX - frame.width
                target.origin.y = min(max(frame.origin.y, bounds.minY),
                                      bounds.maxY - frame.height)
            case .expanded:
                break
            }
        } else if !wasClamped {
            return
        }

        commitQuietly(target)
    }

    private func closestEdge(of frame: NSRect, in visible: NSRect) -> (edge: DockEdge, distance: CGFloat) {
        let candidates: [(DockEdge, CGFloat)] = [
            (.top, abs(frame.maxY - visible.maxY)),
            (.bottom, abs(frame.minY - visible.minY)),
            (.left, abs(frame.minX - visible.minX)),
            (.right, abs(frame.maxX - visible.maxX))
        ]
        let best = candidates.min(by: { $0.1 < $1.1 }) ?? (.top, 0)
        return (best.0, best.1)
    }

    /// 缩略条实际贴着哪条边：先看是否真的贴住（2pt 容差），否则退化为最近边
    private func restingEdge(of frame: NSRect, in visible: NSRect) -> DockEdge {
        if abs(frame.minY - visible.minY) <= 2 { return .bottom }
        if abs(frame.maxY - visible.maxY) <= 2 { return .top }
        if abs(frame.minX - visible.minX) <= 2 { return .left }
        if abs(frame.maxX - visible.maxX) <= 2 { return .right }
        return closestEdge(of: frame, in: visible).edge
    }

    private func keepOnScreen() {
        guard let bounds = liveBounds else { return }
        // 无论窗口跑到哪（哪怕整块都在屏幕外），都只是"夹回最近的可见位置"，
        // 绝不重置到右上角——否则缩略条被拖动时会莫名瞬移到屏幕角落。
        commitQuietly(clamp(surface.frame, into: bounds))
    }

    private func visibleFrame(for rect: NSRect) -> NSRect {
        for screen in NSScreen.screens where screen.frame.intersects(rect) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? rect
    }

    private func defaultExpandedFrame(near compact: NSRect) -> NSRect {
        let bounds = visibleFrame(for: compact)
        let size = WidgetShape.expanded.size
        return NSRect(
            x: bounds.maxX - size.width - 24,
            y: bounds.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    // MARK: 状态持久化

    private func persistFrame() {
        let key = shape.isCompact ? Key.compactFrame : Key.expandedFrame
        let value = NSStringFromRect(surface.frame)
        // 拖动时每次位移都会回调 windowDidMove，坐标没变就别重复写盘
        guard defaults.string(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
    }

    /// 跟随系统的「减弱动态效果」：开了就不要收缩/展开动画
    private var animationsAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func restoreLayout() {
        let compactActive = defaults.bool(forKey: Key.compactActive)

        if compactActive,
           let stored = defaults.string(forKey: Key.compactFrame).flatMap(NSRectFromString) {
            let horizontal = defaults.bool(forKey: Key.compactHorizontal)
            let target: WidgetShape = horizontal ? .pill : .rail
            shape = target
            canvas.shape = target

            var frame = stored
            frame.size = target.size
            commitQuietly(frame, display: false)
            keepOnScreen()
            return
        }

        if let stored = defaults.string(forKey: Key.expandedFrame).flatMap(NSRectFromString) {
            var frame = stored
            frame.size = WidgetShape.expanded.size
            commitQuietly(frame, display: false)
        } else {
            surface.setFrame(defaultExpandedFrame(near: NSScreen.main?.visibleFrame ?? .zero), display: false)
        }
        shape = .expanded
        canvas.shape = .expanded
        keepOnScreen()
    }

    // MARK: 自检（仅 -D SNAPTEST 构建使用）

    func selfTestSnap() -> String {
        guard let bounds = liveBounds else { return "no screen" }
        var report: [String] = []

        surface.setFrameOrigin(NSPoint(x: bounds.minX - 12, y: bounds.minY - 9))
        dockToNearestEdge()
        report.append("full left-bottom -> \(fmt(surface.frame))")

        surface.setFrameOrigin(NSPoint(x: bounds.maxX - 5, y: bounds.midY))
        dockToNearestEdge()
        report.append("full right -> \(fmt(surface.frame))")

        surface.setFrameOrigin(NSPoint(x: bounds.midX, y: bounds.maxY + 6))
        dockToNearestEdge()
        report.append("full top -> \(fmt(surface.frame))")

        // 折叠到贴右 → 竖条
        surface.setFrame(NSRect(x: bounds.maxX - DockWidget.contentSize.width, y: bounds.midY, width: DockWidget.contentSize.width, height: DockWidget.contentSize.height), display: false)
        fold()
        report.append("collapse right -> shape=\(shape.rawValue) frame=\(fmt(surface.frame))")

        // 竖条拖到顶部附近 → 应变横条
        let compact = surface.frame
        surface.setFrameOrigin(NSPoint(x: compact.origin.x, y: bounds.maxY - compact.height + 4))
        dockCompactToEdge()
        report.append("compact drag top -> shape=\(shape.rawValue) frame=\(fmt(surface.frame))")

        // 展开回完整面板
        unfold()
        report.append("expand -> shape=\(shape.rawValue) frame=\(fmt(surface.frame))")

        // 锚点 1：完整窗贴左边、贴上边 → 收缩后应保持左边缘 + 上边缘
        surface.setFrame(NSRect(x: bounds.minX, y: bounds.maxY - DockWidget.contentSize.height, width: DockWidget.contentSize.width, height: DockWidget.contentSize.height), display: false)
        fold()
        report.append("collapse flush-left/top -> shape=\(shape.rawValue) frame=\(fmt(surface.frame))")

        // 锚点 2：把缩略条往右挪，再展开 → 应以缩略条当前位置展开，而不是收缩前的旧位置
        if shape.isCompact {
            let moved = surface.frame
            surface.setFrameOrigin(NSPoint(x: moved.origin.x + 180, y: moved.origin.y))
            dockCompactToEdge()
            let afterDrag = surface.frame
            unfold()
            report.append("compact moved to minX=\(Int(afterDrag.minX)) -> expand frame=\(fmt(surface.frame))")
        }

        report.append("sizes -> H=\(WidgetShape.pill.size) V=\(WidgetShape.rail.size) F=\(WidgetShape.expanded.size)")
        report.append("visibleFrame -> \(fmt(bounds))")
        return report.joined(separator: "\n")
    }

    private func fmt(_ rect: NSRect) -> String {
        String(format: "(%.0f, %.0f, %.0f, %.0f)",
               rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }
}
