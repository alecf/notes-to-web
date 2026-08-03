import NotesToWebKit
import SwiftUI
import WebKit

/// Live preview of the exported page.
///
/// Media is referenced straight out of Notes' container via `file:` URLs, so videos
/// actually play in the preview rather than showing as placeholders. Read access is
/// scoped to the user's home directory, which covers both the preview file and the
/// Notes container.
///
/// Poster frames are generated into a cache directory the same way the exporter
/// generates them, so the preview shows the same still frames the published page
/// will — not a column of black rectangles.
struct PreviewWebView: NSViewRepresentable {
    let document: NoteDocument

    private static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/com.alecf.notes-to-web", directoryHint: .isDirectory)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.renderedNote != identity else { return }
        context.coordinator.renderedNote = identity
        context.coordinator.posterTask?.cancel()

        // Render immediately with whatever posters are already cached, then fill in
        // the rest in the background so switching notes stays instant.
        let cached = Self.existingPosters(for: document)
        load(document, posters: cached, into: webView)

        let attachments = document.attachments.values.filter { $0.kind == .video }
        guard cached.count < attachments.count else { return }

        context.coordinator.posterTask = Task { [document] in
            let posters = await PosterFrame.cache(for: Array(attachments), in: Self.cacheDirectory)
            guard !Task.isCancelled, posters.count > cached.count else { return }
            load(document, posters: posters, into: webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var renderedNote: String?
        var posterTask: Task<Void, Never>?

        deinit { posterTask?.cancel() }

        /// Links in a preview should open in the browser, not navigate the preview.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    // MARK: Rendering

    /// Distinguishes one note's document from another without holding the whole thing.
    private var identity: String {
        "\(document.title)|\(document.blocks.count)|\(document.attachments.keys.sorted().joined())"
    }

    private static func existingPosters(for document: NoteDocument) -> [String: URL] {
        var posters: [String: URL] = [:]
        for attachment in document.attachments.values where attachment.kind == .video {
            let url = cacheDirectory.appending(path: "\(attachment.identifier).jpg", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                posters[attachment.identifier] = url
            }
        }
        return posters
    }

    private func load(_ document: NoteDocument, posters: [String: URL], into webView: WKWebView) {
        var assets: [String: RenderedAsset] = [:]
        for (identifier, stored) in document.attachments {
            assets[identifier] = RenderedAsset(
                mediaPath: stored.fileURL?.absoluteString,
                posterPath: posters[identifier]?.absoluteString,
                mimeType: stored.mimeType,
                displayName: stored.displayName,
                byteCount: stored.fileSize
            )
        }

        let renderer = HTMLRenderer(
            assets: assets,
            stylesheetHref: nil,
            inlineStylesheet: HTMLRenderer.bundledStylesheet
        )

        let directory = Self.cacheDirectory.appending(path: "preview", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return }

        let fileURL = directory.appending(path: "preview.html", directoryHint: .notDirectory)
        guard (try? Data(renderer.render(document).utf8).write(to: fileURL)) != nil else { return }

        webView.loadFileURL(fileURL, allowingReadAccessTo: FileManager.default.homeDirectoryForCurrentUser)
    }
}
