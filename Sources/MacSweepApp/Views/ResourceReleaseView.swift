import AppKit
import MacSweepCore
import SwiftUI

struct ResourceReleaseView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: CleanupCenterStore
    @ObservedObject var qlBridge: QLPreviewPanelBridge
    let palette: AppPalette

    @StateObject private var spacebarMonitorBox = SpacebarQuickLookMonitorBox()

    private var l10n: L10n { state.l10n }

    private var activeQuickLookURL: URL? {
        switch store.resourceSubTab {
        case .largeFiles:
            return store.inspectedLargeFileURL
        case .duplicates:
            return store.focusedDuplicateURL
        case .memory:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topModeHeader

            Group {
                switch store.resourceSubTab {
                case .largeFiles:
                    largeFilesBody
                case .duplicates:
                    duplicatesBody
                case .memory:
                    memoryBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.detailBackground)
        .task {
            await store.loadResourceTabIfNeeded()
        }
        .task(id: "\(state.activeTab.rawValue)-\(store.resourceSubTab.rawValue)-\(store.autoRefreshMemory)") {
            guard !state.isDemoMode,
                  state.activeTab == .resourceRelease,
                  store.resourceSubTab == .memory,
                  store.autoRefreshMemory else {
                return
            }
            await store.refreshMemorySnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await store.refreshMemorySnapshot()
            }
        }
        .onAppear {
            installSpacebarMonitor()
        }
        .onDisappear {
            spacebarMonitorBox.remove()
            qlBridge.updateSelection(urls: [])
        }
        .onChange(of: store.inspectedLargeFileURL) {
            syncQuickLookSelection()
        }
        .onChange(of: store.focusedDuplicateURL) {
            syncQuickLookSelection()
        }
        .alert(
            l10n.duplicateAllCopiesWarningTitle,
            isPresented: Binding(
                get: { store.pendingAllCopiesWarning != nil },
                set: { presented in
                    if !presented {
                        store.pendingAllCopiesWarning = nil
                    }
                }
            ),
            presenting: store.pendingAllCopiesWarning
        ) { _ in
            Button(l10n.duplicateKeepOneAndContinue) {
                store.confirmKeepOneCopyAndProceed()
            }
            Button(l10n.duplicateDeleteAllAnyway, role: .destructive) {
                store.confirmDeleteAllCopiesAnyway()
            }
            Button(l10n.cancel, role: .cancel) {
                store.pendingAllCopiesWarning = nil
            }
        } message: { warning in
            Text(l10n.duplicateAllCopiesWarningBody(warning.affectedGroupIDs.count))
        }
        .alert(l10n.memoryElevatedConfirmTitle, isPresented: $store.showElevatedPurgeConfirm) {
            Button(l10n.cancel, role: .cancel) {}
            Button(l10n.confirm, role: .destructive) {
                Task { await store.performElevatedPurge() }
            }
        } message: {
            Text(l10n.memoryElevatedConfirmBody)
        }
    }

    // MARK: - Top Mode Header

    private var topModeHeader: some View {
        HStack(spacing: 16) {
            Text(l10n.resourceReleaseTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Picker("", selection: $store.resourceSubTab) {
                Text(l10n.subTabLargeFiles).tag(ResourceReleaseSubTab.largeFiles)
                Text(l10n.subTabDuplicates).tag(ResourceReleaseSubTab.duplicates)
                Text(l10n.subTabMemory).tag(ResourceReleaseSubTab.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if store.resourceSubTab == .largeFiles {
                Button {
                    store.showLargeFileInspector.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 12, weight: .medium))
                        Text(l10n.toggleInspector)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(store.showLargeFileInspector ? palette.accent : palette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(store.showLargeFileInspector ? palette.accent.opacity(0.14) : palette.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(store.showLargeFileInspector ? palette.activeBorder : palette.border, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
            } else if store.resourceSubTab == .memory {
                Button {
                    Task { await store.refreshMemorySnapshot() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                        Text(l10n.refresh)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(palette.cardBackground)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.sidebarBackground.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    // MARK: - Sub-View 1: Large Files (F7)

    private var largeFilesBody: some View {
        let items = store.filteredAndSortedLargeFiles
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                largeFilesControlsBar

                if let prog = store.largeFilesProgress, store.isScanningLargeFiles {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.t("已扫描 \(prog.scannedFiles) 个文件", "\(prog.scannedFiles) files scanned"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                        Text("· \(prog.candidateFiles)")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.accent)
                            .monospacedDigit()
                        Text(verbatim: SafeFileReader.sanitizeForDisplay(prog.currentPath))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(palette.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(palette.cardBackground.opacity(0.45))
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
                }

                if let error = store.largeFilesError {
                    errorStateView(error) { store.scanLargeFiles() }
                } else if store.isScanningLargeFiles && store.largeFiles.isEmpty {
                    scanningStateView(l10n.t("正在扫描大文件...", "Scanning for large files..."))
                } else if items.isEmpty {
                    emptyStateView(
                        icon: "doc.badge.ellipsis",
                        title: l10n.largeFilesEmptyTitle,
                        subtitle: l10n.largeFilesEmptySubtitle,
                        buttonTitle: l10n.largeFilesScanAction
                    ) {
                        store.scanLargeFiles()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { item in
                                largeFileRow(item)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // Bottom Action Bar
                let moveTrashDisabled = store.selectedLargeFileCount == 0 || state.isPerformingRemoval
                HStack(spacing: 10) {
                    Text(l10n.selectedSummary(count: store.selectedLargeFileCount, bytes: Int64(store.selectedLargeFileBytes)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 6)

                    if !store.showLargeFileInspector, let focusedURL = store.inspectedLargeFileURL {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Button {
                                    triggerQuickLook(for: focusedURL)
                                } label: {
                                    Label(l10n.quickLook, systemImage: "eye")
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    state.revealInFinder(focusedURL)
                                } label: {
                                    Label(l10n.revealInFinder, systemImage: "folder")
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                if !store.isInspectedLargeFileProtected {
                                    Button {
                                        store.protectPath(focusedURL)
                                    } label: {
                                        Label(l10n.protectPath, systemImage: "shield.lefthalf.filled")
                                            .font(.system(size: 11.5))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            HStack(spacing: 6) {
                                Button {
                                    triggerQuickLook(for: focusedURL)
                                } label: {
                                    Image(systemName: "eye")
                                        .font(.system(size: 11.5))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(l10n.quickLook)

                                Button {
                                    state.revealInFinder(focusedURL)
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 11.5))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(l10n.revealInFinder)

                                if !store.isInspectedLargeFileProtected {
                                    Button {
                                        store.protectPath(focusedURL)
                                    } label: {
                                        Image(systemName: "shield.lefthalf.filled")
                                            .font(.system(size: 11.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help(l10n.protectPath)
                                }
                            }
                        }
                    }

                    Button {
                        store.requestRemovalForSelectedLargeFiles(preferredMode: .trash)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(l10n.moveToTrash)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(moveTrashDisabled ? palette.secondaryText : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(moveTrashDisabled ? palette.cardBackground : palette.accent)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(moveTrashDisabled ? palette.border : Color.clear, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(moveTrashDisabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(palette.sidebarBackground.opacity(0.75))
                .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)

            if store.showLargeFileInspector {
                Rectangle().fill(palette.border).frame(width: 1)
                FileInspectorView(
                    url: store.inspectedLargeFileURL,
                    metadata: store.inspectedLargeFileMetadata,
                    previewState: store.largeFilePreviewState,
                    isProtected: store.isInspectedLargeFileProtected,
                    protectionReason: store.inspectedLargeFileProtectionReason,
                    isQuickLookAllowed: !state.isDemoMode,
                    palette: palette,
                    l10n: l10n,
                    onQuickLook: { triggerQuickLook(for: $0) },
                    onReveal: { state.revealInFinder($0) },
                    onProtect: { store.protectPath($0) }
                )
                .frame(width: 285)
            }
        }
    }

    private var largeFilesControlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                rootPresetButton(title: l10n.homeFolder, url: state.homeDirectoryURL, activeURL: store.largeFilesRootURL) {
                    store.scanLargeFiles(at: $0)
                }
                rootPresetButton(title: l10n.downloadsFolder, url: state.homeDirectoryURL.appendingPathComponent("Downloads"), activeURL: store.largeFilesRootURL) {
                    store.scanLargeFiles(at: $0)
                }
                Button(l10n.chooseFolder) {
                    if let picked = chooseDirectoryPanel(title: l10n.chooseFolder, initialURL: store.largeFilesRootURL) {
                        store.scanLargeFiles(at: picked)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(verbatim: SafeFileReader.sanitizeForDisplay(store.largeFilesRootURL.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if store.isScanningLargeFiles {
                    Button(l10n.stopScan) {
                        store.cancelLargeFilesScan()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(l10n.largeFilesScanAction) {
                        store.scanLargeFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach([DiskSizeThresholdPreset.mb50, .mb100, .mb500, .gb1], id: \.rawValue) { preset in
                        Button(sizePresetTitle(preset)) {
                            store.largeFileMinSizePreset = preset
                            store.scanLargeFiles()
                        }
                    }
                } label: {
                    filterChipLabel(title: "\(l10n.largeFilesMinSizeLabel): \(sizePresetTitle(store.largeFileMinSizePreset))")
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)

                Menu {
                    ForEach(DiskAgePreset.allCases, id: \.rawValue) { preset in
                        Button(agePresetTitle(preset)) {
                            store.largeFileAgePreset = preset
                        }
                    }
                } label: {
                    filterChipLabel(title: agePresetTitle(store.largeFileAgePreset))
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)

                Menu {
                    ForEach(LargeFileCategoryFilter.allCases) { cat in
                        Button(largeFileCategoryFilterTitle(cat)) {
                            store.largeFileCategoryFilter = cat
                        }
                    }
                } label: {
                    filterChipLabel(title: largeFileCategoryFilterTitle(store.largeFileCategoryFilter))
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)

                Menu {
                    Button(l10n.largeFilesSortSize) { store.largeFileSortOrder = .sizeDescending }
                    Button(l10n.largeFilesSortModified) { store.largeFileSortOrder = .modifiedDescending }
                    Button(l10n.largeFilesSortName) { store.largeFileSortOrder = .nameAscending }
                } label: {
                    filterChipLabel(title: largeFileSortTitle(store.largeFileSortOrder))
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)

                Spacer()

                searchField(text: $store.largeFileSearchText)
                    .frame(minWidth: 110, idealWidth: 150, maxWidth: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.listBackground.opacity(0.65))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private func largeFileRow(_ item: LargeFileItem) -> some View {
        let isChecked = store.selectedLargeFileIDs.contains(item.id)
        let isFocused = store.focusedLargeFileID == item.id

        return HStack(spacing: 10) {
            if item.isProtected {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accent)
                    .frame(width: 18)
            } else {
                SweepCheckbox(isChecked: isChecked, isDisabled: false, palette: palette) {
                    store.toggleLargeFileSelection(item.id)
                }
            }

            AppIconView(path: item.url.path, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    miniBadge(l10n.largeFileCategoryTitle(item.category), color: palette.secondaryText)

                    if item.isUserImmutable {
                        miniBadge(l10n.userLockedBadge, color: palette.warning)
                    }
                    if item.isProtected {
                        miniBadge(l10n.protectedBadge, color: palette.accent)
                    }
                }

                Text(verbatim: SafeFileReader.sanitizeForDisplay(item.relativePathFromRoot.isEmpty ? item.url.path : item.relativePathFromRoot))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(l10n.formatDate(item.modificationDate))
                .font(.system(size: 10.5))
                .foregroundStyle(palette.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(ByteFormatter.format(item.bytes))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isFocused ? palette.cardSelectedBackground : palette.cardBackground.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isFocused ? palette.activeBorder : palette.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusLargeFile(item)
        }
        .contextMenu {
            Button(l10n.quickLook) {
                store.focusLargeFile(item)
                triggerQuickLook(for: item.url)
            }
            Button(l10n.revealInFinder) {
                state.revealInFinder(item.url)
            }
            if !item.isProtected {
                Button(l10n.protectPath) {
                    store.protectPath(item.url)
                }
            }
        }
    }

    // MARK: - Sub-View 2: Duplicate Files (F8)

    private var duplicatesBody: some View {
        let visibleGroups = store.filteredDuplicateGroups

        return VStack(spacing: 0) {
            duplicatesControlsBar

            if let prog = store.duplicateProgress, store.isScanningDuplicates {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stageLabel(prog.stage))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    if prog.totalCandidateFiles > 0 {
                        Text("\(prog.hashedFiles)/\(prog.totalCandidateFiles)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                            .monospacedDigit()
                    }
                    Text(verbatim: SafeFileReader.sanitizeForDisplay(prog.currentPath))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(palette.cardBackground.opacity(0.45))
                .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
            }

            if let error = store.duplicateError {
                errorStateView(error) { store.scanDuplicates() }
            } else if store.isScanningDuplicates && store.duplicateGroups.isEmpty {
                scanningStateView(l10n.t("正在执行三阶段重复文件扫描...", "Running 3-stage duplicate file scan..."))
            } else if visibleGroups.isEmpty {
                emptyStateView(
                    icon: "square.on.square.dashed",
                    title: l10n.duplicatesEmptyTitle,
                    subtitle: l10n.duplicatesEmptySubtitle,
                    buttonTitle: l10n.scanDuplicates
                ) {
                    store.scanDuplicates()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleGroups) { group in
                            duplicateGroupCard(group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            // Bottom Action Bar
            let cleanDupsDisabled = store.selectedDuplicateCount == 0 || state.isPerformingRemoval
            HStack(spacing: 10) {
                Text(l10n.selectedSummary(count: store.selectedDuplicateCount, bytes: Int64(store.selectedDuplicateBytes)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 6)

                smartSelectMenu
                    .disabled(store.duplicateGroups.isEmpty)

                Button {
                    store.requestRemovalForSelectedDuplicates()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(l10n.junkCleanAction)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(cleanDupsDisabled ? palette.secondaryText : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(cleanDupsDisabled ? palette.cardBackground : palette.accent)
                            .overlay(
                                Capsule()
                                    .strokeBorder(cleanDupsDisabled ? palette.border : Color.clear, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(cleanDupsDisabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.sidebarBackground.opacity(0.75))
            .overlay(alignment: .top) { Rectangle().fill(palette.border).frame(height: 1) }
        }
    }

    private var duplicatesControlsBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                rootPresetButton(title: l10n.homeFolder, url: state.homeDirectoryURL, activeURL: store.duplicateRootURL) {
                    store.scanDuplicates(at: $0)
                }
                rootPresetButton(title: l10n.downloadsFolder, url: state.homeDirectoryURL.appendingPathComponent("Downloads"), activeURL: store.duplicateRootURL) {
                    store.scanDuplicates(at: $0)
                }
                Button(l10n.chooseFolder) {
                    if let picked = chooseDirectoryPanel(title: l10n.chooseFolder, initialURL: store.duplicateRootURL) {
                        store.scanDuplicates(at: picked)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    ForEach(DuplicateMinSizePreset.allCases) { preset in
                        Button(preset.label) {
                            store.duplicateMinSizePreset = preset
                            store.scanDuplicates()
                        }
                    }
                } label: {
                    filterChipLabel(title: "\(l10n.largeFilesMinSizeLabel): \(store.duplicateMinSizePreset.label)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: true, vertical: false)

                Text(verbatim: SafeFileReader.sanitizeForDisplay(store.duplicateRootURL.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if store.isScanningDuplicates {
                    Button(l10n.stopScan) {
                        store.cancelDuplicatesScan()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(l10n.scanDuplicates) {
                        store.scanDuplicates()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statChip(label: l10n.duplicateGroupsCount(store.duplicateGroups.count), color: palette.accent)
                        statChip(label: l10n.itemCountLabel(store.totalDuplicateCopiesCount), color: palette.secondaryText)
                        statChip(label: "\(l10n.duplicateReclaimableLabel): \(ByteFormatter.format(store.totalDuplicateReclaimableBytes))", color: palette.warning)
                    }
                    HStack(spacing: 8) {
                        statChip(label: l10n.duplicateGroupsCount(store.duplicateGroups.count), color: palette.accent)
                        statChip(label: ByteFormatter.format(store.totalDuplicateReclaimableBytes), color: palette.warning)
                    }
                }

                Spacer()

                smartSelectMenu
                    .disabled(store.duplicateGroups.isEmpty)

                searchField(text: $store.duplicateSearchText)
                    .frame(minWidth: 120, idealWidth: 170, maxWidth: 210)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(palette.listBackground.opacity(0.65))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private var smartSelectMenu: some View {
        Menu {
            Button(l10n.duplicatePreferNonDownloads) {
                store.applyDuplicateSelectionPreset(.preferNonDownloads)
            }
            Button(l10n.duplicateKeepNewest) {
                store.applyDuplicateSelectionPreset(.keepNewest)
            }
            Button(l10n.duplicateKeepOldest) {
                store.applyDuplicateSelectionPreset(.keepOldest)
            }
            Button(l10n.duplicateKeepShortestPath) {
                store.applyDuplicateSelectionPreset(.keepShortestPath)
            }
            Divider()
            Button(l10n.duplicateClearSelection) {
                store.applyDuplicateSelectionPreset(.clearAll)
            }
        } label: {
            Label(l10n.duplicateSmartSelect, systemImage: "wand.and.rays")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardBackground)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func duplicateGroupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: "SHA-256 \(group.sha256Hex.prefix(12))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(palette.accent.opacity(0.14)))

                Text(l10n.itemCountLabel(group.files.count))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText)

                Text("· \(ByteFormatter.format(group.fileSize))")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()

                if group.allCopiesSelected {
                    miniBadge(l10n.duplicateAllCopiesBadge, color: palette.danger)
                }

                Spacer()

                Text("\(l10n.duplicateReclaimableLabel): \(ByteFormatter.format(group.reclaimableBytes))")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.warning)
                    .monospacedDigit()
            }

            VStack(spacing: 5) {
                ForEach(group.files) { entry in
                    duplicateEntryRow(entry, groupID: group.id)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(palette.cardBackground.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(group.allCopiesSelected ? palette.danger.opacity(0.55) : palette.border, lineWidth: 1)
                )
        )
    }

    private func duplicateEntryRow(_ entry: DuplicateFileEntry, groupID: String) -> some View {
        let isFocused = store.focusedDuplicateURL?.path == entry.url.path
        return HStack(spacing: 9) {
            if entry.isProtected {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accent)
                    .frame(width: 18)
            } else {
                SweepCheckbox(isChecked: entry.isSelected, isDisabled: false, palette: palette) {
                    store.toggleDuplicateEntry(groupID: groupID, entryID: entry.id)
                }
            }

            AppIconView(path: entry.url.path, size: 20)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    miniBadge(
                        entry.isSelected ? l10n.duplicateDeleteLabel : l10n.duplicateKeepLabel,
                        color: entry.isSelected ? palette.danger : palette.success
                    )
                    if entry.isUserImmutable {
                        miniBadge(l10n.userLockedBadge, color: palette.warning)
                    }
                    if entry.isProtected {
                        miniBadge(l10n.protectedBadge, color: palette.accent)
                    }
                }

                Text(verbatim: SafeFileReader.sanitizeForDisplay(entry.url.path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Text(l10n.formatDate(entry.modificationDate))
                .font(.system(size: 10.5))
                .foregroundStyle(palette.tertiaryText)
                .fixedSize(horizontal: true, vertical: false)

            Button {
                store.focusedDuplicateURL = entry.url
                triggerQuickLook(for: entry.url)
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardBackground))
            }
            .buttonStyle(.plain)
            .help("\(l10n.quickLook) (Space)")

            Button {
                state.revealInFinder(entry.url)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondaryText)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardBackground))
            }
            .buttonStyle(.plain)
            .help(l10n.revealInFinder)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? palette.cardSelectedBackground : palette.sidebarBackground.opacity(0.45))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusedDuplicateURL = entry.url
        }
        .contextMenu {
            Button(l10n.quickLook) {
                store.focusedDuplicateURL = entry.url
                triggerQuickLook(for: entry.url)
            }
            Button(l10n.revealInFinder) {
                state.revealInFinder(entry.url)
            }
            Button(l10n.keepOnlyThisCopy) {
                store.keepOnlyDuplicateEntry(groupID: groupID, entryID: entry.id)
            }
            if !entry.isProtected {
                Button(l10n.protectPath) {
                    store.protectPath(entry.url)
                }
            }
        }
    }

    // MARK: - Sub-View 3: RAM & Memory (F9)

    private var memoryBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let snap = store.memorySnapshot {
                    // Status Header
                    HStack(spacing: 12) {
                        Text("\(l10n.memoryPhysicalTotal): \(ByteFormatter.formatMemory(snap.totalBytes))")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .monospacedDigit()

                        Text("\(l10n.memoryUsedLabel): \(ByteFormatter.formatMemory(snap.usedBytes))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                            .monospacedDigit()

                        pressureBadge(snap.pressureLevel)

                        Spacer()

                        Toggle(l10n.memoryAutoRefresh, isOn: $store.autoRefreshMemory)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                    }

                    // Segmented Bar Card
                    memoryPressureBarCard(snap)

                    // 6-Tile Breakdown Grid
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                        spacing: 10
                    ) {
                        memoryTile(title: l10n.memoryActive, bytes: snap.activeBytes, total: snap.totalBytes, color: palette.accent)
                        memoryTile(title: l10n.memoryWired, bytes: snap.wiredBytes, total: snap.totalBytes, color: palette.warning)
                        memoryTile(title: l10n.memoryCompressed, bytes: snap.compressedBytes, total: snap.totalBytes, color: Color.purple)
                        memoryTile(title: l10n.memoryCachedFiles, bytes: snap.cachedFilesBytes, total: snap.totalBytes, color: palette.success)
                        memoryTile(title: l10n.memoryFree, bytes: snap.freeBytes, total: snap.totalBytes, color: palette.secondaryText)
                        swapTile(used: snap.swapUsedBytes, total: snap.swapTotalBytes)
                    }

                    // Honest Memory Release Action Card
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.memoryHonestDisclaimer)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Button {
                                Task { await store.performStandardPressureRelief() }
                            } label: {
                                HStack(spacing: 6) {
                                    if store.isReleasingMemory {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "waveform.path.ecg")
                                    }
                                    Text(l10n.memoryStandardRelief)
                                        .font(.system(size: 12.5, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isReleasingMemory)

                            Button {
                                store.showElevatedPurgeConfirm = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.shield")
                                    Text(l10n.memoryElevatedPurge)
                                        .font(.system(size: 12.5, weight: .medium))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isReleasingMemory)

                            Spacer()
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(palette.cardBackground.opacity(0.62))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                    )

                    // Before / After Comparison Card
                    if let res = store.lastMemoryReleaseResult {
                        memoryResultCard(res)
                    }
                } else {
                    VStack(spacing: 10) {
                        Spacer()
                        ProgressView()
                        Text(l10n.t("正在读取 Mach 内存采样...", "Sampling Mach VM statistics..."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(18)
        }
    }

    private func memoryPressureBarCard(_ snap: MemorySnapshot) -> some View {
        let denom = Double(max(1, snap.totalBytes))
        let appFrac = min(1.0, Double(snap.appMemoryBytes) / denom)
        let wiredFrac = min(max(0, 1.0 - appFrac), Double(snap.wiredBytes) / denom)
        let compFrac = min(max(0, 1.0 - appFrac - wiredFrac), Double(snap.compressedBytes) / denom)
        let cacheFrac = min(max(0, 1.0 - appFrac - wiredFrac - compFrac), Double(snap.cachedFilesBytes) / denom)

        return VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let w = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.sidebarBackground.opacity(0.9))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.border, lineWidth: 1))

                    HStack(spacing: 0) {
                        Rectangle().fill(palette.accent).frame(width: w * CGFloat(appFrac))
                        Rectangle().fill(palette.warning).frame(width: w * CGFloat(wiredFrac))
                        Rectangle().fill(Color.purple.opacity(0.85)).frame(width: w * CGFloat(compFrac))
                        Rectangle().fill(palette.success.opacity(0.75)).frame(width: w * CGFloat(cacheFrac))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .frame(height: 14)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statChip(label: "\(l10n.memoryAppMemory): \(ByteFormatter.formatMemory(snap.appMemoryBytes))", color: palette.accent)
                    statChip(label: "\(l10n.memoryWired): \(ByteFormatter.formatMemory(snap.wiredBytes))", color: palette.warning)
                    statChip(label: "\(l10n.memoryCompressed): \(ByteFormatter.formatMemory(snap.compressedBytes))", color: Color.purple)
                    statChip(label: "\(l10n.memoryCachedFiles): \(ByteFormatter.formatMemory(snap.cachedFilesBytes))", color: palette.success)
                    statChip(label: "\(l10n.memoryFree): \(ByteFormatter.formatMemory(snap.freeBytes))", color: palette.secondaryText)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        statChip(label: "\(l10n.memoryAppMemory): \(ByteFormatter.formatMemory(snap.appMemoryBytes))", color: palette.accent)
                        statChip(label: "\(l10n.memoryWired): \(ByteFormatter.formatMemory(snap.wiredBytes))", color: palette.warning)
                        statChip(label: "\(l10n.memoryCompressed): \(ByteFormatter.formatMemory(snap.compressedBytes))", color: Color.purple)
                    }
                    HStack(spacing: 12) {
                        statChip(label: "\(l10n.memoryCachedFiles): \(ByteFormatter.formatMemory(snap.cachedFilesBytes))", color: palette.success)
                        statChip(label: "\(l10n.memoryFree): \(ByteFormatter.formatMemory(snap.freeBytes))", color: palette.secondaryText)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(palette.cardBackground.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        )
    }

    private func memoryTile(title: String, bytes: UInt64, total: UInt64, color: Color) -> some View {
        let pct = total > 0 ? (Double(bytes) / Double(total)) * 100.0 : 0.0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text(String(format: "%.1f%%", pct))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
                    .monospacedDigit()
            }
            Text(ByteFormatter.formatMemory(bytes))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        )
    }

    private func swapTile(used: UInt64, total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(palette.tertiaryText).frame(width: 7, height: 7)
                Text(l10n.memorySwap)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if total > 0 {
                    Text("/ \(ByteFormatter.formatMemory(total))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(palette.tertiaryText)
                        .monospacedDigit()
                }
            }
            Text(ByteFormatter.formatMemory(used))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        )
    }

    private func memoryResultCard(_ res: MemoryReleaseResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.success)
                Text(res.usedElevation ? l10n.memoryElevatedPurge : l10n.memoryStandardRelief)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                miniBadge(res.methodUsed, color: palette.accent)
                Spacer()
                Text("\(l10n.memoryReclaimedLabel): +\(ByteFormatter.formatMemory(res.reclaimedEstimateBytes))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.success)
                    .monospacedDigit()
            }

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.memoryBeforeLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.tertiaryText)
                    Text("\(l10n.memoryFree): \(ByteFormatter.formatMemory(res.before.freeBytes)) · \(l10n.memoryCachedFiles): \(ByteFormatter.formatMemory(res.before.cachedFilesBytes))")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.memoryAfterLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.tertiaryText)
                    Text("\(l10n.memoryFree): \(ByteFormatter.formatMemory(res.after.freeBytes)) · \(l10n.memoryCachedFiles): \(ByteFormatter.formatMemory(res.after.cachedFilesBytes))")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .monospacedDigit()
                }
            }

            Text(verbatim: res.note)
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(palette.success.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(palette.success.opacity(0.35), lineWidth: 1))
        )
    }

    private func pressureBadge(_ level: MemoryPressureLevel) -> some View {
        let color: Color
        let text: String
        switch level {
        case .normal:
            color = palette.success
            text = l10n.memoryPressureNormal
        case .warning:
            color = palette.warning
            text = l10n.memoryPressureWarning
        case .critical:
            color = palette.danger
            text = l10n.memoryPressureCritical
        }
        return miniBadge("\(l10n.memoryPressureLabel): \(text)", color: color)
    }

    // MARK: - Shared UI Helpers

    private func rootPresetButton(
        title: String,
        url: URL,
        activeURL: URL,
        action: @escaping (URL) -> Void
    ) -> some View {
        let active = activeURL.standardizedFileURL.path == url.standardizedFileURL.path
        return Button {
            action(url)
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .white : palette.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(active ? palette.accent : palette.cardBackground))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func filterChipLabel(title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        )
    }

    private func statChip(label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
            TextField(l10n.searchPlaceholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(palette.cardBackground.opacity(0.65))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        )
    }

    private func scanningStateView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorStateView(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(palette.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(l10n.refresh, action: retry)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateView(
        icon: String,
        title: String,
        subtitle: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.accent)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func miniBadge(_ title: String, color: Color) -> some View {
        Text(verbatim: title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.15)))
            .fixedSize(horizontal: true, vertical: false)
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

    private func largeFileCategoryFilterTitle(_ filter: LargeFileCategoryFilter) -> String {
        switch filter {
        case .all: return l10n.largeFilesCategoryAll
        case .video: return l10n.largeFilesCatVideo
        case .archiveOrDiskImage: return l10n.largeFilesCatArchive
        case .installer: return l10n.largeFilesCatInstaller
        case .audio: return l10n.largeFilesCatAudio
        case .document: return l10n.largeFilesCatDocument
        case .other: return l10n.largeFilesCatOther
        }
    }

    private func largeFileSortTitle(_ order: LargeFileSortOrder) -> String {
        switch order {
        case .sizeDescending: return l10n.largeFilesSortSize
        case .modifiedDescending: return l10n.largeFilesSortModified
        case .nameAscending: return l10n.largeFilesSortName
        }
    }

    private func stageLabel(_ stage: ResourceScanStage) -> String {
        switch stage {
        case .largeFiles: return l10n.largeFilesScanAction
        case .duplicatesSizeGrouping: return l10n.duplicateStageSize
        case .duplicatesPartialHash: return l10n.duplicateStagePartialHash
        case .duplicatesFullHash: return l10n.duplicateStageFullHash
        }
    }

    private func chooseDirectoryPanel(title: String, initialURL: URL) -> URL? {
        if state.isDemoMode {
            state.banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：请使用上方快捷目录", "Demo mode: use preset folder buttons"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return nil
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = title
        panel.directoryURL = initialURL
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    // MARK: - QuickLook Helpers

    private func syncQuickLookSelection() {
        if state.isDemoMode { return }
        if let url = activeQuickLookURL, isQuickLookEligible(url) {
            qlBridge.updateSelection(urls: [url])
        } else {
            qlBridge.updateSelection(urls: [])
        }
    }

    private func isQuickLookEligible(_ url: URL) -> Bool {
        if state.isDemoMode { return false }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let mode = st.st_mode & S_IFMT
        let isSymlink = (mode == S_IFLNK)
        let isDataless = (st.st_flags & UInt32(SF_DATALESS)) != 0
        let isSpecial = (mode != S_IFREG && mode != S_IFDIR)
        return QLPreviewPanelBridge.isEligibleForQuickLook(
            url: url,
            isDataless: isDataless,
            isSymlink: isSymlink,
            isSpecial: isSpecial
        )
    }

    private func triggerQuickLook(for url: URL) {
        if state.isDemoMode {
            state.banner = OperationBanner(
                isError: false,
                message: l10n.t(
                    "演示模式：QuickLook 预览仅作用于真实磁盘文件（\(url.lastPathComponent)）",
                    "Demo mode: QuickLook preview is disabled for synthetic fixture paths (\(url.lastPathComponent))"
                ),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        guard isQuickLookEligible(url) else { return }
        qlBridge.presentOrToggle(urls: [url])
    }

    private func installSpacebarMonitor() {
        spacebarMonitorBox.install(
            shouldHandle: {
                state.activeTab == .resourceRelease
                    && store.resourceSubTab != .memory
                    && state.pendingConfirmation == nil
                    && !state.showSettingsSheet
            },
            onTrigger: {
                if let url = activeQuickLookURL {
                    triggerQuickLook(for: url)
                }
            }
        )
    }
}
