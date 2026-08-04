import Foundation
import Testing

@testable import NotesToWebKit

@Suite("Transcode cache")
struct TranscodeCacheTests {
    private func withCache<T>(
        maximumBytes: Int64 = 3 * 1024 * 1024 * 1024,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60,
        _ body: (TranscodeCache, URL) async throws -> T
    ) async throws -> T {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "ntw-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let cache = TranscodeCache(
            directory: scratch.appending(path: "cache", directoryHint: .isDirectory),
            maximumBytes: maximumBytes,
            maximumAge: maximumAge
        )
        return try await body(cache, scratch)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test("The same file and the same settings reuse the previous encode")
    func hitOnIdenticalInputs() async throws {
        try await withCache { cache, scratch in
            let source = scratch.appending(path: "clip.mov")
            try write(1_000, to: source)
            let settings = VideoEncodeSettings(quality: .balanced, codec: .h264, sizeBudget: nil)

            let key = try #require(cache.key(for: source, settings: settings))
            let encoded = scratch.appending(path: "out.mp4")
            try write(500, to: encoded)
            cache.store(encoded, key: key)

            let restored = scratch.appending(path: "again.mp4")
            #expect(cache.restore(key: key, to: restored))
            #expect(try Data(contentsOf: restored).count == 500)
        }
    }

    @Test("Changing any encode setting invalidates the cache")
    func missOnChangedSettings() async throws {
        try await withCache { cache, scratch in
            let source = scratch.appending(path: "clip.mov")
            try write(1_000, to: source)

            let base = VideoEncodeSettings(quality: .balanced, codec: .h264, sizeBudget: nil)
            let key = try #require(cache.key(for: source, settings: base))

            // Each of these is a different encode and must not reuse the other's output.
            let variants = [
                VideoEncodeSettings(quality: .small, codec: .h264, sizeBudget: nil),
                VideoEncodeSettings(quality: .balanced, codec: .hevc, sizeBudget: nil),
                VideoEncodeSettings(quality: .balanced, codec: .h264, sizeBudget: 5_000_000),
            ]
            for variant in variants {
                #expect(cache.key(for: source, settings: variant) != key)
            }
        }
    }

    @Test("Editing the source invalidates the cache")
    func missOnChangedSource() async throws {
        try await withCache { cache, scratch in
            let source = scratch.appending(path: "clip.mov")
            try write(1_000, to: source)
            let settings = VideoEncodeSettings.webDefault
            let before = try #require(cache.key(for: source, settings: settings))

            // A different length is a different video, whatever the path says.
            try write(2_000, to: source)
            #expect(cache.key(for: source, settings: settings) != before)
        }
    }

    @Test("A cache miss is reported, not faked")
    func missReturnsFalse() async throws {
        try await withCache { cache, scratch in
            let destination = scratch.appending(path: "out.mp4")
            #expect(!cache.restore(key: "nope", to: destination))
            #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        }
    }

    @Test("Entries nobody has used in a long time are dropped")
    func prunesByAge() async throws {
        try await withCache(maximumAge: 60) { cache, scratch in
            let file = scratch.appending(path: "a.mp4")
            try write(100, to: file)
            cache.store(file, key: "old")
            cache.store(file, key: "new")

            let stale = cache.directory.appending(path: "old.mp4")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                ofItemAtPath: stale.path(percentEncoded: false)
            )

            #expect(cache.prune() == 1)
            #expect(!cache.restore(key: "old", to: scratch.appending(path: "x.mp4")))
            #expect(cache.restore(key: "new", to: scratch.appending(path: "y.mp4")))
        }
    }

    @Test("Over the size ceiling, the least recently used goes first")
    func prunesBySizeLeastRecentlyUsedFirst() async throws {
        try await withCache(maximumBytes: 250) { cache, scratch in
            let file = scratch.appending(path: "a.mp4")
            try write(100, to: file)
            for key in ["first", "second", "third"] {
                cache.store(file, key: key)
            }
            // Make "first" the oldest use and "third" the newest.
            for (key, offset) in [("first", -300.0), ("second", -200.0), ("third", -100.0)] {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: offset)],
                    ofItemAtPath: cache.directory.appending(path: "\(key).mp4").path(percentEncoded: false)
                )
            }

            #expect(cache.prune() == 1)
            #expect(!cache.restore(key: "first", to: scratch.appending(path: "x.mp4")))
            #expect(cache.restore(key: "third", to: scratch.appending(path: "z.mp4")))
            #expect(cache.contents().byteCount <= 250)
        }
    }

    @Test("Using an entry protects it from the next eviction")
    func restoringCountsAsUse() async throws {
        try await withCache(maximumBytes: 150) { cache, scratch in
            let file = scratch.appending(path: "a.mp4")
            try write(100, to: file)
            cache.store(file, key: "kept")
            cache.store(file, key: "dropped")

            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                ofItemAtPath: cache.directory.appending(path: "kept.mp4").path(percentEncoded: false)
            )
            // Touching it moves it to the front of the queue.
            #expect(cache.restore(key: "kept", to: scratch.appending(path: "x.mp4")))

            cache.prune()
            #expect(cache.restore(key: "kept", to: scratch.appending(path: "y.mp4")))
        }
    }

    @Test("Poster keys ignore encode settings, since a still does not depend on them")
    func posterKeyIsSettingsIndependent() async throws {
        try await withCache { cache, scratch in
            let source = scratch.appending(path: "clip.mov")
            try write(1_000, to: source)
            let key = try #require(cache.key(for: source))
            // Same file, no settings involved: stable across quality changes.
            #expect(cache.key(for: source) == key)
            #expect(cache.key(for: source, settings: .webDefault) != key)
        }
    }

    @Test("A missing source file has no key rather than a bogus one")
    func noKeyForMissingSource() async throws {
        try await withCache { cache, scratch in
            let missing = scratch.appending(path: "gone.mov")
            #expect(cache.key(for: missing, settings: .webDefault) == nil)
            #expect(cache.key(for: missing) == nil)
        }
    }
}
