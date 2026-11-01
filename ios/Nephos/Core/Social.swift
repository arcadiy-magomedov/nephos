import Foundation

struct TrashCursor: Codable, Hashable, Sendable {
    let deletedAt: String
    let id: UUID
}

struct TrashItem: Codable, Identifiable, Equatable, Sendable {
    let asset: Asset
    let deletedAt: String
    let purgeAfter: String
    var id: UUID { asset.id }
}

struct TrashPage: Codable, Sendable {
    let items: [TrashItem]
    let nextCursor: TrashCursor?

    func validate(before: TrashCursor?) throws {
        guard items.count <= 50, Set(items.map(\.id)).count == items.count,
            items.allSatisfy({ item in
                guard item.asset.sharedBy == nil, let deleted = GalleryDates.parse(item.deletedAt),
                    let purge = GalleryDates.parse(item.purgeAfter)
                else { return false }
                return purge > deleted
            }),
            nextCursor == nil || nextCursor != before,
            nextCursor == nil
                || items.last.map({
                    $0.id == nextCursor?.id && $0.deletedAt == nextCursor?.deletedAt
                }) == true
        else { throw ClientError.invalid("Invalid trash page. Previously loaded items were preserved.") }
    }
}

struct MediaDeletionResult: Sendable {
    var deleted: Set<UUID> = []
    var failed: [UUID: String] = [:]
    var removedLocal: Set<String> = []
    var photosError: String?
    var localStatusError: String?
}

struct FacePerson: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String?
    let aliases: [String]
    let redirectId: UUID?
    var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed person" }
}

struct FaceObservation: Codable, Identifiable, Sendable {
    let id: UUID
    let assetId: UUID
    let personId: UUID?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let quality: String
}

struct FacePage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let next: UUID?
}

struct FaceCorrection: Decodable, Identifiable, Sendable {
    let id: UUID
    let kind: String
    let subjectId: UUID
    let targetId: UUID?
    let createdAt: String
    var title: String {
        switch kind {
        case "name": "Name updated"
        case "merge": "Groups merged"
        case "unmerge": "Merge undone"
        case "split": "Face separated"
        case "assign": "Face reassigned"
        case "negative": "Marked as different people"
        case "negative_removed": "Different-person rule removed"
        default: "Face correction"
        }
    }
}

struct DirectoryUser: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct DirectoryPage: Decodable, Sendable {
    let items: [DirectoryUser]
    let nextCursor: String?
}

struct MediaShare: Codable, Identifiable, Sendable {
    let id: UUID
    let libraryId: UUID
    let libraryName: String
    let ownerId: String
    let ownerName: String
    let recipientId: String
    let recipientName: String
    let allAssets: Bool
    let assetIds: [UUID]
}

struct SharePage: Decodable, Sendable {
    let items: [MediaShare]
    let nextCursor: UUID?
}

struct ShareInput: Encodable, Sendable {
    let libraryId: UUID
    let recipientId: String
    let allAssets: Bool
    let assetIds: [UUID]

    func validate() throws {
        guard UUID(uuidString: recipientId) != nil, assetIds.count <= 500,
            Set(assetIds).count == assetIds.count, allAssets ? assetIds.isEmpty : !assetIds.isEmpty
        else { throw ClientError.invalid("Choose a known user and either selected items or all your library media.") }
    }
}

struct PersonNameInput: Encodable, Sendable {
    let name: String?
    let aliases: [String]

    func validate() throws {
        guard (name?.count ?? 0) <= 120, aliases.count <= 10,
            aliases.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 120 })
        else { throw ClientError.invalid("Use a name up to 120 characters and at most 10 nonempty aliases.") }
    }
}

extension API {
    func trash(before: TrashCursor? = nil) async throws -> TrashPage {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let before {
            query += [
                URLQueryItem(name: "before", value: before.deletedAt),
                URLQueryItem(name: "beforeId", value: before.id.uuidString),
            ]
        }
        let page = try await json(TrashPage.self, "v1/trash", query: query)
        try page.validate(before: before)
        return page
    }

    func restoreAsset(_ id: UUID) async throws {
        try await change("v1/assets/\(id)/restore", method: "POST")
    }

    func trashPreviewRequest(_ id: UUID, size: PreviewSize = .thumbnail) async throws -> URLRequest {
        var result = try await request(
            "v1/trash/\(id)/preview",
            query: [
                URLQueryItem(name: "size", value: String(size.rawValue))
            ])
        result.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        return result
    }

    func deleteAsset(_ id: UUID) async throws {
        try await change("v1/assets/\(id)", method: "DELETE")
    }

    func assets(ids: [UUID]) async throws -> [Asset] {
        guard ids.count <= 50 else { throw ClientError.invalid("Load at most 50 assets at a time.") }
        var result: [Asset] = []
        for id in ids {
            try Task.checkCancellation()
            result.append(try await asset(id))
        }
        return result
    }

