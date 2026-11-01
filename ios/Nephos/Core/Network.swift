import Foundation

enum IdentityTokenClaims {
    enum Purpose: Sendable {
        case authorization(nonce: String)
        case refresh(nonce: String, subject: String)
    }

    static func validate(
        _ claims: [String: Any], issuer: String, clientID: String, purpose: Purpose, now: Date = Date()
    ) throws -> String {
        guard claims["iss"] as? String == issuer else {
            throw ClientError.invalid("Identity token issuer validation failed.")
        }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID),
            audience.count == 1 || claims["azp"] as? String == clientID,
            claims["azp"] == nil || claims["azp"] as? String == clientID
        else { throw ClientError.invalid("Identity token audience validation failed.") }
        func numericDate(_ key: String) -> Double? {
            guard let value = claims[key] as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite
            else { return nil }
            return value.doubleValue
        }
        let timestamp = now.timeIntervalSince1970
        guard let expiry = numericDate("exp"), expiry > timestamp,
            let issued = numericDate("iat"), issued <= timestamp + 30, expiry > issued
        else { throw ClientError.invalid("Identity token lifetime validation failed.") }
        if claims["nbf"] != nil {
            guard let notBefore = numericDate("nbf"), notBefore <= timestamp + 30 else {
                throw ClientError.invalid("Identity token is not valid yet.")
            }
        }
        guard let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw ClientError.invalid("Identity token subject is missing.")
        }
        switch purpose {
        case .authorization(let nonce):
            guard claims["nonce"] as? String == nonce else {
                throw ClientError.invalid("Identity token nonce validation failed.")
            }
        case .refresh(let nonce, let expectedSubject):
            // OIDC Core 12.2 permits refresh ID tokens to omit nonce, not to change it.
            if claims["nonce"] != nil, claims["nonce"] as? String != nonce {
                throw ClientError.invalid("Refreshed identity token nonce validation failed.")
            }
            guard subject == expectedSubject else {
                throw ClientError.invalid("Refresh changed the authenticated account.")
            }
        }
        return subject
    }
}

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
    func recoverAccessToken(rejected: String) async throws -> String
}

extension AccessTokenProviding {
    func recoverAccessToken(rejected: String) async throws -> String { throw ClientError.signedOut }
}

@MainActor
final class API {
    let connection: Connection
    let auth: any AccessTokenProviding
    let session: URLSession
    private(set) var invalidated = false
    init(connection: Connection, auth: any AccessTokenProviding, session: URLSession = HTTP.makeSession()) {
        self.connection = connection
        self.auth = auth
        self.session = session
    }
    func invalidate() {
        invalidated = true
        session.invalidateAndCancel()
    }
    func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            parts.queryItems = query
            // Server query parsers interpret a literal plus as a space.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
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
        try JSONDecoder().decode(type, from: await data(request(path, method: method, body: body, query: query)))
    }
    func data(_ request: URLRequest, maximum: Int = 2 * 1024 * 1024) async throws -> Data {
        guard !invalidated else { throw CancellationError() }
        do {
            return try await HTTP.data(request, maximum: maximum, session: session)
        } catch ClientError.signedOut {
            guard !invalidated else { throw CancellationError() }
            guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
                authorization.hasPrefix("Bearer ")
            else { throw ClientError.signedOut }
            let token = try await auth.recoverAccessToken(rejected: String(authorization.dropFirst(7)))
            guard !invalidated else { throw CancellationError() }
            var retried = request
            retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await HTTP.data(retried, maximum: maximum, session: session)
        }
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
