import Foundation
import Network

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

        if headers["expect"]?.lowercased() == "100-continue" {
            await connection.sendAsync(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = await readChunkedBody(from: connection, buffer: &buffer) else { return nil }
            body = decoded
        } else {
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard await fill(&buffer, to: length, from: connection) else { return nil }
            body = Data(buffer.prefix(length))
            buffer.removeFirst(length)
        }

        let connectionHeader = headers["connection"]?.lowercased() ?? ""
        let keepAlive = start[2] == "HTTP/1.1" ? connectionHeader != "close" : connectionHeader == "keep-alive"
        return HTTPRequest(method: start[0].uppercased(), target: start[1], headers: headers, body: body, keepAlive: keepAlive)
    }

    private static func fill(_ buffer: inout Data, to length: Int, from connection: NWConnection) async -> Bool {
        while buffer.count < length {
            guard let chunk = await connection.receiveChunk() else { return false }
            buffer.append(chunk)
        }
        return true
    }

    private static func readChunkedBody(from connection: NWConnection, buffer: inout Data) async -> Data? {
        let crlf = Data("\r\n".utf8)
        var body = Data()
        while true {
            while buffer.range(of: crlf) == nil {
                guard buffer.count < 64 * 1024, let chunk = await connection.receiveChunk() else { return nil }
                buffer.append(chunk)
            }
            guard let lineEnd = buffer.range(of: crlf) else { return nil }
            let sizeLine = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<lineEnd.upperBound)
            guard let size = Int(sizeLine.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            guard await fill(&buffer, to: size + 2, from: connection) else { return nil }
            if size == 0 {
                if let trailerEnd = buffer.range(of: Data("\r\n\r\n".utf8)), buffer.prefix(2) != crlf {
                    buffer.removeSubrange(buffer.startIndex..<trailerEnd.upperBound)
                } else {
                    buffer.removeFirst(2)
                }
                return body
            }
            body.append(buffer.prefix(size))
            buffer.removeFirst(size + 2)
        }
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
