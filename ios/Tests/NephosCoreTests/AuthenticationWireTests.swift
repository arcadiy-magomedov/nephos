import Foundation
import Testing

@testable import NephosCore

struct AuthenticationWireTests {
    @Test("Camel-case discovery properties retain the OIDC wire names")
    func discoveryDecoding() throws {
        let data = Data(
            """
            {
                "issuer": "https://identity.example.test",
                "token_endpoint": "https://identity.example.test/token",
                "jwks_uri": "https://identity.example.test/keys",
                "revocation_endpoint": "https://identity.example.test/revoke"
            }
            """.utf8)

        let discovery = try JSONDecoder().decode(OIDCDiscovery.self, from: data)

        #expect(discovery.tokenEndpoint.absoluteString == "https://identity.example.test/token")
        #expect(discovery.jwksURI.absoluteString == "https://identity.example.test/keys")
        #expect(discovery.revocationEndpoint?.absoluteString == "https://identity.example.test/revoke")
    }

    @Test("Camel-case token properties retain the OAuth wire names")
    func tokenDecoding() throws {
        let data = Data(
            """
            {
                "access_token": "fixture-access",
                "refresh_token": "fixture-refresh",
                "id_token": "fixture-id",
                "expires_in": 300,
                "token_type": "Bearer"
            }
            """.utf8)

        let tokens = try OAuthResponse.tokens(data, status: 200)

        #expect(tokens.accessToken == "fixture-access")
        #expect(tokens.refreshToken == "fixture-refresh")
        #expect(tokens.idToken == "fixture-id")
        #expect(tokens.expiresIn == 300)
        #expect(tokens.tokenType == "Bearer")
    }
}
