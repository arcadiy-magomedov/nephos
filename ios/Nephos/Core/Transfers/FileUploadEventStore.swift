import Foundation

actor FileUploadEventStore {
    nonisolated private let directory: URL
    private var progress: [UUID: Int64] = [:]

    init(directory: URL) { self.directory = directory }

    nonisolated func record(_ receipt: FileUploadReceipt) throws {
        guard receipt.upload.isValid else { throw FileUploadError.invalid("Invalid file upload receipt.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: path(receipt.upload.id), options: .atomic)
    }

    func receipts(scope: String) throws -> [FileUploadReceipt] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "json" }.map {
            let receipt = try JSONDecoder().decode(FileUploadReceipt.self, from: Data(contentsOf: $0))
            guard receipt.upload.isValid else { throw FileUploadError.invalid("Invalid stored file upload receipt.") }
            return receipt
        }.filter { $0.upload.scope == scope }.sorted { $0.completedAt < $1.completedAt }
    }

    func acknowledge(id: UUID) throws {
        try FileManager.default.removeItem(at: path(id))
        progress.removeValue(forKey: id)
    }

    func update(_ upload: FileUploadDescriptor, bytes: Int64) {
        progress[upload.id] = min(upload.byteCount, max(0, bytes))
    }

    func sent(id: UUID) -> Int64 { progress[id] ?? 0 }

    nonisolated private func path(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}
