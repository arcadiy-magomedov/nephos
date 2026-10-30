import Foundation

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTP {
    static let delegate = NoRedirects()
    static let session: URLSession = makeSession()
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    static func request(
        _ url: URL, method: String = "GET", body: Data? = nil,
        token: String? = nil, contentType: String = "application/json"
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
    static func data(_ request: URLRequest, maximum: Int = 2 * 1024 * 1024, session: URLSession = HTTP.session)
        async throws -> Data
    {
        let (stream, response) = try await session.bytes(for: request)
        try check(response)
        guard response.expectedContentLength <= maximum else {
            throw ClientError.invalid("Response exceeds the permitted size.")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < maximum else { throw ClientError.invalid("Response exceeds the permitted size.") }
            data.append(byte)
        }
        return data
    }
    static func json<T: Decodable & Sendable>(_ type: T.Type, _ request: URLRequest, session: URLSession = HTTP.session)
        async throws -> T
    {
        try JSONDecoder().decode(type, from: await data(request, session: session))
    }
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalid("Invalid HTTP response.") }
        if http.statusCode == 401 { throw ClientError.signedOut }
        guard (200..<300).contains(http.statusCode) else {
            let reason: String
            switch http.statusCode {
            case 403: reason = "You no longer have permission. No local files were deleted."
            case 404: reason = "The requested resource is unavailable."
            case 409: reason = "The server reported a conflict. Resume to reconcile upload state."
            case 300..<400: reason = "Redirects are blocked to protect credentials. Configure the canonical URL."
            default: reason = "Try again when the server is available."
            }
            throw ClientError.http(http.statusCode, reason)
        }
    }
}

@MainActor
protocol AccessTokenProviding: AnyObject {
    func accessToken() async throws -> String
}

@MainActor
final class API {
    let connection: Connection
    let auth: any AccessTokenProviding
    let session = HTTP.makeSession()
    private(set) var invalidated = false
    init(connection: Connection, auth: any AccessTokenProviding) {
        self.connection = connection
        self.auth = auth
    }
    func invalidate() {
        invalidated = true
        session.invalidateAndCancel()
    }
    func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw ClientError.invalid("Invalid API URL.") }
        return url
    }
    func request(
        _ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = []
    ) async throws -> URLRequest {
        guard !invalidated else { throw CancellationError() }
        let token = try await auth.accessToken()
        guard !invalidated else { throw CancellationError() }
        return HTTP.request(try endpoint(path, query: query), method: method, body: body, token: token)
    }
    func json<T: Decodable & Sendable>(
        _ type: T.Type, _ path: String, method: String = "GET",
        body: Data? = nil, query: [URLQueryItem] = []
    ) async throws -> T {
        try await HTTP.json(type, request(path, method: method, body: body, query: query), session: session)
    }
    func libraries(cursor: UUID? = nil) async throws -> LibraryPage {
        try await json(
            LibraryPage.self, "v1/libraries",
            query: Paging.libraries(after: cursor))
    }
    func assets(library: UUID, cursor: GalleryCursor?) async throws -> AssetPage {
        try await json(AssetPage.self, "v1/libraries/\(library)/assets", query: Paging.gallery(before: cursor))
    }
}
