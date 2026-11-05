<p align="center"><img src="CleanBro/Icon/AppIcon.png?v=2" width="128" alt="CleanBro icon"></p>

# CleanBro

Two tools for inspecting and tidying up disk usage on macOS:

- **`cleanbro`**: a Go CLI that scans folder sizes quickly and in parallel, similar to `du`, with a tree view and a list of the largest files.
- **CleanBro**: a native SwiftUI app for cleaning junk files, uninstalling apps, and analyzing your disk.

![CleanBro](docs/screenshots/clean.png?v=2)

## Table of contents

- [Install the app](#install-the-app)
- [cleanbro (CLI)](#cleanbro-cli)
  - [Install](#install)
  - [Build](#build)
  - [Usage](#usage)
- [CleanBro (macOS app)](#cleanbro-macos-app)
  - [Features](#features)
  - [Build](#build-1)
  - [Permissions](#permissions)
- [CI/CD](#cicd)
- [Changelog](#changelog)
- [Project structure](#project-structure)
- [License](#license)

## Install the app

Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel. Pick the easiest option that works for you:

**1. One-line install (easiest)**

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/jetorbitdev/cleanbro/main/install.sh | bash
```

It downloads the latest release, verifies its checksum, installs it to `/Applications`, and opens it. No Gatekeeper prompt, because files downloaded with `curl` aren't quarantined. It may ask for your password if `/Applications` needs admin rights.

**2. Download the zip**

1. Download `CleanBro.zip` from the [latest release](https://github.com/jetorbitdev/cleanbro/releases/latest).
2. Double-click it to extract, then drag `CleanBro.app` into **Applications**.
3. Open it. macOS will refuse with *"can't be opened"* because the app isn't notarized.
4. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

**3. Build from source**: see [Build](#build-1) below.

On first launch, CleanBro asks for **Full Disk Access**. Click **Buka Pengaturan** (Open Settings), turn on CleanBro in the list (or drag it in from the Finder window that opens), then reopen the app.

## cleanbro (CLI)

### Install

Download `cleanbro-cli-macos-universal.tar.gz` from the [latest release](https://github.com/jetorbitdev/cleanbro/releases/latest), then:

```sh
tar -xzf cleanbro-cli-macos-universal.tar.gz
xattr -d com.apple.quarantine cleanbro
sudo mv cleanbro /usr/local/bin/
```

### Build

Requires Go (see the version in `go.mod`).

```sh
go build -o bin/cleanbro .
```

The output goes to `bin/` because a plain `-o cleanbro` would collide with the `CleanBro/` folder on case-insensitive filesystems.

### Usage

```sh
cleanbro [options] [path]     # default path: ~
```

| Option | Default | Description |
|--------|---------|-------------|
| `-d` | `1` | Tree depth to display |
| `-n` | `20` | Number of top folders per level (`0` = all) |
| `-f` | `15` | Show the N largest files (`0` = off) |
| `-x` | `false` | Don't cross into other filesystems/volumes |
| `-j` | `CPU × 4` | Number of parallel goroutines |

Examples:

```sh
cleanbro ~
cleanbro -d 2 -n 10 ~/Library
sudo cleanbro -d 1 /
```

Sample output:

```
📁 ~/Library  —  total 35.9 GiB, 279216 file, 77335 folder  (5.33s)

  24.8 GiB  ██████████████░░░░░░  69.0%  Application Support/
   3.8 GiB  ██░░░░░░░░░░░░░░░░░░  10.6%  Containers/
   3.7 GiB  ██░░░░░░░░░░░░░░░░░░  10.2%  Developer/
   3.2 GiB  ██░░░░░░░░░░░░░░░░░░   9.1%  Caches/
 154.6 MiB  ░░░░░░░░░░░░░░░░░░░░   0.4%  HTTPStorages/
 285.3 MiB                               … 108 folder lainnya

💾 Volume: 202.6 GiB terpakai dari 228.3 GiB, sisa 25.7 GiB
```

Notes:

- Sizes are the disk blocks actually allocated (like `du`), not the logical file size.
- Hard links are counted only once.
- `/Volumes`, `/System/Volumes`, and `/dev` are skipped to avoid double counting, unless that path itself is being scanned.
- If you see a "permission denied" warning, run with `sudo` or grant **Full Disk Access** to Terminal (System Settings → Privacy & Security).

## CleanBro (macOS app)

Requires macOS 14 (Sonoma) or later and the Swift 6 toolchain (Xcode 16+).

### Features

**Tools**
- **Home**: start screen with a disk-usage map (including a breakdown of *Other* space), stat cards, and a collect-and-trash bar.
- **Cleanup**: scans and removes app caches, logs and crash reports, developer data (Xcode DerivedData, DeviceSupport, simulator caches, npm, Gradle, `~/.cache`), incomplete downloads, and the Trash.
- **Uninstall Apps**: removes an app together with its support files. Apps installed from a Homebrew cask can be removed through Homebrew.
- **Homebrew**: lists installed formulae and casks with their sizes, uninstalls them (optionally with zap), and runs `brew cleanup`.

**Analysis**
- **Disk Usage**: folder size tree.
- **Large Files**: files of 100 MB or more.
- **Stale Files**: files that haven't been modified in a long time.
- **Duplicate Files**: finds duplicates by size, then by SHA-256 hash.

Files can be moved to the Trash or deleted permanently. Folders you don't want scanned can be excluded in Settings (⌘,).

**Appearance and language**: System, Light or Dark mode (sidebar button, View menu, or Settings › General), and an English or Bahasa Indonesia interface (Settings › General).

### Build

```sh
cd CleanBro
./build.sh
open build/CleanBro.app
```

`build.sh` builds a universal (Apple Silicon + Intel) release with SwiftPM, assembles the `CleanBro.app` bundle (with `Icon/AppIcon.icns`) in `CleanBro/build/`, signs it ad-hoc, and creates `CleanBro.zip` for sharing.

To use it on another Mac, share `CleanBro.zip` (don't copy the `.app` folder directly). Because the app isn't notarized by Apple, macOS blocks it when it was downloaded or received through a browser, AirDrop, or a chat app. On macOS 26 this shows up as *"The application “CleanBro.app” can't be opened."* (running the binary from Terminal reports `operation not permitted`). To allow it, open **System Settings → Privacy & Security** and click **Open Anyway**, or from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/CleanBro.app
```

If it still won't open, the bundle may have been damaged in transit (the executable permission was lost, or `._*` files ended up inside it). Re-extract the zip with Archive Utility (double-click it), or repair it from Terminal:

```sh
APP=/Applications/CleanBro.app
find "$APP" -name '._*' -delete
chmod +x "$APP/Contents/MacOS/CleanBro"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
```

To regenerate the app icon, run `swift Icon/make-icon.swift` from the `CleanBro/` folder.

For development:

```sh
cd CleanBro
swift run
```

### Permissions

To read the Trash and some folders in `~/Library`, grant CleanBro **Full Disk Access** in System Settings → Privacy & Security → Full Disk Access. The app shows a reminder if this permission hasn't been granted yet.

## CI/CD

GitHub Actions ([`.github/workflows/build.yml`](.github/workflows/build.yml)) builds `CleanBro.app` and the universal `cleanbro` CLI on every push to `main` and on pull requests. Build outputs can be downloaded as artifacts from the **Actions** tab.

To release, push a version tag. The workflow creates a GitHub Release containing `CleanBro.zip`, `cleanbro-cli-macos-universal.tar.gz`, and `SHA256SUMS.txt`, with the app version taken from the tag name:

```sh
git tag v1.0.0
git push origin v1.0.0
```

## Changelog

### v1.1.1 (2026-11-05)

- Fix: the DIR / file-type badge is now readable on selected rows in both light and dark themes.

### v1.1.0 (2026-11-04)

- **Home dashboard**: new default start screen with a disk-usage map, stat cards, and a collect-and-trash bar.
- **Other space breakdown**: the *Other* block on the map can be opened to show other APFS volumes in the startup container (Preboot, Recovery, VM/swap, Update), skipped folders with their measured size, and what couldn't be read, with the reason (permission errors, local snapshots, cloud folders). A Full Disk Access button appears when items couldn't be read.
- **Homebrew tool**: list installed formulae and casks with sizes, uninstall (optionally zap), and run `brew cleanup`. Uninstall Apps tags cask-installed apps and offers to remove them through Homebrew so brew's records stay in sync.
- **Light/dark mode**: System, Light or Dark, from the sidebar, the View menu, or Settings › General.
- **Language**: English (default) or Bahasa Indonesia; dates and numbers follow the choice.
- New theme, refreshed sidebar, and a matching split divider.
- Build: the development region is now `en`, so AppKit's own menus no longer default to Indonesian.

### v1.0.2 (2026-11-03)

- New broom app icon.
- One-line installer (`install.sh`) and an easiest-first install guide.
- The app asks for Full Disk Access on first launch.

### v1.0.1 (2026-11-03)

- The CLI was renamed from `cekdisk` to `cleanbro`.

### v1.0.0 (2026-11-03)

- First release: the `cleanbro` CLI and the CleanBro app (Cleanup, Uninstall Apps, Disk Usage, Large Files, Stale Files, Duplicate Files), universal builds, and GitHub Releases from version tags.

## Project structure

```
.
├── main.go            # cleanbro CLI source
├── go.mod
├── install.sh         # one-line installer for the app
├── CleanBro/
│   ├── Package.swift
│   ├── build.sh       # build & bundle the .app
│   ├── Icon/          # AppIcon.icns + make-icon.swift generator
│   └── Sources/CleanBro/
├── docs/screenshots/  # README images
└── template/          # UI design mockup (HTML)
```

## License

Copyright (C) 2026 gilang

This program is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License version 3](LICENSE) as published by the Free Software Foundation.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY. See the [LICENSE](LICENSE) file for details.
