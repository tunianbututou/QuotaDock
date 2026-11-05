import AppKit
import Foundation

/// 额度数据流：负责把「内置助手里读到的额度」变成界面能直接用的状态。
/// 只有它会碰 QuotaBridge，视图层一律读它的 @Published 属性。
@MainActor final class QuotaStream: ObservableObject {
    static let shared = QuotaStream()

    enum Stage: Equatable {
        case waking          // 正在叫醒额度服务
        case awaitingSignIn  // 服务在，但账号没登录
        case authorizing     // 浏览器授权流程进行中
        case priming         // 已登录，还没拿到第一批数字
        case live            // 正常出数
        case stalled         // 出错了，正在退避重试
    }

    /// 助手会主动推过来的几条消息。字符串是协议常量，单列出来免得散在 switch 里。
    private enum Signal {
        static let signInFinished = "account/login/completed"
        static let accountTouched = "account/updated"
        static let quotaTouched = "account/rateLimits/updated"
    }

    @Published private(set) var phase: Stage = .waking
    @Published private(set) var account: LinkedAccount = .signedOut
    @Published private(set) var report: QuotaReport?
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var isPreviewing = false
    @Published var failureText: String?
    /// 窗口长度 → 消耗速度预估。每次拉完数据重算一次，界面直接取用，不在绘制里算。
    @Published private(set) var estimates: [Int: QuotaUsageEstimate] = [:]

    private var bridge: QuotaBridge?
    private var ticker: Task<Void, Never>?
    private var retries: Task<Void, Never>?
    private var attemptIndex = 0
    private var didWarmUp = false
    /// 同一时刻只允许一个 pull 在跑：轮询、手动刷新、服务端推送常撞在一起
    private var pullInFlight = false
    /// pull 发现管道不能用时会去 connect，connect 末尾又会 pull —— 用这个挡住套娃
    private var rewiring = false

    /// 重试间隔（秒）。指数退避，封顶 5 分钟，别把助手当沙包。
    private static let retryLadder: [TimeInterval] = [15, 30, 60, 120, 300]

    /// 菜单栏和贴边条都只看这一个数：主窗口中优先级最高的那个窗口还剩多少
    var featuredRemaining: Double? {
        report?.featuredWindow?.availablePercent
    }

    /// 套餐标识（PLUS / PRO …），拿不到就退回账号信息
    var planTag: String {
        (report?.tierTag ?? account.planType ?? "ChatGPT").uppercased()
    }

    /// 这档额度的消耗预估；还没轮到这个窗口时返回 nil
    func estimate(for window: QuotaWindow) -> QuotaUsageEstimate? {
        estimates[window.spanMinutes]
    }

    // MARK: 生命周期

    /// 退出前收尾：停轮询、主动结束子进程。
    /// 少了这一步，App 退出后助手会被 launchd 收编成孤儿，开关几次就堆一排 app-server。
    /// 这是个单例，生命周期跟 App 一样长，所以收尾只走这里、不挂在 deinit 上。
    func shutdown() {
        retries?.cancel()
        retries = nil
        ticker?.cancel()
        ticker = nil
        bridge?.shutdown()
        bridge = nil
    }

