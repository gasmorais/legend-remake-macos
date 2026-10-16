import Foundation
import Network

final class CacheProxy: @unchecked Sendable {
    enum Freshness {
        case immutable
        case revalidate
        case live
    }

    let cache: URLCache
    private let upstream: URL
    private let session: URLSession
    private let liveSession: URLSession
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.legendremake.cache", attributes: .concurrent)
    private let index: CacheIndex
    private let requestLog = LogFile(Paths.shared.logs.appending(path: "requests.log"))
    private let state = ProxyState()
    private(set) var origin: URL?

    private static let forwardedRequestHeaders: Set<String> = [
        "user-agent", "referer", "accept", "accept-language", "content-type", "cookie", "x-flash-version", "x-requested-with",
    ]
    private static let forwardedResponseHeaders = ["Content-Type", "Set-Cookie", "Content-Disposition"]
    private static let rewrittenPrefixes = ["/cdn/", "/xml/"]
    private static let rewrittenBases = ["REQUEST_PATH", "FOWARDSITE"]
    private static let staticExtensions: Set<String> = [
        "swf", "png", "jpg", "jpeg", "gif", "mp3", "wav", "xml", "dat", "txt", "json", "zip", "bin", "atf", "css", "js",
    ]
    private static let bustingParameters: Set<String> = ["rnd", "random", "nocache", "_"]
    private static let timestampParameters: Set<String> = ["v", "t", "time"]
    private static let freshFor: TimeInterval = 30 * 60

    init(upstream: URL, directory: URL) throws {
        self.upstream = upstream
        cache = URLCache(memoryCapacity: 128 << 20, diskCapacity: 4 << 30, directory: directory)
        index = CacheIndex(file: Paths.shared.support.appending(path: "cache-index.json"))

        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)

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

    func start() async throws -> URL {
        let port = try await listener.startOnLoopback(queue: queue) { [weak self] connection in
            self?.serve(connection)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        origin = url
        log("[cache] proxy em \(url.absoluteString), \(ByteCountFormatter.string(fromByteCount: Int64(cache.currentDiskUsage), countStyle: .file)) em disco")
        prepare()
        return url
    }

    func prepare() {
        guard state.beginWarmUp(every: 10 * 60) else { return }
        Task.detached(priority: .utility) { [weak self] in await self?.warmUp() }
    }

    func clear() {
        cache.removeAllCachedResponses()
        index.reset()
        state.reset()
    }

    private func warmUp() async {
        let entries = index.recentEntries(within: 14 * 24 * 3600)
        guard !entries.isEmpty else { return }
        let started = Date()
        var refreshed = 0
        await withTaskGroup(of: Bool.self) { group in
            var pending = entries.makeIterator()
            func next() -> Bool {
                guard let entry = pending.next(), let url = URL(string: entry.key) else { return false }
                group.addTask { [weak self] in
                    var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
                    request.setValue(entry.userAgent, forHTTPHeaderField: "User-Agent")
                    return await self?.revalidate(request, key: entry.key) ?? false
                }
                return true
            }
            for _ in 0..<6 where next() {}
            for await ok in group {
                if ok { refreshed += 1 }
                _ = next()
            }
        }
        log("[cache] \(refreshed) de \(entries.count) arquivos revalidados em \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    private func revalidate(_ request: URLRequest, key: String) async -> Bool {
        guard state.claim(key) else { return false }
        defer { state.release(key) }
        var request = request
        request.cachePolicy = .useProtocolCachePolicy
        guard let (_, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        index.markValidated(key)
        return true
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            var buffer = Data()
            while let request = await HTTPRequest.read(from: connection, buffer: &buffer) {
                let response = await respond(to: request)
                await connection.sendAsync(response.serialized(headOnly: request.method == "HEAD"))
                if !request.keepAlive { break }
            }
            connection.cancel()
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

        let freshness = Self.freshness(path: path, method: request.method)
        let key = url.absoluteString
        let userAgent = request.headers["user-agent"]
        var outgoing = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60)
        outgoing.httpMethod = request.method == "HEAD" ? "GET" : request.method
        for (name, value) in request.headers where Self.forwardedRequestHeaders.contains(name) {
            outgoing.setValue(value, forHTTPHeaderField: name)
        }
        if !request.body.isEmpty {
            outgoing.httpBody = request.body
        }

        let started = Date()
        do {
            var (data, http, source) = try await fetch(outgoing, freshness: freshness, key: key, userAgent: userAgent)
            if http.statusCode == 200 {
                if path == "/client/config.xml", let origin, let text = String(data: data, encoding: .utf8) {
                    let sounds = await audioClasses(userAgent: userAgent)
                    data = Data(rewriteConfig(text, origin: origin, sounds: sounds).utf8)
                } else if path == "/client/Loading.swf" {
                    data = await withSounds(data, userAgent: userAgent)
                }
            }
            var headers: [(String, String)] = []
            for name in Self.forwardedResponseHeaders {
                if let value = http.value(forHTTPHeaderField: name) { headers.append((name, value)) }
            }
            record(request.method, http.statusCode, source, started, data.count, request.target)
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch {
            record(request.method, 502, "erro", started, 0, "\(request.target) (\(error.localizedDescription))")
            return HTTPResponse(status: 502)
        }
    }

    private func fetch(_ request: URLRequest, freshness: Freshness, key: String, userAgent: String?) async throws -> (Data, HTTPURLResponse, String) {
        if freshness == .live {
            let metrics = FetchMetrics()
            let (data, response) = try await liveSession.data(for: request, delegate: metrics)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http, metrics.source)
        }

        let stored = await cachedCopy(of: request)
        if let stored {
            if freshness == .revalidate && !index.isFresh(key, within: Self.freshFor) {
                index.markValidated(key, userAgent: userAgent, remember: true)
                Task.detached(priority: .utility) { [weak self] in _ = await self?.revalidate(request, key: key) }
                return (stored.0, stored.1, "disco+revalida")
            }
            return (stored.0, stored.1, "disco")
        }

        let metrics = FetchMetrics()
        do {
            let (data, response) = try await session.data(for: request, delegate: metrics)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if http.statusCode == 200 {
                index.markValidated(key, userAgent: userAgent, remember: freshness == .revalidate)
            }
            return (data, http, metrics.source)
        } catch {
            guard let stale = await cachedCopy(of: request, allowingAnyStatus: true) else { throw error }
            return (stale.0, stale.1, "disco (servidor falhou)")
        }
    }

    private func cachedCopy(of request: URLRequest, allowingAnyStatus: Bool = false) async -> (Data, HTTPURLResponse)? {
        var local = request
        local.cachePolicy = .returnCacheDataDontLoad
        guard let (data, response) = try? await session.data(for: local),
              let http = response as? HTTPURLResponse,
              allowingAnyStatus || http.statusCode == 200
        else { return nil }
        return (data, http)
    }

    private func audioData(userAgent: String?) async -> Data? {
        var request = URLRequest(url: upstream.appending(path: "cdn/audio.swf"), timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, http, _) = try? await fetch(request, freshness: .revalidate, key: request.url!.absoluteString, userAgent: userAgent),
              http.statusCode == 200 else { return nil }
        return data
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
            let block = "    <sounds source=\"audio.swf\">\n" + entries.joined(separator: "\n") + "\n    </sounds>\n  "
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

    var soundClasses: [String]? {
        get { lock.withLock { classes } }
        set { lock.withLock { classes = newValue } }
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

final class FetchMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private(set) var source = "rede"

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics
        if transactions.contains(where: { ($0.response as? HTTPURLResponse)?.statusCode == 304 }) {
            source = "304"
        } else if transactions.last?.resourceFetchType == .localCache {
            source = "cache"
        }
    }
}

final class CacheIndex: @unchecked Sendable {
    struct Entry: Codable {
        var lastSeen: Date
        var userAgent: String
    }

    private let file: URL
    private let lock = NSLock()
    private var entries: [String: Entry]
    private var validated: [String: Date] = [:]
    private var saveScheduled = false

    init(file: URL) {
        self.file = file
        entries = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.iso.decode([String: Entry].self, from: $0) } ?? [:]
    }

    func isFresh(_ key: String, within interval: TimeInterval) -> Bool {
        lock.withLock { validated[key].map { Date().timeIntervalSince($0) < interval } ?? false }
    }

    func markValidated(_ key: String, userAgent: String? = nil, remember: Bool = false) {
        let schedule: Bool = lock.withLock {
            validated[key] = Date()
            guard remember, let userAgent else { return false }
            entries[key] = Entry(lastSeen: Date(), userAgent: userAgent)
            defer { saveScheduled = true }
            return !saveScheduled
        }
        if schedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in self?.save() }
        }
    }

