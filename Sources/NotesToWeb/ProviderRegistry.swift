import Foundation
import NotesToWebKit

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
    /// Confirms a token and reports which account it can publish to. Empty means
    /// the token is fine but cannot enumerate accounts, which is a different
    /// problem from a bad token and gets a different message.
    let discoverAccounts: @Sendable (String) async throws -> [DiscoveredAccount]
    /// Sites that already exist on the connected account.
    let listSites: @Sendable (String, String) async throws -> [String]
    /// The host sites are served from, for showing a real URL before publishing.
    let accountHost: @Sendable (String, String) async throws -> String?
    /// nil when the name is usable, otherwise the provider's own rule.
    let validateSiteName: @Sendable (String) -> String?
    /// Builds a publisher for one site. Returns nil when setup is incomplete.
    let makePublisher: @Sendable (_ token: String, _ accountID: String, _ site: String)
        -> (any SitePublisher)?

    struct DiscoveredAccount: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }
}

enum ProviderRegistry {
    static let all: [ProviderDescriptor] = [cloudflare]

    static func provider(id: String?) -> ProviderDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    private static let cloudflare = ProviderDescriptor(
        id: CloudflarePublisher.providerID,
        displayName: CloudflarePublisher.displayName,
        capabilities: CloudflarePublisher.capabilities,
        discoverAccounts: { token in
            try await CloudflarePublisher.discoverAccounts(apiToken: token)
                .map { .init(id: $0.id, name: $0.name) }
        },
        listSites: { token, accountID in
            try await CloudflarePublisher.listSites(apiToken: token, accountID: accountID)
                .filter(\.servesAssets)
                .map(\.name)
        },
        accountHost: { token, accountID in
            try await CloudflarePublisher.accountSubdomain(apiToken: token, accountID: accountID)
        },
        validateSiteName: { CloudflarePublisher.validateSiteName($0) },
        makePublisher: { token, accountID, site in
            guard !token.isEmpty, !accountID.isEmpty, !site.isEmpty else { return nil }
            return CloudflarePublisher(apiToken: token, accountID: accountID, scriptName: site)
        }
    )
}
