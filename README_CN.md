<p align="center">
  <img src="img/flowmori-app-icon.png" width="128" alt="Flowmori 应用图标">
</p>

# Flowmori

[English](README.md) | [简体中文](README_CN.md)

原生 macOS 菜单栏工具，提供剪贴板历史、截图标注、悬浮贴图和菜单栏收纳。使用 Swift、AppKit 和 SwiftUI 构建，数据保存在本机。

<p align="center">
  <img src="img/flowmori-hero.png" width="900" alt="Flowmori 主视觉">
</p>

## 功能

- **剪贴板历史：** 搜索、收藏和复制文本与图片，可暂停记录或排除指定应用。默认保留 500 条普通记录，收藏不自动清理。
- **截图标注：** 框选区域、调整大小，添加矩形、箭头、文字或自由绘制。通过截图工具条直接复制、保存或贴图。
- **悬浮贴图：** 将剪贴板图片固定在屏幕上，支持多张贴图、移动、缩放、复制、保存、隐藏和关闭。
- **菜单栏收纳：** 将支持的应用图标集中到面板中，保留系统状态项，并从面板访问支持的菜单和弹窗。

## 安装

需要 **Apple Silicon Mac，macOS 26 或更高版本**。当前应用界面以简体中文为主。

1. 从 [Releases](https://github.com/BaiYu96/flowmori/releases) 下载 DMG。
2. 打开 DMG，将 **Flowmori.app** 拖到 **Applications**。
3. 从「应用程序」启动 Flowmori，再推出磁盘映像。更新时先退出正在运行的旧版，再拖入替换。

当前版本为**早期预览版**，使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 可能阻止首次启动。仅在信任来源时，通过「系统设置 → 隐私与安全性」提供的选项批准打开，不要关闭系统安全保护。目前不支持自动更新。

菜单栏收纳为实验功能，仅在 **macOS 26.6.2（构建号 25G83）** 启用。该功能依赖系统内部接口，其他系统构建会禁用收纳。目前启动新应用可能导致收纳自动展开并暂停，可点击「收纳全部」重试。

## 快速上手

左键点击 Flowmori 菜单栏图标打开收纳面板；右键打开全部工具、设置和退出菜单。

| 默认快捷键 | 操作 |
| --- | --- |
| Option + V | 在鼠标附近打开／关闭剪贴板历史 |
| Option + A | 框选截图并标注 |
| Option + P | 将剪贴板图片贴到屏幕 |
| Option + M | 打开／关闭菜单栏收纳面板 |

快捷键可在设置中修改。选择历史条目后会复制内容，再到目标应用按 **⌘V** 粘贴。使用收纳前，先在设置中启用该功能并授予辅助功能权限，再点击「收纳全部」。

全新安装默认开启登录启动，可在设置中关闭。

## 权限与隐私

- **屏幕录制：** 用于截图和显示菜单栏图标图像，不录制音频或麦克风。
- **辅助功能：** 用于菜单栏交互。剪贴板读取遵循 macOS 的授权设置。
- **本机存储：** 历史与图片保存在 `~/Library/Application Support/Flowmori/`，不提供云同步、不上传数据、不发送遥测。
- **敏感内容：** 跳过带有保密、临时标记的剪贴板内容，默认排除部分密码管理器。无法可靠识别未标记的敏感文本，可手动暂停记录或排除来源应用。

暂不记录文件复制及包含多个独立对象的复制，单条历史上限为 32 MB。重新构建或更新 ad-hoc 签名的应用后，可能需要重新授权；建议从固定安装位置运行。

从 MacFlow 或使用旧应用标识符的 Flowmori 升级时，请查看[迁移说明](docs/MIGRATION.md)。

## 从源码构建

需要带有 Swift 6 工具链的 Apple Command Line Tools，无第三方包依赖。

```sh
bash scripts/build-app.sh release
open dist/Flowmori.app
```

若要构建、安装到 `~/Applications` 并启动，请先退出已运行的实例，再执行 `bash scripts/install.sh`。

```sh
# 运行测试
bash scripts/swift-command.sh test

# 将已有签名构建打包为 DMG、应用 ZIP 和源码 ZIP
bash scripts/package.sh
```

打包不会重新构建或签名。源码包仅包含 Git 已跟踪的公开源码文件，新增源码需先暂存。诊断与实机检查步骤见[测试与验证](docs/TESTING.md)。

## 反馈与许可证

欢迎通过 [GitHub Issues](https://github.com/BaiYu96/flowmori/issues) 反馈问题或建议。菜单栏问题请附上 macOS 版本与构建号、相关应用和复现步骤。

采用 [MIT 许可证](LICENSE)。
