import Foundation

/// 记住每一档最近一次算出来的消耗速度（百分点/分钟）。
///
/// 两个场景离不开它：
/// 1. 主额度见底后采样会变平，最近一小时的曲线拟合不出「原来掉多快」；
/// 2. 程序重启后内存里的缓存放不住，但趋势图上那条预测线还要接着画。
enum RateMemory {
    private static let prefix = "QuotaDock.rate."

    static func remember(_ dropPerMinute: Double, spanMinutes: Int) {
        guard dropPerMinute > 0 else { return }
        UserDefaults.standard.set(dropPerMinute, forKey: prefix + String(spanMinutes))
    }

    static func recall(_ spanMinutes: Int) -> Double? {
        let stored = UserDefaults.standard.double(forKey: prefix + String(spanMinutes))
        return stored > 0 ? stored : nil
    }
}
