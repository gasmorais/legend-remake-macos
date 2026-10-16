import Foundation
import Network

final class EngineLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    var onMessage: (@MainActor ([String]) -> Void)?
    var onClose: (@MainActor () -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ fields: String...) {
        let line = fields
            .map { $0.replacingOccurrences(of: "[\\t\\r\\n]+", with: " ", options: .regularExpression) }
            .joined(separator: "\t") + "\n"
        connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    fileprivate func start(onFirstLine: @escaping ([String]) -> Void) {
        var greeted = false
        receiveLines { [weak self] fields in
            guard let self else { return }
            if !greeted {
                greeted = true
                onFirstLine(fields)
            } else if let handler = self.onMessage {
                Task { @MainActor in handler(fields) }
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if let handler = self?.onClose {
                    self?.onClose = nil
                    Task { @MainActor in handler() }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLines(_ handle: @escaping ([String]) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<newline]
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    if !text.isEmpty {
                        handle(text.components(separatedBy: "\t"))
                    }
                }
            }
            if complete || error != nil {
                self.connection.cancel()
            } else {
                self.receiveLines(handle)
            }
        }
    }
}

final class EngineServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.legendremake.ipc")
    private let lock = NSLock()
    private var waiting: [String: @MainActor (EngineLink) -> Void] = [:]
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        port = try await listener.startOnLoopback(queue: queue) { [weak self] connection in
            self?.accept(connection)
        }
        log("[ipc] escutando em 127.0.0.1:\(port)")
    }

    func expect(token: String, attach: @escaping @MainActor (EngineLink) -> Void) {
        lock.withLock { waiting[token] = attach }
    }

    func forget(token: String) {
        _ = lock.withLock { waiting.removeValue(forKey: token) }
    }

    private func accept(_ connection: NWConnection) {
        let link = EngineLink(connection: connection, queue: queue)
        link.start { [weak self] fields in
            guard let self, fields.count >= 2, fields[0] == "hello",
                  let attach = self.lock.withLock({ self.waiting.removeValue(forKey: fields[1]) })
            else {
                log("[ipc] conexão com token desconhecido, fechada")
                link.close()
                return
            }
            Task { @MainActor in attach(link) }
        }
    }
}

extension NWListener {
    func startOnLoopback(queue: DispatchQueue, accept: @escaping @Sendable (NWConnection) -> Void) async throws -> UInt16 {
        newConnectionHandler = accept
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: self?.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            start(queue: queue)
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
