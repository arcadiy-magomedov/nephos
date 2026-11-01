import Foundation

enum LoginPinError: LocalizedError {
    case invalidEmail, invalidRequest, unknownAccount, rateLimited, invalidExpiry, expiredRequest
    var errorDescription: String? {
        switch self {
        case .invalidEmail: "Enter a valid email address."
        case .invalidRequest: "The server rejected the email address or sign-in client."
        case .unknownAccount: "This email is not an enabled known account. Contact your administrator."
        case .rateLimited:
            "Too many PIN requests. Wait one minute before requesting again. If you already requested a PIN, you can still enter it."
        case .invalidExpiry: "The server returned an invalid PIN expiry."
        case .expiredRequest: "Request a new PIN before signing in."
        }
    }
}

enum LoginPinPolicy {
    static func email(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.utf8.count <= 320, parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
            !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains(".."),
            parts[0].allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+/=?^_`{|}~.-".contains($0))
            })
        else { throw LoginPinError.invalidEmail }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard parts[1].utf8.count <= 253, labels.count >= 2,
            labels.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                    && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            })
        else { throw LoginPinError.invalidEmail }
        return value
    }
}

struct LoginPinReceipt: Decodable, Sendable {
    let expiresIn: Int
    func validate() throws {
        guard (1...1800).contains(expiresIn) else {
            throw LoginPinError.invalidExpiry
        }
    }
}

struct LoginPinRequest: Codable, Sendable {
    let connection: Connection
    let email: String
    let requestedAt: Date
    let expiresAt: Date

    init(connection: Connection, email: String, receipt: LoginPinReceipt, requestedAt: Date = Date()) throws {
        try receipt.validate()
        self.connection = connection
        self.email = try LoginPinPolicy.email(email)
        self.requestedAt = requestedAt
        expiresAt = requestedAt.addingTimeInterval(TimeInterval(receipt.expiresIn))
    }

    func isValid(for connection: Connection, now: Date = Date()) -> Bool {
        self.connection == connection && requestedAt <= now && expiresAt > now
            && expiresAt.timeIntervalSince(requestedAt) <= 1800
            && (try? LoginPinPolicy.email(email)) == email
    }
}

enum LoginPinClient {
    static func request(connection: Connection, email: String, session: URLSession = HTTP.session) async throws
        -> LoginPinReceipt
    {
        try Task.checkCancellation()
        let normalized = try LoginPinPolicy.email(email)
        #if DEBUG
            let allowHTTP = connection.allowDevelopmentHTTP
        #else
            let allowHTTP = false
        #endif
        let issuer = try URLPolicy.validate(
            connection.config.issuer, allowDevelopmentHTTP: allowHTTP)
        struct Payload: Encodable {
            let email: String
            let clientId: String
        }
        let body = try JSONEncoder().encode(Payload(email: normalized, clientId: connection.config.clientId))
        let request = HTTP.request(
            issuer.appendingPathComponent("nephos-admin/request-pin"), method: "POST", body: body)
        do {
            let receipt = try await HTTP.json(LoginPinReceipt.self, request, session: session)
            try receipt.validate()
            try Task.checkCancellation()
            return receipt
        } catch ClientError.http(400, _) {
            throw LoginPinError.invalidRequest
        } catch ClientError.http(404, _) {
            throw LoginPinError.unknownAccount
        } catch ClientError.http(429, _) {
            throw LoginPinError.rateLimited
        }
    }
}
