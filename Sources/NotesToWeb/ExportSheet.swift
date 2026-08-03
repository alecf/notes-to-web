import SwiftUI

struct ExportSheet: View {
    @Bindable var library: LibraryModel

    var body: some View {
        VStack(spacing: 18) {
            switch library.exportState {
            case .idle:
                EmptyView()

            case .running(let fraction, let message):
                VStack(spacing: 12) {
                    ProgressView(value: fraction) {
                        Text("Exporting").font(.headline)
                    } currentValueLabel: {
                        Text(message).foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                    Text("Videos are copied and converted, so this can take a moment.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

            case .finished(let directory, let assetCount, let warnings):
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Exported").font(.title3.weight(.semibold))
                    Text("\(directory.lastPathComponent) — index.html and \(assetCount) asset\(assetCount == 1 ? "" : "s"). Upload the whole folder as-is.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if !warnings.isEmpty {
                        DisclosureGroup("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(warnings, id: \.self) { warning in
                                    Text("• \(warning)").font(.callout)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: 420)
                    }

                    HStack(spacing: 12) {
                        Button("Reveal in Finder") { library.revealInFinder(directory) }
                            .buttonStyle(.borderedProminent)
                        Button("Done") { library.exportState = .idle }
                            .keyboardShortcut(.defaultAction)
                    }
                }

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("Export Failed").font(.title3.weight(.semibold))
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Close") { library.exportState = .idle }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}
