import Foundation
import XCTest

@testable import NephosCore

private final class RecoveryProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
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
        let data = try await client.data(client.request("v1/libraries"))
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "{\"items\":[]}")
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
    func testUnauthenticated401DoesNotMeanTheSavedSessionWasRevoked() async throws {
        let client = api(RecoveryTokens())
        defer { client.invalidate() }
        do {
            _ = try await HTTP.data(HTTP.request(try client.endpoint("v1/config")), session: client.session)
            XCTFail("The configuration request must fail.")
        } catch ClientError.http(let status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    @MainActor
    func testTemporaryRefreshFailureDoesNotBecomeSignedOut() async throws {
        let tokens = RecoveryTokens()
        tokens.transientFailure = true
        let client = api(tokens)
        do {
            _ = try await client.data(client.request("v1/libraries"))
            XCTFail("The network failure must be surfaced.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
            XCTAssertFalse(client.invalidated)
        }
    }

    @MainActor
    func testExternalSignOutAndForbiddenAccessStateTransitions() async throws {
        let saved = Credentials(
            connection: Connection(
                baseURL: URL(string: "https://photos.example.test")!,
                config: ServerConfig(
                    serverId: "test", issuer: "https://photos.example.test/realms/nephos",
                    clientId: "nephos-ios", maxUploadBytes: nil, chunkSize: nil),
                allowDevelopmentHTTP: false),
            subject: "test-account", nonce: "test-nonce", accessToken: "access",
            refreshToken: "offline-refresh", expiresAt: .distantFuture)
        let store = RecoverySessionStorage(saved)
        let flag = RecoveryFlag()
        let model = SignInModel(
            store: store,
            validate: { _ in
                if flag.forbidden { throw ClientError.http(403, "Access was denied.") }
            })
        await model.restore()
        XCTAssertEqual(model.screen, .signedIn)
        XCTAssertFalse(model.hasUnfinishedEnrollment)
        XCTAssertTrue(model.accessDenied)

        flag.forbidden = false
        await model.restore()
        XCTAssertEqual(model.screen, .signedIn)
        XCTAssertFalse(model.accessDenied)
        XCTAssertTrue(model.message.isEmpty)

        await model.handleExternalSignOut()
        XCTAssertEqual(model.screen, .welcome)
        XCTAssertFalse(model.hasUnfinishedEnrollment)
        XCTAssertNil(try store.vault().current)
    }
}

@MainActor
private final class RecoveryFlag {
    var forbidden = true
}

@MainActor
private final class RecoverySessionStorage: SessionStorage {
    private var currentVault = EnrollmentVault()
    init(_ credentials: Credentials) { currentVault.save(credentials) }
    func vault() throws -> EnrollmentVault { currentVault }
    @discardableResult
    func update(_ change: @Sendable (inout EnrollmentVault) throws -> Void) throws -> EnrollmentVault {
        try change(&currentVault)
        return currentVault
    }
    func remove() throws { currentVault = EnrollmentVault() }
}
