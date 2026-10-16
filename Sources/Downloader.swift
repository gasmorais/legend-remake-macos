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

    private let session: URLSession
    private let chunkSize = 256 * 1024
    private let stallTimeout: TimeInterval = 4
    private let attempts = 8

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
    }

    func fetch(_ url: URL, headers: [String: String], validating meta: DiskCache.Meta? = nil, parallel: Int = 4) async throws -> Outcome {
        var conditional = headers
        if let etag = meta?.etag { conditional["If-None-Match"] = etag }
        if let lastModified = meta?.lastModified { conditional["If-Modified-Since"] = lastModified }

        let first = try await retrying { try await self.part(url, headers: conditional, from: 0, to: self.chunkSize, timeout: $0) }
        if first.status == 304 { return .notModified }
        guard first.status == 206, let total = first.total else { return .fetched(first.response) }

        var parts: [Int: Data] = [0: first.response.data]
        let offsets = Array(stride(from: first.response.data.count, to: total, by: chunkSize))
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var pending = offsets.makeIterator()
            func next() -> Bool {
                guard let offset = pending.next() else { return false }
                let end = min(offset + chunkSize, total)
                group.addTask {
                    let piece = try await self.retrying { try await self.part(url, headers: headers, from: offset, to: end, timeout: $0) }
                    guard piece.status == 206, piece.response.data.count == end - offset else { throw URLError(.cannotParseResponse) }
                    return (offset, piece.response.data)
                }
                return true
            }
            for _ in 0..<parallel where next() {}
            for try await (offset, data) in group {
                parts[offset] = data
                _ = next()
            }
        }

        var data = Data(capacity: total)
        for offset in parts.keys.sorted() {
            data.append(parts[offset]!)
        }
        guard data.count == total else { throw URLError(.cannotParseResponse) }
        var response = first.response
        response.status = 200
        response.data = data
        return .fetched(response)
    }

    private struct Part {
        var status: Int
        var total: Int?
        var response: Response
    }

    private func part(_ url: URL, headers: [String: String], from start: Int, to end: Int, timeout: TimeInterval) async throws -> Part {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 206, start == 0, data.count != min(end, Self.total(http) ?? end) {
            throw URLError(.networkConnectionLost)
        }
        return Part(
            status: http.statusCode,
            total: Self.total(http),
            response: Response(
                status: http.statusCode,
                data: data,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                setCookie: http.value(forHTTPHeaderField: "Set-Cookie")
            )
        )
    }

    private static func total(_ http: HTTPURLResponse) -> Int? {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") else { return nil }
        return Int(range[range.index(after: slash)...])
    }

    private func retrying<T>(_ operation: (TimeInterval) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation(stallTimeout + Double(attempt) * 2)
            } catch let error as URLError where attempt + 1 < attempts && error.code != .cancelled {
                attempt += 1
                try await Task.sleep(for: .milliseconds(150 * attempt))
            }
        }
    }
}
