import Foundation
import Testing

@testable import NephosCore

@Suite
struct FileUploadTests {
    @Test(arguments: [
        ("book.pdf", "application/pdf"), ("book.epub", "application/epub+zip"),
        ("audio.flac", "audio/flac"), ("archive.zip", "application/zip"),
        ("opaque.custom", "application/x-nephos-fixture"),
    ])
    func preservesArbitraryFileBytesAndCallerRequest(fileName: String, mediaType: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-file-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(fileName)
        let bytes = Data([0, 255, 13, 10, 128, 42])
        try bytes.write(to: file)
        let descriptor = FileUploadDescriptor(
            id: UUID(), scope: "personal-library", byteCount: Int64(bytes.count), context: Data([7, 0, 255]))
        var request = URLRequest(url: try URLPolicy.validate("https://library.example.test:8443/custom/import"))
        request.httpMethod = "POST"
        request.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
        request.setValue("fixture-import", forHTTPHeaderField: "X-Import-ID")
        request.allowsCellularAccess = false

        let prepared = try FileUploadRequest.prepare(request, upload: descriptor, file: file)

        #expect(prepared.url == request.url)
        #expect(prepared.httpMethod == "POST")
        #expect(prepared.value(forHTTPHeaderField: "Content-Type") == mediaType)
        #expect(prepared.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        #expect(prepared.value(forHTTPHeaderField: "X-Import-ID") == "fixture-import")
        #expect(prepared.value(forHTTPHeaderField: "Content-Length") == "6")
        #expect(!prepared.allowsCellularAccess)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileUploadDescriptor.parse(descriptor.taskDescription()) == descriptor)
    }

    @Test
    func supportsEmptyFilesAndDefaultsToBinaryWithoutInspectingTheExtension() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-empty-\(UUID()).unrecognized")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let upload = FileUploadDescriptor(id: UUID(), scope: "documents", byteCount: 0, context: Data())
        var request = URLRequest(url: try URLPolicy.validate("https://library.example.test/empty"))
        request.httpMethod = "PUT"

        let prepared = try FileUploadRequest.prepare(request, upload: upload, file: file)

        #expect(prepared.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(prepared.value(forHTTPHeaderField: "Content-Length") == "0")
    }

    @Test
    func genericTransportDoesNotInheritTheMediaEightGiBLimit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-sparse-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let size: Int64 = 8 * 1024 * 1024 * 1024 + 1
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let upload = FileUploadDescriptor(id: UUID(), scope: "archives", byteCount: size, context: Data())
        var request = URLRequest(url: try URLPolicy.validate("https://library.example.test/archives"))
        request.httpMethod = "PATCH"

        let prepared = try FileUploadRequest.prepare(request, upload: upload, file: file)

        #expect(prepared.value(forHTTPHeaderField: "Content-Length") == String(size))
    }

    @Test
    func rejectsChangedSourceLengthAndConflictingRequestBodies() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        let upload = FileUploadDescriptor(id: UUID(), scope: "documents", byteCount: 1, context: Data())
        var request = URLRequest(url: try URLPolicy.validate("https://library.example.test/documents"))
        request.httpMethod = "PUT"
        request.setValue("2", forHTTPHeaderField: "Content-Length")

        #expect(throws: FileUploadError.self) { try FileUploadRequest.prepare(request, upload: upload, file: file) }
        request.setValue(nil, forHTTPHeaderField: "Content-Length")
        request.httpBody = Data([9])
        #expect(throws: FileUploadError.self) { try FileUploadRequest.prepare(request, upload: upload, file: file) }
        request.httpBody = nil
        try Data([1, 2]).write(to: file)
        #expect(throws: FileUploadError.self) { try FileUploadRequest.prepare(request, upload: upload, file: file) }
    }

    @Test
    func arbitraryCallerContextAndResultsSurviveRelaunchWithoutMediaModels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nephos-file-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let upload = FileUploadDescriptor(
            id: UUID(), scope: "books", byteCount: 1024, context: Data("opaque-caller-job".utf8))
        let store = FileUploadEventStore(directory: directory)
        try store.record(
            FileUploadReceipt(
                upload: upload, status: 201, error: nil, cancelled: false, completedAt: Date()))

        let reopened = FileUploadEventStore(directory: directory)
        let receipt = try #require(try await reopened.receipts(scope: "books").first)

        #expect(receipt.upload == upload)
        #expect(receipt.status == 201)
        #expect(try await reopened.receipts(scope: "music").isEmpty)
        try await reopened.acknowledge(id: upload.id)
        #expect(try await reopened.receipts(scope: "books").isEmpty)
    }
}
