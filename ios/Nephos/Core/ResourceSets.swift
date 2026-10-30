import Foundation

struct ResourcePart: Codable, Equatable, Sendable {
    let assetId: UUID
    let role: String
    let sha256: String
    let size: Int64
    let fileName: String
    let uniformTypeIdentifier: String
}

struct ResourceSetIntent: Codable, Equatable, Sendable {
    let kind: String
    let sourceRevision: String
    let primaryAssetId: UUID
    let resources: [ResourcePart]
}

struct ResourceManifest: Codable, Equatable, Sendable {
    let id: UUID
    let libraryId: UUID
    let kind: String
    let sourceRevision: String
    let primaryAssetId: UUID
    let resources: [ResourcePart]
    let createdAt: String

    var intent: ResourceSetIntent {
        ResourceSetIntent(
            kind: kind, sourceRevision: sourceRevision, primaryAssetId: primaryAssetId, resources: resources)
    }

    func validate(primary: Asset) throws {
        guard libraryId == primary.libraryId, primaryAssetId == primary.id,
            primary.resourceSetId == nil || primary.resourceSetId == id,
            (1...16).contains(resources.count),
            Set(resources.map(\.assetId)).count == resources.count,
            resources.contains(where: {
                $0.assetId == primary.id && $0.sha256 == primary.sha256 && $0.size == primary.size
            }),
            resources.allSatisfy({
                $0.size > 0 && $0.sha256.count == 64 && $0.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            })
        else { throw ClientError.invalid("Resource manifest does not match the selected original.") }
    }

    var restoreSupported: Bool {
        let roles = resources.map(\.role).sorted()
        if kind == "single", resources.count == 1 { return ["photo", "video"].contains(resources[0].role) }
        if kind == "live-photo" { return roles == ["pairedVideo", "photo"] }
        if kind == "raw-jpeg" { return roles == ["alternatePhoto", "photo"] }
        return false
    }
}

struct ResourceSetRetention: Codable, Sendable {
    let id: UUID
    let assurance: String
    let retainedUntil: String
    let resources: [RetentionHold]

    func validates(_ manifest: ResourceManifest, now: Date = Date()) -> Bool {
        id == manifest.id && assurance == "single-volume-no-independent-backup"
            && resources.count == manifest.resources.count
            && manifest.resources.allSatisfy { part in
                resources.contains {
                    $0.allowsRemoval(id: part.assetId, sha256: part.sha256, size: part.size, now: now)
                }
            }
    }
}

struct ResourceSetRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let libraryId: UUID
    let source: SourceRevision
    let kind: String
    var manifest: ResourceManifest?
    var error: String?
    var retention: ResourceSetRetention?
    var retryCount: Int?
    var nextRetryAt: Date?

    func intent(records: [UploadRecord]) throws -> ResourceSetIntent {
        let matching = records.filter { $0.resourceSetId == id }.sorted { $0.resourceIndex < $1.resourceIndex }
        guard (1...16).contains(source.resourceNames.count),
            matching.count == source.resourceNames.count,
            matching.map(\.resourceIndex) == Array(source.resourceNames.indices),
            matching.allSatisfy({
                $0.source == source && $0.libraryId == libraryId && $0.phase == .ready
                    && $0.evidence?.id == $0.committedAssetID && $0.evidence?.available == true
                    && $0.evidence?.sha256 == $0.sha256 && $0.evidence?.size == $0.size && $0.resourceRole != nil
                    && $0.uniformTypeIdentifier != nil && $0.remoteRemoved != true
            })
        else {
            throw ClientError.invalid(
                "Resource set is incomplete. Every required original must be verified before publication.")
        }
        let parts = matching.map {
            ResourcePart(
                assetId: $0.committedAssetID, role: $0.resourceRole!,
                sha256: $0.sha256, size: $0.size, fileName: $0.fileName,
                uniformTypeIdentifier: $0.uniformTypeIdentifier!)
        }
        let primary =
            parts.first(where: { $0.role == "fullSizePhoto" || $0.role == "fullSizeVideo" }) ?? parts.first(where: {
                $0.role == "photo" || $0.role == "video"
            }) ?? parts[0]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Preserve the complete revision, not just modification time or a resource's hash.
        let revision = String(decoding: try encoder.encode(source), as: UTF8.self)
        return ResourceSetIntent(
            kind: kind, sourceRevision: revision, primaryAssetId: primary.assetId, resources: parts)
    }
}

extension API {
    func publish(_ group: ResourceSetRecord, records: [UploadRecord]) async throws -> ResourceManifest {
        let intent = try group.intent(records: records)
        let result = try await json(
            ResourceManifest.self, "v1/libraries/\(group.libraryId)/resource-sets/\(group.id)",
            method: "PUT", body: JSONEncoder().encode(intent))
        guard result.id == group.id, result.libraryId == group.libraryId, result.intent == intent else {
            throw ClientError.invalid("Published manifest differs from the complete local resource set.")
        }
        return result
    }
    func resources(_ asset: Asset) async throws -> ResourceManifest? {
        do {
            let result = try await json(ResourceManifest.self, "v1/assets/\(asset.id)/resources")
            try result.validate(primary: asset)
            return result
        } catch ClientError.http(404, _) where asset.resourceSetId == nil { return nil }
    }
    func retain(_ manifest: ResourceManifest) async throws -> ResourceSetRetention {
        let result = try await json(
            ResourceSetRetention.self, "v1/resource-sets/\(manifest.id)/retention", method: "POST", body: Data())
        guard result.validates(manifest) else {
            throw ClientError.invalid("Not every resource has a fresh matching retention hold.")
        }
        return result
    }
}
