import Foundation

final class Downloader: Sendable {
    struct Response {
        var status: Int
        var data: Data
        var etag: String?
        var lastModified: String?
        var contentType: String?
        var setCookie: String?
    }

    enum Outcome {
        case notModified
        case fetched(Response)
    }

    typealias StartHandler = @Sendable (Int, Response) async -> Void
    typealias DataHandler = @Sendable (Data) async -> Void

    private let session: URLSession
    private let chunkSize = 256 * 1024
    private let headerTimeout: TimeInterval = 6
    private let chunkStall: TimeInterval = 4
    private let fullBodyStall: TimeInterval = 45
    private let attempts = 8

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 1800
        session = URLSession(configuration: config)
    }

    func fetch(_ url: URL, headers: [String: String], validating meta: DiskCache.Meta? = nil, parallel: Int = 4) async throws -> Outcome {
        try await stream(url, headers: headers, validating: meta, parallel: parallel, onStart: nil, onData: nil)
    }

    func stream(
        _ url: URL,
        headers: [String: String],
        validating meta: DiskCache.Meta? = nil,
        parallel: Int = 4,
        onStart: StartHandler?,
        onData: DataHandler?
    ) async throws -> Outcome {
        var conditional = headers
        if let etag = meta?.etag { conditional["If-None-Match"] = etag }
        if let lastModified = meta?.lastModified { conditional["If-Modified-Since"] = lastModified }

        let first = try await retrying { slack in
            try await self.transfer(url, headers: conditional, range: 0..<self.chunkSize, slack: slack, onStart: onStart, onData: onData)
        }
        if first.response.status == 304 { return .notModified }
        guard first.response.status == 206, let total = first.total else { return .fetched(first.response) }

        var head = first.response
        head.status = 200
        await onStart?(total, head)
        await onData?(first.response.data)

        var data = Data(capacity: total)
        data.append(first.response.data)
        var pending: [Int: Data] = [:]
        let offsets = Array(stride(from: first.response.data.count, to: total, by: chunkSize))
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var queue = offsets.makeIterator()
            func next() -> Bool {
                guard let offset = queue.next() else { return false }
                let end = min(offset + chunkSize, total)
                group.addTask {
                    let piece = try await self.retrying { slack in
                        try await self.transfer(url, headers: headers, range: offset..<end, slack: slack, onStart: nil, onData: nil)
                    }
                    guard piece.response.status == 206, piece.response.data.count == end - offset else { throw URLError(.cannotParseResponse) }
                    return (offset, piece.response.data)
                }
                return true
            }
            for _ in 0..<parallel where next() {}
            for try await (offset, chunk) in group {
                pending[offset] = chunk
                while let ready = pending.removeValue(forKey: data.count) {
                    data.append(ready)
                    await onData?(ready)
                }
                _ = next()
            }
        }

        guard data.count == total else { throw URLError(.cannotParseResponse) }
        head.data = data
        return .fetched(head)
    }

    struct Probe {
        var status: Int
        var length: Int?
        var etag: String?
        var lastModified: String?
    }

    func probe(_ url: URL, headers: [String: String]) async throws -> Probe {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let session = session
        let prepared = request
        let (bytes, response) = try await Watchdog().run(limit: headerTimeout * 3) {
            try await session.bytes(for: prepared)
        }
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let length = http.statusCode == 206 ? Self.total(http) : (http.expectedContentLength > 0 ? Int(http.expectedContentLength) : nil)
        return Probe(status: http.statusCode, length: length, etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    private struct Transfer {
        var total: Int?
        var response: Response
    }

    private func transfer(
        _ url: URL,
        headers: [String: String],
        range: Range<Int>,
        slack: TimeInterval,
        onStart: StartHandler?,
        onData: DataHandler?
    ) async throws -> Transfer {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        let watchdog = Watchdog()
        let session = session
        let prepared = request
        let (bytes, response) = try await watchdog.run(limit: headerTimeout + slack) {
            try await session.bytes(for: prepared)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        var result = Response(
            status: http.statusCode,
            data: Data(),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            setCookie: http.value(forHTTPHeaderField: "Set-Cookie")
        )
        let total = Self.total(http)
        let partial = http.statusCode == 206
        let expected = partial ? range.count : Int(http.expectedContentLength)
        let streaming = !partial && http.statusCode == 200 && expected > 0 && onStart != nil
        if streaming { await onStart?(expected, result) }

        let body = try await watchdog.run(limit: partial ? chunkStall + slack : fullBodyStall, cancelling: bytes.task) {
            var body = Data(capacity: max(0, min(expected, 64 << 20)))
            var batch = [UInt8]()
            batch.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                batch.append(byte)
                if batch.count & 1023 == 0 { watchdog.touch() }
                if batch.count == 64 * 1024 {
                    body.append(contentsOf: batch)
                    if streaming { await onData?(Data(batch)) }
                    batch.removeAll(keepingCapacity: true)
                }
            }
            body.append(contentsOf: batch)
            if streaming, !batch.isEmpty { await onData?(Data(batch)) }
            return body
        }

        if partial, let total, body.count != min(range.count, total - range.lowerBound) {
            throw URLError(.networkConnectionLost)
        }
        if !partial, expected > 0, body.count != expected {
            throw streaming ? URLError(.cannotParseResponse) : URLError(.networkConnectionLost)
        }
        result.data = body
        return Transfer(total: total, response: result)
    }

    private static func total(_ http: HTTPURLResponse) -> Int? {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") else { return nil }
        return Int(range[range.index(after: slash)...])
    }

    private func retrying<T>(_ operation: (TimeInterval) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation(Double(attempt) * 2)
            } catch let error as URLError where attempt + 1 < attempts && error.code != .cancelled && error.code != .cannotParseResponse {
                attempt += 1
                try await Task.sleep(for: .milliseconds(150 * attempt))
            }
        }
    }
}

final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.withLock { last = Date() }
    }

    func run<T>(limit: TimeInterval, cancelling task: URLSessionTask? = nil, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        touch()
        let box = ResultBox<T>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { box.set(try await operation()) }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    if Date().timeIntervalSince(self.lock.withLock({ self.last })) > limit {
                        task?.cancel()
                        throw URLError(.timedOut)
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
        guard let value = box.value else { throw URLError(.timedOut) }
        return value
    }
}

final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? { lock.withLock { stored } }

    func set(_ value: T) {
        lock.withLock { stored = value }
    }
}