    func warmUp() async {
        guard !didWarmUp else { return }
        didWarmUp = true

        // 改了刷新间隔就立刻换档，不必等当前这一轮睡完
        let watchCadence: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.restartTicking() }
        }
        NotificationCenter.default.addObserver(
            forName: .cadenceChanged, object: nil, queue: .main, using: watchCadence
        )

        // 账本从磁盘读完（或补进新采样）时重算一次：否则启动后要等下一轮才知道该显示多久见底
        let watchLedger: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEstimates() }
        }
        NotificationCenter.default.addObserver(
            forName: UsageLedger.didChange, object: nil, queue: .main, using: watchLedger
        )

        await connect()
    }

    private func restartTicking() {
        ticker?.cancel()
        ticker = nil
        guard account.isSignedIn else { return }
        startTicking()
    }

    /// 建立连接 → 认账号 → 先拉一次 → 开始轮询
    func connect() async {
        do {
            let live = try await usableBridge()
            account = try await live.readAccount()

            // 握手通了，把退避清零：下次真出问题重新从 15 秒起步
            retries?.cancel()
            retries = nil
            attemptIndex = 0

            guard account.isSignedIn else {
                phase = .awaitingSignIn
                return
            }

            await pull()
            startTicking()
        } catch {
            noteFailure(error)
        }
    }

    /// 拿一条能用的管道：还活着就续用，否则换一条新的。
    /// 以前这里无条件复用旧 bridge，助手一死就永远卡在失败态，只能重启 App。
    private func usableBridge() async throws -> QuotaBridge {
        if let bridge, bridge.isProcessAlive {
            return bridge
        }

        bridge?.shutdown()
        bridge = nil
        phase = .waking

        let fresh = QuotaBridge()
        fresh.onNotice = { [weak self] method, params in
            guard let stream = self else { return }
            Task(priority: .userInitiated) { @MainActor in
                stream.handleNotice(method, params)
            }
        }
        try await fresh.launch()
        bridge = fresh
        return fresh
    }

    // MARK: 取数

    /// 拉一次额度。手动刷新、定时轮询、助手推送都走这里，所以必须能重入安全。
    func pull() async {
        guard !isPreviewing else { return }

        // 管道没了：换一条再读，别让界面一直停在失败态
        if bridge?.isProcessAlive != true {
            guard !rewiring else { return }
            rewiring = true
            defer { rewiring = false }

            bridge?.shutdown()
            bridge = nil
            await connect()
            return
        }

        guard let bridge, !pullInFlight else { return }
        pullInFlight = true
        defer { pullInFlight = false }

        phase = report == nil ? .priming : .live
        failureText = nil

        do {
            // 懒加载账号：启动时可能还没登录，用户后来在浏览器里授权完才需要重读
            if !account.isSignedIn {
                account = try await bridge.readAccount()
            }
            guard account.isSignedIn else {
                phase = .awaitingSignIn
                return
            }

            publish(try await bridge.readQuota())
        } catch {
            // 传输层坏了就丢掉这条管道，下一轮会重建
            if let failure = error as? BridgeError, failure.poisonsChannel {
                bridge.shutdown()
                self.bridge = nil
            }
            noteFailure(error)
        }
    }

    /// 新数据到手：更新状态、记一笔历史、算一遍消耗速度、跑一遍提醒规则
    private func publish(_ snapshot: QuotaReport) {
        report = snapshot
        refreshedAt = Date()
        phase = .live

        UsageLedger.shared.capture(snapshot)
        refreshEstimates()
        AlertCenter.shared.ingest(report: snapshot, isPreviewing: false)
    }

    /// 用账本里最近一小时的采样，给每个窗口长度算一次见底时间。
    /// 放在这里而不是绘制里：面板每秒重绘一次，拟合一次一分钟就够。
    private func refreshEstimates() {
        let moment = Date()
        let tracks = UsageLedger.shared.tracks()
        let windows = report?.mainGroup?.windows ?? []

        // 主额度（最短的那档）见底 = 消耗被拦住：其它档在重置前一格都不会掉，
        // 预测要平移到「重置时刻 + 按原速度烧完剩余」，而不是拿平掉的采样重新拟合。
        var blockedUntil: Date?
        if let primary = windows
            .filter({ $0.availablePercent <= 0.4 })
            .min(by: { $0.spanMinutes < $1.spanMinutes }) {
            blockedUntil = primary.resetsOn
        }

        var fresh: [Int: QuotaUsageEstimate] = [:]
        for track in tracks {
            let span = track.spanMinutes
            let remaining = windows.first { $0.spanMinutes == span }?.availablePercent
                ?? track.samples.last?.leftPercent ?? 100

            // 已经见底：没有「还要多久」可言
            if remaining <= 0.4 {
                fresh[span] = .exhausted
                continue
            }

            // 被主档拦住期间：本档数值不动，沿用上一次预测的速度往后平移，保持恒定
            if let until = blockedUntil, until > moment {
                if let kept = estimates[span]?.forecast {
                    fresh[span] = .falling(
                        QuotaForecast.shifted(kept, remaining: remaining, blockedUntil: until, now: moment)
                    )
                    continue
                }
                // 刚启动、内存里还没缓存：用上次记住的速度，或者从「最后一次下降」那段估一个
                if let rate = RateMemory.recall(span) ?? QuotaForecast.recentRate(in: track.samples) {
                    let base = ExhaustionForecast(
                        dropPerMinute: rate,
                        secondsLeft: 0,
                        measuredFrom: moment,
                        measuredAt: moment
                    )
                    fresh[span] = .falling(
                        QuotaForecast.shifted(base, remaining: remaining, blockedUntil: until, now: moment)
                    )
                    continue
                }
            }

            let estimate = QuotaForecast.estimate(samples: track.samples, now: moment)
            if case let .falling(forecast) = estimate {
                RateMemory.remember(forecast.dropPerMinute, spanMinutes: span)
            }
            fresh[span] = estimate
        }

        if fresh != estimates {
            estimates = fresh
        }
    }

    // MARK: 登录

    func beginSignIn() async {
        failureText = nil
        report = nil

        do {
            if bridge == nil {
                await connect()
            }
            guard let bridge else {
                throw BridgeError.bridgeCold
            }

            phase = .authorizing
            NSWorkspace.shared.open(try await bridge.beginLogin())
        } catch {
            noteFailure(error)
        }
    }

    func openUsagePage() {
        guard let page = URL(string: "https://chatgpt.com/codex/settings/usage") else {
            return
        }
        NSWorkspace.shared.open(page)
    }

    // MARK: 轮询

    private func startTicking() {
        guard ticker == nil else { return }

        ticker = Task { [weak self] in
            var keepGoing = true
            while keepGoing {
                let seconds = Preferences.shared.cadenceSeconds
                try? await Task.sleep(for: .seconds(seconds))
                keepGoing = !Task.isCancelled
                if keepGoing {
                    await self?.pull()
                }
            }
        }
    }

    // MARK: 助手推过来的消息

    private func handleNotice(_ method: String, _ params: WireValue) {
        switch method {
        case Signal.signInFinished:
            guard params["success"]?.asTruthy == true else {
                failureText = params["error"]?.asText ?? "登录没有完成。"
                phase = .awaitingSignIn
                return
            }
            reloadAccountThenPull(startTickingAfterwards: true)

        case Signal.accountTouched:
            spawn { stream in
                guard let bridge = stream.bridge else { return }
                do {
                    stream.account = try await bridge.readAccount()
                    if stream.account.isSignedIn {
                        await stream.pull()
                    } else {
                        stream.phase = .awaitingSignIn
                    }
                } catch {
                    stream.noteFailure(error)
                }
            }

        case Signal.quotaTouched:
            // 助手说数字变了，直接重读，别等下一轮
            spawn { stream in
                await stream.pull()
            }

        default:
            break
        }
    }

    private func reloadAccountThenPull(startTickingAfterwards: Bool) {
        spawn { stream in
            guard let bridge = stream.bridge else { return }
            do {
                stream.account = try await bridge.readAccount()
                await stream.pull()
                if startTickingAfterwards {
                    stream.startTicking()
                }
            } catch {
                stream.noteFailure(error)
            }
        }
    }

    /// 把一段异步收尾工作挂到独立任务上；对象已经释放就什么都不做。
    /// 推送回调来自任意线程，所以闭包统一在主 actor 上跑。
    private func spawn(_ work: @escaping @MainActor (QuotaStream) async -> Void) {
        Task { [weak host = self] in
            guard let host else { return }
            await work(host)
        }
    }

    // MARK: 失败与重试

    private func noteFailure(_ error: Error) {
        failureText = error.localizedDescription
        phase = .stalled
        scheduleRetry()
    }

    /// 只在「轮询根本没跑起来」时补一次重试：首次握手失败、助手被系统杀掉这类情况，
    /// 以前只能靠用户手点刷新才能恢复。轮询期间的偶发失败交给下一轮，不叠加退避。
    private func scheduleRetry() {
        guard ticker == nil, retries == nil, !isPreviewing else { return }

        let wait = Self.retryLadder[min(attemptIndex, Self.retryLadder.count - 1)]
        attemptIndex += 1

        retries = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.retries = nil
            await self.connect()
        }
    }
}
