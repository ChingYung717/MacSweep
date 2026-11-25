# MacSweep 产品演进与工程规划方案（Planning & Roadmap）

> **状态图例（Status Legend）**：本文档严格区分 **【已实现基线 / M0 Baseline】** 与 **【规划演进 / Planned M1–M5】**，确保架构设计、安全边界与对外文档描述与代码仓库实际状态保持一致。

---

## 0. 文档定位与演进目标

**MacSweep** 当前（M0 基线）是一款基于纯 Swift（Swift 6 + SwiftUI / AppKit + SwiftPM）构建的原生 macOS 应用卸载、启动项管理、扩展清理与残留文件扫描工具，具备零第三方运行时依赖、零后台常驻进程、零网络遥测与命令行工具链直接编译（无需安装完整 `Xcode.app`）的工程特性。

面向完整产品演进与开源发布，本次规划覆盖以下四大核心目标：

1. **R1 — 整体规划与分阶段路线图**：形成清晰的架构规范、安全边界、功能规格、脱敏截图与 README 改版方案，以及可执行、可验收的 M1–M5 + 独立 E2E 轨道路线图。
2. **R2 — 文件管理器（File Manager）**：在统一页签下提供「磁盘空间分析（Space Analyzer）」与「通用文件浏览与日常管理（File Browser）」双子模式，集成 QuickLook 与安全只读元数据检查，并在 MacSweep 既有 `SafetyGuard` 安全边界内支持安全的移动、重命名、新建目录与废纸篓优先删除。
3. **R3 — 垃圾/缓存清理与扩展资源释放（Junk Cleaner & Resource Release）**：扩展面向应用缓存（严格遵守 `sharedVendorFolderNames` 子路径隔离）、系统/用户日志、浏览器缓存、开发者工具缓存、废纸篓的专项清理能力，并新增大文件排查、三阶段哈希重复文件查找与基于 Mach 内核统计的实时内存监控与诚实释放能力。
4. **R4 — 脱敏演示数据模式、自动化截图流水线与 GitHub 描述页更新**：构建完全与本机真实磁盘/隐私数据隔离的 `--demo-mode`（虚构用户 `/Users/alex` 与合成图标），实现 2x Retina 离屏自动导出管线生成 `docs/screenshots/*.png`，并全面更新 `README.md`、`README_EN.md` 与 `README_ZH.md`（含修复现存文档中的校验数量与页签数量不一致问题）。

---

## 1. 现有工程基线与目标系统架构

### 1.1 已验证的 M0 工程基线（Verified M0 Baseline）

以下资产已在仓库中实现并通过编译与沙盒校验验证：

| 层次 | 现有模块 / 文件 | 已验证实现现状（M0 Baseline） | 已知局限 / 待演进项 |
|---|---|---|---|
| **构建与打包** | `Package.swift`、`make_app.sh`、`.github/workflows/ci.yml`、`scripts/publish_preview.sh` | `swift-tools-version: 6.0`，`.macOS(.v14)`；零外部依赖；`make_app.sh` 支持 Hardened Runtime 打包与签名；CI 在 `macos-15` 上校验 `otool -L` 零 `/opt/homebrew` 或 `/usr/local` 动态库 | `docs/` 与 `docs/screenshots/` 目录尚未建立 |
| **核心层（Swift 6）** | `Sources/MacSweepCore/` | 严格并发模式（`Sendable`），**零 `SwiftUI` 导入**：<br>• `Models/`：`AppItem`、`ServiceFile`、`StartupItem`、`ExtensionItem`、`LeftoverItem`、`Preferences`、`CleanupRecord`<br>• `Safety/`：`SafetyGuard`、`SafeFileReader`、`PermissionChecker`<br>• `Scanners/`：`LibraryIndex`、`AppScanner`、`ServiceFileMatcher`、`DirectorySizer`、`StartupScanner`、`ExtensionScanner`、`LeftoverScanner`<br>• `Actions/`：`RemovalEngine`、`PrivilegedExecutor`、`StartupController`、`ProcessRunner` | • `SafetyGuard` 尚无移动/重命名/新建目录/缓存子路径专属校验接口，也无通用 `FileOperationsEngine`<br>• `DirectorySizer` 当前按 `lstat` 跳过符号链接与限流遍历，但**尚未**实现 `(st_dev, st_ino)` 硬链接去重、`st_dev` 单卷边界约束与 `SF_DATALESS` 跳过<br>• `Demo/` 目录尚不存在 |
| **应用层（Swift 5）** | `Sources/MacSweepApp/` | 采用 `.swiftLanguageMode(.v5)` 兼容 CommandLineTools（使用 `LocalState<Value>` + `@StateObject` + `@MainActor ObservableObject`，禁止 `@State` 宏）：<br>• 4 个主功能页签：`ApplicationsView`、`StartupProgramsView`、`ExtensionsView`、`LeftoversView`<br>• 组件：`MainSplitView`、`SidebarRail`、`SettingsSheet`、`ConfirmationSheet`、`DropZoneHeroView`、`FileRowView`、`AppIconView`<br>• 主题与本地化：`AppPalette`（`.deepOcean` / `.system`）、`L10n`（`.zhHans` / `.en` / `.system`） | • `SweepPreferences.protectedPaths` 已在核心层持久化并由 `SafetyGuard` 强制执行，但 `SettingsSheet` 的「保护名单」页签**尚无对应的路径增删 UI**<br>• 尚无文件管理器、垃圾清理、资源释放页签及演示截图模式 |
| **测试与文档** | `Tests/MacSweepChecks/`、`README*.md` | 共 10 个文件，运行 `swift run MacSweepChecks` 实际通过 **59 项**沙盒与回归校验（支持只读 `--live-audit`） | `README.md`、`README_EN.md`、`README_ZH.md` 中仍写着过时的 **29 项**校验数量，且缺乏项目截图展示 |

