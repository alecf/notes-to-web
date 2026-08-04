import AppKit
import NotesToWebKit
import SwiftUI

struct ExportSheet: View {
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(spacing: 18) {
            switch library.exportState {
            case .idle:
                EmptyView()
            case .configuring:
                OptionsView(library: library)
            case .running(let fraction, let message, let detail):
                RunningView(fraction: fraction, message: message, detail: detail) { library.cancel() }
            case .finished(let summary):
                FinishedView(library: library, summary: summary)
            case .publishing(let fraction, let message):
                RunningView(fraction: fraction, message: message, detail: nil) { library.cancel() }
            case .published(let url, let summary):
                PublishedView(library: library, url: url, summary: summary)
            case .failed(let message):
                FailedView(message: message) { library.exportState = .idle }
            }
        }
        .padding(28)
        .frame(width: 500)
    }
}

// MARK: - Options

private struct OptionsView: View {
    @Bindable var library: LibraryModel

    private var preferences: Preferences { library.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export \(library.selectedNote?.title ?? "Note")")
                .font(.title3.weight(.semibold))

            Form {
                Section("Publish to") {
                    Picker("Destination", selection: $library.target.kind) {
                        ForEach(library.availableDestinations) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    switch library.target.kind {
                    case .disk:
                        LabeledContent("Folder") {
                            HStack {
                                Text(library.target.folderURL?.path(percentEncoded: false) ?? "Not chosen")
                                    .foregroundStyle(library.target.folderURL == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Button("Choose…") { library.chooseFolder() }
                            }
                        }
                    case .cloudflare:
                        SitePicker(library: library)
                        TextField("Path", text: Binding(
                            get: { library.target.path ?? library.notePath },
                            set: { library.target.path = $0 }
                        ))
                        if let site = library.target.site, !site.isEmpty {
                            Text("\(site).\(library.preferences.workersSubdomain)/\(library.notePath)/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Video") {
                    Toggle("Compress for the web", isOn: Binding(
                        get: { preferences.compressVideo },
                        set: { preferences.compressVideo = $0; library.refreshEstimate() }
                    ))
                    .help("Re-encode videos at a web-friendly bitrate. Off keeps the original quality and size.")

                    if preferences.compressVideo {
                        Picker("Quality", selection: Binding(
                            get: { preferences.quality },
                            set: { preferences.quality = $0; library.refreshEstimate() }
                        )) {
                            ForEach(VideoQuality.allCases) { quality in
                                Text("\(quality.displayName) — \(quality.detail)").tag(quality)
                            }
                        }

                        Picker("Format", selection: Binding(
                            get: { preferences.codec },
                            set: { preferences.codec = $0; library.refreshEstimate() }
                        )) {
                            ForEach(VideoCodec.allCases) { codec in
                                Text("\(codec.displayName) — \(codec.detail)").tag(codec)
                            }
                        }

                        Toggle("Keep every file under \(library.sizeBudgetLabel)", isOn: Binding(
                            get: { preferences.enforceSizeBudget },
                            set: { preferences.enforceSizeBudget = $0; library.refreshEstimate() }
                        ))
                        .help("Most free static hosts reject any single file over about 25 MB.")
                    }
                }
            }
            .formStyle(.grouped)

            EstimateRow(library: library)

            HStack {
                Button("Cancel") { library.exportState = .idle }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export") { library.confirmExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!library.isTargetComplete)
            }
        }
    }

}

/// Existing sites plus a way to name a new one. Sites come from the connected
/// account and from anything already staged locally.
private struct SitePicker: View {
    @Bindable var library: LibraryModel
    @State private var isCreating = false
    @State private var newName = ""

    var body: some View {
        if isCreating || library.sites.isEmpty {
            HStack {
                TextField("Site name", text: $newName, prompt: Text("alecs-notes"))
                    .onSubmit(create)
                Button("Create", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                if !library.sites.isEmpty {
                    Button("Cancel") { isCreating = false }
                }
            }
        } else {
            HStack {
                Picker("Site", selection: Binding(
                    get: { library.target.site ?? library.sites.first ?? "" },
                    set: { library.target.site = $0 }
                )) {
                    ForEach(library.sites, id: \.self) { Text($0).tag($0) }
                }
                Button("New…") { newName = ""; isCreating = true }
                if library.isLoadingSites { ProgressView().controlSize(.small) }
            }
        }
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.createSite(named: trimmed)
        isCreating = false
    }
}

private struct EstimateRow: View {
    @Bindable var library: LibraryModel

    var body: some View {
        Group {
            if library.isEstimating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring videos…").foregroundStyle(.secondary)
                }
            } else if let estimate = library.estimate, estimate.videoCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                        Text(sizeLine(estimate))
                    }
                    ForEach(estimate.oversized.prefix(3), id: \.self) { name in
                        Label(
                            "\(name) will still be over \(library.sizeBudgetLabel) — it may be too long to compress that far.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                    if estimate.oversized.count > 3 {
                        Text("…and \(estimate.oversized.count - 3) more.")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sizeLine(_ estimate: LibraryModel.ExportEstimate) -> String {
        let count = "\(estimate.videoCount) video\(estimate.videoCount == 1 ? "" : "s")"
        let from = ByteCountFormatter.string(fromByteCount: estimate.sourceBytes, countStyle: .file)
        guard estimate.estimatedBytes < estimate.sourceBytes else { return "\(count) · \(from)" }
        let to = ByteCountFormatter.string(fromByteCount: estimate.estimatedBytes, countStyle: .file)
        let saved = Int((1 - Double(estimate.estimatedBytes) / Double(estimate.sourceBytes)) * 100)
        return "\(count) · \(from) → about \(to) (\(saved)% smaller)"
    }
}

// MARK: - Running

private struct RunningView: View {
    let fraction: Double
    let message: String
    let detail: String?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: fraction) {
                Text(message).font(.headline)
            } currentValueLabel: {
                HStack {
                    Text(detail ?? " ").foregroundStyle(.secondary)
                    Spacer()
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .progressViewStyle(.linear)
            .animation(.easeOut(duration: 0.2), value: fraction)

            Button("Cancel", action: cancel)
        }
    }
}

// MARK: - Finished

private struct FinishedView: View {
    @Bindable var library: LibraryModel
    let summary: LibraryModel.ExportSummary

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Exported").font(.title3.weight(.semibold))

            Text(headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let saved = savedLine {
                Text(saved)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
            }

            if !summary.warnings.isEmpty {
                DisclosureGroup("\(summary.warnings.count) warning\(summary.warnings.count == 1 ? "" : "s")") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(summary.warnings, id: \.self) { warning in
                            Text("• \(warning)").font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 430)
            }

            HStack(spacing: 12) {
                Button("Reveal in Finder") { library.revealInFinder(summary.directory) }
                Button("Preview") { library.open(summary.directory.appending(path: "index.html")) }

                if library.canPublish, summary.slug != nil, let provider = library.provider {
                    Button("Publish to \(provider.displayName)") { library.publish() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Button("Done") { library.exportState = .idle }
                } else {
                    Button("Done") { library.exportState = .idle }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var headline: String {
        let assets = "\(summary.assetCount) file\(summary.assetCount == 1 ? "" : "s")"
        let size = ByteCountFormatter.string(fromByteCount: summary.exportedBytes, countStyle: .file)
        if let slug = summary.slug {
            return "Added to your site as /\(slug)/ — \(assets), \(size)."
        }
        return "\(summary.directory.lastPathComponent) — index.html and \(assets), \(size). Upload the whole folder as-is."
    }

    private var savedLine: String? {
        guard summary.sourceBytes > summary.exportedBytes, summary.sourceBytes > 0 else { return nil }
        let before = ByteCountFormatter.string(fromByteCount: summary.sourceBytes, countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: summary.exportedBytes, countStyle: .file)
        let saved = Int((1 - Double(summary.exportedBytes) / Double(summary.sourceBytes)) * 100)
        return "\(before) → \(after), \(saved)% smaller"
    }
}

private struct PublishedView: View {
    @Bindable var library: LibraryModel
    let url: URL
    let summary: LibraryModel.ExportSummary

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Published").font(.title3.weight(.semibold))
            Link(url.absoluteString, destination: url)
                .font(.callout)
            // A brand-new workers.dev hostname takes up to a minute to reach
            // every edge location. Without this, a first publish reads as broken.
            Text("A brand-new address can take a minute to work everywhere. If it 404s, wait and reload.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Button("Done") { library.exportState = .idle }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct FailedView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Export Failed").font(.title3.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Close", action: dismiss)
                .keyboardShortcut(.defaultAction)
        }
    }
}
