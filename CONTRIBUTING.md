# Contributing to MacSweep / 贡献指南

Thank you for your interest in contributing to **MacSweep**!  
感谢您对 **MacSweep** 开源项目的关注与贡献！

---

## 简体中文指南

### 1. 开发环境准备
1. 运行在 **macOS 14.0 (Sonoma)** 或更高版本，已安装 Xcode Command Line Tools（Swift 6.0+，无需安装完整 Xcode.app，也无需 Homebrew）。
2. 克隆仓库并验证构建与校验套件：
   ```bash
   swift build
   swift run MacSweepChecks
   swift run MacSweepChecks --live-audit
   ```

### 2. 代码规范与约束
- **分层边界**：
  - `Sources/MacSweepCore` 保持纯引擎逻辑与模型定义，不引入 SwiftUI 视图代码，确保所有扫描、匹配、安全校验与命令构造逻辑均可在沙盒单测中独立验证。
  - `Sources/MacSweepApp` 需兼容仅安装 `/Library/Developer/CommandLineTools` 的构建环境（避免依赖需要完整 Xcode.app 的 SwiftUI Macro 插件，视图局部状态使用 `LocalState` + `@StateObject`，全局状态托管在 `@MainActor final class AppState: ObservableObject`）。
- **删除与提权安全**：
  - 任何删除路径构造与执行前都必须经过 `SafetyGuard.validateForRemoval` 双重校验（原始路径 + 解析后路径），且删除动作绝不跟随符号链接目标。
  - 传给 `/bin/sh` 的所有路径、标签与包名必须使用 `ProcessRunner.posixQuote` 单引号转义；传给 AppleScript 的字符串必须经过 `ProcessRunner.appleScriptEscape` 转义。
  - 任何涉及特权脚本、错误码传播或状态校验的修改，都必须在 `Tests/MacSweepChecks` 中补充回归用例，确保 `swift run MacSweepChecks` 100% 通过。
- **隐私与安全**：严禁在源码、测试、文档或截图中提交包含个人用户名、本机已安装应用列表、本机真实文件路径或内部专有软件信息的内容。

---

## English Guidelines

### 1. Development Setup
1. Requires **macOS 14.0 (Sonoma)** or later with Xcode Command Line Tools (Swift 6.0+; no full `Xcode.app` or Homebrew required).
2. Build and run the verification suite:
   ```bash
   swift build
   swift run MacSweepChecks
   swift run MacSweepChecks --live-audit
   ```

### 2. Coding Standards
- **Layer Separation**:
  - Keep `Sources/MacSweepCore` free of SwiftUI views so scanners, matchers, safety guards, and command builders remain cleanly testable in isolated temporary sandboxes.
  - Ensure `Sources/MacSweepApp` compiles cleanly with standalone Command Line Tools (`swift build` without requiring full `Xcode.app` macro plugins; use `LocalState` + `@StateObject` and `@MainActor final class AppState: ObservableObject`).
- **Removal & Privilege Safety**:
  - Every path scheduled for removal must pass `SafetyGuard.validateForRemoval` (validating both raw and symlink-resolved paths), and removal must operate on the raw URL without following symlinks.
  - Quote every shell operand via `ProcessRunner.posixQuote` and escape every AppleScript string via `ProcessRunner.appleScriptEscape`.
  - Add regression checks under `Tests/MacSweepChecks` for bug fixes or privilege/matching changes; all pull requests must pass `swift run MacSweepChecks` with 0 failures.
- **Privacy**: Never commit personal usernames, host app inventories, local file paths, or screenshots containing private application data.

---

## 预发布 / Preview Releases

推送到 `main` 后，CI 先在 `macos-15` 运行构建、`MacSweepChecks` 校验与 macOS arm64 安装包验证，再将此次推送的分支头发布为 `v<版本号>-<7位短提交 SHA>`（例如 `v1.0.0-abc1234`）预发布版本，并在 Release 标题附带提交说明。Release 提供 `MacSweep-arm64.zip`、校验和 `SHA256SUMS`、包含版本号与最低 macOS 版本的 `build-info.txt`，以及 GitHub 根据同一标签生成的源码 ZIP 和 tar.gz。安装包采用临时签名，供测试使用。

After each push to `main`, CI builds, runs `MacSweepChecks`, and verifies the macOS arm64 package before publishing it as a `v<version>-<short commit SHA>` (e.g. `v1.0.0-abc1234`) prerelease with the commit subject in the release title. The release includes `MacSweep-arm64.zip`, `SHA256SUMS`, `build-info.txt` with the version and minimum macOS version, and GitHub's source archives for the same tag. The app is signed ad hoc for testing.
