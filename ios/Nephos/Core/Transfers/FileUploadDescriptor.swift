import Foundation

struct FileUploadDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let scope: String
    let byteCount: Int64
    let context: Data

    var isValid: Bool {
        !scope.isEmpty && scope.utf8.count <= 256 && byteCount >= 0 && context.count <= 8192
    }

    func taskDescription() throws -> String {
        guard isValid else { throw FileUploadError.invalid("Invalid background file upload descriptor.") }
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func parse(_ description: String?) throws -> Self {
        guard let description, description.utf8.count <= 16384 else {
            throw FileUploadError.invalid("Missing background file upload identity.")
        }
        let value = try JSONDecoder().decode(Self.self, from: Data(description.utf8))
        guard value.isValid else { throw FileUploadError.invalid("Invalid background file upload identity.") }
        return value
    }
}
