import Foundation

/// 从历史采样里认出「额度重置」发生过的时刻。
///
/// 判据只有两条，都朝向「向上」：
/// 1. 最新值 ≥95%——不要求正好 100%。轮询间隔 60 秒，重置那一瞬间很可能采不到，
///    等下一次读到已经是 99%，放宽到 95 才不会漏判；
/// 2. 相比上一条采样跳了 ≥10 个点——这样 100→99→98 这种**向下**的消耗走不到这里，
///    96→98 的抖动也凑不够幅度，不会被误标成重置。
/// 一次被认出来的重置：发生在哪个时刻、属于哪一档额度。
/// 带上档位名字，图上才能写明白是「5 小时额度重置时刻」而不是笼统的一条线。
struct ResetMark: Hashable {
    let at: Date
    let caption: String
}

enum ResetMoments {
    /// 恢复到这个百分比以上就算「满了」
    static let recoveredTo: Double = 95
    /// 相对上一条采样至少要跳这么多，才算跳变而不是抖动
    static let minimumJump: Double = 10

    static func detect(in samples: [LedgerSample], caption: String) -> [ResetMark] {
        var marks: [ResetMark] = []
        var previous: LedgerSample?
        for sample in samples {
            if let previous,
               sample.leftPercent >= recoveredTo,
               sample.leftPercent - previous.leftPercent >= minimumJump {
                marks.append(ResetMark(at: sample.at, caption: caption))
            }
            previous = sample
        }
        return marks
    }

    /// 多条曲线合并去重：同一两分钟内检测到的算同一次重置
    static func merged(_ groups: [(samples: [LedgerSample], caption: String)]) -> [ResetMark] {
        var all: [ResetMark] = []
        for group in groups {
            all.append(contentsOf: detect(in: group.samples, caption: group.caption))
        }
        all.sort { $0.at < $1.at }
        var unique: [ResetMark] = []
        for mark in all {
            if let last = unique.last, mark.at.timeIntervalSince(last.at) <= 120 { continue }
            unique.append(mark)
        }
        return unique
    }
}
