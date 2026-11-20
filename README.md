# MacSweep

原生 macOS 应用清理与卸载工具，采用纯 Swift + SwiftUI/AppKit 与 SwiftPM 构建，零第三方运行时依赖、零后台常驻进程。

## 核心功能

- **应用程序（卸载 / 重置 / 拖放快卸）**：基于一次性内存 `LibraryIndex` 索引 + `pkgutil` 懒查关联全部服务文件（Caches / Preferences / Application Support / Containers / Group Containers / Saved State / LaunchAgents & Daemons 等），支持体积分组折叠、异步限流体积计算、彻底卸载、仅重置应用数据以及拖放任意 `.app` 快速分析。
- **启动程序**：统一查看与启停 `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`（结合 `launchctl print-disabled` 还原真实状态），检测可执行文件已缺失的僵尸启动项，并展示应用内嵌登录项与系统设置快捷入口。
- **扩展**：覆盖 Chrome / Edge / Brave / Arc / Firefox / Safari 浏览器扩展、`pluginkit` 第三方 `.appex` 应用扩展以及 macOS 偏好设置面板、QuickLook、Spotlight、屏保、互联网与音频（含 HAL）插件。无完全磁盘访问权限时自动降级并引导授权。
- **残留文件**：构建全机已安装应用指纹库，内置 Apple 系统组件与常见开发/CLI 目录防误杀保护，按「高置信度 / 建议核对」分级展示孤立残留并支持永久忽略。
- **安全与体验**：默认移至废纸篓（root/受限项优先委托 Finder `delete` 保留「放回原处」，拒绝自动化授权时自动降级为批量提权 `mv`）；支持深海蓝暗色（默认）与跟随系统浅/深色主题切换、中/英双语即时切换。

## 本地构建与验证

无需安装完整 Xcode.app，仅需 macOS Command Line Tools（Swift 6+）：

```bash
# 运行核心引擎沙盒校验（19 项）
swift run MacSweepChecks

# 执行只读本机扫描巡检
swift run MacSweepChecks --live-audit

# 编译 Release 版本并打包签名 dist/MacSweep.app
./make_app.sh

# 启动应用
open dist/MacSweep.app
```

`make_app.sh` 会自动检测本机钥匙串中的 `Apple Development` 证书进行签名（保证完全磁盘访问 / 应用管理等 TCC 授权跨重编不失效）；也可以通过 `MACSWEEP_SIGN_IDENTITY="..." ./make_app.sh` 指定签名身份。
