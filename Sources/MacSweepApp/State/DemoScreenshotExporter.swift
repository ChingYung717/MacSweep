import AppKit
import Darwin
import Foundation
import MacSweepCore
import SwiftUI

@MainActor
public enum DemoScreenshotExporter {
    private struct ScreenshotSpec {
        let filename: String
        let tab: MainTab
        let defaultLanguage: AppLanguage
        let defaultTheme: ThemeMode
        let forceLightAppearance: Bool
        let showSettingsProtectionSheet: Bool
        let configure: @MainActor (AppState) -> Void
    }

    enum ExporterError: Error, LocalizedError {
        case bitmapCreationFailed
        case pngEncodingFailed
        case directoryNotWritable(String)

        var errorDescription: String? {
            switch self {
            case .bitmapCreationFailed:
                return "Failed to allocate 2240x1400 NSBitmapImageRep"
            case .pngEncodingFailed:
                return "Failed to encode PNG representation"
            case let .directoryNotWritable(path):
                return "Screenshot output directory is not writable: \(path)"
            }
        }
    }

    @MainActor
    private final class OffscreenExportWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    @MainActor
    private final class ExportAppDelegate: NSObject, NSApplicationDelegate {
        let options: DemoLaunchOptions
        let outputURL: URL

        init(options: DemoLaunchOptions, outputURL: URL) {
            self.options = options
            self.outputURL = outputURL
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                do {
                    try await DemoScreenshotExporter.exportAll(options: options, to: outputURL)
                    Darwin.exit(0)
                } catch {
                    fputs("Screenshot export failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
        }
    }

    private static var activeDelegate: ExportAppDelegate?

    public static func runCLI(options: DemoLaunchOptions, outputPath: String) -> Never {
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        do {
            try prepareAndVerifyDirectory(outputURL)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ExportAppDelegate(options: options, outputURL: outputURL)
        activeDelegate = delegate
        app.delegate = delegate
        app.run()
        Darwin.exit(0)
    }

    private static func prepareAndVerifyDirectory(_ dirURL: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw ExporterError.directoryNotWritable(dirURL.path)
            }
        } else {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        let probeURL = dirURL.appendingPathComponent(".macsweep_write_probe_\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try Data("probe".utf8).write(to: probeURL, options: .atomic)
            try? FileManager.default.removeItem(at: probeURL)
        } catch {
            throw ExporterError.directoryNotWritable(dirURL.path)
        }
    }

    private static func exportAll(options: DemoLaunchOptions, to outputDirURL: URL) async throws {
        let state = AppState(launchOptions: options)
        let catalog = DemoFixtureCatalog.default
        let logicalSize = CGSize(width: 1120, height: 700)

        let window = OffscreenExportWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: logicalSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)

        let specs = buildSpecs(catalog: catalog)
        for spec in specs {
            let effectiveLang = options.languageOverride ?? spec.defaultLanguage
            let effectiveTheme = options.themeOverride ?? spec.defaultTheme
            let isDark: Bool
            if options.themeOverride != nil {
                isDark = (effectiveTheme == .deepOcean)
            } else if spec.forceLightAppearance {
                isDark = false
            } else {
                isDark = (effectiveTheme == .deepOcean)
            }

            state.banner = nil
            state.pendingConfirmation = nil
            state.showSettingsSheet = false
            state.preferences.language = effectiveLang
            state.preferences.themeMode = effectiveTheme
            state.activeTab = spec.tab
            spec.configure(state)

            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

            let colorScheme: ColorScheme = isDark ? .dark : .light
            let palette = AppPalette.resolve(mode: effectiveTheme, systemScheme: colorScheme)

            let rootContent: AnyView
            if spec.showSettingsProtectionSheet {
                rootContent = AnyView(
                    ZStack {
                        MainSplitView(state: state)
                        Color.black.opacity(0.28)
                        SettingsSheet(state: state, palette: palette)
                            .background(palette.windowBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(palette.border, lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.22), radius: 22, y: 8)
                    }
                    .frame(width: logicalSize.width, height: logicalSize.height)
                    .environment(\.colorScheme, colorScheme)
                    .allowsHitTesting(false)
                )
            } else {
                rootContent = AnyView(
                    MainSplitView(state: state)
                        .frame(width: logicalSize.width, height: logicalSize.height)
                        .environment(\.colorScheme, colorScheme)
                        .allowsHitTesting(false)
                )
            }

            let hostingView = NSHostingView(rootView: rootContent)
            hostingView.frame = NSRect(origin: .zero, size: logicalSize)
            window.contentView = hostingView

            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)

            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2240,
                pixelsHigh: 1400,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else {
                throw ExporterError.bitmapCreationFailed
            }
            rep.size = logicalSize
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

            guard let pngData = rep.representation(using: .png, properties: [:]) else {
                throw ExporterError.pngEncodingFailed
            }
            let targetURL = outputDirURL.appendingPathComponent(spec.filename)
            try pngData.write(to: targetURL, options: .atomic)
        }

