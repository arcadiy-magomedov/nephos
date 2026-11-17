import Foundation

extension UploadTransfer {
    func fileDescriptor() throws -> FileUploadDescriptor {
        guard isValid else { throw ClientError.invalid("Invalid media transfer mapping.") }
        return FileUploadDescriptor(
            id: id, scope: scope, byteCount: bytes, context: try JSONEncoder().encode(self))
    }

    init(descriptor: FileUploadDescriptor) throws {
        let transfer = try JSONDecoder().decode(Self.self, from: descriptor.context)
        guard transfer.isValid, transfer.id == descriptor.id, transfer.scope == descriptor.scope,
            transfer.bytes == descriptor.byteCount
        else { throw ClientError.invalid("The background file does not match its media transfer.") }
        self = transfer
    }
}
