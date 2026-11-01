import CryptoKit
import Foundation
import Security
import UIKit

// Wire DTOs retain the OIDC field names.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct OIDCDiscovery: Decodable, Sendable {
    let issuer: String
    let token_endpoint: URL
    let jwks_uri: URL
}
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TokenResponse: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double
    let token_type: String
}
struct Credentials: Codable, Sendable {
    let connection: Connection
    let subject: String
    let nonce: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}
enum Keychain {
    private static let service = "app.nephos.ios.session"
    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "current",
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw ClientError.invalid("Unable to securely save the session.")
            }
        } else if status != errSecSuccess {
            throw ClientError.invalid("Keychain is unavailable.")
        }
    }
    static func load() throws -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "current",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClientError.invalid("Unlock the device to access your saved session.")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    static func remove() throws {
        let status = SecItemDelete(
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClientError.invalid("Unable to remove the Keychain session.")
        }
    }
}

@MainActor
final class AuthSession: AccessTokenProviding {
    private(set) var credentials: Credentials?
    private var refreshTask: Task<String, Error>?
    private var generation = UUID()

    var subject: String? { credentials?.subject }
    init(credentials: Credentials? = nil) { self.credentials = credentials }

    static func isCancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func discovery(_ connection: Connection) async throws -> OIDCDiscovery {
        let issuer = try URLPolicy.validate(connection.config.issuer, allowDevelopmentHTTP: developmentHTTP(connection))
        let doc = try await HTTP.json(
            OIDCDiscovery.self, HTTP.request(issuer.appendingPathComponent(".well-known/openid-configuration")))
        guard doc.issuer == connection.config.issuer else {
            throw ClientError.invalid("OIDC issuer mismatch.")
        }
        for endpoint in [doc.token_endpoint, doc.jwks_uri] {
            _ = try URLPolicy.validate(endpoint.absoluteString, allowDevelopmentHTTP: developmentHTTP(connection))
            guard URLPolicy.sameOrigin(issuer, endpoint) else {
                throw ClientError.invalid("OIDC endpoint is outside the approved issuer origin.")
            }
        }
        return doc
    }
    static func developmentHTTP(_ connection: Connection) -> Bool {
        #if DEBUG
            return connection.allowDevelopmentHTTP
        #else
            return false
        #endif
    }
    static func requestPin(connection: Connection, email: String) async throws -> LoginPinReceipt {
        _ = try await discovery(connection)
        return try await LoginPinClient.request(connection: connection, email: email)
    }
    func login(connection: Connection, email: String, pin: String) async throws {
        let expectedGeneration = generation
        let discovery = try await Self.discovery(connection)
        let nonce = try Self.random()
        let tokens = try await Self.exchange(
            discovery.token_endpoint,
            [
                "grant_type": "urn:nephos:params:oauth:grant-type:login-pin",
                "client_id": connection.config.clientId,
                "username": email.trimmingCharacters(in: .whitespacesAndNewlines),
                "pin": pin,
                "nonce": nonce,
                "scope": "openid profile offline_access",
                "device_id": UUID().uuidString,
                "device_name": String(UIDevice.current.name.prefix(100)),
            ])
        guard let idToken = tokens.id_token else {
            throw ClientError.invalid("OIDC response omitted the identity token.")
        }
        guard let refreshToken = tokens.refresh_token, !refreshToken.isEmpty else {
            throw ClientError.invalid("OIDC response omitted the persistent refresh token.")
        }
        let subject = try await JWTVerifier.verify(
            idToken, discovery: discovery, clientID: connection.config.clientId, purpose: .authorization(nonce: nonce))
        guard generation == expectedGeneration else { throw CancellationError() }
        let saved = Credentials(
            connection: connection, subject: subject, nonce: nonce, accessToken: tokens.access_token,
            refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(tokens.expires_in))
        try Keychain.save(saved)
        credentials = saved
    }
    func accessToken() async throws -> String {
        guard let saved = credentials else { throw ClientError.signedOut }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let refreshTask { return try await refreshTask.value }
        let expectedGeneration = generation
        let task = Task { @MainActor in
            guard let refresh = saved.refreshToken else { throw ClientError.signedOut }
            let discovery = try await Self.discovery(saved.connection)
            let tokens: TokenResponse
            do {
                tokens = try await Self.exchange(
                    discovery.token_endpoint,
                    [
                        "grant_type": "refresh_token", "refresh_token": refresh,
                        "client_id": saved.connection.config.clientId,
                    ])
            } catch ClientError.http(400, _) { throw ClientError.signedOut }
            if let idToken = tokens.id_token {
                _ = try await JWTVerifier.verify(
                    idToken, discovery: discovery, clientID: saved.connection.config.clientId,
                    purpose: .refresh(nonce: saved.nonce, subject: saved.subject))
            }
            guard self.generation == expectedGeneration else { throw CancellationError() }
            var updated = saved
            updated.accessToken = tokens.access_token
            updated.refreshToken = tokens.refresh_token ?? saved.refreshToken
            updated.expiresAt = Date().addingTimeInterval(tokens.expires_in)
            try Keychain.save(updated)
            self.credentials = updated
            return updated.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
    func signOut() throws {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        try Keychain.remove()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClientError.invalid("Secure random generator failed.")
        }
        return Hashing.base64URL(Data(bytes))
    }
    private static func exchange(_ endpoint: URL, _ fields: [String: String]) async throws -> TokenResponse {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        let tokens = try await HTTP.json(
            TokenResponse.self,
            HTTP.request(
                endpoint, method: "POST", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded"))
        guard tokens.token_type.lowercased() == "bearer", tokens.expires_in > 0, !tokens.access_token.isEmpty else {
            throw ClientError.invalid("Unsupported token response.")
        }
        return tokens
    }
}

enum JWTVerifier {
    private struct Keys: Decodable, Sendable { let keys: [JWK] }
    private struct JWK: Decodable, Sendable {
        let kty: String
        let kid: String?
        let use: String?
        let alg: String?
        let n: String?
        let e: String?
    }
    private static func decode(_ value: String) throws -> Data {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        else {
            throw ClientError.invalid("Malformed identity token.")
        }
        return data
    }
    static func verify(
        _ token: String, discovery: OIDCDiscovery, clientID: String, purpose: IdentityTokenClaims.Purpose
    ) async throws
        -> String
    {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3, token.count < 128 * 1024,
            let header = try JSONSerialization.jsonObject(with: decode(segments[0])) as? [String: Any],
            header["alg"] as? String == "RS256", header["crit"] == nil,
            let kid = header["kid"] as? String
        else { throw ClientError.invalid("Only signed RS256 identity tokens are supported.") }
        let keys = try await HTTP.json(Keys.self, HTTP.request(discovery.jwks_uri))
        let matching = keys.keys.filter {
            $0.kid == kid && $0.kty == "RSA" && ($0.use == nil || $0.use == "sig")
                && ($0.alg == nil || $0.alg == "RS256")
        }
        guard matching.count == 1, let n = matching[0].n, let e = matching[0].e else {
            throw ClientError.invalid("OIDC signing key is missing or ambiguous.")
        }
        let modulus = try decode(n)
        let exponent = try decode(e)
        guard modulus.count >= 256, modulus.count <= 1024 else {
            throw ClientError.invalid("Unsupported RSA signing key size.")
        }
        let der = sequence(integer(modulus) + integer(exponent))
        guard
            let key = SecKeyCreateWithData(
                der as CFData,
                [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
                ] as CFDictionary, nil),
            SecKeyVerifySignature(
                key, .rsaSignatureMessagePKCS1v15SHA256,
                Data("\(segments[0]).\(segments[1])".utf8) as CFData, try decode(segments[2]) as CFData, nil),
            let claims = try JSONSerialization.jsonObject(with: decode(segments[1])) as? [String: Any]
        else { throw ClientError.invalid("Identity token signature is invalid.") }
        return try IdentityTokenClaims.validate(claims, issuer: discovery.issuer, clientID: clientID, purpose: purpose)
    }
    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes = [UInt8]()
        while value > 0 {
            bytes.insert(UInt8(value & 255), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func integer(_ bytes: Data) -> Data {
        let payload = bytes.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + bytes : bytes
        return Data([0x02]) + length(payload.count) + payload
    }
    private static func sequence(_ bytes: Data) -> Data { Data([0x30]) + length(bytes.count) + bytes }
}
