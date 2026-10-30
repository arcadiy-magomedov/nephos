import Foundation

enum MediaRange {
    static let maximumLength = 512 * 1024

    static func validate(_ response: URLResponse, offset: Int64, length: Int, size: Int64) throws {
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalid("Invalid range response.") }
        try HTTP.check(response)
        guard response.statusCode == 206,
            response.value(forHTTPHeaderField: "Content-Range")
                == "bytes \(offset)-\(offset + Int64(length) - 1)/\(size)",
            response.expectedContentLength == Int64(length),
            response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true
        else { throw ClientError.invalid("The server did not honor the bounded original byte range.") }
    }

    @MainActor
    static func fetch(_ asset: Asset, offset: Int64, length: Int, api: API) async throws -> Data {
        guard offset >= 0, length > 0, length <= maximumLength, offset <= asset.size - Int64(length) else {
            throw ClientError.invalid("Invalid original byte range.")
        }
        var request = try await UploadClient(api: api).originalRequest(asset.id)
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await api.session.bytes(for: request)
        try validate(response, offset: offset, length: length, size: asset.size)
        var result = Data()
        result.reserveCapacity(length)
        for try await byte in bytes {
            guard result.count < length else {
                throw ClientError.invalid("Range response exceeded the requested length.")
            }
            result.append(byte)
        }
        try Task.checkCancellation()
        guard result.count == length else { throw ClientError.invalid("Truncated original byte range.") }
        return result
    }
}
