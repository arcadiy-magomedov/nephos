#if UI_QUALIFICATION
    import CryptoKit
    import Foundation
    import Security

    enum QRNativeQualification {
        static func checkPersistence() throws {
            guard Bundle.main.bundleIdentifier == "app.nephos.ui-qualification" else {
                throw ClientError.invalid("Qualification must use its isolated application.")
            }
            try Keychain.remove()
            let qr = EnrollmentQR(
                v: 1, origin: "https://native.example.test", inviteId: UUID().uuidString.lowercased(),
                secret: Hashing.base64URL(Data(repeating: 11, count: 32)))
            let connection = Connection(
                baseURL: URL(string: qr.origin)!,
                config: ServerConfig(
                    serverId: "native-tests", issuer: qr.origin + "/realms/nephos", clientId: "nephos-ios",
                    maxUploadBytes: 8_589_934_592, chunkSize: 4_194_304), allowDevelopmentHTTP: false)
            let legacy = Credentials(
                connection: connection, subject: "legacy", nonce: "legacy-nonce", accessToken: "qualification-only",
                refreshToken: "qualification-only", expiresAt: .distantFuture)
            let status = SecItemAdd(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "app.nephos.ios.session",
                    kSecAttrAccount as String: "current",
                    kSecValueData as String: try JSONEncoder().encode(legacy),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ] as CFDictionary, nil)
            guard status == errSecSuccess, try Keychain.load()?.subject == "legacy" else {
                throw ClientError.invalid("Legacy session did not migrate.")
            }
            let first = try Keychain.prepare(qr: qr, connection: connection)
            let resumed = try Keychain.prepare(qr: qr, connection: connection)
            guard first.requestID == resumed.requestID, first.privateKey == resumed.privateKey,
                first.nonce == resumed.nonce, try Keychain.load()?.subject == "legacy"
            else { throw ClientError.invalid("Lost-response recovery changed key or signed out the existing account.") }
            do {
                try Keychain.commit(legacy, requestID: UUID())
                throw ClientError.invalid("An unrelated request committed.")
            } catch QREnrollmentError.invalidProof {}
            try Keychain.cancelEnrollment()
            guard try Keychain.load()?.subject == "legacy", try Keychain.vault().pending == nil else {
                throw ClientError.invalid("Cancellation destroyed the existing account.")
            }
            let fresh = try Keychain.prepare(qr: qr, connection: connection)
            let proofKey = DPoPKey(signingKey: DeviceSigningKey(persisted: fresh.privateKey))
            let credentials = Credentials(
                connection: connection, subject: "new-account", nonce: fresh.nonce,
                accessToken: "qualification-only", refreshToken: "qualification-only", expiresAt: .distantFuture,
                dpopKeyThumbprint: try proofKey.thumbprint)
            try Keychain.commit(credentials, requestID: fresh.requestID)
            let vault = try Keychain.vault()
            guard vault.sessions.count == 2, vault.current?.subject == "new-account", vault.pending == nil,
                let account = vault.activeAccount, vault.deviceKeys[account] == fresh.privateKey,
                vault.current?.dpopKeyThumbprint == credentials.dpopKeyThumbprint
            else { throw ClientError.invalid("The token and account-bound device key commit was not atomic.") }
            do {
                try Keychain.refresh(legacy, previous: legacy)
                throw ClientError.invalid("An old account's refresh replaced the newly enrolled account.")
            } catch is CancellationError {}
            try Keychain.remove()
        }
    }
#endif
