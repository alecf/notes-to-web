import NotesToWebKit
import SwiftUI
import WebKit

/// Live preview of the exported page.
///
/// Media is referenced straight out of Notes' container via `file:` URLs, so videos
/// actually play in the preview rather than showing as placeholders. Read access is
/// scoped to the user's home directory, which covers both the preview file and the
/// Notes container.
struct PreviewWebView: NSViewRepresentable {
    let document: NoteDocument

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
        guard context.coordinator.renderedTitle != document.title
                || context.coordinator.renderedBlockCount != document.blocks.count
        else { return }
        context.coordinator.renderedTitle = document.title
        context.coordinator.renderedBlockCount = document.blocks.count

        guard let fileURL = try? writePreview(document) else { return }
        webView.loadFileURL(fileURL, allowingReadAccessTo: FileManager.default.homeDirectoryForCurrentUser)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var renderedTitle: String?
        var renderedBlockCount: Int?

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

    private func writePreview(_ document: NoteDocument) throws -> URL {
        var assets: [String: RenderedAsset] = [:]
        for (identifier, stored) in document.attachments {
            assets[identifier] = RenderedAsset(
                mediaPath: stored.fileURL?.absoluteString,
                posterPath: nil,
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

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/com.alecf.notes-to-web/preview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appending(path: "preview.html", directoryHint: .notDirectory)
        try Data(renderer.render(document).utf8).write(to: fileURL)
        return fileURL
    }
}
