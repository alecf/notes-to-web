import Foundation

/// One published note inside a site root.
public struct SiteEntry: Sendable, Hashable, Codable, Identifiable {
    /// Directory name, and therefore the URL path segment.
    public let slug: String
    public let title: String
    /// Notes' own identifier, so re-exporting the same note reuses its slug
    /// instead of piling up `workout-2`, `workout-3`, … beside it.
    public let noteIdentifier: String
    public let updatedAt: Date
    public let byteCount: Int64
    public let assetCount: Int

    public var id: String { slug }

    public init(
        slug: String,
        title: String,
        noteIdentifier: String,
        updatedAt: Date,
        byteCount: Int64,
        assetCount: Int
    ) {
        self.slug = slug
        self.title = title
        self.noteIdentifier = noteIdentifier
        self.updatedAt = updatedAt
        self.byteCount = byteCount
        self.assetCount = assetCount
    }

    public var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        guard assetCount > 0 else { return size }
        return "\(assetCount) file\(assetCount == 1 ? "" : "s") · \(size)"
    }
}

public struct SiteMetadata: Sendable, Codable {
    public var siteTitle: String
    public var entries: [SiteEntry]

    public init(siteTitle: String = "Notes", entries: [SiteEntry] = []) {
        self.siteTitle = siteTitle
        self.entries = entries
    }
}

public enum SiteLibraryError: Error, LocalizedError {
    case couldNotCreateDirectory(URL)
    case metadataUnreadable(URL, String)
    case notADirectory(URL)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateDirectory(let url):
            "Could not create \(url.path(percentEncoded: false))."
        case .metadataUnreadable(let url, let reason):
            "\(url.lastPathComponent) could not be read (\(reason)). Move it aside and export again to start a fresh site."
        case .notADirectory(let url):
            "\(url.path(percentEncoded: false)) is not a folder."
        }
    }
}

/// Reading and writing the sidecar that records what a site contains.
enum SiteMetadataFile {
    /// Dot-prefixed so it is skipped when the tree is walked for upload.
    static let filename = ".notes-to-web.json"

    static func url(in root: URL) -> URL {
        root.appending(path: filename, directoryHint: .notDirectory)
    }

    static func read(at root: URL) throws -> SiteMetadata {
        guard let data = try? Data(contentsOf: url(in: root)) else {
            return SiteMetadata(siteTitle: root.lastPathComponent)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SiteMetadata.self, from: data)
        } catch {
            throw SiteLibraryError.metadataUnreadable(url(in: root), error.localizedDescription)
        }
    }

    static func write(_ metadata: SiteMetadata, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url(in: root))
    }
}

/// One site: a folder holding every note published to one host. Each note lives
/// in its own subdirectory, so a note published as `workout-1` is served at
/// `<site>/workout-1/`. Publishing uploads the whole folder; this folder is the
/// source of truth, not the remote host.
public actor SiteLibrary {
    public nonisolated let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: Metadata

    public func metadata() throws -> SiteMetadata {
        try SiteMetadataFile.read(at: root)
    }

    private func write(_ metadata: SiteMetadata) throws {
        try SiteMetadataFile.write(metadata, at: root)
    }

    public func setSiteTitle(_ title: String) throws {
        var meta = try metadata()
        meta.siteTitle = title
        try write(meta)
        try writeIndex(meta)
    }

    public func entries() throws -> [SiteEntry] {
        try metadata().entries.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Slugs and destinations

    /// The directory a note should be exported into. Re-exporting a note reuses
    /// the slug it already has so its published URL stays stable.
    public func slug(forTitle title: String, noteIdentifier: String) throws -> String {
        let meta = try metadata()
        if let existing = meta.entries.first(where: { $0.noteIdentifier == noteIdentifier }) {
            return existing.slug
        }
        let taken = Set(meta.entries.map(\.slug))
        let base = title.slugified
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    public nonisolated func directory(for slug: String) -> URL {
        root.appending(path: slug, directoryHint: .isDirectory)
    }

    public func prepare() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: root.path(percentEncoded: false), isDirectory: &isDirectory
        ) {
            guard isDirectory.boolValue else { throw SiteLibraryError.notADirectory(root) }
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw SiteLibraryError.couldNotCreateDirectory(root)
        }
    }

    /// Clears a note's directory so a re-export replaces it rather than merging
    /// with assets from a previous run that may no longer be referenced.
    public func clearDirectory(for slug: String) throws {
        let directory = directory(for: slug)
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SiteLibraryError.couldNotCreateDirectory(directory)
        }
    }

    // MARK: Recording

    public func record(_ entry: SiteEntry) throws {
        var meta = try metadata()
        meta.entries.removeAll { $0.slug == entry.slug || $0.noteIdentifier == entry.noteIdentifier }
        meta.entries.append(entry)
        try write(meta)
        try writeIndex(meta)
        try writeSharedStylesheet()
    }

    public func remove(slug: String) throws {
        var meta = try metadata()
        meta.entries.removeAll { $0.slug == slug }
        let directory = directory(for: slug)
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
        try write(meta)
        try writeIndex(meta)
    }

    // MARK: Generated files

    private func writeIndex(_ metadata: SiteMetadata) throws {
        let html = IndexPage(siteTitle: metadata.siteTitle, entries: metadata.entries).render()
        try Data(html.utf8).write(
            to: root.appending(path: "index.html", directoryHint: .notDirectory)
        )
    }

    /// The index page needs a stylesheet at the site root; note pages carry
    /// their own copy inside their own directory.
    private func writeSharedStylesheet() throws {
        let assets = root.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data(Stylesheet.css.utf8).write(
            to: assets.appending(path: "style.css", directoryHint: .notDirectory)
        )
    }

    // MARK: Sizing

    /// Total bytes that would be uploaded, for the pre-publish summary.
    public func totalByteCount() -> Int64 {
        Self.byteCount(of: root)
    }

    public nonisolated static func byteCount(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}
