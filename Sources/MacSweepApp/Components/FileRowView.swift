import Darwin
import MacSweepCore
import SwiftUI

private struct DirectoryChildItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64?
}

struct FileRowView: View {
    let file: ServiceFile
    let isDisabled: Bool
    let palette: AppPalette
    let l10n: L10n
    let versionBadge: String?
    let allowExpandDirectory: Bool
    let showParentOnly: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onRevealURL: ((URL) -> Void)?

    init(
        file: ServiceFile,
        isDisabled: Bool = false,
        palette: AppPalette,
        l10n: L10n,
        versionBadge: String? = nil,
        allowExpandDirectory: Bool = false,
        showParentOnly: Bool = false,
        onToggle: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onRevealURL: ((URL) -> Void)? = nil
    ) {
        self.file = file
        self.isDisabled = isDisabled
        self.palette = palette
        self.l10n = l10n
        self.versionBadge = versionBadge
        self.allowExpandDirectory = allowExpandDirectory
        self.showParentOnly = showParentOnly
        self.onToggle = onToggle
        self.onReveal = onReveal
        self.onRevealURL = onRevealURL
    }

    @StateObject private var hoverState = LocalState(false)
    @StateObject private var isExpandedBox = LocalState(false)
    @StateObject private var isLoadingChildrenBox = LocalState(false)
    @StateObject private var childrenBox = LocalState<[DirectoryChildItem]?>(nil)
    @StateObject private var overflowCountBox = LocalState(0)

    private var canExpand: Bool {
        allowExpandDirectory
            && file.isDirectory
            && !file.isSymbolicLink
            && file.url.pathExtension.lowercased() != "app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if allowExpandDirectory {
                    if canExpand {
                        Button {
                            toggleExpansion()
                        } label: {
                            Image(systemName: isExpandedBox.value ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 14, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 14, height: 18)
                    }
                }

                SweepCheckbox(
                    isChecked: file.isSelected,
                    isDisabled: isDisabled,
                    palette: palette,
                    action: onToggle
                )

                AppIconView(path: file.url.path, size: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(SafeFileReader.sanitizeForDisplay(file.displayName))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let versionBadge, !versionBadge.isEmpty {
                            Text(versionBadge)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(palette.secondaryText)
                        }

                        if file.isSystemScope {
                            Label(l10n.t("系统级", "System"), systemImage: "shield.lefthalf.filled")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(palette.warning)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(palette.warning.opacity(0.16)))
                        }

                        if file.requiresAdmin {
                            Label(l10n.adminBadge, systemImage: "lock.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(palette.warning)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(palette.warning.opacity(0.16)))
                        }

                        if file.requiresReboot {
                            Text(l10n.rebootBadge)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(palette.accent.opacity(0.16)))
                        }
                    }

