import Foundation
import GRDB

public enum NotesStoreError: Error, LocalizedError {
    case fullDiskAccessRequired
    case databaseMissing(URL)
    case noteHasNoContent
    case notePasswordProtected

    public var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            "Notes to Web needs Full Disk Access to read your notes."
        case .databaseMissing(let url):
            "Could not find the Notes database at \(url.path(percentEncoded: false))."
        case .noteHasNoContent:
            "This note has no stored content yet. Open it in Notes once, then try again."
        case .notePasswordProtected:
            "This note is locked. Unlock it in Notes before exporting."
        }
    }
}

// MARK: - Browsing model

public struct NoteAccount: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let identifier: String
    public let name: String
}

public struct NoteFolder: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let accountID: Int64
    public let parentID: Int64?
    public let isTrash: Bool
    public let noteCount: Int
}

public struct NoteSummary: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let title: String
    public let snippet: String
    public let folderID: Int64
    public let accountIdentifier: String
    public let modified: Date
    public let attachmentCount: Int
    public let isPasswordProtected: Bool
}

/// Read-only access to Notes' Core Data store.
///
/// Notes.app keeps the database open with a write-ahead log that is routinely
/// hundreds of megabytes, so this snapshots the database and its sidecars to a
/// temporary directory and reads the copy. The user's data is never modified.
public final class NotesStore {
    private let queue: DatabaseQueue
    private let snapshotDirectory: URL