### 1.2 演进后两层纯 Swift 目标架构（M1–M5 Target Architecture）

演进后的完整架构继续严格遵守 **MacSweepCore（Swift 6 严格并发、零 SwiftUI）** 与 **MacSweepApp（Swift 5 模式、无第三方运行库）** 的分层隔离：

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ Sources/MacSweepAppEntry (`MacSweepApp` executable target · Swift 5 mode)    │
│ └── MacSweepApp.swift    CLI/Env 解析 (--demo-mode / --export-screenshots)     │
├──────────────────────────────────────────────────────────────────────────────┤
│ Sources/MacSweepApp (`MacSweepUI` library · @MainActor ObservableObject)     │
│ ├── State/                                                                   │
│ │   ├── AppState.swift               [基线+M1/M4] 全局状态、protectedPaths 管理│
│ │   ├── FileManagerStore.swift       [规划 M2] 空间分析与文件浏览状态          │
│ │   ├── CleanupCenterStore.swift     [规划 M3] 垃圾清理、大/重复文件、内存释放 │
│ │   ├── DemoScreenshotExporter.swift [规划 M4] 2x Retina 离屏窗口快照导出     │
│ │   └── Localization.swift / Theme.swift [基线+M1–M3] 双语与深海蓝/跟随系统    │
│ ├── Views/ (7 大功能页签 + 设置弹窗)                                          │
│ │   ├── Applications / Startup / Extensions / LeftoversView   [已实现基线]   │
│ │   ├── FileManagerView.swift        [规划 M2] 空间分析 + 文件浏览 + 预览检查 │
│ │   ├── JunkCleanerView.swift        [规划 M3] 垃圾/缓存专项清理             │
│ │   ├── ResourceReleaseView.swift    [规划 M3] 大文件 / 重复文件 / 内存释放   │
│ │   └── SettingsSheet.swift          [基线+M1] 新增 protectedPaths 管理卡片   │
│ └── Components/                                                              │
│     └── 既有组件 + QuickLook/BoundedPreview / AnalyzerBars / MemoryGauge     │
├──────────────────────────────────────────────────────────────────────────────┤
│ Sources/MacSweepCore (Swift 6 strict Sendable · ZERO SwiftUI imports)        │
│ ├── Safety/                                                                  │
│ │   ├── SafetyGuard.swift            [基线+M1] move/rename/mkdir/cache-subpath│
│ │   ├── SafeFileReader.swift         [已实现基线] O_NOFOLLOW/O_NONBLOCK 限流读│
│ │   └── PermissionChecker.swift      [已实现基线] 非侵入式 FDA 探测           │
│ ├── Actions/                                                                 │
│ │   ├── RemovalEngine.swift          [已实现基线] 废纸篓优先 + Finder/提权降级│
│ │   ├── FileOperationsEngine.swift   [规划 M1] move/rename/mkdir/metadata    │
│ │   ├── MemoryReleaseService.swift   [规划 M3] Mach VM 采样与诚实释放         │
│ │   └── PrivilegedExecutor / StartupController / ProcessRunner  [已实现基线] │
│ ├── Scanners/                                                                │
│ │   ├── 既有 7 个扫描器              [已实现基线]                             │
│ │   ├── DiskSpaceAnalyzer.swift      [规划 M2] 树状体积测算 (st_dev/inode/dataless)
│ │   ├── FileBrowserService.swift     [规划 M2] 目录枚举、排序与非阻塞属性读取 │
│ │   ├── JunkCacheScanner.swift       [规划 M3] 缓存/日志/浏览器/开发/废纸篓   │
│ │   └── LargeAndDuplicateScanner.swift [规划 M3] 大文件与 3 阶段 SHA256 去重   │
│ ├── Models/                                                                  │
│ │   ├── 既有 7 个模型                [已实现基线]                             │
│ │   ├── FileMutationModels.swift     [规划 M1] FileMetadataInfo / Error / Res │
│ │   ├── DiskTreeNode.swift / FileBrowserItem.swift               [规划 M2]   │
│ │   └── JunkAndResourceModels.swift  [规划 M3] 垃圾/大文件/重复/内存模型      │
│ └── Demo/                                                                    │
│     └── DemoFixtureCatalog.swift     [规划 M4] /Users/alex 全套脱敏夹具与配置 │
├──────────────────────────────────────────────────────────────────────────────┤
│ Tests/MacSweepChecks (Swift 6 CLT 沙盒与回归校验)                            │
│ ├── 既有 59 项校验                   [已实现基线]                             │
│ ├── FileOpsSafetyChecks.swift        [规划 M1] 移动/重命名/新建/缓存子路径/TOCTOU
│ ├── FileManagerChecks.swift          [规划 M2] 空间树、硬链接/卷边界、浏览排序 │
│ ├── JunkAndResourceChecks.swift      [规划 M3] 缓存隔离、3阶段去重、Mach 内存  │
│ └── DemoModeChecks.swift             [规划 M4] 零真实用户名/路径泄漏静态与动态审计
├──────────────────────────────────────────────────────────────────────────────┤
│ Tests/MacSweepE2E (独立黑盒 E2E 轨道)                                         │
│ └── Tiers 1–4 端到端用例 + Tier-5 对抗性加固                     [并行/M5]   │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 核心安全准则与不可变不变量（Safety Invariants）

