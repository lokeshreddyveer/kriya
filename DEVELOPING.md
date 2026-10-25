# Developing Kriya

Notes for building and changing the app. What the app does and how to use it is in README.md.

## Building and testing

Scripts: `scripts/build-core.sh` (Rust tests, bindings, universal library), `scripts/swift-build.sh` (debug build), `scripts/release.sh <version> <build>` (signed, notarized DMG).

## Layout

```
core/                         Rust core, shared by every platform (Windows later)
  crates/kriya-core/            profiles · action engine · rules · configuration · SQLite storage · backup · crash-guard logic
apps/macos/                   The macOS app: SwiftUI + AppKit
  Sources/Core/                 stores the interface binds to (settings, profiles, actions, backup, crash guard)
  Sources/Adapter/              macOS-only parts: permissions, event tap, IOHID devices, action executor, services, updates
  Sources/UI/                   menu-bar popover and the settings window
  Tests/                        unit tests (use throwaway folders; never the real data)
scripts/build-core.sh         builds the universal Rust library + Swift bindings; `build-core.sh test` runs tests and lints
scripts/release.sh            sign, notarize, staple, DMG
```

The split follows the architecture diagram: the core decides *what* (which features are off in this app, what an action
means, whether it is allowed); the macOS adapter does the OS work (Accessibility, CGEventTap, IOKit, Finder extension).
Nothing in `core/` knows about macOS, so a Windows app can reuse it.

## Build

Needs Xcode, Rust (the toolchain is pinned in `core/rust-toolchain.toml`) and XcodeGen.

```sh
scripts/build-core.sh                      # Rust core -> apps/macos/Generated (xcframework + Swift bindings)
cd apps/macos && xcodegen generate         # -> Kriya.xcodeproj
open Kriya.xcodeproj                       # run the Kriya scheme
scripts/build-core.sh test                 # core tests, clippy, fmt
```

`apps/macos/Generated/` is produced by the first script and is not checked in.

## Phase 1 checklist

| # | Item | Where |
|---|------|-------|
| 1 | Swift, SwiftUI, AppKit | `apps/macos/Sources` |
| 2 | Universal binary (arm64 + x86_64) | `ARCHS_STANDARD` in `project.yml`; `build-core.sh` lipos both; `release.sh` checks it |
| 3 | Menu-bar app with popover | `UI/StatusItemController.swift`, `UI/PopoverView.swift` |
| 4 | Settings window with sidebar | `UI/Settings/SettingsWindow.swift` and the panes beside it |
| 5 | Launch at login | `Adapter/LaunchAtLogin.swift` (SMAppService) |
| 6–9 | Accessibility / Input Monitoring, on-demand requests, live status and recovery | `Adapter/PermissionManager.swift`, `Adapter/ServiceManager.swift` |
| 10 | Modular architecture | core crate + `FeatureModule` protocol |
| 11 | Central configuration | core `AppSettings` + `Core/ConfigStore.swift` |
| 12 | SQLite storage | `core/.../store.rs` (versioned migrations, WAL, integrity check) |
| 13 | Shared device registry | `store.rs` devices table + `Adapter/DeviceRegistry.swift` |
| 14 | Shared action engine | `core/.../actions.rs` (validate, flatten) + `Adapter/ActionExecutor.swift` |
| 15 | Global event monitoring | `Adapter/EventMonitor.swift` (one shared tap, own thread, auto re-enable) |
| 16 | Service lifecycle | `Adapter/ServiceManager.swift` (start/stop by setting, permission, safe mode; wake from sleep) |
| 17 | Profile foundation | `core/.../profiles.rs`, `Core/ProfileStore.swift`, `UI/Settings/ProfilesPane.swift` |
| 18 | Feature switches | Features pane and popover |
| 19 | Crash recovery and safe mode | `core/.../session.rs`, `Core/CrashGuard.swift`, `Support/CrashSignalHandler.swift` |
| 20 | Local diagnostic log | `Support/Log.swift`, Diagnostics pane |
| 21 | Backup and restore | `core/.../backup.rs`, `Core/BackupManager.swift`, Backup pane |
| 22 | Light / dark / system | `ConfigStore.applyAppearance` |
| 23 | Automatic updates | `Adapter/UpdateManager.swift` (Sparkle; the public key is built in) |
| 24 | Signing and notarization | `scripts/release.sh` |

Phase 1 ships the feature switches with placeholder modules. Each feature arrives in its own phase and replaces its
`ScaffoldModule`. Mouse & Trackpad (Phase 2) is the first real one.

## Phase 2 checklist (mouse & trackpad)

