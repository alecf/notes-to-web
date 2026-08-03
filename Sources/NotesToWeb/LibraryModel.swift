import AppKit
import Foundation
import NotesToWebKit
import Observation

@MainActor
@Observable
final class LibraryModel {
    enum Access {
        case checking
        case needsFullDiskAccess
        case ready
        case failed(String)
    }

    enum ExportState: Equatable {
        case idle
        case running(fraction: Double, message: String)
        case finished(directory: URL, assetCount: Int, warnings: [String])
        case failed(String)
    }

    private(set) var access: Access = .checking
    private(set) var accounts: [NoteAccount] = []
    private(set) var folders: [NoteFolder] = []
    private(set) var notes: [NoteSummary] = []
    private(set) var document: NoteDocument?
    private(set) var documentError: String?

    var selectedFolder: NoteFolder? { didSet { reloadNotes() } }
    var selectedNote: NoteSummary? { didSet { reloadDocument() } }
    var searchText = "" { didSet { reloadNotes() } }

    var exportState: ExportState = .idle

    private var store: NotesStore?
    private let exporter = Exporter()

    init() {
        reload()
    }

    // MARK: Loading

    func reload() {
        access = .checking
        do {
            let store = try NotesStore()
            self.store = store
            accounts = try store.accounts()
            folders = try store.folders()
            access = .ready

            // Land the user somewhere useful instead of an empty pane.
            if selectedFolder == nil || !folders.contains(where: { $0.id == selectedFolder?.id }) {
                selectedFolder = folders.max(by: { $0.noteCount < $1.noteCount })
            } else {
                reloadNotes()
            }
        } catch NotesStoreError.fullDiskAccessRequired {
            access = .needsFullDiskAccess
        } catch {
            access = .failed(error.localizedDescription)
        }
    }

    func folders(in account: NoteAccount) -> [NoteFolder] {
        folders.filter { $0.accountID == account.id }
    }

    /// Accounts that actually have folders worth showing.
    var visibleAccounts: [NoteAccount] {
        accounts.filter { account in folders.contains { $0.accountID == account.id } }
    }

    private func reloadNotes() {
        guard let store, let folder = selectedFolder else {
            notes = []
            selectedNote = nil
            return
        }
        do {
            let all = try store.notes(inFolder: folder.id)
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            notes = query.isEmpty ? all : all.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.snippet.localizedCaseInsensitiveContains(query)
            }
        } catch {
            notes = []
        }
        if let selectedNote, !notes.contains(where: { $0.id == selectedNote.id }) {
            self.selectedNote = nil
        }
    }

    private func reloadDocument() {
        document = nil
        documentError = nil
        exportState = .idle
        guard let store, let note = selectedNote else { return }
        do {
            document = try store.loadDocument(for: note)
        } catch {
            documentError = error.localizedDescription
        }
    }

    // MARK: Export

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(NotesStoreLocation.fullDiskAccessSettingsURL)
    }

    func beginExport() {
        guard let document, let note = selectedNote else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose an empty folder for the exported website."
        panel.nameFieldStringValue = note.title.suggestedDirectoryName

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        run(export: document, to: destination)
    }

    private func run(export document: NoteDocument, to destination: URL) {
        exportState = .running(fraction: 0, message: "Preparing")
        Task {
            do {
                let result = try await exporter.export(document: document, to: destination) { progress in
                    Task { @MainActor in
                        self.exportState = .running(fraction: progress.fraction, message: progress.message)
                    }
                }
                exportState = .finished(
                    directory: result.directory,
                    assetCount: result.assetCount,
                    warnings: result.warnings
                )
            } catch {
                exportState = .failed(error.localizedDescription)
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension String {
    /// A tidy folder name derived from a note title.
    var suggestedDirectoryName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
        let words = cleaned.split(separator: " ").prefix(6)
        let name = words.joined(separator: "-").lowercased()
        return name.isEmpty ? "note" : name
    }
}
