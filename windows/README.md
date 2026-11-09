# CleanBro for Windows

Tauri v2 app: Rust backend (`src-tauri/`), plain HTML/JS UI (`ui/`). Separate from the macOS SwiftUI app in `../CleanBro`.

## Status

- [x] Disk Usage (folder size tree)
- [x] Large Files, Stale Files, Duplicates (SHA-256, three-pass) with Recycle Bin removal
- [x] Cleanup (`%TEMP%`, browser/GPU caches, crash dumps, dev caches, partial downloads, Recycle Bin)
- [ ] Uninstall Apps (registry `Uninstall` keys)
- [ ] winget / Scoop tool (replaces Homebrew)

## Develop

```sh
pnpm install
pnpm tauri dev      # run
pnpm tauri build    # NSIS installer (on Windows)
```
