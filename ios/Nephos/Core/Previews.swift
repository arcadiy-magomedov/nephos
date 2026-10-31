import Foundation

enum PreviewSize: Int, CaseIterable, Sendable {
    case thumbnail = 512
    case screen = 1280
    case detail = 2560
}

extension API {
    func previewRequest(_ id: UUID, size: PreviewSize) async throws -> URLRequest {
        var result = try await request(
            "v1/assets/\(id)/preview",
            query: [
                URLQueryItem(name: "size", value: String(size.rawValue))
            ])
        result.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        return result
    }
}
