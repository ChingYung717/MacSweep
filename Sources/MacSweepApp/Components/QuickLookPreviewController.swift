import AppKit
import MacSweepCore
import QuickLookUI
import SwiftUI

struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL?
    let isEligible: Bool

    func makeNSView(context: Context) -> QLPreviewView {
        let view = (QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView(frame: .zero))!
        view.autostarts = false
        view.shouldCloseWithWindow = true
        view.previewItem = (isEligible ? url : nil) as NSURL?
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        let target: URL? = isEligible ? url : nil
        if nsView.previewItem?.previewItemURL != target {
            nsView.previewItem = target as NSURL?
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.previewItem = nil
    }
}

@MainActor
final class QLPreviewPanelBridge: NSResponder, ObservableObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var previewItems: [NSURL] = []
    private weak var attachedWindow: NSWindow?
    private weak var previousNextResponder: NSResponder?

    static func isEligibleForQuickLook(metadata: FileMetadataInfo?) -> Bool {
        guard let metadata else { return false }
        return !metadata.isDataless
            && !metadata.isSymbolicLink
            && metadata.kind != .special
            && FileManager.default.fileExists(atPath: metadata.url.path)
    }

    static func isEligibleForQuickLook(
        url: URL,
        isDataless: Bool,
        isSymlink: Bool,
        isSpecial: Bool
    ) -> Bool {
        guard url.isFileURL, !isDataless, !isSymlink, !isSpecial else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func attach(to window: NSWindow?) {
        guard attachedWindow !== window else { return }
        detach()
        guard let window else { return }
        attachedWindow = window
        previousNextResponder = window.nextResponder
        self.nextResponder = previousNextResponder
        window.nextResponder = self
    }

    func detach() {
        if let window = attachedWindow, window.nextResponder === self {
            window.nextResponder = previousNextResponder
        }
        attachedWindow = nil
        previousNextResponder = nil
        self.nextResponder = nil
    }

    func updateSelection(urls: [URL]) {
        previewItems = urls.map { $0.standardizedFileURL as NSURL }
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(),
           panel.isVisible {
            if previewItems.isEmpty {
                panel.orderOut(nil)
            } else {
                panel.reloadData()
            }
        }
    }

    func presentOrToggle(urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        previewItems = urls.map { $0.standardizedFileURL as NSURL }
        guard !previewItems.isEmpty else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.updateController()
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !previewItems.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource === self {
            panel.dataSource = nil
        }
        if panel.delegate === self {
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index >= 0, index < previewItems.count else { return nil }
        return previewItems[index]
    }
}

struct QuickLookPanelBridgeHost: NSViewRepresentable {
    let bridge: QLPreviewPanelBridge

    final class BridgeAnchorNSView: NSView {
        weak var bridge: QLPreviewPanelBridge?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let bridgeRef = bridge
            let targetWindow = window
            Task { @MainActor in
                bridgeRef?.attach(to: targetWindow)
            }
        }
    }

    func makeNSView(context: Context) -> BridgeAnchorNSView {
        let view = BridgeAnchorNSView(frame: .zero)
        view.bridge = bridge
        return view
    }

    func updateNSView(_ nsView: BridgeAnchorNSView, context: Context) {
        nsView.bridge = bridge
        if let win = nsView.window {
            bridge.attach(to: win)
        }
    }

    static func dismantleNSView(_ nsView: BridgeAnchorNSView, coordinator: ()) {
        let bridgeRef = nsView.bridge
        Task { @MainActor in
            bridgeRef?.detach()
        }
    }
}

private final class LocalEventMonitorHandle {
    var monitor: Any?

    func replace(with newMonitor: Any?) {
        if let existing = monitor {
            NSEvent.removeMonitor(existing)
        }
        monitor = newMonitor
    }

    deinit {
        if let existing = monitor {
            NSEvent.removeMonitor(existing)
        }
    }
}

@MainActor
final class SpacebarQuickLookMonitorBox: ObservableObject {
    private let handle = LocalEventMonitorHandle()

    func install(
        shouldHandle: @escaping @MainActor () -> Bool,
        onTrigger: @escaping @MainActor () -> Void
    ) {
        let installed = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49 else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return event }
            guard let keyWin = NSApp.keyWindow,
                  keyWin.attachedSheet == nil,
                  !(keyWin.firstResponder is NSTextView) else {
                return event
            }
            guard shouldHandle() else { return event }
            onTrigger()
            return nil
        }
        handle.replace(with: installed)
    }

    func remove() {
        handle.replace(with: nil)
    }
}
