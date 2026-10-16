import Foundation

enum LauncherError: LocalizedError, Equatable {
    case offline
    case rejected(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .offline: "Sem conexão com o servidor. Verifique sua internet e tente novamente."
        case .rejected(let message), .server(let message): message
        }
    }
}

struct ServerStatus: Equatable {
    let online: Int
    let boot: String
}

struct Login {
    let username: String
    let ticket: String
}

struct Profile {
    let username: String
    let characterName: String?
    let level: Int?
    let playSeconds: Int?
}

final class LauncherAPI: Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    func login(username: String, password: String) async throws -> Login {
        try await credentials("login", username: username, password: password)
    }

    func register(username: String, password: String) async throws -> Login {
        try await credentials("register", username: username, password: password)
    }

    func resume(username: String, ticket: String) async throws {
        _ = try await post("resume", ["username": username, "ticket": ticket])
    }

    func profiles(_ accounts: [(username: String, ticket: String)]) async throws -> [Profile] {
        var request = URLRequest(url: Server.api.appending(path: "profiles"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "accounts": accounts.map { ["username": $0.username, "ticket": $0.ticket] },
        ])
        let (data, response) = try await perform(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["accounts"] as? [[String: Any]]
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LauncherError.server("Resposta inesperada do servidor (\(status)): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return items.compactMap { item in
            guard item["ok"] as? Bool != false, let username = item["username"] as? String else { return nil }
            let character = item["character"] as? [String: Any]
            let name = (character?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(
                username: username,
                characterName: name,
                level: (character?["level"] as? NSNumber)?.intValue,
                playSeconds: (character?["playSeconds"] as? NSNumber)?.intValue
            )
        }
    }

    func status() async throws -> ServerStatus {
        let (data, _) = try await perform(URLRequest(url: Server.api.appending(path: "status")))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["ok"] as? Bool == true else {
            throw LauncherError.server("Resposta inválida do servidor.")
        }
        return ServerStatus(online: (json["online"] as? NSNumber)?.intValue ?? 0, boot: json["boot"] as? String ?? "")
    }

    private func credentials(_ action: String, username: String, password: String) async throws -> Login {
        let json = try await post(action, ["username": username, "password": password])
        guard let ticket = json["ticket"] as? String, !ticket.isEmpty else {
            throw LauncherError.server("Resposta inválida do servidor.")
        }
        return Login(username: json["username"] as? String ?? username, ticket: ticket)
    }

    private func post(_ action: String, _ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: Server.api.appending(path: action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LauncherError.server(status >= 500 ? "O servidor respondeu com erro (\(status))." : "Resposta inválida do servidor.")
        }
        if json["ok"] as? Bool == true {
            return json
        }
        let message = json["error"] as? String ?? "O servidor recusou o pedido."
        throw status >= 500 ? LauncherError.server(message) : LauncherError.rejected(message)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await session.data(for: request)
            } catch let error as URLError {
                switch error.code {
                case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .secureConnectionFailed:
                    throw LauncherError.server("A conexão segura com o servidor falhou. Verifique a data e a hora do Mac.")
                case .cancelled:
                    throw CancellationError()
                case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost:
                    guard attempt < 2 else { throw LauncherError.offline }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(800 * attempt))
                default:
                    throw LauncherError.offline
                }
            }
        }
    }
}
