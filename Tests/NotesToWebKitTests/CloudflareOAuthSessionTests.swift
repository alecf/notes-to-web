import Foundation
import Testing
@testable import NotesToWebKit

/// In-memory stand-in for the Keychain, so the token lifecycle is testable without
/// `NOTES_TO_WEB_KEYCHAIN=1` and without touching the developer's real login keychain.
private final class MemoryStorage: OAuthTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    init(_ tokens: OAuthTokens? = nil) { self.tokens = tokens }

    func load() throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    func save(_ tokens: OAuthTokens) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}

private let config = CloudflareOAuthConfig(
    clientID: "test-client",
    redirectURI: URL(string: "http://127.0.0.1:9792/oauth/callback")!,
    scopes: ["workers-platform.write", "offline_access"]
)

private let epoch = Date(timeIntervalSince1970: 1_000_000)

private func client(status: Int = 200, body: String) -> CloudflareOAuthClient {
    CloudflareOAuthClient(
        config: config,
        executor: { request in
            (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!)
        },
        now: { epoch }
    )
}

@Suite("Cloudflare OAuth session")
struct CloudflareOAuthSessionTests {

    @Test("With nothing stored, the session asks for a sign-in rather than failing obscurely")
    func signedOut() async throws {
        let session = CloudflareOAuthSession(
            client: client(body: "{}"), storage: MemoryStorage(), now: { epoch }
        )
        #expect(await session.isSignedIn == false)
        await #expect(throws: OAuthError.needsReauthorization) {
            _ = try await session.accessToken()
        }
    }

    @Test("A token with time left is used as-is, with no needless refresh")
    func usesFreshToken() async throws {
        let storage = MemoryStorage(OAuthTokens(
            accessToken: "still-good", refreshToken: "rt",
            expiresAt: epoch.addingTimeInterval(3600), scope: nil
        ))
        // Any refresh attempt would decode this and fail the test by returning "refreshed".
        let session = CloudflareOAuthSession(
            client: client(body: #"{"access_token":"refreshed","expires_in":3600}"#),
            storage: storage, now: { epoch }
        )

        #expect(await session.isSignedIn)
        #expect(try await session.accessToken() == "still-good")
    }

    @Test("An expired token is refreshed and the new one is written back")
    func refreshesAndPersists() async throws {
        let storage = MemoryStorage(OAuthTokens(
            accessToken: "stale", refreshToken: "rt-1",
            expiresAt: epoch.addingTimeInterval(-10), scope: nil
        ))
        let session = CloudflareOAuthSession(
            client: client(body: #"{"access_token":"fresh","expires_in":3600}"#),
            storage: storage, now: { epoch }
        )

        #expect(try await session.accessToken() == "fresh")

        // Persisted, or the next launch signs the user out for no reason.
        let saved = try #require(try storage.load())
        #expect(saved.accessToken == "fresh")
        #expect(saved.refreshToken == "rt-1")
        #expect(saved.expiresAt == epoch.addingTimeInterval(3600))
    }

    @Test("A revoked grant clears the stored tokens, so the UI stops claiming it is connected")
    func revokedGrantSignsOut() async throws {
        let storage = MemoryStorage(OAuthTokens(
            accessToken: "stale", refreshToken: "rt-dead",
            expiresAt: epoch.addingTimeInterval(-10), scope: nil
        ))
        let session = CloudflareOAuthSession(
            client: client(status: 400, body: #"{"error":"invalid_grant"}"#),
            storage: storage, now: { epoch }
        )

        await #expect(throws: OAuthError.needsReauthorization) {
            _ = try await session.accessToken()
        }
        #expect(try storage.load() == nil)
        #expect(await session.isSignedIn == false)
    }

    @Test("A network failure does not throw away a still-valid refresh token")
    func transientFailureKeepsTokens() async throws {
        let storage = MemoryStorage(OAuthTokens(
            accessToken: "stale", refreshToken: "rt-1",
            expiresAt: epoch.addingTimeInterval(-10), scope: nil
        ))
        let session = CloudflareOAuthSession(
            client: client(status: 503, body: "gateway down"),
            storage: storage, now: { epoch }
        )

        await #expect(throws: OAuthError.self) { _ = try await session.accessToken() }
        // Cloudflare being down at 9am must not require signing in again at 9:01.
        #expect(try storage.load()?.refreshToken == "rt-1")
    }

    @Test("Signing out forgets the tokens locally")
    func signOut() async throws {
        let storage = MemoryStorage(OAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: epoch.addingTimeInterval(3600), scope: nil
        ))
        let session = CloudflareOAuthSession(
            client: client(body: "{}"), storage: storage, now: { epoch }
        )

        await session.signOut()

        #expect(try storage.load() == nil)
        #expect(await session.isSignedIn == false)
    }

    @Test("A whole sign-in runs browser to stored token without a client secret")
    func fullAuthorizationRound() async throws {
        let storage = MemoryStorage()
        let session = CloudflareOAuthSession(
            client: client(body: #"""
            {"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}
            """#),
            storage: storage,
            now: { epoch },
            listenerPort: 9792
        )

        // Stands in for the browser: fetch the redirect the way Cloudflare would.
        let tokens = try await session.signIn(timeout: 10) { authorizationURL in
            let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            Task {
                var request = URLRequest(
                    url: URL(string: "http://127.0.0.1:9792/oauth/callback?code=c1&state=\(state)")!
                )
                request.timeoutInterval = 5
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        #expect(tokens.accessToken == "at-new")
        #expect(try storage.load()?.refreshToken == "rt-new")
        #expect(await session.isSignedIn)
    }
}

@Suite("Cloudflare API token source")
struct CloudflareAPITokenSourceTests {

    @Test("Each request asks the token source again, so a refresh takes effect immediately")
    func rereadsTokenPerRequest() async throws {
        let issued = Counter()
        let seen = Recorder()
        let api = CloudflareAPI(
            tokenSource: { "token-\(await issued.next())" },
            executor: { request in
                await seen.add(request.value(forHTTPHeaderField: "Authorization") ?? "")
                return (
                    Data(#"{"success":true,"result":{"subdomain":"x"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        _ = try await api.get("/a", as: AccountSubdomain.self)
        _ = try await api.get("/b", as: AccountSubdomain.self)

        #expect(await seen.values == ["Bearer token-1", "Bearer token-2"])
    }
}

private actor Counter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private actor Recorder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

@Suite("Publishing with an OAuth session")
struct CloudflareOAuthPublisherTests {

    @Test("A publisher built from a session authenticates with the session's access token")
    func publisherUsesSessionToken() async throws {
        let storage = MemoryStorage(OAuthTokens(
            accessToken: "session-token", refreshToken: "rt",
            expiresAt: epoch.addingTimeInterval(3600), scope: nil
        ))
        let session = CloudflareOAuthSession(
            client: client(body: "{}"), storage: storage, now: { epoch }
        )
        let seen = Recorder()
        let api = CloudflareAPI(
            session: session,
            executor: { request in
                await seen.add(request.value(forHTTPHeaderField: "Authorization") ?? "")
                return (
                    Data(#"{"success":true,"result":{"subdomain":"alec"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        let subdomain = try await CloudflarePublisher.accountSubdomain(api: api, accountID: "acct1")

        #expect(subdomain == "alec")
        #expect(await seen.values == ["Bearer session-token"])
    }
}