    public init() throws {
        let source = NotesStoreLocation.databaseURL
        guard NotesStoreLocation.hasFullDiskAccess else {
            // Distinguish "not allowed" from "not there" — they need different fixes.
            throw FileManager.default.fileExists(atPath: source.path(percentEncoded: false))
                ? NotesStoreError.fullDiskAccessRequired
                : NotesStoreError.databaseMissing(source)
        }

        snapshotDirectory = FileManager.default.temporaryDirectory
            .appending(path: "notes-to-web-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        // The -wal and -shm sidecars must come along or we read stale data.
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(filePath: source.path(percentEncoded: false) + suffix)
            guard FileManager.default.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try FileManager.default.copyItem(
                at: from,
                to: snapshotDirectory.appending(path: from.lastPathComponent, directoryHint: .notDirectory)
            )
        }

        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(
            path: snapshotDirectory.appending(path: source.lastPathComponent).path(percentEncoded: false),
            configuration: config
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }

    // MARK: Browsing

    public func accounts() throws -> [NoteAccount] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT Z_PK, ZIDENTIFIER, ZNAME
                FROM ZICCLOUDSYNCINGOBJECT
                WHERE Z_ENT = \(Entity.account) AND ZNAME IS NOT NULL
                ORDER BY ZACCOUNTNAMEFORACCOUNTLISTSORTING
                """)
            .map { NoteAccount(id: $0["Z_PK"], identifier: $0["ZIDENTIFIER"] ?? "", name: $0["ZNAME"] ?? "Account") }
        }
    }

    /// Folders, excluding Recently Deleted and any folder with no notes in it.
    public func folders() throws -> [NoteFolder] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.Z_PK, f.ZTITLE2, COALESCE(f.ZACCOUNT8, f.ZOWNER) AS accountID,
                       f.ZPARENT, f.ZIDENTIFIER, f.ZFOLDERTYPE,
                       (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                        WHERE n.Z_ENT = \(Entity.note) AND n.ZFOLDER = f.Z_PK
                          AND COALESCE(n.ZMARKEDFORDELETION, 0) = 0) AS noteCount
                FROM ZICCLOUDSYNCINGOBJECT f
                WHERE f.Z_ENT = \(Entity.folder) AND COALESCE(f.ZMARKEDFORDELETION, 0) = 0
                ORDER BY f.ZTITLE2 COLLATE NOCASE
                """)
            .compactMap { row -> NoteFolder? in
                guard let accountID: Int64 = row["accountID"] else { return nil }
                let identifier: String = row["ZIDENTIFIER"] ?? ""
                let isTrash = identifier.hasPrefix("TrashFolder") || (row["ZFOLDERTYPE"] as Int64? == 1)
                let count: Int = row["noteCount"] ?? 0
                guard !isTrash, count > 0 else { return nil }
                return NoteFolder(
                    id: row["Z_PK"],
                    name: row["ZTITLE2"] ?? "Untitled Folder",
                    accountID: accountID,
                    parentID: row["ZPARENT"],
                    isTrash: isTrash,
                    noteCount: count
                )
            }
        }
    }

    public func notes(inFolder folderID: Int64) throws -> [NoteSummary] {
        try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.Z_PK, n.ZTITLE1, n.ZSNIPPET, n.ZFOLDER, n.ZMODIFICATIONDATE1,
                       COALESCE(n.ZISPASSWORDPROTECTED, 0) AS locked,
                       a.ZIDENTIFIER AS accountIdentifier,
                       (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT t
                        WHERE t.Z_ENT = \(Entity.attachment) AND t.ZNOTE = n.Z_PK) AS attachmentCount
                FROM ZICCLOUDSYNCINGOBJECT n
                LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = n.ZACCOUNT7
                WHERE n.Z_ENT = \(Entity.note) AND n.ZFOLDER = ?
                  AND COALESCE(n.ZMARKEDFORDELETION, 0) = 0
                ORDER BY n.ZMODIFICATIONDATE1 DESC
                """, arguments: [folderID])
            .map { row in
                NoteSummary(
                    id: row["Z_PK"],
                    title: (row["ZTITLE1"] as String?)?.nilIfBlank ?? "Untitled Note",
                    snippet: row["ZSNIPPET"] ?? "",
                    folderID: row["ZFOLDER"] ?? folderID,
                    accountIdentifier: row["accountIdentifier"] ?? "",
                    modified: Date(timeIntervalSinceReferenceDate: row["ZMODIFICATIONDATE1"] ?? 0),
                    attachmentCount: row["attachmentCount"] ?? 0,
                    isPasswordProtected: (row["locked"] as Int64? ?? 0) != 0
                )
            }
        }
    }

    // MARK: Content

    /// The decompressed, decoded protobuf document for a note.
    public func document(forNote noteID: Int64) throws -> PBNote {
        let blob: Data? = try queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT d.ZDATA
                FROM ZICCLOUDSYNCINGOBJECT n
                JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA
                WHERE n.Z_PK = ?
                """, arguments: [noteID])?["ZDATA"]
        }
        guard let blob, !blob.isEmpty else { throw NotesStoreError.noteHasNoContent }
        let store = try PBNoteStoreProto(serializedBytes: Gzip.decompress(blob))
        return store.document.note
    }

    /// Every attachment belonging to a note, keyed by the identifier that appears
    /// in the document's attribute runs.
    public func attachments(forNote noteID: Int64) throws -> [String: StoredAttachment] {
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.ZIDENTIFIER AS attachmentID,
                       t.ZTYPEUTI     AS typeUTI,
                       t.ZFILESIZE    AS fileSize,
                       t.ZTITLE       AS title,
                       t.ZURLSTRING   AS urlString,
                       m.ZIDENTIFIER  AS mediaID,
                       m.ZFILENAME    AS filename,
                       a.ZIDENTIFIER  AS accountID
                FROM ZICCLOUDSYNCINGOBJECT t
                LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = t.ZMEDIA
                LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = t.ZACCOUNT1
                WHERE t.Z_ENT = \(Entity.attachment) AND t.ZNOTE = ?
                """, arguments: [noteID])
        }

        var result: [String: StoredAttachment] = [:]
        for row in rows {
            guard let id: String = row["attachmentID"] else { continue }
            let mediaID: String? = row["mediaID"]
            let accountID: String? = row["accountID"]
            let filename: String? = row["filename"]

            let fileURL: URL? = if let mediaID, let accountID {
                NotesStoreLocation.mediaFile(account: accountID, media: mediaID, filename: filename)
            } else {
                nil
            }

            result[id] = StoredAttachment(
                identifier: id,
                typeUTI: row["typeUTI"] ?? "",
                filename: filename,
                title: row["title"],
                urlString: row["urlString"],
                fileURL: fileURL,
                fileSize: row["fileSize"] ?? 0
            )
        }
        return result
    }

    private enum Entity {
        static let attachment = 5
        static let note = 12
        static let account = 14
        static let folder = 15
    }
}

/// An attachment as recorded in the store, with its backing file resolved if present.
public struct StoredAttachment: Hashable, Sendable {
    public let identifier: String
    public let typeUTI: String
    public let filename: String?
    public let title: String?
    public let urlString: String?
    /// `nil` when the file has not been downloaded from iCloud to this Mac.
    public let fileURL: URL?
    public let fileSize: Int64

    /// A stable, filesystem-safe name for the exported asset.
    public func exportName(fallbackIndex: Int) -> String {
        if let filename, !filename.isEmpty { return filename.sanitizedForFilesystem }
        let ext = UTIKind(typeUTI).preferredExtension ?? "bin"
        return "attachment-\(fallbackIndex).\(ext)"
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    var sanitizedForFilesystem: String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = components(separatedBy: bad).joined(separator: "-")
        return cleaned.isEmpty ? "attachment" : cleaned
    }
}
