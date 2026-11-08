import Foundation
import XCTest

@testable import NephosCore

@MainActor
private final class MemorySessionStorage: SessionStorage {
    var data: Data
    var readFails = false
    var writeFails = false

    init(_ credentials: Credentials?) throws {
        var vault = EnrollmentVault()
        if let credentials { vault.save(credentials) }
        data = try JSONEncoder().encode(vault)
    }

    func vault() throws -> EnrollmentVault {
        if readFails { throw ClientError.invalid("Keychain locked") }
        return try JSONDecoder().decode(EnrollmentVault.self, from: data)
    }

    @discardableResult
    func update(_ change: @Sendable (inout EnrollmentVault) throws -> Void) throws -> EnrollmentVault {
        if writeFails { throw ClientError.invalid("Keychain write failed") }
        var value = try vault()
        try change(&value)
        data = try JSONEncoder().encode(value)
        return value
    }

    func remove() throws {
        if writeFails { throw ClientError.invalid("Keychain delete failed") }
        data = try JSONEncoder().encode(EnrollmentVault())
    }
}

@MainActor
private final class RenewalState {
    var offline = true
}

final class SessionPersistenceTests: XCTestCase {
    private func credentials(expiry: Date = .distantPast) -> Credentials {
        Credentials(
            connection: Connection(
                baseURL: URL(string: "https://photos.example.test")!,
                config: ServerConfig(
                    serverId: "test", issuer: "https://photos.example.test/realms/nephos",
                    clientId: "nephos-ios", maxUploadBytes: nil, chunkSize: nil),
                allowDevelopmentHTTP: false),
            subject: "test-account", nonce: "test-nonce", accessToken: "old-access",
            refreshToken: "offline-refresh", expiresAt: expiry)
    }