所有已有与新增的扫描、预览及变更能力必须严格满足以下不变量：

1. **路径三重解析与系统/凭证边界（`SafetyGuard`）**：
   - 对原始标准化路径（`standardizedFileURL`）、Foundation 符号链接解析路径（`resolvingSymlinksInPath()`）及最深存在祖先 POSIX `realpath(3)` 路径（保留 `/private` 前缀）进行全部比对。
   - 严禁触碰根目录、`/System`、`/Library/Apple`、`criticalExactPathsLower`、`immutableBarePrefixesLower`（含系统路径及用户侧 `Keychains`、`Safari`、`Mail`、`Messages`、`com.apple.TCC`、`*.photoslibrary`、`~/.ssh`、`~/.gnupg`）、MacSweep 自身包体与数据目录（`selfBundlePathsLower` / `selfDataPathsLower`）、用户配置的 `protectedBundleIDs` 与 `protectedPaths`。
   - **祖先 BSD 标志精准判断**：由于 macOS 根级目录（`/`、`/Users`、`/Applications`、`/Library`）带有 `SF_NOUNLINK`（`sunlnk`），目标父祖先校验仅对解析后的真实祖先检查 `SF_RESTRICTED | SF_IMMUTABLE` 并叠加 `pointsToSystemVolume` 检查；仅对叶子目标本身使用完整 `isSIPRestricted`（含 `SF_NOUNLINK`），从而既防 SIP 逃逸又不误伤 `~/Downloads` 或 `/Applications` 正常目录操作。
2. **TOCTOU 父目录锁定与非跟随操作**：
   - 扫描阶段记录 `expectedCanonicalParent`（经 `realpath(3)` 解析）。
   - 执行阶段以 `open(..., O_SEARCH | O_DIRECTORY)` 钉住父目录文件描述符，调用 `fcntl(fd, F_GETPATH)` 校验真实父路径是否与预期一致，并在标准路径上重新运行 `SafetyGuard` 校验；原子操作均基于目录 FD（`fstatat(..., AT_SYMLINK_NOFOLLOW)`、`renameatx_np(..., RENAME_EXCL)`、`mkdirat`），绝不在路径变更间隙跟随符号链接。
3. **M1 新增操作边界与设置页补齐**：
   - `SafetyGuard.validateForMoveOrRename(source:destination:expectedSourceCanonicalParent:)`：校验源可移除、TOCTOU 父目录一致、目标未落入受保护区域、禁止目录移入自身或子孙目录、默认禁止静默覆盖已存在目标（仅对通过 `(st_dev, st_ino)` 验证的 APFS/HFS+ 纯大小写重命名放行）。
   - `SafetyGuard.validateDirectoryCreation(at:)`：校验合法目录名、无已存在重名项、无受保护祖先或符号链接逃逸。
   - `SafetyGuard.validateCacheSubpath(_:)`：确保缓存清理路径**全部候选解析结果**严格位于 `~/Library/Caches/` 下，拦截 `apple`、`com.apple.*` 及裸露的 `sharedVendorFolderNames` 厂商根目录，仅允许具名子应用缓存（如 `<Vendor>/<AppCache>`）。
   - `SettingsSheet`「保护名单（Skip List）」页签补齐 `SweepPreferences.protectedPaths` 的增删、合法性校验与 `NSOpenPanel` 选择 UI，消除 M0 阶段的 UI 缺口。
4. **M2/M3 扫描遍历安全不变量**：
   - 使用 `lstat` 不跟随符号链接（防止目录环与跨目录重复计数）。
   - 记录根节点 `st_dev`，严禁无提示跨越文件系统挂载边界（避免误扫外接卷或 Time Machine 快照）。
   - 通过 `(st_dev, st_ino)` 集合对硬链接去重，防止 APFS 克隆/硬链接造成容量虚高或重复计数错误。
   - 检查 `SF_DATALESS` 标志，跳过仅占位未下载的 iCloud 云端文件，避免扫描期间触发大量隐式云端下载。
   - 支持 Swift 结构化并发取消（`Task.checkCancellation()`）与节流进度回调。
5. **废纸篓优先与显式确认**：
   - 所有删除行为（含文件管理器删除、垃圾缓存清理、大文件与重复文件删除）**必须**经由 `RemovalEngine.remove(...)` 与 `ConfirmationSheet` 执行；默认使用 `RemovalMode.trash`（优先保留「放回原处」），`.permanent` 模式下禁用 Return 快捷键防误触，并将全部成功删除路径记录至 `CleanupHistoryStore`（`history.json`，上限 100 条，`0600` 原子写入）。

