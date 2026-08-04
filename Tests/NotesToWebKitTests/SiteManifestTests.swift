import CryptoKit
import Foundation
import Testing
@testable import NotesToWebKit

/// Builds a throwaway directory tree and hands back its root.
private func makeTree(_ files: [String: Data]) throws -> URL {
    let root = URL(filePath: NSTemporaryDirectory())
        .appending(path: "notes-to-web-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
    for (path, data) in files {
        let url = root.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
    return root
}

private func text(_ string: String) -> Data { Data(string.utf8) }

@Suite("Site manifest")
struct SiteManifestTests {

    @Test("Relative paths are site-absolute and sorted")
    func paths() throws {
        let root = try makeTree([
            "index.html": text("<!doctype html>"),
            "assets/style.css": text("body{}"),
            "assets/clip.mp4": text("not really a movie"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root)
        #expect(manifest.files.map(\.path) == ["/assets/clip.mp4", "/assets/style.css", "/index.html"])
    }

    @Test("A path prefix places the whole tree under a subpath")
    func prefix() throws {
        let root = try makeTree(["index.html": text("hi"), "assets/style.css": text("body{}")])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root, pathPrefix: "workout-1")
        #expect(manifest.files.map(\.path) == ["/workout-1/assets/style.css", "/workout-1/index.html"])
        #expect(SiteManifest.normalizedPrefix("") == "/")
        #expect(SiteManifest.normalizedPrefix("/a/") == "/a/")
        #expect(SiteManifest.normalizedPrefix("a") == "/a/")
    }

    @Test("Dotfiles and hidden directories never reach the manifest")
    func dotfiles() throws {
        let root = try makeTree([
            "index.html": text("hi"),
            ".DS_Store": text("junk"),
            ".git/config": text("[core]"),
            "assets/.DS_Store": text("junk"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root)
        #expect(manifest.files.map(\.path) == ["/index.html"])
    }

    @Test("Hashes match Cloudflare's derivation: sha256(base64(bytes) + extension), 32 hex chars")
    func goldenHashes() throws {
        let root = try makeTree([
            "hello.txt": text("hello"),
            "index.html": text("<!doctype html><title>Hi</title>\n"),
            "empty.css": Data(),
            "clip.mp4": text("abcd"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root)
        let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })

        // Computed independently: sha256((base64 of contents) + extension).hex[0..<32]
        #expect(byPath["/hello.txt"]?.hash == "129d0bf9c674d4cc340cf5f8feeb9f36")
        #expect(byPath["/index.html"]?.hash == "924c3bc4b1b97972f6620ed497a7159c")
        #expect(byPath["/empty.css"]?.hash == "36e64f19f57a05c8cd5b6bf7eff72703")
        #expect(byPath["/clip.mp4"]?.hash == "6455934667a2ce6027f261c601ee6066")
        #expect(manifest.files.allSatisfy { $0.hash.count == 32 })
    }

    @Test("Chunked hashing of a multi-megabyte file matches hashing it in one shot")
    func streamedHashing() throws {
        // Deliberately not a multiple of 3 and larger than the read chunk, so a naive
        // implementation would emit base64 padding mid-stream and diverge.
        var bytes = Data(count: 3 * 256 * 1024 * 2 + 7)
        for index in bytes.indices { bytes[index] = UInt8(index % 251) }
        let root = try makeTree(["big.mp4": bytes])
        defer { try? FileManager.default.removeItem(at: root) }

        let oneShot = SHA256.hash(data: Data((bytes.base64EncodedString() + "mp4").utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(32)

        let manifest = try SiteManifest.build(root: root)
        #expect(manifest.files.first?.hash == String(oneShot))
        #expect(manifest.files.first?.size == Int64(bytes.count))
    }

    @Test("Content types cover the formats an export actually ships")
    func contentTypes() throws {
        let root = try makeTree([
            "index.html": text("hi"),
            "assets/style.css": text("body{}"),
            "assets/clip.mp4": text("x"),
            "assets/clip.poster.jpg": text("x"),
            "assets/notes.weirdext": text("x"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let types = Dictionary(
            uniqueKeysWithValues: try SiteManifest.build(root: root).files.map { ($0.path, $0.contentType) }
        )
        #expect(types["/index.html"] == "text/html")
        #expect(types["/assets/style.css"] == "text/css")
        #expect(types["/assets/clip.mp4"] == "video/mp4")
        #expect(types["/assets/clip.poster.jpg"] == "image/jpeg")
        #expect(types["/assets/notes.weirdext"] == "application/octet-stream")
    }

    @Test("Identical files collapse to one upload, and sizes total up")
    func dedupe() throws {
        let root = try makeTree([
            "a/logo.png": text("same bytes"),
            "b/logo.png": text("same bytes"),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try SiteManifest.build(root: root)
        #expect(manifest.files.count == 2)
        #expect(manifest.filesByHash.count == 1)
        #expect(manifest.totalByteCount == 20)
    }

    @Test("A file that is not a directory is refused with a readable message")
    func notADirectory() throws {
        let root = try makeTree(["index.html": text("hi")])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: PublishError.self) {
            try SiteManifest.build(root: root.appending(path: "index.html"))
        }
    }
}
