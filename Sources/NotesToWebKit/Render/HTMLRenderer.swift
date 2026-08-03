import Foundation

/// Where an attachment's files ended up, so the renderer can point at them.
public struct RenderedAsset: Sendable, Hashable {
    public let mediaPath: String?
    public let posterPath: String?
    public let mimeType: String
    public let displayName: String
    public let byteCount: Int64

    public init(mediaPath: String?, posterPath: String?, mimeType: String, displayName: String, byteCount: Int64) {
        self.mediaPath = mediaPath
        self.posterPath = posterPath
        self.mimeType = mimeType
        self.displayName = displayName
        self.byteCount = byteCount
    }
}

public struct HTMLRenderer: Sendable {
    /// Asset locations keyed by attachment identifier. Empty when previewing before
    /// export, in which case attachments render as labelled placeholders.
    public var assets: [String: RenderedAsset]
    public var stylesheetHref: String?
    public var inlineStylesheet: String?

    public init(
        assets: [String: RenderedAsset] = [:],
        stylesheetHref: String? = "assets/style.css",
        inlineStylesheet: String? = nil
    ) {
        self.assets = assets
        self.stylesheetHref = stylesheetHref
        self.inlineStylesheet = inlineStylesheet
    }

    public func render(_ document: NoteDocument) -> String {
        var head = """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(document.title))</title>
            """
        if let inlineStylesheet {
            head += "\n<style>\n\(inlineStylesheet)\n</style>"
        } else if let stylesheetHref {
            head += "\n<link rel=\"stylesheet\" href=\"\(escape(stylesheetHref))\">"
        }

        return """
            \(head)
            </head>
            <body>
            <main class="note">
            \(renderBlocks(document))
            </main>
            </body>
            </html>

            """
    }

    /// Just the note body, for embedding in a preview.
    public func renderBlocks(_ document: NoteDocument) -> String {
        var out: [String] = []
        var index = 0
        let blocks = document.blocks

        while index < blocks.count {
            // Consecutive list items of the same kind become one list.
            if case .listItem(let kind, _, _, _) = blocks[index] {
                var items: [Block] = []
                while index < blocks.count, case .listItem(let k, _, _, _) = blocks[index], k == kind {
                    items.append(blocks[index])
                    index += 1
                }
                out.append(renderList(kind: kind, items: items))
                continue
            }
            out.append(render(block: blocks[index], in: document))
            index += 1
        }
        return out.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Blocks

    private func render(block: Block, in document: NoteDocument) -> String {
        switch block {
        case .title(let spans):
            "<h1>\(render(spans))</h1>"
        case .heading(let level, let spans):
            "<h\(level)>\(render(spans))</h\(level)>"
        case .paragraph(let spans):
            spans.isEmpty ? "" : "<p>\(render(spans))</p>"
        case .monospaced(let spans):
            "<pre><code>\(render(spans))</code></pre>"
        case .listItem(let kind, _, let checked, let spans):
            renderList(kind: kind, items: [.listItem(kind: kind, indent: 0, checked: checked, spans: spans)])
        case .attachment(let identifier):
            render(attachment: identifier, in: document)
        }
    }

    private func renderList(kind: ListKind, items: [Block]) -> String {
        let tag = kind == .numbered ? "ol" : "ul"
        let classAttr = switch kind {
        case .bulleted: ""
        case .dashed: " class=\"dashed\""
        case .numbered: ""
        case .checklist: " class=\"checklist\""
        }

        let rendered = items.map { item -> String in
            guard case .listItem(_, let indent, let checked, let spans) = item else { return "" }
            let indentAttr = indent > 0 ? " style=\"--indent:\(indent)\"" : ""
            if kind == .checklist {
                let isChecked = checked == true
                let box = "<input type=\"checkbox\" disabled\(isChecked ? " checked" : "")>"
                let doneClass = isChecked ? " class=\"done\"" : ""
                return "<li\(doneClass)\(indentAttr)>\(box)<span>\(render(spans))</span></li>"
            }
            return "<li\(indentAttr)>\(render(spans))</li>"
        }.joined(separator: "\n")

        return "<\(tag)\(classAttr)>\n\(rendered)\n</\(tag)>"
    }

    private func render(attachment identifier: String, in document: NoteDocument) -> String {
        guard let stored = document.attachments[identifier] else { return "" }
        guard let asset = assets[identifier] else {
            // Preview before export: show what will be embedded.
            return """
                <figure class="attachment placeholder" data-kind="\(escape(String(describing: stored.kind)))">\
                <span>\(escape(stored.displayName))</span></figure>
                """
        }

        guard let mediaPath = asset.mediaPath else {
            return """
                <figure class="attachment missing"><span>\(escape(asset.displayName))\
                 — not downloaded to this Mac</span></figure>
                """
        }

        switch stored.kind {
        case .video:
            let poster = asset.posterPath.map { " poster=\"\(escape($0))\"" } ?? ""
            return """
                <figure class="attachment video">
                <video controls preload="metadata" playsinline\(poster)>
                <source src="\(escape(mediaPath))" type="\(escape(asset.mimeType))">
                <a href="\(escape(mediaPath))">Download \(escape(asset.displayName))</a>
                </video>
                </figure>
                """
        case .image:
            return """
                <figure class="attachment image">\
                <img src="\(escape(mediaPath))" alt="\(escape(asset.displayName))" loading="lazy">\
                </figure>
                """
        case .audio:
            return """
                <figure class="attachment audio">\
                <audio controls preload="metadata" src="\(escape(mediaPath))"></audio></figure>
                """
        case .pdf, .other:
            return """
                <figure class="attachment file">\
                <a href="\(escape(mediaPath))" download>\(escape(asset.displayName))\
                <small>\(byteSize(asset.byteCount))</small></a></figure>
                """
        case .url:
            let href = stored.urlString ?? mediaPath
            return """
                <figure class="attachment link">\
                <a href="\(escape(href))">\(escape(asset.displayName))</a></figure>
                """
        }
    }

    // MARK: Inline

    private func render(_ spans: [Span]) -> String {
        spans.map { span in
            var html = escape(span.text)
            if span.style.contains(.monospaced) { html = "<code>\(html)</code>" }
            if span.style.contains(.bold) { html = "<strong>\(html)</strong>" }
            if span.style.contains(.italic) { html = "<em>\(html)</em>" }
            if span.style.contains(.underline) { html = "<u>\(html)</u>" }
            if span.style.contains(.strikethrough) { html = "<s>\(html)</s>" }
            if let link = span.link, let safe = safeHref(link) {
                html = "<a href=\"\(escape(safe))\" rel=\"noopener noreferrer\">\(html)</a>"
            }
            return html
        }.joined()
    }

    /// Drop `javascript:` and similar, so a link pasted into a note cannot become
    /// script on the published page.
    private func safeHref(_ raw: String) -> String? {
        guard let scheme = URL(string: raw)?.scheme?.lowercased() else {
            return raw.hasPrefix("/") || raw.hasPrefix("#") ? raw : nil
        }
        return ["http", "https", "mailto", "tel"].contains(scheme) ? raw : nil
    }

    private func byteSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
