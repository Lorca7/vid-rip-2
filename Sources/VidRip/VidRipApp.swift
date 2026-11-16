import AppKit
import SwiftUI

@main
struct VidRipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("VidRip", id: "main") {
            ContentView()
                .environmentObject(app)
        }
        .defaultSize(width: 1200, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video File…") { app.openLocalFile() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Tools") {
                Button("Update YouTube Downloader (yt-dlp)") { app.updateYtDlp() }
                Divider()
                Button("Show Downloads Cache in Finder") { app.revealCache() }
                Button("Clear Downloads Cache") { app.clearCache() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than an .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessRunner.terminateAll()
    }
}
