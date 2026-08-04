import CryptoKit
import Foundation

// MARK: - PKCE

/// A one-shot PKCE pair: a random secret kept in memory, and the hash of it that travels
/// through the browser.
///
/// This is what lets an open-source, downloadable app authenticate at all. A client secret
/// compiled into a published binary is a published secret; PKCE replaces it with a value
/// generated fresh for every login, so intercepting the redirect gets an attacker a code
/// they cannot redeem.
public struct PKCEChallenge: Sendable, Equatable {
    /// The secret half. Never logged, never put in a URL, never stored.
    public let verifier: String
    /// The public half: base64url(SHA-256(verifier)), unpadded, per RFC 7636.
    public let challenge: String

    public var method: String { "S256" }

    public init() {
        // 32 bytes → 43 base64url characters, the shortest length RFC 7636 permits and
        // already 256 bits of entropy.
        var bytes = [UInt8](repeating: 0, count: 32)
        // `SystemRandomNumberGenerator` is the CSPRNG; `Int.random` without one is not
        // guaranteed to be, and this value is the whole security of the exchange.
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        self.init(verifier: Self.base64URL(Data(bytes)))
    }

    /// Deterministic form, used by the RFC's own worked example in the tests.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url without padding: `+/=` are all significant in a query string.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Configuration

/// Where to talk to, and as whom.
///
/// `clientID` is **not a secret** — Wrangler ships its own in a public repository, and the
/// OAuth spec calls this a "public client" precisely because the identifier is expected to
/// be readable. There is deliberately no `clientSecret` field: adding one would put a
/// published secret in a downloadable binary, which `AGENTS.md` forbids outright.
public struct CloudflareOAuthConfig: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL

    /// Published by Cloudflare at `dash.cloudflare.com/.well-known/openid-configuration`,
    /// which also advertises `code_challenge_methods_supported: ["plain", "S256"]` and
    /// `token_endpoint_auth_methods_supported` including `"none"` — the two facts this
    /// whole flow depends on.
    public static let defaultAuthorizationEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
    public static let defaultTokenEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/token")!
    public static let defaultRevocationEndpoint = URL(string: "https://dash.cloudflare.com/oauth2/revoke")!

    public init(
        clientID: String,
        redirectURI: URL,
        scopes: [String],
        authorizationEndpoint: URL = CloudflareOAuthConfig.defaultAuthorizationEndpoint,
        tokenEndpoint: URL = CloudflareOAuthConfig.defaultTokenEndpoint,
        revocationEndpoint: URL = CloudflareOAuthConfig.defaultRevocationEndpoint
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
    }
}

// MARK: - Tokens

/// What a successful exchange hands back. Stored in the Keychain, never in `UserDefaults`.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// Publishing a note can take minutes, so a token is treated as spent well before it
    /// actually lapses. Expiring mid-upload would fail the deployment, not just a request.
    public static let expiryMargin: TimeInterval = 120

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= Self.expiryMargin
    }
}

// MARK: - Errors

public enum OAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case stateMismatch
    case authorizationDenied(String)
    case missingCode
    /// The refresh token is gone or revoked: only a fresh sign-in fixes this.
    case needsReauthorization
    case server(error: String, description: String)
    case malformedResponse(String)
    case network(String)
    case callbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            """
            This build has no Cloudflare OAuth client configured, so signing in is not \
            available. Create an API token instead.
            """
        case .stateMismatch:
            """
            The sign-in reply did not match the request this app started, so it was ignored. \
            Try signing in again, and avoid opening two sign-in windows at once.
            """
        case .authorizationDenied(let reason):
            reason.isEmpty
                ? "Sign-in was cancelled, so nothing was connected."
                : "Cloudflare did not complete the sign-in: \(reason)"
        case .missingCode:
            "Cloudflare's reply carried no authorization code. Try signing in again."
        case .needsReauthorization:
            """
            This Cloudflare sign-in has expired or been revoked. Sign in again to reconnect; \
            nothing else needs changing.
            """
        case .server(let error, let description):
            description.isEmpty
                ? "Cloudflare refused the sign-in (\(error))."
                : "Cloudflare refused the sign-in: \(description) (\(error))"
        case .malformedResponse(let detail):
            "Cloudflare sent a sign-in reply this app could not read: \(detail)"
        case .network(let detail):
            "Could not reach Cloudflare to sign in: \(detail)"
        case .callbackFailed(let detail):
            """
            The sign-in window could not hand its answer back to this app: \(detail). \
            Check that no other app is using the same port, then try again.
            """
        }
    }
}

