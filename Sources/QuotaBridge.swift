import AppKit
import Foundation

// MARK: - 账号

/// 当前挂在助手上的账号。没登录时三个字段都是空/否，不区分「没登录」和「读失败」。
struct LinkedAccount: Equatable {
    var isSignedIn: Bool
    var email: String?
    var planType: String?

    static let signedOut = LinkedAccount(isSignedIn: false, email: nil, planType: nil)
}

// MARK: - 错误

enum BridgeError: LocalizedError {
    /// 包里没找到可执行文件
    case runtimeNotFound
    /// 还没起来就往里写
    case bridgeCold
    /// 进程没了
    case bridgeDied
    /// 一条请求等太久
    case unresponsive
    /// 回包不是合法 JSON-RPC
    case garbledReply
    /// 助手自己报的错，原文照抄给用户
    case assistantSaid(String)

    var errorDescription: String? { spoken }

    /// 这几类意味着「这条管道不能用了」，调用方应当整个换掉而不是重试当前请求
    var poisonsChannel: Bool {
        switch self {
        case .bridgeCold, .bridgeDied, .unresponsive:
            return true
        case .runtimeNotFound, .garbledReply, .assistantSaid:
            return false
        }
    }

    /// 给界面看的一句话
    private var spoken: String {
        switch self {
        case .runtimeNotFound:
            return "没有找到内置额度服务程序。"
        case .bridgeCold:
            return "额度服务尚未启动。"
        case .bridgeDied:
            return "额度服务意外停止了。"
        case .unresponsive:
            return "额度服务长时间没有响应。"
        case .garbledReply:
            return "额度服务返回了无法识别的数据。"
        case .assistantSaid(let detail):
            return detail
        }
    }
}

// MARK: - 子进程管道

/// 只管一件事：把子进程跑起来，并且安全地拿到它的 stdin。
/// 结束、判活都从这里走，调用方不需要直接碰 Process / FileHandle。
private final class ChildChannel {
    private let mutex = NSLock()
    private var worker: Process?
    private var sink: FileHandle?

    /// stdin 句柄；没起来时是 nil
    var writable: FileHandle? {
        mutex.lock()
        defer { mutex.unlock() }
        return sink
    }

    var alive: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return worker?.isRunning == true
    }

    func adopt(_ process: Process, input: FileHandle) {
        mutex.lock()
        worker = process
        sink = input
        mutex.unlock()
    }

    /// 交出并清空当前进程，返回给调用方自行收尾（这里不 terminate，避免持锁跑外部代码）
    func detach() -> (process: Process?, pipe: FileHandle?) {
        mutex.lock()
        defer { mutex.unlock() }
        let pair = (worker, sink)
        worker = nil
        sink = nil
        return pair
    }
}

// MARK: - 待回包登记表

/// 请求号 → 等待中的 continuation。超时与正常回包谁先到都能安全兑现（后到的拿不到槽位，直接放弃）。
private final class RequestRegistry {
    private let serial = DispatchQueue(label: "com.quotadock.bridge.tickets")
    private var parked: [Int: CheckedContinuation<WireValue, Error>] = [:]
    private var lastTicket = 0

    func newTicket() -> Int {
        serial.sync {
            lastTicket += 1
            return lastTicket
        }
    }

    func park(_ continuation: CheckedContinuation<WireValue, Error>, at ticket: Int) {
        serial.sync { parked[ticket] = continuation }
    }

    /// 取走槽位；已被取走或从未登记时返回 nil
    func claim(_ ticket: Int) -> CheckedContinuation<WireValue, Error>? {
        serial.sync { parked.removeValue(forKey: ticket) }
    }

    /// 清空并交还所有等待者
    func evictAll() -> [CheckedContinuation<WireValue, Error>] {
        serial.sync {
            let all = Array(parked.values)
            parked.removeAll()
            return all
        }
    }
}

// MARK: - 字节流分帧

/// 管道给的是随时可能断在半个 JSON 里的字节流，这里攒够一个换行才吐一帧。
private final class InboundFramer {
    private let serial = DispatchQueue(label: "com.quotadock.bridge.framer")
    private var carry = Data()

    func push(_ chunk: Data) -> [Data] {
        serial.sync {
            carry.append(chunk)

            var frames: [Data] = []
            while let terminator = carry.firstIndex(of: 0x0A) {
                let head = carry[carry.startIndex..<terminator]
                carry.removeFirst(terminator - carry.startIndex + 1)

                // 聊天式接口偶尔发 CRLF，行尾的 \r 不算内容
                let trimmed = head.drop { byte in byte == 0x0D }
                if !trimmed.isEmpty {
                    frames.append(Data(trimmed))
                }
            }
            return frames
        }
    }
}

