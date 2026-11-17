import BackgroundTasks
import Foundation
import OSLog
import Observation
import Photos

@MainActor
@Observable
final class UploadModel {
    static let shared = UploadModel()
    static let backgroundSessionIdentifier = "app.nephos.ios.media-upload.v1"
    private(set) var snapshot = UploadSnapshot.empty
    private(set) var destination: UploadDestination?
    private(set) var libraries: [UploadLibrary] = []
    private(set) var thumbnailItems: [String: UploadItem] = [:]
    private(set) var message: String?
    private(set) var showsProgress = false
    private(set) var loadingLibraries = false
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var repository: SQLiteUploadRepository?
    @ObservationIgnored private var configuration: UploadConfigurationStore?
    @ObservationIgnored private var files: UploadFileStore?
    @ObservationIgnored private var events: UploadEventStore?
    @ObservationIgnored private var transport: MediaUploadTransport?
    @ObservationIgnored private var fileUploader: BackgroundFileUploader?
    @ObservationIgnored private var coordinator: UploadCoordinator?
    @ObservationIgnored private var client: UploadHTTPClient?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workID: UUID?
    @ObservationIgnored private var historyLimit = 100
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var backgroundCompletions: [() -> Void] = []
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var needsDiscovery = true
    @ObservationIgnored private lazy var connectivity = UploadConnectivity { [weak self] in
        self?.networkChanged()
    }
    @ObservationIgnored private let logger = Logger(subsystem: "app.nephos.ios", category: "UploadQueue")

    private init() {
        do {
            let directory = try UploadEnvironment.sharedDirectory()
            self.directory = directory
            repository = try SQLiteUploadRepository(url: directory.appendingPathComponent("uploads.sqlite"))
            configuration = UploadConfigurationStore(directory: directory)
            files = UploadFileStore(directory: directory)
            let events = UploadEventStore(directory: directory)
            self.events = events
            let uploader = try BackgroundFileUploader(
                identifier: Self.backgroundSessionIdentifier, events: events.files,
                onEvent: { Task { @MainActor in UploadModel.shared.receivedBackgroundEvent() } },
                onFinished: { UploadModel.shared.finishedBackgroundEvents() },
                onError: { error in Task { @MainActor in UploadModel.shared.message = error } })
            fileUploader = uploader
            transport = MediaUploadTransport(files: uploader)
        } catch { message = error.localizedDescription }
    }

    func activate() {
        fileUploader?.activate()
        _ = connectivity
    }

    func restore() async {
        do {
            let vault = try await KeychainStorage().vault()
            guard let saved = vault.current else {
                await transport?.cancel(scope: nil)
                destination = nil
                coordinator = nil
                client = nil
                snapshot = .empty
                thumbnailItems = [:]
                libraries = []
                showsProgress = false
                return
            }
            if let stored = try await configuration?.load(),
                stored.accountKey == AccountIdentity.key(connection: saved.connection, subject: saved.subject),
                stored.installationID == vault.installationID
            {
                if destination != stored { try configure(stored) }
                try await reload()
            } else {
                await transport?.cancel(scope: nil)
                destination = nil
                coordinator = nil
                snapshot = .empty
                thumbnailItems = [:]
                libraries = []
                showsProgress = false
                client = UploadHTTPClient(
                    connection: saved.connection,
                    authorization: UploadAuthorization(
                        account: AccountIdentity.key(
                            connection: saved.connection, subject: saved.subject)))
            }
        } catch { report(error) }
    }

    func loadLibraries() async {
        guard !loadingLibraries else { return }
        loadingLibraries = true
        defer { loadingLibraries = false }
        await restore()
        do {
            guard let client else { throw ClientError.invalid("Sign in before choosing an upload library.") }
            libraries = try await client.libraries()
            if libraries.count == 1, destination == nil { await select(libraries[0]) }
            if libraries.isEmpty { message = "No upload library is available. Ask your administrator to add one." }
        } catch { report(error) }
    }

