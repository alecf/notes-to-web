import Foundation

/// Where Notes keeps its data, and whether we are currently allowed to read it.
public enum NotesStoreLocation {
    /// Notes' group container. TCC-protected: reading it requires Full Disk Access.
    public static var groupContainer: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.apple.notes", directoryHint: .isDirectory)
    }

    public static var databaseURL: URL {
        groupContainer.appending(path: "NoteStore.sqlite", directoryHint: .notDirectory)
    }

    public static var accountsDirectory: URL {
        groupContainer.appending(path: "Accounts", directoryHint: .isDirectory)
    }

    /// Media for an attachment lives at `Accounts/<account>/Media/<media>/<generation>/<filename>`.
    ///
    /// The generation directory is not recorded in the columns we read, so this
    /// searches for it rather than assuming a layout.
    public static func mediaFile(
        account: String,
        media: String,
        filename: String?
    ) -> URL? {
        let dir = accountsDirectory
            .appending(path: account, directoryHint: .isDirectory)
            .appending(path: "Media", directoryHint: .isDirectory)
            .appending(path: media, directoryHint: .isDirectory)

        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { return nil }

        // Preferred: the recorded filename, directly in the media directory or one
        // generation level down.
        if let filename {
            let direct = dir.appending(path: filename, directoryHint: .notDirectory)
            if fm.fileExists(atPath: direct.path(percentEncoded: false)) { return direct }

            if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
                for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let nested = child.appending(path: filename, directoryHint: .notDirectory)
                    if fm.fileExists(atPath: nested.path(percentEncoded: false)) { return nested }
                }
            }
        }

        // Fallback: the single regular file somewhere under the media directory.
        // Notes occasionally stores a file whose name differs from ZFILENAME.
        guard let walker = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return url
            }
        }
        return nil
    }

    /// Whether this process can actually read the Notes database.
    ///
    /// Checked by opening the file rather than by `fileExists`, because TCC lets
    /// `stat` succeed while denying `open`.
    public static var hasFullDiskAccess: Bool {
        guard let handle = try? FileHandle(forReadingFrom: databaseURL) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) != nil
    }

    /// Deep link to the Full Disk Access pane of System Settings.
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}