// MARK: - 桥

/// 与内置额度助手之间的一条 JSON-RPC 通道。
/// 一个实例对应一个子进程；进程死了就当废物丢掉，由上层新建。
final class QuotaBridge: @unchecked Sendable {
    typealias NoticeHandler = @Sendable (String, WireValue) -> Void

    /// 单条请求最多等多久。没这个上限时，助手卡住（刚唤醒、被挂起）会让刷新永远悬着，
    /// 轮询停摆、界面停在旧数字上，用户看不出哪儿坏了。
    private static let replyDeadline: TimeInterval = 20

    private let runtime: URL
    private let agentHome: URL?

    private let channel = ChildChannel()
    private let registry = RequestRegistry()
    private let framer = InboundFramer()
    /// 只保护「一帧一帧往外写」，不参与任何状态判断
    private let writeGate = NSLock()

    /// 服务端主动推的消息（登录完成、额度刷新等）
    var onNotice: NoticeHandler?

    /// 协议里必填、我们什么都不声明的那个字段
    private static let noCapabilities = WireValue.record([:])

    init(runtime: URL = AgentRuntime.resolved(),
         agentHome: URL? = AgentWorkspace.defaultLocation()) {
        self.runtime = runtime
        self.agentHome = agentHome
    }

    /// 进程还在不在。上层据此决定「继续用」还是「换一条」。
    var isProcessAlive: Bool { channel.alive }

    // MARK: 起停

    func launch() async throws {
        guard !channel.alive else { return }

        guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw BridgeError.runtimeNotFound
        }
        if let agentHome {
            try FileManager.default.createDirectory(at: agentHome, withIntermediateDirectories: true)
        }

        let intake = Pipe()
        let transcript = Pipe()
        let diagnostics = Pipe()

        let worker = Process()
        worker.executableURL = runtime
        worker.arguments = ["app-server"]
        worker.standardInput = intake
        worker.standardOutput = transcript
        worker.standardError = diagnostics
        worker.environment = launchEnvironment()

