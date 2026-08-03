import Foundation

// MARK: - Semantic document

public struct InlineStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let underline = InlineStyle(rawValue: 1 << 2)
    public static let strikethrough = InlineStyle(rawValue: 1 << 3)
    public static let monospaced = InlineStyle(rawValue: 1 << 4)
}

public struct Span: Sendable, Hashable {
    public var text: String
    public var style: InlineStyle
    public var link: String?

    public init(text: String, style: InlineStyle = [], link: String? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

public enum ListKind: Sendable, Hashable {
    case bulleted
    case dashed
    case numbered
    case checklist
}

public enum Block: Sendable, Hashable {
    case title([Span])
    case heading(level: Int, spans: [Span])
    case paragraph([Span])
    case monospaced([Span])
    case listItem(kind: ListKind, indent: Int, checked: Bool?, spans: [Span])
    case attachment(identifier: String)
}

public struct NoteDocument: Sendable {
    public var title: String
    public var blocks: [Block]
    public var attachments: [String: StoredAttachment]

    public init(title: String, blocks: [Block], attachments: [String: StoredAttachment]) {
        self.title = title
        self.blocks = blocks
        self.attachments = attachments
    }
}

// MARK: - Decoding

/// Notes marks an attachment's position in the note text with this character.
let objectReplacementCharacter: UInt16 = 0xFFFC

public enum NoteDocumentBuilder {
    /// Style values used by `ParagraphStyle.style_type`.
    private enum StyleType {
        static let title: Int32 = 0
        static let heading: Int32 = 1
        static let subheading: Int32 = 2
        static let monospaced: Int32 = 4
        static let dottedList: Int32 = 100
        static let dashedList: Int32 = 101
        static let numberedList: Int32 = 102
        static let checkbox: Int32 = 103
    }

    public static func build(
        note: PBNote,
        attachments: [String: StoredAttachment],
        fallbackTitle: String
    ) -> NoteDocument {
        // Run lengths are UTF-16 code units, so the text must be sliced that way.
        // Doing this with Characters corrupts any note containing emoji.
        let units = Array(note.noteText.utf16)

        var blocks: [Block] = []
        var pending: [Span] = []
        var pendingStyle: PBParagraphStyle?
        var offset = 0

        func flushParagraph() {
            defer { pending = []; pendingStyle = nil }
            let spans = pending.filter { !$0.text.isEmpty }
            // Blank lines are how notes are spaced, not content. Dropping them keeps
            // the output free of empty <p> elements; the stylesheet handles rhythm.
            guard !spans.isEmpty else { return }
            blocks.append(block(for: pendingStyle, spans: spans))
        }

        for run in note.attributeRun {
            let length = Int(run.length)
            guard length > 0, offset < units.count else { offset += max(0, length); continue }
            let end = min(offset + length, units.count)
            let slice = Array(units[offset..<end])
            offset = end

            let runStyle: PBParagraphStyle? = run.hasParagraphStyle ? run.paragraphStyle : nil

            // An attachment run is a single U+FFFC. Break the paragraph around it so
            // videos and images sit at block level where they belong.
            if run.hasAttachmentInfo, !run.attachmentInfo.attachmentIdentifier.isEmpty {
                let id = run.attachmentInfo.attachmentIdentifier
                if attachments[id] != nil {
                    flushParagraph()
                    blocks.append(.attachment(identifier: id))
                }
                continue
            }

            let style = inlineStyle(for: run)
            let link = run.hasLink && !run.link.isEmpty ? run.link : nil

            // Newlines terminate paragraphs; the newline belongs to the paragraph it
            // closes, so this run's style applies to that paragraph. The style must
            // not leak past the flush — a run that ends exactly on a newline says
            // nothing about the paragraph that follows it.
            var segmentStart = 0
            for (i, unit) in slice.enumerated() where unit == 0x000A {
                pendingStyle = runStyle ?? pendingStyle
                append(String(utf16CodeUnits: Array(slice[segmentStart..<i]), count: i - segmentStart),
                       style: style, link: link, into: &pending)
                flushParagraph()
                segmentStart = i + 1
            }
            if segmentStart < slice.count {
                pendingStyle = runStyle ?? pendingStyle
                let tail = Array(slice[segmentStart...])
                append(String(utf16CodeUnits: tail, count: tail.count),
                       style: style, link: link, into: &pending)
            }
        }
        flushParagraph()

        let title = extractedTitle(from: blocks) ?? fallbackTitle
        return NoteDocument(title: title, blocks: blocks, attachments: attachments)
    }

    private static func append(_ text: String, style: InlineStyle, link: String?, into spans: inout [Span]) {
        guard !text.isEmpty else { return }
        // Merge with the previous span when the formatting is identical, so the
        // output has one <strong> instead of six adjacent ones.
        if var last = spans.last, last.style == style, last.link == link {
            last.text += text
            spans[spans.count - 1] = last
        } else {
            spans.append(Span(text: text, style: style, link: link))
        }
    }

    private static func inlineStyle(for run: PBAttributeRun) -> InlineStyle {
        var style: InlineStyle = []
        // Bold/italic arrive as either a top-level weight or font hints.
        let hints = (run.hasFont && run.font.hasFontHints) ? run.font.fontHints : 0
        let weight = run.hasFontWeight ? run.fontWeight : 0
        if weight & 1 != 0 || hints & 1 != 0 { style.insert(.bold) }
        if weight & 2 != 0 || hints & 2 != 0 { style.insert(.italic) }
        if run.hasUnderlined, run.underlined != 0 { style.insert(.underline) }
        if run.hasStrikethrough, run.strikethrough != 0 { style.insert(.strikethrough) }
        if run.hasFont, isMonospaced(run.font.fontName) { style.insert(.monospaced) }
        return style
    }

    private static func isMonospaced(_ fontName: String) -> Bool {
        let lowered = fontName.lowercased()
        return ["menlo", "courier", "mono"].contains { lowered.contains($0) }
    }

    private static func block(for style: PBParagraphStyle?, spans: [Span]) -> Block {
        guard let style, style.hasStyleType else { return .paragraph(spans) }
        let indent = style.hasIndentAmount ? Int(style.indentAmount) : 0

        switch style.styleType {
        case StyleType.title:
            return .title(spans)
        case StyleType.heading:
            return .heading(level: 2, spans: spans)
        case StyleType.subheading:
            return .heading(level: 3, spans: spans)
        case StyleType.monospaced:
            return .monospaced(spans)
        case StyleType.dottedList:
            return .listItem(kind: .bulleted, indent: indent, checked: nil, spans: spans)
        case StyleType.dashedList:
            return .listItem(kind: .dashed, indent: indent, checked: nil, spans: spans)
        case StyleType.numberedList:
            return .listItem(kind: .numbered, indent: indent, checked: nil, spans: spans)
        case StyleType.checkbox:
            let done = style.hasChecklist && style.checklist.hasDone && style.checklist.done != 0
            return .listItem(kind: .checklist, indent: indent, checked: done, spans: spans)
        default:
            // Notes may also mark a checklist purely by attaching a checklist object.
            if style.hasChecklist {
                let done = style.checklist.hasDone && style.checklist.done != 0
                return .listItem(kind: .checklist, indent: indent, checked: done, spans: spans)
            }
            return .paragraph(spans)
        }
    }

    private static func extractedTitle(from blocks: [Block]) -> String? {
        for block in blocks {
            if case .title(let spans) = block {
                let text = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}
