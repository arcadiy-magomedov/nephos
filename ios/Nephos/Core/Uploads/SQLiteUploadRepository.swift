import Foundation

actor SQLiteUploadRepository: UploadRepository {
    private let database: UploadDatabase
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        database = try UploadDatabase(url: url)
        self.now = now
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS upload_scopes(
                scope TEXT PRIMARY KEY, policy TEXT NOT NULL DEFAULT 'disabled',
                paused INTEGER NOT NULL DEFAULT 0, scanning INTEGER NOT NULL DEFAULT 0,
                notice TEXT, checkpoint BLOB, active_batch TEXT
            )
            """)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS upload_batches(
                id TEXT PRIMARY KEY, scope TEXT NOT NULL REFERENCES upload_scopes(scope),
                created REAL NOT NULL, completed REAL
            )
            """)
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS upload_items(
                id TEXT PRIMARY KEY, scope TEXT NOT NULL REFERENCES upload_scopes(scope),
                batch_id TEXT NOT NULL REFERENCES upload_batches(id),
                local_id TEXT NOT NULL, revision TEXT NOT NULL, phase TEXT NOT NULL,
                updated REAL NOT NULL, payload BLOB NOT NULL,
                UNIQUE(scope,local_id,revision)
            )
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS upload_item_groups ON upload_items(scope,phase,updated DESC)")
        try database.execute("CREATE INDEX IF NOT EXISTS upload_item_batches ON upload_items(batch_id,phase)")
    }

    func setPolicy(_ policy: UploadPolicy, scope: String) throws {
        try ensure(scope)
        try database.execute(
            """
            UPDATE upload_scopes
            SET policy=?,paused=0,scanning=CASE WHEN ?='disabled' THEN 0 ELSE scanning END
            WHERE scope=?
            """,
            [.text(policy.rawValue), .text(policy.rawValue), .text(scope)])
    }

    func setPaused(_ paused: Bool, scope: String) throws {
        try ensure(scope)
        try database.execute(
            "UPDATE upload_scopes SET paused=? WHERE scope=?", [.integer(paused ? 1 : 0), .text(scope)])
    }

    func setNotice(_ notice: String?, scope: String) throws {
        try ensure(scope)
        try database.execute(
            "UPDATE upload_scopes SET notice=? WHERE scope=?", [notice.map { .text($0) } ?? .null, .text(scope)])
    }

    func beginDiscovery(scope: String) throws {
        try ensure(scope)
        try database.execute("UPDATE upload_scopes SET scanning=1 WHERE scope=?", [.text(scope)])
    }

    func checkpoint(scope: String) throws -> Data? {
        try ensure(scope)
        guard
            let row = try database.rows(
                "SELECT checkpoint FROM upload_scopes WHERE scope=?", [.text(scope)]
            ).first, case .blob(let data) = row[0]
        else { return nil }
        return data
    }

    func appendDiscovery(_ candidates: [UploadCandidate], scope: String) throws {
        try database.transaction { try discover(candidates, scope: scope) }
    }

    private func discover(_ candidates: [UploadCandidate], scope: String) throws {
        guard candidates.allSatisfy(\.isValid) else {
            throw ClientError.invalid("Photos returned an unsupported or incomplete resource manifest.")
        }
        try ensure(scope)
        let account = try settings(scope)
        if account.policy != .disabled {
            for candidate in candidates
            where try database.rows(
                "SELECT id FROM upload_items WHERE scope=? AND local_id=? AND revision=?",
                [.text(scope), .text(candidate.localIdentifier), .text(candidate.sourceRevision)]
            ).isEmpty {
                if var previous = try decode(
                    database.rows(
                        """
                        SELECT payload FROM upload_items WHERE scope=? AND local_id=? AND phase<>'succeeded'
                        ORDER BY updated DESC LIMIT 1
                        """, [.text(scope), .text(candidate.localIdentifier)]
                    ).first)
                {
                    previous.sourceRevision = candidate.sourceRevision
                    previous.resourceSetID = UploadIdentity.resourceSet(scope: scope, candidate: candidate)
                    previous.generation = UUID()
                    previous.kind = candidate.kind
                    previous.capturedAt = candidate.capturedAt
                    previous.resources = UploadIdentity.resources(scope: scope, candidate: candidate)
                    previous.phase = candidate.discoveryError == nil ? .queued : .failed
                    previous.committed = false
                    previous.error = candidate.discoveryError
                    previous.updatedAt = now()
                    try save(previous)
                    continue
                }
                let batchID = try activeBatch(scope)
                let item = UploadItem(
                    id: UploadIdentity.resourceSet(scope: scope, candidate: candidate),
                    batchID: batchID, scope: scope,
                    resourceSetID: UploadIdentity.resourceSet(scope: scope, candidate: candidate),
                    localIdentifier: candidate.localIdentifier, sourceRevision: candidate.sourceRevision,
                    kind: candidate.kind, capturedAt: candidate.capturedAt,
                    resources: UploadIdentity.resources(scope: scope, candidate: candidate),
                    phase: candidate.discoveryError == nil ? .queued : .failed,
                    error: candidate.discoveryError, createdAt: now(), updatedAt: now())
                try save(item)
            }
        }
    }

    func finishDiscovery(_ candidates: [UploadCandidate], checkpoint: Data?, scope: String) throws {
        try database.transaction {
            try discover(candidates, scope: scope)
            try database.execute(
                "UPDATE upload_scopes SET scanning=0,checkpoint=? WHERE scope=?",
                [checkpoint.map { .blob($0) } ?? .null, .text(scope)])
            try closeDrainedBatch(scope)
        }
    }

    func item(id: UUID, scope: String) throws -> UploadItem? {
        try decode(
            database.rows(
                "SELECT payload FROM upload_items WHERE id=? AND scope=?",
                [.text(id.uuidString), .text(scope)]
            ).first)
    }

    func items(localIdentifiers: [String], scope: String) throws -> [UploadItem] {
        var result: [UploadItem] = []
        for id in Set(localIdentifiers) {
            if let item = try decode(
                database.rows(
                    "SELECT payload FROM upload_items WHERE scope=? AND local_id=? ORDER BY updated DESC LIMIT 1",
                    [.text(scope), .text(id)]
                ).first)
            {
                result.append(item)
            }
        }
        return result
    }

    func pending(scope: String, limit: Int = 16) throws -> [UploadItem] {
        try database.rows(
            """
            SELECT payload FROM upload_items WHERE scope=? AND phase NOT IN ('succeeded','failed')
            ORDER BY CASE phase WHEN 'verifying' THEN 0 WHEN 'uploading' THEN 1 WHEN 'scheduled' THEN 1
                WHEN 'preparing' THEN 2 ELSE 3 END,updated,id LIMIT ?
            """, [.text(scope), .integer(Int64(max(0, limit)))]
        ).map {
            guard let item = try decode($0) else { throw corrupt() }
            return item
        }
    }

    func update(_ item: UploadItem) throws {
        try database.transaction {
            guard let current = try self.item(id: item.id, scope: item.scope),
                current.sourceRevision == item.sourceRevision,
                current.generation == item.generation,
                current.resources.map(\.id) == item.resources.map(\.id)
            else { throw CancellationError() }
            if current.phase == .succeeded { return }
            if item.phase == .succeeded,
                !item.committed
                    || !item.resources.allSatisfy({
                        $0.phase == .ready && ($0.expectedBytes ?? 0) > 0
                            && $0.sha256?.count == 64
                    })
            {
                throw ClientError.invalid("Incomplete media cannot be marked as backed up.")
            }
            var updated = item
            for index in updated.resources.indices where current.resources[index].phase == .ready {
                updated.resources[index] = current.resources[index]
            }
            updated.updatedAt = now()
            try save(updated)
        }
    }

    func retryFailed(scope: String) throws {
        try database.transaction {
            for var item in try load("scope=? AND phase='failed'", [.text(scope)], limit: Int.max) {
                item.phase = .queued
                item.generation = UUID()
                item.error = nil
                item.updatedAt = now()
                for index in item.resources.indices where item.resources[index].phase != .ready {
                    item.resources[index].phase = .pending
                    item.resources[index].needsRestart = true
                    item.resources[index].attempts = 0
                    item.resources[index].error = nil
                    item.resources[index].retryAfter = nil
                }

                try save(item)
            }
        }
    }

    func snapshot(scope: String, limit: Int = 100) throws -> UploadSnapshot {
        try ensure(scope)
        let account = try settings(scope)
        let row = try database.rows(
            """
            SELECT b.id,b.created,b.completed,count(i.id),
                coalesce(sum(i.phase='succeeded'),0),coalesce(sum(i.phase='failed'),0)
            FROM upload_batches b LEFT JOIN upload_items i ON i.batch_id=b.id
            WHERE b.scope=? GROUP BY b.id
            ORDER BY b.completed IS NULL DESC,b.created DESC LIMIT 1
            """, [.text(scope)]
        ).first
        var batch: UploadBatch?
        if let row {
            guard let id = UUID(uuidString: try string(row[0])) else { throw corrupt() }
            batch = UploadBatch(
                id: id, total: Int(try integer(row[3])), succeeded: Int(try integer(row[4])),
                failed: Int(try integer(row[5])), createdAt: Date(timeIntervalSince1970: try number(row[1])),
                completedAt: try optionalNumber(row[2]).map { Date(timeIntervalSince1970: $0) })
        }
        let counts = try database.rows(
            """
            SELECT coalesce(sum(phase='succeeded'),0),coalesce(sum(phase='failed'),0),
                coalesce(sum(phase NOT IN ('succeeded','failed')),0)
            FROM upload_items WHERE scope=?
            """, [.text(scope)]
        ).first
        guard let counts else { throw corrupt() }
        return UploadSnapshot(
            policy: account.policy, paused: account.paused, scanning: account.scanning,
            notice: account.notice, batch: batch,
            succeeded: try load("scope=? AND phase='succeeded'", [.text(scope)], limit: limit),
            failed: try load("scope=? AND phase='failed'", [.text(scope)], limit: limit),
            pending: try pending(scope: scope, limit: limit),
            succeededCount: Int(try integer(counts[0])), failedCount: Int(try integer(counts[1])),
            pendingCount: Int(try integer(counts[2])))
    }

}

