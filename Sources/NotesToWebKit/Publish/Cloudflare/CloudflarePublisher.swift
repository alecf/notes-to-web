import Foundation

/// Publishes an exported note to Cloudflare Workers Static Assets.
///
/// Workers rather than Pages: the assets-only upload flow (upload session → bucketed
/// upload → script deployment) is documented as a REST contract, while Pages Direct Upload
/// only documents Wrangler and the dashboard. See `docs` links in the design notes.
///
/// A deployment replaces the script's entire asset set, so `siteRoot` must contain
/// everything the site should serve. Content-hash deduplication makes republishing an
/// unchanged 20 MB video free — the upload session simply never asks for it.
public struct CloudflarePublisher: SitePublisher {
    public static let providerID = "cloudflare-workers"
    public static let displayName = "Cloudflare Workers"

    public static let capabilities = ProviderCapabilities(
        maxFileSize: 25 * 1024 * 1024,
        // The free-plan ceiling. Paid accounts get 100,000; refusing at the lower number
        // is the safe direction to be wrong in.
        maxFileCount: 20_000,
        supportsSubpaths: true,
        credentialLabel: "API token",
        credentialHelp: """
        The token is kept in your login keychain and sent only to api.cloudflare.com. \
        Nothing is embedded in this app, and you can revoke it from the same page at any time.
        """,
        credentialSteps: [
            "Open the Cloudflare dashboard and sign in. A free account is enough.",
            "Click **Create a token** below, then choose **Create Custom Token**.",
            "Give it any name, and add one permission: **Account** → **Workers Scripts** → **Edit**.",
            "Under **Account Resources**, pick the account you want to publish to.",
            "Continue to summary, create the token, and copy it. Cloudflare shows it once and never again.",
        ],
        credentialURL: URL(string: "https://dash.cloudflare.com/profile/api-tokens")
    )

    /// Cloudflare's asset upload endpoint takes base64, which inflates a payload by a third;
    /// batching on raw bytes keeps a request near 27 MB and keeps peak memory predictable.
    static let maxBatchBytes = 20 * 1024 * 1024

    public let accountID: String
    public let scriptName: String
    /// Site-absolute prefix, so several notes can share one workers.dev host.
    public let pathPrefix: String
    public let compatibilityDate: String

    private let api: CloudflareAPI

    public init(
        apiToken: String,
        accountID: String,
        scriptName: String,
        pathPrefix: String = "/",
        compatibilityDate: String = "2025-01-01"
    ) {
        self.init(
            api: CloudflareAPI(token: apiToken),
            accountID: accountID,
            scriptName: scriptName,
            pathPrefix: pathPrefix,
            compatibilityDate: compatibilityDate
        )
    }

    /// The form to use after `discoverAccounts` has answered, so the caller never has to
    /// unwrap an account back into a string.
    public init(
        apiToken: String,
        account: CloudflareAccount,
        scriptName: String,
        pathPrefix: String = "/",
        compatibilityDate: String = "2025-01-01"
    ) {
        self.init(
            api: CloudflareAPI(token: apiToken),
            accountID: account.id,
            scriptName: scriptName,
            pathPrefix: pathPrefix,
            compatibilityDate: compatibilityDate
        )
    }

    /// Injection point for tests and for callers that need a custom transport.
    public init(
        api: CloudflareAPI,
        accountID: String,
        scriptName: String,
        pathPrefix: String = "/",
        compatibilityDate: String = "2025-01-01"
    ) {
        self.api = api
        self.accountID = accountID
        self.scriptName = scriptName
        self.pathPrefix = SiteManifest.normalizedPrefix(pathPrefix)
        self.compatibilityDate = compatibilityDate
    }

    // MARK: Credentials

    public func validateCredentials() async throws -> String {
        guard !accountID.isEmpty else {
            throw PublishError.accountNotFound("(none given)")
        }

        // Enumeration first: an account-scoped token 401s on /user/tokens/verify
        // even though it works, so verifying up front rejects good tokens.
        let accounts = try await Self.enumerateAccounts(api: api)
        if let match = accounts.first(where: { $0.id == accountID }) {
            return match.label
        }
        if !accounts.isEmpty {
            throw PublishError.accountNotFound(accountID)
        }

        // Could not enumerate. Only now is it worth asking whether the token is
        // broken; if it is not, publishing to the given ID may still work fine.
        try await Self.verifiedToken(api: api)
        return "Cloudflare account \(accountID)"
    }

    // MARK: Publish

