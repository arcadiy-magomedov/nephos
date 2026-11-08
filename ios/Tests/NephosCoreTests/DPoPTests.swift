import CryptoKit
import Foundation
import XCTest

@testable import NephosCore

private func decodePart(_ value: String) throws -> Data {
    let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return try XCTUnwrap(
        Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)))
}

private func claims(_ proof: String, part: Int = 1) throws -> [String: Any] {
    let segments = proof.components(separatedBy: ".")
    guard segments.count == 3 else { throw ClientError.invalid("Malformed test proof") }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: decodePart(segments[part])) as? [String: Any])
}

private final class NonceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let proof = request.value(forHTTPHeaderField: "DPoP")
            var status = 200
            var headers: [String: String] = [:]
            var body: [String: Any] = ["hasProof": proof != nil]
            if let proof {
                let payload = try claims(proof)
                if payload["nonce"] == nil || request.url?.path == "/loop" {
                    status = 400
                    headers["DPoP-Nonce"] = try XCTUnwrap(payload["jti"] as? String)
                    body = ["error": "use_dpop_nonce"]
                } else {
                    body = ["proof": proof]
                }
            }
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class DPoPTests: XCTestCase {
    func testProofUsesPublicJWKRawSignatureCanonicalTargetAndStableKey() throws {
        let persisted = try DeviceSigningKey.generate().persisted
        let key = DPoPKey(signingKey: DeviceSigningKey(persisted: persisted))
        let url = URL(string: "https://photos.example.test/realms/nephos/token?ignored=1#fragment")!
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let proof = try key.proof(for: url, now: time)
        let header = try claims(proof, part: 0)
        let payload = try claims(proof)
        let jwk = try XCTUnwrap(header["jwk"] as? [String: String])
        XCTAssertEqual(header["typ"] as? String, "dpop+jwt")
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(Set(jwk.keys), ["crv", "kty", "x", "y"])
        XCTAssertEqual(jwk["crv"], "P-256")
        XCTAssertEqual(jwk["kty"], "EC")
        XCTAssertEqual(try decodePart(XCTUnwrap(jwk["x"])).count, 32)
        XCTAssertEqual(try decodePart(XCTUnwrap(jwk["y"])).count, 32)
        XCTAssertEqual(payload["htu"] as? String, "https://photos.example.test/realms/nephos/token")
        XCTAssertEqual(payload["htm"] as? String, "POST")
        XCTAssertEqual(payload["iat"] as? Int, 1_800_000_000)
        XCTAssertNil(payload["ath"])
        XCTAssertNil(payload["nonce"])
        let segments = proof.components(separatedBy: ".")
        let raw = try decodePart(segments[2])
        XCTAssertEqual(raw.count, 64)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(
            try key.signingKey.publicKey.isValidSignature(
                signature, for: Data(segments.prefix(2).joined(separator: ".").utf8)))
        let canonical = #"{"crv":"P-256","kty":"EC","x":""# + jwk["x"]! + #"","y":""# + jwk["y"]! + #""}"#
        XCTAssertEqual(try key.thumbprint, Hashing.base64URL(Data(SHA256.hash(data: Data(canonical.utf8)))))
        let restored = DPoPKey(signingKey: DeviceSigningKey(persisted: persisted))
        XCTAssertEqual(try restored.thumbprint, try key.thumbprint)
        XCTAssertNotEqual(
            try claims(restored.proof(for: url, now: time))["jti"] as? String, payload["jti"] as? String)
        XCTAssertThrowsError(try key.proof(for: URL(string: "http://photos.example.test/token")!))
    }

    func testNonceRetryCreatesFreshProofAndRemainsBounded() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let key = DPoPKey(signingKey: try DeviceSigningKey.generate())
        let (data, response) = try await OAuthTransport.post(
            URL(string: "https://photos.example.test/token")!, fields: ["client_id": "nephos-ios"], key: key,
            session: session)
        XCTAssertEqual(response.statusCode, 200)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let payload = try claims(XCTUnwrap(result["proof"]))
        XCTAssertNotNil(payload["nonce"])
        XCTAssertNotEqual(payload["jti"] as? String, payload["nonce"] as? String)
        do {
            _ = try await OAuthTransport.post(
                URL(string: "https://photos.example.test/loop")!, fields: [:], key: key, session: session)
            XCTFail("Repeated nonce challenges must not create an unbounded retry loop")
        } catch ClientError.invalid {}
        let (legacy, _) = try await OAuthTransport.post(
            URL(string: "https://photos.example.test/token")!, fields: [:], session: session)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: legacy) as? [String: Bool])?["hasProof"], false)
    }

    func testRefreshClaimsRejectBindingDowngradeAndChangedIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original: [String: Any] = [
            "iss": "https://photos.example.test/realms/nephos", "sub": "account", "azp": "nephos-ios",
            "typ": "Offline", "iat": 1_799_999_900, "exp": 1_800_000_300, "cnf": ["jkt": "device-key"],
        ]
        func verify(_ value: [String: Any]) throws {
            try RefreshTokenClaims.validate(
                value, issuer: "https://photos.example.test/realms/nephos",
                clientID: "nephos-ios", subject: "account", thumbprint: "device-key", now: now)
        }
        try verify(original)
        let replacements: [(String, Any?)] = [
            ("cnf", nil), ("cnf", ["jkt": "another-key"]), ("iss", "https://wrong.example.test"),
            ("sub", "other-account"), ("azp", "other-client"), ("typ", "Bearer"),
            ("exp", 1_799_999_999), ("exp", true), ("iat", 1_800_000_100),
        ]
        for (field, value) in replacements {
            var altered = original
            altered[field] = value
            XCTAssertThrowsError(try verify(altered), field)
        }
    }

    func testOpaqueRefreshResponseChecksMetadataWithoutUsingPublicJWTVerifier() throws {
        let issuer = "https://photos.example.test/realms/nephos"
        let now = Int(Date().timeIntervalSince1970)
        func credential(algorithm: String = "HS512", thumbprint: String = "device-key") throws -> String {
            let header = Hashing.base64URL(
                try JSONSerialization.data(withJSONObject: ["alg": algorithm, "typ": "JWT"]))
            let payload = Hashing.base64URL(
                try JSONSerialization.data(withJSONObject: [
                    "iss": issuer, "sub": "account", "azp": "nephos-ios", "aud": issuer,
                    "typ": "Offline", "iat": now, "exp": now + 300, "cnf": ["jkt": thumbprint],
                ]))
            let message = "\(header).\(payload)"
            let signature = HMAC<SHA512>.authenticationCode(
                for: Data(message.utf8), using: SymmetricKey(size: .bits256))
            return "\(message).\(Hashing.base64URL(Data(signature)))"
        }
        func check(_ token: String) throws {
            try RefreshTokenClaims.validateResponseCredential(
                token, issuer: issuer, clientID: "nephos-ios", subject: "account", thumbprint: "device-key")
        }
        try check(credential())
        XCTAssertThrowsError(try check(credential(thumbprint: "another-device")))
        XCTAssertThrowsError(try check(credential(algorithm: "none")))
        XCTAssertThrowsError(try check(credential(algorithm: "RS256")))
        XCTAssertThrowsError(try check("malformed.refresh"))
    }
}
