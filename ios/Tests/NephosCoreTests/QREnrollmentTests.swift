import CoreImage
import CryptoKit
import Foundation
import ImageIO
import XCTest

@testable import NephosCore

final class QREnrollmentTests: XCTestCase {
    private let origin = "https://photos.example.test:8443"
    private var qr: EnrollmentQR {
        EnrollmentQR(
            v: 1, origin: origin, inviteId: "00000000-0000-0000-0000-000000000123",
            secret: Hashing.base64URL(Data(repeating: 42, count: 32)))
    }
    private var connection: Connection {
        Connection(
            baseURL: URL(string: origin)!,
            config: ServerConfig(
                serverId: "qr-tests", issuer: origin + "/realms/nephos", clientId: "nephos-ios",
                maxUploadBytes: 8_589_934_592, chunkSize: 4_194_304), allowDevelopmentHTTP: false)
    }
    private func raw(_ fields: [String: Any]) throws -> String {
        String(
            data: try JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes]),
            encoding: .utf8)!
    }
    private var fields: [String: Any] {
        ["v": 1, "origin": origin, "inviteId": qr.inviteId, "secret": qr.secret]
    }
    private func credentials(_ pending: PendingEnrollment, subject: String = "account-one") -> Credentials {
        Credentials(
            connection: connection, subject: subject, nonce: pending.nonce,
            accessToken: "opaque-test-only", refreshToken: "opaque-test-only", expiresAt: Date().addingTimeInterval(300)
        )
    }
    func testStrictVersionedOriginOnlySchema() throws {
        XCTAssertEqual(try EnrollmentQR.parse(raw(fields)), qr)
        for valid in ["https://localhost:8443", "https://[::1]:8443", "https://photos.example.test"] {
            var values = fields
            values["origin"] = valid
            XCTAssertEqual(try EnrollmentQR.parse(raw(values)).origin, valid)
        }
        for invalid in [
            "http://photos.example.test", "https://photos.example.test/",
            "https://user@photos.example.test", "https://user:pass@photos.example.test",
            "https://photos.example.test/path", "https://photos.example.test?query",
            "https://photos.example.test#fragment", "https://photos.example.test:0",
            "https://photos.example.test:65536", "https://PHOTOS.example.test", "https://photos.example.test.",
            "file:///photos", "//photos.example.test", " https://photos.example.test", "https://фото.example.test",
            "https://foo%20bar.example.test", "https://foo_bar.example.test", "https://-foo.example.test",
            "https://photos.example.test:",
            "https://photos.example.test:08443",
        ] {
            var bad = fields
            bad["origin"] = invalid
            XCTAssertThrowsError(try EnrollmentQR.parse(raw(bad)), invalid)
        }
        for version in [0, 2, -1] {
            var bad = fields
            bad["v"] = version
            XCTAssertThrowsError(try EnrollmentQR.parse(raw(bad)))
        }
        var bad = fields
        bad["v"] = true
        XCTAssertThrowsError(try EnrollmentQR.parse(raw(bad)))
        bad = fields
        bad["extra"] = "unsupported"
        XCTAssertThrowsError(try EnrollmentQR.parse(raw(bad)))
        bad = fields
        bad["inviteId"] = "not-a-uuid"
        XCTAssertThrowsError(try EnrollmentQR.parse(raw(bad)))
        for secret in ["", "secret", qr.secret + "=", String(repeating: "A", count: 44), qr.secret + "\n"] {
            bad = fields
            bad["secret"] = secret
            XCTAssertThrowsError(try EnrollmentQR.parse(raw(bad)))
        }
        let duplicate = "{\"v\":1," + (try raw(fields)).dropFirst()
        XCTAssertThrowsError(try EnrollmentQR.parse(duplicate))
        XCTAssertThrowsError(try EnrollmentQR.parse("{\"\\u0076\":1," + (try raw(fields)).dropFirst()))
        XCTAssertEqual(try EnrollmentQR.parse(String(data: JSONEncoder().encode(qr), encoding: .utf8)!), qr)
        XCTAssertThrowsError(try EnrollmentQR.parse(String(repeating: "x", count: 2049)))
    }

    func testKeyAndImmutableRequestSurviveCrashAndLostResponse() throws {
        var vault = EnrollmentVault()
        let pending = try PendingEnrollment(qr: qr, connection: connection, installationID: vault.installationID)
        vault.pending = pending
        let restored = try JSONDecoder().decode(EnrollmentVault.self, from: JSONEncoder().encode(vault))
        let resumed = try XCTUnwrap(restored.pending)
        XCTAssertEqual(resumed.requestID, pending.requestID)
        XCTAssertEqual(resumed.nonce, pending.nonce)
        XCTAssertEqual(resumed.deviceName, pending.deviceName)
        XCTAssertEqual(try resumed.publicKey, try pending.publicKey)
        XCTAssertEqual(resumed.installationID, restored.installationID)
        XCTAssertNil(restored.current)
    }

    func testAtomicCommitPreservesExistingAccountsAndClearsPendingOnlyOnSuccess() throws {
        var vault = EnrollmentVault()
        let pending = try PendingEnrollment(qr: qr, connection: connection, installationID: vault.installationID)
        let old = credentials(pending, subject: "existing")
        vault.save(old)
        vault.pending = pending
        XCTAssertThrowsError(try vault.commit(credentials(pending), requestID: UUID()))
        XCTAssertEqual(vault.current?.subject, "existing")
        XCTAssertNotNil(vault.pending)
        let persisted = try JSONEncoder().encode(vault)
        var relaunched = try JSONDecoder().decode(EnrollmentVault.self, from: persisted)
        try relaunched.commit(credentials(pending), requestID: pending.requestID)
        XCTAssertEqual(relaunched.current?.subject, "account-one")
        XCTAssertEqual(relaunched.sessions.count, 2)
        XCTAssertNil(relaunched.pending)
        let account = try XCTUnwrap(relaunched.activeAccount)
        XCTAssertEqual(relaunched.deviceKeys[account], pending.privateKey)
        XCTAssertThrowsError(try relaunched.commit(credentials(pending), requestID: pending.requestID))
    }

    func testCrossInstallationAndNonceCommitRejectedWithoutDestroyingSession() throws {
        var vault = EnrollmentVault()
        let pending = try PendingEnrollment(qr: qr, connection: connection, installationID: UUID())
        vault.pending = pending
        XCTAssertThrowsError(try vault.commit(credentials(pending), requestID: pending.requestID))
        XCTAssertNotNil(vault.pending)
        vault.installationID = pending.installationID
        let wrongNonce = Credentials(
            connection: connection, subject: "one", nonce: "different", accessToken: "test",
            refreshToken: "test", expiresAt: .distantFuture)
        XCTAssertThrowsError(try vault.commit(wrongNonce, requestID: pending.requestID))
        XCTAssertNil(vault.current)
    }

    func testCanonicalChallengeSignatureAndSameKeyFreshChallengeRecovery() throws {
        let pending = try PendingEnrollment(qr: qr, connection: connection, installationID: UUID())
        let key = try P256.Signing.PrivateKey(rawRepresentation: pending.privateKey).publicKey
        for _ in 0..<2 {
            let id = UUID().uuidString.lowercased()
            let lines = [
                "nephos-qr-v1", origin, "nephos-ios", qr.inviteId, pending.requestID.uuidString.lowercased(),
                Hashing.base64URL(Data(SHA256.hash(data: try pending.publicKey))), id,
                Hashing.base64URL(Data(repeating: 12, count: 32)),
            ]
            let bytes = Data(lines.joined(separator: "\n").utf8)
            let signature = try pending.signature(challenge: Hashing.base64URL(bytes), challengeID: id)
            XCTAssertTrue(
                key.isValidSignature(
                    try P256.Signing.ECDSASignature(derRepresentation: EnrollmentQR.decode(signature)!), for: bytes))
            for index in 0..<lines.count {
                var altered = lines
                altered[index] = "attacker"
                XCTAssertThrowsError(
                    try pending.signature(
                        challenge: Hashing.base64URL(Data(altered.joined(separator: "\n").utf8)), challengeID: id))
            }
        }
    }

    func testRealQRCodeImageDecoderRejectsInvalidImageAndDecodesCredential() throws {
        let payload = try raw(fields)
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let framed = output.composited(
            over: CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -32, dy: -32)))
        func png(_ source: CIImage) throws -> Data {
            let image = try XCTUnwrap(CIContext().createCGImage(source, from: source.extent))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        XCTAssertEqual(try QRImageDecoder.payload(png(framed)), payload)
        XCTAssertEqual(
            try QRImageDecoder.payload(png(framed.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)))), payload)
        let shifted = framed.transformed(by: CGAffineTransform(translationX: framed.extent.width + 64, y: 0))
        let combined = framed.composited(over: shifted).composited(
            over: CIImage(color: .white).cropped(to: framed.extent.union(shifted.extent)))
        XCTAssertThrowsError(try QRImageDecoder.payload(png(combined)))
        XCTAssertThrowsError(try QRImageDecoder.payload(png(CIImage(color: .white).cropped(to: framed.extent))))
        XCTAssertThrowsError(try QRImageDecoder.payload(Data("not-an-image".utf8)))
        XCTAssertThrowsError(try QRImageDecoder.payload(Data(repeating: 0, count: 32 * 1024 * 1024 + 1)))
    }

    func testExplicitProviderErrors() {
        for code in [
            "invite_expired", "invite_used", "invite_cancelled", "user_disabled", "recovery_expired", "session_revoked",
            "invalid_proof", "temporarily_unavailable",
        ] {
            XCTAssertNotNil(QREnrollmentError.provider(code)?.errorDescription)
        }
        XCTAssertNil(QREnrollmentError.provider("arbitrary server content"))
    }
}
