import Foundation
import NotesToWebKit

/// Where "Sign in with Cloudflare" gets its client ID, and what it asks for.
///
/// ## Why there is a client ID in the source at all
///
/// An OAuth **client ID is not a secret**. It is a public identifier, which is why the spec
/// has a category called "public client" and why Wrangler ships its own in a public
/// repository. `AGENTS.md` forbids embedding secrets, and this does not break that rule:
/// the secret half of the exchange is the PKCE code verifier, which is generated fresh for
/// every sign-in and never leaves the machine. There is deliberately no client *secret*
/// anywhere in this app.
///
/// So the client ID is committed, like a bundle identifier. It needs no CI configuration,
/// local builds behave exactly like release builds, and a fork that never touches it still
/// works. The two overrides below exist for forks that want their own client, not for
/// secrecy.
///
/// ## Resolution order
///
/// 1. `NOTES_TO_WEB_CF_CLIENT_ID` in the environment — for trying a client without rebuilding.
/// 2. `CFOAuthClientID` in `Info.plist` — for a fork that repackages without editing Swift.
/// 3. The constant below.
///
/// When all three are empty, the OAuth button is simply not shown and the API-token flow is
/// the only option. That is the current state until a client is registered.
enum CloudflareOAuthConfiguration {

    /// The registered public client ID. Empty until one exists.
    ///
    /// To create it: Cloudflare dashboard → **Manage Account** → **OAuth clients** →
    /// **Create client**, with
    /// - grant type `authorization_code`, response type `code`
    /// - token endpoint auth method **none** (this is what makes it a public client)
    /// - redirect URL exactly `http://127.0.0.1:9787/oauth/callback`
    ///
    /// Note that setting a client's visibility to **public** is **permanent** and requires
    /// domain verification, a logo, and a client URL — which is what lets people other than
    /// the account owner sign in. A private client works for the owner's own account, so it
    /// is worth testing with one before making that irreversible choice.
    static let bakedInClientID = ""

    /// The scopes to request.
    ///
    /// **These are a best guess and need confirming before the client is registered.**
    /// Cloudflare documents only that "OAuth scope names correspond to Cloudflare API token
    /// permission names" and uses `workers-platform.read` as its lone example. The real list
    /// comes from an authenticated call:
    ///
    /// ```sh
    /// curl https://api.cloudflare.com/client/v4/oauth/scopes \
    ///   -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
    /// ```
    ///
    /// `offline_access` is the standard one and is not a guess: without it Cloudflare issues
    /// no refresh token, and the user is signed out roughly every hour.
    static let scopes = [
        "workers-platform.write",
        "account.read",
        "offline_access",
    ]

    /// Resolved client ID, or an empty string when this build has none.
    static var clientID: String {
        let candidates = [
            ProcessInfo.processInfo.environment["NOTES_TO_WEB_CF_CLIENT_ID"],
            Bundle.main.object(forInfoDictionaryKey: "CFOAuthClientID") as? String,
            bakedInClientID,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Whether to offer the button at all. False hides it rather than showing something
    /// that fails when pressed.
    static var isAvailable: Bool { !clientID.isEmpty }

    static var config: CloudflareOAuthConfig {
        CloudflareOAuthConfig(
            clientID: clientID,
            // Must match a redirect URL registered on the client, character for character.
            redirectURI: URL(string: "http://127.0.0.1:\(OAuthCallbackListener.defaultPort)/oauth/callback")!,
            scopes: scopes
        )
    }

    /// One session for the process: it owns the refresh serialisation, so a second instance
    /// would let two refreshes race and burn each other's refresh token.
    static let session = CloudflareOAuthSession(
        client: CloudflareOAuthClient(config: CloudflareOAuthConfiguration.config)
    )
}
