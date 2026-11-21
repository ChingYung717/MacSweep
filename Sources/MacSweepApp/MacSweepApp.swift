import AppKit
import MacSweepCore
import SwiftUI

@MainActor
final class MacSweepAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpenURLs: [URL] = []
    var onOpenURLs: (([URL]) -> Void)? {
        didSet {
            if let handler = onOpenURLs, !pendingOpenURLs.isEmpty {
                let queued = pendingOpenURLs
                pendingOpenURLs.removeAll()
                handler(queued)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = onOpenURLs {
            handler(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(MacSweepAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            NSApplication.shared.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup("MacSweep") {
            MainSplitView(state: state)
                .frame(minWidth: 1020, minHeight: 650)
                .onAppear {
                    appDelegate.onOpenURLs = { [state] urls in
                        if let appURL = urls.first(where: { $0.pathExtension.lowercased() == "app" }) {
                            Task { @MainActor in
                                state.inspectDroppedApp(at: appURL)
                            }
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button(state.l10n.settings) {
                    state.showSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
