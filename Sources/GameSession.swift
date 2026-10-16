import AppKit
import Foundation

@MainActor
final class GameSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case idle
        case checking
        case loading(Double?)
        case playing
        case reconnecting(at: Date, reason: String)
        case kicked
        case hung
        case failed(String)
    }

    let username: String
    nonisolated var id: String { username.lowercased() }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var online = false
    @Published private(set) var onlineSince: Date?
    @Published private(set) var fps: Int?
    @Published private(set) var memoryMB: Int?

    private unowned let model: AppModel
    private var process: Process?
    private var link: EngineLink?
    private var token = ""
    private var ticket = ""
    private var stopping = false
    private var attempts = 0
    private var lastPerf = Date()
    private var startedAt: Date?
    private var previousAccess: Date?
    private var sentFrameRate: Int?
    private var hiddenChecks = 0
    private var sentTitle: String?
    private var task: Task<Void, Never>?
    private var watchdog: Timer?
    private let engineLog: LogFile

    private static let retryDelays: [TimeInterval] = [3, 10, 30]
    private static let hiddenFrameRate = 10
    private static let backgroundFrameRate = 25

    init(username: String, model: AppModel) {
        self.username = username
        self.model = model
        engineLog = LogFile(Paths.shared.logs.appending(path: "engine-\(username.lowercased()).log"))
    }

    var isRunning: Bool { process?.isRunning == true }
    var pid: pid_t? { isRunning ? process?.processIdentifier : nil }

    var isBusy: Bool {
        switch phase {
        case .checking, .loading: true
        default: false
        }
    }

    func play() {
        if phase == .playing || phase == .hung, let pid {
            NSRunningApplication(processIdentifier: pid)?.bringToFront()
            return
        }
        guard !isBusy else { return }
        task?.cancel()
        task = Task { await launch() }
    }

    func restart() {
        attempts = 0
        terminate { [weak self] in self?.play() }
    }

    func stop() {
        task?.cancel()
        attempts = 0
        terminate { [weak self] in self?.phase = .idle }
    }

    func waitForEngine() {
        guard phase == .hung else { return }
        lastPerf = Date()
        phase = .playing
    }

    func setMuted(_ muted: Bool) {
        link?.send("mute", muted ? "1" : "0")
    }

    func networkReturned() {
        switch phase {
        case .reconnecting, .failed: play()
        default: break
        }
    }

    func updateFrameRate(visible: Bool, focused: Bool, force: Bool = false) {
        guard phase == .playing || phase == .hung, let startedAt else { return }
        if force { sentFrameRate = nil }
        hiddenChecks = visible ? 0 : hiddenChecks + 1
        let warmingUp = Date().timeIntervalSince(startedAt) < 4
        let target: Int
        if warmingUp || focused {
            target = model.frameRate
        } else if hiddenChecks >= 3 {
            target = Self.hiddenFrameRate
        } else {
            target = min(model.frameRate, Self.backgroundFrameRate)
        }
        guard target != sentFrameRate else { return }
        sentFrameRate = target
        link?.send("fps", String(target))
    }

    func refreshTitle() {
        guard let link else { return }
        let title = windowTitle()
        guard title != sentTitle else { return }
        sentTitle = title
        link.send("title", title)
    }

    private func windowTitle() -> String {
        let account = model.account(username)
        var parts: [String] = []
        if let name = account?.characterName {
            parts.append(account?.level.map { "\(name) (Nv. \($0))" } ?? name)
        }
        parts.append(username)
        switch phase {
        case .playing where online:
            if let onlineSince { parts.append("Online há \(Formatting.elapsed(since: onlineSince))") }
        case .playing:
            parts.append("Conectando…")
        case .hung:
            parts.append("Sem resposta")
        default:
            parts.append("Carregando…")
        }
        if let previousAccess {
            parts.append("Último acesso: \(Formatting.lastAccess(previousAccess))")
        }
        return "Legend Remake — " + parts.joined(separator: " · ")
    }

    private func launch() async {
        phase = .checking
        model.prepareCache()
        guard let saved = Keychain.ticket(for: username) else {
            phase = .idle
            model.requestLogin(username: username)
            return
        }
        do {
            try await model.api.resume(username: username, ticket: saved)
        } catch is CancellationError {
            return
        } catch LauncherError.rejected(let message) {
            log("[\(username)] sessão recusada: \(message)")
            Keychain.remove(for: username)
            phase = .idle
            model.requestLogin(username: username, message: "Sua sessão expirou. Entre novamente.")
            return
        } catch {
            scheduleRetry(reason: error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }
        ticket = saved
        startEngine()
    }

    private func startEngine() {
        guard let server = model.engineServer, server.port > 0 else {
            phase = .failed("Não foi possível preparar o jogo. Feche o launcher e abra de novo.")
            return
        }
        token = UUID().uuidString
        stopping = false
        sentFrameRate = nil
        sentTitle = nil
        startedAt = nil
        online = false
        onlineSince = nil
        fps = nil
        memoryMB = nil
        previousAccess = model.account(username)?.lastPlayedAt
        phase = .loading(nil)

        server.expect(token: token) { [weak self] link in self?.attach(link) }

        let process = Process()
        process.executableURL = Paths.shared.adl
        process.arguments = [
            "-nodebug", "-profile", "extendedDesktop",
            Paths.shared.engineDescriptor.path, Paths.shared.engineRoot.path,
            "--", "--ipc=\(server.port)", "--token=\(token)", "--slot=\(username)",
        ]
        let output = Pipe()
        let filter = EngineOutputFilter(log: engineLog)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                filter.consume(data)
            }
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.qualityOfService = .userInteractive
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in self?.engineExited(finished, status: status, reason: reason) }
        }
        do {
            try process.run()
        } catch {
            server.forget(token: token)
            phase = .failed("O jogo não abriu: \(error.localizedDescription)")
            return
        }
        self.process = process
        log("[\(username)] motor aberto, pid \(process.processIdentifier)")
        startWatchdog()
    }

    private func attach(_ link: EngineLink) {
        self.link = link
        link.onMessage = { [weak self] fields in self?.handle(fields) }
        link.onClose = { [weak self] in self?.linkClosed() }
        model.engineServer?.forget(token: token)
        sentFrameRate = model.frameRate
        link.send("fps", String(model.frameRate))
        refreshTitle()
        link.send("play", Server.gameOrigin(model).absoluteString, username, ticket, model.isMuted(username) ? "1" : "0")
        link.send("front", "1")
        lastPerf = Date()
    }

    private func handle(_ fields: [String]) {
        guard let kind = fields.first else { return }
        let arg = { (index: Int) in fields.indices.contains(index) ? fields[index] : "" }
        switch kind {
        case "state":
            handleState(arg(1), Double(arg(2)), Double(arg(3)))
        case "perf":
            lastPerf = Date()
            fps = Int(arg(1))
            memoryMB = Int(arg(2))
            if phase == .hung {
                phase = .playing
                refreshTitle()
            }
        case "key":
            model.handleShortcut(arg(1), from: self)
        case "log":
            engineLog.write(arg(1))
        default:
            break
        }
    }

    private func handleState(_ state: String, _ loaded: Double?, _ total: Double?) {
        switch state {
        case "loading":
            if let loaded, let total, total > 0 { phase = .loading(min(loaded / total, 1)) }
        case "started":
            phase = .playing
            startedAt = Date()
            lastPerf = Date()
            model.markPlayed(username)
            log("[\(username)] jogo na tela")
            if let pid { NSRunningApplication(processIdentifier: pid)?.bringToFront() }
        case "online":
            online = true
            onlineSince = onlineSince ?? Date()
            attempts = 0
            log("[\(username)] conectado ao jogo")
        case "offline":
            online = false
            lost("A conexão com o servidor caiu.")
        case "kicked":
            online = false
            log("[\(username)] conta conectada em outro lugar")
            terminate { [weak self] in self?.phase = .kicked }
        case "failed":
            lost("O jogo não carregou.")
        default:
            break
        }
        refreshTitle()
    }

    private func lost(_ reason: String) {
        log("[\(username)] \(reason)")
        terminate { [weak self] in self?.scheduleRetry(reason: reason) }
    }

    private func scheduleRetry(reason: String) {
        guard attempts < Self.retryDelays.count else {
            phase = .failed(reason)
            return
        }
        let delay = Self.retryDelays[attempts]
        attempts += 1
        phase = .reconnecting(at: Date().addingTimeInterval(delay), reason: reason)
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.launch()
        }
    }

    private func linkClosed() {
        link = nil
        guard !stopping, isRunning else { return }
        log("[\(username)] motor fechou a conexão")
    }

    private func engineExited(_ finished: Process, status: Int32, reason: Process.TerminationReason) {
        guard finished === process else { return }
        watchdog?.invalidate()
        link?.close()
        link = nil
        model.engineServer?.forget(token: token)
        process = nil
        online = false
        onlineSince = nil
        startedAt = nil
        fps = nil
        memoryMB = nil
        log("[\(username)] motor terminou (código \(status))")
        if stopping {
            stopping = false
            return
        }
        switch phase {
        case .kicked, .failed, .reconnecting:
            return
        case .playing where status == 0 && reason == .exit, .loading where status == 0 && reason == .exit:
            phase = .idle
        default:
            scheduleRetry(reason: "O jogo fechou inesperadamente.")
        }
    }

    private func terminate(then next: @escaping @MainActor () -> Void) {
        watchdog?.invalidate()
        guard let process, process.isRunning else {
            next()
            return
        }
        stopping = true
        link?.send("quit")
        let pid = process.processIdentifier
        Task { [weak self] in
            for _ in 0..<30 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { kill(pid, SIGKILL) }
            process.waitUntilExit()
            await MainActor.run {
                self?.engineExited(process, status: 0, reason: .exit)
                next()
            }
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let launchedAt = Date()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth(launchedAt: launchedAt) }
        }
    }

    private func checkHealth(launchedAt: Date) {
        let now = Date()
        switch phase {
        case .loading where link == nil && now.timeIntervalSince(launchedAt) > 25:
            lost("O jogo demorou demais para abrir.")
        case .playing where now.timeIntervalSince(lastPerf) > 30:
            log("[\(username)] o jogo não responde há \(Int(now.timeIntervalSince(lastPerf))) s")
            phase = .hung
            refreshTitle()
        case .playing:
            refreshTitle()
        default:
            break
        }
    }
}

final class EngineOutputFilter: @unchecked Sendable {
    private static let noise = ["receive pkg.code", "error messaging the mach port"]
    private let log: LogFile
    private let lock = NSLock()
    private var pending = Data()

    init(log: LogFile) {
        self.log = log
    }

    func consume(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var result: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                result.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return result
        }
        for line in lines where !line.isEmpty && !Self.noise.contains(where: line.contains) {
            log.write(line)
        }
    }
}

extension Server {
    @MainActor
    static func gameOrigin(_ model: AppModel) -> URL {
        model.proxyOrigin ?? game
    }
}