    public func publish(
        siteRoot: URL,
        progress: @Sendable @escaping (PublishProgress) -> Void
    ) async throws -> PublishResult {
        try validateScriptName()

        progress(PublishProgress(
            completedBytes: 0, totalBytes: 0, completedFiles: 0, totalFiles: 0,
            message: "Reading \(siteRoot.lastPathComponent)"
        ))

        let manifest = try SiteManifest.build(root: siteRoot, pathPrefix: pathPrefix)
        guard !manifest.files.isEmpty else { throw PublishError.emptySite(siteRoot) }
        try preflight(manifest)
        try Task.checkCancellation()

        var warnings: [String] = []
        let session = try await openUploadSession(manifest: manifest)

        let byHash = manifest.filesByHash
        var pending: [SiteFile] = []
        for hash in session.buckets.flatMap({ $0 }) {
            guard let file = byHash[hash] else {
                warnings.append("Cloudflare asked for a file this export does not contain (\(hash)); it was skipped.")
                continue
            }
            pending.append(file)
        }

        let totalBytes = pending.reduce(0) { $0 + $1.size }
        let totalFiles = pending.count
        var uploadedBytes: Int64 = 0
        var uploadedFiles = 0
        var completionToken: String?

        progress(PublishProgress(
            completedBytes: 0, totalBytes: totalBytes, completedFiles: 0, totalFiles: totalFiles,
            message: totalFiles == 0 ? "Everything is already uploaded" : "Uploading \(totalFiles) files"
        ))

        for batch in Self.batches(of: pending, maxBytes: Self.maxBatchBytes) {
            try Task.checkCancellation()
            progress(PublishProgress(
                completedBytes: uploadedBytes,
                totalBytes: totalBytes,
                completedFiles: uploadedFiles,
                totalFiles: totalFiles,
                message: "Uploading \(batch.first?.path.lastPathSegment ?? "files")"
            ))

            if let jwt = try await upload(batch, sessionJWT: session.jwt) {
                completionToken = jwt
            }
            uploadedBytes += batch.reduce(0) { $0 + $1.size }
            uploadedFiles += batch.count
        }

        progress(PublishProgress(
            completedBytes: uploadedBytes,
            totalBytes: totalBytes,
            completedFiles: uploadedFiles,
            totalFiles: totalFiles,
            message: "Publishing"
        ))

        // With nothing to upload there is no completion token; the session JWT stands in and
        // the previously stored assets are re-attached by hash.
        let deploymentToken = completionToken ?? session.jwt
        try await deploy(assetsJWT: deploymentToken)

        do {
            try await enableWorkersDevSubdomain()
        } catch {
            warnings.append(
                "The site deployed but the workers.dev address could not be switched on automatically: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            )
        }

        let url = try await publicURL()

        progress(PublishProgress(
            completedBytes: max(uploadedBytes, totalBytes),
            totalBytes: totalBytes,
            completedFiles: uploadedFiles,
            totalFiles: totalFiles,
            message: "Published"
        ))

        return PublishResult(
            url: url,
            uploadedFileCount: uploadedFiles,
            skippedFileCount: max(0, manifest.files.count - uploadedFiles),
            uploadedByteCount: uploadedBytes,
            warnings: warnings
        )
    }

    // MARK: Steps

    func preflight(_ manifest: SiteManifest) throws {
        if let limit = Self.capabilities.maxFileCount, manifest.files.count > limit {
            throw PublishError.tooManyFiles(
                count: manifest.files.count, limit: limit, provider: Self.displayName
            )
        }
        guard let limit = Self.capabilities.maxFileSize else { return }
        // Checked before a single byte goes out: failing halfway leaves a half-uploaded
        // session and a user who has waited ten minutes for a refusal.
        for file in manifest.files where file.size > limit {
            throw PublishError.fileTooLarge(
                path: file.path, size: file.size, limit: limit, provider: Self.displayName
            )
        }
    }

    private func openUploadSession(manifest: SiteManifest) async throws -> UploadSession {
        let entries = Dictionary(
            manifest.files.map { ($0.path, ManifestEntry(hash: $0.hash, size: $0.size)) },
            uniquingKeysWith: { first, _ in first }
        )
        let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/scripts/\(CloudflareAPI.segment(scriptName))/assets-upload-session"
        let session = try await api.postJSON(
            path,
            body: ManifestBody(manifest: entries),
            as: UploadSession.self
        )
        return try CloudflareAPI.require(session, "upload session")
    }

    /// Returns the completion token when this was the request that finished the session.
    private func upload(_ files: [SiteFile], sessionJWT: String) async throws -> String? {
        var form = MultipartFormData()
        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file.localURL, options: .mappedIfSafe)
            } catch {
                throw PublishError.unreadableFile(
                    path: file.path, reason: error.localizedDescription
                )
            }
            // Field name and filename are both the hash; the part's Content-Type becomes the
            // header Cloudflare serves the asset with.
            form.append(
                name: file.hash,
                body: data.base64EncodedData(),
                filename: file.hash,
                contentType: file.contentType
            )
        }

        let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/assets/upload?base64=true"
        let result = try await api.postMultipart(
            path,
            form: form,
            as: UploadCompletion.self,
            credential: .bearer(sessionJWT)
        )
        return result?.jwt
    }

    private func deploy(assetsJWT: String) async throws {
        let metadata = WorkerMetadata(
            assets: WorkerMetadata.Assets(
                jwt: assetsJWT,
                config: WorkerMetadata.AssetsConfig(
                    // Directory-index behaviour: /workout-1/ serves /workout-1/index.html.
                    htmlHandling: "auto-trailing-slash",
                    // "none" lets Cloudflare's own 404 answer; a "404-page" setting would
                    // require every export to ship a 404.html.
                    notFoundHandling: "none"
                )
            ),
            compatibilityDate: compatibilityDate
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json: Data
        do {
            json = try encoder.encode(metadata)
        } catch {
            throw PublishError.uploadIncomplete(error.localizedDescription)
        }

        var form = MultipartFormData()
        // No `main_module` part: this is an assets-only Worker, so there is no script to run.
        form.append(name: "metadata", body: json, contentType: "application/json")

        let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/scripts/\(CloudflareAPI.segment(scriptName))"
        _ = try await api.putMultipart(path, form: form, as: EmptyResult.self)
    }

    private func enableWorkersDevSubdomain() async throws {
        let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/scripts/\(CloudflareAPI.segment(scriptName))/subdomain"
        _ = try await api.postJSON(path, body: SubdomainToggle(enabled: true), as: SubdomainToggle.self)
    }

    private func publicURL() async throws -> URL {
        let subdomain: AccountSubdomain?
        do {
            let path = "/accounts/\(CloudflareAPI.segment(accountID))/workers/subdomain"
            subdomain = try await api.get(path, as: AccountSubdomain.self)
        } catch let error as CloudflareAPIError {
            throw PublishError.noPublicURL(error.errorDescription ?? "\(error)")
        }
        guard let name = subdomain?.subdomain, !name.isEmpty else {
            throw PublishError.noPublicURL(
                "this account has no workers.dev subdomain yet. Register one in the Workers dashboard."
            )
        }
        guard let url = URL(string: "https://\(scriptName).\(name).workers.dev\(pathPrefix)") else {
            throw PublishError.noPublicURL("\(scriptName).\(name).workers.dev is not a usable address")
        }
        return url
    }

    // MARK: Helpers

    func validateScriptName() throws {
        if let reason = Self.validateSiteName(scriptName) {
            throw PublishError.invalidSiteName(name: scriptName, reason: reason)
        }
    }

    /// Cloudflare's buckets are already sized for it; this only splits one further when a
    /// single request would carry more than `maxBytes`. A file larger than the ceiling still
    /// goes out alone rather than being dropped.
    static func batches(of files: [SiteFile], maxBytes: Int) -> [[SiteFile]] {
        var batches: [[SiteFile]] = []
        var current: [SiteFile] = []
        var currentBytes = 0
        for file in files {
            if !current.isEmpty, currentBytes + Int(file.size) > maxBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(file)
            currentBytes += Int(file.size)
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

// MARK: - Wire types

private struct ManifestEntry: Encodable, Sendable {
    let hash: String
    let size: Int64
}

private struct ManifestBody: Encodable, Sendable {
    let manifest: [String: ManifestEntry]
}

struct UploadSession: Decodable, Sendable {
    let jwt: String
    /// Hashes Cloudflare does not already have, grouped into suggested requests.
    let buckets: [[String]]

    private enum CodingKeys: String, CodingKey { case jwt, buckets }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jwt = try container.decode(String.self, forKey: .jwt)
        buckets = try container.decodeIfPresent([[String]].self, forKey: .buckets) ?? []
    }

    init(jwt: String, buckets: [[String]]) {
        self.jwt = jwt
        self.buckets = buckets
    }
}

struct UploadCompletion: Decodable, Sendable {
    /// Present only on the request that completes the session.
    let jwt: String?
}

private struct WorkerMetadata: Encodable, Sendable {
    struct AssetsConfig: Encodable, Sendable {
        let htmlHandling: String
        let notFoundHandling: String

        enum CodingKeys: String, CodingKey {
            case htmlHandling = "html_handling"
            case notFoundHandling = "not_found_handling"
        }
    }

    struct Assets: Encodable, Sendable {
        let jwt: String
        let config: AssetsConfig
    }

    let assets: Assets
    let compatibilityDate: String

    enum CodingKeys: String, CodingKey {
        case assets
        case compatibilityDate = "compatibility_date"
    }
}

private struct SubdomainToggle: Codable, Sendable {
    let enabled: Bool
}

struct AccountSubdomain: Decodable, Sendable {
    let subdomain: String
}

struct TokenVerification: Decodable, Sendable {
    let id: String?
    let status: String
}

struct AccountSummary: Decodable, Sendable {
    let id: String
    let name: String
}

extension String {
    /// Last path segment of a site-absolute path, for progress text.
    var lastPathSegment: String {
        split(separator: "/").last.map(String.init) ?? self
    }
}
