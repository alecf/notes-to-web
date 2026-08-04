import Foundation

/// Progress for a publish run.
///
/// Byte counts lead because file counts lie: a note is usually one 20 MB video and
/// a dozen 4 KB pages, and a bar driven by file count sits at 92% for a minute.
public struct PublishProgress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    public let message: String

    public init(
        completedBytes: Int64,
        totalBytes: Int64,
        completedFiles: Int,
        totalFiles: Int,
        message: String
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.message = message
    }

    public var fraction: Double {
        if totalBytes > 0 {
            return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
        }
        if totalFiles > 0 {
            return min(1, max(0, Double(completedFiles) / Double(totalFiles)))
        }
        return 0
    }
}

public struct PublishResult: Sendable {
    public let url: URL
    public let uploadedFileCount: Int
    /// Files the host already had, matched by content hash, so we never sent them.
    public let skippedFileCount: Int
    public let uploadedByteCount: Int64
    public let warnings: [String]

    public init(
        url: URL,
        uploadedFileCount: Int,
        skippedFileCount: Int,
        uploadedByteCount: Int64,
        warnings: [String]
    ) {
        self.url = url
        self.uploadedFileCount = uploadedFileCount
        self.skippedFileCount = skippedFileCount
        self.uploadedByteCount = uploadedByteCount
        self.warnings = warnings
    }
}

public struct ProviderCapabilities: Sendable {
    public let maxFileSize: Int64?
    public let maxFileCount: Int?
    public let supportsSubpaths: Bool
    /// What the provider calls the secret, e.g. "API token".
    public let credentialLabel: String
    /// Human instructions for obtaining the credential, shown in the UI.
    public let credentialHelp: String
    /// The same instructions as discrete steps, so the UI can number them
    /// instead of presenting a paragraph nobody reads.
    public let credentialSteps: [String]
    /// Where to go create it.
    public let credentialURL: URL?

    public init(
        maxFileSize: Int64?,
        maxFileCount: Int?,
        supportsSubpaths: Bool,
        credentialLabel: String,
        credentialHelp: String,
        credentialSteps: [String] = [],
        credentialURL: URL?
    ) {
        self.credentialSteps = credentialSteps
        self.maxFileSize = maxFileSize
        self.maxFileCount = maxFileCount
        self.supportsSubpaths = supportsSubpaths
        self.credentialLabel = credentialLabel
        self.credentialHelp = credentialHelp
        self.credentialURL = credentialURL
    }
}

public protocol SitePublisher: Sendable {
    /// Stable identifier; also the keychain account key for this provider's credential.
    static var providerID: String { get }
    static var displayName: String { get }
    static var capabilities: ProviderCapabilities { get }

    /// Confirms the credential works; returns a human label for the connected account.
    func validateCredentials() async throws -> String

    /// Uploads the whole directory tree rooted at `siteRoot`, preserving relative paths.
    func publish(
        siteRoot: URL,
        progress: @Sendable @escaping (PublishProgress) -> Void
    ) async throws -> PublishResult
}

extension SitePublisher {
    public func publish(siteRoot: URL) async throws -> PublishResult {
        try await publish(siteRoot: siteRoot, progress: { _ in })
    }
}

public enum PublishError: Error, LocalizedError, Equatable {
    case notADirectory(URL)
    case emptySite(URL)
    /// A single file is over the provider's ceiling. Names the file and both sizes,
    /// because "413 Payload Too Large" tells the user nothing they can act on.
    case fileTooLarge(path: String, size: Int64, limit: Int64, provider: String)
    case tooManyFiles(count: Int, limit: Int, provider: String)
    case unreadableFile(path: String, reason: String)
    /// `reason` is the provider's own rule, in a sentence: the generic version of this
    /// message sends people off to guess which character was the problem.
    case invalidSiteName(name: String, reason: String)
    case credentialRejected(String)
    case accountNotFound(String)
    /// The provider took the files but never told us the deployment was complete.
    case uploadIncomplete(String)
    case noPublicURL(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            "\(url.lastPathComponent) is not a folder, so there is nothing to publish."
        case .emptySite(let url):
            "\(url.lastPathComponent) is empty. Export the note first, then publish that folder."
        case .fileTooLarge(let path, let size, let limit, let provider):
            """
            \(path) is \(Self.bytes(size)), but \(provider) will not accept any file over \
            \(Self.bytes(limit)). Re-export with a shorter or lower-resolution video, or host \
            that file somewhere else, then publish again. Nothing was uploaded.
            """
        case .tooManyFiles(let count, let limit, let provider):
            """
            This folder has \(count) files and \(provider) allows \(limit) per deployment. \
            Split it into separate sites. Nothing was uploaded.
            """
        case .unreadableFile(let path, let reason):
            "Could not read \(path): \(reason)"
        case .invalidSiteName(let name, let reason):
            "“\(name)” is not a usable site name. \(reason)"
        case .credentialRejected(let detail):
            detail
        case .accountNotFound(let identifier):
            """
            This token cannot see account \(identifier). Check the account ID, and make sure the \
            token was scoped to that account when you created it.
            """
        case .uploadIncomplete(let detail):
            """
            The files uploaded but the site was not published: \(detail). Nothing was changed on \
            the live site; try again.
            """
        case .noPublicURL(let detail):
            """
            The site was published but its public address could not be determined: \(detail). \
            Check the Workers dashboard for the URL.
            """
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
