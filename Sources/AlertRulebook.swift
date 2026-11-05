import Foundation

public enum AlertEvent: Equatable, Sendable {
    /// 某一轮窗口的剩余额度跌破阈值
    case runningLow(caption: String, leftPercent: Int, resetsOn: Date)
    /// 某一轮窗口翻新（重置时间前移且额度回涨）
    case cycleRenewed(caption: String, leftPercent: Int)
}

/// 提醒规则：只在「状态真的发生变化」时出一条事件，同一次变化绝不重复播报。
///
/// 判据全部基于前后两次读数：额度跌破阈值要「这轮窗口没变、上一次还高于阈值、
/// 这一次已低于阈值」；翻新要「重置时间前移、旧的重置时间已过、额度回涨」。
/// 这样网络抖动、打开程序时的首帧、手动刷新都不会误报。
public struct AlertRulebook: Sendable {
    /// 一轮窗口的身份证：长度 + 重置时刻（+ 阈值，用于区分「低额度」与「翻新」两类事件）
    private struct Cycle: Hashable, Sendable {
        let spanMinutes: Int
        let resetEpoch: Int
        let threshold: Int?

        init(_ window: QuotaWindow, threshold: Int? = nil) {
            spanMinutes = window.spanMinutes
            resetEpoch = Int(window.resetsOn.timeIntervalSince1970.rounded())
            self.threshold = threshold
        }
    }

    private var lastSeen: [Int: QuotaWindow] = [:]
    /// 已经播报过的 (窗口, 阈值) 组合
    private var announced: Set<Cycle> = []
    private var hasPrevious = false

    public init() {}

    /// 丢掉全部记忆：退出登录、切换账号、进入演示模式时必须调用，
    /// 否则下次读数会被当成「变化」而误报。
    public mutating func rearm() {
        lastSeen = [:]
        announced = []
        hasPrevious = false
    }

    public mutating func evaluate(
        report: QuotaReport,
        warnBelowPercent: Int,
        announceResets: Bool
    ) -> [AlertEvent] {
        let windows = report.mainGroup?.windows ?? []

        defer {
            lastSeen = Dictionary(
                uniqueKeysWithValues: windows.map { ($0.spanMinutes, $0) }
            )
            hasPrevious = true
        }

        // 第一次读数只当作基准，不产生事件
        guard hasPrevious else { return [] }

        let threshold = Double(warnBelowPercent)
        var events: [AlertEvent] = []

        for current in windows {
            guard let previous = lastSeen[current.spanMinutes] else { continue }

            let sameCycle = abs(current.resetsOn.timeIntervalSince(previous.resetsOn)) < 1
            let leftNow = Int(current.availablePercent.rounded())

            if sameCycle,
               previous.availablePercent > threshold,
               current.availablePercent <= threshold,
               announced.insert(Cycle(current, threshold: warnBelowPercent)).inserted {
                events.append(
                    .runningLow(
                        caption: current.caption,
                        leftPercent: leftNow,
                        resetsOn: current.resetsOn
                    )
                )
                continue
            }

            let renewed = current.resetsOn > previous.resetsOn
                && previous.resetsOn <= report.sampledAt
                && current.availablePercent > previous.availablePercent

            if announceResets,
               renewed,
               announced.insert(Cycle(current)).inserted {
                events.append(.cycleRenewed(caption: current.caption, leftPercent: leftNow))
            }
        }

        return events
    }
}
