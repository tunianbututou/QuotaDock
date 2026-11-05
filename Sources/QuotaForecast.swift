import Foundation

/// 按最近一段的下降速度，估算这档额度还要多久见底。
struct ExhaustionForecast: Equatable, Sendable {
    /// 每分钟掉几个百分点（正数表示在掉）
    let dropPerMinute: Double
    /// 从 `measuredAt` 起还能撑多少秒
    let secondsLeft: TimeInterval
    /// 拟合采用的采样区间
    let measuredFrom: Date
    /// 拟合用的最后一个采样时刻
    let measuredAt: Date

    /// 见底时刻
    var zeroDate: Date { measuredAt.addingTimeInterval(secondsLeft) }

    /// 秒数转成「3:12:45」；超过 26 小时换成「2 天 3 小时」，省得数字太长
    static func spell(_ seconds: TimeInterval) -> String {
        Localization.spellCountdown(seconds)
    }
}

/// 三个状态而不是一个可选值：让界面能区分「没数据」和「有数据但没在掉」
enum QuotaUsageEstimate: Equatable, Sendable {
    /// 采样还不够，先别下结论
    case collecting
    /// 采样够，但这段几乎没消耗
    case steady
    /// 已经见底，不用再预测
    case exhausted
    /// 正在掉，附带见底时间
    case falling(ExhaustionForecast)

    var forecast: ExhaustionForecast? {
        if case let .falling(value) = self { return value }
        return nil
    }

    /// 悬浮窗那一行小字。`resetAt` 给了且预计见底晚于重置，就直说「重置前不会耗尽」。
    func caption(resetAt: Date? = nil) -> String {
        switch self {
        case .collecting:
            return Localization.text(.estimateCollecting)
        case .steady:
            return Localization.text(.estimateSteady)
        case .exhausted:
            return Localization.text(.estimateExhausted)
        case let .falling(forecast):
            if let resetAt, forecast.zeroDate >= resetAt {
                return Localization.text(.estimateBeforeReset)
            }
            // 用绝对见底时刻现算，不要用拟合时烘焙的秒数：
            // 否则同一屏里「随周额度耗尽」和「预计…耗尽」会差出几十秒
            return Localization.format(
                .estimateFalling,
                ExhaustionForecast.spell(max(0, forecast.zeroDate.timeIntervalSinceNow))
            )
        }
    }
}

/// 线性拟合最近一段的剩余额度，把斜率换算成见底时间。
/// 先看最近 20 分钟（抓当前这一波），判不出来再退回 1 小时（照顾慢速消耗）。
enum QuotaForecast {
    /// 长窗口：慢速消耗（比如周额度一小时才动一个点）靠它，避免被短窗口的抖动带偏
    static let horizon: TimeInterval = 3_600
    /// 短窗口：抓「现在」这一波消耗。5 小时额度常常长时间不动、然后猛掉一阵，
    /// 只看一小时会被前面那段平线稀释，斜率严重偏小——预测线于是变成一条缓坡，
    /// 看着像「直接把当前点和重置点连起来」。
    static let burstHorizon: TimeInterval = 20 * 60
    /// 少于 4 个点、或跨度不足 4 分钟，就不硬算
    private static let fewestPoints = 4
    private static let shortestSpan: TimeInterval = 240
    /// 断档超过 20 分钟（睡眠 / 关机）说明中间没观测过，别把两头连成一条线
    private static let widestGap: TimeInterval = 1_200
    /// 每分钟掉不到 0.02 个点，就当没在掉
    private static let slowestRate = 0.02

    /// 主额度（比如 5 小时）见底后消耗会被拦住：其它档位在重置前一格都不会掉，
    /// 预测不能拿「平掉的采样」重新拟合，而是沿用见底前的速度，
    /// 把见底点平移到主档重置之后：`重置时刻 + 剩余量 ÷ 原速度`。阻挡期内这是个恒定时刻。
    static func shifted(
        _ forecast: ExhaustionForecast,
        remaining: Double,
        blockedUntil: Date,
        now: Date
    ) -> ExhaustionForecast {
        let burnPerSecond = forecast.dropPerMinute / 60
        let secondsAfterReset = burnPerSecond > 0 ? remaining / burnPerSecond : 0
        return ExhaustionForecast(
            dropPerMinute: forecast.dropPerMinute,
            secondsLeft: max(0, blockedUntil.timeIntervalSince(now)) + secondsAfterReset,
            measuredFrom: forecast.measuredFrom,
            measuredAt: forecast.measuredAt
        )
    }

