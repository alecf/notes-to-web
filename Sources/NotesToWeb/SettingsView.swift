import AppKit
import NotesToWebKit
import SwiftUI

struct SettingsView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        TabView {
            SiteSettings(library: library)
                .tabItem { Label("Site", systemImage: "folder") }
            VideoSettings(preferences: library.preferences)
                .tabItem { Label("Video", systemImage: "film") }
            PublishingSettings(library: library)
                .tabItem { Label("Publishing", systemImage: "globe") }
        }
        .frame(width: 560, height: 400)
    }
}

// MARK: - Site

private struct SiteSettings: View {
    @Bindable var library: LibraryModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Site folder") {
                    HStack {
                        Text(library.preferences.siteRoot?.path(percentEncoded: false) ?? "Not set")
                            .foregroundStyle(library.preferences.siteRoot == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Choose…") { chooseSiteRoot() }
                    }
                }
            } footer: {
                Text("""
                    Every note you export lands in its own subfolder here, so they publish as \
                    one site: /workout-plan/, /recipes/, and so on. Publishing uploads this whole \
                    folder — unchanged files are skipped, so re-publishing one note is cheap.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseSiteRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder to hold every note you publish."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.preferences.siteRoot = url
        library.destination = .site
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

// MARK: - Publishing

private struct PublishingSettings: View {
    @Bindable var library: LibraryModel

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

            if let provider = ProviderRegistry.provider(id: library.preferences.providerID) {
                Section {
                    ForEach(provider.settings) { field in
                        TextField(field.label, text: Binding(
                            get: { field.value(library.preferences) },
                            set: { field.setValue(library.preferences, $0) }
                        ), prompt: Text(field.prompt))
                        .help(field.help)
                    }

                    SecureField(provider.capabilities.credentialLabel, text: $library.credentialInput,
                                prompt: Text("Paste it here"))

                    HStack {
                        if let url = provider.capabilities.credentialURL {
                            Link("Create a token…", destination: url)
                        }
                        Spacer()
                        Button("Save & Test") { library.saveAndTestCredentials() }
                            .disabled(library.credentialInput.isEmpty || library.isTestingConnection)
                        if library.isTestingConnection {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if let status = library.connectionStatus {
                        Label(status.message, systemImage: status.isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.isGood ? .green : .orange)
                            .font(.callout)
                    }
                } header: {
                    Text(provider.displayName)
                } footer: {
                    Text(provider.capabilities.credentialHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("""
                    Your token is stored in the macOS Keychain, never in a preferences file and \
                    never in this app's source. Nothing is embedded in the app itself — you create \
                    the token, you can revoke it, and it never leaves your Mac except to the \
                    provider you chose.
                    """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { library.loadStoredCredential() }
    }
}
