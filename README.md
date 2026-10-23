# Kriya

Mouse, trackpad, window and right-click control for the Mac. A menu-bar app, signed with a Developer ID and notarized
(not sandboxed, not on the App Store: it has to watch input and move other apps' windows).

**Status:** the app builds, is signed with a Developer ID and notarized by `scripts/release.sh`, which also runs the Rust tests. The Swift tests run with `xcodebuild test` (quit the installed Kriya first, because the test host shares its bundle identifier). The version of each release is in `apps/macos/project.yml`, `appcast.xml` and the GitHub release; test counts are not kept here, so they cannot go stale. Most features have **not yet been checked by hand in everyday use**: see "Not verified" below.

## What Kriya does by itself

Kriya has no check or scan buttons. These happen without you asking, and each can be turned off:

- **Kriya's own updates:** it looks for a signed update when it starts and about every hour, and installs it. Turn off in Settings › General › Updates ("Look for updates automatically" and "Install them automatically").
- **Homebrew apps:** when the Apps pane's check finds an outdated Homebrew app, Kriya upgrades it, one app at a time, and lists what it did under Apps › Updates. Turn off with "Upgrade Homebrew apps automatically" in Apps › Updates. Apps that update themselves are only listed.
- **The apps list, leftovers and update check:** the list follows your Applications folders, leftovers are looked for again when it changes, and updates are checked every hour. These only read; nothing is removed or installed by them except the two above.
- **Nothing else changes your files or apps by itself.** Removing an app or its leftovers, installing from the Install tab and every Finder action wait for you.

Build and test: `scripts/build-core.sh` (Rust tests, bindings, universal library), `scripts/swift-build.sh` (debug build), `scripts/release.sh <version> <build>` (signed, notarized DMG).

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

## Phase 3: window management

Snap to halves, thirds, quarters and sixths; maximize without full screen; center; undo and restore original; custom sizes
(share of the display or points); drag-to-edge and corner snapping with a preview; shortcuts for every layout and command
(system hot-key service, no extra permission); moving between displays with or without preserved proportions; cycling a half
through third and two-thirds; hold-a-modifier to move or resize from anywhere in a window (needs Input Monitoring); saved
layouts and a per-display-set automatic snapshot that returns when displays reconnect, plus pulling off-screen windows back;
per-app placement rules applied when an app opens; a searchable, most-recently-used window switcher; exclusions; diagnostics.
Logic: `core/.../windows.rs` and `window_store.rs`. macOS: `Adapter/Windows/`, `UI/Settings/WindowsPane.swift`.

## Phase 4: window buttons

Per-button, per-modifier actions for the red, yellow and green buttons (close, quit, hide, minimize, maximize without full
screen, full screen, center, snap, saved action, do nothing), per-app profiles, exclusions (plus built-in system ones), an
optional hover menu, and a safe fallback: a button that cannot be read, or an action that fails, performs the normal click.
A repeat press within 350 ms is swallowed so an action never runs twice. Logic: `core/.../traffic.rs`, `traffic_store.rs`.
macOS: `Adapter/Windows/TrafficLightFeature.swift`, `UI/Settings/TrafficPane.swift`.

## Phase 5: Finder and right-click actions

A Finder Sync extension (`apps/macos/FinderExtension`, sandboxed) shows the menu; it reads `finder-menu.json` from
Application Support and asks the app to act through `kriya://finder/run?…`, authenticated by a secret token in that file.
The app does the file work (`Adapter/Finder/FileActionRunner.swift`): new file/folder, templates, copy path (full, name,
parent, shell-escaped), open in a terminal, Open With favorites, duplicate, rename, batch rename with a live preview, move,
copy, compress, extract, convert (sips/textutil/afconvert/avconvert), copy file info, shell and AppleScript scripts, Apple
Shortcuts. Actions are ordered by dragging; destructive ones ask first; nothing is overwritten; system folders are refused.
Also: Services menu entries (declared in `project.yml`) and a searchable launcher on a global shortcut. Logic: `core/.../finder.rs`.
The user called the launcher "KarmaSetu file-action launcher"; it is named Kriya here to match the app.

## Phase 6: clipboard manager

History of text, rich text, images, files and links; search, pins, snippets, collections, tags, previews; paste as plain
text and remove formatting; duplicate detection; retention and size limits with automatic cleanup; excluded apps (password
managers by default), copies marked secret by apps, and text that looks like a password, key or card number are never
recorded; pause; clear (deleted content is overwritten on disk); shortcuts; a quick-access window; snippet import and export.
Stored only on this Mac, in its own private file (`clipboard.sqlite`), never in a settings backup, never sent anywhere.
Logic: `core/.../clipboard.rs`, `clipboard_db.rs`. macOS: `Adapter/Clipboard/`, `UI/Settings/ClipboardPane.swift`.
On macOS 15.4 and later, macOS may ask whether Kriya can read what other apps copy; choose Allow.

## Phase 7: selection bar

A PopClip-style bar next to selected text. The selection is read through Accessibility (never in password fields or while
secure input is on); apps that do not share it can use an optional copy-and-restore fallback, off unless enabled, never in
excluded apps. Actions: copy, cut, paste, paste plain, case changes, trim, dedupe and sort lines, URL and HTML encoding, JSON
format and validation, web search and custom link templates, open links, dictionary, spelling, translate (opens the chosen
service in the browser), custom text pipelines (including regex), shell and AppleScript scripts (each must be approved by
its exact text), Apple Shortcuts. Per-app behavior, appearance, delay, a manual shortcut, and action packages to import and
export. Logic: `core/.../text_tools.rs`, `selection.rs`. macOS: `Adapter/Selection/`, `UI/Settings/SelectionPane.swift`.

## Phase 8: keyboard and text expansion

Global and per-app keyboard shortcuts (scope: everywhere, only in apps, or everywhere except) that run a command, a saved
action, a workflow or insert a snippet. Each is checked before saving against macOS's own shortcuts, the rest of Kriya, and
your other shortcuts (blocking), with a warning for ⌘+letter combinations. Text expansion: abbreviations that expand after
a delimiter or immediately, per-app, case rules, and conflict detection (duplicates are refused; an abbreviation cut short
by a shorter immediate one is warned). Placeholders: dates and times with formats and offsets, clipboard, cursor position,
values asked for, unique ID. Categories, favorites, search, import and export. Expansion never runs in password fields, while
macOS secure input is on, or in excluded apps; only the last few typed characters are kept, in memory. A command launcher
searches everything Kriya can do, and Settings is reachable by keyboard (⌘1–⌘9, ⌘[ and ⌘]).
Logic: `core/.../template.rs`, `expansion.rs`, `keyboard.rs`. macOS: `Adapter/Keyboard/`, `UI/Settings/KeyboardPane.swift`.

## Phase 9: automation

Workflows: a trigger, optional conditions, and steps that run one after another. Triggers: by hand or by any shortcut, mouse
rule, Finder item, selection action or launcher entry that runs `workflow.<id>`; a keyboard shortcut; a mouse button; a
trackpad gesture (where macOS passes it on); a window being placed; something being copied; a hot corner or screen edge; an
app activating, opening or quitting; a display being connected or removed. Each step can have its own condition (two steps
with opposite conditions make an "if … otherwise …"), and can stop the workflow or carry on if it fails. Steps: open, quit,
hide or activate an app, open an address, run a Shortcut, AppleScript or shell script, press keys, move or resize windows,
change text, copy or type text, switch a mouse preset or a feature, pause the clipboard, system operations (lock, sleep,
screen saver, light/dark, volume), wait, show a message, and run another workflow. A visual builder, a dry run that lists what
would happen, a live test, duplication, and import and export with versioned manifests (older workflows are migrated, newer
ones refused). Every run is written down (steps, timings, errors), never the text it worked on.
Safety: any step that runs code, presses keys, quits apps or controls the system makes the workflow need your authorization,
which belongs to its exact content and disappears when a step changes; imported or restored workflows come in unauthorized
and switched off; time limit (never more than 10 minutes) with programs stopped; a stop button; runaway protection (more than
8 starts in 10 seconds is refused; chains at most 5 deep; loops refused on save); nothing starts by itself in safe mode.
The catalog in `core/.../workflow.rs` is the single registry of triggers, conditions and steps that the builder reads.
Logic: `core/.../workflow.rs`, `workflow_store.rs`. macOS: `Adapter/Automation/`, `UI/Settings/AutomationPane.swift`.

## Not verified

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
- **Updates:** `SUFeedURL` in `project.yml` points at `lokeshreddyveer/kriya`, which is private for now, so updates do not reach other people until the repository is public or the feed moves.

## More window features (Windows pane)

Added after the first release. Every one has a shortcut you can set under Windows › Shortcuts; most also have options under Windows › Options.

- **Focus by direction**: focus the window to the left, right, above or below.
- **Pointer to window**: move the pointer to the middle of the active window.
- **Stash**: slide a window to the nearer screen edge, leaving a sliver; point at the sliver to bring it out.
- **Radial menu**: a ring of eight places around the pointer, with a live preview; click to place.
- **Keyboard grid**: place a window on a grid with the arrow keys (Shift extends, Return places).
- **Todo mode**: keep one app in a narrow column; every layout uses the rest of the display.
- **Drop zones**: hold the chosen keys while dragging a window to see a saved layout's places and drop onto one.
- **Window groups** (Windows › Layouts): pick a few open windows, name the group, and restore them together (apps that are closed are opened), move or fit the whole group into a display or half of one, or give it a shortcut.
- **Window switcher (⌥Tab)**: opens at once from a list kept ready in the background, shows large window previews that fill in as they arrive, and works like ⌘Tab (hold ⌥, tap Tab, let go). ⌥⇧Tab goes backwards, ⌥` switches between the windows of the front app, typing filters, 1 to 9 pick a card, hover chooses and shows a close button, and ⌘W, ⌘M, ⌘H and ⌘Q close, minimize, hide or quit. Card size and which display it opens on are settings.
- **Restore details**: after a layout restore, a report says for each window whether it was placed, went to another or the main display, or was not found and why (app not running or hidden, only minimized windows, no window open, excluded app, or a window that would not move), with a way to choose a replacement window and try again.
- **Resizing**: almost maximize with a margin, maximize width or height only, bigger, smaller, wider, narrower, taller, shorter (with optional shape keeping), and a width limit for ultrawide displays.
- **Arranging**: cascade or tile the windows on a display.
- **Switching**: previous window, next window of the same app, send behind.
- **Act on the pointer's window**: shortcuts and the menu-bar strip can move a window you have not clicked.
- **Menu bar**: a row of six places (halves, maximize, center) in the menu-bar panel.
- **Snap haptics**: a light tap on the trackpad when a dragged window reaches an edge.

Already there: hot corners (an Automation trigger) and undo history (Undo last move, Restore original).
Not offered: moving windows between Spaces and always-on-top, which macOS only allows through private APIs.

## More mouse features

- **Scroll with a key held**: hold chosen keys to scroll sideways, or to scroll plainly (no smoothing, acceleration or speed change). Set per preset under Mouse › Presets › Scrolling.
- **Pointer between displays**: "Move pointer to next display" and "previous display" are commands any shortcut, button or gesture can run. Center-pointer-in-window is under Windows.
- **Common actions**: Actions › Add Common Actions saves ready-made ones: Back, Forward, Mission Control, App Exposé, previous and next desktop, Show desktop, Switch app, next and previous tab, new and close tab, Reload, Lock screen, and a few window and pointer commands. They use the shortcuts macOS and browsers already have, so they work where those are switched on.
- **Every window command is pickable** for buttons and gestures, so a gesture can place a window.

- **Drag to scroll** (Mouse › Drag): hold the middle or a side button (or the left or right with a key) and drag to move the page like a hand grab; it keeps gliding after you let go. A press without moving is still sent on as a click.
- **Window follows the pointer** (Mouse › Drag): hold chosen keys and the window under the pointer follows it, no click.

Not offered: Logitech-specific device features (ratchet or SmartShift control), which need the maker's own protocol.

## More right-click, window-button and selection features

- **Folder tools** (Add Common Actions in the Finder pane): New Folders (one name per line), Find Large Files (lists the biggest files in a folder, nothing changed), Tidy Up This Folder (sorts loose files into Images, Documents, Archives, Audio, Video and Installers; asks first, never deletes) and Undo Last Tidy-Up.
- **Recent file operations** (Finder › Actions): moves, copies, renames, batch renames, archives, extractions, aliases and new files are listed with Undo (items put back only if their old place is free; things an action made go to the Trash), Show, and the reason for anything that failed. A move or copy that fails for one item still does the rest. Kept for two weeks.
- **Folder Rules** (own pane under Files & Text): watch a folder and move, copy, rename, sort by kind or send to the Trash the files that match (type, kind, name, age, size). A new rule starts off, shows a preview of exactly what it would do, only touches finished files (not downloads in progress), never overwrites, and everything it does is in Recent file operations with Undo.
- **Move to / Copy to**: the chooser lists starred and recent folders first, with search, ⌘1–⌘9 and “Choose Another Folder…”.
- **⌥ + right-click** (Right-Click Menu › Pointer Menu): opens the pointer menu; a plain right-click keeps the app's own menu.
- **Pointer menu** (Right-Click Menu › Pointer Menu): a menu that opens at the pointer from any shortcut, button or gesture. It holds your own items (saved actions or workflows, optionally limited to chosen apps) and the front app's own menu bar, built live from Accessibility. Use the actions “Open the pointer menu” and “Open the app's menu at the pointer” (Actions › Add Common Actions).
- **Finder**: show or hide hidden files, open the parent folder, and an editor action, all under “Add Common Actions” in the Finder pane's menu. **Default apps by file type** (Setup tab) lists which app opens each extension and applies it to macOS.
- **Window buttons**: new actions: close or quit if it is the last window, bring back a minimized window, restore previous size, and a radial menu for the green button. Optional confirmation before a button quits an app.
- **Title bar**: a double-click or middle-click on the empty title bar can run any button action (Window Buttons › Title Bar).
- **Selection bar**: copy as plain text, copy as Markdown (formatting kept), count words, share, open in another app, new UUID, press a key combination (bold, italic, underline), PascalCase, CONSTANT_CASE, Base64 encode and decode, escape and unescape strings. Actions can be put in **groups** that share one bar button. “Add Common Actions” in the Selection bar pane adds ready-made Markdown, code, search (Wikipedia, DuckDuckGo, GitHub, YouTube, Maps), email, new note, new reminder and new calendar event actions; the ones that run scripts ask for your approval first.

Not offered: running JavaScript or TypeScript extensions, installing extensions from a catalog, iCloud sync of actions, and automatic extension updates. Actions can be exported and imported as packages, and custom shell and AppleScript actions need your approval.

## Link routing and default apps

- **Link Routing** (Files & Text › Link Routing): make Kriya your default browser and it sends each link where your rules say. Rules match a site (and its subdomains), an address prefix, text in the address or a regular expression; they can depend on the app the link came from and on keys held, and send the link to a browser and profile (Chrome, Edge, Brave, Vivaldi, Chromium), ask which browser, or copy it. The first matching rule wins. Holding Option (changeable) shows a menu of browsers whatever the rules say. A link is never lost: anything that cannot be done opens in Safari, and Kriya never hands a link back to itself.
- **Cleaning**: removes tracking parameters (utm_*, fbclid, gclid and others, plus names you add) without touching the rest of the address, and replaces known redirect wrappers (Google, Facebook, LinkedIn, Slack, YouTube, DuckDuckGo, Outlook safe links) with the real address. Nothing is fetched.
- **Log and test**: the last 200 links with what was done to each, and a box to try a link and see the decision without opening it.
- **Default apps by file type** (Finder Actions › Setup): choose the app for each extension (.md, .csv, .json, .pdf and others) and apply it to macOS.

Not offered: Safari and Firefox profiles (neither has a supported way to open a link in a chosen profile), and expanding short links (bit.ly, t.co) that need a network request.

## App switching, workspaces and focus

- **Workspaces** (Windows › Workspaces): a named set of apps and web addresses that open together, optionally hiding every other app and arranging the windows in a saved layout. Each workspace is a command (“Workspace: …”) for a shortcut, mouse button, gesture or hot corner.
- **Focus mode**: choose the apps that stay visible; one command turns it on (everything else is hidden, and an app that comes to the front is hidden again) and off.
- **App control commands**: previous app, hide all apps, hide other apps, quit all apps (asks first, leaves the Finder, Kriya and a keep list running), relaunch the front app.
- **Windows**: favorite windows 1 to 5 (set one, go to one, opening the app if needed), cycle the windows under the pointer, focus a window on the next display, bring back a minimized window, and small pictures of each window in the switcher (needs Screen Recording).

Already there: the window switcher with search and keyboard selection, previous window, focus a window by screen direction, hot corners and mouse-triggered automation.
Not offered: showing every window on screen as a Mission Control style grid.

## Pointer effects

Find the pointer also by double-tapping Control or by shaking the mouse, and the halo and click rings can be kept out of chosen apps.


Pointer Effects (Input): a master switch, then:

- **Highlight**: a soft disc or ring that follows the pointer, with your own colour, size and strength, and an optional slow breathing movement.
- **Clicks**: a ring at every click, one colour for the left button and one for the others, with size and duration.
- **Find the pointer**: three rings spread from the pointer, as a command for a shortcut, button or hot corner.
- **Magnifier**: a live zoomed view around the pointer in a small window that follows it (circle or square, zoom 1.5× to 8×), with commands to switch it on and off and to zoom in and out. Needs Screen Recording; it only looks, never records.
- **Hide when still**: the pointer disappears after a few seconds and returns at the first movement, and on demand. This asks the window server for permission to do it from the background, which is not a public API; if it does not work on your Mac the pointer simply stays visible.
- **Saved positions**: named spots on a chosen display (or the current one) that the pointer can jump to, each a command.
- **Presenting**: presentation mode switches on the highlight and click rings together; the effects are hidden from screen sharing and recordings unless you choose to show them (some sharing tools capture regardless).
- **Spotlight**: dims every display except a circle or rounded rectangle around the pointer (size and darkness adjustable); a command, so it can have a shortcut. Hidden from screen sharing unless you choose to show the effects.
- **Launcher** (compact bar that grows with results, in sections): apps, windows, files, clipboard, settings, a calculator, timers and emoji, plus **quicklinks** (a saved address with {query}: “gh swift”), **scripts** (a zsh script you wrote, with what you type as $1), **converters** (“5 km to mi”, “100 f in c”, “time in tokyo”, “3pm nyc in london”, colours, base64, URL encoding, SHA-256, MD5, case, slugs, JSON, timestamps), **generators** (uuid, password, lorem, QR code, screen colour picker), optional **currency** conversion from daily reference rates (only currency codes are sent) and your **next meeting** with a Join button for Zoom, Meet, Teams and Webex links (calendar access, off until you allow it). Web search and “yt cats”-style site keywords are built in.

Already there: move the pointer to the next or previous display, and to the middle of the front window.

## Keyboard remapping, Keep Awake, displays, file shelf and apps

- **Key remapping** (Keyboard › Keys): a key can do one thing when tapped and another when held, a double tap, or two keys pressed together can act as one. Quick setups: Caps Lock as Hyper (Escape when tapped), Caps Lock as Control, Right ⌘ as Control. Off until turned on; Caps Lock is swapped only while a rule uses it and restored when remapping stops or Kriya quits.
- **Window switcher on ⌥Tab**, working like ⌘Tab: hold ⌥, tap Tab to step, let go to switch. ⌘Tab itself is left native.
- **Keep Awake** (Sleep & Power): timed sessions, until turned off, keep the display on, while chosen apps run, and stop at a battery level. Commands for shortcuts.
- **Displays & Corners**: resolution and refresh rate per display, software dimming, saved display profiles (applied again when the same displays reconnect) and hot corners that run a saved action.
- **File Shelf**: a small panel that holds files, text and images; opens when you shake the pointer while dragging files, or from a shortcut. Drag items out into any app, Quick Look, zip.
- **Apps**: remove an app with the files it leaves in your Library (previewed, moved to the Trash), find leftovers of apps already gone, and check for updates (apps with their own update feed, and Homebrew).
- **Mouse**: double-click a button to run an action, hold a button and turn the wheel for two actions, drag to scroll with glide, window follows the pointer.
- **Hold rules** (Mouse › Buttons): a button rule can fire on a hold instead of a click (150–1500 ms); a quick press is still an ordinary click. **Auto-scroll** (Mouse › Drag): click a chosen button and move the pointer to scroll; Escape, a click or the wheel stops it.
- **Device status** (Mouse › Devices): battery from macOS for devices that report one (otherwise “not reported”), last used, and a note when a device came back and its settings with it.
- **Command line, URL commands and Shortcuts**: General › Command line installs a `kriya` tool (`kriya run window.left_half`, `kriya action <id>`, `kriya workflow <id>`, `kriya launcher text`), the same commands are `kriya://run` addresses guarded by a secret only your account can read, and the Shortcuts app gets Open Launcher, Run a Kriya Command and Run a Saved Action.
- **Menu bar icons** (General): hide icons behind an arrow by holding ⌘ and dragging them left of a divider; hides again after a time you choose. It checks that macOS really made the room and says so if not.
- **Record keys** (Actions): press keys once and save them as an action (a single key press or a timed sequence). Only key codes are kept.
- **Clipboard history**: drag an item straight out of the quick paste panel into another app (never a sensitive item).
- **Settings from another Mac**: the Backup pane offers iCloud copies from another Mac that are newer than this Mac's, with Review and Not Now. Nothing is applied by itself.
- **Windows**: radial menu colour and size, a layout grid on the green-button hover, move to the display left/right/above/below, act on the window under the pointer, and optionally place an app's windows by its rule every time it comes forward.
- **Clipboard**: a paste stack that pastes copied items one after another, and read-aloud commands.
- **Pointer**: hold chosen keys to show the magnifier.

## Privacy, launcher, capture, browser and diagnostics (0.2.8)

- **Encrypted clipboard** (Clipboard › Privacy): history can be sealed with AES-256-GCM, each value bound to its row. The key is made on the Mac and kept in the login Keychain (this device only). Turning it on encrypts what is saved and overwrites the readable copies; turning it off reverses that. Text that looks like a password, key or card number is saved only while encrypted, labelled sensitive, shown as dots, and can expire after a time you choose or be removed in one step. Per-app exclusions stay. An optional Touch ID or password lock covers the history (and re-locks on sleep and screen lock). If the key is lost the history cannot be read, and the pane offers to delete it and start again. Search while encrypted is done in memory, so it is slower on very large histories.
- **Protected backups** (Backup & Restore › Protection): a passphrase (PBKDF2-SHA256, AES-256-GCM) seals every backup, including automatic and iCloud Drive ones. The passphrase is kept in the Keychain; another Mac asks for it when restoring. Lose it and a protected backup cannot be opened. Clipboard history is still never part of a backup.
- **Launcher** (Launcher pane, same shortcut as before): fuzzy search over apps, open windows, files (Spotlight, home folder, only for what you type), clipboard history, snippets, saved actions, workflows, window layouts, Kriya and macOS settings, plus a calculator, timers and emoji. Pins, short names, ⌘K actions and what you use most. The menu-bar window search uses the same results.
- **Shortcut Map** is now an interaction map: keyboard shortcuts, remapped keys, mouse buttons, gestures, double-clicks, window buttons, hot corners and automation triggers together, with the ones that want the same thing flagged and explained, and an Order tab showing which part of Kriya sees an event first.
- **Layout editor** (Windows › Layouts › Draw a Layout): drag boxes on a picture of a display, give each an app, start from a template, and choose what happens to other windows (leave, minimize, hide, close with a confirmation). A layout can open apps that are not running. Layouts made before keep working unchanged.
- **Screen Capture** pane: region, window or full screen using the system tool (no scrolling capture), delay, copy and save, copy text from a region with the Mac's own text recognition, hide private text (emails, phone numbers, card numbers, addresses, keys and words you list), and an editor with boxes, arrows, highlights, blocks, mosaic and notes. Needs Screen Recording. Nothing is uploaded.
- **Browser connection** (Link Routing › Browsers): extensions for Chromium browsers and Firefox send a link, page or selected text to Kriya through a native-messaging connection. Three permissions only, no page access, no network. Chromium needs "Load unpacked"; Firefox loads it temporarily until Mozilla signs it. Safari is not covered.
- **Diagnostics**: Health (permissions and what each feature needs, secure-input status, release stuck modifier keys), Trace (what Kriya did for each shortcut or command, off until started, five minutes), Timeline (event-tap speed over the last ten minutes), and support reports with your name, paths, addresses and keys removed. Devices shows which mouse settings apply right now and why, with a tester for buttons, scrolling and keys.

Not verified by hand: the encrypted file on disk, the Keychain and Touch ID flows, capture and text recognition on a real screen, the layout editor on real windows, and the extensions in a real browser.

## Apple Intelligence (0.2.9)

Kriya uses Apple Intelligence's on-device model through the Foundation Models framework (macOS 26 or later, on a Mac with Apple Intelligence turned on). It never uses the framework's cloud model, so nothing leaves the Mac, and what you select or copy is not logged or kept.

- **Selection bar:** an "Apple Intelligence" group of actions: Summarize, Key points, Fix grammar, Make friendlier, Make professional, Make shorter, Explain, Draft a reply, and your own instruction (Settings › Selection Bar › Add Action › Ask Apple Intelligence). The result opens in a small window: Return replaces the selection (rewrites in an editable field) or copies it; Escape closes. The actions are left out of the bar on a Mac that cannot run it.
- **Launcher:** type `ask` (or `ai`, or `?`) and a question; or Summarize, Fix, Explain, Make professional or shorter the clipboard text. In clipboard results, ⌘K offers Summarize, Explain and Fix grammar.
- **Never sent:** anything marked secret by the app that copied it, clipboard items labelled sensitive, and text that looks like a password, key or card number.
- **Apple Intelligence pane:** status and how to fix it, where it is used, the language of results, and a place to try it.
- **Limits:** about 6000 characters go to the model (a longer text is cut, and the result says so; one retry with less if the model says it is still too long). The model supports a limited set of languages and can make mistakes.
- Existing selection-bar setups get the new actions once; ones you remove do not come back.

Verified: it compiles, its tests pass with a stand-in model, and a real call to this Mac's on-device model fixed a test sentence. Not verified by hand: the selection bar actions, the result window, the launcher "ask" and the clipboard actions on real windows.

## Quick paste window, and Apple Intelligence fixes (0.2.10)

- **The quick paste window can be moved:** drag the bar at its top, or any empty part. Clipboard › Settings can make it open where you left it instead of at the pointer.
- **Right-click an item:** Paste, Paste as Plain Text, Copy (without pasting), Pin to the Top, Save as Snippet, Show in Finder or Copy Path for files, Open Link for links, an Apple Intelligence submenu for text (never for items labelled sensitive), and Delete. ⌘P pins the highlighted item. Pinned items show a pin mark and have their own filter.
- **Apple Intelligence:** the selection is read again when you choose an action, and the longer reading is used when it contains the first (some apps report only part of a selection at first). The result window shows how many characters were used, stays on the screen the pointer is on, and Summarize or Key points on under 140 characters says there is nothing to summarize instead of repeating the text.
