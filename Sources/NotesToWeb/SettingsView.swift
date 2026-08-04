import AppKit
import NotesToWebKit
import SwiftUI

struct SettingsView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        TabView {
            DiskSettings(preferences: library.preferences)
                .tabItem { Label("Folders", systemImage: "folder") }
            VideoSettings(preferences: library.preferences)
                .tabItem { Label("Video", systemImage: "film") }
            PublishingSettings(library: library)
                .tabItem { Label("Publishing", systemImage: "globe") }
            StorageSettings(library: library)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 560, height: 400)
    }
}

// MARK: - Disk

private struct DiskSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                LabeledContent("Start in") {
                    HStack {
                        Text(preferences.defaultExportFolder?.path(percentEncoded: false) ?? "Ask each time")
                            .foregroundStyle(preferences.defaultExportFolder == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…", action: choose)
                        if preferences.defaultExportFolder != nil {
                            Button("Clear") { preferences.defaultExportFolder = nil }
                        }
                    }
                }
            } header: {
                Text("A folder on this Mac")
            } footer: {
                Text("""
                    Where the folder chooser opens when a note has no folder yet. Each note \
                    remembers its own folder after the first export, so re-exporting never asks \
                    again.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where the folder chooser should start."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.defaultExportFolder = url
    }
}

// MARK: - Video

private struct VideoSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Compress videos for the web", isOn: $preferences.compressVideo)
                Picker("Quality", selection: $preferences.quality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text("\(quality.displayName) — \(quality.detail)").tag(quality)
                    }
                }
                .disabled(!preferences.compressVideo)
                Picker("Format", selection: $preferences.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text("\(codec.displayName) — \(codec.detail)").tag(codec)
                    }
                }
                .disabled(!preferences.compressVideo)
                Toggle("Keep every file under the host's limit", isOn: $preferences.enforceSizeBudget)
                    .disabled(!preferences.compressVideo)
            } footer: {
                Text("""
                    Straight off an iPhone, a short clip can be 50 MB. Cloudflare and most free \
                    static hosts reject any single file over 25 MB, so compression is usually the \
                    difference between a site that publishes and one that doesn't.

                    H.264 plays in every browser. HEVC files are roughly 40% smaller but some \
                    browsers can't decode them.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// A numbered instruction. The text is Markdown so providers can bold the
/// labels a user has to click without the UI knowing anything about them.
private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(.tint, in: .circle)
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    @Bindable var library: LibraryModel
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("Compressed video") {
                    HStack {
                        Text(size(library.cacheByteCount))
                        Spacer()
                        Button("Empty") { library.clearCache(); refresh += 1 }
                            .disabled(library.cacheByteCount == 0)
                    }
                }
            } footer: {
                Text("""
                    Re-exporting a note reuses these instead of compressing again, which is the \
                    difference between a minute and an instant. Emptying this only costs time on \
                    the next export. Anything unused for 30 days is removed automatically, and \
                    macOS may reclaim it sooner if the disk fills.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Published sites") {
                    HStack {
                        Text(size(library.stagedByteCount))
                        Spacer()
                        Button("Remove") { library.clearStagedSites(); refresh += 1 }
                            .disabled(library.stagedByteCount == 0)
                    }
                }
            } footer: {
                Text("""
                    A copy of each site as published. Cloudflare replaces a site's whole contents \
                    on every publish, so this is what keeps notes you published earlier from \
                    disappearing when you publish another one. Removing it means re-exporting \
                    those notes before the next publish.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .id(refresh)
    }

    private func size(_ bytes: Int64) -> String {
        bytes == 0 ? "Nothing stored" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Publishing

private struct PublishingSettings: View {
    @Bindable var library: LibraryModel

    private var provider: ProviderDescriptor? {
        ProviderRegistry.provider(id: library.preferences.providerID)
    }

    var body: some View {
        Form {
            Section {
                Picker("Publish to", selection: Binding(
                    get: { library.preferences.providerID ?? "" },
                    set: { library.selectProvider(id: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Nowhere — I'll upload it myself").tag("")
                    ForEach(ProviderRegistry.all) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
            }

            if let provider {
                if library.preferences.isConnected {
                    connected(provider)
                } else {
                    steps(provider)
                }

                tokenField(provider)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { library.loadStoredCredential() }
    }

    @ViewBuilder
    private func connected(_ provider: ProviderDescriptor) -> some View {
        Section {
            LabeledContent("Account") {
                HStack {
                    Text(library.preferences.accountName)
                    Spacer()
                    Button("Disconnect") { library.disconnect() }
                }
            }
        } header: {
            Text(provider.displayName)
        }
    }

    @ViewBuilder
    private func steps(_ provider: ProviderDescriptor) -> some View {
        if !provider.capabilities.credentialSteps.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(provider.capabilities.credentialSteps.enumerated()), id: \.offset) { index, step in
                        NumberedStep(number: index + 1, text: step)
                    }
                    if let url = provider.capabilities.credentialURL {
                        Link("Create a token…", destination: url)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Getting a \(provider.capabilities.credentialLabel)")
            }
        }
    }

    @ViewBuilder
    private func tokenField(_ provider: ProviderDescriptor) -> some View {
        Section {
            SecureField(
                provider.capabilities.credentialLabel,
                text: $library.credentialInput,
                prompt: Text("Paste it here")
            )
            .onSubmit { library.connect() }

            HStack {
                Button(library.preferences.isConnected ? "Update Token" : "Connect") {
                    library.connect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(library.credentialInput.isEmpty || library.isTestingConnection)
                if library.isTestingConnection {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if let status = library.connectionStatus {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(status.message)
                    } icon: {
                        Image(systemName: status.isGood
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(status.isGood ? .green : .orange)

                    if status.needsMembershipsPermission,
                       let url = provider.capabilities.credentialURL {
                        Link("Edit the token…", destination: url)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text(provider.capabilities.credentialHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
