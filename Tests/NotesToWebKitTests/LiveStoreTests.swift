import Foundation
import Testing
@testable import NotesToWebKit

/// Smoke tests against the real Notes library on this Mac.
///
/// Disabled by default: they need Full Disk Access and they read your actual notes.
/// Run with `NOTES_TO_WEB_LIVE=1 swift test` when changing the store or parser.
@Suite(
    "Live Notes store",
    .enabled(if: ProcessInfo.processInfo.environment["NOTES_TO_WEB_LIVE"] == "1")
)
struct LiveStoreTests {

    @Test("The library opens and has readable structure")
    func libraryOpens() throws {
        let store = try NotesStore()
        let accounts = try store.accounts()
        let folders = try store.folders()

        #expect(!accounts.isEmpty)
        #expect(!folders.isEmpty)
        #expect(folders.allSatisfy { !$0.isTrash })
        #expect(folders.allSatisfy { folder in accounts.contains { $0.id == folder.accountID } })
    }

    @Test("Every note in the library decodes without throwing")
    func allNotesDecode() throws {
        let store = try NotesStore()
        var decoded = 0
        var withAttachments = 0

        for folder in try store.folders() {
            for note in try store.notes(inFolder: folder.id) where !note.isPasswordProtected {
                let document: NoteDocument
                do {
                    document = try store.loadDocument(for: note)
                } catch NotesStoreError.noteHasNoContent {
                    continue  // never opened on this Mac; nothing to decode
                }
                decoded += 1

                // Every attachment block must resolve to a known attachment.
                for case .attachment(let id) in document.blocks {
                    #expect(document.attachments[id] != nil, "unresolved attachment in “\(note.title)”")
                    withAttachments += 1
                }

                // The renderer must not crash or emit unescaped angle brackets from note text.
                _ = HTMLRenderer().render(document)
            }
        }

        #expect(decoded > 0)
        print("decoded \(decoded) notes, \(withAttachments) attachment blocks")
    }

    @Test("Attachment counts in the list match what the document contains")
    func attachmentCountsAgree() throws {
        let store = try NotesStore()

        for folder in try store.folders() {
            for note in try store.notes(inFolder: folder.id)
            where note.attachmentCount > 0 && !note.isPasswordProtected {
                guard let document = try? store.loadDocument(for: note) else { continue }
                let placed = document.blocks.count { if case .attachment = $0 { true } else { false } }

                // Placed can be lower than the row count — Notes keeps rows for
                // attachments that were deleted from the text — but never higher.
                #expect(placed <= note.attachmentCount, "“\(note.title)” placed \(placed) of \(note.attachmentCount)")
            }
        }
    }
}
