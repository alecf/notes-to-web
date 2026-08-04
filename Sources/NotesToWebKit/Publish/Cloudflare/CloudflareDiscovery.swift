import Foundation

// MARK: - Types

/// A Cloudflare account an API token can reach.
public struct CloudflareAccount: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// "Alec's Account (a1b2…)" — what to show once one is picked.
    public var label: String { name.isEmpty ? id : "\(name) (\(id))" }
}

/// A Worker script in an account, as the scripts list describes it.
///
/// `id` is the script name: Workers have no separate identifier, and the name is what
/// becomes `<name>.<subdomain>.workers.dev`.
public struct CloudflareSite: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// True when this Worker serves static assets — i.e. plausibly one of ours.
    ///
    /// False also means "the list did not say": see `CloudflarePublisher.listSites`.
    /// Treat it as "safe to offer as one of this app's sites", never as "definitely not ours".
    public let servesAssets: Bool
    public let modifiedAt: Date?

    public init(id: String, name: String, servesAssets: Bool, modifiedAt: Date?) {
        self.id = id
        self.name = name
        self.servesAssets = servesAssets
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Discovery

extension CloudflarePublisher {

    // MARK: Accounts

    /// The account's `workers.dev` subdomain, so a site's address can be shown
    /// before anything is published. nil when the account has not claimed one.
    public static func accountSubdomain(apiToken: String, accountID: String) async throws -> String? {
        try await accountSubdomain(api: CloudflareAPI(token: apiToken), accountID: accountID)
    }

    public static func accountSubdomain(api: CloudflareAPI, accountID: String) async throws -> String? {
        let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/subdomain"
        return try? await api.get(path, as: AccountSubdomain.self)?.subdomain
    }


    /// Accounts this token can publish to. Empty when the token cannot enumerate
    /// them, which is not an error — the caller falls back to asking for an ID.
    ///
    /// Throws only when the token itself is no good. The two outcomes are deliberately
    /// different: a token that fails `/user/tokens/verify` is broken and the user must
    /// make a new one, while a token that verifies but cannot list accounts is likely
    /// **fine** — see the note on `enumerateAccounts`.
    public static func discoverAccounts(apiToken: String) async throws -> [CloudflareAccount] {
        try await discoverAccounts(api: CloudflareAPI(token: apiToken))
    }

    /// Injection point for tests and for callers that need a custom transport.
    ///
    /// Enumeration comes first, and verification is only a tie-breaker, because
    /// **account-scoped tokens cannot call `/user/tokens/verify` at all** — it
    /// answers 401 for them while every account endpoint works normally.
    /// Verifying first therefore rejected perfectly good tokens. Measured
    /// against a real account-owned token: `/user/tokens/verify` 401,
    /// `/accounts` 200, `/accounts/{id}/workers/scripts` 200.
    public static func discoverAccounts(api: CloudflareAPI) async throws -> [CloudflareAccount] {
        let accounts = try await enumerateAccounts(api: api)
        if !accounts.isEmpty { return accounts }

        // Nothing came back. Now it matters whether the token is broken or
        // merely too narrow to enumerate, and only verify can tell us apart.
        try await verifiedToken(api: api)
        return []
    }

    /// `GET /user/tokens/verify`, with every 4xx turned into one sentence about the token.
    ///
    /// Only meaningful for *user*-scoped tokens. Account-owned tokens answer 401 here
    /// even when they work perfectly, so this must never be the first thing asked —
    /// see `discoverAccounts`.
    @discardableResult
    static func verifiedToken(api: CloudflareAPI) async throws -> TokenVerification {
        let verification: TokenVerification
        do {
            verification = try CloudflareAPI.require(
                await api.get("/user/tokens/verify", as: TokenVerification.self),
                "token status"
            )
        } catch let error as CloudflareAPIError {
            switch error {
            case .unauthorized(let detail), .notFound(let detail),
                 .requestRejected(_, let detail):
                throw PublishError.credentialRejected(
                    """
                    Cloudflare would not accept that API token. Check that the whole token was \
                    pasted and that it has not been revoked, then try again. \
                    (Cloudflare said: \(detail))
                    """
                )
            // Rate limits, outages, and unreadable replies say nothing about the token.
            case .rateLimited, .serverError, .malformedResponse, .network:
                throw error
            }
        }
        guard verification.status == "active" else {
            throw PublishError.credentialRejected(
                "That API token is \(verification.status). Create a new one in the Cloudflare dashboard."
            )
        }
        return verification
    }

    /// Asks the two endpoints that can name an account, and gives up quietly if neither will.
    ///
    /// **What is actually known about the permissions here**, because it decides the whole
    /// design: Cloudflare does not document the permission `GET /accounts` requires, and no
    /// page states it. The available evidence says a token carrying only *Account → Workers
    /// Scripts → Edit* will **not** be able to enumerate:
    ///
    /// - Cloudflare's own *Edit Cloudflare Workers* token template bundles *Account Settings:
    ///   Read*, *User Details: Read* and *User Memberships: Read* alongside the Workers
    ///   permission, which it would not do if Workers alone sufficed for account discovery.
    /// - Wrangler discovers the account through `GET /memberships`, and a workers-sdk
    ///   maintainer states that this needs *All users → Memberships: Read*, "which is not
    ///   added to the normal Workers Edit API token template" (workers-sdk#1873). Narrow
    ///   tokens get HTTP 403 with code 9109 there (workers-sdk#1422).
    /// - This is also why Cloudflare tells API-token users to set `CLOUDFLARE_ACCOUNT_ID`:
    ///   it exists to skip a discovery step that often cannot run.
    ///
    /// None of that was reproducible here without a live narrow token, so **neither outcome
    /// is assumed**. Both endpoints are tried, the first that answers wins, and a refusal
    /// from both is not an error — the caller asks the user for an ID instead. A permission
    /// failure must never be reported as a bad token: the token may be perfectly good, and
    /// `verifiedToken` has already established that it is.
    static func enumerateAccounts(api: CloudflareAPI) async throws -> [CloudflareAccount] {
        // `/accounts` first: one request, and the answer is already in the shape we want.
        if let accounts = try await attempt(
            { try await api.get("/accounts?per_page=50", as: [AccountSummary].self) },
            map: { $0.map { CloudflareAccount(id: $0.id, name: $0.name) } }
        ), !accounts.isEmpty {
            return accounts
        }
        // `/memberships` needs a different permission, so a token that fails one may pass
        // the other. It is what wrangler uses, and it costs one request in the case that
        // would otherwise make the user go and copy a 32-character hex string.
        return try await attempt(
            { try await api.get("/memberships?per_page=50", as: [MembershipSummary].self) },
            map: { $0.compactMap(\.account) }
        ) ?? []
    }

    /// Runs a discovery call, distinguishing "Cloudflare said no" (nil) from "no results".
    private static func attempt<Response: Sendable, Value>(
        _ call: () async throws -> Response?,
        map: (Response) -> [Value]
    ) async throws -> [Value]? {
        do {
            guard let response = try await call() else { return [] }
            return map(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch is CloudflareAPIError {
            // Refused, rate limited, or unreadable: to the caller these all mean the same
            // thing, which is that it has to ask. None of them mean the token is bad.
            return nil
        }
    }

    // MARK: Sites

    /// The Workers in an account, newest first, each flagged with whether it serves assets.
    ///
    /// Believed to need only the Workers Scripts permission the token already carries for
    /// publishing; Cloudflare does not print a permission requirement on this endpoint's
    /// reference page either. If it turns out that *Edit* does not imply *Read*, this call
    /// fails loudly rather than quietly, which is the right way round: unlike account
    /// discovery, there is no manual answer the user could type instead.
    public static func listSites(apiToken: String, accountID: String) async throws -> [CloudflareSite] {
        try await listSites(api: CloudflareAPI(token: apiToken), accountID: accountID)
    }

    /// Injection point for tests and for callers that need a custom transport.
    public static func listSites(api: CloudflareAPI, accountID: String) async throws -> [CloudflareSite] {
        let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/scripts"
        let scripts = try await api.get(path, as: [WorkerScriptSummary].self) ?? []
        return scripts
            .map(\.site)
            .sorted { left, right in
                switch (left.modifiedAt, right.modifiedAt) {
                case let (l?, r?) where l != r: return l > r
                case (nil, .some): return false
                case (.some, nil): return true
                default: return left.name < right.name
                }
            }
    }

    /// Whether a proposed new site name is free, and valid as a Workers script name.
    ///
    /// An invalid name is reported as unavailable rather than thrown: the caller should
    /// already be showing `validateSiteName`'s reason, and a name that cannot exist is
    /// certainly not one you can have.
    public static func isSiteNameAvailable(
        _ name: String, apiToken: String, accountID: String
    ) async throws -> Bool {
        try await isSiteNameAvailable(name, api: CloudflareAPI(token: apiToken), accountID: accountID)
    }

    /// Injection point for tests and for callers that need a custom transport.
    ///
    /// Asks the scripts list rather than probing the script itself: a `GET` on one script
    /// answers with the script's own body, not a JSON envelope, and a 404 there is
    /// ambiguous between "no such script" and "no such account".
    public static func isSiteNameAvailable(
        _ name: String, api: CloudflareAPI, accountID: String
    ) async throws -> Bool {
        guard validateSiteName(name) == nil else { return false }
        let taken = try await listSites(api: api, accountID: accountID)
        return !taken.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Names

    /// Why `name` cannot be a Workers script name, or nil when it can.
    ///
    /// Cloudflare's documented rules for the Wrangler `name` field: "Alphanumeric characters
    /// (a, b, c, etc.) and dashes (-) only. Do not use underscores (_)", up to 255
    /// characters — but "if you plan to use a workers.dev subdomain, the name must be 63
    /// characters or less and cannot start or end with a dash." Every site this app
    /// publishes is on workers.dev, so the stricter set is the only relevant one.
    ///
    /// Uppercase is refused too. The docs only imply it, but the name becomes a hostname
    /// label, and an address that does not match what the user typed is worse than a
    /// rejection that offers the lowercase spelling. Cloudflare's dashboard has been
    /// observed to accept underscores despite the documentation (workers-sdk#5223); it is
    /// still refused here, because such a name cannot be served from workers.dev.
    public static func validateSiteName(_ name: String) -> String? {
        if name.isEmpty {
            return "Enter a name — it becomes the address your notes are published at."
        }
        if name.count > maxSiteNameLength {
            return """
            A site name can be at most \(maxSiteNameLength) characters, and this one is \(name.count).
            """
        }
        if name.contains(where: \.isUppercase) {
            return "Site names are lowercase only. Try “\(name.lowercased())”."
        }
        if let offender = name.first(where: { !Self.siteNameCharacters.contains($0) }) {
            let described = offender == " " ? "a space" : "“\(offender)”"
            return "Site names can only use letters, numbers and dashes, so \(described) will not work."
        }
        if name.hasPrefix("-") || name.hasSuffix("-") {
            return "A site name cannot start or end with a dash."
        }
        return nil
    }

    /// Cloudflare's own workers.dev limit, and also the DNS cap on one hostname label.
    static let maxSiteNameLength = 63

    private static let siteNameCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
}

// MARK: - Wire types

/// One entry of `GET /memberships`. A membership the user has not accepted cannot be
/// published to, so it is dropped rather than offered.
struct MembershipSummary: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let id: String
        let name: String?
    }

    let status: String?
    private let rawAccount: Account?

    private enum CodingKeys: String, CodingKey { case status, account }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        rawAccount = try container.decodeIfPresent(Account.self, forKey: .account)
    }

    var account: CloudflareAccount? {
        guard let rawAccount, status == nil || status == "accepted" else { return nil }
        return CloudflareAccount(id: rawAccount.id, name: rawAccount.name ?? "")
    }
}

/// One entry of `GET /accounts/{id}/workers/scripts`.
struct WorkerScriptSummary: Decodable, Sendable {
    let id: String
    let modifiedOn: String?
    /// `has_assets` is documented on the list response as "Whether a Worker contains
    /// assets", so no second request is needed to tell our sites from the user's own
    /// Workers. It is still optional here: an older or trimmed reply that omits it must
    /// decode rather than fail the whole listing.
    let hasAssets: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case modifiedOn = "modified_on"
        case hasAssets = "has_assets"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        modifiedOn = try container.decodeIfPresent(String.self, forKey: .modifiedOn)
        hasAssets = try container.decodeIfPresent(Bool.self, forKey: .hasAssets)
    }

    init(id: String, modifiedOn: String? = nil, hasAssets: Bool? = nil) {
        self.id = id
        self.modifiedOn = modifiedOn
        self.hasAssets = hasAssets
    }

    var site: CloudflareSite {
        CloudflareSite(
            id: id,
            name: id,
            // Conservative on purpose: an older account-plan response omits the field
            // entirely, and claiming a Worker serves assets when it does not would offer
            // the user's unrelated code Worker as a site to overwrite.
            servesAssets: hasAssets ?? false,
            modifiedAt: modifiedOn.flatMap(CloudflareTimestamp.parse)
        )
    }
}

/// Cloudflare stamps `modified_on` as RFC 3339 with a variable number of fractional
/// digits (six is common), which `ISO8601DateFormatter` only reads with the fractional
/// option switched on — and only reads *without* it when there are none.
enum CloudflareTimestamp {
    /// Built per call rather than cached: `ISO8601DateFormatter` is a reference type and a
    /// shared instance would be a `Sendable` argument this package cannot make honestly.
    /// A site list is tens of rows, not thousands.
    static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
            as [ISO8601DateFormatter.Options] {
            formatter.formatOptions = options
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
