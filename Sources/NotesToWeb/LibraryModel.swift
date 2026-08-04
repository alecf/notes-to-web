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

    /// Where an export lands. `site` keeps every note under one folder so they
    /// publish as sibling paths on one domain; `folder` is the one-off case.
    enum Destination: Hashable {
        case folder
        case site
    }

    enum ExportState: Equatable {
        case idle
        /// Sheet is open, showing options and a size estimate.
        case configuring
        case running(fraction: Double, message: String, detail: String?)
        case finished(ExportSummary)
        case publishing(fraction: Double, message: String)
        case published(url: URL, summary: ExportSummary)
        case failed(String)
    }

    struct ExportSummary: Equatable {
        let directory: URL
        let assetCount: Int
        let sourceBytes: Int64
        let exportedBytes: Int64
        let largestFileBytes: Int64
        let warnings: [String]
        /// Set when the note went into the site root, giving it a published path.
        let slug: String?
    }

    /// Computed before the user commits, by reading each video's metadata. Real
    /// numbers, not a guess — planning is cheap because it never decodes a frame.
    struct ExportEstimate: Equatable {
        let videoCount: Int
        let sourceBytes: Int64
        let estimatedBytes: Int64
        /// Videos that will still exceed the destination's per-file limit.
        let oversized: [String]
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
    var destination: Destination = .site
    private(set) var estimate: ExportEstimate?
    private(set) var isEstimating = false

    let preferences: Preferences

    var credentialInput = ""
    private(set) var connectionStatus: ConnectionStatus?
    private(set) var isTestingConnection = false

    private var store: NotesStore?
    private let exporter = Exporter()
    private let transcoder = VideoTranscoder()
    private let credentials = CredentialStore()
    private var work: Task<Void, Never>?
    private var storedCredential: String?
    private var lastSummary: ExportSummary?

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        if preferences.siteRoot == nil { destination = .folder }
        reload()
        loadStoredCredential()
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

    /// Opens the options sheet and starts costing the export in the background.
    func beginExport() {
        guard document != nil else { return }
        if preferences.siteRoot == nil { destination = .folder }
        exportState = .configuring
        refreshEstimate()
    }

    /// Per-file ceiling for this export, taken from whichever provider is
    /// selected rather than assumed. Leaves headroom under the hard limit for
    /// container overhead the bitrate maths cannot predict exactly.
    var sizeBudget: Int64? {
        guard preferences.enforceSizeBudget else { return nil }
        guard let limit = provider?.capabilities.maxFileSize else {
            return VideoEncodeSettings.defaultSizeBudget
        }
        return min(VideoEncodeSettings.defaultSizeBudget, Int64(Double(limit) * 0.88))
    }

    var sizeBudgetLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBudget ?? VideoEncodeSettings.defaultSizeBudget,
                                  countStyle: .file)
    }

    var exportOptions: ExportOptions {
        guard preferences.compressVideo else { return ExportOptions(video: .original) }
        return ExportOptions(video: .webOptimized(VideoEncodeSettings(
            quality: preferences.quality,
            codec: preferences.codec,
            sizeBudget: sizeBudget
        )))
    }

    var isBusy: Bool {
        switch exportState {
        case .running, .publishing: true
        default: false
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        exportState = .idle
    }

    /// Re-costs the export. Called when the sheet opens and whenever a video
    /// setting changes, so the numbers on screen always match the controls.
    func refreshEstimate() {
        guard let document else { return }
        work?.cancel()

        let videos = document.blocks.compactMap { block -> StoredAttachment? in
            guard case .attachment(let id) = block,
                  let stored = document.attachments[id], stored.kind == .video
            else { return nil }
            return stored
        }

        guard case .webOptimized(let settings) = exportOptions.video, !videos.isEmpty else {
            let bytes = videos.reduce(Int64(0)) { $0 + $1.fileSize }
            estimate = ExportEstimate(
                videoCount: videos.count,
                sourceBytes: bytes,
                estimatedBytes: bytes,
                oversized: []
            )
            return
        }

        isEstimating = true
        let limit = sizeBudget ?? .max
        work = Task {
            var source: Int64 = 0
            var estimated: Int64 = 0
            var oversized: [String] = []

            for video in videos {
                if Task.isCancelled { return }
                source += video.fileSize
                guard let url = video.fileURL,
                      let plan = try? await transcoder.plan(for: url, settings: settings)
                else {
                    estimated += video.fileSize
                    continue
                }
                estimated += plan.passesThrough ? plan.sourceByteCount : plan.estimatedByteCount
                if plan.exceedsBudget || plan.estimatedByteCount > limit {
                    oversized.append(video.displayName)
                }
            }

            if Task.isCancelled { return }
            estimate = ExportEstimate(
                videoCount: videos.count,
                sourceBytes: source,
                estimatedBytes: estimated,
                oversized: oversized
            )
            isEstimating = false
        }
    }

    /// Commits the export the sheet is configured for.
    func confirmExport() {
        guard let document, let note = selectedNote else { return }
        work?.cancel()

        switch destination {
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose an empty folder for the exported website."
            panel.nameFieldStringValue = note.title.slugified

            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportState = .running(fraction: 0, message: "Preparing", detail: nil)
            work = Task {
                await run(document, to: url, options: exportOptions, slug: nil, site: nil)
            }

        case .site:
            guard let root = preferences.siteRoot else {
                exportState = .failed("No site folder is set. Choose one in Settings, or export to a folder instead.")
                return
            }
            var options = exportOptions
            options.overwriteDestination = true

            let library = SiteLibrary(root: root)
            let title = note.title
            // Scoped by account so a row ID from one account can't collide with
            // another's, and so the slug survives re-reading the store.
            let identifier = "\(note.accountIdentifier)/\(note.id)"

            exportState = .running(fraction: 0, message: "Preparing", detail: nil)
            work = Task {
                do {
                    try await library.prepare()
                    let slug = try await library.slug(forTitle: title, noteIdentifier: identifier)
                    try await library.clearDirectory(for: slug)
                    await run(
                        document,
                        to: library.directory(for: slug),
                        options: options,
                        slug: slug,
                        site: (library, title, identifier)
                    )
                } catch {
                    exportState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func run(
        _ document: NoteDocument,
        to url: URL,
        options: ExportOptions,
        slug: String?,
        site: (library: SiteLibrary, title: String, identifier: String)?
    ) async {
        do {
            let result = try await exporter.export(document: document, to: url, options: options) { progress in
                Task { @MainActor in
                    guard case .running = self.exportState else { return }
                    self.exportState = .running(
                        fraction: progress.fraction,
                        message: progress.message,
                        detail: progress.detail
                    )
                }
            }

            if let site, let slug {
                try await site.library.record(SiteEntry(
                    slug: slug,
                    title: site.title,
                    noteIdentifier: site.identifier,
                    updatedAt: .now,
                    byteCount: result.exportedByteCount,
                    assetCount: result.assetCount
                ))
            }

            let summary = ExportSummary(
                directory: result.directory,
                assetCount: result.assetCount,
                sourceBytes: result.sourceByteCount,
                exportedBytes: result.exportedByteCount,
                largestFileBytes: result.largestFileByteCount,
                warnings: result.warnings,
                slug: slug
            )
            lastSummary = summary
            exportState = .finished(summary)
        } catch is CancellationError {
            exportState = .idle
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Publishing

    struct ConnectionStatus: Equatable {
        let message: String
        let isGood: Bool
    }

    /// The provider configured to publish to, if any.
    var provider: ProviderDescriptor? { ProviderRegistry.provider(id: preferences.providerID) }

    var canPublish: Bool {
        provider != nil && preferences.siteRoot != nil && storedCredential?.isEmpty == false
    }

    func selectProvider(id: String?) {
        preferences.providerID = id
        connectionStatus = nil
        loadStoredCredential()
    }

    func loadStoredCredential() {
        guard let provider else { credentialInput = ""; return }
        storedCredential = try? credentials.read(provider: provider.id)
        // Show that something is stored without ever putting the secret back on
        // screen, where it could be read over a shoulder or captured in a screenshot.
        credentialInput = storedCredential == nil ? "" : String(repeating: "•", count: 24)
    }

    func saveAndTestCredentials() {
        guard let provider, !credentialInput.isEmpty else { return }
        let secret = credentialInput.allSatisfy { $0 == "•" }
            ? storedCredential
            : credentialInput
        guard let secret, !secret.isEmpty else { return }

        isTestingConnection = true
        connectionStatus = nil
        Task {
            defer { isTestingConnection = false }
            guard let publisher = provider.makePublisher(preferences, secret) else {
                connectionStatus = ConnectionStatus(
                    message: "Fill in every field above first.",
                    isGood: false
                )
                return
            }
            do {
                let label = try await publisher.validateCredentials()
                try credentials.write(secret, provider: provider.id)
                storedCredential = secret
                credentialInput = String(repeating: "•", count: 24)
                connectionStatus = ConnectionStatus(message: "Connected to \(label).", isGood: true)
            } catch {
                connectionStatus = ConnectionStatus(message: error.localizedDescription, isGood: false)
            }
        }
    }

    /// Uploads the whole site folder. Unchanged files are skipped by the
    /// provider's content hashing, so republishing one note is cheap.
    func publish() {
        guard let provider, let root = preferences.siteRoot else { return }
        guard let secret = storedCredential ?? (try? credentials.read(provider: provider.id)) ?? nil,
              let publisher = provider.makePublisher(preferences, secret)
        else {
            exportState = .failed("Connect a \(provider.displayName) account in Settings first.")
            return
        }

        let summary = lastSummary
        exportState = .publishing(fraction: 0, message: "Preparing upload")
        work = Task {
            do {
                let result = try await publisher.publish(siteRoot: root) { progress in
                    Task { @MainActor in
                        guard case .publishing = self.exportState else { return }
                        self.exportState = .publishing(
                            fraction: progress.fraction,
                            message: progress.message
                        )
                    }
                }
                let url = summary?.slug.map { result.url.appending(path: $0, directoryHint: .isDirectory) }
                    ?? result.url
                if let summary {
                    exportState = .published(url: url, summary: summary)
                } else {
                    exportState = .idle
                    open(url)
                }
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
            }
        }
    }
}
