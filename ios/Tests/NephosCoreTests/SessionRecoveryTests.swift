import Foundation
import XCTest

@testable import NephosCore

private final class RecoveryProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed"
        let status = request.url?.path == "/revoked" ? 401 : authorized ? 200 : 401
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"items\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class RecoveryTokens: AccessTokenProviding {
    var recoveries = 0
    var transientFailure = false
    func accessToken() async throws -> String { "expired" }
    func recoverAccessToken(rejected: String) async throws -> String {
        XCTAssertEqual(rejected, "expired")
        recoveries += 1
        if transientFailure { throw URLError(.notConnectedToInternet) }
        return "refreshed"
    }
}

final class SessionRecoveryTests: XCTestCase {
    @MainActor
    private func api(_ tokens: RecoveryTokens) -> API {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryProtocol.self]
        return API(
            connection: Connection(
                baseURL: URL(string: "http://recovery.invalid")!,
                config: ServerConfig(
                    serverId: "fixture", issuer: "https://identity.invalid", clientId: "fixture",
                    maxUploadBytes: 1000, chunkSize: 100), allowDevelopmentHTTP: true),
            auth: tokens, session: URLSession(configuration: configuration))
    }

    @MainActor
    func testExpiredAccessTokenRefreshesAndRetriesWithoutInvalidatingSession() async throws {
        let tokens = RecoveryTokens()
        let client = api(tokens)
        let page = try await client.libraries()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(tokens.recoveries, 1)
        XCTAssertFalse(client.invalidated)
    }

    @MainActor
    func testRevokedSessionStopsAfterOneRefreshAttempt() async throws {
        let tokens = RecoveryTokens()
        let client = api(tokens)
        do {
            _ = try await client.data(client.request("revoked"))
            XCTFail("Revoked access must not succeed.")
        } catch ClientError.signedOut {
            XCTAssertEqual(tokens.recoveries, 1)
        }
    }

    @MainActor
    func testTemporaryRefreshFailureDoesNotBecomeSignedOut() async throws {
        let tokens = RecoveryTokens()
        tokens.transientFailure = true
        let client = api(tokens)
        do {
            _ = try await client.libraries()
            XCTFail("The network failure must be surfaced.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
            XCTAssertFalse(client.invalidated)
        }
    }
}
