import Foundation
import XCTest

@testable import NephosCore

private final class PinRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.path, "/realms/nephos/nephos-admin/request-pin")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bodyData.append(contentsOf: buffer.prefix(count))
            }
        }
        do {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: String])
            XCTAssertEqual(Set(payload.keys), ["email", "clientId"])
            XCTAssertEqual(payload["clientId"], "nephos-ios")
            XCTAssertEqual(payload["email"], request.value(forHTTPHeaderField: "X-Test-Email"))
        } catch { XCTFail("Invalid public PIN request payload: \(error)") }
        let email = request.value(forHTTPHeaderField: "X-Test-Email") ?? ""
        let status: Int
        switch email {
        case "unknown@example.test": status = 404
        case "wait@example.test": status = 429
        case "invalid@example.test": status = 400
        case "offline@example.test": status = 503
        default: status = 200
        }
        let body = Data((email == "expired@example.test" ? #"{"expiresIn":0}"# : #"{"expiresIn":1800}"#).utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LoginPinTests: XCTestCase {
    func testEmailIsNormalizedAndMalformedAddressesAreRejected() throws {
        XCTAssertEqual(try LoginPinPolicy.email("  Known.User+photo@Example.TEST \n"), "known.user+photo@example.test")
        for invalid in [
            "", "user", "user@", "@example.test", "user@@example.test", ".user@example.test",
            "user.@example.test", "u..ser@example.test", "user name@example.test",
            "user@example", "user@-example.test", "user@example-.test", "user@example..test",
            "user@exam_ple.test", "user@\u{00E9}xample.test", String(repeating: "x", count: 65) + "@example.test",
        ] {
            XCTAssertThrowsError(try LoginPinPolicy.email(invalid), invalid)
        }
    }

    func testReceiptHasBoundedExpiry() throws {
        for expiry in [1, 60, 1800] { try LoginPinReceipt(expiresIn: expiry).validate() }
        for expiry in [-1, 0, 1801, Int.max] {
            XCTAssertThrowsError(try LoginPinReceipt(expiresIn: expiry).validate())
        }

    }

    func testAccountAndRateLimitErrorsAreVisibleGuidanceNotHiddenTechnicalDetails() {
        for error in [LoginPinError.unknownAccount, .rateLimited, .invalidEmail, .expiredRequest] {
            let failure = OnboardingFailure(error, identity: true)
            XCTAssertEqual(failure.guidance, error.localizedDescription)
        }
    }

    func testRequestUsesIssuerAndNeverIncludesPINOrCredentials() async throws {
        let normalized = try LoginPinPolicy.email("Known@Example.test")
        let connection = connection()
        let session = session(email: normalized)
        defer { session.invalidateAndCancel() }
        let receipt = try await LoginPinClient.request(connection: connection, email: normalized, session: session)
        XCTAssertEqual(receipt.expiresIn, 1800)
    }

    func testUnknownDisabledAndRateLimitedRequestsCannotProduceAReceipt() async throws {
        for (email, message) in [
            ("unknown@example.test", "enabled known account"),
            ("wait@example.test", "Wait"),
            ("invalid@example.test", "rejected"),
            ("offline@example.test", "available"),
            ("expired@example.test", "invalid PIN expiry"),
        ] {
            let session = session(email: email)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await LoginPinClient.request(connection: connection(), email: email, session: session)
                XCTFail("Rejected request must not advance to PIN input.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription)
            }
        }
    }

    private func connection() -> Connection {
        Connection(
            baseURL: URL(string: "https://photos.example.test")!,
            config: ServerConfig(
                serverId: "test", issuer: "https://photos.example.test/realms/nephos", clientId: "nephos-ios",
                maxUploadBytes: 100, chunkSize: 4_194_304),
            allowDevelopmentHTTP: false)
    }

    private func session(email: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PinRequestProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Email": email]
        return URLSession(configuration: configuration)
    }
}