---

## 2. R2 文件管理器设计（File Manager）

### 2.1 统一入口与状态架构
- 在 `SidebarRail` 与 `MainTab` 中新增 `.fileManager` 页签，对应视图 `FileManagerView` 与状态 store `FileManagerStore`（`@MainActor ObservableObject`）。
- 顶部提供双子模式切换器：**空间分析（Space Analyzer）** 与 **文件浏览（File Browser）**，共用同一套 `SafetyGuard`、`FileOperationsEngine`、`RemovalEngine` 与 `ConfirmationSheet` 确认流。

### 2.2 R2.1 磁盘空间分析与大/旧文件排查（Space Analyzer）
- **核心模型（`DiskTreeNode.swift`）**：
  - `DiskTreeNode`：`id: String`、`url: URL`、`name: String`、`isDirectory: Bool`、`isPackage: Bool`、`isSymlink: Bool`、`bytes: UInt64`、`fileCount: Int`、`folderCount: Int`、`modificationDate: Date?`、`accessDate: Date?`、`children: [DiskTreeNode]`、`isTruncated: Bool`。
  - `DiskScanProgress`：已扫描文件数、累计字节数、当前扫描路径与耗时。
- **扫描引擎（`DiskSpaceAnalyzer.swift`）**：
  - 接口：`analyze(root: URL, maxDepth: Int, onProgress: @Sendable (DiskScanProgress) -> Void) async throws -> DiskTreeNode`。
  - 遵循全部扫描安全不变量（`lstat` 跳过符号链接、`st_dev` 单卷边界、`(st_dev, st_ino)` 硬链接去重、`SF_DATALESS` 跳过、深度上限与单目录安全截断标记 `isTruncated`、可随时取消）。
- **视图与交互**：
  - **根目录选择器**：快捷切换用户主目录 `~`、`/Applications`、已挂载外接卷或通过 `NSOpenPanel` 自选目录。
  - **卷容量总览条（Volume Capacity Bar）**：展示磁盘总容量、已用空间、可用空间及当前扫描子树占比。
  - **层级体积占比条与面包屑下钻**：按字节降序展示当前层级子目录/大文件及百分比进度条，支持双击目录或点击面包屑逐级下钻与回退。
  - **大文件 / 旧文件快捷过滤**：一键筛选 `>= 100 MB` / `>= 500 MB` 大体积项目，或超过 `90 天` / `180 天` / `365 天` 未修改/未访问的陈旧文件。
  - **安全动作**：支持在 Finder 中显示、QuickLook/右侧预览、加入 `protectedPaths` 保护名单，以及经 `ConfirmationSheet` + `RemovalEngine` 移至废纸篓或永久删除。

### 2.3 R2.2 通用文件浏览与日常管理（General File Browser）
- **目录服务（`FileBrowserService.swift`）**：
  - 接口：`listDirectory(at url: URL, showHidden: Bool, sortBy: FileBrowserSort, ascending: Bool) throws -> [FileBrowserEntry]`。
  - 列表读取严格基于非阻塞属性与 `lstat`，遇到权限受限目录提供明确可读的错误提示（可引导授予 FDA），不静默吞掉异常。
- **导航与日常操作**：
  - **常用目录侧栏/快捷栏**：主目录、桌面、文稿、下载、应用程序、`~/Library/Caches` 一键跳转。
  - **历史栈与面包屑**：支持后退 / 前进、返回上级、可点击面包屑导航。
  - **视图工具栏**：隐藏文件显示切换（`⌘⇧.` 联动）、实时文件名过滤搜索、多字段排序（名称 / 大小 / 修改日期 / 类型）、多选操作。
- **预览与元数据检查（QuickLook + 安全内置预览）**：
  - **原生 QuickLook**：选中文件按空格键或点击预览按钮调用 macOS 原生 `QuickLookUI`（`QLPreviewPanel`），支持 PDF、图片、音视频与办公文档，无需第三方解析库。
  - **右侧元数据与受限内容预览面板**：
    - 通过 `FileOperationsEngine.inspectMetadata(at:)` 展示 `FileMetadataInfo`（大小、分配空间、创建/修改/访问时间、POSIX 权限八进制与符号串、`isUserImmutable`（`uchg`）、`isSIPRestricted`、符号链接原始目标及解析结果、`isDataless`、UTI 类型）。
    - 通过 `SafeFileReader.readBoundedPrefix`（`O_RDONLY | O_NOFOLLOW | O_NONBLOCK`，上限 64 KB–2 MB）及 `sanitizeForDisplay` 安全预览纯文本、源码、JSON、plist 与图片缩略图，绝不在主线程阻塞读取大文件或 FIFO 设备节点。
