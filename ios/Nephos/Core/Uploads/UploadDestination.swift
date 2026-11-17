import Foundation

struct UploadDestination: Codable, Equatable, Sendable {
    let connection: Connection
    let subject: String
    let installationID: UUID
    let libraryID: UUID
    let libraryName: String

    var accountKey: String { AccountIdentity.key(connection: connection, subject: subject) }
    var scope: String {
        Hashing.sha256(
            Data([accountKey, installationID.uuidString, libraryID.uuidString].joined(separator: "\n").utf8))
    }
}
