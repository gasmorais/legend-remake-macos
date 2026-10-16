import Foundation
import Network

final class CacheProxy: @unchecked Sendable {
    enum Freshness {
        case immutable
        case revalidate
        case live
    }

    struct PrefetchProgress: Equatable {
        var done = 0
        var total = 0
    }

    private let upstream: URL
    private let disk: DiskCache
    private let legacyDirectory: URL
    private let downloader = Downloader()
    private let liveSession: URLSession
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.legendremake.cache", attributes: .concurrent)
    private let requestLog = LogFile(Paths.shared.logs.appending(path: "requests.log"))
    private let state = ProxyState()
    private(set) var origin: URL?
    var prefetchEnabled = true
    var onPrefetchProgress: (@Sendable (PrefetchProgress) -> Void)?

    private static let forwardedRequestHeaders: Set<String> = [
        "user-agent", "referer", "accept", "accept-language", "content-type", "cookie", "x-flash-version", "x-requested-with",
    ]
    private static let rewrittenPrefixes = ["/cdn/", "/xml/"]
    private static let rewrittenBases = ["REQUEST_PATH", "FOWARDSITE"]
    private static let staticExtensions: Set<String> = [
        "swf", "png", "jpg", "jpeg", "gif", "mp3", "wav", "xml", "dat", "txt", "json", "zip", "bin", "atf", "css", "js",
    ]
    private static let bustingParameters: Set<String> = ["rnd", "random", "nocache", "_"]
    private static let timestampParameters: Set<String> = ["v", "t", "time"]
    private static let freshFor: TimeInterval = 30 * 60
    private static let transformedPaths: Set<String> = ["/client/config.xml", "/client/Loading.swf", "/client/code_md5.dat"]
    private static let missingFor: TimeInterval = 10 * 60
    private static let priorityModules = [
        "playerinfo", "army", "fashion", "mounts", "pet", "shop", "store", "task", "friends", "mailcheck",
        "consortia", "vip", "playerlevelup", "heroroad", "setting", "chat",
    ]

