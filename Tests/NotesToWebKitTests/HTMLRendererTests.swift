import Foundation
import Testing
@testable import NotesToWebKit

private func document(_ blocks: [Block], attachments: [String: StoredAttachment] = [:]) -> NoteDocument {
    NoteDocument(title: "Doc", blocks: blocks, attachments: attachments)
}

private let videoAttachment = StoredAttachment(
    identifier: "vid",
    typeUTI: "com.apple.quicktime-movie",
    filename: "IMG_1.mov",
    title: nil,
    urlString: nil,
    fileURL: URL(filePath: "/tmp/IMG_1.mov"),
    fileSize: 500
)

@Suite("HTML renderer")
struct HTMLRendererTests {

    @Test("Consecutive list items collapse into a single list")
    func listGrouping() {
        let blocks: [Block] = [
            .listItem(kind: .bulleted, indent: 0, checked: nil, spans: [Span(text: "one")]),
            .listItem(kind: .bulleted, indent: 0, checked: nil, spans: [Span(text: "two")]),
            .paragraph([Span(text: "break")]),
            .listItem(kind: .numbered, indent: 0, checked: nil, spans: [Span(text: "three")]),
        ]
        let html = HTMLRenderer().renderBlocks(document(blocks))

        #expect(html.components(separatedBy: "<ul>").count == 2)
        #expect(html.contains("<li>one</li>\n<li>two</li>"))
        #expect(html.contains("<ol>"))
    }

    @Test("Videos render as an inline video element with a poster")
    func videoRendering() {
        let assets = ["vid": RenderedAsset(
            mediaPath: "assets/IMG_1.mp4",
            posterPath: "assets/IMG_1.poster.jpg",
            mimeType: "video/mp4",
            displayName: "IMG_1.mov",
            byteCount: 500
        )]
        let html = HTMLRenderer(assets: assets)
            .renderBlocks(document([.attachment(identifier: "vid")], attachments: ["vid": videoAttachment]))

        #expect(html.contains("<video controls preload=\"metadata\" playsinline poster=\"assets/IMG_1.poster.jpg\">"))
        #expect(html.contains("<source src=\"assets/IMG_1.mp4\" type=\"video/mp4\">"))
        // A download link inside the element is the fallback for browsers that refuse the codec.
        #expect(html.contains("<a href=\"assets/IMG_1.mp4\">Download IMG_1.mov</a>"))
    }

    @Test("An attachment with no exported file says so instead of rendering a dead element")
    func missingAssetRendering() {
        let assets = ["vid": RenderedAsset(
            mediaPath: nil, posterPath: nil, mimeType: "video/quicktime",
            displayName: "IMG_1.mov", byteCount: 0
        )]
        let html = HTMLRenderer(assets: assets)
            .renderBlocks(document([.attachment(identifier: "vid")], attachments: ["vid": videoAttachment]))

        #expect(html.contains("not downloaded to this Mac"))
        #expect(!html.contains("<video"))
    }

    @Test("Text is escaped")
    func escaping() {
        let html = HTMLRenderer().renderBlocks(document([
            .paragraph([Span(text: "5 < 6 & \"quoted\" <script>alert(1)</script>")])
        ]))
        #expect(html.contains("5 &lt; 6 &amp; &quot;quoted&quot; &lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }

    @Test("Dangerous link schemes are stripped", arguments: [
        "javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "vbscript:x",
    ])
    func unsafeLinksDropped(href: String) {
        let html = HTMLRenderer().renderBlocks(document([
            .paragraph([Span(text: "click", link: href)])
        ]))
        #expect(!html.contains("<a href"))
        #expect(html.contains("click"))
    }

    @Test("Ordinary link schemes survive", arguments: [
        "https://example.com", "http://example.com", "mailto:a@b.c", "tel:+15550100",
    ])
    func safeLinksKept(href: String) {
        let html = HTMLRenderer().renderBlocks(document([
            .paragraph([Span(text: "click", link: href)])
        ]))
        #expect(html.contains("rel=\"noopener noreferrer\""))
    }

    @Test("Nested inline styles all apply")
    func nestedStyles() {
        let html = HTMLRenderer().renderBlocks(document([
            .paragraph([Span(text: "x", style: [.bold, .italic, .strikethrough])])
        ]))
        #expect(html.contains("<strong>"))
        #expect(html.contains("<em>"))
        #expect(html.contains("<s>"))
    }

    @Test("Checked checklist items are marked both semantically and visually")
    func checklistRendering() {
        let html = HTMLRenderer().renderBlocks(document([
            .listItem(kind: .checklist, indent: 0, checked: true, spans: [Span(text: "done")]),
            .listItem(kind: .checklist, indent: 0, checked: false, spans: [Span(text: "todo")]),
        ]))
        #expect(html.contains("<ul class=\"checklist\">"))
        #expect(html.contains("<li class=\"done\"><input type=\"checkbox\" disabled checked>"))
        #expect(html.contains("<li><input type=\"checkbox\" disabled>"))
    }

    @Test("A full page has the structure a static host needs")
    func fullPage() {
        let html = HTMLRenderer().render(document([.title([Span(text: "Hi")])]))
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<meta name=\"viewport\""))
        #expect(html.contains("<title>Doc</title>"))
        #expect(html.contains("<link rel=\"stylesheet\" href=\"assets/style.css\">"))
    }
}

@Suite("Gzip")
struct GzipTests {
    @Test("Round-trips a gzip stream produced by the system gzip")
    func roundTrip() throws {
        let original = Data(String(repeating: "notes to web ", count: 500).utf8)
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "gzip-test-\(UUID().uuidString).txt", directoryHint: .notDirectory)
        try original.write(to: tmp)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = ["-n", tmp.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()

        let gzURL = URL(filePath: tmp.path(percentEncoded: false) + ".gz")
        defer { try? FileManager.default.removeItem(at: gzURL) }

        #expect(try Gzip.decompress(Data(contentsOf: gzURL)) == original)
    }

    @Test("Rejects data that is not gzip")
    func rejectsNonGzip() {
        #expect(throws: GzipError.self) {
            try Gzip.decompress(Data(repeating: 0x41, count: 64))
        }
    }
}
