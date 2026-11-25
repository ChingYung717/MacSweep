import AppKit
import MacSweepCore
import SwiftUI

struct FileManagerView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: FileManagerStore
    @ObservedObject var qlBridge: QLPreviewPanelBridge
    let palette: AppPalette

    @StateObject private var showNewFolderSheetBox = LocalState(false)
    @StateObject private var newFolderNameBox = LocalState("")
    @StateObject private var newFolderErrorBox = LocalState<String?>(nil)

    @StateObject private var renameTargetEntryBox = LocalState<FileBrowserEntry?>(nil)
    @StateObject private var renameNameBox = LocalState("")
    @StateObject private var renameErrorBox = LocalState<String?>(nil)

    @StateObject private var spacebarMonitorBox = SpacebarQuickLookMonitorBox()

    private var l10n: L10n { state.l10n }

    var body: some View {
        VStack(spacing: 0) {
            topModeHeader

            Group {
                switch store.mode {
                case .spaceAnalyzer:
                    spaceAnalyzerBody
                case .fileBrowser:
                    fileBrowserBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.detailBackground)
        .task {
            await store.loadInitialIfNeeded()
        }
        .onAppear {
            installSpacebarMonitor()
        }
        .onDisappear {
            spacebarMonitorBox.remove()
            qlBridge.updateSelection(urls: [])
        }
        .onChange(of: store.inspectedMetadata) {
            syncQuickLookSelection()
        }
        .onChange(of: store.inspectedURL) {
            syncQuickLookSelection()
        }
        .sheet(isPresented: $showNewFolderSheetBox.value) {
            newFolderSheet
        }
        .sheet(item: $renameTargetEntryBox.value) { entry in
            renameItemSheet(for: entry)
        }
    }

    // MARK: - Top Header

    private var topModeHeader: some View {
        HStack(spacing: 12) {
            Text(l10n.tabFileManager)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.primaryText)

            Picker("", selection: $store.mode) {
                Text(l10n.fileManagerSpaceAnalyzer).tag(FileManagerMode.spaceAnalyzer)
                Text(l10n.fileManagerFileBrowser).tag(FileManagerMode.fileBrowser)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Spacer()

            Button {
                store.showInspector.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 12, weight: .medium))
                    Text(l10n.toggleInspector)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(store.showInspector ? palette.accent : palette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(store.showInspector ? palette.accent.opacity(0.14) : palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(store.showInspector ? palette.activeBorder : palette.border, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.listBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    // MARK: - Mode 1: Space Analyzer

    private var spaceAnalyzerBody: some View {
        VStack(spacing: 0) {
            analyzerControlsBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(palette.listBackground.opacity(0.65))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.border).frame(height: 1)
                }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        if let vol = store.analyzerVolumeInfo {
                            VolumeCapacityBarView(
                                volume: vol,
                                analyzedNode: store.analyzerRootNode,
                                palette: palette,
                                l10n: l10n
                            )
                        }

                        if store.isAnalyzing {
                            analyzerProgressBanner
                        }

                        if let err = store.analyzerError {
                            analyzerErrorBanner(err)
                        }

                        analyzerFilterAndBreadcrumbBar
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider().opacity(0.25)

                    analyzerContentList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    analyzerBottomBar
                }
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)

                if store.showInspector {
                    Rectangle().fill(palette.border).frame(width: 1)
                    inspectorPane
                        .frame(width: 315)
                }
            }
        }
    }

    private var analyzerControlsBar: some View {
        let homeURL = state.homeDirectoryURL.standardizedFileURL
        let appsURL = URL(fileURLWithPath: "/Applications")

        return HStack(spacing: 8) {
            presetButton(title: l10n.homeFolder, icon: "house.fill", isActive: store.analyzerRootURL.path == homeURL.path) {
                store.startSpaceAnalysis(at: homeURL)
            }

            presetButton(title: l10n.applicationsFolder, icon: "square.grid.2x2.fill", isActive: store.analyzerRootURL.path == appsURL.path) {
                store.startSpaceAnalysis(at: appsURL)
            }

            Menu {
                ForEach(store.analyzerAvailableVolumes) { vol in
                    Button {
                        store.startSpaceAnalysis(at: vol.url)
                    } label: {
                        HStack {
                            Text("\(vol.name) (\(ByteFormatter.format(vol.totalBytes)))")
                            if store.analyzerRootURL.path == vol.url.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 11.5))
                    Text(l10n.volumesSection)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                if let chosen = chooseDirectoryPanel(title: l10n.chooseFolder, initialURL: store.analyzerRootURL) {
                    store.startSpaceAnalysis(at: chosen)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11.5))
                    Text(l10n.chooseFolder)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Text(SafeFileReader.sanitizeForDisplay(store.analyzerRootURL.path))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(palette.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            if store.isAnalyzing {
                Button {
                    store.cancelSpaceAnalysis()
                } label: {
                    Label(l10n.stopScan, systemImage: "stop.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.danger))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    store.startSpaceAnalysis(at: store.analyzerRootURL)
                } label: {
                    Label(l10n.refresh, systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func presetButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                Text(title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? Color.white : palette.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? palette.accent : palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isActive ? palette.activeBorder : palette.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var analyzerProgressBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(l10n.analyzingSpace)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    if let prog = store.scanProgress {
                        Text(l10n.scannedItemsCount(prog.scannedFiles, folders: prog.scannedFolders))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondaryText)
                        Text("· \(ByteFormatter.format(prog.totalBytes))")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.accent)
                            .monospacedDigit()
                    }
                }
                if let prog = store.scanProgress {
                    Text(SafeFileReader.sanitizeForDisplay(prog.currentPath))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(palette.accent.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func analyzerErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.danger)
            Text(SafeFileReader.sanitizeForDisplay(message))
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
            Spacer()
            if !state.hasFullDiskAccess {
                Button(l10n.folderFDAAction) {
                    state.openSystemSettings(PermissionChecker.fullDiskAccessSettingsURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(palette.danger.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(palette.danger.opacity(0.4), lineWidth: 1)
                )
        )
    }

    private var analyzerFilterAndBreadcrumbBar: some View {
        VStack(spacing: 8) {
            // Breadcrumbs
            HStack(spacing: 6) {
                Button {
                    store.navigateAnalyzerUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.analyzerBreadcrumbIDs.isEmpty ? palette.tertiaryText : palette.primaryText)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
                }
                .buttonStyle(.plain)
                .disabled(store.analyzerBreadcrumbIDs.isEmpty)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(store.analyzerBreadcrumbs.enumerated()), id: \.element.id) { idx, node in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            let isLast = idx == store.analyzerBreadcrumbs.count - 1
                            Button {
                                store.navigateAnalyzerBreadcrumb(to: node.id)
                            } label: {
                                Text(node.displayName)
                                    .font(.system(size: 11.5, weight: isLast ? .semibold : .medium))
                                    .foregroundStyle(isLast ? palette.primaryText : palette.secondaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(isLast ? palette.cardSelectedBackground : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
            }

            // Filter Chips & Search
            HStack(spacing: 8) {
                // Size filter menu
                Menu {
                    ForEach(DiskSizeThresholdPreset.allCases, id: \.self) { preset in
                        Button {
                            store.setAnalyzerSizePreset(preset)
                        } label: {
                            HStack {
                                Text(sizePresetTitle(preset))
                                if store.analyzerSizePreset == preset {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    filterMenuLabel(
                        title: sizePresetTitle(store.analyzerSizePreset),
                        icon: "scalemass",
                        isActive: store.analyzerSizePreset != .all
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Age filter menu
                Menu {
                    ForEach(DiskAgePreset.allCases, id: \.self) { preset in
                        Button {
                            store.setAnalyzerAgePreset(preset)
                        } label: {
                            HStack {
                                Text(agePresetTitle(preset))
                                if store.analyzerAgePreset == preset {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        store.setAnalyzerAgeBasis(.modificationDate)
                    } label: {
                        HStack {
                            Text(l10n.ageBasisModified)
                            if store.analyzerAgeBasis == .modificationDate { Image(systemName: "checkmark") }
                        }
                    }
                    Button {
                        store.setAnalyzerAgeBasis(.accessDate)
                    } label: {
                        HStack {
                            Text(l10n.ageBasisAccessed)
                            if store.analyzerAgeBasis == .accessDate { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    filterMenuLabel(
                        title: agePresetTitle(store.analyzerAgePreset),
                        icon: "clock",
                        isActive: store.analyzerAgePreset != .all
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if store.isAnalyzerFilterActive {
                    Button {
                        store.analyzerSizePreset = .all
                        store.analyzerAgePreset = .all
                        store.analyzerSearchText = ""
                        store.recomputeAnalyzerFilter()
                    } label: {
                        Text(l10n.deselectAll)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if store.isFilteringDeep {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(l10n.deepFilterActive)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                // Search field
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.tertiaryText)
                    TextField(l10n.searchPlaceholder, text: Binding(
                        get: { store.analyzerSearchText },
                        set: { newVal in
                            store.analyzerSearchText = newVal
                            store.recomputeAnalyzerFilter()
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.primaryText)
                    if !store.analyzerSearchText.isEmpty {
                        Button {
                            store.analyzerSearchText = ""
                            store.recomputeAnalyzerFilter()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 190)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        )
                )
            }
        }
    }

    private func filterMenuLabel(title: String, icon: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
        }
        .foregroundStyle(isActive ? palette.accent : palette.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? palette.accent.opacity(0.14) : palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isActive ? palette.activeBorder : palette.border, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var analyzerContentList: some View {
        if store.analyzerRootNode == nil && !store.isAnalyzing {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(palette.tertiaryText)
                Text(l10n.emptyAnalyzerTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text(l10n.emptyAnalyzerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                Button(l10n.startAnalysis) {
                    store.startSpaceAnalysis(at: store.analyzerRootURL)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                Spacer()
            }
            .padding(24)
        } else if store.isAnalyzerFilterActive {
            if store.analyzerFilteredItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(palette.tertiaryText)
                    Text(l10n.noFilteredResults)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
            } else {
                let maxBytes = max(1, store.analyzerFilteredItems.first?.bytes ?? 1)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.analyzerFilteredItems) { item in
                            analyzerFilteredRow(item, maxBytes: maxBytes)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        } else if let current = store.currentAnalyzerNode {
            let parentBytes = max(1, current.bytes)
            if current.children.isEmpty && !store.isAnalyzing {
                VStack(spacing: 8) {
                    Spacer()
                    Text(current.isTruncated ? l10n.truncatedTreeNote : l10n.emptyDirectoryLabel)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                    if current.isTruncated {
                        Button(l10n.reanalyzeHere) {
                            store.startSpaceAnalysis(at: current.url)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(current.children) { node in
                            analyzerTreeRow(node, parentBytes: parentBytes)
                        }
                        if current.isTruncated && current.truncatedChildCount > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(palette.tertiaryText)
                                Text(l10n.truncatedRemainderLabel(current.truncatedChildCount, bytes: current.unlistedChildrenBytes))
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.tertiaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func analyzerTreeRow(_ node: DiskTreeNode, parentBytes: UInt64) -> some View {
        let isSelected = store.selectedAnalyzerNodeIDs.contains(node.id)
        let isFocused = store.focusedAnalyzerNodeID == node.id
        let fraction = parentBytes > 0 ? Double(node.bytes) / Double(parentBytes) : 0
        let pctString = String(format: "%.1f%%", fraction * 100)

        return HStack(spacing: 9) {
            if node.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
            } else {
                SweepCheckbox(
                    isChecked: isSelected,
                    isDisabled: node.isSymlink,
                    palette: palette
                ) {
                    store.toggleAnalyzerSelection(node.id)
                }
            }

            AppIconView(path: node.url.path, size: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: node.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if node.isPackage {
                        miniBadge(l10n.packageBadge, color: palette.accent)
                    } else if node.isSymlink {
                        miniBadge(l10n.symlinkBadge, color: palette.secondaryText)
                    }
                    if node.isProtected {
                        miniBadge(l10n.protectedBadge, color: palette.accent)
                    }
                    if node.isUserImmutable {
                        miniBadge(l10n.userLockedBadge, color: palette.warning)
                    }
                    if !node.isAccessible {
                        miniBadge(l10n.t("无权限", "No Access"), color: palette.danger)
                    } else if node.isTruncated {
                        Button {
                            store.startSpaceAnalysis(at: node.url)
                        } label: {
                            Text(l10n.reanalyzeHere)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(palette.accent.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .help(l10n.truncatedTreeNote)
                    }
                }

                HStack(spacing: 8) {
                    ProportionalSizeBar(fraction: fraction, palette: palette)
                        .frame(maxWidth: 210)
                    Text(pctString)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(palette.tertiaryText)
                        .monospacedDigit()
                    if node.isDirectory && !node.isPackage {
                        Text(l10n.filesAndFoldersSummary(files: node.fileCount, folders: node.folderCount))
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(ByteFormatter.format(node.bytes))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()

            if node.isDirectory && !node.isPackage && !node.isSymlink && node.isAccessible {
                Button {
                    store.drillIntoAnalyzerNode(node)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused || isSelected ? palette.cardSelectedBackground : palette.cardBackground.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? palette.activeBorder : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.isDirectory && !node.isPackage && !node.isSymlink && node.isAccessible {
                store.drillIntoAnalyzerNode(node)
            } else {
                store.focusAnalyzerNode(node.url, nodeID: node.id)
                triggerQuickLook(for: node.url)
            }
        }
        .onTapGesture(count: 1) {
            store.focusAnalyzerNode(node.url, nodeID: node.id)
        }
        .contextMenu {
            Button(l10n.quickLook) {
                store.focusAnalyzerNode(node.url, nodeID: node.id)
                triggerQuickLook(for: node.url)
            }
            Button(l10n.revealInFinder) {
                state.revealInFinder(node.url)
            }
            if node.isDirectory && !node.isPackage && !node.isSymlink && node.isAccessible {
                Button(l10n.reanalyzeHere) {
                    store.startSpaceAnalysis(at: node.url)
                }
            }
            Divider()
            if !node.isProtected {
                Button(l10n.protectPath) {
                    store.protectURLs([node.url])
                }
                if !node.isSymlink {
                    Button(l10n.moveToTrash, role: .destructive) {
                        store.selectedAnalyzerNodeIDs = [node.id]
                        store.requestRemovalForAnalyzerSelection(preferredMode: .trash)
                    }
                }
            }
        }
    }

    private func analyzerFilteredRow(_ item: DiskFilteredItem, maxBytes: UInt64) -> some View {
        let isSelected = store.selectedAnalyzerNodeIDs.contains(item.id)
        let isFocused = store.focusedAnalyzerNodeID == item.id
        let fraction = maxBytes > 0 ? Double(item.bytes) / Double(maxBytes) : 0

        return HStack(spacing: 9) {
            if item.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22, height: 22)
            } else {
                SweepCheckbox(
                    isChecked: isSelected,
                    isDisabled: false,
                    palette: palette
                ) {
                    store.toggleAnalyzerSelection(item.id)
                }
            }

            AppIconView(path: item.url.path, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isProtected {
                        miniBadge(l10n.protectedBadge, color: palette.accent)
                    }
                    if item.isUserImmutable {
                        miniBadge(l10n.userLockedBadge, color: palette.warning)
                    }
                }
                HStack(spacing: 8) {
                    ProportionalSizeBar(fraction: fraction, palette: palette)
                        .frame(width: 110)
                    Text(SafeFileReader.sanitizeForDisplay(item.relativePathFromRoot))
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(l10n.formatDate(item.modificationDate))
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)

            Text(ByteFormatter.format(item.bytes))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused || isSelected ? palette.cardSelectedBackground : palette.cardBackground.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? palette.activeBorder : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.focusAnalyzerNode(item.url, nodeID: item.id)
            triggerQuickLook(for: item.url)
        }
        .onTapGesture(count: 1) {
            store.focusAnalyzerNode(item.url, nodeID: item.id)
        }
        .contextMenu {
            Button(l10n.quickLook) {
                store.focusAnalyzerNode(item.url, nodeID: item.id)
                triggerQuickLook(for: item.url)
            }
            Button(l10n.revealInFinder) {
                state.revealInFinder(item.url)
            }
            Divider()
            if !item.isProtected {
                Button(l10n.protectPath) {
                    store.protectURLs([item.url])
                }
                Button(l10n.moveToTrash, role: .destructive) {
                    store.selectedAnalyzerNodeIDs = [item.id]
                    store.requestRemovalForAnalyzerSelection(preferredMode: .trash)
                }
            }
        }
    }

    private var analyzerBottomBar: some View {
        let summary = store.selectedAnalyzerSummary
        let selectedURLs: [URL] = {
            if store.isAnalyzerFilterActive {
                return store.analyzerFilteredItems.filter { store.selectedAnalyzerNodeIDs.contains($0.id) }.map(\.url)
            }
            return (store.currentAnalyzerNode?.children ?? []).filter { store.selectedAnalyzerNodeIDs.contains($0.id) }.map(\.url)
        }()

        return HStack(spacing: 10) {
            Text(l10n.selectedSummary(count: summary.count, bytes: Int64(min(summary.bytes, UInt64(Int64.max)))))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)

            Spacer()

            Button(l10n.quickLook) {
                if let url = store.inspectedURL ?? selectedURLs.first {
                    triggerQuickLook(for: url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.inspectedURL == nil && selectedURLs.isEmpty)

            Button(l10n.revealInFinder) {
                if let url = selectedURLs.first ?? store.inspectedURL {
                    state.revealInFinder(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedURLs.isEmpty && store.inspectedURL == nil)

            Button(l10n.protectPath) {
                store.protectURLs(selectedURLs)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedURLs.isEmpty)

            Button {
                store.requestRemovalForAnalyzerSelection()
            } label: {
                Text(l10n.cleanSelected)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.danger)
            .controlSize(.small)
            .disabled(summary.count == 0 || state.isPerformingRemoval)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(palette.listBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    // MARK: - Mode 2: File Browser

    private var fileBrowserBody: some View {
        HStack(spacing: 0) {
            browserFavoritesRail
                .frame(width: 150)
                .background(palette.sidebarBackground.opacity(0.65))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(palette.border).frame(width: 1)
                }

            VStack(spacing: 0) {
                browserToolbar
                browserBreadcrumbStrip
                if let err = store.browserErrorMessage {
                    browserErrorBanner(err)
                }
                browserEntryList
                browserBottomBar
            }
            .frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)

            if store.showInspector {
                Rectangle().fill(palette.border).frame(width: 1)
                inspectorPane
                    .frame(width: 315)
            }
        }
    }

    private var browserFavoritesRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.favoritesTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(store.favorites.filter { $0.kind != .volume }) { fav in
                    favoriteRow(fav)
                }

                let volumes = store.favorites.filter { $0.kind == .volume }
                if !volumes.isEmpty {
                    Text(l10n.volumesSection)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.tertiaryText)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    ForEach(volumes) { fav in
                        favoriteRow(fav)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func favoriteRow(_ fav: FileBrowserFavorite) -> some View {
        let isActive = store.currentDirectoryURL.path == fav.url.path
        return Button {
            Task { await store.loadDirectory(fav.url, pushHistory: true) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: favoriteIcon(for: fav.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.white : palette.accent)
                    .frame(width: 16)
                Text(favoriteTitle(for: fav))
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? Color.white : (fav.isAccessible ? palette.primaryText : palette.tertiaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? palette.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var browserToolbar: some View {
        HStack(spacing: 7) {
            HStack(spacing: 3) {
                toolbarIconButton("chevron.left", help: l10n.navBack, disabled: !store.canGoBack) {
                    store.goBack()
                }
                toolbarIconButton("chevron.right", help: l10n.navForward, disabled: !store.canGoForward) {
                    store.goForward()
                }
                toolbarIconButton("chevron.up", help: l10n.navUp, disabled: !store.canGoUp) {
                    store.goUp()
                }
            }

            Button {
                store.toggleShowHiddenFiles()
            } label: {
                Image(systemName: store.showHiddenFiles ? "eye.fill" : "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.showHiddenFiles ? palette.accent : palette.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(store.showHiddenFiles ? palette.accent.opacity(0.15) : palette.cardBackground)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .help(store.showHiddenFiles ? l10n.hideHiddenFiles : l10n.showHiddenFiles)

            toolbarIconButton("folder.badge.plus", help: l10n.newFolder, disabled: store.isPerformingFileOp) {
                newFolderNameBox.value = ""
                newFolderErrorBox.value = nil
                showNewFolderSheetBox.value = true
            }

            toolbarIconButton("arrow.clockwise", help: l10n.refresh, disabled: store.isLoadingDirectory) {
                store.refreshCurrentDirectory()
            }

            Menu {
                ForEach(FileBrowserSort.allCases, id: \.self) { sort in
                    Button {
                        store.setBrowserSort(by: sort)
                    } label: {
                        HStack {
                            Text(browserSortTitle(sort))
                            if store.browserSortBy == sort {
                                Image(systemName: store.browserAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    store.setBrowserSort(by: store.browserSortBy, ascending: true)
                } label: {
                    HStack {
                        Text(l10n.sortAscending)
                        if store.browserAscending { Image(systemName: "checkmark") }
                    }
                }
                Button {
                    store.setBrowserSort(by: store.browserSortBy, ascending: false)
                } label: {
                    HStack {
                        Text(l10n.sortDescending)
                        if !store.browserAscending { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                    Text(browserSortTitle(store.browserSortBy))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(palette.cardBackground)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border, lineWidth: 1))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryText)
                TextField(l10n.searchPlaceholder, text: Binding(
                    get: { store.browserSearchText },
                    set: { newVal in
                        store.updateBrowserSearchText(newVal)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
                if !store.browserSearchText.isEmpty {
                    Button {
                        store.updateBrowserSearchText("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 100, idealWidth: 145, maxWidth: 165)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.cardBackground)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.listBackground.opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    private func toolbarIconButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? palette.tertiaryText : palette.secondaryText)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var browserBreadcrumbStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                let crumbs = store.pathBreadcrumbs
                ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                    if idx > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(palette.tertiaryText)
                    }
                    let isLast = idx == crumbs.count - 1
                    Button {
                        Task { await store.loadDirectory(crumb.url, pushHistory: true) }
                    } label: {
                        Text(crumb.title)
                            .font(.system(size: 11.5, weight: isLast ? .semibold : .medium))
                            .foregroundStyle(isLast ? palette.primaryText : palette.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isLast ? palette.cardSelectedBackground : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    private func browserErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(palette.warning)
            Text(SafeFileReader.sanitizeForDisplay(message))
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
            Spacer()
            Button(l10n.refresh) {
                store.refreshCurrentDirectory()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)

            if store.browserNeedsFDA {
                Button(l10n.folderFDAAction) {
                    state.openSystemSettings(PermissionChecker.fullDiskAccessSettingsURL)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.warning.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.warning.opacity(0.35)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var browserEntryList: some View {
        if store.isLoadingDirectory && store.browserEntries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if store.browserEntries.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(palette.tertiaryText)
                Text(l10n.emptyDirectoryLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.browserEntries) { entry in
                        browserRow(entry)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func browserRow(_ entry: FileBrowserEntry) -> some View {
        let isSelected = store.selectedBrowserEntryIDs.contains(entry.id)
        let isFocused = store.focusedBrowserEntryID == entry.id

        return HStack(spacing: 9) {
            if entry.isProtected || entry.isSIPRestricted {
                Image(systemName: entry.isSIPRestricted ? "lock.shield.fill" : "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isSIPRestricted ? palette.danger : palette.accent)
                    .frame(width: 22, height: 22)
            } else {
                SweepCheckbox(
                    isChecked: isSelected,
                    isDisabled: false,
                    palette: palette
                ) {
                    store.toggleBrowserSelection(entry, additive: true)
                }
            }

            AppIconView(path: entry.url.path, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(entry.isHidden ? palette.secondaryText : palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if entry.isSIPRestricted {
                        miniBadge(l10n.systemProtectedBadge, color: palette.danger)
                    } else if entry.isProtected {
                        miniBadge(l10n.protectedBadge, color: palette.accent)
                    }
                    if entry.isUserImmutable {
                        miniBadge(l10n.userLockedBadge, color: palette.warning)
                    }
                    if entry.isDataless {
                        miniBadge(l10n.datalessBadge, color: palette.warning)
                    }
                    if entry.isSymlinkBroken {
                        miniBadge(l10n.brokenSymlinkBadge, color: palette.danger)
                    } else if entry.isSymbolicLink {
                        miniBadge(l10n.symlinkBadge, color: palette.accent)
                    } else if entry.isPackage {
                        miniBadge(l10n.packageBadge, color: palette.secondaryText)
                    }
                }

                Text(SafeFileReader.sanitizeForDisplay(entry.kindDescription))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(l10n.formatDate(entry.modificationDate))
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
                .frame(minWidth: 80, alignment: .trailing)

            Text(entry.isDirectory && !entry.isPackage ? "--" : ByteFormatter.format(entry.sizeBytes))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isFocused || isSelected ? palette.cardSelectedBackground : palette.cardBackground.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isFocused ? palette.activeBorder : Color.clear, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory && !entry.isPackage && !entry.isSymbolicLink {
                store.openBrowserEntry(entry)
            } else {
                store.selectSingleBrowserEntry(entry)
                triggerQuickLook(for: entry.url)
            }
        }
        .onTapGesture(count: 1) {
            store.selectSingleBrowserEntry(entry)
        }
        .contextMenu {
            Button(l10n.quickLook) {
                store.selectSingleBrowserEntry(entry)
                triggerQuickLook(for: entry.url)
            }
            Button(l10n.revealInFinder) {
                state.revealInFinder(entry.url)
            }
            Divider()
            if !entry.isMutationLocked {
                Button(l10n.renameItem) {
                    beginRename(entry)
                }
                Button(l10n.moveTo) {
                    beginMove(entries: [entry])
                }
            }
            if !entry.isProtected {
                Button(l10n.protectPath) {
                    store.protectURLs([entry.url])
                }
            }
            if !entry.isProtected && !entry.isSIPRestricted {
                Divider()
                Button(l10n.moveToTrash, role: .destructive) {
                    store.requestRemovalForBrowserSelection(entries: [entry], preferredMode: .trash)
                }
                Button(l10n.deletePermanently, role: .destructive) {
                    store.requestRemovalForBrowserSelection(entries: [entry], preferredMode: .permanent)
                }
            }
        }
    }

    private var browserBottomBar: some View {
        let selected = store.selectedBrowserEntries
        let movable = selected.filter { !$0.isMutationLocked }
        let singleUnlocked = selected.count == 1 ? movable.first : nil
        let deletable = selected.filter { !$0.isProtected && !$0.isSIPRestricted }
        let protectable = selected.filter { !$0.isProtected }
        let quickLookTarget = store.inspectedURL ?? store.focusedBrowserEntry?.url

        return HStack(spacing: 6) {
            Text(l10n.selectedSummary(count: selected.count, bytes: store.selectedBrowserBytes))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button(l10n.renameItem) {
                if let entry = singleUnlocked {
                    beginRename(entry)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(singleUnlocked == nil || store.isPerformingFileOp)

            Button(l10n.moveTo) {
                beginMove(entries: movable)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(movable.isEmpty || store.isPerformingFileOp)

            Button(l10n.moveToTrash) {
                store.requestRemovalForBrowserSelection(entries: deletable, preferredMode: .trash)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .controlSize(.small)
            .disabled(deletable.isEmpty || state.isPerformingRemoval)

            Menu {
                Button {
                    if let target = quickLookTarget {
                        triggerQuickLook(for: target)
                    }
                } label: {
                    Label(l10n.quickLook, systemImage: "eye")
                }
                .disabled(quickLookTarget == nil)

                Button {
                    store.protectURLs(protectable.map(\.url))
                } label: {
                    Label(l10n.protectPath, systemImage: "lock.shield")
                }
                .disabled(protectable.isEmpty)

                Divider()

                Button(role: .destructive) {
                    store.requestRemovalForBrowserSelection(entries: deletable, preferredMode: .permanent)
                } label: {
                    Label(l10n.deletePermanently, systemImage: "trash.slash")
                }
                .disabled(deletable.isEmpty || state.isPerformingRemoval)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(palette.border, lineWidth: 1)
                            )
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n.t("更多操作", "More Actions"))
            .accessibilityLabel(l10n.t("更多操作", "More Actions"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.listBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    // MARK: - Shared Inspector

    private var inspectorPane: some View {
        FileInspectorView(
            url: store.inspectedURL,
            metadata: store.inspectedMetadata,
            previewState: store.previewState,
            isProtected: store.isInspectedURLProtected,
            protectionReason: store.inspectedProtectionReason,
            isQuickLookAllowed: !state.isDemoMode,
            palette: palette,
            l10n: l10n,
            onQuickLook: { url in triggerQuickLook(for: url) },
            onReveal: { url in state.revealInFinder(url) },
            onProtect: { url in store.protectURLs([url]) }
        )
    }

    // MARK: - Sheets

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.newFolder)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(palette.primaryText)

            Text(l10n.newFolderPrompt)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)

            TextField(l10n.folderNamePlaceholder, text: $newFolderNameBox.value)
                .textFieldStyle(.roundedBorder)

            if let err = newFolderErrorBox.value {
                Text(SafeFileReader.sanitizeForDisplay(err))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(l10n.cancel) {
                    showNewFolderSheetBox.value = false
                }
                .keyboardShortcut(.cancelAction)

                Button(l10n.createAction) {
                    let name = newFolderNameBox.value
                    Task {
                        if let err = await store.createFolder(named: name) {
                            newFolderErrorBox.value = err
                        } else {
                            showNewFolderSheetBox.value = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderNameBox.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPerformingFileOp)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(palette.detailBackground)
        .preferredColorScheme(palette.isDeepOcean ? .dark : nil)
    }

    private func renameItemSheet(for entry: FileBrowserEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.renamePrompt)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(palette.primaryText)

            Text(SafeFileReader.sanitizeForDisplay(entry.name))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            TextField(entry.name, text: $renameNameBox.value)
                .textFieldStyle(.roundedBorder)

            if let err = renameErrorBox.value {
                Text(SafeFileReader.sanitizeForDisplay(err))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(l10n.cancel) {
                    renameTargetEntryBox.value = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(l10n.renameAction) {
                    let targetName = renameNameBox.value
                    Task {
                        if let err = await store.renameEntry(entry, to: targetName) {
                            renameErrorBox.value = err
                        } else {
                            renameTargetEntryBox.value = nil
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(renameNameBox.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPerformingFileOp)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(palette.detailBackground)
        .preferredColorScheme(palette.isDeepOcean ? .dark : nil)
    }

    // MARK: - Actions & Helpers

    private func beginRename(_ entry: FileBrowserEntry) {
        renameNameBox.value = entry.name
        renameErrorBox.value = nil
        renameTargetEntryBox.value = entry
    }

    private func beginMove(entries: [FileBrowserEntry]) {
        guard !entries.isEmpty else { return }
        if let destination = chooseDirectoryPanel(title: l10n.chooseMoveDestination, initialURL: store.currentDirectoryURL) {
            Task {
                await store.moveEntries(entries, to: destination)
            }
        }
    }

    private func chooseDirectoryPanel(title: String, initialURL: URL) -> URL? {
        if state.isDemoMode {
            state.banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：请使用快捷目录或侧边栏导航", "Demo mode: use preset folders or favorites to navigate"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return nil
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = title
        panel.directoryURL = initialURL
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    private func installSpacebarMonitor() {
        spacebarMonitorBox.install(
            shouldHandle: {
                state.activeTab == .fileManager
                    && state.pendingConfirmation == nil
                    && !state.showSettingsSheet
                    && !showNewFolderSheetBox.value
                    && renameTargetEntryBox.value == nil
            },
            onTrigger: {
                if let url = store.inspectedURL {
                    triggerQuickLook(for: url)
                } else if store.mode == .fileBrowser, let first = store.selectedBrowserEntries.first {
                    triggerQuickLook(for: first.url)
                }
            }
        )
    }

    private func syncQuickLookSelection() {
        if state.isDemoMode { return }
        if let url = store.inspectedURL,
           QLPreviewPanelBridge.isEligibleForQuickLook(metadata: store.inspectedMetadata) {
            qlBridge.updateSelection(urls: [url])
        } else {
            qlBridge.updateSelection(urls: [])
        }
    }

    private func triggerQuickLook(for url: URL) {
        if state.isDemoMode {
            state.banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：已在右侧检查器展示安全预览", "Demo mode: preview displayed in Inspector"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        if let meta = store.inspectedMetadata, meta.url.path == url.standardizedFileURL.path {
            guard QLPreviewPanelBridge.isEligibleForQuickLook(metadata: meta) else { return }
            qlBridge.presentOrToggle(urls: [url])
            return
        }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        let mode = st.st_mode & S_IFMT
        let isSymlink = (mode == S_IFLNK)
        let isDataless = (st.st_flags & UInt32(SF_DATALESS)) != 0
        let isSpecial = (mode != S_IFREG && mode != S_IFDIR)
        guard QLPreviewPanelBridge.isEligibleForQuickLook(
            url: url,
            isDataless: isDataless,
            isSymlink: isSymlink,
            isSpecial: isSpecial
        ) else { return }
        qlBridge.presentOrToggle(urls: [url])
    }

    private func miniBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func sizePresetTitle(_ preset: DiskSizeThresholdPreset) -> String {
        switch preset {
        case .all: return l10n.filterAll
        case .mb50: return l10n.filterOver50MB
        case .mb100: return l10n.filterOver100MB
        case .mb500: return l10n.filterOver500MB
        case .gb1: return l10n.filterOver1GB
        }
    }

    private func agePresetTitle(_ preset: DiskAgePreset) -> String {
        switch preset {
        case .all: return l10n.filterAll
        case .days30: return l10n.t("> 30 天", "> 30 Days")
        case .days90: return l10n.filterOlder90Days
        case .days180: return l10n.filterOlder180Days
        case .days365: return l10n.filterOlder365Days
        }
    }

    private func browserSortTitle(_ sort: FileBrowserSort) -> String {
        switch sort {
        case .name: return l10n.sortByName
        case .size: return l10n.sortBySize
        case .modificationDate: return l10n.sortByModified
        case .kind: return l10n.sortByKind
        }
    }

    private func favoriteIcon(for kind: FileBrowserFavoriteKind) -> String {
        switch kind {
        case .home: return "house.fill"
        case .desktop: return "menubar.dock.rectangle"
        case .documents: return "doc.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .applications: return "square.grid.2x2.fill"
        case .caches: return "archivebox.fill"
        case .volume: return "externaldrive.fill"
        }
    }

    private func favoriteTitle(for fav: FileBrowserFavorite) -> String {
        switch fav.kind {
        case .home: return l10n.homeFolder
        case .desktop: return l10n.desktopFolder
        case .documents: return l10n.documentsFolder
        case .downloads: return l10n.downloadsFolder
        case .applications: return l10n.applicationsFolder
        case .caches: return l10n.userCachesFolder
        case .volume: return SafeFileReader.sanitizeForDisplay(fav.title)
        }
    }
}