extension SQLiteUploadRepository {
    private func ensure(_ scope: String) throws {
        guard !scope.isEmpty else { throw ClientError.invalid("The upload account is missing.") }
        try database.execute("INSERT OR IGNORE INTO upload_scopes(scope) VALUES(?)", [.text(scope)])
    }

    private struct ScopeSettings {
        let policy: UploadPolicy
        let paused: Bool
        let scanning: Bool
        let notice: String?
    }

    private func settings(_ scope: String) throws -> ScopeSettings {
        guard
            let row = try database.rows(
                "SELECT policy,paused,scanning,notice FROM upload_scopes WHERE scope=?", [.text(scope)]
            ).first, let policy = UploadPolicy(rawValue: try string(row[0]))
        else { throw corrupt() }
        let notice: String?
        if case .null = row[3] { notice = nil } else { notice = try string(row[3]) }
        return ScopeSettings(
            policy: policy, paused: try integer(row[1]) != 0, scanning: try integer(row[2]) != 0, notice: notice)
    }

    private func activeBatch(_ scope: String) throws -> UUID {
        guard
            let row = try database.rows(
                "SELECT active_batch FROM upload_scopes WHERE scope=?", [.text(scope)]
            ).first
        else { throw corrupt() }
        if case .text(let value) = row[0] {
            guard let id = UUID(uuidString: value) else { throw corrupt() }
            return id
        }
        let id = UUID()
        try database.execute(
            "INSERT INTO upload_batches(id,scope,created) VALUES(?,?,?)",
            [.text(id.uuidString), .text(scope), .real(now().timeIntervalSince1970)])
        try database.execute(
            "UPDATE upload_scopes SET active_batch=? WHERE scope=?", [.text(id.uuidString), .text(scope)])
        return id
    }

