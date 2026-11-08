import CryptoKit
import Foundation

enum ClientError: LocalizedError {
    case invalid(String)
    case http(Int, String)
    case signedOut

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .http(let code, let message): "Server returned \(code). \(message)"
        case .signedOut: "This session is no longer valid. Ask your administrator for a new QR code."
        }
    }
}

struct ServerConfig: Codable, Equatable, Sendable {
    let serverId: String
    let issuer: String
    let clientId: String
    let maxUploadBytes: Int64?
    let chunkSize: Int?
}

struct Connection: Codable, Equatable, Sendable {
    let baseURL: URL
    let config: ServerConfig
    let allowDevelopmentHTTP: Bool
    var persistentLogin: PersistentLoginConfiguration? = nil

    func hasSameIdentity(as other: Connection) -> Bool {
        baseURL == other.baseURL && config.serverId == other.config.serverId
            && config.issuer == other.config.issuer && config.clientId == other.config.clientId
    }
}

struct PersistentLoginConfiguration: Codable, Equatable, Sendable {
    let version: Int
    let refreshBinding: String
    let dpopAlgorithm: String
    let dpopKey: String
    let accessTokenType: String
    let refreshReuse: String
    let legacySessions: String

    var supportsDPoP: Bool {
        version == 1 && refreshBinding == "dpop" && dpopAlgorithm == "ES256"
            && dpopKey == "enrollment" && accessTokenType == "Bearer"
            && refreshReuse == "session-lifetime" && legacySessions == "unbound-no-rebind"
    }
}

enum URLPolicy {
    static func validate(_ raw: String, allowDevelopmentHTTP: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: raw), parts.scheme == "https",
            let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil, let url = parts.url
        else { throw ClientError.invalid("Sign-in requires a canonical HTTPS address.") }
        return url
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }
}

enum AccountIdentity {
    static func key(connection: Connection, subject: String) -> String {
        // Preserve the deployed vault's account keys across the app rebuild.
        Hashing.sha256(
            Data(
                [connection.baseURL.absoluteString, connection.config.serverId, connection.config.issuer, subject]
                    .joined(separator: "\n").utf8))
    }
}

enum Hashing {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
