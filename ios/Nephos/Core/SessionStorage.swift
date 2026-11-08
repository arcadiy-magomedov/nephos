import Foundation

protocol SessionStorage: Sendable {
    func vault() async throws -> EnrollmentVault
    @discardableResult
    func update(_ change: @Sendable (inout EnrollmentVault) throws -> Void) async throws -> EnrollmentVault
    func remove() async throws
}

actor KeychainStorage: SessionStorage {
    func vault() throws -> EnrollmentVault { try Keychain.vault() }
    @discardableResult
    func update(_ change: @Sendable (inout EnrollmentVault) throws -> Void) throws -> EnrollmentVault {
        try Keychain.update(change)
    }
    func remove() throws { try Keychain.remove() }
}

extension EnrollmentVault {
    mutating func refresh(_ credentials: Credentials, previous: Credentials) throws {
        let account = AccountIdentity.key(connection: previous.connection, subject: previous.subject)
        guard activeAccount == account, current?.nonce == previous.nonce,
            current?.refreshToken == previous.refreshToken,
            credentials.subject == previous.subject, credentials.nonce == previous.nonce,
            credentials.dpopKeyThumbprint == previous.dpopKeyThumbprint,
            credentials.connection.hasSameIdentity(as: previous.connection)
        else { throw CancellationError() }
        sessions[account] = credentials
    }
}

enum OAuthResponse {
    static func tokens(_ data: Data, status: Int) throws -> TokenResponse {
        if status == 400,
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            fields["error"] as? String == "invalid_grant",
            let reason = fields["error_description"] as? String,
            [
                "Offline user session not found", "Offline session not active", "Session not active",
                "Client session not active", "Session doesn't have required client", "User disabled",
                "Offline session invalid because offline access not granted anymore",
                "Refresh token expired",
            ].contains(reason)
        {
            throw ClientError.signedOut
        }
        guard (200..<300).contains(status) else {
            throw ClientError.http(status, "Session renewal failed. Your saved session has been kept; retry later.")
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard tokens.token_type.lowercased() == "bearer", tokens.expires_in.isFinite,
            tokens.expires_in > 0, !tokens.access_token.isEmpty, tokens.refresh_token?.isEmpty != true
        else { throw ClientError.invalid("Unsupported token response. Your saved session has been kept.") }
        return tokens
    }
}
