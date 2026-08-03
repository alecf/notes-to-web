import Foundation

public extension NotesStore {
    /// Load a note and decode it into a renderable document.
    func loadDocument(for note: NoteSummary) throws -> NoteDocument {
        guard !note.isPasswordProtected else { throw NotesStoreError.notePasswordProtected }
        return NoteDocumentBuilder.build(
            note: try document(forNote: note.id),
            attachments: try attachments(forNote: note.id),
            fallbackTitle: note.title
        )
    }
}