- **日常变更操作与安全边界**：
  - **移动（Move）**、**重命名（Rename）**、**新建文件夹（Create Folder）**：全部通过 `FileOperationsEngine` 执行，底层使用 `SafetyGuard` 校验 + `expectedCanonicalParent` TOCTOU 校验 + `renameatx_np(..., RENAME_EXCL)` / `mkdirat`，拒绝空名、`.`、`..`、`/`、`\0`、越权覆盖与符号链接逃逸。
  - **删除（Delete）**：统一转交 `RemovalEngine` + `ConfirmationSheet`，绝不直接调用无校验的 `FileManager.removeItem`。
  - **UI 与 Core 双层锁定**：对 SIP 受保护项、系统目录、MacSweep 自身与 `protectedPaths` 展示「系统保护 / 已保护」锁标识，并在界面与核心引擎双层禁用移动、重命名与删除。

---

## 3. R3 垃圾/缓存文件清理与扩展资源释放设计

### 3.1 R3.1 磁盘垃圾与缓存清理（`JunkCacheScanner` + `JunkCleanerView`）
- **核心模型（`JunkAndResourceModels.swift`）**：
  - `JunkCategoryItem`：`id`、`category`、`title`、`description`、`entries: [JunkEntry]`、`totalBytes`、`requiresAdmin`、`safetyNote`。
  - `JunkEntry`：`id`、`url`、`name`、`bytes`、`isSelected`、`requiresAdmin`、`expectedCanonicalParent`、`isRunningAppBlocked`、`safetyReason`。
- **五大清理分类与安全规则**：
  1. **用户与应用缓存（User & App Caches）**：扫描 `~/Library/Caches/*`。**强制执行 `SafetyGuard.validateCacheSubpath` 规范**：绝不选中 `~/Library/Caches` 根目录、绝不选中 `apple` / `com.apple.*`、绝不整目录选中 `sharedVendorFolderNames`（如 `Google`、`Microsoft`、`Adobe`、`JetBrains`、`Tencent` 等 44 个共享厂商目录），而是下钻至具体应用子目录（如 `~/Library/Caches/Google/Chrome`）。
  2. **日志与崩溃报告（Logs & Crash Reports）**：扫描 `~/Library/Logs/*` 与 `~/Library/Logs/DiagnosticReports/*` 子项（不删父目录）；系统级 `/Library/Logs/*` 仅作只读展示或标记 `requiresAdmin` 且默认不勾选。
  3. **浏览器缓存（Browser Caches）**：精准定位 Chrome、Edge、Brave、Arc、Firefox、Safari 的缓存子目录（**严禁**触碰配置文件、书签、历史记录、密码库与扩展数据）；若无 FDA 提示优雅降级，若目标浏览器正在运行则提示先退出或暂停清理。
  4. **开发者工具缓存（Developer Caches）**：支持 Xcode `DerivedData`、`Archives`（出于保留签名归档考虑**默认不勾选**）、`CoreSimulator/Caches`、Homebrew 下载缓存（`~/Library/Caches/Homebrew`）、`npm`（`~/.npm/_cacache`）、`pnpm`、`pip`/`uv`、`cargo` 缓存。严禁删除工具链二进制、SDK 或环境配置本身（与 `leftoverSafeIgnoreNames` 保持一致）。
  5. **废纸篓内容（User Trash）**：枚举 `~/.Trash` 内条目并展示体积与删除前提示，支持按条目或整栏经确认后安全清空。
- **交互与执行**：左侧/分组清单展示各分类可释放估算体积与风险说明（`safetyNote`），高风险分类默认不勾选；确认清理后统一通过 `RemovalEngine` + `ConfirmationSheet` 执行并写入历史记录。

### 3.2 R3.2 扩展资源释放（`LargeAndDuplicateScanner` + `MemoryReleaseService` + `ResourceReleaseView`）

`ResourceReleaseView` 整合三大扩展资源释放能力（可通过分段视图切换）：

1. **大文件排查（Large Files Finder）**：
   - 模型：`LargeFileItem`（`url`、`name`、`bytes`、`modificationDate`、`accessDate`、`category`、`expectedCanonicalParent`）。
   - 功能：支持阈值配置（`>= 50 MB` / `100 MB` / `500 MB` / `1 GB`）、陈旧时间过滤（`> 30 / 90 / 365 天`）与文件类型过滤（视频、镜像/压缩包 DMG/ZIP/ISO、安装包、文档、其他）。
   - 安全边界：自动跳过符号链接、`SF_DATALESS` 占位文件、`.photoslibrary` 图库内部、SIP/系统及 `protectedPaths`；支持预览、Finder 定位与经 `ConfirmationSheet` 安全删除。

2. **三阶段重复文件排查（3-Stage Duplicate File Finder）**：
   - 模型：`DuplicateGroup`（`id: String` 为 `sha256 + size`、`fileSize: UInt64`、`files: [DuplicateFileEntry]`、`reclaimableBytes: UInt64`）。
   - **三阶段低 I/O 哈希流水线**：
     - **阶段 1（体积分组）**：在单卷（`st_dev`）范围内遍历，忽略 0 字节空文件、符号链接与 `SF_DATALESS` 文件；利用 `(st_dev, st_ino)` 对硬链接去重（同一 inode 的硬链接不占额外磁盘空间，绝不误判为重复副本）。
     - **阶段 2（首尾局部哈希）**：对同体积候选文件使用 `SafeFileReader`（`O_NOFOLLOW | O_NONBLOCK`）仅读取头部与尾部固定分片进行快速摘要，淘汰绝大部分非重复文件。
     - **阶段 3（流式全量 SHA-256）**：仅对局部哈希碰撞组使用原生 `CryptoKit.SHA256` 流式分块计算完整哈希，保证 100% 字节级一致。
   - **智能勾选与防全删保护**：提供「智能保留一份」快捷选择策略（默认保留最早修改或非 `Downloads` 路径的一份副本）；单组内至少保留 1 份副本或在高危全删前强制二次警示；排除 `.app` 内部资源与受保护目录。

