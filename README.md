# Kriya

A menu-bar app for the Mac that puts the things you use all day under your control: mouse and trackpad, windows, keyboard,
clipboard, Finder, screenshots and recordings, and a launcher that finds anything. One app, many small tools, each switched on or
off by itself.

- macOS 14 or later, Apple silicon and Intel. Apple Intelligence features need macOS 26 and a supported Mac.
- Signed and notarized. Not sandboxed and not in the App Store, because it has to watch input and move other apps' windows.
- No account, no analytics. What you copy, select or type stays on your Mac unless you switch on something that sends it.

## Install

1. Download `Kriya-<version>.dmg` from [Releases](https://github.com/lokeshreddyveer/kriya/releases), open it and drag Kriya to Applications.
2. Open Kriya. An icon appears in the menu bar: click it for the quick panel, right-click it for a short menu.
3. Open **Settings**. **Overview** has a switch for each feature and shows any permission it needs, with a button to grant it.

Kriya updates itself with signed updates. To build it from source, see [DEVELOPING.md](DEVELOPING.md).

## What it does

| Area | Highlights |
|---|---|
| **Mouse & trackpad** | Per-device and per-app presets, button rules (click, hold, double-click, chords, gestures), drag to scroll, smooth and trackpad-style scrolling, click-and-drag navigation, pointer speed, device details and battery |
| **Windows** | Shortcuts, snapping, layouts, window switcher, workspaces, displays and monitor controls |
| **Keyboard** | Shortcuts, remapping, text expansion |
| **Clipboard & selection** | History, paste stack, a bar of actions beside selected text |
| **Finder** | Right-click actions and templates, folder rules, file shelf |
| **Launcher** | Apps, windows, files, calculator, timers, clipboard, quicklinks and natural-language requests |
| **Screen capture** | Screenshots, scrolling capture, recording, GIFs, editor, backdrops, OCR, pins, 19 capture commands |
| **Sound** | Per-app volume and equaliser, devices, a mixer in the menu bar |
| **Automation** | Saved actions, workflows, scripts, MIDI, the `kriya` command and `kriya://` links |
| **AI** | On-device Apple Intelligence by default; optional providers you add yourself |
| **Apps & system** | App list and leftovers, Homebrew updates, backups, pointer effects, diagnostics |

Every setting is described in the [feature reference](docs/FEATURES.md). What changed in each version is in [RELEASES.md](RELEASES.md).

## Permissions

macOS asks the first time a feature needs one. **Settings › Permissions** shows each state and can fix it.

| Permission | Needed for |
|---|---|
| Accessibility | moving and resizing windows, the switcher, reading selected text |
| Input Monitoring | mouse buttons and gestures, keyboard shortcuts and remapping, text expansion, drag tools |
| Screen Recording | window previews, the magnifier, screen capture |
| Microphone, Speech, Calendars, Contacts | dictation, your next meeting, finding people. Optional, asked only when you use them |
| Finder extension | the right-click menu (switch on “Kriya” in System Settings › Login Items & Extensions › Finder) |

## Safety

- If Kriya quits unexpectedly three times in half an hour, it starts in **safe mode** with every feature off. Holding Option while opening it does the same on purpose.
- **Pause Mouse Rules** (menu-bar menu, settings, or a shortcut) sends every click, move and scroll straight through. Features that take hold of a button or the pointer are off until you turn them on.
- **Local-only mode** switches off everything that could leave your Mac: AI providers, capture uploads, iCloud sync and backup, update checks, web research.

## Privacy

No analytics and no account. Settings and clipboard history stay on this Mac. Network use is limited to update checks, Homebrew searches
you run, and what you set up yourself. What you type, copy or select is never written to the log. The full list is under Privacy in the
[feature reference](docs/FEATURES.md#privacy).

## More

[Feature reference](docs/FEATURES.md) · [Releases](RELEASES.md) · [Developing](DEVELOPING.md) · [Hardware tests](docs/HARDWARE-TESTS.md)
