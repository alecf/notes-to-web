import Foundation
import Testing

@testable import NotesToWebKit

@Suite("Site library")
struct SiteLibraryTests {
    /// A fresh temporary site root, removed when the test finishes.
    private func withTemporaryRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "notes-to-web-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(root)
    }

    @Test("Slugs are derived from the title and stay unique")
    func slugsAreUnique() async throws {
        try await withTemporaryRoot { root in
            let library = SiteLibrary(root: root)
            try await library.prepare()

            let first = try await library.slug(forTitle: "Workout Plan", noteIdentifier: "a/1")
            #expect(first == "workout-plan")

            try await library.record(SiteEntry(
                slug: first, title: "Workout Plan", noteIdentifier: "a/1",
                updatedAt: .now, byteCount: 10, assetCount: 1
            ))

            // A different note with the same title must not claim the same path.
            let second = try await library.slug(forTitle: "Workout Plan", noteIdentifier: "a/2")
            #expect(second == "workout-plan-2")
        }
    }

    @Test("Re-exporting a note keeps its published URL stable")
    func slugsAreStableForTheSameNote() async throws {
        try await withTemporaryRoot { root in
            let library = SiteLibrary(root: root)
            try await library.prepare()

            let slug = try await library.slug(forTitle: "Workout Plan", noteIdentifier: "a/1")
            try await library.record(SiteEntry(
                slug: slug, title: "Workout Plan", noteIdentifier: "a/1",
                updatedAt: .now, byteCount: 10, assetCount: 1
            ))

            // Same note, retitled: the slug it was published under wins, because
            // changing it would break every link anyone already has.
            let again = try await library.slug(forTitle: "Totally Different Name", noteIdentifier: "a/1")
            #expect(again == slug)

            let entries = try await library.entries()
            #expect(entries.count == 1)
        }
    }

    @Test("Recording a note writes an index listing it")
    func recordWritesIndex() async throws {
        try await withTemporaryRoot { root in
            let library = SiteLibrary(root: root)
            try await library.prepare()
            try await library.record(SiteEntry(
                slug: "workout-plan", title: "Workout Plan", noteIdentifier: "a/1",
                updatedAt: .now, byteCount: 1_048_576, assetCount: 3
            ))

            let index = try String(contentsOf: root.appending(path: "index.html"), encoding: .utf8)
            #expect(index.contains(#"href="workout-plan/""#))
            #expect(index.contains("Workout Plan"))
            #expect(index.contains("3 files"))

            // The index needs a stylesheet at the root, beside it.
            #expect(FileManager.default.fileExists(
                atPath: root.appending(path: "assets/style.css").path(percentEncoded: false)
            ))
        }
    }

    @Test("Removing a note drops its directory and its index entry")
    func removeDeletesEverything() async throws {
        try await withTemporaryRoot { root in
            let library = SiteLibrary(root: root)
            try await library.prepare()
            try await library.clearDirectory(for: "workout-plan")
            try Data("hi".utf8).write(to: root.appending(path: "workout-plan/index.html"))
            try await library.record(SiteEntry(
                slug: "workout-plan", title: "Workout Plan", noteIdentifier: "a/1",
                updatedAt: .now, byteCount: 2, assetCount: 0
            ))

            try await library.remove(slug: "workout-plan")

            #expect(try await library.entries().isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(path: "workout-plan").path(percentEncoded: false)
            ))
        }
    }

    @Test("Clearing a directory drops assets a previous export left behind")
    func clearDirectoryRemovesStaleAssets() async throws {
        try await withTemporaryRoot { root in
            let library = SiteLibrary(root: root)
            try await library.prepare()
            try await library.clearDirectory(for: "workout-plan")

            let stale = root.appending(path: "workout-plan/assets/old.mp4")
            try FileManager.default.createDirectory(
                at: stale.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("stale".utf8).write(to: stale)

            try await library.clearDirectory(for: "workout-plan")
            #expect(!FileManager.default.fileExists(atPath: stale.path(percentEncoded: false)))
        }
    }

    @Test("Metadata survives a round trip through disk")
    func metadataRoundTrips() async throws {
        try await withTemporaryRoot { root in
            try await SiteLibrary(root: root).prepare()
            try await SiteLibrary(root: root).record(SiteEntry(
                slug: "a", title: "A", noteIdentifier: "x/1",
                updatedAt: .now, byteCount: 5, assetCount: 1
            ))

            let reopened = try await SiteLibrary(root: root).entries()
            #expect(reopened.map(\.slug) == ["a"])
            #expect(reopened.first?.noteIdentifier == "x/1")
        }
    }

    @Test("Titles that are all punctuation still produce a usable slug")
    func slugFallsBackForUnusableTitles() {
        #expect("".slugified == "note")
        #expect("///".slugified == "note")
        #expect("Café ☕️ Notes".slugified == "cafe-notes")
    }

    @Test("The index escapes titles rather than trusting them")
    func indexEscapesTitles() {
        let html = IndexPage(
            siteTitle: "My <Notes>",
            entries: [SiteEntry(
                slug: "x", title: #"<script>alert("hi")</script>"#, noteIdentifier: "a/1",
                updatedAt: .now, byteCount: 1, assetCount: 0
            )]
        ).render()

        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("My &lt;Notes&gt;"))
    }
}
