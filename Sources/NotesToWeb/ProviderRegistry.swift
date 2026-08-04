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
    /// Extra non-secret fields this provider needs, rendered as text fields.
    let settings: [SettingField]
    /// Builds a publisher from stored preferences plus the secret from the
    /// Keychain. Returns nil when something required is still blank.
    let makePublisher: @Sendable @MainActor (Preferences, String) -> (any SitePublisher)?

    struct SettingField: Identifiable, Sendable {
        let id: String
        let label: String
        let prompt: String
        let help: String
        let value: @Sendable @MainActor (Preferences) -> String
        let setValue: @Sendable @MainActor (Preferences, String) -> Void
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
        settings: [
            .init(
                id: "accountID",
                label: "Account ID",
                prompt: "32-character hex string",
                help: "Cloudflare dashboard → Workers & Pages → Overview, in the right-hand sidebar.",
                value: { $0.cloudflareAccountID },
                setValue: { $0.cloudflareAccountID = $1 }
            ),
            .init(
                id: "projectName",
                label: "Site name",
                prompt: "alecs-notes",
                help: "Becomes the subdomain your notes are served from.",
                value: { $0.cloudflareProjectName },
                setValue: { $0.cloudflareProjectName = $1 }
            ),
        ],
        makePublisher: { preferences, token in
            let account = preferences.cloudflareAccountID.trimmingCharacters(in: .whitespaces)
            let project = preferences.cloudflareProjectName.trimmingCharacters(in: .whitespaces)
            guard !account.isEmpty, !project.isEmpty, !token.isEmpty else { return nil }
            return CloudflarePublisher(apiToken: token, accountID: account, scriptName: project)
        }
    )
}
