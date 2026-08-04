import Foundation

/// The landing page listing every note published to a site root, so
/// `alecs-notes.example.com/` is something other than a 404.
public struct IndexPage: Sendable {
    public var siteTitle: String
    public var entries: [SiteEntry]

    public init(siteTitle: String, entries: [SiteEntry]) {
        self.siteTitle = siteTitle
        self.entries = entries
    }

    public func render() -> String {
        let sorted = entries.sorted { $0.updatedAt > $1.updatedAt }
        let items = sorted.map { entry in
            """
            <li class="entry">
            <a href="\(entry.slug.htmlEscaped)/">\(entry.title.htmlEscaped)</a>
            <span class="meta">\(Self.dateFormatter.string(from: entry.updatedAt)) · \(entry.summary.htmlEscaped)</span>
            </li>
            """
        }.joined(separator: "\n")

        let body = sorted.isEmpty
            ? "<p class=\"empty\">Nothing published here yet.</p>"
            : "<ul class=\"entries\">\n\(items)\n</ul>"

        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(siteTitle.htmlEscaped)</title>
            <link rel="stylesheet" href="assets/style.css">
            </head>
            <body>
            <main class="note index">
            <h1>\(siteTitle.htmlEscaped)</h1>
            \(body)
            </main>
            </body>
            </html>

            """
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

extension String {
    /// Escapes the five characters that can break out of HTML text or an
    /// attribute value.
    var htmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for character in self {
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

    /// A tidy, URL-safe directory name derived from a note title.
    ///
    /// Deliberately ASCII: this becomes both a path segment and a directory
    /// name, and "café" surviving as `caf%C3%A9` helps nobody.
    public var slugified: String {
        let folded = folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 -_")
        let cleaned = folded.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
        let words = cleaned.split(separator: " ").prefix(6)
        let name = words.joined(separator: "-")
        return name.isEmpty ? "note" : name
    }
}