    private func closeDrainedBatch(_ scope: String) throws {
        guard
            let row = try database.rows(
                "SELECT active_batch FROM upload_scopes WHERE scope=? AND scanning=0", [.text(scope)]
            ).first, case .text(let id) = row[0]
        else { return }
        let remaining = try database.rows(
            "SELECT count(*) FROM upload_items WHERE batch_id=? AND phase<>'succeeded'", [.text(id)])
        guard let count = remaining.first, try integer(count[0]) == 0 else { return }
        try database.execute(
            "UPDATE upload_batches SET completed=? WHERE id=? AND completed IS NULL",
            [.real(now().timeIntervalSince1970), .text(id)])
        try database.execute("UPDATE upload_scopes SET active_batch=NULL WHERE scope=?", [.text(scope)])
    }

    private func save(_ item: UploadItem) throws {
        try database.execute(
            """
            INSERT INTO upload_items(id,scope,batch_id,local_id,revision,phase,updated,payload)
            VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,phase=excluded.phase,
                updated=excluded.updated,payload=excluded.payload
            """,
            [
                .text(item.id.uuidString), .text(item.scope), .text(item.batchID.uuidString),
                .text(item.localIdentifier), .text(item.sourceRevision), .text(item.phase.rawValue),
                .real(item.updatedAt.timeIntervalSince1970), .blob(try encoder.encode(item)),
            ])
    }

    private func load(
        _ predicate: String, _ values: [UploadDatabase.Value], limit: Int
    ) throws -> [UploadItem] {
        return try database.rows(
            "SELECT payload FROM upload_items WHERE \(predicate) ORDER BY updated DESC,id LIMIT ?",
            values + [.integer(Int64(max(0, limit)))]
        ).map {
            guard let item = try decode($0) else { throw corrupt() }
            return item
        }
    }

    private func decode(_ row: [UploadDatabase.Value]?) throws -> UploadItem? {
        guard let row else { return nil }
        guard case .blob(let data) = row[0] else { throw corrupt() }
        return try decoder.decode(UploadItem.self, from: data)
    }

    private func string(_ value: UploadDatabase.Value) throws -> String {
        guard case .text(let text) = value else { throw corrupt() }
        return text
    }
    private func integer(_ value: UploadDatabase.Value) throws -> Int64 {
        guard case .integer(let number) = value else { throw corrupt() }
        return number
    }
    private func number(_ value: UploadDatabase.Value) throws -> Double {
        switch value {
        case .real(let number): number
        case .integer(let number): Double(number)
        default: throw corrupt()
        }
    }
    private func optionalNumber(_ value: UploadDatabase.Value) throws -> Double? {
        if case .null = value { return nil }
        return try number(value)
    }
    private func corrupt() -> ClientError { .invalid("The upload database contains an invalid record.") }
}
