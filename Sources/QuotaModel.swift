import Foundation

// MARK: - 额度读数

/// 一段额度窗口的读数：这轮窗口有多长、已经用掉多少、什么时候回到满额。
public struct QuotaWindow: Equatable, Sendable, Identifiable {
    public let consumedPercent: Double
    public let spanMinutes: Int
    public let resetsOn: Date

    /// 同一轮窗口的稳定标识：长度 + 重置时刻
    public var id: String { "\(spanMinutes)@\(Int(resetsOn.timeIntervalSince1970))" }

    public var availablePercent: Double {
        min(100, max(0, 100 - consumedPercent))
    }

    public var isWeekly: Bool {
        spanMinutes >= 10_080
    }

    /// 人类可读的窗口长度：周额度 / N 小时额度 / N 分钟额度
    public var caption: String {
        Self.label(forMinutes: spanMinutes)
    }

    /// 窗口长度的说法：周额度 / N 小时额度 / N 分钟额度。历史曲线也用同一套措辞。
    public static func label(forMinutes minutes: Int) -> String {
        guard minutes > 0 else { return Localization.text(.quotaPlain) }

        if minutes >= 10_080 {
            let weeks = minutes / 10_080
            return weeks >= 2
                ? Localization.format(.quotaWeeks, weeks)
                : Localization.text(.quotaWeekly)
        }
        if minutes.isMultiple(of: 60) {
            return Localization.format(.quotaHours, minutes / 60)
        }
        return Localization.format(.quotaMinutes, minutes)
    }

    /// 悬浮窗行标题 / 菜单栏摘要用的短写法，比 `caption` 少一个「额度」后缀
    public var rowLabel: String {
        if isWeekly { return Localization.text(.rowWeekly) }
        if spanMinutes.isMultiple(of: 60) {
            return Localization.format(.rowHours, spanMinutes / 60)
        }
        return Localization.format(.rowMinutes, spanMinutes)
    }

    /// 贴边缩略条上的极简写法：周 / 5h / 90m
    public var shortCaption: String {
        if isWeekly { return Localization.text(.shortWeekly) }
        if spanMinutes.isMultiple(of: 60) {
            return Localization.format(.shortHours, spanMinutes / 60)
        }
        return Localization.format(.shortMinutes, spanMinutes)
    }
}

/// 一组额度（账户下可能同时存在多个额度集合，通常只有一个 `codex`）。
public struct QuotaGroup: Equatable, Sendable, Identifiable {
    public let id: String
    /// 服务端给的展示名，通常为空
    public let label: String?
    /// 套餐档位（plus / pro …），只有部分返回里带
    public let tier: String?
    public let primary: QuotaWindow?
    public let secondary: QuotaWindow?
    /// 触发限流时的原因码；非空表示这组额度当前被拦住了
    public let haltedBy: String?

    /// 实际拿到的窗口，按「短窗口 → 长窗口」排列；没有的窗口不会占位。
    public var windows: [QuotaWindow] {
        [primary, secondary].compactMap(\.self)
    }
}

/// 一次读取的完整结果。
public struct QuotaReport: Equatable, Sendable {
    public let groups: [QuotaGroup]
    public let sampledAt: Date

    /// 主额度组：优先 `codex`，否则取第一组
    public var mainGroup: QuotaGroup? {
        groups.first { $0.id == "codex" } ?? groups.first
    }

    /// 头号窗口：主组的 primary，没有就退到 secondary
    public var featuredWindow: QuotaWindow? {
        mainGroup?.primary ?? mainGroup?.secondary
    }

    public var tierTag: String? {
        mainGroup?.tier ?? groups.lazy.compactMap(\.tier).first
    }
}

// MARK: - 解码

public enum QuotaDecodeError: LocalizedError {
    case invalidPayload
    case emptyQuota

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return Localization.text(.decodeInvalid)
        case .emptyQuota:
            return Localization.text(.decodeEmpty)
        }
    }
}
/// 把 app-server 的原始返回翻译成 `QuotaReport`。
///
/// 接口有两种形态：带 `rateLimitsByLimitId` 的多组返回，和只有单个 `rateLimits` 的旧形态。
/// 两种都归一化成同一张组列表，上层不需要知道差异。
public enum QuotaDecoder {
    private enum Field {
        static let grouped = "rateLimitsByLimitId"
        static let single = "rateLimits"
        static let groupID = "limitId"
        static let groupName = "limitName"
        static let plan = "planType"
        static let blocked = "rateLimitReachedType"
        static let primary = "primary"
        static let secondary = "secondary"
        static let consumed = "usedPercent"
        static let minutes = "windowDurationMins"
        static let resetsAt = "resetsAt"
    }

    public static func decode(
        _ payload: WireValue,
        sampledAt: Date = Date()
    ) throws -> QuotaReport {
        guard let root = payload.asRecord else {
            throw QuotaDecodeError.invalidPayload
        }

        let rawGroups = collectGroups(in: root)
        let groups = rawGroups.compactMap { pair in
            group(from: pair.value, fallbackID: pair.key)
        }

        guard !groups.isEmpty else {
            throw QuotaDecodeError.emptyQuota
        }
        return QuotaReport(groups: groups, sampledAt: sampledAt)
    }

    /// 归一化「多组」与「单组」两种返回形态
    private static func collectGroups(in root: [String: WireValue]) -> [(key: String, value: WireValue)] {
        if let byID = root[Field.grouped]?.asRecord {
            return byID
                .map { (key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
        }

        if let single = root[Field.single] {
            let identifier = single[Field.groupID]?.asText ?? "codex"
            return [(key: identifier, value: single)]
        }

        return []
    }

    private static func group(from value: WireValue, fallbackID: String) -> QuotaGroup? {
        guard let object = value.asRecord else { return nil }
        return QuotaGroup(
            id: object[Field.groupID]?.asText ?? fallbackID,
            label: object[Field.groupName]?.asText,
            tier: object[Field.plan]?.asText,
            primary: window(from: object[Field.primary]),
            secondary: window(from: object[Field.secondary]),
            haltedBy: object[Field.blocked]?.asText
        )
    }

    /// 三项缺一不可：没有重置时间的窗口无法计算倒计时，直接丢弃
    private static func window(from value: WireValue?) -> QuotaWindow? {
        guard let object = value?.asRecord else { return nil }
        let consumed = object[Field.consumed]?.asDecimal
        let minutes = object[Field.minutes]?.asInteger
        let reset = object[Field.resetsAt]?.asDecimal
        guard let consumed, let minutes, let reset else { return nil }

        return QuotaWindow(
            consumedPercent: consumed,
            spanMinutes: minutes,
            resetsOn: Date(timeIntervalSince1970: reset)
        )
    }
}