| # | Item | Where |
|---|------|-------|
| 1–5 | Detection of mice and trackpads, USB, Bluetooth and receiver, via IOHIDManager | `Adapter/DeviceRegistry.swift` (`classify` is unit-tested) |
| 6, 8 | Separate settings per device; default and custom presets | `core/.../mouse.rs`, `mouse_store.rs`, Devices tab |
| 7 | Rename devices | Devices pane |
| 9–15 | Reverse, per-axis speed, smoothing, acceleration, sensitivity | `core/.../scroll.rs`, `Adapter/MouseFeature.swift`, `SmoothScrollDriver.swift` |
| 16–18 | Pointer speed, acceleration presets, precision mode | `Adapter/PointerTuner.swift` |
| 19–24 | Middle and extra buttons to keys, apps, window actions, scripts | button rules, `Adapter/ActionExecutor.swift` |
| 25–28 | Button gestures, directions, rocker, distance and time limit | `core/.../gestures.rs` |
| 29–31 | Per-app presets, automatic switching, app exclusions | `MouseStore`, Apps tab |
| 32 | Connect and disconnect handling | `DeviceRegistry` + `MouseFeature` re-apply |
| 33 | Input latency diagnostics (average, p95, p99, worst) | `EventMonitor`, Diagnostics pane |
| 34 | Preset import and export; backups include mouse data | `mouse_store.rs`, Presets menu |
| 35 | Restore defaults (default preset, or everything) | Presets menu |

Window actions in button rules (`window.left_half` and so on) are saved now and start working in the Window Management phase.

## Known limits and things to check by hand

Everything compiles and passes its tests, but these were never exercised on a real desktop and are the most likely to need attention:
- **Finder extension:** needs to be enabled in System Settings, and the temporary home-relative read exception in `KriyaFinder.entitlements` makes it unsuitable for the Mac App Store. Finder sometimes needs a relaunch to show the menu.
- **Window buttons:** clicks on buttons are taken (not just watched) when a rule exists, which needs Input Monitoring; the button does not highlight on press.
- **Hover menu** may sit beside macOS's own green-button menu on newer systems.
- **Window switcher and launcher** panels depend on `onKeyPress` (macOS 14).
- **Accessibility quirks:** some apps refuse resizing or move only partly; Diagnostics shows which.

Phase 2 specifics, none of it tested on hardware:
- **Which device an event came from:** macOS events do not say, so `DeviceActivityTracker` guesses from the last device that reported movement. Two devices used at once can blur.
- **Per-device pointer speed** uses private IOKit functions (`PointerTuner`). Fine for a notarized download, not for the App Store. If they change, it logs and does nothing.
- **Smooth scrolling** posts synthetic pixel scroll events at about 125 Hz; feel and per-app behavior need hands-on tuning.
- **Gestures** hold the activation button's press back until release to tell a click from a gesture, so that button feels slightly delayed. Check the middle button in browsers.
- **Rocker** swallows the second click, so Back/Forward bindings must be tried in each browser.
- A fast-moving gesture or smooth scroll uses `CGEvent` fields whose exact behavior across macOS versions is unverified.


The code builds and its automated tests pass (see Status), but the features that need a real keyboard, mouse and displays have only been tried in a few spots. Specific things to check by hand first:

- **Key remapping:** Caps Lock is swapped with the system's `hidutil`, keeping any mappings someone else made. Turn remapping off and quit Kriya once to confirm Caps Lock works normally again.
- **Several features on one mouse button:** drag to scroll, button gestures, modifier-drag, window-button clicks and double-click actions all use the shared event tap. Once one takes an event, later ones see only the events that end it (a button let go, a key up, a modifier change).
- **IOHID matching without Input Monitoring:** the device registry opens `IOHIDManager` at launch; if macOS prompts for Input Monitoring just for listing mice, defer `start()` until the Mouse feature is on.
- **Finder extension:** needs enabling in System Settings, and may need a Finder relaunch to show its menu.
- There is no app icon yet (the menu bar uses an SF Symbol).
- **Updates:** `SUFeedURL` in `project.yml` points at `appcast.xml` in this public repository. After `scripts/release.sh`, sign the DMG with Sparkle's `sign_update`, add an `<item>` to `appcast.xml`, and upload the DMG to a GitHub release named `v<version>`.


Notes added later:

- **Finder extension:** a build registers its own copy of the extension; after building, `pluginkit -a /Applications/Kriya.app/Contents/PlugIns/KriyaFinder.appex` and unregister stray copies with `lsregister -u`, or macOS sends `kriya://` links to the wrong copy. Extension activity is logged under the `app.kriya.finder` subsystem.
- **Force-quitting during testing** makes Kriya start in safe mode (three unexpected quits); delete `~/Library/Application Support/Kriya/session.json` and quit it gracefully.
- **Updates:** the feed is `appcast.xml` on `main`; a release is not offered to anyone until its DMG is uploaded and its item is in that file.
- **Not built:** multi-finger trackpad gestures (private framework), Spaces and always-on-top (private APIs), Safari extension, Logitech-specific features, scrolling capture.
