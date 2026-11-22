import Foundation

actor UploadAuthorization {
    private let expectedAccount: String
    private let store: any SessionStorage
    private var renewal: Task<Credentials, Error>?

    init(account: String, store: any SessionStorage = KeychainStorage()) {
        expectedAccount = account
        self.store = store
    }

    func credentials(forceRefresh: Bool = false) async throws -> Credentials {
        let vault = try await store.vault()
        guard vault.activeAccount == expectedAccount, let saved = vault.current,
            AccountIdentity.key(connection: saved.connection, subject: saved.subject) == expectedAccount
        else { throw CancellationError() }
        if let renewal { return try await renewal.value }
        if !forceRefresh, saved.expiresAt.timeIntervalSinceNow > 60 { return saved }
        let store = self.store
        let task = Task { @concurrent in
            let updated = try await AuthSession.renewCredentials(saved, store: store)
            try await store.update { try $0.refresh(updated, previous: saved) }
            return updated
        }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }
}