    func select(_ library: UploadLibrary) async {
        guard destination?.libraryID != library.id else { return }
        do {
            guard let configuration else { throw unavailable() }
            let vault = try await KeychainStorage().vault()
            guard let saved = vault.current else { throw ClientError.signedOut }
            work?.cancel()
            if let old = destination {
                try await repository?.setPolicy(.disabled, scope: old.scope)
                await transport?.cancel(scope: old.scope)
            }
            let selected = UploadDestination(
                connection: saved.connection, subject: saved.subject, installationID: vault.installationID,
                libraryID: library.id, libraryName: library.name)
            try await configuration.save(selected)
            try configure(selected)
            try await reload()
            message = nil
        } catch { report(error) }
    }

    func setPolicy(_ policy: UploadPolicy) async {
        if policy == .disabled, destination == nil { return }
        if destination == nil { await loadLibraries() }
        do {
            guard let destination, let repository else {
                throw ClientError.invalid("Choose an upload library before enabling automatic uploads.")
            }
            if policy != .disabled {
                let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                let permission =
                    status == .notDetermined
                    ? await PHPhotoLibrary.requestAuthorization(for: .readWrite) : status
                guard permission == .authorized || permission == .limited else {
                    throw ClientError.invalid(
                        "Allow Photos access in system Settings before enabling automatic uploads.")
                }
            }
            work?.cancel()
            try await repository.setPolicy(policy, scope: destination.scope)
            await transport?.cancel(scope: destination.scope)
            needsDiscovery = true
            try await reload()
            message = nil
            if policy == .disabled { UploadBackgroundScheduler.cancel() } else { UploadBackgroundScheduler.schedule() }
            await process(discover: policy != .disabled)
        } catch { report(error) }
    }

    func togglePause() async {
        do {
            guard let destination, let repository else { throw unavailable() }
            let paused = !snapshot.paused
            work?.cancel()
            try await repository.setPaused(paused, scope: destination.scope)
            if paused { await transport?.cancel(scope: destination.scope) }
            try await reload()
            await process(discover: true)
        } catch { report(error) }
    }

    func retryFailed() async {
        do {
            guard let destination, let repository else { throw unavailable() }
            try await repository.retryFailed(scope: destination.scope)
            try await reload()
            await process(discover: true)
        } catch { report(error) }
    }

    func foreground() {
        isForeground = true
        guard foregroundTask == nil else { return }
        foregroundTask = Task { [weak self] in
            guard let self else { return }
            await restore()
            var lastDiscovery = Date.distantPast
            while !Task.isCancelled {
                let discover = needsDiscovery || Date().timeIntervalSince(lastDiscovery) >= 15
                if work == nil {
                    if discover {
                        lastDiscovery = Date()
                        needsDiscovery = false
                    }
                    _ = startWork(discover: discover)
                }
                do {
                    try await reload()
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    if !AuthSession.isCancelled(error) { report(error) }
                    break
                }
            }
            foregroundTask = nil
        }
    }

    func background() {
        isForeground = false
        foregroundTask?.cancel()
        work?.cancel()
        if snapshot.policy != .disabled { UploadBackgroundScheduler.schedule() }
    }

    func stop() async {
        isForeground = false
        foregroundTask?.cancel()
        work?.cancel()
        await transport?.cancel(scope: nil)
        UploadBackgroundScheduler.cancel()
    }