                    Text(SafeFileReader.sanitizeForDisplay(
                        showParentOnly
                            ? shortenedPath(file.url.deletingLastPathComponent().path)
                            : shortenedPath(file.url.path)
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if hoverState.value {
                    Button(action: onReveal) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardHoverBackground))
                    }
                    .buttonStyle(.plain)
                    .help(l10n.revealInFinder)
                }

                if file.isSymbolicLink {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.accent)
                        .help(l10n.t("符号链接", "Symbolic Link"))
                }

                if let sz = file.size {
                    Text(ByteFormatter.format(sz))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoverState.value ? palette.cardHoverBackground.opacity(0.7) : Color.clear)
            )
            .onHover { hoverState.value = $0 }
            .help(file.matchReason.isEmpty ? file.url.path : "\(file.url.path)\n(\(file.matchReason))")

            if isExpandedBox.value {
                if isLoadingChildrenBox.value {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.75)
                        Text(l10n.t("正在读取目录内容...", "Loading folder contents..."))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryText)
                    }
                    .padding(.leading, 44)
                    .padding(.vertical, 4)
                } else if let children = childrenBox.value {
                    if children.isEmpty {
                        Text(l10n.t("空文件夹", "Empty folder"))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryText)
                            .padding(.leading, 44)
                            .padding(.vertical, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(children) { child in
                                DirectoryChildRowView(
                                    item: child,
                                    depth: 1,
                                    palette: palette,
                                    l10n: l10n,
                                    onRevealURL: { target in
                                        if let onRevealURL {
                                            onRevealURL(target)
                                        } else {
                                            onReveal()
                                        }
                                    }
                                )
                            }
                            if overflowCountBox.value > 0 {
                                Text(l10n.isChinese
                                     ? "… 另有 \(overflowCountBox.value) 个项目未展开（点击 Finder 查看全部）"
                                     : "… \(overflowCountBox.value) more items (reveal in Finder to view all)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(palette.tertiaryText)
                                    .padding(.leading, 44)
                                    .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleExpansion() {
        isExpandedBox.value.toggle()
        guard isExpandedBox.value, childrenBox.value == nil, !isLoadingChildrenBox.value else {
            return
        }
        if IconCache.shared.isDemoMode {
            let demoItems = DemoFixtureCatalog.default.directoryChildren(for: file.url).map { child in
                DirectoryChildItem(
                    id: child.url.path,
                    url: child.url,
                    name: child.name,
                    isDirectory: child.isDirectory,
                    isSymbolicLink: child.isSymbolicLink,
                    size: child.size
                )
            }
            childrenBox.value = demoItems
            overflowCountBox.value = 0
            return
        }
        isLoadingChildrenBox.value = true
        let targetURL = file.url
        Task.detached(priority: .userInitiated) {
            let (loaded, overflow) = Self.loadDirectChildren(of: targetURL, maxItems: 120)
            await MainActor.run {
                childrenBox.value = loaded
                overflowCountBox.value = overflow
                isLoadingChildrenBox.value = false
            }
        }
    }

    nonisolated fileprivate static func loadDirectChildren(
        of dirURL: URL,
        maxItems: Int
    ) -> ([DirectoryChildItem], Int) {
        var dirStat = stat()
        guard lstat(dirURL.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            return ([], 0)
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return ([], 0)
        }

        let sortedURLs = urls.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        let overflow = max(0, sortedURLs.count - maxItems)
        let slice = sortedURLs.prefix(maxItems)

        var items: [DirectoryChildItem] = []
        items.reserveCapacity(slice.count)
        for child in slice {
            var st = stat()
            guard lstat(child.path, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            let isLink = (mode == S_IFLNK)
            let isDir = (mode == S_IFDIR)
            let sz: Int64?
            if isLink {
                sz = Int64(st.st_size)
            } else if !isDir {
                sz = st.st_blocks > 0 ? Int64(st.st_blocks) * 512 : Int64(st.st_size)
            } else {
                sz = DirectorySizer.measureSizeSync(of: child, maxEntries: 10_000).bytes
            }
            items.append(DirectoryChildItem(
                id: child.path,
                url: child,
                name: child.lastPathComponent,
                isDirectory: isDir,
                isSymbolicLink: isLink,
                size: sz
            ))
        }

        items.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            let ls = $0.size ?? 0
            let rs = $1.size ?? 0
            if ls != rs { return ls > rs }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (items, overflow)
    }

    private func shortenedPath(_ path: String) -> String {
        let home = IconCache.shared.isDemoMode
            ? DemoFixtureCatalog.homeDirectoryPath
            : FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private struct DirectoryChildRowView: View {
    let item: DirectoryChildItem
    let depth: Int
    let palette: AppPalette
    let l10n: L10n
    let onRevealURL: (URL) -> Void

    @StateObject private var hoverBox = LocalState(false)
    @StateObject private var expandedBox = LocalState(false)
    @StateObject private var loadingBox = LocalState(false)
    @StateObject private var subChildrenBox = LocalState<[DirectoryChildItem]?>(nil)
    @StateObject private var overflowBox = LocalState(0)

    private var canExpand: Bool {
        depth < 3 && item.isDirectory && !item.isSymbolicLink && item.url.pathExtension.lowercased() != "app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                if canExpand {
                    Button {
                        toggle()
                    } label: {
                        Image(systemName: expandedBox.value ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.tertiaryText)
                            .frame(width: 12, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 12, height: 16)
                }

                AppIconView(path: item.url.path, size: 17)

                Text(SafeFileReader.sanitizeForDisplay(item.name))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if hoverBox.value {
                    Button {
                        onRevealURL(item.url)
                    } label: {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(palette.cardHoverBackground))
                    }
                    .buttonStyle(.plain)
                    .help(l10n.revealInFinder)
                }

                if item.isSymbolicLink {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.accent)
                }

                if let sz = item.size {
                    Text(ByteFormatter.format(sz))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(palette.tertiaryText)
                        .monospacedDigit()
                }
            }
            .padding(.leading, CGFloat(24 + depth * 16))
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoverBox.value ? palette.cardHoverBackground.opacity(0.55) : Color.clear)
            )
            .onHover { hoverBox.value = $0 }
            .help(item.url.path)

            if expandedBox.value {
                if loadingBox.value {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                        Text(l10n.t("正在读取...", "Loading..."))
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.tertiaryText)
                    }
                    .padding(.leading, CGFloat(40 + depth * 16))
                    .padding(.vertical, 3)
                } else if let children = subChildrenBox.value {
                    ForEach(children) { child in
                        DirectoryChildRowView(
                            item: child,
                            depth: depth + 1,
                            palette: palette,
                            l10n: l10n,
                            onRevealURL: onRevealURL
                        )
                    }
                    if overflowBox.value > 0 {
                        Text(l10n.isChinese
                             ? "… 另有 \(overflowBox.value) 个项目"
                             : "… \(overflowBox.value) more items")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.tertiaryText)
                            .padding(.leading, CGFloat(40 + depth * 16))
                            .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func toggle() {
        expandedBox.value.toggle()
        guard expandedBox.value, subChildrenBox.value == nil, !loadingBox.value else { return }
        if IconCache.shared.isDemoMode {
            subChildrenBox.value = DemoFixtureCatalog.default.directoryChildren(for: item.url).map { child in
                DirectoryChildItem(
                    id: child.url.path,
                    url: child.url,
                    name: child.name,
                    isDirectory: child.isDirectory,
                    isSymbolicLink: child.isSymbolicLink,
                    size: child.size
                )
            }
            overflowBox.value = 0
            return
        }
        loadingBox.value = true
        let targetURL = item.url
        Task.detached(priority: .userInitiated) {
            let (loaded, overflow) = FileRowView.loadDirectChildren(of: targetURL, maxItems: 80)
            await MainActor.run {
                subChildrenBox.value = loaded
                overflowBox.value = overflow
                loadingBox.value = false
            }
        }
    }
}
