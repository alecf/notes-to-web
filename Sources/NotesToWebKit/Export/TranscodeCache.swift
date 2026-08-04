import CryptoKit
import Foundation

/// Keeps compressed video around so re-exporting a note does not re-encode
/// footage that has not changed.
///
/// Compression dominates export time — a 17-clip note is most of a minute — and
/// almost every re-export changes only the note's text. Keying on both the
/// source file and the encode settings means an unchanged video is reused, and
/// changing quality, codec, or size budget correctly invalidates everything.
///
/// Lives in `~/Library/Caches`, which is the contract for "expensive to make,
/// safe to delete": macOS may reclaim it under disk pressure, Time Machine
/// skips it, and cleanup tools know to empty it. Application Support would have
/// been wrong — nothing ever reclaims that.
public struct TranscodeCache: Sendable {
    public static let defaultDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appending(path: "com.alecf.notes-to-web/transcodes", directoryHint: .isDirectory)

    public let directory: URL
    /// Evicted down to this on `prune()`, oldest use first.
    public let maximumBytes: Int64
    /// Entries untouched for longer than this go regardless of total size, so a
    /// user who exports twice and never returns does not keep gigabytes forever.
    public let maximumAge: TimeInterval

    public init(
        directory: URL = TranscodeCache.defaultDirectory,
        maximumBytes: Int64 = 3 * 1024 * 1024 * 1024,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
    }

    // MARK: Keys

    /// Identity of a source file plus the settings it would be encoded with.
    ///
    /// Size and modification date rather than a content hash: Notes writes each
    /// revision of an attachment to a new generation directory, so the path
    /// itself changes when the media changes, and hashing 500 MB on every export
    /// would cost more than it saves.
    public func key(for source: URL, settings: VideoEncodeSettings) -> String? {
        guard var hasher = Self.identityHasher(for: source) else { return nil }
        hasher.update(data: Self.fingerprint(of: settings))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Identity of a source file alone, for artefacts that do not depend on
    /// encode settings — a poster frame is the same still whatever bitrate the
    /// video ends up at.
    public func key(for source: URL) -> String? {
        guard let hasher = Self.identityHasher(for: source) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Path, size, and modification date.
    ///
    /// Deliberately `FileManager.attributesOfItem` rather than
    /// `URL.resourceValues`: the latter caches per URL instance, so re-reading a
    /// file that has been rewritten hands back the *old* size and the key would
    /// not change. That would serve a stale encode for an edited video.
    private static func identityHasher(for source: URL) -> SHA256? {
        let path = source.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: Data("\(size.int64Value)".utf8))
        hasher.update(data: Data("\(modified)".utf8))
        return hasher
    }

    /// A stable encoding of the settings, so the same settings always produce
    /// the same key and any new field automatically invalidates the cache.
    private static func fingerprint(of settings: VideoEncodeSettings) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(settings)) ?? Data()
    }

    // MARK: Lookup

    private func fileURL(for key: String, extension ext: String) -> URL {
        directory.appending(path: "\(key).\(ext)", directoryHint: .notDirectory)
    }

    /// Copies a cached encode into place. Returns false when there is no hit.
    ///
    /// On APFS this is a clone, so it costs no time and no extra space until one
    /// of the copies is written to.
    public func restore(key: String, to destination: URL, extension ext: String = "mp4") -> Bool {
        let cached = fileURL(for: key, extension: ext)
        guard FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)) else {
            return false
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: cached, to: destination)
            touch(cached)
            return true
        } catch {
            // A corrupt or half-written entry must never fail an export; drop it
            // and let the caller encode from scratch.
            try? FileManager.default.removeItem(at: cached)
            return false
        }
    }

    /// Adds a finished encode to the cache. Failure is silent: a cache that
    /// cannot be written is a lost optimisation, not a failed export.
    public func store(_ file: URL, key: String, extension ext: String = "mp4") {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let cached = fileURL(for: key, extension: ext)
            try? FileManager.default.removeItem(at: cached)
            try FileManager.default.copyItem(at: file, to: cached)
        } catch {
            return
        }
    }

    /// Records use, so eviction is least-recently-used rather than oldest-made.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
    }

    // MARK: Eviction

    public struct Contents: Sendable {
        public let fileCount: Int
        public let byteCount: Int64
    }

    public func contents() -> Contents {
        let entries = self.entries()
        return Contents(
            fileCount: entries.count,
            byteCount: entries.reduce(0) { $0 + $1.size }
        )
    }

    private struct Entry {
        let url: URL
        let size: Int64
        let used: Date
    }

    private func entries() -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ), let size = values.fileSize else { return nil }
            return Entry(
                url: url,
                size: Int64(size),
                used: values.contentModificationDate ?? .distantPast
            )
        }
    }

    /// Drops anything stale, then anything over the size ceiling, oldest first.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        var kept: [Entry] = []
        var removed = 0

        for entry in entries() {
            if now.timeIntervalSince(entry.used) > maximumAge {
                try? FileManager.default.removeItem(at: entry.url)
                removed += 1
            } else {
                kept.append(entry)
            }
        }

        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        guard total > maximumBytes else { return removed }

        for entry in kept.sorted(by: { $0.used < $1.used }) {
            if total <= maximumBytes { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            removed += 1
        }
        return removed
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
