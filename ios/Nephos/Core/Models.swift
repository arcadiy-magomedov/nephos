import CryptoKit
import Foundation

enum ClientError: LocalizedError {
    case invalid(String)
    case http(Int, String)
    case signedOut
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .http(let code, let message): return "Server returned \(code). \(message)"
        case .signedOut: return "Your session has expired. Sign in again; queued uploads are preserved."
        }
    }
}

struct ServerConfig: Codable, Equatable, Sendable {
    let serverId: String
    let issuer: String
    let clientId: String
    let maxUploadBytes: Int64
    let chunkSize: Int
}

struct Connection: Codable, Equatable, Sendable {
    let baseURL: URL
    let config: ServerConfig
    let allowDevelopmentHTTP: Bool
}

enum URLPolicy {
    static func validate(_ raw: String, allowDevelopmentHTTP: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = parts.host?.lowercased(), !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.scheme == "https" || (allowDevelopmentHTTP && parts.scheme == "http" && isLocal(host))
        else {
            throw ClientError.invalid(
                "Use an HTTPS URL without credentials, query, or fragment. Development HTTP is limited to explicitly approved local hosts."
            )
        }
        parts.host = host
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw ClientError.invalid("Invalid server URL.") }
        return url
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let bytes = components.compactMap { Int($0) }
        guard components.count == 4, bytes.count == 4,
            zip(components, bytes).allSatisfy({ String($0.1) == $0.0 }),
            bytes.allSatisfy({ (0...255).contains($0) })
        else { return false }
        return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? (lhs.scheme == "https" ? 443 : 80)) == (rhs.port ?? (rhs.scheme == "https" ? 443 : 80))
    }
}

struct Library: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}
struct LibraryPage: Codable, Sendable {
    let items: [Library]
    let nextCursor: UUID?
}
struct Asset: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let libraryId: UUID
    let fileName: String
    let mediaType: String
    let size: Int64
    let sha256: String
    let createdAt: String
    let hasPreview: Bool
    var resourceSetId: UUID?
    var isVideo: Bool { mediaType.hasPrefix("video/") }
}
struct GalleryCursor: Codable, Equatable, Sendable {
    let createdAt: String
    let id: UUID
}
enum Paging {
    static func libraries(after: UUID?) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: "50")]
            + (after.map { [URLQueryItem(name: "after", value: $0.uuidString)] } ?? [])
    }
    static func gallery(before: GalleryCursor?) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "limit", value: "50")]
        if let before {
            query += [
                URLQueryItem(name: "before", value: before.createdAt),
                URLQueryItem(name: "beforeId", value: before.id.uuidString),
            ]
        }
        return query
    }
}
struct AssetPage: Codable, Sendable {
    let items: [Asset]
    let nextCursor: GalleryCursor?
}
struct GalleryWindow: Codable, Sendable {
    private(set) var items: [Asset] = []
    private(set) var nextCursor: GalleryCursor?
    private(set) var hasLoaded = false
    static let maximumCount = 300

    mutating func reset() { self = GalleryWindow() }
    mutating func append(_ page: AssetPage, libraryID: UUID) throws {
        guard page.items.allSatisfy({ $0.libraryId == libraryID }) else {
            throw ClientError.invalid("Gallery response crossed the selected library boundary.")
        }
        guard page.nextCursor == nil || page.nextCursor != nextCursor else {
            throw ClientError.invalid("Server returned a repeated gallery cursor.")
        }
        let known = Set(items.map(\.id))
        var newIDs = known
        items += page.items.filter { newIDs.insert($0.id).inserted }
        if items.count > Self.maximumCount { items.removeFirst(items.count - Self.maximumCount) }
        nextCursor = page.nextCursor
        hasLoaded = true
    }
}

struct BackupSettings: Codable, Equatable, Sendable {
    var automaticBackup = false
    var automaticCleanup = false
    var allowCellular = false
    var cleanupWarningsAcknowledged = false
}

enum UploadPhase: String, Codable, Sendable {
    case queued, uploading, verifying, ready, paused, failed, sourceChanged
}
struct SourceRevision: Codable, Equatable, Sendable {
    let localIdentifier: String
    let modificationTime: Double
    let resourceNames: [String]
    let resourceTypes: [Int]
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double
    let cleanupSupported: Bool
    var creationTime: Double?
    var resourceUTIs: [String]?
    func matchesCurrentRevision(_ current: SourceRevision) -> Bool {
        var known = self
        if known.resourceUTIs == nil { known.resourceUTIs = current.resourceUTIs }
        return known == current
    }
}
struct BackupEvidence: Codable, Equatable, Sendable {
    let id: UUID
    let sha256: String
    let size: Int64
    let available: Bool
    let createdAt: String
}
struct RetentionHold: Codable, Equatable, Sendable {
    let id: UUID
    let sha256: String
    let size: Int64
    let available: Bool
    let holdId: UUID
    let retainedUntil: String
    let assurance: String

