import AppKit
import Foundation

// MARK: - 外观模式

/// 跟随系统 / 强制浅色 / 强制深色
public enum ThemeMode: String, CaseIterable, Hashable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return Localization.text(.themeSystem)
        case .light: return Localization.text(.themeLight)
        case .dark: return Localization.text(.themeDark)
        }
    }

    /// nil = 跟随系统
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 调色板

/// 一套完整的视觉 token。悬浮窗、贴边条、趋势图共用，避免各处各写一份颜色。
struct Swatch {
    let surfaceTop: NSColor
    let surfaceBottom: NSColor

    let inkPrimary: NSColor
    let inkSecondary: NSColor
    let inkTertiary: NSColor
    /// 头部那排功能按钮统一用的亮色（五个按钮一个色，别再各用各的灰）
    let toolbarGlyph: NSColor

    let edgeFaint: NSColor
    let edgeStrong: NSColor
    let groove: NSColor
    let pillFill: NSColor

    let brand: NSColor
    let positive: NSColor
    let caution: NSColor
    let error: NSColor

    /// 趋势图
    let gridMajor: NSColor
    let gridMinor: NSColor
    let gridTick: NSColor
    let gridMinorTick: NSColor
    let liveEdge: NSColor
    let hoverLine: NSColor
    let dotRing: NSColor
    let tooltipBg: NSColor
    let tooltipBorder: NSColor

    /// 趋势窗 / 设置窗的窗口底色
    let windowBackground: NSColor

    static let dark = Swatch(
        surfaceTop: NSColor(srgbRed: 15 / 255, green: 16 / 255, blue: 20 / 255, alpha: 0.985),
        surfaceBottom: NSColor(srgbRed: 11 / 255, green: 12 / 255, blue: 15 / 255, alpha: 0.995),

        inkPrimary: NSColor.white.withAlphaComponent(0.96),
        inkSecondary: NSColor.white.withAlphaComponent(0.78),
        inkTertiary: NSColor.white.withAlphaComponent(0.55),
        toolbarGlyph: NSColor.white.withAlphaComponent(0.92),

        edgeFaint: NSColor.white.withAlphaComponent(0.10),
        edgeStrong: NSColor.white.withAlphaComponent(0.20),
        groove: NSColor.white.withAlphaComponent(0.12),
        pillFill: NSColor.white.withAlphaComponent(0.07),

        brand: NSColor(srgbRed: 0x45 / 255, green: 0x82 / 255, blue: 0xE6 / 255, alpha: 1),
        positive: NSColor(srgbRed: 0x2B / 255, green: 0xA4 / 255, blue: 0x71 / 255, alpha: 1),
        caution: NSColor(srgbRed: 0xCF / 255, green: 0x6E / 255, blue: 0x2D / 255, alpha: 1),
        error: NSColor(srgbRed: 0xC6 / 255, green: 0x47 / 255, blue: 0x51 / 255, alpha: 1),

        gridMajor: NSColor.white.withAlphaComponent(0.085),
        gridMinor: NSColor.white.withAlphaComponent(0.035),
        gridTick: NSColor.white.withAlphaComponent(0.07),
        gridMinorTick: NSColor.white.withAlphaComponent(0.045),
        liveEdge: NSColor.white.withAlphaComponent(0.18),
        hoverLine: NSColor.white.withAlphaComponent(0.22),
        dotRing: NSColor.black.withAlphaComponent(0.60),
        tooltipBg: NSColor.black.withAlphaComponent(0.82),
        tooltipBorder: NSColor.white.withAlphaComponent(0.10),

        windowBackground: NSColor(srgbRed: 0.055, green: 0.06, blue: 0.075, alpha: 1)
    )

    /// 浅色：白底 + 深字 + 加深过的强调色（同一个绿/橙在白底上要压暗才够对比）
    static let light = Swatch(
        surfaceTop: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.985),
        surfaceBottom: NSColor(srgbRed: 0.951, green: 0.957, blue: 0.969, alpha: 0.995),

        inkPrimary: NSColor.black.withAlphaComponent(0.88),
        inkSecondary: NSColor.black.withAlphaComponent(0.60),
        inkTertiary: NSColor.black.withAlphaComponent(0.44),
        toolbarGlyph: NSColor.black.withAlphaComponent(0.74),

        edgeFaint: NSColor.black.withAlphaComponent(0.12),
        edgeStrong: NSColor.black.withAlphaComponent(0.22),
        groove: NSColor.black.withAlphaComponent(0.10),
        pillFill: NSColor.black.withAlphaComponent(0.05),

        brand: NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1),
        positive: NSColor(srgbRed: 0x0E / 255, green: 0x8A / 255, blue: 0x5F / 255, alpha: 1),
        caution: NSColor(srgbRed: 0xA8 / 255, green: 0x5A / 255, blue: 0x0B / 255, alpha: 1),
        error: NSColor(srgbRed: 0xC0 / 255, green: 0x33 / 255, blue: 0x3F / 255, alpha: 1),

        gridMajor: NSColor.black.withAlphaComponent(0.10),
        gridMinor: NSColor.black.withAlphaComponent(0.045),
        gridTick: NSColor.black.withAlphaComponent(0.08),
        gridMinorTick: NSColor.black.withAlphaComponent(0.05),
        liveEdge: NSColor.black.withAlphaComponent(0.22),
        hoverLine: NSColor.black.withAlphaComponent(0.28),
        dotRing: NSColor.white.withAlphaComponent(0.95),
        tooltipBg: NSColor.white.withAlphaComponent(0.97),
        tooltipBorder: NSColor.black.withAlphaComponent(0.12),

        windowBackground: NSColor(srgbRed: 0.965, green: 0.968, blue: 0.975, alpha: 1)
    )
}

