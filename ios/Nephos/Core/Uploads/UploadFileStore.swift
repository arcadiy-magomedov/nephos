import CryptoKit
import Foundation
import OSLog

actor UploadFileStore {
    private let root: URL
    private var verified: [UUID: (size: Int64, hash: String)] = [:]
    private let logger = Logger(subsystem: "app.nephos.ios", category: "UploadStaging")

    init(directory: URL) {
        root = directory.appendingPathComponent("staging", isDirectory: true)
    }

    func prepare(_ resource: UploadResource, item: UploadItem, source: any UploadPhotoSource) async throws
        -> (size: Int64, hash: String)
    {
        let file = original(resource.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        if FileManager.default.fileExists(atPath: file.path) {
            if let saved = verified[resource.id],
                saved.size == resource.expectedBytes && saved.hash == resource.sha256
            {
                return saved
            }
            let saved = try await digest(file)
            if saved.size == resource.expectedBytes && saved.hash == resource.sha256 {
                verified[resource.id] = saved
                return saved
            }
            try FileManager.default.removeItem(at: file)
        }
        do {
            try await source.export(item: item, resource: resource, to: file)
            let saved = try await digest(file)
            if let size = resource.expectedBytes, let hash = resource.sha256,
                saved.size != size || saved.hash != hash
            {
                throw ClientError.invalid(
                    "The Photos resource changed after its upload was prepared. Refresh Photos before retrying.")
            }
            verified[resource.id] = saved
            return saved
        } catch {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            throw error
        }
    }

    func chunk(_ transfer: UploadTransfer, total: Int64) throws -> URL {
        let file = chunkPath(transfer)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let input = try FileHandle(forReadingFrom: original(transfer.resourceID))
        defer { close(input) }
        try input.seek(toOffset: UInt64(transfer.part) * UInt64(UploadChunk.byteCount))
        let expected = Int(UploadChunk.size(part: transfer.part, total: total))
        guard let data = try input.read(upToCount: expected), data.count == expected,
            expected == transfer.bytes
        else { throw ClientError.invalid("The staged original changed before its chunk could be uploaded.") }
        try data.write(to: file, options: .atomic)
        return file
    }

    func removeChunk(_ transfer: UploadTransfer) throws {
        let file = chunkPath(transfer)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func removeOriginal(_ resource: UUID) throws {
        let file = original(resource)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        verified.removeValue(forKey: resource)
    }

    private func original(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).original") }
    private func chunkPath(_ transfer: UploadTransfer) -> URL {
        root.appendingPathComponent("\(transfer.id.uuidString).chunk")
    }

    private func digest(_ url: URL) async throws -> (size: Int64, hash: String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { close(input) }
        var hash = SHA256()
        var count: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= UploadChunk.maximumBytes else {
                throw ClientError.invalid("This resource exceeds the server's 8 GiB upload limit.")
            }
            hash.update(data: data)
            await Task.yield()
        }
        guard count > 0 else { throw ClientError.invalid("Photos returned an empty original resource.") }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func close(_ handle: FileHandle) {
        do { try handle.close() } catch {
            logger.error("Unable to close upload staging: \(error.localizedDescription, privacy: .private)")
        }
    }
}
