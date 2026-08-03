import Foundation
import UniformTypeIdentifiers

/// How an attachment should be presented on the page.
public enum UTIKind: Sendable, Hashable {
    case video
    case image
    case audio
    case pdf
    case url
    case other

    public init(_ typeUTI: String) {
        if let type = UTType(typeUTI) {
            if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video; return }
            if type.conforms(to: .image) { self = .image; return }
            if type.conforms(to: .audio) { self = .audio; return }
            if type.conforms(to: .pdf) { self = .pdf; return }
            if type.conforms(to: .url) { self = .url; return }
        }
        // Notes uses private UTIs for some attachment kinds that UTType cannot resolve.
        self = switch typeUTI {
        case "com.apple.notes.gallery": .image
        case let t where t.hasPrefix("com.apple.notes.inlinetextattachment"): .other
        default: .other
        }
    }

    public var preferredExtension: String? {
        switch self {
        case .video: "mov"
        case .image: "jpg"
        case .audio: "m4a"
        case .pdf: "pdf"
        case .url, .other: nil
        }
    }
}

extension StoredAttachment {
    public var kind: UTIKind { UTIKind(typeUTI) }

    /// MIME type for the `<source>` / `<img>` tag.
    public var mimeType: String {
        if let type = UTType(typeUTI), let mime = type.preferredMIMEType { return mime }
        return switch kind {
        case .video: "video/quicktime"
        case .image: "image/jpeg"
        case .audio: "audio/mp4"
        case .pdf: "application/pdf"
        case .url, .other: "application/octet-stream"
        }
    }

    /// What to show a human when the file itself cannot be embedded.
    public var displayName: String {
        title ?? filename ?? urlString ?? "Attachment"
    }
}