        transcript.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self?.absorb(chunk)
        }

        // 诊断输出必须一直读走：没人读的话管道塞满，助手进程会直接卡在写日志上。
        // 内容一律丢弃，不落盘也不进日志——里面可能夹着账号信息。
        diagnostics.fileHandleForReading.readabilityHandler = { noise in
            _ = noise.availableData
        }

        worker.terminationHandler = { [weak self] _ in
            self?.channelDied()
        }

        try worker.run()
        channel.adopt(worker, input: intake.fileHandleForWriting)

        // 握手：报上自己的名字与版本，再补一条 initialized 通知
        var client: [String: WireValue] = [:]
        client["name"] = .text("quotadock")
        client["title"] = .text("QuotaDock")
        client["version"] = .text(BuildStamp.current)

        let hello = try await ask("initialize", .record([
            "clientInfo": .record(client),
            "capabilities": Self.noCapabilities
        ]))
        guard hello.asRecord != nil else {
            throw BridgeError.garbledReply
        }
        try notify("initialized", .record([:]))
    }

    func shutdown() {
        let leftover = channel.detach()
        try? leftover.pipe?.close()
        if leftover.process?.isRunning == true {
            leftover.process?.terminate()
        }
        sweepWaiting(with: BridgeError.bridgeDied)
    }

    // MARK: 业务调用

    func readAccount() async throws -> LinkedAccount {
        let payload = try await ask("account/read", .record(["refreshToken": .flag(false)]))

        guard let root = payload.asRecord else {
            throw BridgeError.garbledReply
        }
        guard let node = root["account"]?.asRecord else {
            return .signedOut
        }

        return LinkedAccount(
            isSignedIn: true,
            email: node["email"]?.asText,
            planType: node["planType"]?.asText
        )
    }

    func readQuota() async throws -> QuotaReport {
        let payload = try await ask("account/rateLimits/read", .record([:]))
        return try QuotaDecoder.decode(payload)
    }

    func beginLogin() async throws -> URL {
        // 走浏览器托管页：授权完由服务端把结果推回来，我们不需要起本地回调端口
        var form: [String: WireValue] = [:]
        form["appBrand"] = .text("chatgpt")
        form["type"] = .text("chatgpt")
        form["useHostedLoginSuccessPage"] = .flag(true)

        let payload = try await ask("account/login/start", .record(form))

        guard let address = payload["authUrl"]?.asText else {
            throw BridgeError.garbledReply
        }
        guard let link = URL(string: address) else {
            throw BridgeError.garbledReply
        }
        return link
    }

    func signOut() async throws {
        _ = try await ask("account/logout", .record([:]))
    }

    // MARK: 收发

    private func ask(_ method: String, _ params: WireValue) async throws -> WireValue {
        let ticket = registry.newTicket()

        // 到点就把槽位兑成失败；若回包已经先一步确认，claim 会扑空，等于什么也没发生
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.replyDeadline
        ) { [weak self] in
            self?.finish(ticket, with: .failure(BridgeError.unresponsive))
        }

        return try await withCheckedThrowingContinuation { (slot: CheckedContinuation<WireValue, Error>) in
            registry.park(slot, at: ticket)
            do {
                try submit(method, params, carrying: ticket)
            } catch {
                finish(ticket, with: .failure(error))
            }
        }
    }

    private func notify(_ method: String, _ params: WireValue) throws {
        try submit(method, params, carrying: nil)
    }

    private func submit(_ method: String, _ params: WireValue, carrying ticket: Int?) throws {
        var envelope = [String: WireValue]()
        envelope["method"] = .text(method)
        envelope["params"] = params
        if let ticket {
            envelope["id"] = .decimal(Double(ticket))
        }
        try write(.record(envelope))
    }

    private func write(_ message: WireValue) throws {
        guard let sink = channel.writable else {
            throw BridgeError.bridgeCold
        }

        var payload = try JSONEncoder().encode(message)
        payload.append(0x0A)

        writeGate.lock()
        defer { writeGate.unlock() }
        try sink.write(contentsOf: payload)
    }

    // MARK: 收包

    private func absorb(_ chunk: Data) {
        for frame in framer.push(chunk) {
            consume(frame)
        }
    }

    private func consume(_ frame: Data) {
        let decoded = try? JSONDecoder().decode(WireValue.self, from: frame)
        guard let fields = decoded?.asRecord else {
            return
        }

        if let ticket = fields["id"]?.asInteger {
            finish(ticket, with: verdict(from: fields))
            return
        }

        guard let method = fields["method"]?.asText else { return }
        onNotice?(method, fields["params"] ?? .nothing)
    }

    private func verdict(from fields: [String: WireValue]) -> Result<WireValue, Error> {
        if let complaint = fields["error"]?.asRecord {
            let detail = complaint["message"]?.asText ?? "额度请求失败。"
            return .failure(BridgeError.assistantSaid(detail))
        }
        if let payload = fields["result"] {
            return .success(payload)
        }
        return .failure(BridgeError.garbledReply)
    }

    private func finish(_ ticket: Int, with result: Result<WireValue, Error>) {
        guard let waiting = registry.claim(ticket) else { return }
        waiting.resume(with: result)
    }

    // MARK: 收尾

    private func channelDied() {
        _ = channel.detach()
        sweepWaiting(with: BridgeError.bridgeDied)
    }

    private func sweepWaiting(with error: Error) {
        for waiting in registry.evictAll() {
            waiting.resume(throwing: error)
        }
    }

    private func launchEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let agentHome {
            // 让助手把登录态写进容器，而不是用户全局的 ~/.codex
            env["CODEX_HOME"] = agentHome.path
        }
        return env
    }
}

// MARK: - 可执行文件与工作目录

/// 找「额度助手」可执行文件：包内内置 → 环境变量指定 → npm 全局装的那份。
enum AgentRuntime {
    /// 包内路径（正常安装后就走这条）。从可执行文件往回退两级就是 `Contents`。
    private static var embeddedPath: String {
        let contents = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/", isDirectory: true)
        return contents
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "codex")
            .path
    }

    /// 只供开发调试：外部已经装过 CLI 时的常见落点
    private static var loosePaths: [String] {
        [
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/"
                + "@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
            "/usr/local/lib/node_modules/@openai/codex/node_modules/"
                + "@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        ]
    }

    static func resolved() -> URL {
        var ordered = [embeddedPath]
        if let custom = ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"] {
            ordered.append(custom)
        }
        ordered += loosePaths

        for candidate in ordered
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        // 故意给一个不存在的路径：launch() 会据此抛 runtimeNotFound，报错文案才准确
        return URL(fileURLWithPath: "/nonexistent/quotadock-runtime")
    }
}

/// 助手自己的工作目录。给它一个独立目录，登录态与配置不会碰到用户全局那份。
enum AgentWorkspace {
    static func defaultLocation() -> URL? {
        if ProcessInfo.processInfo.environment["QUOTADOCK_KEEP_AGENT_HOME"] == "1" {
            return nil
        }

        // 沙箱里拿到的就是容器内的 Application Support
        let roots = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
        guard let root = roots.first else { return nil }

        return URL(fileURLWithPath: root, isDirectory: true)
            .appending(path: "QuotaDock", directoryHint: .isDirectory)
            .appending(path: "Codex", directoryHint: .isDirectory)
    }
}

enum BuildStamp {
    static let current: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }()
}
