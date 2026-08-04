import AppKit
import Foundation
import NotesToWebKit

/// How the app is authenticated with a provider right now.
///
/// One enum rather than two parallel sets of closures: every call below works the same way
/// whichever half supplied the credential, and the only thing that differs is which
/// `CloudflareAPI` initialiser gets used.
enum PublishCredential: Sendable, Equatable {
    /// A token the user pasted in.
    case token(String)
    /// A browser sign-in, held in `CloudflareOAuthConfiguration.session`.
    case oauth
}

/// One publishable destination, described in terms the UI can render without
/// knowing anything about the provider.
///
/// Adding Vercel, Netlify, or an S3 bucket means writing a `SitePublisher` in
/// the kit and appending one descriptor to `ProviderRegistry.all`. Nothing in
/// the settings screen, the export sheet, or the model needs to change.
struct ProviderDescriptor: Identifiable, Sendable {
    let id: String
    let displayName: String
    let capabilities: ProviderCapabilities
    /// Confirms a credential and reports which account it can publish to. Empty means
    /// the credential is fine but cannot enumerate accounts, which is a different
    /// problem from a bad one and gets a different message.
    let discoverAccounts: @Sendable (PublishCredential) async throws -> [DiscoveredAccount]
    /// Sites that already exist on the connected account.
    let listSites: @Sendable (PublishCredential, String) async throws -> [String]
    /// The host sites are served from, for showing a real URL before publishing.
    let accountHost: @Sendable (PublishCredential, String) async throws -> String?
    /// nil when the name is usable, otherwise the provider's own rule.
    let validateSiteName: @Sendable (String) -> String?
    /// Builds a publisher for one site. Returns nil when setup is incomplete.
    let makePublisher: @Sendable (_ credential: PublishCredential, _ accountID: String, _ site: String)
        -> (any SitePublisher)?
    /// Browser sign-in, when this build has it configured. nil hides the button.
    let oauth: OAuthSupport?

    struct DiscoveredAccount: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    /// The provider-agnostic half of "Sign in with…". The app never learns which OAuth
    /// server is involved or that PKCE exists.
    struct OAuthSupport: Sendable {
        let signIn: @Sendable () async throws -> Void
        let signOut: @Sendable () async -> Void
        let isSignedIn: @Sendable () async -> Bool
    }
}

enum ProviderRegistry {
    static let all: [ProviderDescriptor] = [cloudflare]

    static func provider(id: String?) -> ProviderDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// One transport for either credential. The kit's `api:` injection points already take
    /// a `CloudflareAPI`, so nothing below needs a token-shaped and a session-shaped copy.
    private static func api(_ credential: PublishCredential) -> CloudflareAPI {
        switch credential {
        case .token(let token): CloudflareAPI(token: token)
        case .oauth: CloudflareAPI(session: CloudflareOAuthConfiguration.session)
        }
    }

    private static let cloudflare = ProviderDescriptor(
        id: CloudflarePublisher.providerID,
        displayName: CloudflarePublisher.displayName,
        capabilities: CloudflarePublisher.capabilities,
        discoverAccounts: { credential in
            try await CloudflarePublisher.discoverAccounts(api: api(credential))
                .map { .init(id: $0.id, name: $0.name) }
        },
        listSites: { credential, accountID in
            try await CloudflarePublisher.listSites(api: api(credential), accountID: accountID)
                .filter(\.servesAssets)
                .map(\.name)
        },
        accountHost: { credential, accountID in
            try await CloudflarePublisher.accountSubdomain(api: api(credential), accountID: accountID)
        },
        validateSiteName: { CloudflarePublisher.validateSiteName($0) },
        makePublisher: { credential, accountID, site in
            guard !accountID.isEmpty, !site.isEmpty else { return nil }
            if case .token(let token) = credential, token.isEmpty { return nil }
            return CloudflarePublisher(api: api(credential), accountID: accountID, scriptName: site)
        },
        oauth: CloudflareOAuthConfiguration.isAvailable
            ? ProviderDescriptor.OAuthSupport(
                signIn: {
                    try await CloudflareOAuthConfiguration.session.signIn { url in
                        // The one line of this flow that has to be AppKit: the kit has no
                        // way to open a browser and should not gain one.
                        NSWorkspace.shared.open(url)
                    }
                },
                signOut: { await CloudflareOAuthConfiguration.session.signOut() },
                isSignedIn: { await CloudflareOAuthConfiguration.session.isSignedIn }
            )
            : nil
    )
}
