import Foundation

enum QREnrollmentClient {
    static let grant = "urn:nephos:params:oauth:grant-type:qr"
    private struct Configuration: Decodable, Sendable {
        let v: Int
        let origin: String
        let issuer: String
        let clientId: String
        let grantType: String
        let persistentLogin: PersistentLoginConfiguration?
    }
    private struct Challenge: Decodable, Sendable {
        let challengeId: String
        let challenge: String
        let expiresIn: Int
    }
    private struct ChallengeRequest: Encodable {
        let inviteId: String
        let requestId: String
        let clientId: String
        let publicKey: String
    }

    static func connection(for qr: EnrollmentQR) async throws -> Connection {
        try qr.validate()
        let origin = try URLPolicy.validate(qr.origin)
        let config = try await HTTP.json(
            ServerConfig.self, HTTP.request(origin.appendingPathComponent("v1/config")))
        guard !config.serverId.isEmpty, config.clientId == "nephos-ios"
        else { throw ClientError.invalid("The server advertised an unsupported authentication contract.") }
        let issuer = try URLPolicy.validate(config.issuer)
        guard URLPolicy.sameOrigin(origin, issuer), issuer.absoluteString == config.issuer else {
            throw ClientError.invalid("The sign-in issuer is outside the QR's trusted HTTPS origin.")
        }
        var connection = Connection(baseURL: origin, config: config, allowDevelopmentHTTP: false)
        _ = try await AuthSession.discovery(connection)
        let enrollment = try await HTTP.json(
            Configuration.self, HTTP.request(issuer.appendingPathComponent("nephos-admin/enrollment/config")))
        guard enrollment.v == 1, enrollment.origin == qr.origin,
            enrollment.issuer == config.issuer, enrollment.clientId == config.clientId,
            enrollment.grantType == grant
        else { throw ClientError.invalid("The server's QR enrollment configuration does not match this code.") }
        guard enrollment.persistentLogin?.supportsDPoP == true else {
            throw ClientError.invalid("This server has not enabled device-bound sign-in. Contact your administrator.")
        }
        connection.persistentLogin = enrollment.persistentLogin
        try Task.checkCancellation()
        return connection
    }

    static func exchange(_ pending: PendingEnrollment) async throws -> Credentials {
        let discovery = try await AuthSession.discovery(pending.connection)
        let requestID = pending.requestID.uuidString.lowercased()
        let publicKey = Hashing.base64URL(try pending.publicKey)
        let challengeRequest = ChallengeRequest(
            inviteId: pending.qr.inviteId, requestId: requestID,
            clientId: pending.connection.config.clientId, publicKey: publicKey)
        let issuer = try URLPolicy.validate(pending.connection.config.issuer)
        let challenge: Challenge = try JSONDecoder().decode(
            Challenge.self,
            from: await response(
                HTTP.request(
                    issuer.appendingPathComponent("nephos-admin/enrollment/challenge"), method: "POST",
                    body: try JSONEncoder().encode(challengeRequest))))
        guard (1...60).contains(challenge.expiresIn) else { throw QREnrollmentError.invalidChallenge }
        let signature = try pending.signature(challenge: challenge.challenge, challengeID: challenge.challengeId)
        try Task.checkCancellation()
        let fields = [
            "grant_type": grant, "client_id": pending.connection.config.clientId,
            "invite_id": pending.qr.inviteId, "invite_secret": pending.qr.secret,
            "request_id": requestID, "public_key": publicKey,
            "challenge_id": challenge.challengeId, "signature": signature,
            "device_name": pending.deviceName,
            "nonce": pending.nonce, "scope": "openid offline_access",
        ]
        let key: DPoPKey? =
            pending.connection.persistentLogin?.supportsDPoP == true
            ? DPoPKey(signingKey: DeviceSigningKey(persisted: pending.privateKey)) : nil
        let (data, http) = try await OAuthTransport.post(discovery.token_endpoint, fields: fields, key: key)
        try check(data, response: http)
        let tokens = try OAuthResponse.tokens(data, status: http.statusCode)
        guard tokens.token_type.lowercased() == "bearer", tokens.expires_in.isFinite,
            tokens.expires_in > 0, !tokens.access_token.isEmpty,
            let idToken = tokens.id_token, let refresh = tokens.refresh_token, !refresh.isEmpty
        else { throw ClientError.invalid("The sign-in service omitted a persistent OIDC session.") }
        let subject = try await JWTVerifier.verify(
            idToken, discovery: discovery, clientID: pending.connection.config.clientId,
            purpose: .authorization(nonce: pending.nonce))
        try await JWTVerifier.verifyAccess(
            tokens.access_token, discovery: discovery, clientID: pending.connection.config.clientId,
            subject: subject)
        let thumbprint = try key?.thumbprint
        if let thumbprint {
            try RefreshTokenClaims.validateResponseCredential(
                refresh, issuer: discovery.issuer, clientID: pending.connection.config.clientId,
                subject: subject, thumbprint: thumbprint)
        }
        try Task.checkCancellation()
        return Credentials(
            connection: pending.connection, subject: subject, nonce: pending.nonce,
            accessToken: tokens.access_token, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(tokens.expires_in), dpopKeyThumbprint: thumbprint)
    }

    private static func response(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await HTTP.response(request, maximum: 128 * 1024)
        try check(data, response: response)
        return data
    }

    private static func check(_ data: Data, response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for field in ["error_description", "error"] {
                    if let code = fields[field] as? String, let error = QREnrollmentError.provider(code) {
                        throw error
                    }
                }
            }
            if http.statusCode == 503 { throw QREnrollmentError.unavailable }
            if http.statusCode == 429 { throw QREnrollmentError.rateLimited }
        }
        try HTTP.check(response)
    }
}
