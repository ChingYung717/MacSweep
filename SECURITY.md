# Security Policy / 安全策略

## 删除安全边界、提权隔离与隐私声明 (Removal Safety Boundaries, Privilege Isolation & Privacy)

### 1. 文件删除安全护栏 (`SafetyGuard`)
- **不可逾越的系统与用户关键目录**：`SafetyGuard.validateForRemoval` 在任何删除与命令生成之前强制拦截根目录（`/`）、`/System`、`/Library/Apple`、`/usr/bin`、`/usr/sbin`、`/usr/lib`、`/bin`、`/sbin`、`/private/var/db/receipts`、`/Applications`、用户主目录及所有核心 `~/Library/*` 父目录，以及共享厂商父目录（如 `Application Support/Microsoft`、`Google`、`Adobe` 等）。
- **SIP 与系统卷保护**：通过 POSIX `lstat` 检测 `SF_RESTRICTED` 与 `SF_IMMUTABLE` 标志，并识别指向 `/System/` 或 `/Library/Apple/` 的符号链接（如 `/Applications/Safari.app`），防止误删内置系统应用。
- **符号链接双重校验与防跟随**：校验阶段同时检查原始标准化路径与 `resolvingSymlinksInPath()` 目标路径（拦截指向关键目录的逃逸符号链接）；执行删除阶段始终作用于原始 URL（`FileManager.trashItem` / `removeItem`、`/bin/mv`、`/bin/rm -rf` 与 `chown -R -P` 均不跟随符号链接），绝不误删链接目标文件。
- **自我保护与用户保护名单**：MacSweep 始终阻止删除自身 `.app` 包与 `~/Library/Application Support/MacSweep` 数据目录，并严格遵守用户在设置中配置的受保护 Bundle ID 与跳过路径。

### 2. 提权执行与命令注入防护 (`PrivilegedExecutor` & `StartupController`)
- **废纸篓优先与最小权限**：普通用户可写项直接调用系统 `FileManager.trashItem`；仅当项属 root 或父目录不可写时，废纸篓模式优先通过 Finder Apple Events 执行 `delete`（保留「放回原处」且复用系统原生鉴权）；仅在 Finder 自动化被拒时降级为单次管理员提权的批量 `mv` + `chown -R -P`。
- **严格转义与参数白名单**：所有拼入 Shell 的路径、服务名与 `launchctl` 目标均通过 `ProcessRunner.posixQuote` 单引号转义；拼入 AppleScript 的字符串均通过 `ProcessRunner.appleScriptEscape` 转义；`pkgutil --forget` 仅允许符合 `[A-Za-z0-9._-]` 且非 `com.apple.pkg.*` 的第三方包 ID，且仅在永久删除成功且无前序失败时才执行。
- **错误传播与逐项核验**：特权脚本为每个目标独立捕获退出码（防止 `|| true` 掩盖删除失败），执行结束后引擎对每个目标重新以 `lstat` 核实磁盘状态，绝不盲信批量脚本退出码。
- **删除启动项前先卸载 `launchd` 服务**：移除任何 `LaunchAgents` / `LaunchDaemons` plist 前，先执行 `launchctl bootout` 并重试校验 `launchctl print` 确认服务不再加载；若服务仍存活，则自动保留对应 plist 并向用户报错。
- **运行中应用安全退出**：卸载或重置前仅向运行中应用发送温和退出请求，超时后取消本次删除（绝不静默强杀导致文档丢失），仅由用户在提示栏显式点击后才执行强制退出。

### 3. 权限与隐私边界
- **无侵入式完全磁盘访问（FDA）检测**：`PermissionChecker` 通过原始 `open(O_RDONLY)` 探测系统 TCC 数据库权限，不读取其他应用容器数据，避免在启动时触发无关的 TCC 弹窗。
- **完全离线、零遥测**：MacSweep 不发起任何网络请求，不收集任何分析或崩溃遥测数据，且无任何后台常驻进程；本地仅在 `~/Library/Application Support/MacSweep/` 保存 `preferences.json` 与 `history.json`。

