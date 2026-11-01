import BackgroundTasks
import Foundation
import Observation
import Photos
import UIKit

@MainActor @Observable
final class AppModel {
    var connection: Connection?
    var proposedConnection: Connection?
    var signedIn = false
    var needsReauthentication = false
    var libraries: [Library] = []
    var libraryCursor: UUID?
    var ledger = AccountLedger()
    var gallery = GalleryWindow()
    var retainedGallery: RetainedGallery?
    var galleryIsStale = false
    var galleryRefreshError: String?
    var galleryAtTop = true
    var visibleAnchor: UUID?
    var scrollTarget: UUID?
    var timeline: [TimelineBucket] = []
    var timelineYear: Int?
    var timelineMonth: Int?
    var timelineError: String?
    var mediaGeneration = UUID()
    var photosGeneration = UUID()
    var message: String?
    var activity = ""
    var backupNotice: String?
    var backupDiagnostic: String?
    var isRunning = false
    var isSigningIn = false
    var isLoadingGallery = false
    var isDeletingMedia = false
    var trashItems: [TrashItem] = []
    var trashCursor: TrashCursor?
    var trashLoaded = false
    var isLoadingTrash = false
    var trashLoadError: String?
    var isRestoringTrash = false
    var trashRestoreCompleted = 0
    var trashRestoreTotal = 0
    var trashRestoreFailures: [UUID: String] = [:]
    var trashRestoreNotice: String?
    private var trashEpoch: UUID?
    var showCleanupConfirmation = false
    var photosStatus = "Photos access has not been requested."
    var cleanupReport = ""
    private(set) var account: String?
    private(set) var api: API?
    private(set) var epoch = UUID()
    let photos = PhotosLibrary()
    private var auth: AuthSession
    private var store: LedgerStore?
    private var root: URL
    private var networkObserver: NSObjectProtocol?
    private var automaticTask: Task<Void, Never>?
    private var automaticRunID: UUID?
    var activeBackupItems: Set<UUID> = []
    private let retryWakeup = BackupRetryWakeup()
    private let preparation = BackupPreparation()
    private var backupAccessBlocked = false
    private var galleryLoadID = UUID()
    private var mediaMutationGeneration = UUID()

    private func beginMediaMutation() {
        mediaMutationGeneration = UUID()
        galleryLoadID = UUID()
        isLoadingGallery = false
    }

    private func resetTrash() {
        trashItems = []
        trashCursor = nil
        trashLoaded = false
        isLoadingTrash = false
        trashLoadError = nil
        isRestoringTrash = false
        trashRestoreFailures = [:]
        trashRestoreNotice = nil
        trashEpoch = nil
        isDeletingMedia = false
    }

    func loadTrash(reset: Bool = false) async {
        if trashEpoch != epoch {
            resetTrash()
            trashEpoch = epoch
        }
        guard !isLoadingTrash, !isRestoringTrash, let api else { return }
        let version = epoch
        let boundary = account
        isLoadingTrash = true
        trashLoadError = nil
        defer { if version == epoch { isLoadingTrash = false } }
        do {
            let page = try await api.trash(before: reset ? nil : trashCursor)
            try check(version)
            guard boundary == account else { throw CancellationError() }
            let previous = reset ? [] : trashItems
            let known = Set(previous.map(\.id))
            trashItems = previous + page.items.filter { !known.contains($0.id) }
            trashCursor = page.nextCursor
            trashLoaded = true
        } catch is CancellationError {
        } catch {
            guard version == epoch, boundary == account else { return }
            trashLoadError = "Trash could not be loaded. \(error.localizedDescription)"
            handle(error, notify: false)
        }
    }

    func restoreTrash(_ ids: Set<UUID>) async {
        guard !isRestoringTrash, !isLoadingTrash, !isDeletingMedia, let api,
            trashEpoch == epoch, !ids.isEmpty
        else { return }
        let version = epoch
        let boundary = account
        let items = trashItems.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        isRestoringTrash = true
        beginMediaMutation()
        trashRestoreCompleted = 0
        trashRestoreTotal = items.count
        trashRestoreFailures = [:]
        trashRestoreNotice = nil
        var operationFinished = false
        defer { if !operationFinished && version == epoch { isRestoringTrash = false } }
        for item in items {
            do {
                try check(version)
                guard boundary == account else { throw CancellationError() }
                try await api.restoreAsset(item.id)
                try check(version)
                guard boundary == account else { throw CancellationError() }
                trashItems.removeAll {
                    $0.id == item.id || (item.asset.resourceSetId != nil && $0.asset.resourceSetId == item.asset.resourceSetId)
                }
                for index in ledger.records.indices where ledger.records[index].committedAssetID == item.id
                    || (item.asset.resourceSetId != nil && ledger.records[index].resourceSetId == item.asset.resourceSetId)
                {
                    ledger.records[index].remoteRemoved = nil
                }
                trashRestoreCompleted += 1
            } catch is CancellationError {
                return
            } catch {
                guard version == epoch, boundary == account else { return }
                if case ClientError.http(409, _) = error {
                    trashRestoreFailures[item.id] = "The retention deadline passed or permanent deletion has started."
                } else {
                    trashRestoreFailures[item.id] = error.localizedDescription
                }
                if case ClientError.signedOut = error { handle(error, notify: false) }
                guard version == epoch else { return }
            }
        }
        do {
            try persist()
        } catch {
            trashRestoreNotice = "Restored \(trashRestoreCompleted) of \(trashRestoreTotal) on the server; "
                + "\(trashRestoreFailures.count) failed. Local backup status could not be saved: \(error.localizedDescription)"
        }
        if trashRestoreNotice == nil {
            trashRestoreNotice = trashRestoreFailures.isEmpty
                ? "\(trashRestoreCompleted) item(s) restored."
                : "Restored \(trashRestoreCompleted) of \(trashRestoreTotal). \(trashRestoreFailures.count) failed."
        }
        operationFinished = true
        isRestoringTrash = false
        if trashItems.isEmpty && trashCursor != nil { await loadTrash() }
        guard version == epoch, boundary == account else { return }
        await loadGallery(reset: true, notifyErrors: false)
    }

