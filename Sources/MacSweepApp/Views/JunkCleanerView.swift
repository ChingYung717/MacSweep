import AppKit
import MacSweepCore
import SwiftUI

struct JunkCleanerView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: CleanupCenterStore
    @ObservedObject var qlBridge: QLPreviewPanelBridge
    let palette: AppPalette

    @StateObject private var spacebarMonitorBox = SpacebarQuickLookMonitorBox()

    private var l10n: L10n { state.l10n }

    private var activeCategory: JunkCategoryItem? {
        store.activeJunkCategory
    }

    private var focusedEntry: JunkEntry? {
        guard let cat = activeCategory, let id = store.focusedJunkEntryID else { return nil }
        return cat.entries.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 376)
                .background(palette.listBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(palette.border).frame(width: 1)
                }

            detailPane
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.detailBackground)
        }
        .task {
            await store.loadJunkIfNeeded()
        }
        .onAppear {
            installSpacebarMonitor()
        }
        .onDisappear {
            spacebarMonitorBox.remove()
            qlBridge.updateSelection(urls: [])
        }
        .onChange(of: store.focusedJunkEntryID) {
            if let entry = focusedEntry, isQuickLookEligible(entry.url) {
                qlBridge.updateSelection(urls: [entry.url])
            } else {
                qlBridge.updateSelection(urls: [])
            }
        }
    }

    // MARK: - Left Category Pane

    private var leftPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(l10n.tabJunkCleaner)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)

                Spacer()

                if store.isScanningJunk {
                    ProgressView()
                        .controlSize(.small)
                    Button(l10n.stopScan) {
                        store.cancelJunkScan()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else {
                    Button {
                        store.scanJunk()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.refresh)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Summary Pill Card
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(ByteFormatter.format(store.totalVisibleJunkDiscoveredBytes))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .monospacedDigit()
                    Spacer()
                    Button(l10n.junkSafeSelect) {
                        store.selectRecommendedSafeJunk()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(store.junkCategories.isEmpty)

                    Button(l10n.junkClearAll) {
                        store.clearAllJunkSelections()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .disabled(store.selectedJunkCount == 0)
                }
                if let progText = store.junkScanProgressText, store.isScanningJunk {
                    Text(verbatim: progText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(l10n.selectedSummary(count: store.selectedJunkCount, bytes: Int64(store.selectedJunkBytes)))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.cardBackground.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // FDA Callout
            if store.junkNeedsFDA {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(palette.warning)
                        Text(l10n.t("部分浏览器缓存需要完全磁盘访问权限", "Some browser caches require Full Disk Access"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                    }
                    if !store.junkBlockedBrowserNames.isEmpty {
                        Text(store.junkBlockedBrowserNames.joined(separator: ", "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Button(l10n.openSettings) {
                            state.openSystemSettings(PermissionChecker.fullDiskAccessSettingsURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                        Button(l10n.t("重扫", "Rescan")) {
                            state.refreshPermissionStatus()
                            store.scanJunk()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.warning.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.warning.opacity(0.35), lineWidth: 1))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            // Search box & Hidden Files toggle
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                    TextField(l10n.searchPlaceholder, text: $store.junkSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.primaryText)
                    if !store.junkSearchText.isEmpty {
                        Button { store.junkSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(palette.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(palette.cardBackground.opacity(0.65))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                )

                Button {
                    store.toggleJunkIncludeHidden()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.junkIncludeHidden ? "eye.fill" : "eye.slash")
                            .font(.system(size: 10.5))
                        Text(l10n.hiddenFilesChipLabel)
                            .font(.system(size: 11, weight: store.junkIncludeHidden ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(store.junkIncludeHidden ? palette.accent : palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(store.junkIncludeHidden ? palette.accent.opacity(0.14) : palette.cardBackground.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(store.junkIncludeHidden ? palette.activeBorder : palette.border, lineWidth: 1)
                            )
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .help(l10n.junkHiddenFilesHelp)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Categories
            if store.isScanningJunk && store.junkCategories.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text(l10n.t("正在安全扫描缓存与系统垃圾...", "Scanning caches and system junk..."))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.junkCategories) { cat in
                            categoryRow(cat)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func categoryRow(_ cat: JunkCategoryItem) -> some View {
        let isSelected = activeCategory?.id == cat.id
        let hasSelected = cat.selectedCount > 0
        let visibleEntries = store.visibleEntries(for: cat)
        let visibleBytes = store.visibleBytes(for: cat)
        let allUnselectable = visibleEntries.allSatisfy { $0.isProtected || $0.isRunningAppBlocked }

        return HStack(spacing: 7) {
            SweepCheckbox(
                isChecked: hasSelected,
                isDisabled: visibleEntries.isEmpty || allUnselectable,
                palette: palette
            ) {
                store.toggleJunkCategory(categoryID: cat.id, selected: !hasSelected)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.accent.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: iconName(for: cat.category))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(l10n.junkCategoryTitle(cat.category))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if cat.requiresAdmin {
                        miniBadge(l10n.adminBadge, color: palette.warning)
                    }
                }
                Text(l10n.itemCountLabel(visibleEntries.count))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryText)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatter.format(visibleBytes))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if cat.selectedBytes > 0 {
                    Text(ByteFormatter.format(cat.selectedBytes))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.accent)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? palette.cardSelectedBackground : palette.cardBackground.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? palette.activeBorder : palette.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedJunkCategoryID = cat.id
            store.focusedJunkEntryID = cat.entries.first?.id
        }
    }

    // MARK: - Right Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            if let error = store.junkError {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.danger)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    Button(l10n.refresh) {
                        store.scanJunk()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding()
            } else if let cat = activeCategory {
                let visibleEntries = store.filteredEntries(for: cat)

                // Category Header Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(l10n.junkCategoryTitle(cat.category))
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(palette.primaryText)
                            Text(l10n.junkCategoryDescription(cat.category))
                                .font(.system(size: 12))
                                .foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        Button(l10n.selectAll) {
                            store.toggleJunkCategory(categoryID: cat.id, selected: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(visibleEntries.isEmpty)

                        Button(l10n.deselectAll) {
                            store.toggleJunkCategory(categoryID: cat.id, selected: false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(cat.selectedCount == 0)
                    }

                    // Safety Note Banner
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accent)
                            .padding(.top, 1)
                        Text(l10n.junkCategorySafetyNote(cat.category))
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.accent.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(palette.accent.opacity(0.25), lineWidth: 1)
                            )
                    )
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

                if visibleEntries.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "sparkles")
                            .font(.system(size: 34))
                            .foregroundStyle(palette.success)
                        Text(l10n.junkAllCleanTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text(l10n.junkAllCleanSubtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(visibleEntries) { entry in
                                junkEntryRow(entry, categoryID: cat.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                    }
                }

                // Bottom Sticky Action Bar
                let cleanJunkDisabled = store.selectedJunkCount == 0 || state.isPerformingRemoval
                HStack(spacing: 10) {
                    Text(l10n.selectedSummary(count: store.selectedJunkCount, bytes: Int64(store.selectedJunkBytes)))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 6)

                    if let focused = focusedEntry {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Button {
                                    triggerQuickLook(for: focused.url)
                                } label: {
                                    Label(l10n.quickLook, systemImage: "eye")
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Button {
                                    state.revealInFinder(focused.url)
                                } label: {
                                    Label(l10n.revealInFinder, systemImage: "folder")
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }
                            HStack(spacing: 6) {
                                Button {
                                    triggerQuickLook(for: focused.url)
                                } label: {
                                    Image(systemName: "eye")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help(l10n.quickLook)

                                Button {
                                    state.revealInFinder(focused.url)
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .help(l10n.revealInFinder)
                            }
                        }
                    }

                    Button {
                        store.requestRemovalForSelectedJunk()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(l10n.junkCleanAction)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(cleanJunkDisabled ? palette.secondaryText : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(
                                    cleanJunkDisabled
                                        ? AnyShapeStyle(palette.cardBackground)
                                        : AnyShapeStyle(LinearGradient(
                                            colors: [palette.accent, palette.accent.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(cleanJunkDisabled ? palette.border : Color.clear, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(cleanJunkDisabled)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.sidebarBackground.opacity(0.75))
                .overlay(alignment: .top) {
                    Rectangle().fill(palette.border).frame(height: 1)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(palette.accent)
                    Text(l10n.junkEmptyPromptTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(l10n.junkEmptyPromptSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button(l10n.junkScanAction) {
                        store.scanJunk()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding()
            }
        }
    }

    private func junkEntryRow(_ entry: JunkEntry, categoryID: String) -> some View {
        let isFocused = store.focusedJunkEntryID == entry.id
        let isDisabled = entry.isProtected || entry.isRunningAppBlocked

        return HStack(spacing: 10) {
            if entry.isProtected {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.accent)
                    .frame(width: 18)
            } else {
                SweepCheckbox(
                    isChecked: entry.isSelected,
                    isDisabled: isDisabled,
                    palette: palette
                ) {
                    store.toggleJunkEntry(categoryID: categoryID, entryID: entry.id)
                }
            }

            AppIconView(path: entry.url.path, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(entry.isHidden ? palette.secondaryText : palette.primaryText)
                        .lineLimit(1)

                    if entry.isHidden {
                        miniBadge(l10n.hiddenBadge, color: palette.secondaryText)
                    }
                    if let subgroup = entry.subgroup, !subgroup.isEmpty {
                        miniBadge(SafeFileReader.sanitizeForDisplay(subgroup), color: palette.secondaryText)
                    }
                    if entry.isRunningAppBlocked {
                        miniBadge(l10n.junkRunningAppBlocked, color: palette.warning)
                    }
                    if entry.requiresAdmin {
                        miniBadge(l10n.adminBadge, color: palette.warning)
                    }
                    if entry.isProtected {
                        miniBadge(l10n.protectedBadge, color: palette.accent)
                    }
                    if entry.isUserImmutable {
                        miniBadge(l10n.userLockedBadge, color: palette.warning)
                    }
                }

                Text(verbatim: SafeFileReader.sanitizeForDisplay(entry.url.path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Button {
                    store.focusedJunkEntryID = entry.id
                    triggerQuickLook(for: entry.url)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
                }
                .buttonStyle(.plain)
                .help("\(l10n.quickLook) (Space)")

                Button {
                    state.revealInFinder(entry.url)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
                }
                .buttonStyle(.plain)
                .help(l10n.revealInFinder)
            }

            Text(ByteFormatter.format(entry.bytes))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .frame(minWidth: 66, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
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
            store.focusedJunkEntryID = entry.id
        }
        .contextMenu {
            Button(l10n.quickLook) {
                store.focusedJunkEntryID = entry.id
                triggerQuickLook(for: entry.url)
            }
            Button(l10n.revealInFinder) {
                state.revealInFinder(entry.url)
            }
            if !entry.isProtected {
                Button(l10n.protectPath) {
                    store.protectPath(entry.url)
                }
            }
        }
    }

    // MARK: - Helpers

    private func iconName(for category: JunkCategory) -> String {
        switch category {
        case .userCaches: return "archivebox.fill"
        case .logs: return "doc.text.fill"
        case .browserCaches: return "globe"
        case .developerCaches: return "hammer.fill"
        case .trash: return "trash.fill"
        }
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
                state.activeTab == .junkCleaner
                    && state.pendingConfirmation == nil
                    && !state.showSettingsSheet
            },
            onTrigger: {
                if let entry = focusedEntry {
                    triggerQuickLook(for: entry.url)
                }
            }
        )
    }
}
