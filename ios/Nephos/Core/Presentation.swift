import CoreGraphics
import Foundation

struct ServerAdvertisement: Identifiable, Equatable, Sendable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }

    init(name: String, version: String, address: String) throws {
        guard version == "1", !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 63, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            address.utf8.count <= 251,
            !address.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            })
        else { throw ClientError.invalid("Unsupported server announcement.") }
        let url = try URLPolicy.validate(address)
        guard !OnboardingPolicy.isLoopback((url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))),
            !["0.0.0.0", "::", "[::]"].contains(url.host ?? ""),
            (1...65535).contains(url.port ?? 443)
        else { throw ClientError.invalid("An announced server must have a reachable address and valid port.") }
        self.name = name
        self.url = url
    }
}

struct OnboardingDraft: Codable, Equatable, Sendable {
    var libraryID: UUID
    var backup: Bool
    var allowCellular: Bool
    var ready: Bool
}

enum OnboardingPolicy {
    static func requiresServerReview(_ connection: Connection, draftURL: String) -> Bool {
        guard draftURL == connection.baseURL.absoluteString, let issuer = URL(string: connection.config.issuer) else {
            return true
        }
        return isLoopback(issuer.host ?? "") && !isLoopback(connection.baseURL.host ?? "")
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    static func validateIssuer(_ issuer: URL, server: URL) throws {
        if isLoopback(issuer.host ?? ""), !isLoopback(server.host ?? "") {
            throw ClientError.invalid(
                "The sign-in address points to localhost, which means this device, not your server. Ask the administrator to correct the public OIDC issuer."
            )
        }
    }

    static func completed(settings: BackupSettings, selectedLibrary: UUID?, hasResources: Bool) -> Bool {
        settings.onboardingCompleted ?? (selectedLibrary != nil || hasResources)
    }
}

struct OnboardingFailure: LocalizedError {
    let title: String
    let guidance: String
    let detail: String
    let address: String?
    var errorDescription: String? { "\(title). \(guidance) \(detail)" }

    init(_ error: Error, identity: Bool = false, address: String? = nil) {
        if let existing = error as? OnboardingFailure {
            self = existing
            return
        }
        detail = error.localizedDescription
        self.address = address
        if let urlError = error as? URLError {
            switch urlError.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .secureConnectionFailed:
                title = "Certificate not trusted"
                guidance =
                    "Use the hostname covered by the certificate. For a local development CA, installing its profile is not enough: also enable full trust in Settings > General > About > Certificate Trust Settings. Only trust a CA supplied by your administrator. Certificate checks cannot be skipped."
            default:
                title = identity ? "Sign-in server unavailable" : "Server unavailable"
                guidance =
                    "Check the address, Wi-Fi or VPN, and the Local Network permission in iPhone Settings. A connection failure alone does not identify the cause."
            }
        } else {
            title = identity ? "Check the sign-in address" : "Server check failed"
            guidance = "Review the details below or contact your server administrator."
        }
    }
}

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

enum MediaFilter: String, CaseIterable, Identifiable, Sendable {
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
    let awaitingPublication: Int
    var isComplete: Bool { total > 0 && verified == total && failed == 0 && awaitingPublication == 0 }
    var fraction: Double { total == 0 ? 0 : Double(verified) / Double(total) }

    init(ledger: AccountLedger, library: UUID?) {
        let records = ledger.records.filter { $0.libraryId == library && $0.remoteRemoved != true }
        total = records.count
        verified = records.filter { $0.phase == .ready && $0.evidence?.available == true }.count
        pending = records.filter(\.needsTransfer).count
        awaitingPublication =
            (ledger.resourceSets ?? []).filter {
                $0.libraryId == library && $0.manifest == nil
            }.count
        failed =
            records.filter {
                $0.phase == .failed || $0.phase == .sourceChanged || $0.requiresUserAction == true
            }.count
            + (ledger.resourceSets ?? []).filter { group in
                group.libraryId == library && group.manifest == nil && group.requiresUserAction == true
                    && !records.contains { $0.resourceSetId == group.id && $0.requiresUserAction == true }
            }.count
    }
}

struct BackupItem: Identifiable, Sendable {
    let id: UUID
    let source: SourceRevision
    let group: ResourceSetRecord?
    let records: [UploadRecord]

