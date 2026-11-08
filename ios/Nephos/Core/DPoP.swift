import CryptoKit
import Foundation

struct DPoPKey: Sendable {
    private struct PublicJWK: Encodable {
        let crv = "P-256"
        let kty = "EC"
        let x: String
        let y: String
    }

    private struct Header: Encodable {
        let alg = "ES256"
        let typ = "dpop+jwt"
        let jwk: PublicJWK
    }

    private struct Claims: Encodable {
        let jti: String
        let htm: String
        let htu: String
        let iat: Int
        let nonce: String?
    }

    let signingKey: DeviceSigningKey

    private var jwk: PublicJWK {
        get throws {
            let point = try signingKey.publicKey.x963Representation
            guard point.count == 65, point.first == 4 else {
                throw ClientError.invalid("Unsupported device signing key.")
            }
            return PublicJWK(
                x: Hashing.base64URL(Data(point[1..<33])), y: Hashing.base64URL(Data(point[33..<65])))
        }
    }

    var thumbprint: String {
        get throws { Hashing.base64URL(Data(SHA256.hash(data: try Self.encode(jwk)))) }
    }

    func proof(for url: URL, method: String = "POST", nonce: String? = nil, now: Date = Date()) throws -> String {
        guard var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
            target.scheme == "https", target.host != nil, target.user == nil, target.password == nil,
            !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }),
            now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
            now.timeIntervalSince1970 < Double(Int.max)
        else { throw ClientError.invalid("Invalid proof target or device time.") }
        target.query = nil
        target.fragment = nil
        guard let uri = target.url?.absoluteString else { throw ClientError.invalid("Invalid proof target.") }
        if let nonce, nonce.isEmpty || nonce.utf8.count > 1024 {
            throw ClientError.invalid("The server returned an invalid proof nonce.")
        }
        let header = Hashing.base64URL(try Self.encode(Header(jwk: jwk)))
        let claims = Hashing.base64URL(
            try Self.encode(
                Claims(
                    jti: UUID().uuidString.lowercased(), htm: method, htu: uri,
                    iat: Int(now.timeIntervalSince1970), nonce: nonce)))
        let input = "\(header).\(claims)"
        let signature = try signingKey.signature(for: Data(input.utf8))
        return "\(input).\(Hashing.base64URL(signature.rawRepresentation))"
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

enum OAuthTransport {
    static func post(
        _ endpoint: URL, fields: [String: String], key: DPoPKey? = nil, session: URLSession = HTTP.session
    ) async throws -> (Data, HTTPURLResponse) {
        _ = try URLPolicy.validate(endpoint.absoluteString)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var nonce: String?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = HTTP.request(
                endpoint, method: "POST", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded")
            if let key { request.setValue(try key.proof(for: endpoint, nonce: nonce), forHTTPHeaderField: "DPoP") }
            let (data, response) = try await HTTP.response(request, maximum: 128 * 1024, session: session)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.invalid("Invalid identity-service response.")
            }
            if key != nil, [400, 401].contains(http.statusCode),
                let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                fields["error"] as? String == "use_dpop_nonce"
            {
                guard attempt == 0, let challenge = http.value(forHTTPHeaderField: "DPoP-Nonce"),
                    !challenge.isEmpty, challenge.utf8.count <= 1024
                else {
                    throw ClientError.invalid("Device-proof negotiation failed. Your saved session has been kept.")
                }
                nonce = challenge
                continue
            }
            return (data, http)
        }
        throw ClientError.invalid("Device-proof negotiation failed. Your saved session has been kept.")
    }
}

enum RefreshTokenClaims {
    // Keycloak's HS512 renewal credential is opaque: HTTPS authenticates its receipt.
    // These are consistency checks, not signature verification or authorization.
    static func validateResponseCredential(
        _ token: String, issuer: String, clientID: String, subject: String, thumbprint: String
    ) throws {
        let parts = token.components(separatedBy: ".")
        guard token.utf8.count < 128 * 1024, parts.count == 3,
            let headerData = EnrollmentQR.decode(parts[0]), let payloadData = EnrollmentQR.decode(parts[1]),
            let signature = EnrollmentQR.decode(parts[2]), signature.count == 64,
            let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
            header["alg"] as? String == "HS512", header["crit"] == nil,
            let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            throw ClientError.invalid("Unsupported renewal credential format. Your session has been kept.")
        }
        try validate(payload, issuer: issuer, clientID: clientID, subject: subject, thumbprint: thumbprint)
    }

    static func validate(
        _ claims: [String: Any], issuer: String, clientID: String, subject: String, thumbprint: String,
        now: Date = Date()
    ) throws {
        guard claims["iss"] as? String == issuer, claims["sub"] as? String == subject,
            claims["azp"] as? String == clientID, claims["typ"] as? String == "Offline",
            let confirmation = claims["cnf"] as? [String: Any], confirmation["jkt"] as? String == thumbprint,
            let expiry = claims["exp"] as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
            expiry.doubleValue.isFinite, expiry.doubleValue > now.timeIntervalSince1970,
            let issued = claims["iat"] as? NSNumber, CFGetTypeID(issued) != CFBooleanGetTypeID(),
            issued.doubleValue.isFinite, issued.doubleValue <= now.timeIntervalSince1970 + 30,
            expiry.doubleValue > issued.doubleValue
        else {
            throw ClientError.invalid("Refresh-token identity or device binding failed. Your session has been kept.")
        }
    }
}