---

## English Summary

### 1. Removal Guardrails (`SafetyGuard`)
- **Critical & Immutable Path Blocking**: Every removal target is validated before execution or script generation against critical root, system, user, and shared-vendor directories as well as immutable prefixes (`/System/`, `/Library/Apple/`, `/usr/bin/`, `/private/var/db/receipts/`, etc.).
- **SIP & Symlink Safety**: Uses POSIX `lstat` to detect `SF_RESTRICTED` / `SF_IMMUTABLE` flags and symlinks pointing into `/System/` or `/Library/Apple/`. Both raw and symlink-resolved paths are checked to prevent symlink-escape deletion of protected directories, while actual removal operates strictly on the raw URL without following symlinks.
- **Self-Protection & Skip Lists**: Blocks removal of MacSweep's own bundle, its support directory (`~/Library/Application Support/MacSweep`), and any user-configured protected bundle IDs or paths.

### 2. Privilege Isolation & Injection Defense (`PrivilegedExecutor` & `StartupController`)
- **Trash-First & Least Privilege**: User-writable items use `FileManager.trashItem`. Root/protected items in Trash mode delegate to Finder `delete` first (preserving Put Back) and fall back to a single-prompt elevated `mv` + `chown -R -P` into `~/.Trash` only if Finder automation is denied.
- **Strict Escaping & Sanitization**: Every shell operand is POSIX single-quoted (`ProcessRunner.posixQuote`) and every AppleScript literal is escaped (`ProcessRunner.appleScriptEscape`). `pkgutil --forget` accepts only sanitized ASCII third-party package IDs (excluding `com.apple.pkg.*`) and runs only on permanent removal after deletion succeeds.
- **Explicit Error Propagation & Per-Item Reconciliation**: Privileged batch scripts isolate per-item status so failures are never masked, and `RemovalEngine` reconciles each target via `lstat` afterward.
- **Launchd Bootout Before Plist Deletion**: LaunchAgent/LaunchDaemon plists are unloaded with `launchctl bootout` and verified via `launchctl print` before removal; any plist whose service remains loaded is preserved.
- **Graceful App Termination**: Running apps are terminated gracefully first; if they do not exit, removal aborts cleanly without deleting files unless the user explicitly chooses Force Quit.

### 3. Permissions & Privacy
- **Non-Invasive FDA Probe**: Checks Full Disk Access with `open(O_RDONLY)` on system TCC metadata without probing other apps' private containers.
- **Offline & Zero Telemetry**: MacSweep makes zero network connections, collects zero telemetry, and runs zero background daemons. Only local `preferences.json` and `history.json` are stored under `~/Library/Application Support/MacSweep/`.

---

## 仓库安全基线与维护者核查清单 (Repository Security Checklist)

仓库管理员在 GitHub 远端维护时，可通过以下命令核查并开启仓库级安全设置：

```bash
# 1. 开启私密漏洞报告 (Private Vulnerability Reporting) 与 Dependabot 告警/自动安全更新
gh api -X PUT repos/ChingYung717/MacSweep/private-vulnerability-reporting
gh api -X PUT repos/ChingYung717/MacSweep/vulnerability-alerts
gh api -X PUT repos/ChingYung717/MacSweep/automated-security-fixes

# 2. 开启 Secret Scanning 与 Push Protection
gh api -X PATCH repos/ChingYung717/MacSweep \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

# 3. 为 main 分支绑定必过 CI 检查 ("Build, Test & Package (macOS arm64)") 并禁止强推/删除
gh api -X PUT repos/ChingYung717/MacSweep/branches/main/protection \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Build, Test & Package (macOS arm64)"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

请通过 GitHub 仓库的私密漏洞报告渠道提交安全问题。/ Please report vulnerabilities through GitHub's private vulnerability reporting channel.
