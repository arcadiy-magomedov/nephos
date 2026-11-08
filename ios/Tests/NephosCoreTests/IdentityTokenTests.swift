import Foundation
import XCTest

@testable import NephosCore

final class IdentityTokenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var claims: [String: Any] {
        [
            "iss": "https://photos.example.test/realms/nephos", "aud": "nephos-ios",
            "sub": "test-subject", "iat": now.timeIntervalSince1970 - 10,
            "exp": now.timeIntervalSince1970 + 300,
        ]
    }
    private func validate(_ claims: [String: Any], refresh: Bool) throws -> String {
        try IdentityTokenClaims.validate(
            claims, issuer: "https://photos.example.test/realms/nephos", clientID: "nephos-ios",
            purpose: refresh
                ? .refresh(nonce: "initial-nonce", subject: "test-subject")
                : .authorization(nonce: "initial-nonce"), now: now)
    }

    func testRefreshMayOmitNonceButInitialAuthorizationMustIncludeIt() throws {
        XCTAssertEqual(try validate(claims, refresh: true), "test-subject")
        XCTAssertThrowsError(try validate(claims, refresh: false))
        var authorized = claims
        authorized["nonce"] = "initial-nonce"
        XCTAssertEqual(try validate(authorized, refresh: false), "test-subject")
        XCTAssertEqual(try validate(authorized, refresh: true), "test-subject")
        for nonce: Any in ["wrong-nonce", NSNull(), 123] {
            authorized["nonce"] = nonce
            XCTAssertThrowsError(try validate(authorized, refresh: false))
            XCTAssertThrowsError(try validate(authorized, refresh: true))
        }
    }

    func testRefreshCannotChangeAccountOrTrustBoundary() {
        for (key, value): (String, Any) in [
            ("sub", "another-subject"), ("sub", ""), ("iss", "https://another.example"),
            ("aud", "another-client"), ("aud", ["nephos-ios", "another-client"]),
            ("azp", "another-client"), ("exp", now.timeIntervalSince1970),
            ("iat", now.timeIntervalSince1970 + 60), ("nbf", now.timeIntervalSince1970 + 60),
            ("iat", true), ("iat", "2000000000"), ("nbf", NSNull()), ("exp", Double.infinity),
        ] {
            var invalid = claims
            invalid[key] = value
            XCTAssertThrowsError(try validate(invalid, refresh: true), key)
        }
        for key in ["iss", "aud", "iat", "exp", "sub"] {
            var invalid = claims
            invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try validate(invalid, refresh: true), key)
        }
    }

    func testMultipleAudiencesRequireMatchingAuthorizedParty() throws {
        var multiple = claims
        multiple["aud"] = ["nephos-ios", "other"]
        multiple["azp"] = "nephos-ios"
        XCTAssertEqual(try validate(multiple, refresh: true), "test-subject")
    }
}
