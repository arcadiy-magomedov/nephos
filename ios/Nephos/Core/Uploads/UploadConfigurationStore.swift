import Foundation

actor UploadConfigurationStore {
    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("upload-destination-v1.json")
    }

    func load() throws -> UploadDestination? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(UploadDestination.self, from: Data(contentsOf: url))
    }

    func save(_ destination: UploadDestination) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(destination).write(to: url, options: .atomic)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