        window.close()
    }

    private static func buildSpecs(catalog: DemoFixtureCatalog) -> [ScreenshotSpec] {
        [
            ScreenshotSpec(
                filename: "01-applications-dark-en.png",
                tab: .applications,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.isExpertMode = true
                state.appActionMode = .uninstall
                state.selectedAppID = catalog.defaultSelectedAppID
                state.droppedApp = nil
            },
            ScreenshotSpec(
                filename: "02-file-manager-analyzer.png",
                tab: .fileManager,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.fileManagerStore.mode = .spaceAnalyzer
                state.fileManagerStore.showInspector = true
                state.fileManagerStore.analyzerBreadcrumbIDs = []
                state.fileManagerStore.analyzerSizePreset = .all
                state.fileManagerStore.analyzerAgePreset = .all
                state.fileManagerStore.analyzerSearchText = ""
                let downloadsURL = URL(fileURLWithPath: "/Users/alex/Downloads")
                state.fileManagerStore.focusAnalyzerNode(downloadsURL, nodeID: downloadsURL.path)
            },
            ScreenshotSpec(
                filename: "03-file-manager-browser.png",
                tab: .fileManager,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.fileManagerStore.mode = .fileBrowser
                state.fileManagerStore.showInspector = true
                state.fileManagerStore.showHiddenFiles = true
                state.fileManagerStore.browserSearchText = ""
                state.fileManagerStore.loadDemoCatalog(catalog)
                state.fileManagerStore.mode = .fileBrowser
            },
            ScreenshotSpec(
                filename: "04-junk-cleaner.png",
                tab: .junkCleaner,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.cleanupCenterStore.selectedJunkCategoryID = JunkCategory.developerCaches.rawValue
                state.cleanupCenterStore.focusedJunkEntryID = catalog.junkCategories
                    .first(where: { $0.category == .developerCaches })?.entries.first?.id
            },
            ScreenshotSpec(
                filename: "05-resource-release-duplicates.png",
                tab: .resourceRelease,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.cleanupCenterStore.resourceSubTab = .duplicates
            },
            ScreenshotSpec(
                filename: "06-resource-release-memory.png",
                tab: .resourceRelease,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.cleanupCenterStore.resourceSubTab = .memory
                state.cleanupCenterStore.autoRefreshMemory = false
                state.cleanupCenterStore.memorySnapshot = catalog.memorySnapshot
                state.cleanupCenterStore.lastMemoryReleaseResult = catalog.memoryReleaseResult(from: catalog.memorySnapshot, elevated: false)
            },
            ScreenshotSpec(
                filename: "07-startup-extensions-leftovers.png",
                tab: .startup,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.selectedStartupID = catalog.defaultSelectedStartupID
            },
            ScreenshotSpec(
                filename: "08-settings-protection-light.png",
                tab: .applications,
                defaultLanguage: .en,
                defaultTheme: .system,
                forceLightAppearance: true,
                showSettingsProtectionSheet: true
            ) { state in
                state.selectedAppID = catalog.defaultSelectedAppID
                state.settingsTab = .protection
            },
            ScreenshotSpec(
                filename: "09-resource-release-large-files.png",
                tab: .resourceRelease,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.cleanupCenterStore.resourceSubTab = .largeFiles
                state.cleanupCenterStore.showLargeFileInspector = true
                if let first = state.cleanupCenterStore.largeFiles.first {
                    state.cleanupCenterStore.focusLargeFile(first)
                }
            },
            ScreenshotSpec(
                filename: "10-extensions.png",
                tab: .extensions,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.selectedExtensionID = catalog.defaultSelectedExtensionID
            },
            ScreenshotSpec(
                filename: "11-leftovers.png",
                tab: .leftovers,
                defaultLanguage: .en,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.selectedLeftoverGroupID = catalog.defaultSelectedLeftoverGroupID
            },
            ScreenshotSpec(
                filename: "12-showcase-zh-dark.png",
                tab: .applications,
                defaultLanguage: .zhHans,
                defaultTheme: .deepOcean,
                forceLightAppearance: false,
                showSettingsProtectionSheet: false
            ) { state in
                state.isExpertMode = true
                state.appActionMode = .uninstall
                state.selectedAppID = catalog.defaultSelectedAppID
                state.droppedApp = nil
            },
        ]
    }
}
