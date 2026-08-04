import Foundation
import NotesToWebKit

/// Where a note can be published. Configured once in Settings; chosen per note
/// at export time.
enum DestinationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case disk
    case cloudflare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disk: "A folder on this Mac"
        case .cloudflare: "Cloudflare"
        }
    }

    var symbol: String {
        switch self {
        case .disk: "folder"
        case .cloudflare: "cloud"
        }
    }

    /// The provider backing this destination, if it publishes over a network.
    var provider: ProviderDescriptor? {
        switch self {
        case .disk: nil
        case .cloudflare: ProviderRegistry.provider(id: CloudflarePublisher.providerID)
        }
    }
}

/// Where one note went last time, so re-exporting it is a single confirmation.
///
/// Each field belongs to the destination that uses it: a note can have both a
/// remembered folder and a remembered Cloudflare site, and switching between
/// them does not lose either.
struct NoteTarget: Codable, Equatable, Sendable {
    var kind: DestinationKind = .disk
    /// Disk: the folder this note was written to.
    var folderPath: String?
    /// Cloudflare: which site, and which path within it.
    var site: String?
    var path: String?

    var folderURL: URL? {
        folderPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// A one-line description of where "Export" will put this note.
    func summary(fallbackPath: String) -> String {
        switch kind {
        case .disk:
            return folderURL.map { $0.path(percentEncoded: false) } ?? "Choose a folder…"
        case .cloudflare:
            guard let site, !site.isEmpty else { return "Choose a site…" }
            return "\(site) › /\(path ?? fallbackPath)/"
        }
    }
}

/// Remembers each note's last publishing location.
///
/// Keyed by Notes' own identifier rather than by title, so renaming a note does
/// not strand its history and re-exporting still lands in the same place.
@MainActor
final class NoteTargetStore {
    private var targets: [String: NoteTarget]
    private let fileURL: URL

    init(fileURL: URL = NoteTargetStore.defaultURL) {
        self.fileURL = fileURL
        targets = (try? JSONDecoder().decode(
            [String: NoteTarget].self, from: Data(contentsOf: fileURL)
        )) ?? [:]
    }

    static var defaultURL: URL {
        AppStorageLocation.support.appending(path: "targets.json", directoryHint: .notDirectory)
    }

    subscript(noteID: String) -> NoteTarget? {
        get { targets[noteID] }
        set {
            targets[noteID] = newValue
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(targets).write(to: fileURL)
    }
}

/// Folders the app owns, as opposed to folders the user picks.
enum AppStorageLocation {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appending(path: "com.alecf.notes-to-web", directoryHint: .isDirectory)
    }

    /// Staging for Cloudflare sites.
    ///
    /// A Workers deployment replaces the script's entire asset set, so every
    /// note that shares a site has to be uploaded together. Keeping a copy of
    /// each site here means publishing one note does not wipe its siblings —
    /// and the user never has to know that, or nominate a folder for it.
    static func stagedSite(_ name: String) -> URL {
        support
            .appending(path: "sites", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }
}