    init(upstream: URL, directory: URL, legacyDirectory: URL) throws {
        self.upstream = upstream
        disk = DiskCache(directory: directory)
        self.legacyDirectory = legacyDirectory

        let live = URLSessionConfiguration.ephemeral
        live.urlCache = nil
        live.requestCachePolicy = .reloadIgnoringLocalCacheData
        live.httpShouldSetCookies = false
        live.httpCookieAcceptPolicy = .never
        live.httpMaximumConnectionsPerHost = 8
        live.timeoutIntervalForRequest = 60
        liveSession = URLSession(configuration: live)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    var diskUsage: Int64 { disk.usage }

    func start() async throws -> URL {
        await importLegacyCache()
        let port = try await listener.startOnLoopback(queue: queue) { [weak self] connection in
            self?.serve(connection)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        origin = url
        watchStalls()
        log("[cache] proxy em \(url.absoluteString), \(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file)) em disco")
        prepare()
        return url
    }

    func prepare() {
        guard state.beginWarmUp(every: 10 * 60) else { return }
        Task.detached(priority: .utility) { [weak self] in await self?.warmUp() }
    }

    func clear() {
        disk.clear()
        state.reset()
    }

    private func importLegacyCache() async {
        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return }
        let directory = legacyDirectory
        let disk = disk
        let result = await Task.detached(priority: .userInitiated) {
            LegacyCache.importAll(from: directory, into: disk) { Self.freshness(path: $0.path, method: "GET") == .revalidate }
        }.value
        try? FileManager.default.removeItem(at: directory)
        log("[cache] \(result.files) arquivos do cache antigo importados (\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)))")
    }

    private func warmUp() async {
        let entries = disk.revalidationCandidates(usedWithin: 14 * 24 * 3600)
        guard !entries.isEmpty else { return }
        let started = Date()
        var refreshed = 0
        await withTaskGroup(of: Bool.self) { group in
            var pending = entries.makeIterator()
            func next() -> Bool {
                guard let entry = pending.next() else { return false }
                group.addTask { [weak self] in
                    await self?.revalidate(entry.key, userAgent: entry.meta.userAgent) ?? false
                }
                return true
            }
            for _ in 0..<2 where next() {}
            for await ok in group {
                if ok { refreshed += 1 }
                while state.busy {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                _ = next()
            }
        }
        log("[cache] \(refreshed) de \(entries.count) arquivos conferidos em \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    @discardableResult
    private func revalidate(_ key: String, userAgent: String?) async -> Bool {
        guard state.claim(key) else { return false }
        defer { state.release(key) }
        guard let url = URL(string: key), let current = disk.lookup(key) else { return false }
        var headers: [String: String] = [:]
        if let userAgent = userAgent ?? current.meta.userAgent { headers["User-Agent"] = userAgent }
        if current.meta.etag == nil, current.meta.lastModified == nil,
           let probe = try? await downloader.probe(url, headers: headers),
           probe.status == 200 || probe.status == 206,
           probe.etag != nil || probe.lastModified != nil {
            if probe.length == current.meta.size {
                disk.adoptValidators(key, etag: probe.etag, lastModified: probe.lastModified)
                return true
            }
        }
        guard let outcome = try? await downloader.fetch(url, headers: headers, validating: current.meta) else { return false }
        switch outcome {
        case .notModified:
            disk.markValidated(key)
        case .fetched(let response) where response.status == 200:
            store(key, response, userAgent: userAgent, revalidates: true)
        case .fetched:
            return false
        }
        return true
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            var buffer = Data()
            while let request = await HTTPRequest.read(from: connection, buffer: &buffer) {
                let id = state.begin("\(request.method) \(request.target)")
                let reusable = await handle(request, on: connection)
                state.end(id)
                if !reusable || !request.keepAlive { break }
            }
            connection.cancel()
        }
    }

    private func watchStalls() {
        Task.detached(priority: .utility) { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(5))
                for (request, seconds) in self.state.stalled(after: 15) {
                    self.requestLog.write("AGUARDANDO \(seconds) s \(request)")
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async -> Bool {
        if request.method == "GET" || request.method == "HEAD", let (url, _, _) = normalize(request),
           let status = state.missingStatus(url.absoluteString, within: Self.missingFor) {
            record(request.method, status, "ausente", Date(), 0, request.target)
            await connection.sendAsync(HTTPResponse(status: status).serialized(headOnly: request.method == "HEAD"))
            return true
        }
        guard request.method == "GET",
              let (url, path, headers) = normalize(request),
              Self.freshness(path: path, method: request.method) != .live,
              !Self.transformedPaths.contains(path),
              !disk.contains(url.absoluteString)
        else {
            let response = await respond(to: request)
            await connection.sendAsync(response.serialized(headOnly: request.method == "HEAD"))
            return true
        }
        return await streamDownload(url, path: path, headers: headers, target: request.target, to: connection)
    }

    private func streamDownload(_ url: URL, path: String, headers: [String: String], target: String, to connection: NWConnection) async -> Bool {
        let key = url.absoluteString
        let started = Date()
        if let running = state.download(for: key) {
            let response = try? await running.value
            let reply = response.map { HTTPResponse(status: $0.status, headers: Self.headers(of: $0), body: $0.data) } ?? HTTPResponse(status: 502)
            record("GET", reply.status, "aguardou", started, reply.body.count, target)
            await connection.sendAsync(reply.serialized(headOnly: false))
            return true
        }

        let sent = SentFlag()
        let freshness = Self.freshness(path: path, method: "GET")
        let userAgent = headers["user-agent"]
        let task = Task<Downloader.Response, Error> { [downloader] in
            let outcome = try await downloader.stream(url, headers: headers, onStart: { total, head in
                sent.mark()
                await connection.sendAsync(HTTPResponse.head(status: 200, headers: Self.headers(of: head), length: total))
            }, onData: { chunk in
                await connection.sendAsync(chunk)
            })
            guard case .fetched(let response) = outcome else { throw URLError(.cannotParseResponse) }
            return response
        }
        state.register(task, for: key)
        defer { state.unregister(key) }

        do {
            let response = try await task.value
            if response.status == 200 {
                store(key, response, userAgent: userAgent, revalidates: freshness == .revalidate)
            } else if response.status == 403 || response.status == 404 {
                state.markMissing(key, status: response.status)
            }
            if !sent.value {
                await connection.sendAsync(HTTPResponse(status: response.status, headers: Self.headers(of: response), body: response.data).serialized(headOnly: false))
            }
            record("GET", response.status, sent.value ? "rede (contínuo)" : "rede", started, response.data.count, target)
            return true
        } catch {
            record("GET", 502, "erro", started, 0, "\(target) (\(error.localizedDescription))")
            if sent.value { return false }
            await connection.sendAsync(HTTPResponse(status: 502).serialized(headOnly: false))
            return true
        }
    }

    private static func headers(of response: Downloader.Response) -> [(String, String)] {
        var result: [(String, String)] = []
        if let type = response.contentType { result.append(("Content-Type", type)) }
        if let cookie = response.setCookie { result.append(("Set-Cookie", cookie)) }
        return result
    }

    private func normalize(_ request: HTTPRequest) -> (URL, String, [String: String])? {
        guard var components = URLComponents(string: request.target),
              let path = components.path.removingPercentEncoding
        else { return nil }
        components.queryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            if Self.bustingParameters.contains(name) { return false }
            if Self.timestampParameters.contains(name), let value = item.value, value.count >= 12, value.allSatisfy(\.isNumber) { return false }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        components.scheme = upstream.scheme
        components.host = upstream.host
        components.port = upstream.port
        guard let url = components.url else { return nil }
        var headers: [String: String] = [:]
        for (name, value) in request.headers where Self.forwardedRequestHeaders.contains(name) {
            headers[name] = value
        }
        return (url, path, headers)
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let (url, path, headers) = normalize(request) else { return HTTPResponse(status: 400) }
        let started = Date()
        do {
            let freshness = Self.freshness(path: path, method: request.method)
            var (response, source) = try await fetch(url, method: request.method, headers: headers, body: request.body, freshness: freshness)
            if response.status == 200 {
                if path == "/client/config.xml", let origin, let text = String(data: response.data, encoding: .utf8) {
                    let sounds = await audioClasses(userAgent: headers["user-agent"])
                    response.data = Data(rewriteConfig(text, origin: origin, sounds: sounds).utf8)
                } else if path == "/client/Loading.swf" {
                    response.data = await withSounds(response.data, userAgent: headers["user-agent"])
                } else if path == "/client/code_md5.dat" {
                    startPrefetch(manifest: response.data, userAgent: headers["user-agent"])
                }
            }
            record(request.method, response.status, source, started, response.data.count, request.target)
            return HTTPResponse(status: response.status, headers: Self.headers(of: response), body: response.data)
        } catch {
            record(request.method, 502, "erro", started, 0, "\(request.target) (\(error.localizedDescription))")
            return HTTPResponse(status: 502)
        }
    }

    private func fetch(_ url: URL, method: String, headers: [String: String], body: Data, freshness: Freshness) async throws -> (Downloader.Response, String) {
        if freshness == .live {
            var request = URLRequest(url: url)
            request.httpMethod = method
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if !body.isEmpty { request.httpBody = body }
            let (data, response) = try await liveSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (Downloader.Response(
                status: http.statusCode,
                data: data,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                setCookie: http.value(forHTTPHeaderField: "Set-Cookie")
            ), "rede")
        }

        let key = url.absoluteString
        let userAgent = headers["user-agent"]
        if let cached = disk.lookup(key) {
            let response = Downloader.Response(status: 200, data: cached.data, etag: cached.meta.etag, lastModified: cached.meta.lastModified, contentType: cached.meta.contentType)
            if freshness == .revalidate && !disk.isFresh(key, within: Self.freshFor) {
                disk.markValidated(key, userAgent: userAgent)
                Task.detached(priority: .utility) { [weak self] in await self?.revalidate(key, userAgent: userAgent) }
                return (response, "disco+confere")
            }
            return (response, "disco")
        }

        if let running = state.download(for: key) {
            return (try await running.value, "aguardou")
        }
        let task = Task<Downloader.Response, Error> { [downloader] in
            guard case .fetched(let response) = try await downloader.fetch(url, headers: headers) else {
                throw URLError(.cannotParseResponse)
            }
            return response
        }
        state.register(task, for: key)
        defer { state.unregister(key) }
        let response = try await task.value
        if response.status == 200 {
            store(key, response, userAgent: userAgent, revalidates: freshness == .revalidate)
        }
        return (response, "rede")
    }

    private func store(_ key: String, _ response: Downloader.Response, userAgent: String?, revalidates: Bool) {
        disk.store(key, data: response.data, meta: DiskCache.Meta(
            etag: response.etag,
            lastModified: response.lastModified,
            contentType: response.contentType,
            size: response.data.count,
            validatedAt: Date(),
            lastUsed: Date(),
            userAgent: userAgent,
            revalidates: revalidates
        ))
    }

    private func startPrefetch(manifest: Data, userAgent: String?) {
        guard prefetchEnabled, state.beginPrefetch() else { return }
        let urls = Self.modules(in: manifest, upstream: upstream)
        guard !urls.isEmpty else {
            state.endPrefetch()
            return
        }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            defer { self.state.endPrefetch() }
            var headers: [String: String] = [:]
            if let userAgent { headers["User-Agent"] = userAgent }
            var progress = PrefetchProgress(done: urls.filter { self.disk.contains($0.absoluteString) }.count, total: urls.count)
            self.onPrefetchProgress?(progress)
            let started = Date()
            var bytes = 0
            for url in urls where !self.disk.contains(url.absoluteString) && self.state.missingStatus(url.absoluteString, within: Self.missingFor) == nil {
                guard self.prefetchEnabled else { return }
                while self.state.busy {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !self.disk.contains(url.absoluteString), self.state.download(for: url.absoluteString) == nil else { continue }
                guard case .fetched(let response)? = try? await self.downloader.fetch(url, headers: headers, parallel: 3),
                      response.status == 200 else { continue }
                self.store(url.absoluteString, response, userAgent: userAgent, revalidates: false)
                bytes += response.data.count
                progress.done += 1
                self.onPrefetchProgress?(progress)
            }
            if bytes > 0 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                log("[cache] módulos pré-carregados: \(progress.done) de \(progress.total), \(size) em \(Int(Date().timeIntervalSince(started))) s")
            }
        }
    }

    private static func modules(in manifest: Data, upstream: URL) -> [URL] {
        var data = manifest
        while data.first == 0x78, let inflated = Zlib.inflate(data) {
            data = inflated
        }
        guard let text = String(data: data, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"name="([^"]+)"\s+md5="([0-9a-f]+)"\s+size="([0-9]+)""#)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let modules: [(url: URL, rank: Int, size: Int)] = pattern.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let md5Range = Range(match.range(at: 2), in: text),
                  let sizeRange = Range(match.range(at: 3), in: text)
            else { return nil }
            let name = text[nameRange].replacingOccurrences(of: "\\", with: "/")
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let hashed = ext.isEmpty ? "\(name)_\(text[md5Range])" : "\(stem)_\(text[md5Range]).\(ext)"
            guard let url = URL(string: "cdn/" + hashed, relativeTo: upstream)?.absoluteURL else { return nil }
            let rank = priorityModules.firstIndex(of: (stem as NSString).lastPathComponent) ?? priorityModules.count
            return (url, rank, Int(text[sizeRange]) ?? .max)
        }
        return modules.sorted { ($0.rank, $0.size) < ($1.rank, $1.size) }.map(\.url)
    }

    private func audioData(userAgent: String?) async -> Data? {
        var headers: [String: String] = [:]
        if let userAgent { headers["user-agent"] = userAgent }
        guard let (response, _) = try? await fetch(upstream.appending(path: "cdn/audio.swf"), method: "GET", headers: headers, body: Data(), freshness: .revalidate),
              response.status == 200 else { return nil }
        return response.data
    }

    private func audioClasses(userAgent: String?) async -> [String] {
        if let known = state.soundClasses { return known }
        guard let audio = await audioData(userAgent: userAgent),
              let classes = try? SWF(audio).symbolNames.filter({ $0.range(of: "^Sound[0-9]+$", options: .regularExpression) != nil })
        else { return [] }
        state.soundClasses = classes
        return classes
    }

    private func withSounds(_ loading: Data, userAgent: String?) async -> Data {
        if let merged = state.mergedLoading(for: loading) { return merged }
        guard let audio = await audioData(userAgent: userAgent) else { return loading }
        do {
            let (merged, classes) = try SWF.embeddingSounds(from: audio, into: loading)
            state.storeMerged(merged, for: loading, classes: classes)
            log("[som] \(classes.count) efeitos sonoros embutidos no Loading.swf")
            return merged
        } catch {
            log("[som] não foi possível embutir os efeitos sonoros: \(error)")
            return loading
        }
    }

    private static func freshness(path: String, method: String) -> Freshness {
        guard method == "GET" || method == "HEAD" else { return .live }
        let name = (path as NSString).lastPathComponent.lowercased()
        guard staticExtensions.contains((name as NSString).pathExtension) else { return .live }
        if name.range(of: "_[0-9a-f]{8}\\.[a-z0-9]+$", options: .regularExpression) != nil { return .immutable }
        return .revalidate
    }

    private func record(_ method: String, _ status: Int, _ source: String, _ started: Date, _ bytes: Int, _ target: String) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        requestLog.write("\(method) \(status) \(source) \(ms) ms \(size) \(target)")
    }

    private func rewriteConfig(_ text: String, origin: URL, sounds: [String]) -> String {
        let base = upstream.absoluteString.trimmingSuffix("/")
        let local = origin.absoluteString.trimmingSuffix("/")
        var result = Self.rewrittenPrefixes.reduce(text) { $0.replacingOccurrences(of: base + $1, with: local + $1) }
        for element in Self.rewrittenBases {
            result = result.replacingOccurrences(
                of: "(<\(element)\\b[^>]*\\bvalue=[\"'])\(NSRegularExpression.escapedPattern(for: base))/",
                with: "$1\(local)/",
                options: .regularExpression
            )
        }
        if !sounds.isEmpty, !result.contains("<sounds"), let close = result.range(of: "</config>") {
            let entries = sounds.sorted().map { "      <sound id=\"\($0.dropFirst(5))\" cls=\"\($0)\" />" }
            let block = "  <sounds source=\"audio.swf\">\n" + entries.joined(separator: "\n") + "\n    </sounds>\n  "
            result.insert(contentsOf: block, at: close.lowerBound)
        }
        return result
    }
}

final class ProxyState: @unchecked Sendable {
    private let lock = NSLock()
    private var inflight = Set<String>()
    private var lastWarmUp: Date?
    private var loadingSource: Data?
    private var loadingMerged: Data?
    private var classes: [String]?
    private var active: [Int: (request: String, since: Date, reported: Int)] = [:]
    private var nextID = 0
    private var downloads: [String: Task<Downloader.Response, Error>] = [:]
    private var prefetching = false
    private var missing: [String: (status: Int, since: Date)] = [:]

    func missingStatus(_ key: String, within interval: TimeInterval) -> Int? {
        lock.withLock {
            guard let entry = missing[key], Date().timeIntervalSince(entry.since) < interval else { return nil }
            return entry.status
        }
    }

    func markMissing(_ key: String, status: Int) {
        lock.withLock { missing[key] = (status, Date()) }
    }

    var soundClasses: [String]? {
        get { lock.withLock { classes } }
        set { lock.withLock { classes = newValue } }
    }

    var busy: Bool {
        lock.withLock { !downloads.isEmpty }
    }

    func download(for key: String) -> Task<Downloader.Response, Error>? {
        lock.withLock { downloads[key] }
    }

    func register(_ task: Task<Downloader.Response, Error>, for key: String) {
        lock.withLock { downloads[key] = task }
    }

    func unregister(_ key: String) {
        _ = lock.withLock { downloads.removeValue(forKey: key) }
    }

    func beginPrefetch() -> Bool {
        lock.withLock {
            defer { prefetching = true }
            return !prefetching
        }
    }

    func endPrefetch() {
        lock.withLock { prefetching = false }
    }

    func begin(_ request: String) -> Int {
        lock.withLock {
            nextID += 1
            active[nextID] = (request, Date(), 0)
            return nextID
        }
    }

    func end(_ id: Int) {
        _ = lock.withLock { active.removeValue(forKey: id) }
    }

    func stalled(after limit: TimeInterval) -> [(String, Int)] {
        lock.withLock {
            var result: [(String, Int)] = []
            for (id, entry) in active {
                let seconds = Int(Date().timeIntervalSince(entry.since))
                guard seconds >= Int(limit), seconds / 15 > entry.reported else { continue }
                active[id]?.reported = seconds / 15
                result.append((entry.request, seconds))
            }
            return result
        }
    }

    func beginWarmUp(every interval: TimeInterval) -> Bool {
        lock.withLock {
            if let lastWarmUp, Date().timeIntervalSince(lastWarmUp) < interval { return false }
            lastWarmUp = Date()
            return true
        }
    }

    func claim(_ key: String) -> Bool {
        lock.withLock { inflight.insert(key).inserted }
    }

    func release(_ key: String) {
        _ = lock.withLock { inflight.remove(key) }
    }

    func mergedLoading(for source: Data) -> Data? {
        lock.withLock { loadingSource == source ? loadingMerged : nil }
    }

    func storeMerged(_ merged: Data, for source: Data, classes: [String]) {
        lock.withLock {
            loadingSource = source
            loadingMerged = merged
            self.classes = classes
        }
    }

    func reset() {
        lock.withLock {
            lastWarmUp = nil
            loadingSource = nil
            loadingMerged = nil
            classes = nil
        }
    }
}

enum Zlib {
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 6, data.first == 0x78 else { return nil }
        return try? (data.subdata(in: 2..<(data.count - 4)) as NSData).decompressed(using: .zlib) as Data
    }
}

final class SentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = false

    var value: Bool { lock.withLock { sent } }

    func mark() {
        lock.withLock { sent = true }
    }
}
