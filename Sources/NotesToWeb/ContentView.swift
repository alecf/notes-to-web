import NotesToWebKit
import SwiftUI

struct ContentView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        switch library.access {
        case .checking:
            ProgressView().controlSize(.large)
        case .needsFullDiskAccess:
            PermissionGate(library: library)
        case .failed(let message):
            FailureView(message: message) { library.reload() }
        case .ready:
            browser
        }
    }

    private var browser: some View {
        NavigationSplitView {
            FolderSidebar(library: library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            NoteList(library: library)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            NoteDetail(library: library)
        }
        .navigationTitle(library.selectedNote?.title ?? "Notes to Web")
        .sheet(isPresented: exportSheetBinding) {
            ExportSheet(library: library)
        }
    }

    private var exportSheetBinding: Binding<Bool> {
        Binding(
            get: { library.exportState != .idle },
            set: { if !$0 { library.exportState = .idle } }
        )
    }
}

// MARK: - Sidebar

struct FolderSidebar: View {
    @Bindable var library: LibraryModel

    var body: some View {
        List(selection: $library.selectedFolder) {
            ForEach(library.visibleAccounts) { account in
                Section(account.name) {
                    ForEach(library.folders(in: account)) { folder in
                        Label {
                            HStack {
                                Text(folder.name)
                                Spacer()
                                Text("\(folder.noteCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .tag(folder)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Note list

struct NoteList: View {
    @Bindable var library: LibraryModel

    var body: some View {
        List(library.notes, selection: $library.selectedNote) { note in
            NoteRow(note: note).tag(note)
        }
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "Search notes")
        .overlay {
            if library.notes.isEmpty {
                ContentUnavailableView(
                    library.searchText.isEmpty ? "No Notes" : "No Matches",
                    systemImage: library.searchText.isEmpty ? "note.text" : "magnifyingglass",
                    description: Text(library.searchText.isEmpty
                        ? "This folder is empty."
                        : "No note in this folder matches “\(library.searchText)”.")
                )
            }
        }
    }
}

struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.isPasswordProtected {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
                }
                Text(note.title).font(.headline).lineLimit(1)
            }
            if !note.snippet.isEmpty {
                Text(note.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(note.modified, format: .dateTime.year().month(.abbreviated).day())
                if note.attachmentCount > 0 {
                    Label("\(note.attachmentCount)", systemImage: "paperclip")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct NoteDetail: View {
    @Bindable var library: LibraryModel

    var body: some View {
        Group {
            if let error = library.documentError {
                ContentUnavailableView("Can't Preview This Note", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let document = library.document {
                PreviewWebView(document: document)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView(
                    "Choose a Note",
                    systemImage: "sidebar.right",
                    description: Text("Pick a note to see exactly how it will look on the web.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.beginExport()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(library.document == nil)
                .help("Write index.html and assets to a folder you can publish")
            }
        }
    }
}

// MARK: - Gates

struct PermissionGate: View {
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Notes to Web needs Full Disk Access")
                .font(.title2.weight(.semibold))

            Text("""
                Apple protects the folder where Notes stores your notes. Notes' scripting \
                interface can't be used instead — it silently drops embedded videos, which \
                is exactly what this app is for.

                Notes to Web only ever reads that folder, from a temporary copy. It never \
                changes your notes.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                stepRow(1, "Open Privacy & Security → Full Disk Access")
                stepRow(2, "Turn on Notes to Web (use + to add it if it isn't listed)")
                stepRow(3, "Come back and click Try Again")
            }
            .font(.callout)
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button("Open System Settings") { library.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { library.reload() }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(.tint, in: .circle)
            Text(text)
        }
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't Read Your Notes", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
