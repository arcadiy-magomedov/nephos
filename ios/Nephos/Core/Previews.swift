import Foundation

enum PreviewSize: Int, CaseIterable, Sendable {
    case thumbnail = 512
    case screen = 1280
    case detail = 2560
}

struct GalleryPreview<Value> {
    var value: Value?
    private var epoch: UUID?
    private var generation: UUID?
    private var source: String?

    mutating func beginRefresh(epoch: UUID, generation: UUID, source: String) {
        if self.epoch != epoch || self.generation != generation || self.source != source {
            value = nil
        }
        self.epoch = epoch
        self.generation = generation
        self.source = source
    }
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
