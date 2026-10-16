import AppKit
import Foundation
import Network

struct Account: Codable, Identifiable, Equatable {
    var username: String
    var muted = false
    var lastPlayedAt: Date?
    var characterName: String?
    var level: Int?
    var playSeconds: Int?

    var id: String { username.lowercased() }

    init(username: String) {
        self.username = username
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decode(String.self, forKey: .username)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName)
        level = try c.decodeIfPresent(Int.self, forKey: .level)
        playSeconds = try c.decodeIfPresent(Int.self, forKey: .playSeconds)
    }

    var characterDetails: String? {
        var parts: [String] = []
        if let level { parts.append("Nível \(level)") }
        if let playSeconds, playSeconds > 0 { parts.append(Formatting.playTime(playSeconds)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct LoginRequest: Identifiable {
    let id = UUID()
    var username: String
    var message: String?
}

enum ServerState: Equatable {
    case checking
    case online(Int)
    case offline
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var sessions: [String: GameSession] = [:]
    @Published private(set) var server: ServerState = .checking
    @Published private(set) var cacheUsage: Int64 = 0
    @Published var loginRequest: LoginRequest?
    @Published private(set) var prefetch = CacheProxy.PrefetchProgress()

    @Published var prefetchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(prefetchEnabled, forKey: "prefetchEnabled")
            proxy?.prefetchEnabled = prefetchEnabled
        }
    }

    @Published var highFrameRate: Bool {
        didSet {
            UserDefaults.standard.set(highFrameRate, forKey: "highFrameRate")
            refreshVisibility(force: true)
        }
    }

    @Published var cacheEnabled: Bool {
        didSet { UserDefaults.standard.set(cacheEnabled, forKey: "cacheEnabled") }
    }

    let api = LauncherAPI()
    private(set) var engineServer: EngineServer?
    private var proxy: CacheProxy?
    private var pathMonitor: NWPathMonitor?
    private var timers: [Timer] = []
    private var lastBoot: String?
    var showLauncher: (() -> Void)?

    private(set) var onBattery = PowerSource.onBattery

    var frameRate: Int { highFrameRate && !onBattery ? 60 : 25 }
    var proxyOrigin: URL? { cacheEnabled ? proxy?.origin : nil }
    var runningSessions: [GameSession] { accounts.compactMap { sessions[$0.id] }.filter(\.isRunning) }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["highFrameRate": false, "cacheEnabled": true, "prefetchEnabled": true])
        highFrameRate = defaults.bool(forKey: "highFrameRate")
        cacheEnabled = defaults.bool(forKey: "cacheEnabled")
        prefetchEnabled = defaults.bool(forKey: "prefetchEnabled")
        loadAccounts()
        UserDefaults(suiteName: "com.adobe.air.ADL")?.set(true, forKey: "NSAppSleepDisabled")
        Quarantine.clearBundle()
        log("[launcher] start v\(AppInfo.fullVersion)")
        Task { await start() }
    }

    private func start() async {
        do {
            let server = try EngineServer()
            try await server.start()
            engineServer = server
        } catch {
            log("[ipc] não abriu: \(error.localizedDescription)")
        }
        do {
            let proxy = try CacheProxy(upstream: Server.game, directory: Paths.shared.cache, legacyDirectory: Paths.shared.legacyCache)
            proxy.prefetchEnabled = prefetchEnabled
            proxy.onPrefetchProgress = { [weak self] progress in
                Task { @MainActor in self?.prefetch = progress }
            }
            _ = try await proxy.start()
            self.proxy = proxy
            cacheUsage = proxy.diskUsage
        } catch {
            log("[cache] não abriu: \(error.localizedDescription)")
        }
        monitorNetwork()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshStatus() }
            },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshProfiles() }
            },
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshVisibility() }
            },
        ]
        await refreshStatus()
        await refreshProfiles()
    }

    func account(_ username: String) -> Account? {
        accounts.first { $0.id == username.lowercased() }
    }

    func session(for account: Account) -> GameSession {
        sessions[account.id] ?? GameSession(username: account.username, model: self)
    }

    func requestLogin(username: String = "", message: String? = nil) {
        showLauncher?()
        loginRequest = LoginRequest(username: username, message: message)
    }

    func completeLogin(_ login: Login) {
        Keychain.store(login.ticket, for: login.username)
        if let index = accounts.firstIndex(where: { $0.id == login.username.lowercased() }) {
            accounts[index].username = login.username
        } else {
            accounts.append(Account(username: login.username))
            sessions[login.username.lowercased()] = GameSession(username: login.username, model: self)
        }
        saveAccounts()
        log("[launcher] login: \(login.username)")
        sessions[login.username.lowercased()]?.play()
        Task { await refreshProfiles() }
    }

    func signOut(_ account: Account) {
        sessions[account.id]?.stop()
        Keychain.remove(for: account.username)
        log("[launcher] sair da conta \(account.username)")
    }

    func remove(_ account: Account) {
        signOut(account)
        accounts.removeAll { $0.id == account.id }
        sessions[account.id] = nil
        saveAccounts()
        log("[launcher] conta removida: \(account.username)")
    }

    func isMuted(_ username: String) -> Bool {
        account(username)?.muted ?? false
    }

    func toggleMute(_ account: Account) {
        guard let index = accounts.firstIndex(of: account) else { return }
        accounts[index].muted.toggle()
        sessions[account.id]?.setMuted(accounts[index].muted)
        saveAccounts()
    }

    func markPlayed(_ username: String) {
        guard let index = accounts.firstIndex(where: { $0.id == username.lowercased() }) else { return }
        accounts[index].lastPlayedAt = Date()
        saveAccounts()
        Task { await refreshProfiles() }
    }

    func refreshProfiles() async {
        let logged = accounts.compactMap { account in
            Keychain.ticket(for: account.username).map { (username: account.username, ticket: $0) }
        }
        guard !logged.isEmpty else { return }
        let profiles: [Profile]
        do {
            profiles = try await api.profiles(logged)
        } catch {
            log("[perfil] falhou: \(error.localizedDescription)")
            return
        }
        if profiles.isEmpty { log("[perfil] o servidor não retornou nenhuma conta") }
        var changed = false
        for profile in profiles {
            guard let index = accounts.firstIndex(where: { $0.id == profile.username.lowercased() }) else { continue }
            var account = accounts[index]
            account.characterName = profile.characterName ?? account.characterName
            account.level = profile.level ?? account.level
            account.playSeconds = profile.playSeconds ?? account.playSeconds
            if account != accounts[index] {
                accounts[index] = account
                changed = true
                log("[perfil] \(account.username): \(account.characterName ?? "sem personagem"), nível \(account.level.map(String.init) ?? "-")")
            }
        }
        if changed {
            saveAccounts()
            sessions.values.forEach { $0.refreshTitle() }
        }
    }

    func prepareCache() {
        if cacheEnabled { proxy?.prepare() }
    }

    func clearCache() {
        proxy?.clear()
        prefetch = CacheProxy.PrefetchProgress()
        cacheUsage = proxy?.diskUsage ?? 0
        log("[cache] limpo")
    }

    func refreshCacheUsage() {
        cacheUsage = proxy?.diskUsage ?? 0
    }

    func handleShortcut(_ key: String, from session: GameSession) {
        let running = runningSessions
        switch key {
        case "F5":
            session.restart()
        case "Ctrl+W":
            session.stop()
        case "Ctrl+T":
            NSApp.activate()
            requestLogin()
        case "Ctrl+Tab", "Ctrl+Shift+Tab":
            guard let index = running.firstIndex(where: { $0 === session }), running.count > 1 else { return }
            let step = key == "Ctrl+Tab" ? 1 : running.count - 1
            running[(index + step) % running.count].play()
        default:
            if key.hasPrefix("Ctrl+"), let number = Int(key.dropFirst(5)), running.indices.contains(number - 1) {
                running[number - 1].play()
            }
        }
    }

    func refreshVisibility(force: Bool = false) {
        let running = runningSessions
        guard !running.isEmpty else { return }
        let visible = WindowVisibility.onscreenProcesses()
        guard !visible.isEmpty else { return }
        let battery = PowerSource.onBattery
        let changed = force || battery != onBattery
        onBattery = battery
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for session in running {
            let pid = session.pid ?? 0
            session.updateFrameRate(visible: visible.contains(pid), focused: pid == frontmost, force: changed)
        }
    }

    func quitAllGames() async {
        let running = runningSessions
        running.forEach { $0.stop() }
        for _ in 0..<40 where running.contains(where: \.isRunning) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func refreshStatus() async {
        do {
            let status = try await api.status()
            if let lastBoot, lastBoot != status.boot {
                log("[server] reiniciou (boot \(lastBoot) -> \(status.boot))")
            }
            lastBoot = status.boot
            server = .online(status.online)
        } catch {
            server = .offline
        }
        refreshCacheUsage()
    }

    private func monitorNetwork() {
        let monitor = NWPathMonitor()
        var wasOffline = false
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied, wasOffline {
                    log("[rede] conexão voltou")
                    await self.refreshStatus()
                    self.sessions.values.forEach { $0.networkReturned() }
                }
                wasOffline = !satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.legendremake.network"))
        pathMonitor = monitor
    }

    private func loadAccounts() {
        if let data = try? Data(contentsOf: Paths.shared.accounts),
           let saved = try? JSONDecoder.iso.decode([Account].self, from: data) {
            accounts = saved
        }
        for account in accounts {
            sessions[account.id] = GameSession(username: account.username, model: self)
        }
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder.iso.encode(accounts) else { return }
        try? data.write(to: Paths.shared.accounts, options: .atomic)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