    func process(discover: Bool) async {
        guard let task = work ?? startWork(discover: discover) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startWork(discover: Bool) -> Task<Void, Never>? {
        guard let coordinator else { return nil }
        let id = UUID()
        let task = Task {
            defer {
                if workID == id {
                    work = nil
                    workID = nil
                }
            }
            do {
                for _ in 0..<10 where !connectivity.hasPath {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let permits = connectivity.permits(snapshot.policy)
                try await coordinator.process(discover: discover, allowsPreparation: permits)
            } catch {
                if !AuthSession.isCancelled(error) { report(error) }
            }
        }
        workID = id
        work = task
        return task
    }

    func loadMoreHistory() async {
        historyLimit += 100
        do { try await reload() } catch { report(error) }
    }

    func watch(_ id: String) { visibleIDs.insert(id) }
    func unwatch(_ id: String) { visibleIDs.remove(id) }
    func photosChanged() {
        needsDiscovery = true
        thumbnailItems = [:]
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletions.append(completion)
        activate()
    }

    func backgroundCheck(discover: Bool = true) async {
        await restore()
        await process(discover: discover)
        do { try await reload() } catch { report(error) }
    }

    private func configure(_ destination: UploadDestination) throws {
        guard let repository, let files, let events, let transport else { throw unavailable() }
        self.destination = destination
        let client = UploadHTTPClient(
            connection: destination.connection, authorization: UploadAuthorization(account: destination.accountKey))
        self.client = client
        coordinator = UploadCoordinator(
            destination: destination, repository: repository, source: UploadPhotoLibrary(), client: client,
            transport: transport, files: files, events: events)
        needsDiscovery = true
    }

    private func reload() async throws {
        guard let destination, let repository else { return }
        let stored = try await repository.snapshot(scope: destination.scope, limit: historyLimit)
        let active = await transport?.active() ?? []
        var sent: [UUID: Int64] = [:]
        if let events {
            for transfer in active { sent[transfer.id] = await events.sent(transfer) }
        }
        func live(_ saved: UploadItem) -> UploadItem {
            guard !saved.phase.isTerminal else { return saved }
            var item = saved
            for index in item.resources.indices
            where item.resources[index].phase != .ready
                && item.resources[index].phase != .verifying
            {
                guard let size = item.resources[index].expectedBytes else { continue }
                let resource = item.resources[index]
                let confirmed = resource.confirmedParts.reduce(Int64(0)) {
                    $0 + UploadChunk.size(part: $1, total: size)
                }
                let transferring = active.filter {
                    $0.itemID == item.id && $0.generation == item.generation && $0.resourceID == resource.id
                        && !resource.confirmedParts.contains($0.part)
                }
                let bytes = transferring.reduce(confirmed) { $0 + (sent[$1.id] ?? 0) }
                item.resources[index].receivedBytes = min(size, bytes)
                if bytes > 0, !transferring.isEmpty { item.phase = .uploading }
            }
            return item
        }
        snapshot = UploadSnapshot(
            policy: stored.policy, paused: stored.paused, scanning: stored.scanning, notice: stored.notice,
            batch: stored.batch, succeeded: stored.succeeded, failed: stored.failed,
            pending: stored.pending.map(live), succeededCount: stored.succeededCount,
            failedCount: stored.failedCount, pendingCount: stored.pendingCount)
        let items = try await repository.items(localIdentifiers: Array(visibleIDs), scope: destination.scope)
        thumbnailItems = Dictionary(
            items.map { ($0.localIdentifier, live($0)) }, uniquingKeysWith: { first, _ in first })
        showsProgress =
            snapshot.batch.map {
                $0.completedAt.map { Date().timeIntervalSince($0) < 2 } ?? true
            } ?? false
    }

    private func receivedBackgroundEvent() {
        guard !isForeground, work == nil else { return }
        backgroundWindow(completions: [])
    }

    private func finishedBackgroundEvents() {
        let completions = backgroundCompletions
        backgroundCompletions.removeAll()
        backgroundWindow(completions: completions)
    }

    private func backgroundWindow(completions: [() -> Void]) {
        let logger = self.logger
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await self.backgroundCheck(discover: false) }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(20)) } catch is CancellationError { return } catch {
                        logger.error(
                            "Background upload deadline failed: \(error.localizedDescription, privacy: .private)")
                    }
                }
                _ = await group.next()
                group.cancelAll()
                // Outcomes were persisted by the URLSession delegate before entering this window.
                for completion in completions { completion() }
            }
        }
    }

    private func networkChanged() {
        if !connectivity.permits(snapshot.policy) {
            work?.cancel()
            if snapshot.policy == .wiFiOnly {
                Task { await transport?.cancel(scope: destination?.scope) }
            }
        }
    }

    private func report(_ error: Error) {
        message = error.localizedDescription
        logger.error("Upload queue requires attention: \(error.localizedDescription, privacy: .private)")
    }

    private func unavailable() -> ClientError {
        .invalid(message ?? "Upload storage is unavailable. Unlock the device and retry.")
    }
}
