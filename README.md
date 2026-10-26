<p align="center">
  <img src="img/flowmori-app-icon.png" width="128" alt="Flowmori app icon">
</p>

# Flowmori

[English](README.md) | [简体中文](README_CN.md)

A native macOS menu bar app for clipboard history, annotated screenshots, floating image pins, and menu bar organization. Built with Swift, AppKit, and SwiftUI. Your data stays on your Mac.

<p align="center">
  <img src="img/flowmori-hero.png" width="900" alt="Flowmori overview">
</p>

## Features

- **Clipboard history:** Search, favorite, and copy saved text and images. Pause recording or exclude apps. Keeps 500 regular entries by default; favorites are retained.
- **Screenshots:** Select an area, resize it, and annotate with rectangles, arrows, text, or freehand drawing. Copy, save, or pin the result from the capture toolbar.
- **Image pins:** Keep clipboard images floating on screen. Move and resize multiple pins, then copy, save, hide, or close them.
- **Menu bar organization:** Collect supported app icons into a panel while keeping system items visible. Access supported menus and popovers from the panel.

## Install

Requires an **Apple Silicon Mac running macOS 26 or later**. The interface is currently primarily in Simplified Chinese.

1. Download the DMG from [Releases](https://github.com/BaiYu96/flowmori/releases).
2. Open it and drag **Flowmori.app** onto **Applications**.
3. Launch Flowmori from Applications, then eject the disk image. Quit the existing app before replacing it when updating.

Current releases are **early previews**, ad-hoc signed and not Apple notarized. macOS may block the first launch. Only open builds you trust, using the approval options in System Settings → Privacy & Security; do not disable system security protections. Automatic updates are not available.

Menu bar organization is experimental and only enabled on **macOS 26.6.2, build 25G83**. It uses internal system interfaces; other OS builds leave this feature disabled. Launching a new app may currently cause collection to expand and pause; use “收纳全部” (Collect All) to retry.

## Quick start

Click the Flowmori menu bar icon to open the collection panel. Right-click it for all tools, Settings, and Quit.

| Default shortcut | Action |
| --- | --- |
| Option + V | Toggle clipboard history near the pointer |
| Option + A | Capture and annotate a screen region |
| Option + P | Pin the clipboard image |
| Option + M | Toggle the menu bar collection panel |

Shortcuts can be changed in Settings. Selecting a history item copies it; press **⌘V** in the destination app to paste. To organize icons, enable the feature in Settings, grant Accessibility access, and click “收纳全部” (Collect All).

New installations enable launch at login by default. You can change this in Settings.

## Permissions and privacy

- **Screen Recording:** Used to capture screenshots and display menu bar icon images. Flowmori does not record audio or microphone input.
- **Accessibility:** Required for menu bar interaction. Clipboard access follows macOS authorization settings.
- **Local storage:** History and images are stored in `~/Library/Application Support/Flowmori/`. No cloud sync, uploads, or telemetry.
- **Sensitive content:** Confidential and temporary clipboard markers are skipped, and some password managers are excluded by default. Unmarked sensitive text cannot be reliably detected; pause recording or exclude its source app as needed.

File copies and copies containing multiple independent objects are not recorded. Each history item is limited to 32 MB. Rebuilding or updating an ad-hoc-signed app may require granting permissions again; run it from a fixed installation location.

Upgrading from MacFlow or an older Flowmori bundle ID? See the [migration notes (Chinese)](docs/MIGRATION.md).

## Build from source

Requires Apple Command Line Tools with Swift 6. No third-party packages are needed.

```sh
bash scripts/build-app.sh release
open dist/Flowmori.app
```

To build, install into `~/Applications`, and launch, quit any running instance first and run `bash scripts/install.sh`.

```sh
# Run tests
bash scripts/swift-command.sh test

# Package the existing signed build as DMG, app ZIP, and source ZIP
bash scripts/package.sh
```

Packaging does not rebuild or re-sign the app. Source archives include only tracked public source files; stage new source files before packaging. See [testing and runtime verification (Chinese)](docs/TESTING.md) for diagnostics and manual checks.

## Feedback and license

Report bugs or request features in [GitHub Issues](https://github.com/BaiYu96/flowmori/issues). For menu bar issues, include your macOS version and build, the affected app, and steps to reproduce.

Licensed under the [MIT License](LICENSE).