// MARK: - Client

/// The OAuth 2.0 authorization-code-with-PKCE flow against Cloudflare's dashboard.
///
/// Deliberately has no opinion about *how* the browser is opened or how the redirect is
/// caught — that is `OAuthCallbackListener`'s job and the app's. This type is pure protocol
/// mechanics so it can be tested without a network, a browser, or a real client ID.
public struct CloudflareOAuthClient: Sendable {
    public typealias Executor = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public let config: CloudflareOAuthConfig
    private let execute: Executor
    private let now: @Sendable () -> Date

    public init(
        config: CloudflareOAuthConfig,
        executor: Executor? = nil,
        now: (@Sendable () -> Date)? = nil
    ) {
        self.config = config
        self.execute = executor ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.malformedResponse("the reply was not an HTTP response")
            }
            return (data, http)
        }
        self.now = now ?? { Date() }
    }

    // MARK: Authorization

    /// A fresh, unguessable `state` value. Compared on the way back to reject a callback
    /// this app did not initiate.
    public static func newState() -> String {
        PKCEChallenge().verifier
    }

    public func authorizationURL(state: String, pkce: PKCEChallenge) -> URL {
        var components = URLComponents(
            url: config.authorizationEndpoint, resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        return components?.url ?? config.authorizationEndpoint
    }

    /// Pulls the code out of the browser's redirect, refusing anything that does not match.
    public static func callbackCode(from url: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        // Denial is checked before state: a user who clicked Cancel should be told that,
        // not handed a CSRF warning that reads like something went wrong.
        if let error = items["error"], !error.isEmpty {
            throw OAuthError.authorizationDenied(items["error_description"] ?? error)
        }
        guard items["state"] == expectedState else {
            throw OAuthError.stateMismatch
        }
        guard let code = items["code"], !code.isEmpty else {
            throw OAuthError.missingCode
        }
        return code
    }

    // MARK: Token endpoint

    public func exchange(code: String, pkce: PKCEChallenge) async throws -> OAuthTokens {
        try await token(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI.absoluteString,
            "client_id": config.clientID,
            "code_verifier": pkce.verifier,
        ])
    }

    /// Cloudflare does not always reissue a refresh token, so the one we already hold is
    /// carried forward. Dropping it would sign the user out on the *next* refresh, an hour
    /// later, which is a miserable bug to track down.
    public func refresh(_ refreshToken: String) async throws -> OAuthTokens {
        let fresh = try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ])
        guard fresh.refreshToken == nil else { return fresh }
        return OAuthTokens(
            accessToken: fresh.accessToken,
            refreshToken: refreshToken,
            expiresAt: fresh.expiresAt,
            scope: fresh.scope
        )
    }

    /// Best effort: a revoke that fails still leaves the app disconnected locally, and
    /// telling the user their sign-out "failed" would be worse than useless.
    public func revoke(_ token: String) async {
        var request = URLRequest(url: config.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(["token": token, "client_id": config.clientID])
        _ = try? await execute(request)
    }

    private func token(form: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No Authorization header and no client_secret: this is a public client, and
        // Cloudflare advertises `none` among its token endpoint auth methods.
        request.httpBody = Self.formBody(form)

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await execute(request)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.network(error.localizedDescription)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.failure(in: data, status: http.statusCode)
        }

        let payload: TokenResponse
        do {
            payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.malformedResponse(error.localizedDescription)
        }
        return OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresIn.map { now().addingTimeInterval($0) },
            scope: payload.scope
        )
    }

    /// `invalid_grant` on a refresh means the grant is gone for good — retrying cannot help,
    /// and the only cure is a new sign-in. Every other error is reported as itself.
    static func failure(in data: Data, status: Int) -> OAuthError {
        guard let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .server(error: "HTTP \(status)", description: text)
        }
        if payload.error == "invalid_grant" || payload.error == "invalid_token" {
            return .needsReauthorization
        }
        return .server(error: payload.error, description: payload.errorDescription ?? "")
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` is a legal query character but means "space" in a form body, so it has to be
        // escaped explicitly — token and code values routinely contain one.
        let encoded = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }
}

// MARK: - Wire types

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct ErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
