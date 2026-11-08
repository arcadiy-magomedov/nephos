import CryptoKit
import Foundation
import Security

// Wire DTOs retain the OIDC field names.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct OIDCDiscovery: Decodable, Sendable {
    let issuer: String
    let token_endpoint: URL
    let jwks_uri: URL
    let revocation_endpoint: URL?
}
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TokenResponse: Decodable, Sendable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double
    let token_type: String
}
enum Keychain {
    private static let service = "app.nephos.ios.session"
    private static let lock = NSRecursiveLock()
    private static func query(account: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { result[kSecAttrAccount as String] = account }
        #if os(macOS)
            result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }
    private static func write(_ data: Data, account: String) throws {
        let query = query(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem:
            guard SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
                throw ClientError.invalid("Unable to securely update the session. Unlock the device and retry.")
            }
        case errSecInteractionNotAllowed:
            throw ClientError.invalid("Unlock the device to save your session.")
        default:
            throw ClientError.invalid("Unable to securely save the session.")
        }
    }
    private static func read(account: String) throws -> Data? {
        let query = query(account: account).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClientError.invalid("Unlock the device to access your saved session.")
        }
        return data
    }
    static func vault() throws -> EnrollmentVault {
        lock.lock()
        defer { lock.unlock() }
        if let data = try read(account: "accounts-v1") {
            return try JSONDecoder().decode(EnrollmentVault.self, from: data)
        }
        var vault = EnrollmentVault()
        if let data = try read(account: "current") {
            vault.save(try JSONDecoder().decode(Credentials.self, from: data))
        }
        try write(try JSONEncoder().encode(vault), account: "accounts-v1")
        // Delete the legacy item only after the new atomic account-bound record exists.
        let status = SecItemDelete(query(account: "current") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClientError.invalid("Unable to finish secure session migration.")
        }
        return vault
    }
    @discardableResult
    static func update(_ change: (inout EnrollmentVault) throws -> Void) throws -> EnrollmentVault {
        lock.lock()
        defer { lock.unlock() }
        var value = try vault()
        try change(&value)
        try write(try JSONEncoder().encode(value), account: "accounts-v1")
        return value
    }
    static func save(_ credentials: Credentials) throws {
        try update { $0.save(credentials) }
    }
    static func refresh(_ credentials: Credentials, previous: Credentials) throws {
        try update { try $0.refresh(credentials, previous: previous) }
    }
    static func load() throws -> Credentials? { try vault().current }
    static func prepare(qr: EnrollmentQR, connection: Connection) throws -> PendingEnrollment {
        var result: PendingEnrollment?
        try update { value in
            if let pending = value.pending, pending.qr == qr, pending.connection == connection {
                guard pending.installationID == value.installationID else { throw QREnrollmentError.invalidProof }
                result = pending
            } else {
                let pending = try PendingEnrollment(
                    qr: qr, connection: connection, installationID: value.installationID,
                    deviceName: "Nephos iPhone")
                value.pending = pending
                result = pending
            }
        }
        guard let result else { throw QREnrollmentError.invalidProof }
        return result
    }
    static func commit(_ credentials: Credentials, requestID: UUID) throws {
        try update { try $0.commit(credentials, requestID: requestID) }
    }
    static func cancelEnrollment() throws {
        try update { $0.pending = nil }
    }
    static func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query() as CFDictionary)
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
    private let store: any SessionStorage
    private let renew: (@MainActor (Credentials) async throws -> Credentials)?

    var subject: String? { credentials?.subject }
    init(
        credentials: Credentials? = nil, store: any SessionStorage = KeychainStorage(),
        renew: (@MainActor (Credentials) async throws -> Credentials)? = nil
    ) {
        self.credentials = credentials
        self.store = store
        self.renew = renew
    }

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
        for endpoint in [doc.token_endpoint, doc.jwks_uri, doc.revocation_endpoint].compactMap({ $0 }) {
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
    func accessToken() async throws -> String {
        guard let saved = credentials else { throw ClientError.signedOut }
        if let refreshTask { return try await refreshTask.value }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        let expectedGeneration = generation
        let task = Task { @MainActor in
            let updated: Credentials
            if let renew = self.renew {
                updated = try await renew(saved)
            } else {
                updated = try await Self.renewCredentials(saved, store: self.store)
            }
            guard self.generation == expectedGeneration else { throw CancellationError() }
            try await self.store.update { try $0.refresh(updated, previous: saved) }
            guard self.generation == expectedGeneration else { throw CancellationError() }
            self.credentials = updated
            return updated.accessToken
        }
        refreshTask = task
        defer { if generation == expectedGeneration { refreshTask = nil } }
        return try await task.value
    }
    func recoverAccessToken(rejected: String) async throws -> String {
        guard var saved = credentials else { throw ClientError.signedOut }
        if saved.accessToken != rejected { return try await accessToken() }
        saved.expiresAt = .distantPast
        credentials = saved
        return try await accessToken()
    }
    func signOut() async throws {
        invalidate()
        try await store.remove()
    }
    func invalidate() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
    }
    static func renewCredentials(_ saved: Credentials, store: any SessionStorage = KeychainStorage()) async throws
        -> Credentials
    {
        guard let refresh = saved.refreshToken, !refresh.isEmpty else { throw ClientError.signedOut }
        let discovery = try await discovery(saved.connection)
        let key = try await proofKey(for: saved, store: store)
        let (data, response) = try await OAuthTransport.post(
            discovery.token_endpoint,
            fields: [
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": saved.connection.config.clientId,
            ], key: key)
        let tokens = try OAuthResponse.tokens(data, status: response.statusCode)
        if let idToken = tokens.id_token {
            _ = try await JWTVerifier.verify(
                idToken, discovery: discovery, clientID: saved.connection.config.clientId,
                purpose: .refresh(nonce: saved.nonce, subject: saved.subject))
        }
        try await JWTVerifier.verifyAccess(
            tokens.access_token, discovery: discovery, clientID: saved.connection.config.clientId,
            subject: saved.subject)
        if let thumbprint = saved.dpopKeyThumbprint {
            guard let replacement = tokens.refresh_token else {
                throw ClientError.invalid(
                    "The server omitted the bound renewal credential. Your session has been kept.")
            }
            try RefreshTokenClaims.validateResponseCredential(
                replacement, issuer: discovery.issuer, clientID: saved.connection.config.clientId,
                subject: saved.subject, thumbprint: thumbprint)
        }
        var updated = saved
        updated.accessToken = tokens.access_token
        updated.refreshToken = tokens.refresh_token ?? saved.refreshToken
        updated.expiresAt = Date().addingTimeInterval(tokens.expires_in)
        return updated
    }
    static func revokeCredentials(_ saved: Credentials, store: any SessionStorage) async throws {
        let discovery = try await discovery(saved.connection)
        guard let endpoint = discovery.revocation_endpoint, let refresh = saved.refreshToken else {
            throw ClientError.invalid("Remote sign-out is unavailable. You can still sign out on this device only.")
        }
        let key = try await proofKey(for: saved, store: store)
        let (_, response) = try await OAuthTransport.post(
            endpoint,
            fields: [
                "client_id": saved.connection.config.clientId, "token": refresh, "token_type_hint": "refresh_token",
            ], key: key)
        guard response.statusCode == 200 else {
            throw ClientError.http(
                response.statusCode, "The server has not confirmed sign-out. Retry or sign out on this device only.")
        }
    }

    static func proofKey(for saved: Credentials, store: any SessionStorage) async throws -> DPoPKey? {
        guard let expected = saved.dpopKeyThumbprint else { return nil }
        let vault = try await store.vault()
        let account = AccountIdentity.key(connection: saved.connection, subject: saved.subject)
        guard vault.activeAccount == account, vault.current?.nonce == saved.nonce,
            let persisted = vault.deviceKeys[account]
        else {
            throw ClientError.invalid("The saved device key is unavailable. Retry after unlocking your device.")
        }
        let key = DPoPKey(signingKey: DeviceSigningKey(persisted: persisted))
        let thumbprint = try await Task.detached { try key.thumbprint }.value
        guard thumbprint == expected else {
            throw ClientError.invalid("The saved device key does not match this session. No credentials were changed.")
        }
        return key
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
        let claims = try await verifiedClaims(token, discovery: discovery)
        return try IdentityTokenClaims.validate(claims, issuer: discovery.issuer, clientID: clientID, purpose: purpose)
    }
    static func verifyAccess(_ token: String, discovery: OIDCDiscovery, clientID: String, subject: String) async throws
    {
        let claims = try await verifiedClaims(token, discovery: discovery)
        guard claims["iss"] as? String == discovery.issuer, claims["sub"] as? String == subject,
            claims["azp"] as? String == clientID, claims["typ"] as? String == "Bearer", claims["cnf"] == nil,
            let expiry = claims["exp"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
            expiry.doubleValue.isFinite, expiry.doubleValue > Date().timeIntervalSince1970,
            let issued = claims["iat"] as? NSNumber, CFGetTypeID(issued) != CFBooleanGetTypeID(),
            issued.doubleValue.isFinite, issued.doubleValue <= Date().timeIntervalSince1970 + 30,
            expiry.doubleValue > issued.doubleValue
        else { throw ClientError.invalid("Access token identity or lifetime validation failed.") }
        if let notBefore = claims["nbf"] {
            guard let date = notBefore as? NSNumber, CFGetTypeID(date) != CFBooleanGetTypeID(),
                date.doubleValue.isFinite, date.doubleValue <= Date().timeIntervalSince1970 + 30
            else { throw ClientError.invalid("Access token is not valid yet.") }
        }
    }
    private static func verifiedClaims(_ token: String, discovery: OIDCDiscovery) async throws -> [String: Any] {
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
        return claims
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