    func allowsRemoval(id: UUID, sha256: String, size: Int64, now: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiry = formatter.date(from: retainedUntil) ?? ISO8601DateFormatter().date(from: retainedUntil)
        return self.id == id && self.sha256 == sha256 && self.size == size && available
            && assurance == "single-volume-no-independent-backup"
            && expiry.map { $0.timeIntervalSince(now) > 3600 } == true
    }
}
struct UploadRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let libraryId: UUID
    let fileName: String
    let mediaType: String
    let size: Int64
    let sha256: String
    var source: SourceRevision
    let resourceIndex: Int
    var phase: UploadPhase = .queued
    var receivedParts: [Int] = []
    var assetId: UUID?
    var error: String?
    var evidence: BackupEvidence?
    var evidenceCheckedAt: Date?
    var retention: RetentionHold?
    var cleanupState: String?
    var retryCount = 0
    var nextRetryAt: Date?
    var lastAttemptAt: Date?
    var capturedAt: String?
    var resourceSetId: UUID?
    var resourceRole: String?
    var uniformTypeIdentifier: String?
    var remoteRemoved: Bool?
    var committedAssetID: UUID { assetId ?? id }

    var needsTransfer: Bool {
        remoteRemoved != true
            && ([.queued, .uploading, .verifying, .paused, .failed].contains(phase)
                || (phase == .ready && evidence == nil))
    }
    mutating func deferRetry(now: Date = Date()) {
        retryCount += 1
        nextRetryAt = now.addingTimeInterval(min(3600, 30 * pow(2, Double(min(retryCount - 1, 7)))))
    }

    mutating func reconcile(_ status: UploadStatus, chunkSize: Int) throws {
        guard status.id == id, status.chunkSize == chunkSize,
            status.receivedParts.allSatisfy({ (0..<Chunking.count(size: size, chunkSize: chunkSize)).contains($0) })
        else { throw ClientError.invalid("Upload status does not match the durable upload intent.") }
        guard let newPhase = UploadPhase(rawValue: status.state),
            [.uploading, .verifying, .ready, .failed].contains(newPhase),
            newPhase != .ready || status.assetId != nil
        else { throw ClientError.invalid("Invalid upload state or committed asset ID.") }
        phase = newPhase
        receivedParts = Array(Set(status.receivedParts)).sorted()
        assetId = status.assetId
        error = status.error
    }

    func cleanupBlock(current: SourceRevision?, now: Date = Date()) -> String? {
        guard source.cleanupSupported, remoteRemoved != true else {
            return "Compound, edited, unsupported, or remotely removed Photos resource: cleanup is blocked."
        }
        guard current.map(source.matchesCurrentRevision) == true else {
            return "The source changed or is no longer accessible."
        }
        guard phase == .ready, let evidence, evidence.id == committedAssetID, evidence.available,
            evidence.sha256 == sha256, evidence.size == size,
            let checked = evidenceCheckedAt, now.timeIntervalSince(checked) >= 0,
            now.timeIntervalSince(checked) < 60
        else { return "Fresh, matching server backup evidence is required." }
        guard let retention, retention.allowsRemoval(id: committedAssetID, sha256: sha256, size: size, now: now) else {
            return "A matching retention hold with at least one hour remaining is required."
        }
        return nil
    }
}
struct UploadIntent: Encodable, Sendable {
    let id: UUID
    let libraryId: UUID
    let fileName: String
    let mediaType: String
    let size: Int64
    let sha256: String
    let capturedAt: String?
    let resourceSetId: UUID?
    init(_ record: UploadRecord) {
        id = record.id
        libraryId = record.libraryId
        fileName = record.fileName
        mediaType = record.mediaType
        size = record.size
        sha256 = record.sha256
        capturedAt = record.capturedAt
        resourceSetId = record.resourceSetId
    }
}
struct UploadStatus: Codable, Sendable {
    let id: UUID
    let state: String
    let chunkSize: Int
    let receivedParts: [Int]
    let assetId: UUID?
    let error: String?
}

enum Chunking {
    static func count(size: Int64, chunkSize: Int) -> Int {
        guard size > 0, chunkSize > 0 else { return 0 }
        return Int((size - 1) / Int64(chunkSize) + 1)
    }
    static func length(index: Int, size: Int64, chunkSize: Int) throws -> Int {
        guard index >= 0, index < count(size: size, chunkSize: chunkSize) else {
            throw ClientError.invalid("Invalid upload part index.")
        }
        return Int(min(Int64(chunkSize), size - Int64(index) * Int64(chunkSize)))
    }
}
enum Hashing {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func pkceChallenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func file(_ url: URL) throws -> (sha256: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: Int64 = 0
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            hash.update(data: bytes)
            size += Int64(bytes.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