3. **内存监控与诚实释放（Memory Monitor & Release）**：
   - 模型：`MemorySnapshot`（`totalBytes`、`activeBytes`、`wiredBytes`、`compressedBytes`、`cachedFilesBytes`、`freeBytes`、`swapUsedBytes`、`swapTotalBytes`、`pressureLevel`）与 `MemoryReleaseResult`（`before`、`after`、`reclaimedEstimateBytes`、`methodUsed`、`usedElevation`、`note`）。
   - **实时 Mach 内核采样**：完全使用 Darwin/Mach 系统 API（`ProcessInfo.processInfo.physicalMemory`、`host_statistics64(mach_host_self(), HOST_VM_INFO64, ...)`、`sysctlbyname("vm.swapusage")` 与 `kern.memorystatus_vm_pressure_level`），不调用外部命令行工具。
   - **诚实释放机制（禁止虚假数字包装）**：
     - **非提权模式**：提供真实透明的内存构成分析、Swap 占用与压力等级显示，并在需要时执行温和的非破坏性内存压力整理建议，绝不伪造「瞬间释放 10 GB」的虚假反馈。
     - **可选管理员提权释放**：在用户明确点击确认后，通过 `PrivilegedExecutor` 调用系统原生 `/usr/sbin/purge` 清理非活跃文件缓存页，释放前后分别采集 `MemorySnapshot` 并如实展示 `before -> after` 的差值与说明 `note`。

---

## 4. R4 脱敏演示数据模式与 GitHub 截图方案

### 4.1 脱敏演示数据模式（`DemoFixtureCatalog` & 运行时隔离）
- **启动参数与环境变量**：
  - `--demo-mode` 或 `MACSWEEP_DEMO_MODE=1`：激活全应用脱敏演示模式。
  - `--demo-tab <applications|startup|extensions|leftovers|fileManager|junkCleaner|resourceRelease>`：指定默认落点页签。
  - `--demo-lang <en|zh>`：覆盖渲染语言（支持分别导出英文与中文截图）。
  - `--demo-theme <deepOcean|system>`：覆盖主题风格。
  - `--export-screenshots <output_dir>`：无头/离屏自动导出 2x Retina 截图集并退出。
- **100% 虚构人物与路径夹具**：
  - 统一使用虚构用户名与主目录 `/Users/alex`（例如 `/Users/alex/Projects/swift-studio`、`/Users/alex/Downloads/macOS-15-Installer.dmg`、`/Users/alex/Library/Caches/...`）。
  - 统一使用虚构第三方应用与开发者标识：`NovaNote.app`（`com.novanote.desktop`）、`PixelForge Studio.app`（`io.pixelforge.studio`）、`CodePulse IDE.app`（`com.codepulse.ide`）、`CloudSync Drive.app`（`com.cloudsync.drive`）、`AudioWeave Pro.app`（`audio.audioweave.pro`）与 `DeckFlow.app`（`com.deckflow.presenter`）等。
  - 夹具中覆盖全部 7 个页签的逼真数据集：`AppItem`、`StartupItem`、`ExtensionItem`、`LeftoverGroup`、`DiskTreeNode`、`FileBrowserEntry`、`JunkCategoryItem`、`LargeFileItem`、`DuplicateGroup` 与 `MemorySnapshot`。
  - **硬性隐私禁忌**：`DemoFixtureCatalog` 与演示模式渲染路径中严禁调用 `NSUserName()`、`NSHomeDirectory()`、`FileManager.default.homeDirectoryForCurrentUser` 或扫描真实 `/Applications`。
- **合成图标渲染（`IconCache` 隔离）**：
  - 当 `isDemoMode == true` 时，`IconCache` 旁路 `NSWorkspace.shared.icon(forFile:)`，改为基于 CoreGraphics + SF Symbols 绘制确定性圆角矩形（Squircle）彩色合成图标，确保本机真实已安装应用的图标绝不泄漏至演示界面或截图。
- **严格副作用隔离（`AppState.isDemoMode == true`）**：
  - 禁用真实 `PreferencesStore` 与 `CleanupHistoryStore` 的磁盘读写（改用内存演示配置与演示清理历史）。
  - 禁用 `PermissionChecker` 真实 TCC 探测（返回稳定的演示授权状态）。
  - 禁用所有真实扫描器、进程枚举及 `RemovalEngine` / `FileOperationsEngine` / `StartupController` / `MemoryReleaseService` 对磁盘和系统的任何真实改动（交互操作仅在内存演示状态中响应，可安全演示确认弹窗与清理反馈）。