    var name: String { source.resourceNames.first ?? "Photo" }
    var isSaved: Bool {
        !records.isEmpty
            && records.allSatisfy { $0.phase == .ready && $0.evidence?.available == true && $0.remoteRemoved != true }
            && (group == nil || (group?.manifest != nil && group?.verifiedResources(in: records) != nil))
    }
    var sourceChanged: Bool { records.contains { $0.phase == .sourceChanged || $0.remoteRemoved == true } }
    var isStopped: Bool {
        group?.requiresUserAction == true || records.contains { $0.requiresUserAction == true || $0.phase == .failed }
            || sourceChanged
    }
    var diagnostic: String? { group?.error ?? records.first(where: { $0.error != nil })?.error }
    var recovery: String {
        if sourceChanged {
            return "The original changed or is no longer accessible. Select its current version in Photos."
        }
        return BackupPresentation.recovery(
            saved: group?.recoveryMessage ?? records.first(where: { $0.recoveryMessage != nil })?.recoveryMessage,
            diagnostic: diagnostic)
    }
    func progress(chunkSize: Int) -> Double? {
        guard chunkSize > 0, records.count == source.resourceNames.count, !records.isEmpty else { return nil }
        let total = records.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0 else { return nil }
        let received = records.reduce(0.0) { sum, record in
            if record.phase == .ready { return sum + Double(record.size) }
            return sum
                + Set(record.receivedParts).reduce(0.0) { bytes, index in
                    guard index >= 0, index < Chunking.count(size: record.size, chunkSize: chunkSize) else {
                        return bytes
                    }
                    return bytes + Double(min(Int64(chunkSize), record.size - Int64(index) * Int64(chunkSize)))
                }
        }
        return min(1, received / total)
    }
    func status(active: Bool) -> String {
        if isSaved { return "Saved" }
        if sourceChanged { return "Original changed" }
        if isStopped {
            if diagnostic?.hasPrefix("Server returned 400.") == true { return "Server rejected" }
            if diagnostic?.hasPrefix("Server returned 403.") == true { return "Access denied" }
            return "Backup stopped"
        }
        if active {
            if records.isEmpty { return "Preparing original" }
            if records.allSatisfy({ $0.phase == .ready }) { return "Finishing backup" }
            return "Uploading"
        }
        if let code = PhotosNetworkFailure.legacyCode(diagnostic) {
            return code == 3164 ? "Waiting for iCloud" : code == 3169 ? "iCloud retry pending" : "Waiting to retry"
        }
        if diagnostic != nil { return "Waiting to retry" }
        return "Queued"
    }
}

enum BackupPresentation {
    static func status(_ record: UploadRecord, wholeItemPending: Bool = false) -> String {
        if record.remoteRemoved == true { return "Removed from server" }
        if record.phase == .sourceChanged { return "Original changed" }
        if record.requiresUserAction == true { return "Backup stopped" }
        if record.error != nil, record.nextRetryAt != nil { return "Waiting to retry" }
        switch record.phase {
        case .queued: return "Waiting to upload"
        case .uploading: return "Uploading"
        case .verifying: return "Checking upload"
        case .ready:
            return record.evidence?.available == true
                ? (wholeItemPending ? "Finishing backup" : "Saved") : "Checking upload"
        case .paused: return "Waiting to resume"
        case .failed, .sourceChanged: return "Backup stopped"
        }
    }

    static func failure(_ error: Error) -> String {
        if let code = PhotosNetworkFailure.code(error) { return PhotosNetworkFailure.message(code) }
        if case ClientError.signedOut = error { return "Sign in again to continue backup." }
        if case ClientError.http(403, _) = error { return "Upload access was denied. Check your library access." }
        if case ClientError.http(let status, _) = error {
            switch status {
            case 400, 422:
                return "The server rejected this item. Update Nephos and the server, then retry."
            case 404:
                return "This upload is no longer available on the server. Retry to check its current state."
            case 409:
                return "The saved upload state conflicts with the server. Retry to reconcile it."
            case 413:
                return "This file exceeds the server's size limit. Ask your administrator to increase it, then retry."
            default: break
            }
        }
        if let error = error as? URLError,
            [
                .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .secureConnectionFailed,
            ].contains(error.code)
        {
            return
                "The server's secure connection could not be verified. Ask your administrator to check its certificate."
        }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            return "Your iPhone is out of storage. Free some space, then retry. Your photos have not been removed."
        }
        if BackupRetryPolicy.isTransient(error) { return "Upload interrupted. It will retry automatically." }
        return
            "Could not finish this backup. Retry; if it fails again, send the error in Details to your administrator."
    }

    static func recovery(saved: String?, diagnostic: String?) -> String {
        if let code = PhotosNetworkFailure.legacyCode(diagnostic) { return PhotosNetworkFailure.message(code) }
        if let saved { return saved }
        // Older ledgers kept only the formatted diagnostic, not recovery guidance.
        for status in [400, 403, 404, 409, 413, 422] {
            if diagnostic?.hasPrefix("Server returned \(status).") == true {
                return failure(ClientError.http(status, ""))
            }
        }
        return failure(ClientError.invalid(""))
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