    func recentEntries(within interval: TimeInterval) -> [(key: String, userAgent: String)] {
        let limit = Date().addingTimeInterval(-interval)
        return lock.withLock {
            entries.filter { $0.value.lastSeen > limit }.map { (key: $0.key, userAgent: $0.value.userAgent) }
        }
    }

    func reset() {
        lock.withLock {
            entries.removeAll()
            validated.removeAll()
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        let data: Data? = lock.withLock {
            saveScheduled = false
            return try? JSONEncoder.iso.encode(entries)
        }
        try? data?.write(to: file, options: .atomic)
    }
}

struct HTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    let keepAlive: Bool

    static func read(from connection: NWConnection, buffer: inout Data) async -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        var headEnd = buffer.range(of: separator)
        while headEnd == nil {
            guard buffer.count < 64 * 1024, let chunk = await connection.receiveChunk() else { return nil }
            buffer.append(chunk)
            headEnd = buffer.range(of: separator)
        }
        guard let headEnd else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<headEnd.upperBound)

        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard start.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "") ?? 0
        while buffer.count < length {
            guard let chunk = await connection.receiveChunk() else { return nil }
            buffer.append(chunk)
        }
        let body = Data(buffer.prefix(length))
        buffer.removeFirst(length)

        let connectionHeader = headers["connection"]?.lowercased() ?? ""
        let keepAlive = start[2] == "HTTP/1.1" ? connectionHeader != "close" : connectionHeader == "keep-alive"
        return HTTPRequest(method: start[0].uppercased(), target: start[1], headers: headers, body: body, keepAlive: keepAlive)
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    func serialized(headOnly: Bool) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
        var data = Data(head.utf8)
        if !headOnly { data.append(body) }
        return data
    }
}

extension NWConnection {
    func receiveChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: complete || error != nil ? nil : Data())
                }
            }
        }
    }

    func sendAsync(_ data: Data) async {
        await withCheckedContinuation { continuation in
            send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
