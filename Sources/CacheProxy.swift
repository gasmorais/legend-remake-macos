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
    private let legacy: URLSession
    private let legacyCache: URLCache
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

    init(upstream: URL, directory: URL, legacyDirectory: URL) throws {
        self.upstream = upstream
        disk = DiskCache(directory: directory)

        legacyCache = URLCache(memoryCapacity: 0, diskCapacity: 4 << 30, directory: legacyDirectory)
        let legacyConfig = URLSessionConfiguration.default
        legacyConfig.urlCache = legacyCache
        legacyConfig.requestCachePolicy = .returnCacheDataDontLoad
        legacy = URLSession(configuration: legacyConfig)

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

    var diskUsage: Int64 { disk.usage + Int64(legacyCache.currentDiskUsage) }

    func start() async throws -> URL {
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
        legacyCache.removeAllCachedResponses()
        state.reset()
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
            for _ in 0..<6 where next() {}
            for await ok in group {
                if ok { refreshed += 1 }
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
                let response = await respond(to: request)
                state.end(id)
                await connection.sendAsync(response.serialized(headOnly: request.method == "HEAD"))
                if !request.keepAlive { break }
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

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard var components = URLComponents(string: request.target),
              let path = components.path.removingPercentEncoding
        else { return HTTPResponse(status: 400) }

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
        guard let url = components.url else { return HTTPResponse(status: 400) }

        var headers: [String: String] = [:]
        for (name, value) in request.headers where Self.forwardedRequestHeaders.contains(name) {
            headers[name] = value
        }

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
            var outgoing: [(String, String)] = []
            if let type = response.contentType { outgoing.append(("Content-Type", type)) }
            if let cookie = response.setCookie { outgoing.append(("Set-Cookie", cookie)) }
            record(request.method, response.status, source, started, response.data.count, request.target)
            return HTTPResponse(status: response.status, headers: outgoing, body: response.data)
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
        var cached = disk.lookup(key)
        if cached == nil {
            cached = await migrateLegacy(url, revalidates: freshness == .revalidate)
        }
        if let cached {
            let response = Downloader.Response(status: 200, data: cached.data, etag: cached.meta.etag, lastModified: cached.meta.lastModified, contentType: cached.meta.contentType)
            if freshness == .revalidate && !disk.isFresh(key, within: Self.freshFor) {
                disk.markValidated(key, userAgent: userAgent)
                Task.detached(priority: .utility) { [weak self] in await self?.revalidate(key, userAgent: userAgent) }
                return (response, "disco+confere")
            }
            return (response, "disco")
        }

        state.downloading(+1)
        defer { state.downloading(-1) }
        guard case .fetched(let response) = try await downloader.fetch(url, headers: headers) else {
            throw URLError(.cannotParseResponse)
        }
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

    private func migrateLegacy(_ url: URL, revalidates: Bool) async -> (data: Data, meta: DiskCache.Meta)? {
        guard let (data, response) = try? await legacy.data(for: URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad)),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        let meta = DiskCache.Meta(
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            size: data.count,
            validatedAt: .distantPast,
            lastUsed: Date(),
            userAgent: nil,
            revalidates: revalidates
        )
        disk.store(url.absoluteString, data: data, meta: meta)
        return (data, meta)
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
            for url in urls where !self.disk.contains(url.absoluteString) {
                guard self.prefetchEnabled else { return }
                while self.state.busy {
                    try? await Task.sleep(for: .milliseconds(500))
                }
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
              let pattern = try? NSRegularExpression(pattern: #"name="([^"]+)"\s+md5="([0-9a-f]+)""#)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text), let md5Range = Range(match.range(at: 2), in: text) else { return nil }
            let name = text[nameRange].replacingOccurrences(of: "\\", with: "/")
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            let hashed = ext.isEmpty ? "\(name)_\(text[md5Range])" : "\(stem)_\(text[md5Range]).\(ext)"
            return URL(string: "cdn/" + hashed, relativeTo: upstream)?.absoluteURL
        }
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
    private var downloads = 0
    private var prefetching = false

    var soundClasses: [String]? {
        get { lock.withLock { classes } }
        set { lock.withLock { classes = newValue } }
    }

    var busy: Bool {
        lock.withLock { downloads > 0 }
    }

    func downloading(_ delta: Int) {
        lock.withLock { downloads += delta }
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