    private func faceQuery(after: UUID?, name: String? = nil) -> [URLQueryItem] {
        var query = Paging.libraries(after: after)
        if let name, !name.isEmpty { query.append(URLQueryItem(name: "name", value: name)) }
        return query
    }

    func asset(_ id: UUID) async throws -> Asset {
        let result = try await json(Asset.self, "v1/assets/\(id)")
        guard result.id == id else { throw ClientError.invalid("Asset metadata returned a different original.") }
        return result
    }

    func people(after: UUID? = nil, name: String? = nil) async throws -> FacePage<FacePerson> {
        guard (name?.count ?? 0) <= 120 else { throw ClientError.invalid("Search is limited to 120 characters.") }
        let result = try await json(
            FacePage<FacePerson>.self, "v1/faces/people", query: faceQuery(after: after, name: name))
        guard result.next == nil || result.next != after else { throw ClientError.invalid("Repeated people cursor.") }
        return result
    }

    func person(_ id: UUID) async throws -> FacePerson {
        let result = try await json(FacePerson.self, "v1/faces/people/\(id)")
        guard result.id == id else { throw ClientError.invalid("Person response returned a different identity.") }
        return result
    }

    func personAssets(_ id: UUID, after: UUID? = nil) async throws -> FacePage<UUID> {
        let page = try await json(FacePage<UUID>.self, "v1/faces/people/\(id)/assets", query: faceQuery(after: after))
        guard page.next == nil || page.next != after else { throw ClientError.invalid("Repeated person-photo cursor.") }
        return page
    }

    func observations(asset: UUID? = nil, person: UUID? = nil, after: UUID? = nil) async throws -> FacePage<
        FaceObservation
    > {
        var query = faceQuery(after: after)
        if let asset { query.append(URLQueryItem(name: "assetId", value: asset.uuidString)) }
        if let person { query.append(URLQueryItem(name: "personId", value: person.uuidString)) }
        let page = try await json(FacePage<FaceObservation>.self, "v1/faces/observations", query: query)
        guard page.next == nil || page.next != after else { throw ClientError.invalid("Repeated observations cursor.") }
        return page
    }

    func change(_ path: String, method: String, body: Data? = nil) async throws {
        _ = try await HTTP.data(request(path, method: method, body: body), session: session)
    }

    func namePerson(_ id: UUID, input: PersonNameInput) async throws {
        try input.validate()
        try await change("v1/faces/people/\(id)/name", method: "PUT", body: JSONEncoder().encode(input))
    }

    func mergePerson(_ source: UUID, into target: UUID) async throws {
        guard source != target else { throw ClientError.invalid("Choose a different person to merge into.") }
        try await change(
            "v1/faces/people/\(source)/merge", method: "POST",
            body: JSONEncoder().encode(["targetId": target]))
    }

    func undoMerge(_ source: UUID) async throws {
        try await change("v1/faces/people/\(source)/merge", method: "DELETE")
    }

    func splitObservation(_ id: UUID) async throws {
        try await change(
            "v1/faces/observations/\(id)/person", method: "PUT",
            body: JSONEncoder().encode(["newPerson": true]))
    }

    func assignObservation(_ id: UUID, person: UUID) async throws {
        try await change(
            "v1/faces/observations/\(id)/person", method: "PUT",
            body: JSONEncoder().encode(["personId": person]))
    }

    func negativeMatch(_ first: UUID, other: UUID) async throws {
        guard first != other else { throw ClientError.invalid("Choose two different people.") }
        try await change(
            "v1/faces/people/\(first)/negative-matches", method: "POST",
            body: JSONEncoder().encode(["otherId": other]))
    }

    func removeNegativeMatch(_ first: UUID, other: UUID) async throws {
        try await change("v1/faces/people/\(first)/negative-matches/\(other)", method: "DELETE")
    }

    func corrections(after: UUID? = nil) async throws -> FacePage<FaceCorrection> {
        let page = try await json(
            FacePage<FaceCorrection>.self, "v1/faces/corrections", query: faceQuery(after: after))
        guard page.next == nil || page.next != after else {
            throw ClientError.invalid("Repeated correction cursor.")
        }
        return page
    }

    func directory(after: String? = nil) async throws -> DirectoryPage {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        let page = try await json(DirectoryPage.self, "v1/users", query: query)
        guard page.nextCursor == nil || page.nextCursor != after else {
            throw ClientError.invalid("Repeated user cursor.")
        }
        return page
    }

    func shares(after: UUID? = nil) async throws -> SharePage {
        let page = try await json(SharePage.self, "v1/shares", query: Paging.libraries(after: after))
        guard page.nextCursor == nil || page.nextCursor != after else {
            throw ClientError.invalid("Repeated share cursor.")
        }
        return page
    }

    func putShare(_ id: UUID, input: ShareInput) async throws -> MediaShare {
        try input.validate()
        return try await json(MediaShare.self, "v1/shares/\(id)", method: "PUT", body: JSONEncoder().encode(input))
    }

    func deleteShare(_ id: UUID) async throws {
        try await change("v1/shares/\(id)", method: "DELETE")
    }
}
