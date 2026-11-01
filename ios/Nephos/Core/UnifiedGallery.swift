import Foundation

struct LocalGalleryAsset: Equatable, Sendable {
    let identifier: String
    let date: Date?
    let isVideo: Bool
}

struct GalleryMedia: Identifiable, Sendable {
    let id: String
    let asset: Asset?
    let localIdentifier: String?
    let shared: Bool
    let uploaded: Bool
    let date: Date?
    let isVideo: Bool

    static func remoteID(_ id: UUID) -> String { "asset:\(id)" }
}

struct GalleryMediaDay: Identifiable, Sendable {
    let id: String
    let date: Date?
    var items: [GalleryMedia]
}

struct UnifiedGalleryInput: Equatable, Sendable {
    let remote: [Asset]
    let local: [LocalGalleryAsset]
    let records: [UploadRecord]
    let readOnlyLibraries: Set<UUID>
    let selectedLibrary: UUID?
    let filter: MediaFilter
}

struct UnifiedGallerySnapshot: Sendable {
    var items: [GalleryMedia] = []
    var filtered: [GalleryMedia] = []
    var days: [GalleryMediaDay] = []
    var pending = 0

    static func build(_ input: UnifiedGalleryInput, calendar: Calendar = .current) throws -> Self {
        try Task.checkCancellation()
        var byAsset: [UUID: UploadRecord] = [:]
        var byLocal: [String: UploadRecord] = [:]
        var pending = 0
        for record in input.records {
            try Task.checkCancellation()
            if byAsset[record.committedAssetID] == nil { byAsset[record.committedAssetID] = record }
            if record.remoteRemoved != true, byLocal[record.source.localIdentifier] == nil {
                byLocal[record.source.localIdentifier] = record
            }
            if record.libraryId == input.selectedLibrary, record.needsTransfer { pending += 1 }
        }
        let local = Dictionary(input.local.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var knownLocal: Set<String> = []
        var knownRemote: Set<UUID> = []
        var items: [GalleryMedia] = []
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for asset in input.remote where knownRemote.insert(asset.id).inserted {
            try Task.checkCancellation()
            let identifier = byAsset[asset.id]?.source.localIdentifier
            let localAsset = identifier.flatMap { local[$0] }
            if let localAsset { knownLocal.insert(localAsset.identifier) }
            items.append(
                GalleryMedia(
                    id: GalleryMedia.remoteID(asset.id), asset: asset, localIdentifier: localAsset?.identifier,
                    shared: asset.sharedBy != nil || input.readOnlyLibraries.contains(asset.libraryId),
                    uploaded: true, date: precise.date(from: asset.createdAt) ?? plain.date(from: asset.createdAt),
                    isVideo: asset.isVideo))
        }
        for asset in input.local where !knownLocal.contains(asset.identifier) {
            try Task.checkCancellation()
            items.append(
                GalleryMedia(
                    id: "local:\(asset.identifier)", asset: nil, localIdentifier: asset.identifier,
                    shared: false, uploaded: byLocal[asset.identifier]?.phase == .ready,
                    date: asset.date, isVideo: asset.isVideo))
        }
        items.sort {
            let lhs = $0.date ?? .distantPast
            let rhs = $1.date ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        let filtered = items.filter {
            switch input.filter {
            case .all: true
            case .photos: !$0.isVideo
            case .videos: $0.isVideo
            case .shared: $0.shared
            }
        }
        var days: [GalleryMediaDay] = []
        var indices: [String: Int] = [:]
        for item in filtered {
            try Task.checkCancellation()
            let date = item.date.map { calendar.startOfDay(for: $0) }
            let key = date.map { String($0.timeIntervalSince1970) } ?? "unknown"
            if let index = indices[key] {
                days[index].items.append(item)
            } else {
                indices[key] = days.count
                days.append(GalleryMediaDay(id: key, date: date, items: [item]))
            }
        }
        return Self(items: items, filtered: filtered, days: days, pending: pending)
    }
}
