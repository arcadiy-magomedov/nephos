import Foundation
import XCTest

@testable import NephosCore

@MainActor
private final class PreviewTestTokens: AccessTokenProviding {
    func accessToken() async throws -> String { "test-only-placeholder" }
}

final class PreviewTests: XCTestCase {
    @MainActor
    func testEveryViewingSizeUsesAuthenticatedPreviewNeverOriginal() async throws {
        let connection = Connection(
            baseURL: URL(string: "https://photos.example.test/nephos")!,
            config: ServerConfig(
                serverId: "test", issuer: "https://auth.example.test", clientId: "nephos-ios",
                maxUploadBytes: 8_589_934_592, chunkSize: 4_194_304),
            allowDevelopmentHTTP: false)
        let api = API(connection: connection, auth: PreviewTestTokens())
        let id = UUID()
        for size in PreviewSize.allCases {
            let request = try await api.previewRequest(id, size: size)
            XCTAssertEqual(request.url?.path, "/nephos/v1/assets/\(id)/preview")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "size", value: String(size.rawValue))])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        }
        api.invalidate()
        do {
            _ = try await api.previewRequest(id, size: .detail)
            XCTFail("An invalidated account must not load previews.")
        } catch is CancellationError {}
    }
}
