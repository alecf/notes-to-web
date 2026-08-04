import CryptoKit
import Foundation
import UniformTypeIdentifiers

public struct SiteFile: Sendable, Equatable {
    /// Site-absolute path, always leading-slashed: `/index.html`, `/assets/style.css`.
    public let path: String
    public let localURL: URL
    /// Content hash in the provider's format (see `SiteManifest.contentHash`).
    public let hash: String
    public let size: Int64
    public let contentType: String

    public init(path: String, localURL: URL, hash: String, size: Int64, contentType: String) {
        self.path = path
        self.localURL = localURL
        self.hash = hash
        self.size = size
        self.contentType = contentType
    }
}

/// The set of files that make up one site, hashed and typed, ready to hand to a provider.
public struct SiteManifest: Sendable {
    public let root: URL
    /// Sorted by path so manifests are reproducible run to run.
    public let files: [SiteFile]

    public init(root: URL, files: [SiteFile]) {
        self.root = root
        self.files = files.sorted { $0.path < $1.path }
    }

    public var totalByteCount: Int64 { files.reduce(0) { $0 + $1.size } }

    public var largest: SiteFile? { files.max { $0.size < $1.size } }

    /// Files keyed by hash, deduplicated: two identical assets upload once.
    public var filesByHash: [String: SiteFile] {
        var result: [String: SiteFile] = [:]
        for file in files where result[file.hash] == nil { result[file.hash] = file }
        return result
    }

    /// Walks `root` and hashes every regular file.
    ///
    /// `pathPrefix` places the whole tree under a subpath so several exported notes can
    /// share one domain (`/workout-1/`, `/workout-2/`).
    public static func build(root: URL, pathPrefix: String = "/") throws -> SiteManifest {
        let fm = FileManager.default
        let base = root.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: base.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PublishError.notADirectory(root)
        }

        let prefix = normalizedPrefix(pathPrefix)
        // Path-based enumeration hands back paths already relative to the root. The URL-based
        // enumerator does not: it reports `/private/var/…` for a root that standardizes to
        // `/var/…`, and subtracting one from the other silently drops every file.
        guard let walker = fm.enumerator(atPath: base.path(percentEncoded: false)) else {
            throw PublishError.notADirectory(root)
        }

        var files: [SiteFile] = []
        for case let relative as String in walker {
            try Task.checkCancellation()

            let url = base.appending(path: relative, directoryHint: .notDirectory)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])

            // Dotfiles are editor and Finder detritus (.DS_Store, .git); never publish them.
            // Checking every component, not just the last, covers anything the enumerator
            // hands back before we get the chance to prune its parent.
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let ext = url.pathExtension
            let size = Int64(values?.fileSize ?? 0)
            files.append(SiteFile(
                path: prefix + relative,
                localURL: url,
                hash: try contentHash(of: url, pathExtension: ext),
                size: size,
                contentType: contentType(forPathExtension: ext)
            ))
        }

        return SiteManifest(root: base, files: files)
    }

    /// Normalizes `""`, `"foo"`, `"/foo/"` to `"/"` or `"/foo/"`.
    public static func normalizedPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "/" : "/\(trimmed)/"
    }

    // MARK: Hashing

    /// Cloudflare's asset hash: SHA-256 over the file's **base64 text** concatenated with the
    /// bare path extension, hex-encoded, truncated to 32 characters. The base64 and the
    /// extension are both load-bearing — hashing the raw bytes produces a hash the upload
    /// session will reject as unknown, and the truncation is to 32 hex characters (128 bits),
    /// not 32 bytes.
    public static func contentHash(of url: URL, pathExtension ext: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PublishError.unreadableFile(
                path: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        // Streamed so a 25 MB video never lands in memory just to be hashed. Base64 encodes
        // in 3-byte groups, so as long as every chunk but the last is a multiple of 3 the
        // streamed encoding is byte-identical to encoding the file in one shot.
        let chunkSize = 3 * 256 * 1024
        var carry = Data()
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                carry.append(chunk)
                let whole = carry.count - (carry.count % 3)
                if whole > 0 {
                    hasher.update(data: Data(carry.prefix(whole).base64EncodedString().utf8))
                    carry.removeFirst(whole)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PublishError.unreadableFile(
                path: url.lastPathComponent,
                reason: error.localizedDescription
            )
        }
        if !carry.isEmpty {
            hasher.update(data: Data(carry.base64EncodedString().utf8))
        }
        hasher.update(data: Data(ext.utf8))

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    // MARK: Content types

    /// The types we actually ship are pinned rather than asked of the system, because
    /// `UTType` answers differ across OS releases (`.js` in particular) and a wrong
    /// `Content-Type` on an asset is baked into the deployment.
    private static let knownTypes: [String: String] = [
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "json": "application/json",
        "txt": "text/plain",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "heic": "image/heic",
        "ico": "image/vnd.microsoft.icon",
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "m4a": "audio/mp4",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "pdf": "application/pdf",
        "woff2": "font/woff2",
        "woff": "font/woff",
        "xml": "application/xml",
        "webmanifest": "application/manifest+json",
    ]

    public static func contentType(forPathExtension ext: String) -> String {
        let key = ext.lowercased()
        if let known = knownTypes[key] { return known }
        if let mime = UTType(filenameExtension: key)?.preferredMIMEType { return mime }
        return "application/octet-stream"
    }
}
