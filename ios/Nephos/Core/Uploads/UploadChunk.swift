import Foundation

enum UploadChunk {
    static let byteCount = 4 * 1024 * 1024
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024

    static func count(size: Int64) -> Int {
        Int((size + Int64(byteCount) - 1) / Int64(byteCount))
    }

    static func size(part: Int, total: Int64) -> Int64 {
        min(Int64(byteCount), max(0, total - Int64(part) * Int64(byteCount)))
    }
}
