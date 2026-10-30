import Foundation

struct AccountLedger: Codable, Sendable {
    var version = 1
    var settings = BackupSettings()
    var selectedLibraryID: UUID?
    var records: [UploadRecord] = []
    var scanAfter: String?
    var resourceSets: [ResourceSetRecord]?
}

struct LedgerStore: Sendable {
    let root: URL
    static let stagingBudget: Int64 = 10 * 1024 * 1024 * 1024
    static let viewerBudget: Int64 = 512 * 1024 * 1024
    static let previewBudget = 32 * 1024 * 1024

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func accountDirectory(_ account: String) throws -> URL {
        guard account.count == 64, account.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ClientError.invalid("Invalid account storage boundary.")
        }
        let url = root.appendingPathComponent(account, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func load(account: String) throws -> AccountLedger {
        let url = try accountDirectory(account).appendingPathComponent("ledger.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountLedger() }
        let ledger = try JSONDecoder().decode(AccountLedger.self, from: Data(contentsOf: url))
        guard ledger.version == 1 else {
            throw ClientError.invalid("Unsupported upload ledger version. Existing staging has been preserved.")
        }
        return ledger
    }
    func save(_ ledger: AccountLedger, account: String) throws {
        try JSONEncoder().encode(ledger).write(
            to: accountDirectory(account).appendingPathComponent("ledger.json"), options: .atomic)
    }
    func loadGallery(account: String, library: UUID) throws -> RetainedGallery? {
        let url = try accountDirectory(account).appendingPathComponent("gallery.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cache = try JSONDecoder().decode(RetainedGallery.self, from: Data(contentsOf: url))
        guard cache.library.id == library, cache.window.items.count <= GalleryWindow.maximumCount,
            cache.window.items.allSatisfy({ $0.libraryId == library })
        else { return nil }
        return cache
    }
    func saveGallery(_ cache: RetainedGallery, account: String) throws {
        guard cache.window.items.count <= GalleryWindow.maximumCount else {
            throw ClientError.invalid("Gallery cache limit exceeded.")
        }
        try JSONEncoder().encode(cache).write(
            to: accountDirectory(account).appendingPathComponent("gallery.json"), options: .atomic)
    }
    func clearGallery(account: String) throws {
        let url = try accountDirectory(account).appendingPathComponent("gallery.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func staging(account: String, id: UUID) throws -> URL {
        try accountDirectory(account).appendingPathComponent(id.uuidString.lowercased() + ".original")
    }
    func chunk(account: String, id: UUID, part: Int) throws -> URL {
        try accountDirectory(account).appendingPathComponent("\(id.uuidString.lowercased()).\(part).part")
    }
    func usedBytes() throws -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
    static func accountKey(connection: Connection, subject: String) -> String {
        Hashing.sha256(
            Data(
                [connection.baseURL.absoluteString, connection.config.serverId, connection.config.issuer, subject]
                    .joined(separator: "\n").utf8))
    }
}
