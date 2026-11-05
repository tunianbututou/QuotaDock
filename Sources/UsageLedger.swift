import Foundation

// MARK: - 曲线上的点

/// 一次采样：那一刻这段额度还剩多少。
struct LedgerSample {
    let at: Date
    let leftPercent: Double
}

/// 一条历史曲线。窗口长度相同的采样落在同一条线上（例如 300 / 10080 分钟两条线）。
struct LedgerTrack {
    let spanMinutes: Int
    var samples: [LedgerSample]

    var title: String { QuotaWindow.label(forMinutes: spanMinutes) }
    var newest: LedgerSample? { samples.last }
}

// MARK: - 账本

/// 额度账本：每次成功读取后按天追加到本机 JSONL，只写不传。
/// 位置在沙箱容器的 `Application Support/QuotaDock/Ledger`，设置页可以直接打开文件夹。
final class UsageLedger {
    static let shared = UsageLedger()

    /// 有新采样（趋势图据此重绘）
    static let didChange = Notification.Name("com.quotadock.ledgerChanged")

    /// 保留多少天，超期的按天文件直接删掉
    static let keepDays = 45
    /// 两次落盘的最小间隔：额度按分钟变化，25 秒已经足够细
    private static let writeCooldown: TimeInterval = 25

    /// 账本目录
    let vaultURL: URL

    /// 所有缓存都由这条串行队列独占，外部只能通过它读写
    private let state = DispatchQueue(label: "com.quotadock.ledger.state")
    /// 磁盘 I/O 单开一条低优先级队列，别卡住主线程
    private let disk = DispatchQueue(label: "com.quotadock.ledger.disk", qos: .utility)

    private var buckets: [Int: [LedgerSample]] = [:]
    private var lastWritten: Date = .distantPast
    private var reading = false
    private var ready = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        vaultURL = base
            .appending(path: "QuotaDock", directoryHint: .isDirectory)
            .appending(path: "Ledger", directoryHint: .isDirectory)

        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        Storage.sweep(folder: vaultURL, keepingDays: Self.keepDays)
        syncFromDisk()
    }

    // MARK: 对外读取

    /// 当前可画的曲线，按窗口长度升序
    func tracks() -> [LedgerTrack] {
        state.sync {
            buckets.keys.sorted().map { span in
                LedgerTrack(spanMinutes: span, samples: buckets[span] ?? [])
            }
        }
    }

    /// 磁盘读完没有：首次启动时缓存可能还是空的
    var isHydrated: Bool {
        state.sync { ready }
    }

    /// 最早一条采样的时间（趋势图用它算「最多能看多久」）
    var earliestSample: Date? {
        state.sync {
            buckets.values.compactMap { $0.first?.at }.min()
        }
    }

    // MARK: 记账

    /// 记一次采样。调用方在主线程（每次读取成功后）。
    func capture(_ report: QuotaReport, at moment: Date = Date()) {
        guard let group = report.mainGroup else { return }
        let windows = group.windows
        guard !windows.isEmpty else { return }

        // 冷却：短时间内的重复调用（手动刷新 + 推送撞在一起）不重复记账
        let allowed: Bool = state.sync {
            guard moment.timeIntervalSince(lastWritten) >= Self.writeCooldown else {
                return false
            }
            lastWritten = moment
            return true
        }
        guard allowed else { return }

        var cells: [Storage.Cell] = []
        cells.reserveCapacity(windows.count)
        for window in windows {
            cells.append(
                Storage.Cell(
                    s: window.spanMinutes,
                    l: window.availablePercent,
                    r: window.resetsOn.timeIntervalSince1970
                )
            )
        }

        state.sync {
            for window in windows {
                buckets[window.spanMinutes, default: []].append(
                    LedgerSample(at: moment, leftPercent: window.availablePercent)
                )
            }
        }

        Storage.append(
            Storage.Row(t: Int(moment.timeIntervalSince1970), v: cells),
            to: vaultURL.appendingPathComponent(Storage.stamp(for: moment) + ".jsonl"),
            on: disk
        )
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: 从磁盘重读

    /// 重读整个目录（异步，读完发 `didChange`）。重复调用会被合并成一次。
    func syncFromDisk() {
        let claimed: Bool = state.sync {
            guard !reading else { return false }
            reading = true
            return true
        }
        guard claimed else { return }

        let folder = vaultURL
        disk.async { [weak self] in
            let loaded = Storage.load(folder)

            DispatchQueue.main.async {
                guard let self else { return }
                self.state.sync {
                    self.buckets = loaded
                    self.reading = false
                    self.ready = true
                }
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
        }
    }
}

// MARK: - 磁盘格式

/// 一天一个 `.jsonl`，一行一条采样：
/// `{"t":1698500000,"v":[{"s":300,"l":51.5,"r":1698503600}]}`
/// 字段压到最短（一分钟一条，一天约 100 KB）。
private enum Storage {
    struct Row: Codable {
        /// 采样时刻（epoch 秒）
        var t: Int
        /// 这一次读到的各窗口
        var v: [Cell]
    }

    struct Cell: Codable {
        /// 窗口长度（分钟）
        var s: Int
        /// 剩余百分比
        var l: Double
        /// 重置时刻（epoch 秒）
        var r: Double
    }

    /// 文件名用的本地日期。刻意不用 DateFormatter：它不线程安全，这里要跨队列调用。
    static func stamp(for moment: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: moment)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func files(in folder: URL) -> [URL] {
        let listed = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        return listed
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 读整个目录，按窗口长度归并成多条曲线
    static func load(_ folder: URL) -> [Int: [LedgerSample]] {
        var grouped: [Int: [LedgerSample]] = [:]

        for file in files(in: folder) {
            guard let blob = try? Data(contentsOf: file) else { continue }
            for raw in blob.split(separator: 0x0A) where !raw.isEmpty {
                guard let row = try? JSONDecoder().decode(Row.self, from: Data(raw)) else {
                    continue
                }
                let moment = Date(timeIntervalSince1970: TimeInterval(row.t))
                for cell in row.v where cell.s > 0 {
                    grouped[cell.s, default: []].append(
                        LedgerSample(at: moment, leftPercent: cell.l)
                    )
                }
            }
        }

        // 同一时间点的样本按理就是顺序写入的，但跨文件重读后仍按时间排一遍更稳
        return grouped.mapValues { points in
            points.sorted { $0.at < $1.at }
        }
    }

    /// 追加一行。文件不存在（当天第一笔）时直接创建。
    static func append(_ row: Row, to file: URL, on queue: DispatchQueue) {
        guard let encoded = try? JSONEncoder().encode(row) else { return }
        queue.async {
            var payload = encoded
            payload.append(0x0A)

            if let tail = try? FileHandle(forWritingTo: file) {
                defer { try? tail.close() }
                _ = try? tail.seekToEnd()
                try? tail.write(contentsOf: payload)
            } else {
                try? payload.write(to: file, options: .atomic)
            }
        }
    }

    /// 删掉保留期之外的按天文件（文件名零填充，字符串比较即时间顺序）
    static func sweep(folder: URL, keepingDays days: Int) {
        let today = Date()
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: today) else {
            return
        }

        let oldestKept = stamp(for: cutoff) + ".jsonl"
        for file in files(in: folder) where file.lastPathComponent < oldestKept {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
