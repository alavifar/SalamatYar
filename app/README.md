# SalamatYar — cross-platform edition (preview)

The same app as the Windows edition in the repository root, rebuilt with [Tauri](https://tauri.app) so that it also runs on macOS and Linux. It is a preview: the stable release is still version 1.3 for Windows.

| | Windows edition (root) | This edition (`app/`) |
| --- | --- | --- |
| Runs on | Windows 10 and 11 | Windows, macOS, Linux |
| Built with | PowerShell + WPF | Rust + HTML/CSS/JS (Tauri 2) |
| Texts | `lang.json` | the same `lang.json`, plus `lang-extra.json` |
| Settings stored | next to the app | in the user's configuration folder |

## What is where

| Path | Purpose |
| --- | --- |
| `src-tauri/src/engine.rs` | Timers, statistics and break logic, with unit tests. No windows or sound. |
| `src-tauri/src/main.rs` | Windows, tray icon, commands called by the interface |
| `src-tauri/src/synth.rs`, `audio.rs` | Chimes and break music, synthesized by the app |
| `ui/` | The interface: `index.html` (main window), `break.html`, `toast.html` |
| `lang-extra.json` | The few texts that differ from the Windows edition |
| `ui/mock.js`, `tools/serve.js` | Preview of the interface in a browser, without building the app |

## Build

You need [Rust](https://rustup.rs), [Node.js](https://nodejs.org) and the [Tauri prerequisites](https://tauri.app/start/prerequisites/) for your system.

```
cd app
npm install
npm run tauri dev      # run from source
npm run tauri build    # build the installer for this system
```

Tests of the timer logic:

```
cd app/src-tauri
cargo test
```

## Preview the interface in a browser

```
cd app
npm run preview
```

Then open `http://localhost:4173/app/ui/index.html?lang=fa`. Useful parameters: `lang`, `theme` (`dark`, `light`, `auto`), `page` (`settings`, `guide`, `about`), and for `break.html`: `kind` (`eye`, `move`) and `mode` (`full`, `window`).

## Self-check of a build

```
salamatyar --minimized --selfcheck check.txt
```

Opens every kind of reminder for a moment with separate, silent settings, writes what happened to `check.txt` and exits.

## Known limits of the preview

- macOS and Linux builds are produced by GitHub Actions and have not been tested by the author on real machines. Reports are very welcome.
- The apps are not code-signed. Windows shows a SmartScreen warning; macOS needs "Open anyway" in Privacy & Security.
- On Linux, absence detection needs an X11 session; on Wayland the app works but does not notice that you are away.
- On Linux the tray icon needs a desktop with AppIndicator support.
- Audio formats for custom music: MP3, WAV, FLAC, OGG, M4A/AAC.

Vazirmatn (the font used for Persian and Arabic) is licensed under the SIL Open Font License; see `ui/fonts/OFL.txt`.