    func testOnlyDefinitiveInvalidGrantRequiresSignInAgain() throws {
        for reason in ["Offline user session not found", "Refresh token expired"] {
            let data = try JSONSerialization.data(
                withJSONObject: ["error": "invalid_grant", "error_description": reason])
            XCTAssertThrowsError(try OAuthResponse.tokens(data, status: 400)) {
                guard case ClientError.signedOut = $0 else {
                    return XCTFail("Must invalidate the rejected refresh token")
                }
            }
        }
        for reason in ["DPoP proof is missing", "Token is not active", "Unrecognized failure", ""] {
            let data = try JSONSerialization.data(
                withJSONObject: ["error": "invalid_grant", "error_description": reason])
            XCTAssertThrowsError(try OAuthResponse.tokens(data, status: 400)) {
                guard case ClientError.http = $0 else {
                    return XCTFail("Unknown or proof failures must preserve sessions")
                }
            }
        }
        for status in [400, 401, 403, 429, 500, 503] {
            XCTAssertThrowsError(
                try OAuthResponse.tokens(Data(#"{"error":"temporarily_unavailable"}"#.utf8), status: status)
            ) {
                guard case ClientError.http = $0 else { return XCTFail("Must preserve credentials on service errors") }
            }
        }
    }

    @MainActor
    func testRefreshIsSavedAndReusedAfterColdLaunch() async throws {
        let saved = credentials()
        let store = try MemorySessionStorage(saved)
        var calls = 0
        let renew: @MainActor (Credentials) async throws -> Credentials = { previous in
            calls += 1
            XCTAssertEqual(previous.refreshToken, "offline-refresh")
            var value = previous
            value.accessToken = "new-access"
            value.refreshToken = "new-refresh"
            value.expiresAt = Date().addingTimeInterval(300)
            return value
        }
        let first = AuthSession(credentials: saved, store: store, renew: renew)
        let access = try await first.accessToken()
        XCTAssertEqual(access, "new-access")
        let restored = try XCTUnwrap(store.vault().current)
        XCTAssertEqual(restored.refreshToken, "new-refresh")
        let relaunched = AuthSession(credentials: restored, store: store, renew: renew)
        let second = try await relaunched.accessToken()
        XCTAssertEqual(second, "new-access")
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testConcurrentRequestsShareRefreshAndCannotResurrectAfterSignOut() async throws {
        let saved = credentials()
        let store = try MemorySessionStorage(saved)
        var completion: CheckedContinuation<Credentials, Error>?
        var calls = 0
        let auth = AuthSession(credentials: saved, store: store) { previous in
            calls += 1
            return try await withCheckedThrowingContinuation { completion = $0 }
        }
        let first = Task { try await auth.accessToken() }
        let second = Task { try await auth.accessToken() }
        while completion == nil { await Task.yield() }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        try await auth.signOut()
        var renewed = saved
        renewed.accessToken = "late-response"
        renewed.expiresAt = .distantFuture
        completion?.resume(returning: renewed)
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("A cancelled refresh must not restore a signed-out session")
            } catch is CancellationError {}
        }
        XCTAssertNil(try store.vault().current)
        XCTAssertNil(auth.credentials)
    }

    @MainActor
    func testOfflineColdLaunchKeepsSessionAndRetryDoesNotNeedQR() async throws {
        let store = try MemorySessionStorage(credentials())
        let state = RenewalState()
        let model = SignInModel(
            store: store,
            renew: { previous in
                if state.offline { throw URLError(.notConnectedToInternet) }
                var result = previous
                result.expiresAt = .distantFuture
                return result
            },
            validate: { session in _ = try await session.accessToken() })
        XCTAssertEqual(model.screen, .restoring)
        await model.restore()
        XCTAssertEqual(model.screen, .recovery)
        XCTAssertNotNil(try store.vault().current)
        state.offline = false
        await model.restore()
        XCTAssertEqual(model.screen, .signedIn)
        XCTAssertEqual(model.serverName, "photos.example.test")
    }

    @MainActor
    func testRevocationReturnsToWelcomeAndClearsSavedSession() async throws {
        let store = try MemorySessionStorage(credentials(expiry: .distantFuture))
        let model = SignInModel(store: store, validate: { _ in throw ClientError.signedOut })
        await model.restore()
        XCTAssertEqual(model.screen, .welcome)
        XCTAssertFalse(model.message.isEmpty)
        XCTAssertNil(try store.vault().current)
    }

    @MainActor
    func testLockedKeychainDoesNotPretendUserHasSignedOut() async throws {
        let store = try MemorySessionStorage(credentials(expiry: .distantFuture))
        store.readFails = true
        let model = SignInModel(store: store, validate: { _ in })
        await model.restore()
        XCTAssertEqual(model.screen, .recovery)
        store.readFails = false
        await model.restore()
        XCTAssertEqual(model.screen, .signedIn)
        store.writeFails = true
        await model.signOut()
        XCTAssertEqual(model.screen, .recovery)
        XCTAssertNotNil(try store.vault().current)
        XCTAssertTrue(model.message.contains("delete failed"))
    }

    @MainActor
    func testRefreshPersistenceFailureKeepsOldCredentialsForRetry() async throws {
        let saved = credentials()
        let store = try MemorySessionStorage(saved)
        store.writeFails = true
        let auth = AuthSession(credentials: saved, store: store) { previous in
            var result = previous
            result.accessToken = "renewed"
            result.expiresAt = .distantFuture
            return result
        }
        do {
            _ = try await auth.accessToken()
            XCTFail("Must report failure to persist the renewed session")
        } catch ClientError.invalid {}
        XCTAssertEqual(auth.credentials?.accessToken, "old-access")
        XCTAssertEqual(try store.vault().current?.accessToken, "old-access")
        store.writeFails = false
        let result = try await auth.accessToken()
        XCTAssertEqual(result, "renewed")
    }

    @MainActor
    func testBoundKeyRestoresWithoutReplacementAndMissingKeyKeepsCredentials() async throws {
        let key = DPoPKey(signingKey: try DeviceSigningKey.generate())
        var saved = credentials()
        saved.dpopKeyThumbprint = try key.thumbprint
        let bound = saved
        let store = try MemorySessionStorage(bound)
        let account = AccountIdentity.key(connection: bound.connection, subject: bound.subject)
        try store.update { $0.deviceKeys[account] = key.signingKey.persisted }
        let restored = try await AuthSession.proofKey(for: bound, store: store)
        XCTAssertEqual(try restored?.thumbprint, bound.dpopKeyThumbprint)
        var downgraded = bound
        downgraded.dpopKeyThumbprint = nil
        let replacement = downgraded
        XCTAssertThrowsError(try store.update { try $0.refresh(replacement, previous: bound) })
        try store.update { $0.deviceKeys[account] = nil }
        do {
            _ = try await AuthSession.proofKey(for: bound, store: store)
            XCTFail("Missing keys must not be regenerated or retried as bearer credentials")
        } catch ClientError.invalid {}
        XCTAssertEqual(try store.vault().current?.dpopKeyThumbprint, bound.dpopKeyThumbprint)
        XCTAssertEqual(try store.vault().current?.refreshToken, bound.refreshToken)
    }

    @MainActor
    func testLegacyCredentialsDoNotAutomaticallyAdoptEnrollmentKey() async throws {
        let saved = credentials()
        let store = try MemorySessionStorage(saved)
        let account = AccountIdentity.key(connection: saved.connection, subject: saved.subject)
        let key = try DeviceSigningKey.generate()
        try store.update { $0.deviceKeys[account] = key.persisted }
        let proof = try await AuthSession.proofKey(for: saved, store: store)
        XCTAssertNil(proof)
        let restored = try XCTUnwrap(store.vault().current)
        XCTAssertNil(restored.dpopKeyThumbprint)
        XCTAssertNil(restored.connection.persistentLogin)
    }

    @MainActor
    func testEnrollmentProofAndConfigurationErrorsPreserveRecoveryKey() async throws {
        let connection = credentials().connection
        let qr = EnrollmentQR(
            v: 1, origin: connection.baseURL.absoluteString, inviteId: UUID().uuidString.lowercased(),
            secret: Hashing.base64URL(Data(repeating: 3, count: 32)))
        for error in [
            QREnrollmentError.invalidRequest, .invalidProof, .invalidChallenge, .invalidScope, .unavailable,
        ] {
            let store = try MemorySessionStorage(nil)
            let pending = try PendingEnrollment(
                qr: qr, connection: connection, installationID: store.vault().installationID)
            try store.update { $0.pending = pending }
            let model = SignInModel(
                store: store, connect: { _ in connection }, exchange: { _ in throw error }, validate: { _ in })
            await model.restore()
            XCTAssertEqual(model.screen, .recovery)
            XCTAssertEqual(try store.vault().pending?.requestID, pending.requestID)
            XCTAssertEqual(try store.vault().pending?.privateKey, pending.privateKey)
        }
    }

    @MainActor
    func testRemoteSignOutCannotSilentlyDiscardUnfinishedEnrollment() async throws {
        let store = try MemorySessionStorage(nil)
        let connection = credentials().connection
        let qr = EnrollmentQR(
            v: 1, origin: connection.baseURL.absoluteString, inviteId: UUID().uuidString.lowercased(),
            secret: Hashing.base64URL(Data(repeating: 3, count: 32)))
        let pending = try PendingEnrollment(
            qr: qr, connection: connection, installationID: store.vault().installationID)
        try store.update { $0.pending = pending }
        let model = SignInModel(store: store, validate: { _ in })
        await model.signOut(remotely: true)
        XCTAssertEqual(model.screen, .recovery)
        XCTAssertTrue(model.message.contains("not confirmed"))
        XCTAssertEqual(try store.vault().pending?.requestID, pending.requestID)
        await model.signOut()
        XCTAssertEqual(model.screen, .welcome)
        XCTAssertNil(try store.vault().pending)
        XCTAssertTrue(model.message.contains("not revoked"))
    }
}
