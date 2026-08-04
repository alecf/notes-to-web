import Foundation

// MARK: - Token template URLs

extension CloudflarePublisher {

    /// One entry of a token template's `permissionGroupKeys` array.
    ///
    /// `type` is Cloudflare's own vocabulary — `read`, `edit`, `revoke`, `run`, `purge` —
    /// not a boolean, and `edit` means full access rather than "write but not create".
    public struct TokenPermission: Codable, Sendable, Equatable {
        public let key: String
        public let type: String

        public init(key: String, type: String) {
            self.key = key
            self.type = type
        }
    }

    /// The permissions a publish actually needs.
    ///
    /// `workers_scripts: edit` is the one that does the work; Cloudflare publishes this exact
    /// pairing as its own "Workers scripts only" template.
    ///
    /// `account_settings: read` is added for a different reason: **it is what might let the
    /// app stop asking for an account ID.** Cloudflare does not document which permission
    /// `GET /accounts` requires, but its *Edit Cloudflare Workers* template bundles Account
    /// Settings Read alongside the Workers permission, which suggests enumeration needs it.
    /// This is unverified, and deliberately harmless if wrong: it is read-only, and
    /// `enumerateAccounts` already treats a refusal as "ask the user" rather than an error.
    public static let tokenPermissions: [TokenPermission] = [
        TokenPermission(key: "workers_scripts", type: "edit"),
        TokenPermission(key: "account_settings", type: "read"),
    ]

    /// A dashboard link that opens the token form with the permissions already selected.
    ///
    /// Without this the user has to find "Create Custom Token", then locate *Account* →
    /// *Workers Scripts* → *Edit* in a dropdown of well over a hundred permissions. That
    /// search is the single most intimidating step in connecting an account, and it is
    /// entirely avoidable: the template URL format is documented, and the dashboard fills
    /// the form in from it.
    ///
    /// The user still has to click through and copy the token — a template URL pre-fills
    /// the form and nothing more, so this is not a way to obtain a token without consent.
    public static var tokenTemplateURL: URL {
        tokenTemplateURL(permissions: tokenPermissions, name: "Notes to Web")
    }

    /// Injection point for tests, and for anywhere that needs a differently scoped token.
    static func tokenTemplateURL(permissions: [TokenPermission], name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dash.cloudflare.com"
        components.path = "/profile/api-tokens"

        let encoder = JSONEncoder()
        // Cloudflare reads the array by key, not by position, but a stable spelling keeps the
        // URL comparable between runs and makes the test assert one thing rather than six.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(permissions)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"

        components.queryItems = [
            URLQueryItem(name: "permissionGroupKeys", value: json),
            // Both are required by the dashboard even though this app only ever wants an
            // account: omitting `zoneId` leaves the form in a state it will not submit.
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
            URLQueryItem(name: "name", value: name),
        ]

        // `URLComponents` leaves `{`, `}` and `"` unescaped in a query value — legal in a URL
        // string, but they survive into the address bar and some clients refuse them, so the
        // JSON is escaped explicitly rather than trusted to the default set.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "{", with: "%7B")
            .replacingOccurrences(of: "}", with: "%7D")
            .replacingOccurrences(of: "\"", with: "%22")

        // The components are all literals bar the token name, which is escaped above; a nil
        // here would mean a programming error, not a runtime condition worth surfacing.
        return components.url ?? URL(string: "https://dash.cloudflare.com/profile/api-tokens")!
    }
}
