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
    /// Where the selected note will go, pre-filled from where it went last time.
    var target = NoteTarget()
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
    private let targets = NoteTargetStore()

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        reload()
        loadStoredCredential()
        // Reclaim stale encodes in the background so a user who exported twice
        // and stopped is not left with gigabytes forever.
        Task.detached(priority: .utility) { TranscodeCache().prune() }
    }

    // MARK: Storage

    /// Reusable compressed video. Safe to delete; costs time, not correctness.
    var cacheByteCount: Int64 { TranscodeCache().contents().byteCount }

    /// Staged copies of published sites. Deleting these means the next publish
    /// of one note drops its siblings from the live site until they are
    /// re-exported, so this is data rather than cache.
    var stagedByteCount: Int64 {
        SiteLibrary.byteCount(of: AppStorageLocation.support.appending(
            path: "sites", directoryHint: .isDirectory
        ))
    }

    func clearCache() {
        TranscodeCache().removeAll()
    }

    func clearStagedSites() {
        try? FileManager.default.removeItem(
            at: AppStorageLocation.support.appending(path: "sites", directoryHint: .isDirectory)
        )
        sites = []
    }

    /// Notes' own identifier for the selection, scoped by account so a row ID
    /// from one account cannot collide with another's.
    var selectedNoteID: String? {
        selectedNote.map { "\($0.accountIdentifier)/\($0.id)" }
    }

    /// The path segment this note publishes under.
    var notePath: String {
        let candidate = target.path?.trimmingCharacters(in: .whitespaces) ?? ""
        return candidate.isEmpty ? (selectedNote?.title.slugified ?? "note") : candidate
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
        // Everything about where this note goes is remembered, so the common
        // case is Export → Return.
        target = selectedNoteID.flatMap { targets[$0] } ?? NoteTarget(
            kind: preferences.isConnected ? .cloudflare : .disk,
            folderPath: preferences.defaultExportFolder?.path(percentEncoded: false)
        )
        exportState = .configuring
        refreshEstimate()
        refreshSites()
    }

    var availableDestinations: [DestinationKind] {
        DestinationKind.allCases.filter { $0 != .cloudflare || preferences.isConnected }
    }

    /// Whether the Export button can do anything yet.
    var isTargetComplete: Bool {
        switch target.kind {
        case .disk: target.folderURL != nil
        case .cloudflare: !(target.site ?? "").isEmpty
        }
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
        guard let document, let note = selectedNote, let noteID = selectedNoteID else { return }
        work?.cancel()

        switch target.kind {
        case .disk:
            guard let folder = target.folderURL else { chooseFolder(); return }
            var options = exportOptions
            options.overwriteDestination = true
            target.folderPath = folder.path(percentEncoded: false)
            targets[noteID] = target
            preferences.defaultExportFolder = folder.deletingLastPathComponent()

            exportState = .running(fraction: 0, message: "Preparing", detail: nil)
            work = Task {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                await run(document, to: folder, options: options, slug: nil, site: nil)
            }

        case .cloudflare:
            let site = (target.site ?? "").trimmingCharacters(in: .whitespaces)
            guard !site.isEmpty else { return }
            if let reason = DestinationKind.cloudflare.provider?.validateSiteName(site) {
                exportState = .failed("“\(site)” will not work as a site name. \(reason)")
                return
            }
            let path = notePath
            target.site = site
            target.path = path
            targets[noteID] = target
            preferences.lastSite = site

            var options = exportOptions
            options.overwriteDestination = true

            // Staged locally because a Workers deploy replaces the whole asset
            // set: siblings already published to this site must be uploaded
            // alongside this note or they would vanish.
            let library = SiteLibrary(root: AppStorageLocation.stagedSite(site))
            let title = note.title

            exportState = .running(fraction: 0, message: "Preparing", detail: nil)
            work = Task {
                do {
                    try await library.prepare()
                    try await library.clearDirectory(for: path)
                    await run(
                        document,
                        to: library.directory(for: path),
                        options: options,
                        slug: path,
                        site: (library, title, noteID)
                    )
                } catch {
                    exportState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Asks for the folder this note should be written to.
    func chooseFolder() {
        guard let note = selectedNote else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for this note's website."
        panel.directoryURL = target.folderURL?.deletingLastPathComponent()
            ?? preferences.defaultExportFolder
        panel.nameFieldStringValue = note.title.slugified

        guard panel.runModal() == .OK, let url = panel.url else { return }
        target.folderPath = url.path(percentEncoded: false)
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

    // MARK: Sites

    /// Sites known locally (folders) plus any on the connected account.
    private(set) var sites: [String] = []
    var selectedSite = ""
    private(set) var isLoadingSites = false

    /// Reloads the site list. Sites come from the connected account and from
    /// anything already staged locally, so a site created offline still shows.
    func refreshSites() {
        guard preferences.isConnected, let provider = DestinationKind.cloudflare.provider else {
            sites = []
            return
        }
        let staged = AppStorageLocation.support.appending(path: "sites", directoryHint: .isDirectory)
        let credential = self.credential

        isLoadingSites = true
        Task {
            defer { isLoadingSites = false }
            var names = Set(
                ((try? FileManager.default.contentsOfDirectory(
                    at: staged, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .map(\.lastPathComponent)
            )
            if let credential,
               let remote = try? await provider.listSites(credential, preferences.accountID) {
                names.formUnion(remote)
            }
            sites = names.sorted()
            if target.site == nil || !(names.contains(target.site ?? "")) {
                target.site = preferences.lastSite.flatMap { names.contains($0) ? $0 : nil } ?? sites.first
            }
        }
    }

    /// Adds a site name to the list. Nothing is created remotely until publish.
    func createSite(named name: String) {
        if let reason = DestinationKind.cloudflare.provider?.validateSiteName(name) {
            connectionStatus = ConnectionStatus(message: reason, isGood: false)
            return
        }
        if !sites.contains(name) { sites = (sites + [name]).sorted() }
        target.site = name
    }

    // MARK: Publishing

    struct ConnectionStatus: Equatable {
        let message: String
        let isGood: Bool
        /// Set when the token works but cannot name the account, which is fixed
        /// by widening the token rather than replacing it.
        var needsMembershipsPermission = false
    }

    var provider: ProviderDescriptor? { ProviderRegistry.provider(id: preferences.providerID) }

    /// The credential to authenticate with, or nil when nothing is connected.
    ///
    /// A browser sign-in is not readable from here — the tokens live in the Keychain behind
    /// the session actor, which is the point — so `.oauth` is a marker rather than a value.
    var credential: PublishCredential? {
        if preferences.usesOAuth { return provider?.oauth == nil ? nil : .oauth }
        guard let secret = storedCredential, !secret.isEmpty else { return nil }
        return .token(secret)
    }

    var canPublish: Bool {
        preferences.isConnected && credential != nil
    }

    /// Whether this build offers a browser sign-in for the selected provider.
    var supportsOAuth: Bool { provider?.oauth != nil }

    func selectProvider(id: String?) {
        preferences.providerID = id
        connectionStatus = nil
        loadStoredCredential()
    }

    func loadStoredCredential() {
        guard let provider else { credentialInput = ""; return }
        storedCredential = try? credentials.read(provider: provider.id)
        // Never put a stored secret back on screen, where it could be read over
        // a shoulder or captured in a screenshot.
        credentialInput = storedCredential == nil ? "" : String(repeating: "\u{2022}", count: 24)
        if credential != nil, preferences.isConnected {
            connectionStatus = ConnectionStatus(
                message: "Connected to \(preferences.accountName).", isGood: true
            )
        }
    }

    func disconnect() {
        guard let provider else { return }
        let wasOAuth = preferences.usesOAuth
        try? credentials.delete(provider: provider.id)
        storedCredential = nil
        credentialInput = ""
        preferences.accountID = ""
        preferences.accountName = ""
        preferences.usesOAuth = false
        connectionStatus = nil
        // Local state is already cleared, so a revocation that fails still leaves the user
        // disconnected. Telling them "disconnect failed" would be worse than useless.
        if wasOAuth, let oauth = provider.oauth {
            Task { await oauth.signOut() }
        }
    }

    /// Opens the browser, waits for the redirect, then resolves the account exactly as the
    /// token path does — the difference between the two ends at the credential.
    func signInWithBrowser() {
        guard let provider, let oauth = provider.oauth else { return }

        isTestingConnection = true
        connectionStatus = nil
        Task {
            defer { isTestingConnection = false }
            do {
                try await oauth.signIn()
                // Set before resolving the account so `credential` reports `.oauth` while
                // the discovery calls below are made.
                preferences.usesOAuth = true
                try await resolveAccount(provider: provider, credential: .oauth)
            } catch {
                preferences.usesOAuth = false
                connectionStatus = ConnectionStatus(
                    message: error.localizedDescription, isGood: false
                )
            }
        }
    }

    /// Validates the token and works out which account it can publish to, so
    /// the account ID never has to be typed.
    func connect() {
        guard let provider, !credentialInput.isEmpty else { return }
        let secret = credentialInput.allSatisfy { $0 == "\u{2022}" } ? storedCredential : credentialInput
        guard let secret, !secret.isEmpty else { return }

        isTestingConnection = true
        connectionStatus = nil
        Task {
            defer { isTestingConnection = false }
            do {
                // Written only once the account resolves, so a bad token never displaces a
                // good one already in the keychain.
                guard try await resolveAccount(provider: provider, credential: .token(secret)) else {
                    return
                }
                try credentials.write(secret, provider: provider.id)
                storedCredential = secret
                preferences.usesOAuth = false
                credentialInput = String(repeating: "\u{2022}", count: 24)
            } catch {
                connectionStatus = ConnectionStatus(
                    message: error.localizedDescription, isGood: false
                )
            }
        }
    }

    /// Works out which account a credential can publish to, and records it.
    ///
    /// Shared by both sign-in paths: once a credential exists, "which account is this?" is
    /// the same question and deserves the same answers, including the awkward ones.
    /// Returns false when it reported a problem the user has to fix.
    @discardableResult
    private func resolveAccount(
        provider: ProviderDescriptor, credential: PublishCredential
    ) async throws -> Bool {
        let accounts = try await provider.discoverAccounts(credential)

        guard let account = accounts.first else {
            // The credential itself is fine — it just cannot name the account.
            connectionStatus = ConnectionStatus(
                message: credential == .oauth
                    ? """
                        You're signed in, but this app could not tell which account to \
                        publish to. Sign in again and make sure the account you want is \
                        selected on Cloudflare's page.
                        """
                    : """
                        That token works, but it cannot see which account it belongs to. \
                        Add one more permission to it in Cloudflare — User \u{2192} \
                        Memberships \u{2192} Read \u{2014} then paste it again.
                        """,
                isGood: false,
                needsMembershipsPermission: credential != .oauth
            )
            return false
        }
        if accounts.count > 1 {
            // Rare, and picking the first silently would publish to the
            // wrong place. Scope the credential to one account instead.
            connectionStatus = ConnectionStatus(
                message: credential == .oauth
                    ? """
                        This sign-in can reach \(accounts.count) accounts \
                        (\(accounts.map(\.name).joined(separator: ", "))). Sign in again and \
                        grant access to just the one you want to publish to.
                        """
                    : """
                        This token can reach \(accounts.count) accounts \
                        (\(accounts.map(\.name).joined(separator: ", "))). Create a token \
                        scoped to just the one you want to publish to.
                        """,
                isGood: false
            )
            return false
        }

        preferences.accountID = account.id
        preferences.accountName = account.name
        connectionStatus = ConnectionStatus(
            message: "Connected to \(account.name).", isGood: true
        )
        if let host = try? await provider.accountHost(credential, account.id), !host.isEmpty {
            preferences.workersSubdomain = host
        }
        refreshSites()
        return true
    }

    /// Uploads the site this note belongs to. Everything staged for that site
    /// goes up together, because a deploy replaces the whole asset set.
    func publish() {
        guard let provider = DestinationKind.cloudflare.provider else { return }
        let site = (target.site ?? preferences.lastSite ?? "").trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty else {
            exportState = .failed("Choose a site first.")
            return
        }
        guard let credential,
              let publisher = provider.makePublisher(credential, preferences.accountID, site)
        else {
            exportState = .failed("Connect a Cloudflare account in Settings first.")
            return
        }

        let staged = AppStorageLocation.stagedSite(site)
        let summary = lastSummary
        exportState = .publishing(fraction: 0, message: "Preparing upload")
        work = Task {
            do {
                let result = try await publisher.publish(siteRoot: staged) { progress in
                    Task { @MainActor in
                        guard case .publishing = self.exportState else { return }
                        self.exportState = .publishing(
                            fraction: progress.fraction, message: progress.message
                        )
                    }
                }
                let url = summary?.slug.map {
                    result.url.appending(path: $0, directoryHint: .isDirectory)
                } ?? result.url
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
