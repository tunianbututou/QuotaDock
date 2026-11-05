import Foundation

/// 菜单栏角标的三种显示方式（顺序与设置页下拉项一致）
public enum BadgeStyle: String, CaseIterable, Hashable, Sendable {
    case glyphAndNumber
    case numberOnly
    case glyphOnly

    /// 设置页下拉项
    public var title: String {
        switch self {
        case .glyphAndNumber: return Localization.text(.badgeGlyphAndNumber)
        case .numberOnly: return Localization.text(.badgeNumberOnly)
        case .glyphOnly: return Localization.text(.badgeGlyphOnly)
        }
    }
}

/// 折算结果：直接写给状态栏按钮的两样东西
public struct BadgeSpec: Equatable, Sendable {
    public var text: String
    public var withIcon: Bool
}

extension BadgeStyle {
    /// 把剩余百分比折成按钮上最终显示的样子。
    /// `remaining` 为 nil（还没拿到数据）时，两种「带数字」的样式各自兜底。
    public func badge(for remaining: Double?) -> BadgeSpec {
        switch self {
        case .glyphAndNumber:
            return BadgeSpec(text: Self.percentText(remaining) ?? "", withIcon: true)
        case .numberOnly:
            return BadgeSpec(text: Self.percentText(remaining) ?? "--%", withIcon: false)
        case .glyphOnly:
            return BadgeSpec(text: "", withIcon: true)
        }
    }

    /// 先夹到 0…100 再取整，避免接口偶尔给出负数或 100 以上时显示成「103%」。
    private static func percentText(_ remaining: Double?) -> String? {
        guard let remaining else { return nil }
        let bounded = min(max(remaining, 0), 100)
        return "\(Int(bounded.rounded()))%"
    }
}

public enum DefaultValues {
    public static let showWidget = false
    public static let widgetOnEverySpace = false
    public static let badgeStyle = BadgeStyle.glyphAndNumber
    public static let hotKeyEnabled = true
    public static let alertsEnabled = false
    public static let warnBelowPercent = 20
    public static let announceResets = true
    public static let checkForUpdates = false
    /// 外观：跟随系统 / 浅色 / 深色
    public static let themeMode = ThemeMode.system
    /// 自动刷新间隔（秒）。额度按分钟级变化，60s 够用；省电可以拉长。
    public static let cadenceSeconds = 60
    /// 可选的刷新间隔
    public static let cadenceChoices = [30, 60, 120, 300]
    /// 默认保持置顶（系统截图选不中）。需要截图时可在菜单里临时让路。
    public static let screenshotPickable = false
    /// 设置页 / 趋势图默认不置顶：它们是普通窗口，能被别的 App 正常盖住。
    public static let companionOnTop = false
}
