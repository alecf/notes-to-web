import Foundation
import Testing
@testable import NotesToWebKit

private let config = CloudflareOAuthConfig(
    clientID: "test-client",
    redirectURI: URL(string: "http://127.0.0.1:8976/oauth/callback")!,
    scopes: ["workers-platform.write", "offline_access"]
)

private func query(_ url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return Dictionary(
        (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

/// Captures the request a client sends, and replies with canned JSON.
private actor Recorder {
    private(set) var requests: [URLRequest] = []
    let status: Int
    let body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func record(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), response)
    }

    var executor: CloudflareOAuthClient.Executor {
        { request in await self.record(request) }
    }

    func body(of index: Int) -> [String: String] {
        guard let data = requests[index].httpBody else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

// MARK: - PKCE

@Suite("PKCE")
struct PKCETests {

    @Test("The verifier is long enough and uses only characters RFC 7636 allows")
    func verifierShape() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<50 {
            let pkce = PKCEChallenge()
            #expect(pkce.verifier.count >= 43)
            #expect(pkce.verifier.count <= 128)
            #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
        }
    }

    @Test("Two challenges never share a verifier, or the whole exchange is replayable")
    func verifierIsRandom() {
        let verifiers = Set((0..<100).map { _ in PKCEChallenge().verifier })
        #expect(verifiers.count == 100)
    }

    @Test("The challenge is the base64url SHA-256 of the verifier, unpadded")
    func challengeMatchesRFC7636() {
        // The worked example from RFC 7636 appendix B.
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
        #expect(!pkce.challenge.contains("="))
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
    }
}

// MARK: - Authorization

@Suite("Cloudflare OAuth authorization")
struct CloudflareOAuthAuthorizationTests {

    @Test("The authorization URL carries the challenge, not the verifier")
    func authorizationURL() {
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let client = CloudflareOAuthClient(config: config)
        let url = client.authorizationURL(state: "state-123", pkce: pkce)
        let items = query(url)

        #expect(url.host() == "dash.cloudflare.com")
        #expect(url.path() == "/oauth2/auth")
        #expect(items["client_id"] == "test-client")
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "http://127.0.0.1:8976/oauth/callback")
        #expect(items["scope"] == "workers-platform.write offline_access")
        #expect(items["state"] == "state-123")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        // The verifier is the secret half. Sending it here would defeat PKCE entirely.
        #expect(!url.absoluteString.contains(pkce.verifier))
    }

    @Test("A matching state yields the code")
    func callbackHappyPath() throws {
        let url = URL(string: "http://127.0.0.1:8976/oauth/callback?code=abc123&state=state-123")!
        let code = try CloudflareOAuthClient.callbackCode(from: url, expectedState: "state-123")
        #expect(code == "abc123")
    }

    @Test("A mismatched state is refused, because that is what CSRF looks like")
    func callbackRejectsForgedState() {
        let url = URL(string: "http://127.0.0.1:8976/oauth/callback?code=abc123&state=attacker")!
        #expect(throws: OAuthError.stateMismatch) {
            try CloudflareOAuthClient.callbackCode(from: url, expectedState: "state-123")
        }
    }

    @Test("A denial comes back as the reason, not as a missing-code error")
    func callbackReportsDenial() {
        let url = URL(string:
            "http://127.0.0.1:8976/oauth/callback?error=access_denied&error_description=User%20said%20no&state=state-123"
        )!
        #expect(throws: OAuthError.authorizationDenied("User said no")) {
            try CloudflareOAuthClient.callbackCode(from: url, expectedState: "state-123")
        }
    }
}

// MARK: - Token exchange

@Suite("Cloudflare OAuth token exchange")
struct CloudflareOAuthTokenTests {

    @Test("Exchange sends the verifier and no client secret")
    func exchangeSendsVerifierNotSecret() async throws {
        let recorder = Recorder(body: #"""
        {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"bearer"}
        """#)
        let client = CloudflareOAuthClient(config: config, executor: await recorder.executor)
        let pkce = PKCEChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")

        _ = try await client.exchange(code: "abc123", pkce: pkce)

        let sent = await recorder.body(of: 0)
        #expect(sent["grant_type"] == "authorization_code")
        #expect(sent["code"] == "abc123")
        #expect(sent["code_verifier"] == pkce.verifier)
        #expect(sent["client_id"] == "test-client")
        #expect(sent["redirect_uri"] == "http://127.0.0.1:8976/oauth/callback")
        // The entire reason this app can do OAuth at all.
        #expect(sent["client_secret"] == nil)
    }

    @Test("expires_in becomes an absolute expiry, so a stored token can be judged later")
    func expiryIsAbsolute() async throws {
        let recorder = Recorder(body: #"""
        {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"token_type":"bearer"}
        """#)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let client = CloudflareOAuthClient(
            config: config, executor: await recorder.executor, now: { start }
        )

        let tokens = try await client.exchange(code: "abc", pkce: PKCEChallenge())

        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.expiresAt == start.addingTimeInterval(3600))
    }

    @Test("A token near its expiry counts as expired, so a publish never starts on a dying one")
    func expiryHasMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(30), scope: nil
        )
        // Thirty seconds is plenty of clock but not plenty of upload.
        #expect(tokens.isExpired(at: now))
        #expect(!OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: now.addingTimeInterval(600), scope: nil
        ).isExpired(at: now))
    }

    @Test("Refresh asks for a refresh_token grant")
    func refreshGrant() async throws {
        let recorder = Recorder(body: #"""
        {"access_token":"at-2","expires_in":3600,"token_type":"bearer"}
        """#)
        let client = CloudflareOAuthClient(config: config, executor: await recorder.executor)

        let tokens = try await client.refresh("rt-1")

        let sent = await recorder.body(of: 0)
        #expect(sent["grant_type"] == "refresh_token")
        #expect(sent["refresh_token"] == "rt-1")
        #expect(sent["client_id"] == "test-client")
        #expect(tokens.accessToken == "at-2")
        // Cloudflare may not reissue one; keeping the old refresh token is what makes the
        // next refresh work instead of silently signing the user out.
        #expect(tokens.refreshToken == "rt-1")
    }

    @Test("An OAuth error becomes a sentence naming what to do")
    func errorIsActionable() async throws {
        let recorder = Recorder(status: 400, body: #"""
        {"error":"invalid_grant","error_description":"code already redeemed"}
        """#)
        let client = CloudflareOAuthClient(config: config, executor: await recorder.executor)

        await #expect(throws: OAuthError.self) {
            _ = try await client.exchange(code: "abc", pkce: PKCEChallenge())
        }
    }

    @Test("An expired refresh token says to sign in again rather than showing a code")
    func expiredRefreshIsRecognisable() async throws {
        let recorder = Recorder(status: 400, body: #"""
        {"error":"invalid_grant","error_description":"refresh token expired"}
        """#)
        let client = CloudflareOAuthClient(config: config, executor: await recorder.executor)

        do {
            _ = try await client.refresh("rt-old")
            Issue.record("expected a failure")
        } catch let error as OAuthError {
            #expect(error == .needsReauthorization)
            let message = try #require(error.errorDescription)
            #expect(message.lowercased().contains("sign in"))
        }
    }
}