// MARK: - 外观管理

/// 全局外观状态。切换时改 `NSApp.appearance`（标准控件跟着变），
/// 再广播 `didChange` 让自绘视图重画。
final class ThemeCenter {
    static let shared = ThemeCenter()
    static let didChange = Notification.Name("com.quotadock.themeChanged")

    private(set) var mode: ThemeMode = .system
    private var observer: NSKeyValueObservation?
    private var isStarted = false

    var isDim: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua
        }
    }

    var swatch: Swatch { isDim ? .dark : .light }

    /// 启动时用：只设值 + 应用到 App，不广播（此时还没有视图监听）
    func configure(_ mode: ThemeMode) {
        self.mode = mode
        NSApp.appearance = mode.nsAppearance
    }

    /// 设置页切换时用：应用 + 广播
    func apply(_ mode: ThemeMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        NSApp.appearance = mode.nsAppearance
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 跟随系统时要感知系统在「深色/浅色」之间切换
    func trackSystemTheme() {
        guard !isStarted else { return }
        isStarted = true
        observer = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self, self.mode == .system else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }
}

// MARK: - 视觉 token 门面

/// 所有自绘代码都从这里取色，不再直接写 `NSColor.white/black`。
enum DockStyle {
    static var swatch: Swatch { ThemeCenter.shared.swatch }

    static var surfaceTop: NSColor { swatch.surfaceTop }
    static var surfaceBottom: NSColor { swatch.surfaceBottom }

    static var inkPrimary: NSColor { swatch.inkPrimary }
    static var inkSecondary: NSColor { swatch.inkSecondary }
    static var inkTertiary: NSColor { swatch.inkTertiary }

    static var edgeFaint: NSColor { swatch.edgeFaint }
    static var edgeStrong: NSColor { swatch.edgeStrong }
    static var groove: NSColor { swatch.groove }
    static var pillFill: NSColor { swatch.pillFill }

    static var brand: NSColor { swatch.brand }
    static var positive: NSColor { swatch.positive }
    static var caution: NSColor { swatch.caution }
    static var error: NSColor { swatch.error }

    static var gridMajor: NSColor { swatch.gridMajor }
    static var gridMinor: NSColor { swatch.gridMinor }
    static var gridTick: NSColor { swatch.gridTick }
    static var gridMinorTick: NSColor { swatch.gridMinorTick }
    static var liveEdge: NSColor { swatch.liveEdge }
    static var hoverLine: NSColor { swatch.hoverLine }
    static var dotRing: NSColor { swatch.dotRing }
    static var tooltipBg: NSColor { swatch.tooltipBg }
    static var tooltipBorder: NSColor { swatch.tooltipBorder }

    /// 重置时刻标记：浅黄色虚线（透明度在绘制处按需给）
    static var resetMark: NSColor { NSColor.systemYellow }

    /// 数据缺口：前后两段曲线之间直接用红线连起来，明确「这一段没采到数据」
    static var gapBridge: NSColor { NSColor.systemRed.withAlphaComponent(0.72) }

    /// 当前时刻的纵向参考线：偏冷的浅灰，深浅底上都够显眼
    static var nowLine: NSColor {
        NSColor(srgbRed: 0.72, green: 0.76, blue: 0.82, alpha: 1)
    }

    /// 头部功能按钮统一亮色
    static var toolbarGlyph: NSColor { swatch.toolbarGlyph }

    /// 套餐标识配色：Plus 绿、Pro 金，其它档位走中性亮色
    static var planPlus: NSColor {
        NSColor(srgbRed: 0x2F / 255, green: 0xD8 / 255, blue: 0x84 / 255, alpha: 1)
    }

    static var planPro: NSColor {
        NSColor(srgbRed: 0xFF / 255, green: 0xC2 / 255, blue: 0x3C / 255, alpha: 1)
    }

    /// PLUS / PRO 之外的档位（免费档、未知档）：用中性的强调蓝
    static var planNeutral: NSColor { brand }

    static func planColor(for tag: String) -> NSColor {
        let upper = tag.uppercased()
        if upper.contains("PRO") { return planPro }
        if upper.contains("PLUS") { return planPlus }
        return planNeutral
    }

    static var windowBackground: NSColor { swatch.windowBackground }

    static func accent(for window: QuotaWindow) -> NSColor {
        let remaining = window.availablePercent
        if remaining <= 12 { return error }
        if remaining <= 30 { return caution }
        return window.spanMinutes >= 10_080 ? positive : brand
    }

    static func statusColor(remaining: Double?) -> NSColor {
        guard let remaining else { return inkTertiary }
        if remaining <= 12 { return error }
        if remaining <= 30 { return caution }
        return positive
    }
}
