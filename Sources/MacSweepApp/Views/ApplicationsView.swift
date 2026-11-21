import MacSweepCore
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationsView: View {
    @ObservedObject var state: AppState
    let palette: AppPalette

    @StateObject private var collapsedBucketsBox = LocalState<Set<AppSizeBucket>>([])
    @StateObject private var collapsedCategoriesBox = LocalState<Set<ServiceFileCategory>>([])
    @StateObject private var dropOverDetailBox = LocalState(false)

    private var l10n: L10n { state.l10n }

    var body: some View {
        HStack(spacing: 0) {
            middleListPane
                .frame(width: 345)
                .background(palette.listBackground)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(palette.border)
                        .frame(width: 1)
                }

            rightDetailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.detailBackground)
                .onDrop(of: [.fileURL], isTargeted: $dropOverDetailBox.value) { providers in
                    handleDrop(providers: providers)
                }
        }
    }

    // MARK: - Middle List Column

    private var middleListPane: some View {
        VStack(spacing: 0) {
            // Top bar aligned with traffic lights
            HStack {
                Text("MacSweep")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button {
                    Task { await state.scanApplications() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .rotationEffect(.degrees(state.isScanningApps ? 360 : 0))
                        .animation(
                            state.isScanningApps ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: state.isScanningApps
                        )
                }
                .buttonStyle(.plain)
                .help(l10n.refresh)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search + Sort Bar (matching screenshot)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                    TextField(l10n.searchPlaceholder, text: $state.appSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.primaryText)
                    if !state.appSearchText.isEmpty {
                        Button {
                            state.appSearchText = ""
                        } label: {
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        )
                )

                Menu {
                    ForEach(AppSortOrder.allCases) { order in
                        Button {
                            state.appSortOrder = order
                        } label: {
                            HStack {
                                Text(sortTitle(order))
                                if state.appSortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(sortTitle(state.appSortOrder))
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            // App list (grouped by size buckets when sorted by size, flat otherwise)
            if state.isScanningApps && state.apps.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text(l10n.scanningServiceFiles)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        if state.appSortOrder == .size {
                            let grouped = groupedApps(state.filteredAndSortedApps)
                            ForEach(grouped, id: \.bucket) { group in
                                bucketHeader(bucket: group.bucket, count: group.items.count)
                                if !collapsedBucketsBox.value.contains(group.bucket) {
                                    ForEach(group.items) { app in
                                        appCardRow(app)
                                    }
                                }
                            }
                        } else {
                            ForEach(state.filteredAndSortedApps) { app in
                                appCardRow(app)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            // Bottom List Footer
            HStack(spacing: 10) {
                Text(l10n.totalAppsCount(state.filteredAndSortedApps.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryText)

                if state.isCalculatingSizes {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }

                Spacer()

                if !state.checkedApps.isEmpty {
                    Button(l10n.deselectAll) {
                        for i in state.apps.indices {
                            state.apps[i].isChecked = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.border).frame(height: 1)
            }
        }
    }

    private func bucketHeader(bucket: AppSizeBucket, count: Int) -> some View {
        let isCollapsed = collapsedBucketsBox.value.contains(bucket)
        return Button {
            if isCollapsed {
                collapsedBucketsBox.value.remove(bucket)
            } else {
                collapsedBucketsBox.value.insert(bucket)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 12)
                Text(l10n.bucketTitle(bucket))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.cardBackground.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func appCardRow(_ app: AppItem) -> some View {
        let isSelected = (state.selectedAppID == app.id && state.droppedApp == nil)
        return HStack(spacing: 10) {
            if app.isSystemProtected || app.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiaryText)
                    .frame(width: 22, height: 22)
                    .help(app.isSystemProtected ? l10n.systemProtectedBadge : l10n.protectedBadge)
            } else {
                SweepCheckbox(
                    isChecked: app.isChecked,
                    isDisabled: !app.canUninstall,
                    palette: palette
                ) {
                    state.toggleAppChecked(app.id)
                }
            }

            AppIconView(path: app.url.path, size: 34)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Text(app.localizedName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if app.isRunning {
                        Circle()
                            .fill(palette.success)
                            .frame(width: 6.5, height: 6.5)
                            .help(l10n.runningBadge)
                    }

                    if app.sharesBundleIDWithOtherApp {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 9.5))
                            .foregroundStyle(palette.warning)
                            .help(l10n.t("与其他已安装应用共享 Bundle ID", "Shares its bundle ID with another installed app"))
                    }

                    if app.isAppleAppStoreApp {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 9.5))
                            .foregroundStyle(palette.secondaryText)
                            .help(l10n.appleStoreWarning)
                    }
                }

                Text(l10n.formatDate(app.displayDate))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let total = app.totalSize {
                Text(ByteFormatter.format(total))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? palette.primaryText : palette.secondaryText)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
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
            state.selectApp(id: app.id)
        }
    }

    // MARK: - Right Detail Pane

    @ViewBuilder
    private var rightDetailPane: some View {
        let checked = state.checkedApps
        if checked.count >= 2 && state.droppedApp == nil {
            batchSummaryDetailPane(apps: checked)
        } else if let app = state.activeDetailApp {
            singleAppDetailPane(app: app)
        } else {
            DropZoneHeroView(
                isScanning: state.isScanningApps || state.isCalculatingSizes,
                palette: palette,
                l10n: l10n
            ) { url in
                state.inspectDroppedApp(at: url)
            }
        }
    }

    private func singleAppDetailPane(app: AppItem) -> some View {
        let isReset = (state.appActionMode == .reset)
        let selectedServiceFiles = app.serviceFiles.filter(\.isSelected)
        let selectedCount = selectedServiceFiles.count + (!isReset && state.includeAppBundleInRemoval && app.canUninstall ? 1 : 0)
        let selectedBytes = selectedServiceFiles.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            + (!isReset && state.includeAppBundleInRemoval && app.canUninstall ? (app.bundleSize ?? 0) : 0)

        return VStack(spacing: 0) {
            // App Detail Header Card
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    AppIconView(path: app.url.path, size: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(app.localizedName)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(palette.primaryText)

                            if !app.version.isEmpty {
                                Text("v\(app.version)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(palette.secondaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.cardBackground))
                            }

                            if app.isRunning {
                                HStack(spacing: 4) {
                                    Circle().fill(palette.success).frame(width: 6, height: 6)
                                    Text(l10n.runningBadge)
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.success)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.success.opacity(0.16)))
                            }

                            if app.isSystemProtected {
                                Label(l10n.systemProtectedBadge, systemImage: "lock.shield.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(palette.warning)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.warning.opacity(0.16)))
                            }
                        }

                        Text(app.bundleID)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)

                        HStack(spacing: 12) {
                            Button {
                                state.revealInFinder(app.url)
                            } label: {
                                Label(app.url.path, systemImage: "folder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            if let total = app.totalSize {
                                Text(ByteFormatter.format(total))
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(palette.primaryText)
                            }
                        }
                    }
                }

                // Mode Switch + Utility Controls
                HStack(spacing: 10) {
                    if app.canUninstall {
                        Picker("", selection: Binding(
                            get: { state.appActionMode },
                            set: { state.setAppActionMode($0) }
                        )) {
                            Text(l10n.uninstallMode).tag(AppActionMode.uninstall)
                            Text(l10n.resetMode).tag(AppActionMode.reset)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    Spacer()

                    if app.isRunning {
                        Button {
                            Task { await state.quitApp(app) }
                        } label: {
                            Label(l10n.quitApp, systemImage: "xmark.circle")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !app.isSystemProtected {
                        Button {
                            state.toggleProtection(for: app)
                        } label: {
                            Label(
                                app.isProtected ? l10n.unprotectApp : l10n.protectApp,
                                systemImage: app.isProtected ? "lock.open" : "lock"
                            )
                            .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if state.droppedApp != nil {
                        Button {
                            state.droppedApp = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if app.sharesBundleIDWithOtherApp {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(palette.warning)
                        Text(l10n.t(
                            "另一个已安装的应用使用相同的 Bundle ID（\(app.bundleID)），服务文件为两者共享，默认不勾选。",
                            "Another installed app uses the same bundle ID (\(app.bundleID)); service files are shared and unchecked by default."
                        ))
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                    }
                }

                if app.isAppleAppStoreApp {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(palette.warning)
                        Text(l10n.appleStoreWarning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(18)
            .background(palette.cardBackground.opacity(0.45))
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.border).frame(height: 1)
            }

            // Categorized File Tree
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Main Application Bundle Row
                    if !isReset {
                        let appFile = ServiceFile(
                            url: app.url,
                            category: .application,
                            size: app.bundleSize,
                            isSelected: state.includeAppBundleInRemoval && app.canUninstall,
                            requiresAdmin: app.requiresAdmin,
                            matchReason: app.bundleID
                        )
                        categorySection(
                            appID: app.id,
                            category: .application,
                            files: [appFile],
                            isMainAppSection: true,
                            disabled: !app.canUninstall
                        )
                    }

                    // Associated Service Files grouped by category
                    let grouped = groupedServiceFiles(app.serviceFiles)
                    if grouped.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 26))
                                    .foregroundStyle(palette.tertiaryText)
                                Text(l10n.noServiceFiles)
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .padding(.vertical, 36)
                            Spacer()
                        }
                    } else {
                        ForEach(grouped, id: \.category) { group in
                            categorySection(
                                appID: app.id,
                                category: group.category,
                                files: group.files,
                                isMainAppSection: false,
                                disabled: !app.canUninstall
                            )
                        }
                    }

                    // Matched pkgutil receipts note
                    if !app.matchedPackageIDs.isEmpty && !isReset {
                        HStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.secondaryText)
                            Text("\(l10n.pkgReceiptsNote): \(app.matchedPackageIDs.joined(separator: ", "))")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(palette.tertiaryText)
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(palette.cardBackground.opacity(0.35))
                        )
                    }
                }
                .padding(16)
            }

            // Sticky Bottom Action Bar
            bottomActionBar(
                selectedCount: selectedCount,
                selectedBytes: selectedBytes,
                buttonTitle: isReset ? l10n.resetApp : l10n.remove,
                disabled: !app.canUninstall || selectedCount == 0 || state.isPerformingRemoval
            ) {
                state.prepareRemovalForCurrentApps()
            }
        }
    }

    private func batchSummaryDetailPane(apps: [AppItem]) -> some View {
        let totalFiles = apps.reduce(0) { $0 + 1 + $1.serviceFiles.filter(\.isSelected).count }
        let totalBytes = apps.reduce(Int64(0)) { acc, app in
            acc + (app.bundleSize ?? 0) + app.serviceFiles.filter(\.isSelected).reduce(0) { $0 + ($1.size ?? 0) }
        }

        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.isChinese ? "已勾选 \(apps.count) 个应用程序" : "\(apps.count) Applications Selected")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(l10n.t("将一并清理这些应用本体及其全部关联服务文件", "All selected app bundles and associated service files will be removed"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Text(ByteFormatter.format(totalBytes))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.accent)
            }
            .padding(18)
            .background(palette.cardBackground.opacity(0.45))
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.border).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(apps) { app in
                        HStack(spacing: 12) {
                            AppIconView(path: app.url.path, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.localizedName)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(palette.primaryText)
                                Text(l10n.isChinese
                                     ? "应用本体 + \(app.serviceFiles.filter(\.isSelected).count) 个服务文件"
                                     : "App bundle + \(app.serviceFiles.filter(\.isSelected).count) service files")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                            let appSelectedBytes = (app.bundleSize ?? 0) + app.serviceFiles.filter(\.isSelected).reduce(0) { $0 + ($1.size ?? 0) }
                            Text(ByteFormatter.format(appSelectedBytes))
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                .foregroundStyle(palette.secondaryText)
                            Button {
                                state.toggleAppChecked(app.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(palette.cardBackground.opacity(0.6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(palette.border, lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(16)
            }

            bottomActionBar(
                selectedCount: totalFiles,
                selectedBytes: totalBytes,
                buttonTitle: l10n.remove,
                disabled: totalFiles == 0 || state.isPerformingRemoval
            ) {
                state.prepareRemovalForCurrentApps()
            }
        }
    }

    private func categorySection(
        appID: String,
        category: ServiceFileCategory,
        files: [ServiceFile],
        isMainAppSection: Bool,
        disabled: Bool
    ) -> some View {
        let isCollapsed = collapsedCategoriesBox.value.contains(category)
        let allSelected = !files.isEmpty && files.allSatisfy(\.isSelected)
        let categoryBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if isCollapsed {
                        collapsedCategoriesBox.value.remove(category)
                    } else {
                        collapsedCategoriesBox.value.insert(category)
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                SweepCheckbox(isChecked: allSelected, isDisabled: disabled, palette: palette) {
                    if isMainAppSection {
                        state.includeAppBundleInRemoval.toggle()
                    } else {
                        state.toggleServiceCategory(appID: appID, category: category, selected: !allSelected)
                    }
                }

                Text(l10n.categoryTitle(category))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.primaryText)

                Text("(\(files.count))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryText)

                Spacer()

                Text(ByteFormatter.format(categoryBytes))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.cardBackground.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(palette.border, lineWidth: 1)
                    )
            )

            if !isCollapsed {
                VStack(spacing: 2) {
                    ForEach(files) { file in
                        FileRowView(
                            file: file,
                            isDisabled: disabled,
                            palette: palette,
                            l10n: l10n,
                            onToggle: {
                                if isMainAppSection {
                                    state.includeAppBundleInRemoval.toggle()
                                } else {
                                    state.toggleServiceFile(appID: appID, fileID: file.id)
                                }
                            },
                            onReveal: {
                                state.revealInFinder(file.url)
                            }
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func bottomActionBar(
        selectedCount: Int,
        selectedBytes: Int64,
        buttonTitle: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.selectedSummary(count: selectedCount, bytes: selectedBytes))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text(state.preferences.defaultRemovalMode == .trash ? l10n.moveToTrashOption : l10n.permanentDeleteOption)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiaryText)
            }

            Spacer()

            Button(action: action) {
                HStack(spacing: 6) {
                    if state.isPerformingRemoval {
                        ProgressView().controlSize(.small)
                    }
                    Text(buttonTitle)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(minWidth: 136, minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: disabled
                                    ? [palette.cardBackground, palette.cardBackground]
                                    : [palette.buttonTop, palette.buttonBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(disabled ? palette.border : Color.white.opacity(0.22), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.55 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(palette.sidebarBackground.opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
    }

    // MARK: - Helpers

    private func sortTitle(_ order: AppSortOrder) -> String {
        switch order {
        case .size: return l10n.sortBySize
        case .name: return l10n.sortByName
        case .lastUsed: return l10n.sortByLastUsed
        case .modified: return l10n.sortByModified
        }
    }

    private func groupedApps(_ list: [AppItem]) -> [(bucket: AppSizeBucket, items: [AppItem])] {
        let dict = Dictionary(grouping: list, by: \.sizeBucket)
        return AppSizeBucket.allCases.compactMap { bucket in
            guard let items = dict[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }

    private func groupedServiceFiles(_ list: [ServiceFile]) -> [(category: ServiceFileCategory, files: [ServiceFile])] {
        let dict = Dictionary(grouping: list, by: \.category)
        return ServiceFileCategory.allCases
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { cat in
                guard let items = dict[cat], !items.isEmpty else { return nil }
                return (cat, items)
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?
            if let data = item as? Data {
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                droppedURL = url
            } else {
                droppedURL = nil
            }
            if let url = droppedURL, url.pathExtension.lowercased() == "app" {
                DispatchQueue.main.async {
                    state.inspectDroppedApp(at: url)
                }
            }
        }
        return true
    }
}
