import Foundation

actor UploadCoordinator {
    let destination: UploadDestination
    private let repository: any UploadRepository
    private let source: any UploadPhotoSource
    private let client: any UploadRemote
    private let transport: any UploadTransport
    private let files: UploadFileStore
    private let events: UploadEventStore
    private var running = false
    private var retryAt: Date?
    private var consecutiveFailures = 0

    init(
        destination: UploadDestination, repository: any UploadRepository, source: any UploadPhotoSource,
        client: any UploadRemote, transport: any UploadTransport, files: UploadFileStore, events: UploadEventStore
    ) {
        self.destination = destination
        self.repository = repository
        self.source = source
        self.client = client
        self.transport = transport
        self.files = files
        self.events = events
    }

    func process(discover: Bool, allowsPreparation: Bool) async throws {
        guard !running else { return }
        running = true
        defer { running = false }
        let scope = destination.scope
        var snapshot = try await repository.snapshot(scope: scope, limit: 0)
        if discover || snapshot.scanning, snapshot.policy != .disabled {
            try await source.discover(repository: repository, scope: scope)
            snapshot = try await repository.snapshot(scope: scope, limit: 0)
        }
        guard snapshot.canTransfer else {
            await transport.cancel(scope: scope)
            return
        }
        guard allowsPreparation else { return }
        if let retryAt, retryAt > Date() { return }
        try await consumeReceipts()
        var active = await transport.active().filter { $0.scope == scope }
        for transfer in active {
            let current = try await repository.item(id: transfer.itemID, scope: scope)
            if current?.generation != transfer.generation
                || current?.resources.contains(where: {
                    $0.id == transfer.resourceID
                }) != true
            {
                await transport.cancel(scope: scope)
                active = []
                break
            }
        }
        for var item in try await repository.pending(scope: scope, limit: 16) {
            var waiting = false
            try Task.checkCancellation()
            guard try await repository.snapshot(scope: scope, limit: 0).canTransfer else { break }
            do {
                try await process(&item, active: &active, allowsPreparation: allowsPreparation, policy: snapshot.policy)
                if item.phase != .failed { item.error = nil }
            } catch {
                if AuthSession.isCancelled(error) { throw error }
                if let failure = error as? UploadFailure, failure.retryable {
                    waiting = true
                    item.error = failure.localizedDescription
                    try await repository.setNotice(
                        "Waiting for the server. \(failure.localizedDescription)", scope: scope)
                } else if error is URLError {
                    waiting = true
                    item.error = error.localizedDescription
                    try await repository.setNotice(
                        "Waiting for a connection. \(error.localizedDescription)", scope: scope)
                } else {
                    item.phase = .failed
                    item.error = error.localizedDescription
                }
            }
            try await repository.update(item)
            if waiting {
                consecutiveFailures += 1
                retryAt = Date().addingTimeInterval(min(300, pow(2, Double(min(8, consecutiveFailures)))))
                return
            }
        }
        consecutiveFailures = 0
        retryAt = nil
        try await repository.setNotice(nil, scope: scope)
        let final = try await repository.snapshot(scope: scope, limit: 0)
        // Reconcile new assets before closing, even when the last transfer finished between periodic checks.
        if final.pendingCount == 0, final.failedCount == 0, final.batch?.completedAt == nil, final.batch != nil {
            try await source.discover(repository: repository, scope: scope)
        }
    }

    private func process(
        _ item: inout UploadItem, active: inout [UploadTransfer], allowsPreparation: Bool, policy: UploadPolicy
    ) async throws {
        if item.phase == .queued, item.resources.allSatisfy({ $0.expectedBytes == nil }),
            let manifest = try await client.manifest(item)
        {
            for index in item.resources.indices {
                guard let remote = manifest.resources.first(where: { $0.assetId == item.resources[index].id }) else {
                    throw ClientError.invalid("The remote resource set is incomplete.")
                }
                item.resources[index].expectedBytes = remote.size
                item.resources[index].receivedBytes = remote.size
                item.resources[index].sha256 = remote.sha256
                item.resources[index].phase = .ready
            }
            item.committed = true
            item.phase = .succeeded
            return
        }
        guard allowsPreparation || item.resources.allSatisfy({ $0.expectedBytes != nil }) else { return }
        for index in item.resources.indices where item.resources[index].expectedBytes == nil {
            guard active.count < 16 else { return }
            item.phase = .preparing
            try await repository.update(item)
            let original = try await files.prepare(item.resources[index], item: item, source: source)
            item.resources[index].expectedBytes = original.size
            item.resources[index].sha256 = original.hash
            try await repository.update(item)
        }
        for index in item.resources.indices where item.resources[index].phase != .ready {
            try Task.checkCancellation()
            var resource = item.resources[index]
            if let retryAfter = resource.retryAfter, retryAfter > Date() { continue }
            let status: UploadResourceStatus
            if resource.needsRestart {
                status = try await client.retry(resource, item: item, library: destination.libraryID)
            } else {
                status = try await client.create(resource, item: item, library: destination.libraryID)
            }
            resource.needsRestart = false
            resource.confirmedParts = Set(status.receivedParts)
            resource.receivedBytes = status.receivedBytes(size: resource.expectedBytes!)
            if status.state == "failed" || status.state == "cancelled" {
                resource.phase = .failed
                resource.error = status.error ?? "The server could not store this original. Retry the upload."
                item.resources[index] = resource
                item.phase = .failed
                item.error = resource.error
                return
            }
            if status.state == "ready" {
                resource.phase = .ready
                resource.receivedBytes = resource.expectedBytes!
                try await files.removeOriginal(resource.id)
            } else if status.state == "verifying" {
                resource.phase = .verifying
            } else {
                let size = resource.expectedBytes!
                if resource.confirmedParts.count == UploadChunk.count(size: size) {
                    _ = try await client.complete(resource)
                    resource.phase = .verifying
                } else if allowsPreparation {
                    let inFlight = active.filter { $0.resourceID == resource.id && $0.generation == item.generation }
                    for transfer in inFlight {
                        resource.receivedBytes += await events.sent(transfer)
                    }
                    resource.receivedBytes = min(size, resource.receivedBytes)
                    if active.count < 16 {
                        _ = try await files.prepare(resource, item: item, source: source)
                        var resourceTasks = inFlight.count
                        for part in 0..<UploadChunk.count(size: size) where active.count < 16 {
                            if resourceTasks >= 4 { break }
                            if resource.confirmedParts.contains(part) || inFlight.contains(where: { $0.part == part }) {
                                continue
                            }
                            let transfer = UploadTransfer(
                                scope: item.scope, itemID: item.id, generation: item.generation,
                                resourceID: resource.id, part: part, bytes: UploadChunk.size(part: part, total: size))
                            let file = try await files.chunk(transfer, total: size)
                            let request = try await client.uploadRequest(resource, part: part, policy: policy)
                            try Task.checkCancellation()
                            guard try await repository.snapshot(scope: item.scope, limit: 0).canTransfer else {
                                throw CancellationError()
                            }
                            try await transport.enqueue(transfer, request: request, file: file)
                            active.append(transfer)
                            resourceTasks += 1
                        }
                    }
                    resource.phase = resource.receivedBytes > 0 ? .receiving : .scheduled
                }
            }
            item.resources[index] = resource
        }
        if item.resources.allSatisfy({ $0.phase == .ready }) {
            item.phase = .verifying
            try await repository.update(item)
            try await client.commit(item, library: destination.libraryID)
            item.committed = true
            item.phase = .succeeded
        } else if item.resources.contains(where: { $0.phase == .receiving }) {
            item.phase = .uploading
        } else if item.resources.contains(where: { $0.phase == .scheduled }) {
            item.phase = .scheduled
        } else {
            item.phase = .verifying
        }
    }

    private func consumeReceipts() async throws {
        for receipt in try await events.receipts(scope: destination.scope) {
            let transfer = receipt.transfer
            if var item = try await repository.item(id: transfer.itemID, scope: transfer.scope),
                item.generation == transfer.generation, item.phase != .succeeded,
                let index = item.resources.firstIndex(where: { $0.id == transfer.resourceID })
            {
                if let status = receipt.status, (200..<300).contains(status), receipt.error == nil {
                    item.resources[index].confirmedParts.insert(transfer.part)
                } else if !receipt.cancelled {
                    item.resources[index].attempts += 1
                    item.resources[index].retryAfter = Date().addingTimeInterval(
                        min(300, pow(2, Double(item.resources[index].attempts))))
                    if receipt.status == 401 { try await client.refreshAuthorization() }
                    if item.resources[index].attempts >= 5 || [400, 403, 404, 413, 415, 507].contains(receipt.status) {
                        item.resources[index].phase = .failed
                        item.phase = .failed
                        item.error =
                            receipt.error
                            ?? "The server rejected this upload (HTTP \(receipt.status ?? 0)). Check server access and storage, then retry."
                        item.resources[index].error = item.error
                    }
                }
                try await repository.update(item)
            }
            try await files.removeChunk(transfer)
            try await events.acknowledge(receipt)
        }
    }
}