    func deleteMediaEverywhere(assetIDs: Set<UUID>, localIdentifiers: Set<String>) async throws
        -> MediaDeletionResult
    {
        guard !isRunning, activeBackupItems.isEmpty, !isDeletingMedia, !isRestoringTrash, let api else {
            throw ClientError.invalid("Wait for backup or restoration to finish before deleting. Nothing was deleted.")
        }
        let version = epoch
        let boundary = account
        isDeletingMedia = true
        beginMediaMutation()
        var operationFinished = false
        defer { if !operationFinished && version == epoch { isDeletingMedia = false } }
        let transfers = await BackgroundTransfers.shared.activeTasks()
        try check(version)
        guard boundary == account else { throw CancellationError() }
        guard !transfers.contains(where: { $0.taskDescription?.hasPrefix((boundary ?? "") + "/") == true }) else {
            throw ClientError.invalid("A system upload is still finishing. Retry deletion after backup finishes.")
        }
        let remoteIDs = ledger.deletionAssets(assetIDs: assetIDs, localIdentifiers: localIdentifiers)
        let records = ledger.records
        let previous = ledger
        ledger.suppressDeletion(assetIDs: remoteIDs, localIdentifiers: localIdentifiers)
        do {
            try persist()
        } catch {
            ledger = previous
            throw ClientError.invalid("Could not save backup suppression. Nothing was deleted. \(error.localizedDescription)")
        }
        var result = MediaDeletionResult()
        for id in remoteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try check(version)
            guard boundary == account else { throw CancellationError() }
            do {
                try await api.deleteAsset(id)
                try check(version)
                guard boundary == account else { throw CancellationError() }
                result.deleted.insert(id)
                gallery.remove([id])
                retainedGallery?.window.remove([id])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try check(version)
                guard boundary == account else { throw CancellationError() }
                if case ClientError.signedOut = error {
                    handle(error, notify: false)
                    throw CancellationError()
                }
                result.failed[id] = error.localizedDescription
            }
        }
        let safeLocal = localIdentifiers.filter { identifier in
            !records.contains {
                $0.source.localIdentifier == identifier && result.failed[$0.committedAssetID] != nil
            }
        }
        try check(version)
        guard boundary == account else { throw CancellationError() }
        if !safeLocal.isEmpty {
            do {
                try await photos.deleteFromPhotos(Array(safeLocal))
                try check(version)
                guard boundary == account else { throw CancellationError() }
                result.removedLocal = safeLocal
                photosGeneration = UUID()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try check(version)
                guard boundary == account else { throw CancellationError() }
                result.photosError = error.localizedDescription
            }
        }
        if let retainedGallery, let store, let boundary {
            do {
                try store.saveGallery(retainedGallery, account: boundary)
            } catch {
                result.localStatusError = error.localizedDescription
            }
        }
        operationFinished = true
        isDeletingMedia = false
        await loadGallery(reset: true, notifyErrors: false)
        try check(version)
        return result
    }

    var selectedLibrary: Library? { libraries.first { $0.id == ledger.selectedLibraryID } }
    var needsOnboarding: Bool { signedIn && ledger.settings.onboardingCompleted == false }
    var subject: String? {
        #if UI_QUALIFICATION
            return qualificationSubject ?? activeAuth?.subject
        #else
            return activeAuth?.subject
        #endif
    }
    #if UI_QUALIFICATION
        private var qualificationSubject: String?
        convenience init(qualificationAPI: API, subject: String, library: Library) {
            precondition(Bundle.main.bundleIdentifier == "app.nephos.ui-qualification")
            self.init()
            self.connection = qualificationAPI.connection
            self.qualificationSubject = subject
            self.account = LedgerStore.accountKey(connection: qualificationAPI.connection, subject: subject)
            self.api = qualificationAPI
            self.libraries = [library]
            self.ledger = AccountLedger()
            self.ledger.selectedLibraryID = library.id
            self.signedIn = true
        }
    #endif
    var recentUploads: [UploadRecord] {
        Array(ledger.records.filter { $0.libraryId == ledger.selectedLibraryID }.suffix(100).reversed())
    }
    private var allBackupItems: [BackupItem] {
        let records = ledger.records.filter { $0.libraryId == ledger.selectedLibraryID }
        let grouped = Dictionary(grouping: records, by: \.resourceSetId)
        let groups = (ledger.resourceSets ?? []).filter { $0.libraryId == ledger.selectedLibraryID }
        let groupIDs = Set(groups.map(\.id))
        var items = groups.map { BackupItem(id: $0.id, source: $0.source, group: $0, records: grouped[$0.id] ?? []) }
        items += records.filter { $0.resourceSetId.map { !groupIDs.contains($0) } ?? true }
            .map { BackupItem(id: $0.id, source: $0.source, group: nil, records: [$0]) }
        return items
    }
    var backupItems: [BackupItem] {
        Array(
            allBackupItems.sorted {
                if $0.isSaved != $1.isSaved { return !$0.isSaved }
                if $0.isStopped != $1.isStopped { return $0.isStopped }
                let first = $0.source.creationTime ?? $0.source.modificationTime
                let second = $1.source.creationTime ?? $1.source.modificationTime
                return first == second ? $0.id.uuidString < $1.id.uuidString : first > second
            }.prefix(100))
    }
    var backupItemCounts: (saved: Int, remaining: Int) {
        let items = allBackupItems
        let saved = items.filter(\.isSaved).count
        return (saved, items.count - saved)
    }
    func backupItem(_ id: UUID) -> BackupItem? { allBackupItems.first { $0.id == id } }
    func isActive(_ item: BackupItem) -> Bool {
        activeBackupItems.contains(item.id) || item.records.contains { activeBackupItems.contains($0.id) }
    }
    var cleanupCandidates: [UploadRecord] {
        ledger.records.filter { record in
            record.phase == .ready && record.source.cleanupSupported && record.remoteRemoved != true
                && (record.resourceSetId == nil
                    || ledger.resourceSets?.contains(where: { $0.id == record.resourceSetId && $0.manifest != nil })
                        == true)
                && record.cleanupState != "removed" && record.libraryId == ledger.selectedLibraryID
        }
    }
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nephos", isDirectory: true)
        auth = AuthSession()
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            let marker = root.appendingPathComponent("installation")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Keychain.remove()
                try Data(UUID().uuidString.utf8).write(to: marker, options: .atomic)
            }
            store = try LedgerStore(root: root.appendingPathComponent("Accounts", isDirectory: true))
            let file = root.appendingPathComponent("connection.json")
            if FileManager.default.fileExists(atPath: file.path) {
                connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: file))
            }
            if let credentials = try Keychain.load(), credentials.connection == connection {
                restoredCredentials = credentials
            }
            // Originals/previews are deliberately ephemeral; only upload staging survives launch.
            let viewer = root.appendingPathComponent("Viewer", isDirectory: true)
            try? FileManager.default.removeItem(at: viewer)
            try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        } catch {
            message = "Local state could not be loaded: \(error.localizedDescription). Existing files were preserved."
        }
        photos.onChange = { [weak self] in
            guard let self else { return }
            self.photosGeneration = UUID()
            self.updatePhotosStatus()
            self.scheduleAutomaticRun()
        }
        BackgroundTransfers.shared.onOrphanCompletion = { [weak self] in self?.scheduleAutomaticRun() }
        updatePhotosStatus()
    }
    private var restoredCredentials: Credentials?

    func restore() async {
        guard let restoredCredentials else { return }
        self.restoredCredentials = nil
        do {
            try await establish(AuthSession(credentials: restoredCredentials))
            scheduleAutomaticRun()
        } catch { handle(error) }
    }
    private var activeAuth: AuthSession?
    private func establish(_ session: AuthSession) async throws {
        guard let connection, let subject = session.subject, let store else {
            throw ClientError.invalid("No valid server/account storage is configured.")
        }
        let startingEpoch = epoch
        _ = try URLPolicy.validate(
            connection.baseURL.absoluteString, allowDevelopmentHTTP: AuthSession.developmentHTTP(connection))
        var offline = false
        let freshConfig: ServerConfig
        do {
            freshConfig = try await HTTP.json(
                ServerConfig.self, HTTP.request(connection.baseURL.appendingPathComponent("v1/config")))
        } catch let error as URLError where Self.isOffline(error) {
            freshConfig = connection.config
            offline = true
        }
        guard startingEpoch == epoch else { throw CancellationError() }
        guard freshConfig == connection.config else {
            throw ClientError.invalid(
                "Server identity or capabilities changed. Sign out and explicitly approve the server again before sending credentials."
            )
        }
        let key = LedgerStore.accountKey(connection: connection, subject: subject)
        var loaded = try store.load(account: key)
        if loaded.resumePhotosNetworkFailures() { try store.save(loaded, account: key) }
        if !offline, loaded.resumeLegacyPhotoKitPublications() {
            try store.save(loaded, account: key)
        }
        if loaded.settings.onboardingCompleted == nil {
            loaded.settings.onboardingCompleted = OnboardingPolicy.completed(
                settings: loaded.settings, selectedLibrary: loaded.selectedLibraryID,
                hasResources: !loaded.records.isEmpty || loaded.resourceSets?.isEmpty == false)
            try store.save(loaded, account: key)
        }
        epoch = UUID()
        resetTrash()
        activeBackupItems.removeAll()
        galleryAtTop = true
        galleryRefreshError = nil
        api?.invalidate()
        mediaGeneration = UUID()
        let boundary = epoch
        await BackgroundTransfers.shared.cancelOutside(account: key)
        guard epoch == boundary else { throw CancellationError() }
        gallery.reset()
        retainedGallery = nil
        visibleAnchor = nil
        timeline = []
        libraries = []
        libraryCursor = nil
        MediaCache.shared.clear()
        cleanupReport = ""
        showCleanupConfirmation = false
        try? FileManager.default.removeItem(at: viewerDirectory())
        try FileManager.default.createDirectory(at: viewerDirectory(), withIntermediateDirectories: true)
        activeAuth = session
        account = key
        ledger = loaded
        api = API(connection: connection, auth: session)
        signedIn = true
        needsReauthentication = false
        try await pruneOrphanStaging(account: key, ledger: loaded)
        if let library = loaded.selectedLibraryID, let cached = try store.loadGallery(account: key, library: library) {
            retainedGallery = cached
            gallery = cached.window
            visibleAnchor = cached.anchor?.id
            scrollTarget = visibleAnchor
            galleryIsStale = true
            if offline { libraries = [cached.library] }
        }
        if offline {
            galleryIsStale = true
            message =
                "Offline — displaying the last account-isolated gallery snapshot. Access and media availability have not been revalidated."
        } else {
            try await loadLibraries(reset: true)
            if ledger.selectedLibraryID != nil { await loadGallery(reset: true) }
        }
    }
    func probe(url: String, allowHTTP: Bool) async throws {
        proposedConnection = nil
        let version = epoch
        do {
            #if DEBUG
                let allowDevelopmentHTTP = allowHTTP
            #else
                let allowDevelopmentHTTP = false
            #endif
            let base = try URLPolicy.validate(url, allowDevelopmentHTTP: allowDevelopmentHTTP)
            let config = try await HTTP.json(ServerConfig.self, HTTP.request(base.appendingPathComponent("v1/config")))
            guard !config.serverId.isEmpty, config.clientId == "nephos-ios",
                config.chunkSize == 4_194_304, config.maxUploadBytes > 0,
                config.maxUploadBytes <= 8_589_934_592
            else { throw ClientError.invalid("The server advertised an unsupported upload/authentication contract.") }
            let candidate = Connection(baseURL: base, config: config, allowDevelopmentHTTP: allowDevelopmentHTTP)
            do {
                let issuer = try URLPolicy.validate(config.issuer, allowDevelopmentHTTP: allowDevelopmentHTTP)
                try OnboardingPolicy.validateIssuer(issuer, server: base)
                _ = try await AuthSession.discovery(candidate)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw OnboardingFailure(error, identity: true, address: config.issuer)
            }
            try Task.checkCancellation()
            guard version == epoch else { throw CancellationError() }
            proposedConnection = candidate
        } catch {
            if error is CancellationError { throw error }
            throw OnboardingFailure(error)
        }
    }
    func approveConnection() async {
        guard let proposedConnection else { return }
        do {
            try await signOut()
            try JSONEncoder().encode(proposedConnection).write(
                to: root.appendingPathComponent("connection.json"), options: .atomic)
            connection = proposedConnection
            self.proposedConnection = nil
        } catch { handle(error) }
    }
    func beginServerChange() async throws {
        try await signOut()
        let file = root.appendingPathComponent("connection.json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        connection = nil
        proposedConnection = nil
    }
    @discardableResult
    func login() async -> Bool {
        guard let connection, !isSigningIn else { return false }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            activity = "Opening the system sign-in browser…"
            let session = AuthSession()
            auth = session
            try await session.login(connection: connection)
            try await establish(session)
            scheduleAutomaticRun()
            activity = ""
            return true
        } catch {
            activity = ""
            if !AuthSession.isCancelled(error) { handle(error) }
            return false
        }
    }
    func signOut() async throws {
        signedIn = false
        retryWakeup.cancel()
        backupNotice = nil
        backupDiagnostic = nil
        backupAccessBlocked = false
        epoch = UUID()
        resetTrash()
        activeBackupItems.removeAll()
        galleryAtTop = true
        galleryRefreshError = nil
        api?.invalidate()
        mediaGeneration = UUID()
        automaticTask?.cancel()
        automaticTask = nil
        await BackgroundTransfers.shared.cancelAll()
        var signOutError: Error?
        do { try activeAuth?.signOut() } catch { signOutError = error }
        do { try auth.signOut() } catch { signOutError = error }
        needsReauthentication = false
        activeAuth = nil
        account = nil
        api = nil
        ledger = AccountLedger()
        gallery.reset()
        retainedGallery = nil
        timeline = []
        visibleAnchor = nil
        libraries = []
        libraryCursor = nil
        cleanupReport = ""
        showCleanupConfirmation = false
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Viewer"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Viewer"), withIntermediateDirectories: true)
        MediaCache.shared.clear()
        if let signOutError { throw signOutError }
    }
    func loadLibraries(reset: Bool = false) async throws {
        guard let api else { throw ClientError.signedOut }
        let version = epoch
        let oldCursor = reset ? nil : libraryCursor
        let page = try await api.libraries(cursor: oldCursor)
        try check(version)
        guard page.nextCursor == nil || page.nextCursor != oldCursor else {
            throw ClientError.invalid("Repeated library cursor.")
        }
        if reset { libraries = [] }
        let known = Set(libraries.map(\.id))
        libraries += page.items.filter { !known.contains($0.id) }
        libraryCursor = page.nextCursor
        if reset, let id = ledger.selectedLibraryID, !libraries.contains(where: { $0.id == id }) {
            // Membership may be on a later page; require an explicitly visible library before new work.
            gallery.reset()
        }
    }
    @discardableResult
    func selectLibrary(_ id: UUID) async -> Bool {
        guard libraries.contains(where: { $0.id == id }), !isRunning, !isDeletingMedia, !isRestoringTrash else {
            return false
        }
        automaticTask?.cancel()
        automaticTask = nil
        retryWakeup.cancel()
        backupNotice = nil
        backupDiagnostic = nil
        backupAccessBlocked = false
        let previous = ledger
        epoch = UUID()
        resetTrash()
        activeBackupItems.removeAll()
        galleryAtTop = true
        galleryRefreshError = nil
        isLoadingGallery = false
        ledger.selectedLibraryID = id
        ledger.scanAfter = nil
        do { try persist() } catch {
            ledger = previous
            handle(error)
            return false
        }
        MediaCache.shared.clear()
        mediaGeneration = UUID()
        gallery.reset()
        retainedGallery = nil
        visibleAnchor = nil
        timeline = []
        timelineYear = nil
        timelineMonth = nil
        if let store, let account {
            do {
                if let cached = try store.loadGallery(account: account, library: id) {
                    retainedGallery = cached
                    gallery = cached.window
                    galleryIsStale = true
                    visibleAnchor = cached.anchor?.id
                }
            } catch { handle(error) }
        }
        await loadGallery(reset: true)
        scheduleAutomaticRun()
        return true
    }
    func loadGallery(
        reset: Bool = false, newest: Bool = false, before: GalleryCursor? = nil, allowRebase: Bool = true,
        notifyErrors: Bool = true, automatic: Bool = false
    )
        async
    {
        guard !isLoadingGallery, !isDeletingMedia, !isRestoringTrash, let api,
            let library = ledger.selectedLibraryID else { return }
        if !reset && gallery.hasLoaded && gallery.nextCursor == nil { return }
        isLoadingGallery = true
        let loadID = UUID()
        galleryLoadID = loadID
        let version = epoch
        let mutationVersion = mediaMutationGeneration
        defer { if galleryLoadID == loadID { isLoadingGallery = false } }
        do {
            var candidate = retainedGallery
            var recordRemovals: [UUID: Bool] = [:]
            if reset || candidate == nil {
                let target: GallerySnapshot
                if before != nil, let retainedGallery {
                    target = retainedGallery.snapshot
                } else {
                    target = try await api.snapshot(library: library)
                }
                try check(version)
                guard mutationVersion == mediaMutationGeneration else { return }
                let old = retainedGallery
                if automatic, let old, !galleryIsStale,
                    GalleryRefreshPolicy.unchanged(old.snapshot, target)
                {
                    var refreshed = old
                    refreshed.snapshot = target
                    refreshed.updatedAt = Date()
                    if let store, let account { try store.saveGallery(refreshed, account: account) }
                    retainedGallery = refreshed
                    galleryRefreshError = nil
                    return
                }
                let followNewest = newest || (automatic && galleryAtTop && old?.startsAtNewest != false)
                var anchor =
                    followNewest
                    ? nil
                    : old?.window.items.first(where: { $0.id == visibleAnchor }).map {
                        GalleryCursor(createdAt: $0.createdAt, id: $0.id)
                    } ?? (followNewest ? nil : old?.anchor)
                if let old, old.snapshot.accessGeneration == target.accessGeneration,
                    old.snapshot.revision <= target.revision
                {
                    var revision = old.snapshot.revision
                    do {
                        while revision < target.revision {
                            let page = try await api.changes(
                                library: library, after: revision, through: target.revision)
                            try check(version)
                            for change in page.changes.flatMap(\.items) {
                                for id in ledger.trackedRecords(for: change.assetId) {
                                    recordRemovals[id] = change.operation == "remove"
                                }
                                // Keep correctness tombstones for tracked local originals even outside the gallery window.
                                if change.operation == "remove" {
                                    if anchor?.id == change.assetId {
                                        anchor = old.window.items.first(where: { $0.id != change.assetId }).map {
                                            GalleryCursor(createdAt: $0.createdAt, id: $0.id)
                                        }
                                    }
                                } else if change.assetId == anchor?.id, let asset = change.asset {
                                    anchor = GalleryCursor(createdAt: asset.createdAt, id: asset.id)
                                }
                            }
                            revision = page.toRevision
                        }
                    } catch ClientError.http(410, _) {
                        // The target snapshot remains authoritative when delta history has expired.
                    }
                } else if old != nil {
                    anchor = nil
                    clearGalleryAccess()
                }
                var window = GalleryWindow()
                let cursor: GalleryCursor?
                if automatic, let old, old.snapshot.accessGeneration == target.accessGeneration {
                    cursor =
                        old.startsAtNewest != false
                        ? nil
                        : old.window.items.first.map {
                            GalleryDates.inclusiveAnchor(GalleryCursor(createdAt: $0.createdAt, id: $0.id))
                        }
                } else {
                    cursor = before ?? anchor.map(GalleryDates.inclusiveAnchor)
                }
                let page = try await api.assets(library: library, snapshot: target.id, cursor: cursor)
                try check(version)
                try window.append(page, libraryID: library)
                if automatic, let old {
                    for _ in 1..<6 {
                        let containsAnchor =
                            anchor == nil || window.items.contains { $0.id == (visibleAnchor ?? anchor?.id) }
                        guard window.items.count < old.window.items.count || !containsAnchor,
                            let next = window.nextCursor
                        else { break }
                        let older = try await api.assets(library: library, snapshot: target.id, cursor: next)
                        try check(version)
                        try window.append(older, libraryID: library)
                    }
                    if !galleryAtTop, let current = old.window.items.first(where: { $0.id == visibleAnchor }) {
                        anchor = GalleryCursor(createdAt: current.createdAt, id: current.id)
                    }
                }
                // Re-query a bounded window against the target, rather than pretending unseen delta
                // upserts are a complete offscreen database. The retained snapshot owns that index.
                candidate = RetainedGallery(
                    library: selectedLibrary ?? Library(id: library, name: "Library"),
                    snapshot: target, window: window, anchor: anchor, updatedAt: Date(), startsAtNewest: cursor == nil)
                if automatic, let anchor, !window.items.contains(where: { $0.id == anchor.id }) {
                    let anchored = try await api.assets(
                        library: library, snapshot: target.id, cursor: GalleryDates.inclusiveAnchor(anchor))
                    try check(version)
                    window.reset()
                    try window.append(anchored, libraryID: library)
                    candidate?.window = window
                    candidate?.startsAtNewest = false
                }
            } else if var current = candidate {
                let page = try await api.assets(
                    library: library, snapshot: current.snapshot.id, cursor: current.window.nextCursor)
                try check(version)
                try current.window.append(page, libraryID: library)
                if current.window.items.first?.id != candidate?.window.items.first?.id {
                    current.startsAtNewest = false
                }
                current.updatedAt = Date()
                candidate = current
            }
            try check(version)
            guard mutationVersion == mediaMutationGeneration, ledger.selectedLibraryID == library,
                var candidate, let store, let account else { return }
            if !reset, let visibleAnchor, let item = candidate.window.items.first(where: { $0.id == visibleAnchor }) {
                candidate.anchor = GalleryCursor(createdAt: item.createdAt, id: item.id)
            }
            if let anchor = candidate.anchor, !candidate.window.items.contains(where: { $0.id == anchor.id }) {
                candidate.anchor = candidate.window.items.first.map {
                    GalleryCursor(createdAt: $0.createdAt, id: $0.id)
                }
            }
            // Write tombstones first: a failed cache write may replay deltas but never loses suppression.
            // Transfers can advance while gallery requests await the network. Merge only the
            // tombstones; never replace the live upload ledger with a stale pre-request copy.
            for index in ledger.records.indices {
                if let removed = recordRemovals[ledger.records[index].id] {
                    ledger.records[index].remoteRemoved = removed ? true : nil
                }
            }
            try persist()
            try store.saveGallery(candidate, account: account)
            retainedGallery = candidate
            gallery = candidate.window
            galleryIsStale = false
            galleryRefreshError = nil
            scrollTarget = reset ? candidate.anchor?.id ?? candidate.window.items.first?.id : visibleAnchor
        } catch ClientError.http(410, _) where allowRebase {
            guard version == epoch, mutationVersion == mediaMutationGeneration,
                ledger.selectedLibraryID == library else { return }
            retainedGallery = nil
            gallery.reset()
            isLoadingGallery = false
            await loadGallery(
                reset: true, newest: newest, before: before, allowRebase: false, notifyErrors: notifyErrors,
                automatic: automatic)
        } catch {
            guard version == epoch, mutationVersion == mediaMutationGeneration,
                ledger.selectedLibraryID == library, !Task.isCancelled,
                !(error is CancellationError)
            else { return }
            if Self.accessDenied(error) { clearGalleryAccess() } else { galleryIsStale = true }
            if automatic {
                handle(error, notify: false)
                galleryRefreshError = error.localizedDescription
            } else if notifyErrors {
                handle(error)
            } else {
                handleBackupError(error)
            }
        }
    }
    static func isOffline(_ error: URLError) -> Bool {
        [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut,
            .dnsLookupFailed,
        ].contains(error.code)
    }
    static func accessDenied(_ error: Error) -> Bool {
        if case ClientError.signedOut = error { return true }
        if case ClientError.http(let status, _) = error { return [403, 404].contains(status) }
        return false
    }
    func clearGalleryAccess() {
        gallery.reset()
        retainedGallery = nil
        timeline = []
        visibleAnchor = nil
        galleryRefreshError = nil
        galleryAtTop = true
        mediaGeneration = UUID()
        MediaCache.shared.clear()
        if let account, let store {
            do { try store.clearGallery(account: account) } catch { message = error.localizedDescription }
        }
        try? FileManager.default.removeItem(at: viewerDirectory())
        try? FileManager.default.createDirectory(at: viewerDirectory(), withIntermediateDirectories: true)
    }
    func rememberAnchor(_ id: UUID) {
        visibleAnchor = id
        guard var retainedGallery, let asset = gallery.items.first(where: { $0.id == id }), let account, let store
        else { return }
        retainedGallery.anchor = GalleryCursor(createdAt: asset.createdAt, id: id)
        self.retainedGallery = retainedGallery
        do { try store.saveGallery(retainedGallery, account: account) } catch { handle(error) }
    }
    func loadTimeline(year: Int? = nil, month: Int? = nil, allowRebase: Bool = true) async {
        guard let api, let cache = retainedGallery else { return }
        let version = epoch
        timelineError = nil
        do {
            let result = try await api.timeline(
                library: cache.library.id, snapshot: cache.snapshot.id, year: year, month: month)
            try check(version)
            guard retainedGallery?.snapshot.id == cache.snapshot.id else { return }
            timeline = result
            timelineYear = year
            timelineMonth = month
        } catch ClientError.http(410, _) where allowRebase {
            guard version == epoch else { return }
            await loadGallery(reset: true)
            await loadTimeline(year: year, month: month, allowRebase: false)
        } catch {
            guard version == epoch else { return }
            timelineError = error.localizedDescription
            if Self.accessDenied(error) { clearGalleryAccess() }
            handle(error)
        }
    }
    func jump(to date: String) async {
        do { await loadGallery(reset: true, newest: true, before: try GalleryDates.endOfBucket(date)) } catch {
            handle(error)
        }
    }
    func setSettings(_ settings: BackupSettings) {
        let old = ledger.settings
        ledger.settings = settings
        do { try persist() } catch {
            ledger.settings = old
            handle(error)
            return
        }
        scheduleAutomaticRun()
        scheduleRetry()
        scheduleBackground()
    }
    func saveOnboarding(_ draft: OnboardingDraft) throws {
        guard needsOnboarding, libraries.contains(where: { $0.id == draft.libraryID }) else {
            throw ClientError.invalid("Select an accessible library before continuing.")
        }
        let previous = ledger.onboarding
        ledger.onboarding = draft
        do { try persist() } catch {
            ledger.onboarding = previous
            throw error
        }
    }
    func completeOnboarding(library id: UUID, backup: Bool, allowCellular: Bool) async throws {
        try await loadLibraries(reset: true)
        while !libraries.contains(where: { $0.id == id }), libraryCursor != nil {
            try await loadLibraries()
        }
        guard let account, signedIn, !needsReauthentication,
            let library = libraries.first(where: { $0.id == id })
        else { throw ClientError.invalid("Select an accessible library before continuing.") }
        guard !backup || (!library.isReadOnly && [.authorized, .limited].contains(photos.authorization)) else {
            throw ClientError.invalid(
                "Backup needs your own library and Photos permission. You can continue in browse-only mode.")
        }
        guard await selectLibrary(id), self.account == account, signedIn, !needsReauthentication else {
            throw ClientError.invalid("Library selection failed or the account changed. Try again.")
        }
        let previous = ledger.settings
        ledger.settings.automaticBackup = backup
        ledger.settings.automaticCleanup = false
        ledger.settings.allowCellular = allowCellular
        ledger.settings.backupPaused = false
        ledger.settings.onboardingCompleted = true
        do { try persist() } catch {
            ledger.settings = previous
            throw error
        }
        if backup { scheduleAutomaticRun() }
        scheduleBackground()
    }
    func setBackupPaused(_ paused: Bool) async {
        var settings = ledger.settings
        settings.backupPaused = paused
        setSettings(settings)
        guard ledger.settings.backupPaused == paused else { return }
        if paused {
            retryWakeup.cancel()
            let task = automaticTask
            task?.cancel()
            await BackgroundTransfers.shared.cancelAll()
            await task?.value
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
        } else {
            scheduleAutomaticRun()
        }
    }
    private func checkBackup(_ version: UUID) throws {
        try check(version)
        guard ledger.settings.backupPaused != true, selectedLibrary?.isReadOnly != true,
            !needsReauthentication, !backupAccessBlocked, !isDeletingMedia
        else {
            throw CancellationError()
        }
    }
    private func persist() throws {
        guard let store, let account else { throw ClientError.invalid("Sign in before changing account settings.") }
        try store.save(ledger, account: account)
    }
    private func update(_ record: UploadRecord) throws {
        if let index = ledger.records.firstIndex(where: { $0.id == record.id }) {
            var merged = record
            if ledger.records[index].remoteRemoved == true { merged.remoteRemoved = true }
            ledger.records[index] = merged
        } else {
            ledger.records.append(record)
        }
        try persist()
    }
    private func pruneOrphanStaging(account: String, ledger: AccountLedger) async throws {
        guard let store else { return }
        let active = await BackgroundTransfers.shared.activeTasks()
        guard !active.contains(where: { $0.taskDescription?.hasPrefix(account + "/") == true }) else { return }
        let directory = try store.accountDirectory(account)
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
    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard version == epoch, signedIn else { throw CancellationError() }
    }
    func handle(_ error: Error, notify: Bool = true) {
        if error is CancellationError { return }
        if let error = error as? URLError, error.code == .cancelled, ledger.settings.backupPaused == true { return }
        if notify { message = error.localizedDescription }
        if Self.accessDenied(error) { clearGalleryAccess() }
        if case ClientError.signedOut = error {
            retryWakeup.cancel()
            epoch = UUID()
            resetTrash()
            activeBackupItems.removeAll()
            api?.invalidate()
            automaticTask?.cancel()
            automaticTask = nil
            needsReauthentication = true
            activity = "Sign in again to resume. Staging is preserved."
            clearGalleryAccess()
            Task { await BackgroundTransfers.shared.cancelAll() }
        }
    }
    private func handleBackupError(_ error: Error) {
        guard !(error is CancellationError),
            !((error as? URLError)?.code == .cancelled
                && (ledger.settings.backupPaused == true || backupAccessBlocked || needsReauthentication || !signedIn))
        else { return }
        backupNotice = BackupPresentation.failure(error)
        backupDiagnostic = error.localizedDescription
        if case ClientError.http(403, _) = error {
            backupAccessBlocked = true
            retryWakeup.cancel()
            Task { await BackgroundTransfers.shared.cancelAll() }
        }
        handle(error, notify: false)
    }
    func updatePhotosStatus() {
        photos.refreshObservation()
        switch photos.authorization {
        case .authorized: photosStatus = "Full Photos access: existing and new photos/videos can be discovered."
        case .limited:
            photosStatus =
                "Limited Photos access: only allowed items can be backed up. Excluded items are not protected."
        case .denied, .restricted:
            photosStatus =
                "Photos access denied. You can still browse the server library. Change access in iOS Settings."
        default: photosStatus = "Grant Photos access to back up originals."
        }
    }
    func requestPhotos() async {
        _ = await photos.requestAccess()
        updatePhotosStatus()
    }
    func importSelected(_ identifiers: [String]) async {
        guard !isRunning, selectedLibrary != nil else { return }
        isRunning = true
        defer {
            isRunning = false
            activity = ""
            offerCleanup()
            scheduleRetry()
            scheduleBackground()
        }
        let version = epoch
        do {
            if !(await BackgroundTransfers.shared.activeTasks()).isEmpty {
                throw ClientError.invalid(
                    "An earlier system upload is still active. Let it finish before importing another batch.")
            }
            if photos.authorization == .notDetermined { await requestPhotos() }
            guard photos.authorization == .authorized || photos.authorization == .limited else {
                throw ClientError.invalid(
                    "Photos permission is needed to export originals and preserve source identity.")
            }
            var seen: Set<String> = []
            let selected = identifiers.prefix(20).filter { seen.insert($0).inserted }
            try await BackupQueue.run(selected) { [self] identifier in
                try checkBackup(version)
                do {
                    guard let asset = photos.asset(identifier) else {
                        throw ClientError.invalid("Selected Photos item is no longer accessible.")
                    }
                    try await stageAndUpload(asset, version: version, ignoreBackoff: true)
                } catch {
                    if version == epoch { handleBackupError(error) }
                }
                try checkBackup(version)
            }
            await loadGallery(reset: true, notifyErrors: false, automatic: true)
        } catch {
            if version == epoch { handleBackupError(error) }
        }
    }
    func runBackup(ignoreBackoff: Bool = false, retryItem: UUID? = nil) async {
        guard !isRunning, signedIn, !needsReauthentication, !needsOnboarding, selectedLibrary != nil,
            selectedLibrary?.isReadOnly != true, ledger.settings.backupPaused != true
        else { return }
        if ignoreBackoff { backupAccessBlocked = false }
        guard !backupAccessBlocked else { return }
        guard NetworkPolicy.shared.isConnected else {
            backupNotice = "Waiting for a connection"
            scheduleRetry()
            return
        }
        isRunning = true
        backupNotice = nil
        backupDiagnostic = nil
        let version = epoch
        defer {
            isRunning = false
            activity = ""
            offerCleanup()
            scheduleBackground()
            scheduleRetry()
        }
        do {
            let groupedRecords = Dictionary(grouping: ledger.records, by: \.resourceSetId)
            let requestedGroup = retryItem.flatMap { id in ledger.records.first { $0.id == id }?.resourceSetId }
            let complete = Array(
                (ledger.resourceSets ?? []).lazy.filter { group in
                    group.libraryId == self.ledger.selectedLibraryID && group.manifest == nil
                        && !self.ledger.suppresses(group.source.localIdentifier, library: group.libraryId)
                        && (retryItem == nil || group.id == retryItem || group.id == requestedGroup)
                        && (ignoreBackoff || group.requiresUserAction != true)
                        && (ignoreBackoff || (group.nextRetryAt ?? .distantPast) <= Date())
                        && (ignoreBackoff
                            || !(groupedRecords[group.id] ?? []).contains {
                                $0.requiresUserAction == true || ($0.nextRetryAt ?? .distantPast) > Date()
                            })
                        && group.verifiedResources(in: groupedRecords[group.id] ?? []) != nil
                }.prefix(12))
            let attemptedPublications = Set(complete.map(\.id))
            try await BackupQueue.run(complete) { [self] group in
                try checkBackup(version)
                do { try await publishGroup(group.id, version: version) } catch {
                    if version == epoch {
                        try recordGroupFailure(group.id, error: error)
                        handleBackupError(error)
                    }
                }
                try checkBackup(version)
            }
            if let reason = NetworkPolicy.shared.backupWaitReason(cellular: ledger.settings.allowCellular) {
                backupNotice = reason
                if !complete.isEmpty { await loadGallery(reset: true, notifyErrors: false, automatic: true) }
                return
            }
            let tasks = await BackgroundTransfers.shared.activeTasks()
            for task in tasks {
                guard task.taskDescription?.hasPrefix((account ?? "") + "/") == true else {
                    task.cancel()
                    continue
                }
                activity = "Waiting for an existing system upload. Its result will be reconciled before retry."
                backupNotice = "An earlier upload is still finishing. Retry when it completes."
                return
            }
            let unpublishedGroupIDs = Set(
                (ledger.resourceSets ?? []).filter { $0.manifest == nil }.map(\.id))
            let pending = ledger.records.filter { record in
                record.libraryId == ledger.selectedLibraryID && record.needsTransfer
                    && !ledger.suppresses(record.source.localIdentifier, library: record.libraryId)
                    && (retryItem == nil || record.id == retryItem || record.resourceSetId == retryItem)
                    && (record.resourceSetId.map { !unpublishedGroupIDs.contains($0) } ?? true)
                    && (ignoreBackoff || record.requiresUserAction != true)
                    && (ignoreBackoff || (record.nextRetryAt ?? .distantPast) <= Date())
            }.sorted { ($0.lastAttemptAt ?? .distantPast) < ($1.lastAttemptAt ?? .distantPast) }
            try await BackupQueue.run(Array(pending.prefix(20))) { [self] record in
                try checkBackup(version)
                do { try await transfer(record, version: version) } catch {
                    if version == epoch { handleBackupError(error) }
                }
                try checkBackup(version)
            }
            // Resume partially exported sets even when automatic discovery is disabled.
            let membersByGroup = Dictionary(grouping: ledger.records, by: \.resourceSetId)
            let retryGroupID = retryItem.flatMap { id in
                ledger.records.first(where: { $0.id == id })?.resourceSetId
            }
            let groups = (ledger.resourceSets ?? []).filter({ group in
                group.libraryId == ledger.selectedLibraryID && group.manifest == nil
                    && !ledger.suppresses(group.source.localIdentifier, library: group.libraryId)
                    && !attemptedPublications.contains(group.id)
                    && (retryItem == nil || group.id == retryItem || group.id == retryGroupID)
                    && (ignoreBackoff || group.requiresUserAction != true)
                    && (ignoreBackoff || (group.nextRetryAt ?? .distantPast) <= Date())
                    && (ignoreBackoff
                        || !(membersByGroup[group.id] ?? []).contains(where: {
                            ($0.nextRetryAt ?? .distantPast) > Date() || $0.requiresUserAction == true
                                || $0.phase == .sourceChanged || $0.remoteRemoved == true
                        }))
            }).prefix(12)
            try await BackupQueue.run(Array(groups)) { [self] group in
                try checkBackup(version)
                do {
                    if let source = photos.asset(group.source.localIdentifier), photos.revision(source) == group.source
                    {
                        try await stageAndUpload(source, version: version, ignoreBackoff: ignoreBackoff)
                    } else {
                        do { try await publishGroup(group.id, version: version) } catch {
                            if version == epoch { try recordGroupFailure(group.id, error: error) }
                            throw error
                        }
                    }
                } catch {
                    if version == epoch { handleBackupError(error) }
                }
                try checkBackup(version)
            }
            if ledger.settings.automaticBackup && retryItem == nil {
                guard photos.authorization == .authorized || photos.authorization == .limited else {
                    throw ClientError.invalid(
                        "Automatic backup is waiting for Photos permission. Open Backup to grant access.")
                }
                let batch = photos.batch(after: ledger.scanAfter)
                try await BackupQueue.run(batch.assets.map(\.localIdentifier)) { [self] identifier in
                    try checkBackup(version)
                    do {
                        guard let asset = photos.asset(identifier) else {
                            throw ClientError.invalid("Photos item is no longer accessible.")
                        }
                        try await stageAndUpload(asset, version: version)
                    } catch {
                        if version == epoch { handleBackupError(error) }
                    }
                    try checkBackup(version)
                }
                ledger.scanAfter = batch.assets.last?.localIdentifier ?? ledger.scanAfter
                try persist()
                if batch.atEnd {
                    ledger.scanAfter = nil
                    try persist()
                } else {
                    activity = "More accessible originals remain; the next scan will continue here."
                }
            }
            await loadGallery(reset: true, notifyErrors: false, automatic: true)
        } catch {
            if version == epoch { handleBackupError(error) }
        }
    }
    private func stageAndUpload(_ asset: PHAsset, version: UUID, ignoreBackoff: Bool = false) async throws {
        try checkBackup(version)
        guard let store, let account, let library = ledger.selectedLibraryID, let connection else {
            throw ClientError.signedOut
        }
        guard !ledger.suppresses(asset.localIdentifier, library: library) else { return }
        let revision = photos.revision(asset)
        let resources = photos.resources(asset)
        guard (1...16).contains(resources.count) else {
            throw ClientError.invalid(
                "Photos must expose 1–16 resources. This item is not backed up or cleanup-eligible.")
        }
        let group: ResourceSetRecord
        if let existing = ledger.resourceSets?.first(where: { $0.libraryId == library && $0.source == revision }) {
            group = existing
            if group.manifest != nil { return }
            if !ignoreBackoff, group.requiresUserAction == true || (group.nextRetryAt ?? .distantPast) > Date() {
                return
            }
            if ignoreBackoff, let index = ledger.resourceSets?.firstIndex(where: { $0.id == group.id }) {
                ledger.resourceSets?[index].requiresUserAction = nil
                ledger.resourceSets?[index].nextRetryAt = nil
                ledger.resourceSets?[index].error = nil
                ledger.resourceSets?[index].recoveryMessage = nil
                try persist()
            }
        } else {
            guard (ledger.resourceSets?.count ?? 0) < 50_000 else {
                throw ClientError.invalid(
                    "The durable resource-set mapping limit is reached. Existing mappings are preserved; new exports are paused."
                )
            }
            group = ResourceSetRecord(id: UUID(), libraryId: library, source: revision, kind: photos.kind(asset))
            if ledger.resourceSets == nil { ledger.resourceSets = [] }
            ledger.resourceSets?.append(group)
            try persist()
        }
        activeBackupItems.insert(group.id)
        defer { if version == epoch { activeBackupItems.remove(group.id) } }
        do {
            for (index, resource) in resources.enumerated() {
                try check(version)
                if var existing = ledger.records.first(where: {
                    $0.source.matchesCurrentRevision(revision) && $0.resourceIndex == index && $0.libraryId == library
                }) {
                    guard existing.remoteRemoved != true else {
                        throw ClientError.invalid(
                            "This revision was removed remotely; automatic re-upload is suppressed.")
                    }
                    existing.source = revision
                    if !ignoreBackoff,
                        existing.requiresUserAction == true || (existing.nextRetryAt ?? .distantPast) > Date()
                    {
                        return
                    }
                    // Legacy immutable intents cannot acquire a set ID on a retry. Finish their
                    // original intent before adopting the committed reference into a manifest.
                    if existing.resourceSetId == nil, existing.needsTransfer {
                        try await transfer(existing, version: version)
                        existing = ledger.records.first(where: { $0.id == existing.id }) ?? existing
                        guard existing.phase == .ready, existing.evidence != nil else { return }
                    }
                    existing.resourceSetId = group.id
                    existing.resourceRole = photos.role(resource)
                    existing.uniformTypeIdentifier = resource.uniformTypeIdentifier
                    try update(existing)
                    if existing.needsTransfer {
                        try await transfer(existing, version: version)
                    }
                    continue
                }
                guard ledger.records.count < 50_000 else {
                    throw ClientError.invalid(
                        "The 50,000-resource durable mapping limit is reached. Existing mappings and pending originals are preserved; new exports are paused."
                    )
                }
                let id = UUID()
                let file = try store.staging(account: account, id: id)
                do {
                    let record = try await preparation.run {
                        try checkBackup(version)
                        let remaining = try exportBudget(store: store, maximum: connection.config.maxUploadBytes)
                        activity =
                            "Exporting original \(resource.originalFilename). iCloud-only originals may need a download."
                        try await photos.export(
                            resource, to: file, maximum: remaining,
                            allowNetwork: NetworkPolicy.shared.allowsBackup(cellular: ledger.settings.allowCellular))
                        try check(version)
                        let hash = try await Task.detached { try Hashing.file(file) }.value
                        try check(version)
                        guard let fresh = photos.asset(asset.localIdentifier), photos.revision(fresh) == revision else {
                            throw ClientError.invalid("Source changed during export. It was not marked backed up.")
                        }
                        var record = UploadRecord(
                            id: id, libraryId: library, fileName: resource.originalFilename,
                            mediaType: photos.mime(resource), size: hash.size, sha256: hash.sha256, source: revision,
                            resourceIndex: index)
                        record.capturedAt = asset.creationDate.map { ISO8601DateFormatter().string(from: $0) }
                        record.resourceSetId = group.id
                        record.resourceRole = photos.role(resource)
                        record.uniformTypeIdentifier = resource.uniformTypeIdentifier
                        try update(record)
                        return record
                    }
                    try await transfer(record, version: version)
                } catch {
                    if !ledger.records.contains(where: { $0.id == id }) {
                        try? FileManager.default.removeItem(at: file)
                    }
                    throw error
                }
            }
            guard
                ledger.records.filter({ $0.resourceSetId == group.id }).allSatisfy({
                    $0.phase == .ready && $0.evidence?.available == true
                })
            else { return }
            try await publishGroup(group.id, version: version)
        } catch {
            if version == epoch { try recordGroupFailure(group.id, error: error) }
            throw error
        }
    }
    private func recordGroupFailure(_ id: UUID, error: Error) throws {
        guard let index = ledger.resourceSets?.firstIndex(where: { $0.id == id }) else { return }
        if ledger.settings.backupPaused == true,
            error is CancellationError || (error as? URLError)?.code == .cancelled
        {
            ledger.resourceSets?[index].error = nil
            ledger.resourceSets?[index].recoveryMessage = nil
            ledger.resourceSets?[index].nextRetryAt = nil
            try persist()
            return
        }
        let retries = (ledger.resourceSets?[index].retryCount ?? 0) + 1
        ledger.resourceSets?[index].error = error.localizedDescription
        ledger.resourceSets?[index].recoveryMessage = BackupPresentation.failure(error)
        ledger.resourceSets?[index].retryCount = retries
        let retry = BackupRetryPolicy.isTransient(error)
        ledger.resourceSets?[index].requiresUserAction = !retry
        ledger.resourceSets?[index].nextRetryAt =
            retry
            ? Date().addingTimeInterval(min(3600, 30 * pow(2, Double(min(retries - 1, 7))))) : nil
        try persist()
    }
    private func publishGroup(_ id: UUID, version: UUID) async throws {
        try checkBackup(version)
        guard let api, let index = ledger.resourceSets?.firstIndex(where: { $0.id == id }),
            let group = ledger.resourceSets?[index], group.manifest == nil
        else { return }
        guard !ledger.suppresses(group.source.localIdentifier, library: group.libraryId) else { return }
        activity = "Publishing complete \(group.kind) resource set…"
        activeBackupItems.insert(id)
        defer { if version == epoch { activeBackupItems.remove(id) } }
        let manifest = try await api.publish(group, records: ledger.records)
        try check(version)
        ledger.resourceSets?[index].manifest = manifest
        ledger.resourceSets?[index].error = nil
        ledger.resourceSets?[index].recoveryMessage = nil
        ledger.resourceSets?[index].retryCount = 0
        ledger.resourceSets?[index].nextRetryAt = nil
        ledger.resourceSets?[index].requiresUserAction = nil
        try persist()
    }
    private func exportBudget(store: LedgerStore, maximum: Int64) throws -> Int64 {
        let free =
            try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        let partReserve = Int64(BackupQueue.concurrency * 2) * Int64(connection?.config.chunkSize ?? 4_194_304)
        let budget = min(
            maximum, LedgerStore.stagingBudget - (try store.usedBytes()) - partReserve,
            free - max(64 * 1024 * 1024, partReserve))
        guard budget > 0 else {
            throw ClientError.invalid(
                "Staging is full or device storage is low. Pending originals are preserved; no new export was started.")
        }
        return budget
    }
    private func transfer(_ original: UploadRecord, version: UUID) async throws {
        try checkBackup(version)
        guard !ledger.suppresses(original.source.localIdentifier, library: original.libraryId) else { return }
        guard let store, let account, let api, let connection else { throw ClientError.signedOut }
        let client = UploadClient(api: api)
        var record = original
        let activityID = record.id
        activeBackupItems.insert(activityID)
        defer { if version == epoch { activeBackupItems.remove(activityID) } }
        record.lastAttemptAt = Date()
        record.requiresUserAction = nil
        record.recoveryMessage = nil
        let staged = try store.staging(account: account, id: record.id)
        do {
            try check(version)
            activity = "Reconciling \(record.fileName)…"
            let status = try await client.begin(record)
            try check(version)
            try record.reconcile(status, chunkSize: connection.config.chunkSize)
            try update(record)
            if record.phase == .uploading {
                if !FileManager.default.fileExists(atPath: staged.path) {
                    guard let asset = photos.asset(record.source.localIdentifier),
                        record.source.matchesCurrentRevision(photos.revision(asset)),
                        photos.resources(asset).indices.contains(record.resourceIndex)
                    else {
                        record.phase = .sourceChanged
                        throw ClientError.invalid("Staging is missing and the source changed or is unavailable.")
                    }
                    try await preparation.run {
                        try checkBackup(version)
                        try await photos.export(
                            photos.resources(asset)[record.resourceIndex], to: staged,
                            maximum: try exportBudget(store: store, maximum: record.size),
                            allowNetwork: NetworkPolicy.shared.allowsBackup(cellular: ledger.settings.allowCellular))
                    }
                    try check(version)
                }
                let hash = try await Task.detached { try Hashing.file(staged) }.value
                try check(version)
                guard hash.sha256 == record.sha256 && hash.size == record.size else {
                    record.phase = .sourceChanged
                    throw ClientError.invalid(
                        "Original staging no longer matches its durable intent. This upload is blocked.")
                }
                let parts = Chunking.count(size: record.size, chunkSize: connection.config.chunkSize)
                for index in 0..<parts where !record.receivedParts.contains(index) {
                    try checkBackup(version)
                    let chunk = try store.chunk(account: account, id: record.id, part: index)
                    let length = try Chunking.length(
                        index: index, size: record.size, chunkSize: connection.config.chunkSize)
                    try await Task.detached {
                        let handle = try FileHandle(forReadingFrom: staged)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(index) * UInt64(connection.config.chunkSize))
                        guard let bytes = try handle.read(upToCount: length), bytes.count == length else {
                            throw ClientError.invalid("Staged original is incomplete.")
                        }
                        try bytes.write(to: chunk, options: .atomic)
                    }.value
                    try check(version)
                    activity = "\(record.fileName): part \(index + 1) of \(parts)"
                    try await client.sendPart(record, index: index, file: chunk) { request, file in
                        try self.checkBackup(version)
                        try await BackgroundTransfers.shared.upload(
                            request: request, file: file,
                            identity: "\(account)/\(record.id)/\(index)", cellular: self.ledger.settings.allowCellular)
                    }
                    try check(version)
                    record.receivedParts.append(index)
                    try update(record)
                    try? FileManager.default.removeItem(at: chunk)
                }
                let completed = try await client.complete(record.id)
                try check(version)
                try record.reconcile(completed, chunkSize: connection.config.chunkSize)
                try update(record)
            }
            // Bound foreground polling. Verification can continue on the server after this run ends.
            for attempt in 0..<5 where record.phase == .verifying {
                activity = "Server is verifying \(record.fileName)…"
                try await Task.sleep(for: .seconds(min(attempt + 1, 4)))
                let checked = try await client.status(record.id)
                try check(version)
                try record.reconcile(checked, chunkSize: connection.config.chunkSize)
                try update(record)
            }
            if record.phase == .ready {
                let evidence = try await client.evidence(record.committedAssetID)
                try check(version)
                guard evidence.id == record.committedAssetID, evidence.available, evidence.sha256 == record.sha256,
                    evidence.size == record.size
                else {
                    throw ClientError.invalid("Backup verification does not match the staged original.")
                }
                record.evidence = evidence
                record.evidenceCheckedAt = Date()
                record.error = nil
                record.retryCount = 0
                record.nextRetryAt = nil
                record.requiresUserAction = nil
                try update(record)
                try? FileManager.default.removeItem(at: staged)
                for part in 0..<Chunking.count(size: record.size, chunkSize: connection.config.chunkSize) {
                    try? FileManager.default.removeItem(at: store.chunk(account: account, id: record.id, part: part))
                }
            } else if record.phase == .failed {
                throw ClientError.invalid(record.error ?? "Server verification failed. The device source is untouched.")
            } else if record.phase == .verifying {
                record.nextRetryAt = Date().addingTimeInterval(30)
                try update(record)
            }
        } catch {
            if version == epoch {
                if ledger.settings.backupPaused == true,
                    error is CancellationError || (error as? URLError)?.code == .cancelled
                {
                    record.error = nil
                    record.nextRetryAt = nil
                } else {
                    record.error = error.localizedDescription
                    record.recoveryMessage = BackupPresentation.failure(error)
                    record.requiresUserAction = !BackupRetryPolicy.isTransient(error)
                    if record.requiresUserAction == true {
                        record.nextRetryAt = nil
                    } else {
                        record.deferRetry()
                    }
                }
                if record.phase != .sourceChanged && record.phase != .ready { record.phase = .paused }
                try update(record)
            }
            throw error
        }
    }
    func checkCleanup() {
        guard !isRunning else { return }
        if cleanupCandidates.isEmpty {
            cleanupReport =
                "No verified single-resource unedited photos/videos are eligible. Compound, edited, unsupported, missing, and changed sources remain on the device."
        } else {
            showCleanupConfirmation = true
        }
    }
    func verifyRetention(_ manifest: ResourceManifest) async throws -> String {
        guard let api else { throw ClientError.signedOut }
        let version = epoch
        let hold = try await api.retain(manifest)
        try check(version)
        if let index = ledger.resourceSets?.firstIndex(where: { $0.id == manifest.id }) {
            ledger.resourceSets?[index].retention = hold
            try persist()
        }
        return
            "Every original has a matching server retention hold through \(hold.retainedUntil). Single-volume storage is NOT an independent backup. Compound/edited cleanup remains blocked."
    }
    private func offerCleanup() {
        if ledger.settings.automaticCleanup && ledger.settings.cleanupWarningsAcknowledged && !cleanupCandidates.isEmpty
            && UIApplication.shared.applicationState == .active
        {
            showCleanupConfirmation = true
        }
    }
    func removeConfirmedCopies() async {
        guard !isRunning, let api, let account, let store,
            UIApplication.shared.applicationState == .active
        else { return }
        isRunning = true
        let version = epoch
        defer {
            isRunning = false
            activity = ""
        }
        var removed = 0
        for var record in cleanupCandidates.prefix(10) {
            do {
                try check(version)
                guard photos.authorization == .authorized || photos.authorization == .limited,
                    let source = photos.asset(record.source.localIdentifier),
                    record.source.matchesCurrentRevision(photos.revision(source)), record.source.cleanupSupported
                else {
                    throw ClientError.invalid("Source is changed, unsupported, or inaccessible; removal blocked.")
                }
                activity = "Rechecking original bytes before removal: \(record.fileName)"
                let exportID = UUID()
                let file = try store.staging(account: account, id: exportID)
                defer { try? FileManager.default.removeItem(at: file) }
                try await photos.export(
                    photos.resources(source)[0], to: file,
                    maximum: try exportBudget(store: store, maximum: record.size),
                    allowNetwork: ledger.settings.allowCellular || !NetworkPolicy.shared.isExpensive)
                let hash = try await Task.detached { try Hashing.file(file) }.value
                try check(version)
                guard hash.sha256 == record.sha256, hash.size == record.size else {
                    throw ClientError.invalid("Photos original bytes changed. Removal blocked.")
                }
                let hold = try await UploadClient(api: api).retain(record.committedAssetID)
                try check(version)
                record.retention = hold
                record.evidence = BackupEvidence(
                    id: hold.id, sha256: hold.sha256, size: hold.size, available: hold.available, createdAt: "")
                record.evidenceCheckedAt = Date()
                let fresh = photos.asset(record.source.localIdentifier)
                if let block = record.cleanupBlock(current: fresh.map(photos.revision)) {
                    throw ClientError.invalid(block)
                }
                guard UIApplication.shared.applicationState == .active, let fresh else {
                    throw ClientError.invalid("Return to the foreground to confirm removal.")
                }
                record.cleanupState = "awaiting-system-confirmation"
                try update(record)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([fresh] as NSArray)
                }
                try check(version)
                record.cleanupState = "removed"
                record.error = nil
                try update(record)
                removed += 1
            } catch {
                if version == epoch {
                    record.cleanupState = "failed"
                    record.error = error.localizedDescription
                    do { try update(record) } catch { handle(error) }
                    cleanupReport = "\(removed) removed. Stopped: \(error.localizedDescription)"
                    handle(error)
                }
                return
            }
        }
        cleanupReport =
            "\(removed) item(s) removed from Photos. iCloud/shared-library deletion can propagate. Recently Deleted may still use space. Server originals were retained, not independently replicated."
    }
    func scheduleAutomaticRun() {
        guard signedIn, !needsReauthentication, !needsOnboarding, !backupAccessBlocked, automaticTask == nil,
            !isRunning, !isDeletingMedia, !isRestoringTrash, selectedLibrary != nil, ledger.settings.backupPaused != true,
            ledger.settings.automaticBackup
                || BackupRetryPolicy.nextAttempt(ledger: ledger, library: ledger.selectedLibraryID) != nil,
            selectedLibrary?.isReadOnly != true
        else { return }
        let version = epoch
        let runID = UUID()
        automaticRunID = runID
        automaticTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.automaticRunID == runID {
                    self.automaticTask = nil
                    self.automaticRunID = nil
                }
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, self.epoch == version else { return }
            await self.runBackup()
        }
    }
    private func scheduleRetry() {
        retryWakeup.cancel()
        guard signedIn, !needsReauthentication, !needsOnboarding, !backupAccessBlocked,
            !isDeletingMedia, !isRestoringTrash, selectedLibrary != nil,
            selectedLibrary?.isReadOnly != true, ledger.settings.backupPaused != true,
            let next = BackupRetryPolicy.nextAttempt(ledger: ledger, library: ledger.selectedLibraryID)
        else { return }
        let version = epoch
        let networkAllowed = NetworkPolicy.shared.allowsBackup(cellular: ledger.settings.allowCellular)
        let date = max(next, Date().addingTimeInterval(networkAllowed ? 2 : 30))
        retryWakeup.schedule(at: date) { [weak self] in
            guard let self, self.epoch == version, UIApplication.shared.applicationState == .active else { return }
            self.scheduleAutomaticRun()
        }
    }
    static let backgroundID = "app.nephos.ios.backup"
    func scheduleBackground() {
        guard signedIn, !needsReauthentication, !needsOnboarding, !backupAccessBlocked, selectedLibrary != nil,
            ledger.settings.backupPaused != true, selectedLibrary?.isReadOnly != true,
            ledger.settings.automaticBackup
                || BackupRetryPolicy.nextAttempt(ledger: ledger, library: ledger.selectedLibraryID) != nil
        else {
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            activity = "Background scheduling unavailable; Back up now remains available."
        }
    }
    func viewerDirectory() -> URL { root.appendingPathComponent("Viewer", isDirectory: true) }
}