### 4.2 自动化 2x Retina 离屏截图管线（`DemoScreenshotExporter`）
- 当同时传入 `--demo-mode` 与 `--export-screenshots <output_dir>` 时：
  - 在非激活离屏 `NSWindow`（逻辑尺寸 `1120x700` pt，强制 `backingScaleFactor = 2.0`，输出 `2240x1400` px 高清 Retina PNG）中托管 `MainSplitView`。
  - 按预设列表自动切换 `--demo-tab`、语言（`en` / `zh`）与主题（`deepOcean` / `system`），等待 SwiftUI 布局与图形渲染完成。
  - 通过 `NSView.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` 导出 PNG 至 `docs/screenshots/`。
- **隐私泄漏自动审计（`DemoModeChecks`）**：
  - 静态与动态校验确保 `DemoFixtureCatalog` 输出及导出清单中不包含任何真实宿主机用户名、真实家目录路径或真实个人应用名称。

### 4.3 目标截图清单（`docs/screenshots/`）

| 序号 | 目标文件名 | 展示内容与验证要点 |
|---|---|---|
| 1 | `01-applications-dark-en.png` | **Applications 卸载视图**（深海蓝暗色）：展示 `NovaNote.app` 分桶体积、服务文件列表与右侧详情页 |
| 2 | `02-file-manager-analyzer.png` | **File Manager — 空间分析视图**：展示卷容量条、`/Users/alex` 目录体积占比条与面包屑下钻 |
| 3 | `03-file-manager-browser.png` | **File Manager — 通用文件浏览与预览**：展示目录列表、隐藏文件开关、文件操作栏与右侧元数据/安全预览面板 |
| 4 | `04-junk-cleaner.png` | **Junk & Cache Cleaner 视图**：展示分类缓存、日志、浏览器缓存、开发缓存与废纸篓条目及可释放总览 |
| 5 | `05-resource-release-duplicates.png` | **Resource Release — 重复文件**：展示三阶段 SHA-256 重复文件分组、智能保留勾选与可释放空间 |
| 6 | `06-resource-release-memory.png` | **Resource Release — 实时内存监控与释放**：展示 Mach VM Active/Wired/Compressed/Cached/Swap 分布与内存压力面板 |
| 7 | `07-startup-extensions-leftovers.png` | **Startup Programs 视图**：展示 LaunchAgents/Daemons、僵尸检测与 Plist XML 预览 |
| 8 | `08-settings-protection-light.png` | **设置与保护名单（浅色主题对比）**：展示 `SettingsSheet` 中新增的 `protectedPaths` 路径保护 UI 与跟随系统浅色主题效果 |
| 9 | `09-resource-release-large-files.png` | **Resource Release — 大文件排查**：展示大小/时间/类型过滤与右侧文件检查器 |
| 10 | `10-extensions.png` | **Extensions 视图**：展示 Chrome/Firefox/Safari 扩展与 QuickLook/HAL 系统插件 |
| 11 | `11-leftovers.png` | **Leftovers 视图**：展示高置信度与系统级孤立残留识别 |
| 12 | `12-showcase-zh-dark.png` | **简体中文主界面**：验证中文排版、标签与深海蓝主题展示效果 |

---

## 5. GitHub README 展示规划与现存文档修复

### 5.1 README 结构改版规划（`README.md`、`README_EN.md`、`README_ZH.md`）
1. **顶部 Hero 与导航栏**：保留 `Resources/AppIcon-1024.png` 图标、中英双语副标题（涵盖「应用卸载 · 启动项/扩展/残留 · 文件管理器 · 垃圾/重复/内存释放」）、文档导航链接（新增 `./docs/PLANNING.md` 入口）、`LICENSE` 与 `SECURITY.md`。
2. **新增可视化截图画廊（Visual Showcase Gallery）**：使用简洁的 Markdown / HTML 双栏图文网格嵌入 `docs/screenshots/*.png`，直观呈现应用卸载、磁盘空间分析、通用文件浏览、垃圾缓存清理、重复文件/内存释放与浅色保护设置页面。
3. **更新特性矩阵与系统架构图**：
   - 将功能与架构图中的「4 大功能页签」升级为完整的 **7 大功能页签**（Applications / Startup / Extensions / Leftovers / File Manager / Junk Cleaner / Resource Release）。
   - 同步更新 `Sources/MacSweepCore`、`Sources/MacSweepApp`（`MacSweepUI`）、`Sources/MacSweepAppEntry`（`MacSweepApp`）、`docs/`、`Tests/MacSweepChecks` 的最新目录结构说明。
4. **快速开始、构建校验与演示模式复现指南**：保留预编译包下载与源码编译步骤，并补充 `--demo-mode` 与 `--export-screenshots` 开发者复现命令，方便社区贡献者安全预览与生成文档截图。

### 5.2 已核实的文档不一致修复清单（M4–M5 同步修正）
1. **校验数量更新**：M0 基线 59 项叠加 M1–M5 新增校验（`FileOpsSafetyChecks`、`FileManagerChecks`、`JunkAndResourceChecks`、`DemoModeChecks`、`AppRuntimeChecks` 与 Tier-5 对抗回归校验）后，`swift run MacSweepChecks` 实际通过 **139 项**；`README.md`、`README_EN.md` 与 `README_ZH.md` 中校验数量已全部统一更新为 **`139`**。
2. **页签数量更新**：已将 `README*.md` 全部同步更新为 **7 大功能页签** 与完整模块结构。
3. **死链与路径校验**：保证 `README*.md` 引用的全部 `./docs/PLANNING.md` 与 `docs/screenshots/*.png` 均为有效相对路径，零 404 断链。

