import CoreGraphics
import Foundation

extension GalleryDates {
    static func parse(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all, photos, videos, shared
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .shared: "Shared"
        }
    }
    func includes(_ asset: Asset) -> Bool {
        switch self {
        case .all: true
        case .photos: asset.mediaType.hasPrefix("image/")
        case .videos: asset.isVideo
        case .shared: asset.sharedBy != nil
        }
    }
}

struct MediaDay: Identifiable {
    let id: String
    let date: Date?
    var assets: [Asset]

    static func groups(_ assets: [Asset], filter: MediaFilter = .all, calendar: Calendar = .current) -> [MediaDay] {
        var groups: [MediaDay] = []
        var indices: [String: Int] = [:]
        for asset in assets where filter.includes(asset) {
            let date = GalleryDates.parse(asset.createdAt).map { calendar.startOfDay(for: $0) }
            let key = date.map { String($0.timeIntervalSince1970) } ?? "unknown"
            if let index = indices[key] {
                groups[index].assets.append(asset)
            } else {
                indices[key] = groups.count
                groups.append(MediaDay(id: key, date: date, assets: [asset]))
            }
        }
        return groups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

struct BackupProgress {
    let total: Int
    let verified: Int
    let pending: Int
    let failed: Int
    var fraction: Double { total == 0 ? 0 : Double(verified) / Double(total) }

    init(ledger: AccountLedger, library: UUID?) {
        let records = ledger.records.filter { $0.libraryId == library && $0.remoteRemoved != true }
        total = records.count
        verified = records.filter { $0.phase == .ready && $0.evidence?.available == true }.count
        pending = records.filter(\.needsTransfer).count
        failed = records.filter { $0.phase == .failed || $0.phase == .sourceChanged }.count
    }
}

extension FaceObservation {
    func cropRect(pixelWidth: Int, pixelHeight: Int) -> CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite),
            x >= 0, y >= 0, width > 0, height > 0,
            x + width <= 1.000001, y + height <= 1.000001,
            pixelWidth > 0, pixelHeight > 0
        else { return nil }
        let rect = CGRect(
            x: x * Double(pixelWidth), y: y * Double(pixelHeight),
            width: width * Double(pixelWidth), height: height * Double(pixelHeight))
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return clipped.isEmpty ? nil : clipped
    }
}
