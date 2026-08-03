import AppKit
import SwiftUI

@main
struct NotesToWebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = LibraryModel()

    var body: some Scene {
        Window("Notes to Web", id: "main") {
            ContentView(library: library)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Export Note…") { library.beginExport() }
                    .keyboardShortcut("e")
                    .disabled(library.selectedNote == nil)
                Button("Refresh Notes") { library.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}

/// SwiftPM-built apps are not launched by LaunchServices as regular apps unless we
/// say so, and an executable target has no default activation policy.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
