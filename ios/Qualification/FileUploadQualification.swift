import Foundation
import SwiftUI

@MainActor
enum FileUploadQualification {
    static let identifier = "app.nephos.ui-qualification.generic-file"
    private static var uploader: BackgroundFileUploader?
    private static var events: FileUploadEventStore?
    private static var directory: URL?

    static func start(origin: URL) async throws {
        guard Bundle.main.bundleIdentifier == "app.nephos.ui-qualification",
            origin.scheme == "https", origin.host == "127.0.0.1"
        else { throw FileUploadError.invalid("Generic upload qualification requires an isolated loopback fixture.") }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("generic-file-qualification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let events = FileUploadEventStore(directory: directory.appendingPathComponent("receipts"))
        self.events = events
        let uploader = try BackgroundFileUploader(
            identifier: identifier, events: events,
            onEvent: { Task { @MainActor in await completed() } },
            onFinished: {},
            onError: { error in Task { @MainActor in writeResult(["error": error]) } })
        self.uploader = uploader
        uploader.activate()
        let inputs: [(String, String, Int, UInt8)] = [
            ("book.pdf", "application/pdf", 5 * 1024 * 1024, 17),
            ("book.epub", "application/epub+zip", 1024 * 1024, 29),
            ("empty.custom", "application/x-nephos-fixture", 0, 0),
        ]
        for (name, type, count, byte) in inputs {
            let file = directory.appendingPathComponent(name)
            try Data(repeating: byte, count: count).write(to: file)
            var request = URLRequest(url: origin.appendingPathComponent("upload").appendingPathComponent(name))
            request.httpMethod = "PUT"
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.setValue("fixture-only", forHTTPHeaderField: "X-Fixture-Caller")
            let descriptor = FileUploadDescriptor(
                id: UUID(), scope: "generic-fixture", byteCount: Int64(count), context: Data(name.utf8))
            try await uploader.enqueue(descriptor, request: request, file: file)
        }
        try Data("queued".utf8).write(to: directory.appendingPathComponent("queued"), options: .atomic)
    }

    private static func completed() async {
        do {
            guard let events else { throw FileUploadError.invalid("The generic fixture was not initialized.") }
            let receipts = try await events.receipts(scope: "generic-fixture")
            if let failed = receipts.first(where: { $0.status != 204 || $0.error != nil || $0.cancelled }) {
                writeResult(["error": failed.error ?? "HTTP \(failed.status ?? 0)"])
            } else if receipts.count == 3 {
                writeResult(["completed": 3])
            }
        } catch { writeResult(["error": error.localizedDescription]) }
    }

    private static func writeResult(_ value: [String: Any]) {
        guard let directory else { return }
        do {
            try JSONSerialization.data(withJSONObject: value).write(
                to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch { NSLog("Unable to persist generic upload qualification result: %@", error.localizedDescription) }
    }
}
