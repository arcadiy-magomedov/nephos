import CryptoKit
import Foundation

enum QREnrollmentError: String, LocalizedError {
    case invalidQR, inviteExpired, inviteUsed, inviteCancelled, userDisabled
    case recoveryExpired, sessionRevoked, invalidProof, unavailable, invalidChallenge
    case inviteUnavailable, invalidRequest, invalidScope, rateLimited
    var errorDescription: String? {
        switch self {
        case .invalidQR: "This is not a supported Nephos sign-in QR code."
        case .inviteExpired: "This QR code expired. Ask your administrator for a new code."
        case .inviteUsed: "This QR code was used by another device. Ask for a new code."
        case .inviteCancelled: "Your administrator cancelled this QR code."
        case .userDisabled: "Your account is disabled. Contact your administrator."
        case .recoveryExpired: "The sign-in recovery window expired. Ask for a new QR code."
        case .sessionRevoked: "This device session was revoked. Ask for a new QR code."
        case .invalidProof: "The server rejected this device's sign-in proof."
        case .unavailable: "The sign-in service is unavailable. Your saved sign-in can be retried."
        case .invalidChallenge: "The server returned an invalid device challenge."
        case .inviteUnavailable: "This invitation is unavailable. Ask your administrator for a new QR code."
        case .invalidRequest: "The server rejected this sign-in request."
        case .invalidScope: "The sign-in service does not support the required offline session."
        case .rateLimited: "Too many sign-in attempts. Wait one minute, then resume your saved sign-in."
        }
    }
    static func provider(_ code: String) -> Self? {
        [
            "invite_expired": .inviteExpired, "invite_used": .inviteUsed, "invite_cancelled": .inviteCancelled,
            "user_disabled": .userDisabled, "recovery_expired": .recoveryExpired,
            "session_revoked": .sessionRevoked, "invalid_proof": .invalidProof,
            "temporarily_unavailable": .unavailable,
            "invite_unavailable": .inviteUnavailable, "invalid_request": .invalidRequest,
            "invalid_scope": .invalidScope,
        ][code]
    }
}

struct EnrollmentQR: Codable, Equatable, Sendable {
    let v: Int
    let origin: String
    let inviteId: String
    let secret: String

    static func parse(_ raw: String) throws -> Self {
        guard raw.utf8.count <= 2048,
            let keys = try? NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"\\s*:"),
            keys.numberOfMatches(in: raw, range: NSRange(raw.startIndex..., in: raw)) == 4,
            let data = raw.data(using: .utf8),
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(fields.keys) == ["v", "origin", "inviteId", "secret"],
            let version = fields["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
            version.doubleValue == 1,
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { throw QREnrollmentError.invalidQR }
        try value.validate()
        return value
    }
    func validate() throws {
        guard v == 1, let parts = URLComponents(string: origin),
            parts.scheme == "https", parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil, parts.path.isEmpty,
            let host = parts.host, !host.isEmpty, host == host.lowercased(),
            Self.validHost(host),
            parts.port == nil || (1...65535).contains(parts.port!),
            origin == "https://\(host)" + (parts.port.map { ":\($0)" } ?? ""),
            let url = parts.url, url.absoluteString == origin,
            let invitation = UUID(uuidString: inviteId), invitation.uuidString.lowercased() == inviteId,
            let decoded = Self.decode(secret), decoded.count == 32
        else { throw QREnrollmentError.invalidQR }
    }
    private static func validHost(_ host: String) -> Bool {
        if host.hasPrefix("[") && host.hasSuffix("]") && host.contains(":") {
            return host.allSatisfy { $0.isHexDigit || ":.[]".contains($0) }
        }
        guard host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        let normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - text.count % 4) % 4)),
            Hashing.base64URL(data) == text
        else { return nil }
        return data
    }
}

struct Credentials: Codable, Sendable {
    let connection: Connection
    let subject: String
    let nonce: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

struct PendingEnrollment: Codable, Sendable {
    let qr: EnrollmentQR
    let connection: Connection
    let installationID: UUID
    let requestID: UUID
    let nonce: String
    let deviceName: String
    let privateKey: Data
    let createdAt: Date
    var publicKey: Data {
        get throws { try P256.Signing.PrivateKey(rawRepresentation: privateKey).publicKey.x963Representation }
    }

    init(qr: EnrollmentQR, connection: Connection, installationID: UUID, deviceName: String = "Nephos iPhone") throws {
        try qr.validate()
        self.qr = qr
        self.connection = connection
        self.installationID = installationID
        requestID = UUID()
        nonce = UUID().uuidString.lowercased()
        self.deviceName = String(deviceName.prefix(100))
        privateKey = P256.Signing.PrivateKey().rawRepresentation
        createdAt = Date()
    }

    func signature(challenge: String, challengeID: String) throws -> String {
        guard UUID(uuidString: challengeID) != nil, let bytes = EnrollmentQR.decode(challenge),
            bytes.count <= 2048, let canonical = String(data: bytes, encoding: .utf8)
        else { throw QREnrollmentError.invalidChallenge }
        let lines = canonical.components(separatedBy: "\n")
        let expected = [
            "nephos-qr-v1", qr.origin, "nephos-ios", qr.inviteId, requestID.uuidString.lowercased(),
            Hashing.base64URL(Data(SHA256.hash(data: try publicKey))), challengeID,
        ]
        guard lines.count == 8, Array(lines.prefix(7)) == expected,
            let random = EnrollmentQR.decode(lines[7]), random.count == 32
        else { throw QREnrollmentError.invalidChallenge }
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
        return Hashing.base64URL(try key.signature(for: bytes).derRepresentation)
    }
}

// A single Keychain item commits active account, credentials, device key and recovery state together.
struct EnrollmentVault: Codable, Sendable {
    var installationID = UUID()
    var activeAccount: String?
    var sessions: [String: Credentials] = [:]
    var deviceKeys: [String: Data] = [:]
    var pending: PendingEnrollment?

    var current: Credentials? { activeAccount.flatMap { sessions[$0] } }
    mutating func save(_ credentials: Credentials) {
        let account = LedgerStore.accountKey(connection: credentials.connection, subject: credentials.subject)
        sessions[account] = credentials
        activeAccount = account
    }
    mutating func commit(_ credentials: Credentials, requestID: UUID) throws {
        guard let pending, pending.installationID == installationID, pending.requestID == requestID,
            pending.connection == credentials.connection, pending.nonce == credentials.nonce
        else { throw QREnrollmentError.invalidProof }
        let account = LedgerStore.accountKey(connection: credentials.connection, subject: credentials.subject)
        deviceKeys[account] = pending.privateKey
        save(credentials)
        self.pending = nil
    }
}