    /// 曲线尾部已经走平（主档见底、或者很久没用）时，往回找「最后一次明显下降」之前的
    /// 那一段重新估算速度——否则一进入拦截期，就再也拟合不出「原来掉多快」。
    static func recentRate(in samples: [LedgerSample]) -> Double? {
        guard let last = samples.last,
              let cut = samples.lastIndex(where: { $0.leftPercent > last.leftPercent + 1 })
        else { return nil }

        let slice = Array(samples[max(0, cut - 120)...cut])
        guard slice.count >= fewestPoints, let tail = slice.last else { return nil }
        if case let .falling(forecast) = estimate(samples: slice, now: tail.at) {
            return forecast.dropPerMinute
        }
        return nil
    }

    static func estimate(samples: [LedgerSample], now: Date = Date()) -> QuotaUsageEstimate {
        // 已经见底：没有「还要多久」可言
        if let last = samples.last, last.leftPercent <= 0.2 {
            return .exhausted
        }

        // 先看最近这一波；判不出来（停顿 / 刚重置）再退回一小时，
        // 免得把一段慢速消耗误判成「没在掉」。
        let burst = fit(samples, now: now, horizon: burstHorizon)
        if case .falling = burst { return burst }
        let broad = fit(samples, now: now, horizon: horizon)
        if case .falling = broad { return broad }

        // 两段都判不出来：只要有一段采样够，就算 steady；否则 collecting
        if case .collecting = burst, case .collecting = broad { return .collecting }
        return .steady
    }

    /// 在指定窗口内做最小二乘，算这一段的消耗速度。
    private static func fit(
        _ samples: [LedgerSample], now: Date, horizon: TimeInterval
    ) -> QuotaUsageEstimate {
        let slice = recentSlice(samples, now: now, horizon: horizon)
        guard slice.count >= fewestPoints,
              let head = slice.first,
              let tail = slice.last
        else {
            return .collecting
        }
        let span = tail.at.timeIntervalSince(head.at)
        guard span >= shortestSpan else { return .collecting }

        // 中间断档太久，拟合出来的斜率不可信
        var previous: Date?
        for point in slice {
            if let previous, point.at.timeIntervalSince(previous) > widestGap {
                return .collecting
            }
            previous = point.at
        }

        // 最小二乘：x 用「距首个采样多少秒」，y 是剩余百分比
        let count = Double(slice.count)
        var sumX = 0.0
        var sumY = 0.0
        for point in slice {
            sumX += point.at.timeIntervalSince(head.at)
            sumY += point.leftPercent
        }
        let meanX = sumX / count
        let meanY = sumY / count

        var covariance = 0.0
        var variance = 0.0
        for point in slice {
            let dx = point.at.timeIntervalSince(head.at) - meanX
            covariance += dx * (point.leftPercent - meanY)
            variance += dx * dx
        }
        guard variance > 0 else { return .collecting }

        let slope = covariance / variance            // 百分点 / 秒
        guard slope < 0 else { return .steady }      // 走平或回升

        let dropPerMinute = -slope * 60
        guard dropPerMinute >= slowestRate else { return .steady }
        guard tail.leftPercent > 0 else { return .steady }

        // 锚在最后一个真实值上，而不是拟合值：预测线从曲线上那个点出发，
        // 见底时刻、悬停预测、线本身必须用同一套数，否则三者会互相打架。
        return .falling(
            ExhaustionForecast(
                dropPerMinute: dropPerMinute,
                secondsLeft: tail.leftPercent / -slope,
                measuredFrom: head.at,
                measuredAt: tail.at
            )
        )
    }

    /// 最近的采样：只看 `horizon` 之内；遇到明显回升（中间重置过）就只保留回升之后那段
    private static func recentSlice(
        _ samples: [LedgerSample], now: Date, horizon: TimeInterval
    ) -> ArraySlice<LedgerSample> {
        guard !samples.isEmpty else { return samples[0..<0] }

        let floor = now.addingTimeInterval(-horizon)
        var start = samples.count - 1
        while start > 0, samples[start - 1].at >= floor {
            start -= 1
        }

        var index = samples.count - 1
        while index > start {
            if samples[index].leftPercent > samples[index - 1].leftPercent + 5 {
                start = index
                break
            }
            index -= 1
        }
        return samples[start...]
    }
}