---

## 6. 分阶段实施路线图与验收标准（M1–M5 + E2E）

### 6.1 里程碑路线图

| 阶段 | 名称 | 核心交付物 | 依赖 | 状态 |
|---|---|---|---|---|
| **M1** | 规划文档与文件操作安全核心 | `docs/PLANNING.md`（R1）；`FileMutationModels.swift`、`SafetyGuard` 移动/重命名/新建目录/缓存子路径校验及 `FileOperationsEngine`（F2）；`SettingsSheet` 补齐 `protectedPaths` 增删 UI（F3）；`FileOpsSafetyChecks` | 无 | **已完成** |
| **M2** | 文件管理器（空间分析 + 通用浏览） | `DiskSpaceAnalyzer`、`FileBrowserService`、`DiskTreeNode`、`FileBrowserItem`、`FileManagerStore`、`FileManagerView`（空间分析 + 文件浏览 + QuickLook/安全预览 + 移动/重命名/新建/删除）、`SidebarRail`/`MainTab`/`L10n` 接入、`FileManagerChecks` | M1 | **已完成** |
| **M3** | 垃圾/缓存清理与扩展资源释放 | `JunkCacheScanner`、`LargeAndDuplicateScanner`、`MemoryReleaseService`、`JunkAndResourceModels`、`CleanupCenterStore`、`JunkCleanerView`、`ResourceReleaseView`（大文件 / 3 阶段去重 / Mach 内存监控与释放）、`SidebarRail`/`MainTab`/`L10n` 接入、`JunkAndResourceChecks` | M2 | **已完成** |
| **M4** | 脱敏演示模式、截图流水线与 README 更新 | `DemoFixtureCatalog`、`AppState`/`IconCache` 演示隔离、`DemoScreenshotExporter`（`--export-screenshots`）、`DemoModeChecks`、生成 `docs/screenshots/*.png`、隐私泄漏审计、更新 `README.md`/`README_EN.md`/`README_ZH.md`（含校验数量与 7 页签修正） | M3 | **已完成** |
| **E2E Track** | 独立黑盒端到端测试套件 | `TEST_INFRA.md`、`Tests/MacSweepE2E/`（Tiers 1–4 覆盖 F1–F11 核心契约与边界，`154/154` 严格通过），已发布 `TEST_READY.md` | 并行 | **已完成** |
| **M5** | 终验阶段：E2E 全通与 Tier-5 对抗加固 | 通过 Tiers 1–4 100% E2E 测试（154/154），完成 Tier-5 对抗性覆盖加固与审计修复（144 项校验全通）、最终构建、校验、截图与文档一致性总审 | M4, E2E | **已完成** |

### 6.2 最终验收清单（Acceptance Criteria）

- [x] **规划文档完整性**：`docs/PLANNING.md` 存在且清晰区分已实现基线与规划演进，完整覆盖 R1–R4、文件管理器、垃圾/缓存与扩展资源释放、脱敏截图方案、README 排版规划与 M1–M5 路线图，且不含任何真实宿主机用户名或个人路径。
- [x] **全工程编译与零外部依赖**：`swift build`、`swift build --target MacSweepApp` 与 `./make_app.sh` 编译无错；`otool -L` 确认无任何 `/opt/homebrew` 或 `/usr/local` 第三方动态库；`Sources/MacSweepCore/` 零 `SwiftUI` 导入；`Sources/MacSweepApp/` 与 `Sources/MacSweepAppEntry/` 零 `@State` 宏使用。
- [x] **交互真实完整**：所有新增界面（`SettingsSheet` 受保护路径管理、`FileManagerView`、`JunkCleanerView`、`ResourceReleaseView`）的按钮、开关、输入框与上下文动作均接入真实核心逻辑，无空壳按钮或占位流程。
- [x] **路径安全与原子边界**：所有删除、移动、重命名、新建目录与缓存清理均经过 `SafetyGuard` 三重解析校验、TOCTOU 父目录 FD 校验、`O_NOFOLLOW` 非跟随操作及 `ConfirmationSheet` 确认（默认废纸篓优先，含废纸篓混合批次独立按项分流），不误操作受保护的系统目录或共享厂商根目录。
- [x] **自动化测试与 E2E 全通**：`swift run MacSweepChecks`（144 项沙盒与回归校验，含原有 59 项 + M1–M5 新增与审计回归校验）与 `Tests/MacSweepE2E`（154/154 严格通过）100% 通过。
- [x] **脱敏截图与 GitHub README 一致性**：`--demo-mode --export-screenshots docs/screenshots` 可稳定复现高清 2x Retina 截图且零真实本机隐私泄漏；`README.md`、`README_EN.md`、`README_ZH.md` 所有图片链接有效，功能描述与实际校验数量 100% 一致。
