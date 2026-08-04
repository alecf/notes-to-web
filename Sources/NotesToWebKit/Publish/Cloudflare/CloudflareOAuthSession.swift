import Foundation

// MARK: - Storage

/// Where a sign-in is remembered between launches.
///
/// Abstracted so the token lifecycle can be tested without the login keychain — the
/// keychain suites are opt-in for good reason, and refresh logic is too important to be
/// covered only when an environment variable is set.
public protocol OAuthTokenStorage: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func clear() throws
}

/// The real one. Same keychain item shape as the API token, under its own account key so
/// a user can hold both without one clobbering the other.
public struct KeychainOAuthTokenStorage: OAuthTokenStorage {
    /// Distinct from `CloudflarePublisher.providerID`, which stores a pasted API token.
    public static let account = "cloudflare-workers.oauth"

    private let store: CredentialStore
    private let key: String

    public init(store: CredentialStore = CredentialStore(), key: String = KeychainOAuthTokenStorage.account) {
        self.store = store
        self.key = key
    }

    public func load() throws -> OAuthTokens? {
        guard let json = try store.read(provider: key) else { return nil }
        // A payload this app cannot read is treated as no sign-in rather than as a fatal
        // error: the cure is signing in again, which is what `nil` already triggers.
        return try? JSONDecoder().decode(OAuthTokens.self, from: Data(json.utf8))
    }

    public func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        try store.write(String(decoding: data, as: UTF8.self), provider: key)
    }

    public func clear() throws {
        try store.delete(provider: key)
    }
}

// MARK: - Session

/// A signed-in Cloudflare account: holds the tokens, refreshes them when they lapse, and
/// runs the browser handshake that creates them in the first place.
///
/// An actor because `accessToken()` is called from every request a publish makes, and two
/// concurrent refreshes would each burn the refresh token — with Cloudflare free to
/// invalidate the loser.
public actor CloudflareOAuthSession {
    private let client: CloudflareOAuthClient
    private let storage: any OAuthTokenStorage
    private let now: @Sendable () -> Date
    private let listenerPort: UInt16
    /// In-flight refresh, so simultaneous callers await one request instead of racing.
    private var refreshInFlight: Task<OAuthTokens, any Error>?

    public init(
        client: CloudflareOAuthClient,
        storage: any OAuthTokenStorage = KeychainOAuthTokenStorage(),
        now: (@Sendable () -> Date)? = nil,
        listenerPort: UInt16 = OAuthCallbackListener.defaultPort
    ) {
        self.client = client
        self.storage = storage
        self.now = now ?? { Date() }
        self.listenerPort = listenerPort
    }

    public var isSignedIn: Bool {
        ((try? storage.load()) ?? nil) != nil
    }

    /// The token to put on the next request, refreshed first if it is spent.
    public func accessToken() async throws -> String {
        guard let tokens = try storage.load() else {
            throw OAuthError.needsReauthorization
        }
        guard tokens.isExpired(at: now()) else { return tokens.accessToken }
        return try await refreshed(using: tokens).accessToken
    }

    private func refreshed(using tokens: OAuthTokens) async throws -> OAuthTokens {
        if let refreshInFlight { return try await refreshInFlight.value }

        guard let refreshToken = tokens.refreshToken else {
            // No refresh token means `offline_access` was not granted; nothing to do but
            // sign in again.
            try? storage.clear()
            throw OAuthError.needsReauthorization
        }

        let task = Task { [client, storage] in
            do {
                let fresh = try await client.refresh(refreshToken)
                try storage.save(fresh)
                return fresh
            } catch let error as OAuthError {
                // Only a dead grant justifies forgetting the tokens. An outage or a flaky
                // network must leave them alone, or every hiccup becomes a re-sign-in.
                if error == .needsReauthorization { try? storage.clear() }
                throw error
            }
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    // MARK: Sign in and out

    /// Runs the whole handshake: bind the loopback port, open the browser, wait for the
    /// redirect, exchange the code, store the result.
    ///
    /// `open` is injected because this package has no AppKit — the app passes
    /// `NSWorkspace.shared.open`, and the tests pass something that fetches the URL.
    @discardableResult
    public func signIn(
        timeout: TimeInterval = 300,
        open: @Sendable (URL) -> Void
    ) async throws -> OAuthTokens {
        guard !client.config.clientID.isEmpty else { throw OAuthError.notConfigured }

        let listener = OAuthCallbackListener(port: listenerPort)
        // Bind before opening the browser: a port clash found afterwards would strand the
        // user on a Cloudflare consent screen whose answer has nowhere to go.
        _ = try await listener.start()
        defer { Task { await listener.stop() } }

        let pkce = PKCEChallenge()
        let state = CloudflareOAuthClient.newState()
        open(client.authorizationURL(state: state, pkce: pkce))

        let callback = try await listener.waitForCallback(timeout: timeout)
        let code = try CloudflareOAuthClient.callbackCode(from: callback, expectedState: state)
        let tokens = try await client.exchange(code: code, pkce: pkce)
        try storage.save(tokens)
        return tokens
    }

    /// Bridges a signed-in session to the v4 API transport.
    ///
    /// Deliberately a `tokenSource` rather than a token: a publish makes many requests over
    /// several minutes, and this is what lets a refresh land between two of them.
    public nonisolated var tokenSource: CloudflareAPI.TokenSource {
        { try await self.accessToken() }
    }

    /// Forgets the sign-in locally and asks Cloudflare to drop it too.
    ///
    /// Local state is cleared first and unconditionally: a user who clicks Disconnect must
    /// end up disconnected even if the revocation request cannot be made.
    public func signOut() async {
        let tokens = try? storage.load()
        try? storage.clear()
        if let token = tokens?.refreshToken ?? tokens?.accessToken {
            await client.revoke(token)
        }
    }
}
