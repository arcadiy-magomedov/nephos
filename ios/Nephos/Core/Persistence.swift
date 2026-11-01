import Foundation

/// Synchronous worker methods deliberately never suspend: a completed write is durable,
/// and revisions prevent an older caller from overwriting a newer durable snapshot.
actor AccountPersistence {
    struct Bootstrap: Sendable {
        let connection: Connection?
        let newInstallation: Bool
    }

    private let root: URL
    private var ledgerRevisions: [String: UInt64] = [:]
    private var galleryRevisions: [String: UInt64] = [:]
    private var connectionRevision: UInt64 = 0
    private var viewerRevision: UInt64 = 0

    init(root: URL) {
        self.root = root
    }

    private func store() throws -> LedgerStore {
        try LedgerStore(root: root.appendingPathComponent("Accounts", isDirectory: true))
    }

    func bootstrap() throws -> Bootstrap {
        #if os(iOS)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = root
        try directory.setResourceValues(values)
        _ = try store()
        let file = root.appendingPathComponent("connection.json")
        let connection =
            FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Connection.self, from: Data(contentsOf: file)) : nil
        try resetViewerFiles()
        return Bootstrap(
            connection: connection,
            newInstallation: !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("installation").path))
    }

    func markInstallation() throws {
        try Data(UUID().uuidString.utf8).write(
            to: root.appendingPathComponent("installation"), options: .atomic)
    }

    func saveConnection(_ connection: Connection?, revision: UInt64) throws {
        guard revision > connectionRevision else { return }
        let file = root.appendingPathComponent("connection.json")
        if let connection {
            try JSONEncoder().encode(connection).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        connectionRevision = revision
    }

    func load(account: String, offline: Bool) throws -> AccountLedger {
        let store = try store()
        var loaded = try store.load(account: account)
        var changed = loaded.resumePhotosNetworkFailures()
        if !offline, loaded.resumeLegacyPhotoKitPublications() { changed = true }
        if loaded.settings.onboardingCompleted == nil {
            loaded.settings.onboardingCompleted = OnboardingPolicy.completed(
                settings: loaded.settings, selectedLibrary: loaded.selectedLibraryID,
                hasResources: !loaded.records.isEmpty || loaded.resourceSets?.isEmpty == false)
            changed = true
        }
        if changed { try store.save(loaded, account: account) }
        return loaded
    }

    func save(_ ledger: AccountLedger, account: String, revision: UInt64) throws {
        guard revision > (ledgerRevisions[account] ?? 0) else { return }
        try store().save(ledger, account: account)
        ledgerRevisions[account] = revision
    }

    func loadGallery(account: String, library: UUID) throws -> RetainedGallery? {
        try store().loadGallery(account: account, library: library)
    }

    func saveGallery(_ cache: RetainedGallery?, account: String, revision: UInt64) throws {
        guard revision > (galleryRevisions[account] ?? 0) else { return }
        let store = try store()
        if let cache {
            try store.saveGallery(cache, account: account)
        } else {
            try store.clearGallery(account: account)
        }
        galleryRevisions[account] = revision
    }

    func resetViewer(revision: UInt64) throws {
        guard revision > viewerRevision else { return }
        try resetViewerFiles()
        viewerRevision = revision
    }

    private func resetViewerFiles() throws {
        let viewer = root.appendingPathComponent("Viewer", isDirectory: true)
        if FileManager.default.fileExists(atPath: viewer.path) {
            try FileManager.default.removeItem(at: viewer)
        }
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
    }

    func staging(account: String, id: UUID) throws -> URL {
        try store().staging(account: account, id: id)
    }

    func chunk(account: String, id: UUID, part: Int) throws -> URL {
        try store().chunk(account: account, id: id, part: part)
    }

    func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    func remove(_ file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func exportBudget(maximum: Int64, partReserve: Int64) throws -> Int64 {
        let free =
            try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        let budget = min(
            maximum, LedgerStore.stagingBudget - (try store().usedBytes()) - partReserve,
            free - max(64 * 1024 * 1024, partReserve))
        guard budget > 0 else {
            throw ClientError.invalid(
                "Staging is full or device storage is low. Pending originals are preserved; no new export was started.")
        }
        return budget
    }

    func pruneOrphanStaging(account: String, ledger: AccountLedger) throws {
        let directory = try store().accountDirectory(account)
        let expected = Set(
            ledger.records.filter { $0.phase != .ready || $0.evidence == nil }.map {
                $0.id.uuidString.lowercased() + ".original"
            })
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if file.pathExtension == "part"
                || (file.pathExtension == "original" && !expected.contains(file.lastPathComponent))
            {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
