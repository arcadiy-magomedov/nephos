import Foundation

struct GallerySnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let revision: Int64
    let accessGeneration: Int64
    let expiresAt: String
    let totalCount: Int64
}
struct TimelineBucket: Codable, Identifiable, Equatable, Sendable {
    let date: String
    let count: Int64
    var id: String { date }
}
struct TimelinePage: Codable, Sendable { let items: [TimelineBucket] }
struct GalleryChange: Codable, Sendable {
    let operation: String
    let assetId: UUID
    let asset: Asset?
}
struct GalleryRevision: Codable, Sendable {
    let revision: Int64
    let items: [GalleryChange]
}
struct GalleryChanges: Codable, Sendable {
    let fromRevision: Int64
    let toRevision: Int64
    let targetRevision: Int64
    let hasMore: Bool
    let changes: [GalleryRevision]

    func validate(after: Int64, through: Int64, library: UUID) throws {
        guard fromRevision == after, targetRevision == through, toRevision >= after, toRevision <= through,
            !hasMore || toRevision > after, hasMore || toRevision == through,
            changes.count <= 20
        else { throw ClientError.invalid("Invalid delta page boundary; previous snapshot preserved.") }
        var previous = after
        for revision in changes {
            guard revision.revision > previous, revision.revision <= toRevision, !revision.items.isEmpty,
                revision.items.allSatisfy({ item in
                    if item.operation == "remove" { return item.asset == nil }
                    return item.operation == "upsert" && item.asset?.id == item.assetId
                        && item.asset?.libraryId == library
                })
            else { throw ClientError.invalid("Invalid atomic gallery revision; previous snapshot preserved.") }
            previous = revision.revision
        }
    }
}

struct RetainedGallery: Codable, Sendable {
    let library: Library
    var snapshot: GallerySnapshot
    var window: GalleryWindow
    var anchor: GalleryCursor?
    var updatedAt: Date
    var startsAtNewest: Bool?
}

struct GalleryRefreshTrigger: Hashable {
    let active: Bool
    let connected: Bool
    let ready: Bool
    let epoch: UUID
    let library: UUID?
    var enabled: Bool { active && connected && ready && library != nil }
}

enum GalleryRefreshPolicy {
    static func delay(failures: Int) -> Double {
        failures == 0 ? 15 : min(300, 15 * pow(2, Double(min(failures, 5))))
    }
    static func unchanged(_ old: GallerySnapshot, _ new: GallerySnapshot) -> Bool {
        old.revision == new.revision && old.accessGeneration == new.accessGeneration
    }
}

enum GalleryDates {
    static func endOfBucket(_ date: String) throws -> GalleryCursor {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == date.split(separator: "-").count else {
            throw ClientError.invalid("Invalid timeline date.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: parts[0], month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
        guard let start = calendar.date(from: components),
            calendar.component(.year, from: start) == parts[0],
            calendar.component(.month, from: start) == (parts.count > 1 ? parts[1] : 1),
            calendar.component(.day, from: start) == (parts.count > 2 ? parts[2] : 1),
            let end = calendar.date(
                byAdding: parts.count == 1 ? .year : (parts.count == 2 ? .month : .day), value: 1, to: start)
        else { throw ClientError.invalid("Invalid timeline date.") }
        return GalleryCursor(
            createdAt: ISO8601DateFormatter().string(from: end),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }
    static func inclusiveAnchor(_ anchor: GalleryCursor) -> GalleryCursor {
        // Include exactly this ID, even when thousands of captures have the same timestamp.
        var bytes = withUnsafeBytes(of: anchor.id.uuid) { Array($0) }
        for index in bytes.indices.reversed() {
            let (next, overflow) = bytes[index].addingReportingOverflow(1)
            bytes[index] = next
            if !overflow {
                let hex = bytes.map { String(format: "%02x", $0) }.joined()
                let offsets = [8, 12, 16, 20]
                var formatted = ""
                for (offset, character) in hex.enumerated() {
                    if offsets.contains(offset) { formatted += "-" }
                    formatted.append(character)
                }
                return GalleryCursor(createdAt: anchor.createdAt, id: UUID(uuidString: formatted)!)
            }
        }
        return anchor
    }
}

extension API {
    func snapshot(library: UUID) async throws -> GallerySnapshot {
        try await json(GallerySnapshot.self, "v1/libraries/\(library)/snapshots", method: "POST", body: Data())
    }
    func assets(library: UUID, snapshot: UUID, cursor: GalleryCursor?) async throws -> AssetPage {
        try await json(
            AssetPage.self, "v1/libraries/\(library)/snapshots/\(snapshot)/assets",
            query: Paging.gallery(before: cursor))
    }
    func timeline(library: UUID, snapshot: UUID, year: Int? = nil, month: Int? = nil) async throws -> [TimelineBucket] {
        var query: [URLQueryItem] = []
        if let year { query.append(URLQueryItem(name: "year", value: String(year))) }
        if let month { query.append(URLQueryItem(name: "month", value: String(month))) }
        return try await json(TimelinePage.self, "v1/libraries/\(library)/snapshots/\(snapshot)/timeline", query: query)
            .items
    }
    func changes(library: UUID, after: Int64, through: Int64) async throws -> GalleryChanges {
        let page = try await json(
            GalleryChanges.self, "v1/libraries/\(library)/changes",
            query: [
                URLQueryItem(name: "after", value: String(after)),
                URLQueryItem(name: "through", value: String(through)),
                URLQueryItem(name: "limit", value: "20"),
            ])
        try page.validate(after: after, through: through, library: library)
        return page
    }
}
