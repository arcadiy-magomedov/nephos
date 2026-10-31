import Foundation

@MainActor
enum BackupQueue {
    static let concurrency = 3

    static func run<Item: Sendable>(
        _ items: [Item], perform: @escaping @MainActor @Sendable (Item) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            var remaining = items.makeIterator()
            for _ in 0..<concurrency {
                guard let item = remaining.next() else { break }
                tasks.addTask { try await perform(item) }
            }
            while try await tasks.next() != nil {
                try Task.checkCancellation()
                if let item = remaining.next() {
                    tasks.addTask { try await perform(item) }
                }
            }
        }
    }
}

@MainActor
final class BackupPreparation {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<Value: Sendable>(_ perform: @MainActor () async throws -> Value) async throws -> Value {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        defer {
            if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await perform()
    }
}

enum BackupRetryPolicy {
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ClientError.http(let status, _) = error {
            return [408, 425, 429].contains(status) || (500...599).contains(status)
        }
        guard let error = error as? URLError else { return false }
        return [
            .cancelled, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed,
        ].contains(error.code)
    }

    static func nextAttempt(ledger: AccountLedger, library: UUID?, now: Date = Date()) -> Date? {
        guard let library, ledger.settings.backupPaused != true else { return nil }
        let records = ledger.records.filter { $0.libraryId == library }
        var dates = records.filter { $0.needsTransfer && $0.requiresUserAction != true }
            .map { $0.nextRetryAt ?? now }
        let children = Dictionary(grouping: records, by: \.resourceSetId)
        for group in ledger.resourceSets ?? []
        where group.libraryId == library && group.manifest == nil && group.requiresUserAction != true {
            let members = children[group.id] ?? []
            guard
                !members.contains(where: {
                    $0.requiresUserAction == true || $0.phase == .sourceChanged || $0.remoteRemoved == true
                })
            else { continue }
            // Publication must not bypass a required original's backoff.
            dates.append(max(group.nextRetryAt ?? now, members.compactMap(\.nextRetryAt).max() ?? now))
        }
        return dates.min()
    }
}

@MainActor
final class BackupRetryWakeup {
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(at date: Date, perform: @escaping @MainActor () -> Void) {
        cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            perform()
        }
    }

    deinit { task?.cancel() }
}

@MainActor
final class UploadClient {
    let api: API
    init(api: API) { self.api = api }

    func begin(_ record: UploadRecord) async throws -> UploadStatus {
        try await api.json(
            UploadStatus.self, "v1/uploads", method: "POST",
            body: JSONEncoder().encode(UploadIntent(record)))
    }
    func status(_ id: UUID) async throws -> UploadStatus {
        try await api.json(UploadStatus.self, "v1/uploads/\(id)")
    }
    func complete(_ id: UUID) async throws -> UploadStatus {
        try await api.json(UploadStatus.self, "v1/uploads/\(id)/complete", method: "POST", body: Data())
    }
    func evidence(_ id: UUID) async throws -> BackupEvidence {
        try await api.json(BackupEvidence.self, "v1/assets/\(id)/backup")
    }
    func retain(_ id: UUID) async throws -> RetentionHold {
        try await api.json(RetentionHold.self, "v1/assets/\(id)/retention", method: "POST", body: Data())
    }
    func originalRequest(_ id: UUID) async throws -> URLRequest {
        var request = try await api.request("v1/assets/\(id)/original")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }
    func sendPart(
        _ record: UploadRecord, index: Int, file: URL,
        using transport: @MainActor (URLRequest, URL) async throws -> Void
    ) async throws {
        let length = try Chunking.length(index: index, size: record.size, chunkSize: api.connection.config.chunkSize)
        let actual = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actual == length else {
            throw ClientError.invalid("Upload part file length does not match its immutable intent.")
        }
        var request = try await api.request("v1/uploads/\(record.id)/parts/\(index)", method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        try await transport(request, file)
    }
    static func foregroundPart(_ request: URLRequest, _ file: URL) async throws {
        let (_, response) = try await HTTP.session.upload(for: request, fromFile: file)
        try HTTP.check(response)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw ClientError.invalid("Upload part was not acknowledged with HTTP 204.")
        }
    }
}
