import Foundation
import Testing
@testable import NotesToWebKit

/// Builds `PBNote` values directly rather than shipping a real note as a fixture,
/// so the tests are self-contained and contain nobody's personal data.
private enum NoteFactory {
    static func run(
        _ length: Int,
        style: Int32? = nil,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        link: String? = nil,
        checked: Bool? = nil,
        attachment: (id: String, uti: String)? = nil
    ) -> PBAttributeRun {
        var run = PBAttributeRun()
        run.length = Int32(length)

        if style != nil || checked != nil {
            var paragraph = PBParagraphStyle()
            if let style { paragraph.styleType = style }
            if let checked {
                var checklist = PBChecklist()
                checklist.done = checked ? 1 : 0
                paragraph.checklist = checklist
            }
            run.paragraphStyle = paragraph
        }
        var weight: Int32 = 0
        if bold { weight |= 1 }
        if italic { weight |= 2 }
        if weight != 0 { run.fontWeight = weight }
        if strikethrough { run.strikethrough = 1 }
        if let link { run.link = link }
        if let attachment {
            var info = PBAttachmentInfo()
            info.attachmentIdentifier = attachment.id
            info.typeUti = attachment.uti
            run.attachmentInfo = info
        }
        return run
    }

    static func note(_ text: String, _ runs: [PBAttributeRun]) -> PBNote {
        var note = PBNote()
        note.noteText = text
        note.attributeRun = runs
        return note
    }

    static func attachment(_ id: String, uti: String, filename: String) -> StoredAttachment {
        StoredAttachment(
            identifier: id,
            typeUTI: uti,
            filename: filename,
            title: nil,
            urlString: nil,
            fileURL: URL(filePath: "/tmp/\(filename)"),
            fileSize: 1234
        )
    }
}

private let objectReplacement = "\u{FFFC}"

@Suite("Note document builder")
struct NoteDocumentBuilderTests {

    @Test("Title style becomes the document title")
    func titleExtraction() {
        let note = NoteFactory.note("My Workout\nbody text\n", [
            NoteFactory.run(11, style: 0),
            NoteFactory.run(10),
        ])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "fallback")

        #expect(doc.title == "My Workout")
        #expect(doc.blocks.first == .title([Span(text: "My Workout")]))
    }

    @Test("Falls back to the store's title when the note has no title paragraph")
    func titleFallback() {
        let note = NoteFactory.note("just body\n", [NoteFactory.run(10)])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "From Store")
        #expect(doc.title == "From Store")
    }

    @Test("Attachments land between the paragraphs they sit between")
    func attachmentPlacement() {
        // "Squats\n" + U+FFFC + "\nLunges\n"
        let text = "Squats\n\(objectReplacement)\nLunges\n"
        let note = NoteFactory.note(text, [
            NoteFactory.run(7),
            NoteFactory.run(1, attachment: (id: "vid-1", uti: "com.apple.quicktime-movie")),
            NoteFactory.run(1),
            NoteFactory.run(7),
        ])
        let attachments = ["vid-1": NoteFactory.attachment("vid-1", uti: "com.apple.quicktime-movie", filename: "a.mov")]

        let doc = NoteDocumentBuilder.build(note: note, attachments: attachments, fallbackTitle: "t")
        let kinds = doc.blocks.map { block -> String in
            switch block {
            case .paragraph(let spans): "p:\(spans.map(\.text).joined())"
            case .attachment(let id): "attachment:\(id)"
            default: "other"
            }
        }
        #expect(kinds == ["p:Squats", "attachment:vid-1", "p:Lunges"])
    }

    @Test("Unknown attachment identifiers are dropped rather than rendered broken")
    func unknownAttachmentDropped() {
        let note = NoteFactory.note("A\n\(objectReplacement)\n", [
            NoteFactory.run(2),
            NoteFactory.run(1, attachment: (id: "ghost", uti: "com.apple.notes.inlinetextattachment.hashtag")),
            NoteFactory.run(1),
        ])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "t")
        #expect(!doc.blocks.contains { if case .attachment = $0 { true } else { false } })
    }

    @Test("Run lengths are interpreted as UTF-16 code units")
    func utf16Lengths() {
        // The emoji is a surrogate pair: 2 UTF-16 units, 1 Character.
        let text = "🏋️‍♀️ lift\nnext\n"
        let firstParagraph = "🏋️‍♀️ lift\n"
        let note = NoteFactory.note(text, [
            NoteFactory.run(firstParagraph.utf16.count, style: 1),
            NoteFactory.run(5),
        ])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "t")

        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0] == .heading(level: 2, spans: [Span(text: "🏋️‍♀️ lift")]))
        #expect(doc.blocks[1] == .paragraph([Span(text: "next")]))
    }

    @Test("Inline formatting is carried onto spans and adjacent identical spans merge")
    func inlineFormatting() {
        let note = NoteFactory.note("boldbold plain\n", [
            NoteFactory.run(4, bold: true),
            NoteFactory.run(4, bold: true),
            NoteFactory.run(7),
        ])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "t")

        guard case .paragraph(let spans) = doc.blocks[0] else {
            Issue.record("expected a paragraph, got \(doc.blocks[0])")
            return
        }
        #expect(spans.count == 2)
        #expect(spans[0] == Span(text: "boldbold", style: .bold))
        #expect(spans[1].style.isEmpty)
    }

    @Test("Checklist state survives", arguments: [true, false])
    func checklistState(done: Bool) {
        let note = NoteFactory.note("task\n", [NoteFactory.run(5, style: 103, checked: done)])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "t")
        #expect(doc.blocks == [.listItem(kind: .checklist, indent: 0, checked: done, spans: [Span(text: "task")])])
    }

    @Test("Paragraph style maps to the right block", arguments: [
        (Int32(0), "title"), (1, "h2"), (2, "h3"), (4, "pre"), (100, "ul"), (101, "ul"), (102, "ol"),
    ])
    func styleMapping(style: Int32, expected: String) {
        let note = NoteFactory.note("x\n", [NoteFactory.run(2, style: style)])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "t")

        let actual = switch doc.blocks[0] {
        case .title: "title"
        case .heading(let level, _): "h\(level)"
        case .monospaced: "pre"
        case .listItem(let kind, _, _, _): kind == .numbered ? "ol" : "ul"
        case .paragraph: "p"
        case .attachment: "attachment"
        }
        #expect(actual == expected)
    }

    @Test("Trailing blank paragraphs are trimmed")
    func trailingBlanksTrimmed() {
        let note = NoteFactory.note("text\n\n\n\n", [
            NoteFactory.run(5),
            NoteFactory.run(1),
            NoteFactory.run(1),
            NoteFactory.run(1),
        ])
        let doc = NoteDocumentBuilder.build(note: note, attachments: [:], fallbackTitle: "t")
        #expect(doc.blocks == [.paragraph([Span(text: "text")])])
    }
}
