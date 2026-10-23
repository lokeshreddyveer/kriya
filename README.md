# Kriya

Kriya is a menu-bar app for the Mac that gives you control over the things you use all day: your mouse and trackpad, your
windows, the keyboard, the clipboard, Finder, and the launcher that finds anything. It is one app with many small tools, and
each one can be switched on or off on its own.

- Works on macOS 14 or later, on Apple silicon and Intel Macs. Apple Intelligence features need macOS 26 and a Mac that supports it.
- Signed and notarized. It is not sandboxed and not in the App Store, because it has to watch input and move other apps' windows.
- Everything stays on your Mac. Nothing you copy, select or type is uploaded.

## Getting started

1. Download `Kriya-<version>.dmg` from the Releases page, open it and drag Kriya to Applications.
2. Open Kriya. A small icon appears in the menu bar. Click it for the quick panel; right-click it for a short menu.
3. Open **Settings** from the quick panel. The sidebar lists every feature, grouped as Input, Windows, Files & Text, Automate and
   System. **Search** at the top of the sidebar finds a setting by name.
4. **Overview** has a switch for each major feature. A feature that needs a permission shows what it needs and a button to grant it.
5. Kriya keeps itself up to date: it looks for a signed update when it starts and about every hour.

### Permissions

macOS asks for these when a feature first needs them. **Settings › Permissions** shows the state of each and fixes it.

| Permission | Needed for |
|---|---|
| Accessibility | moving and resizing windows, the window switcher, window buttons, reading selected text |
| Input Monitoring | mouse buttons and gestures, keyboard shortcuts and remapping, text expansion, drag tools |
| Screen Recording | window previews in the switcher, the pointer magnifier, screen capture |
| Calendars | showing your next meeting in the launcher (optional, off until you allow it) |
| Finder extension | the right-click menu (switch on “Kriya” in System Settings › Login Items & Extensions › Finder) |

### If Kriya starts in safe mode

If Kriya quits unexpectedly three times in half an hour, it starts in safe mode with every feature off, so you can always get
back in. Turn features on again one at a time from Overview. Holding Option while opening Kriya starts it in safe mode on purpose.

---

# Mouse and trackpad

**Settings › Mouse & Trackpad.** Settings belong to a *preset*, and each mouse or trackpad uses a preset. Kriya tells devices
apart, so a mouse and a trackpad can scroll in opposite directions.

- **Devices tab:** every connected mouse and trackpad, wired or wireless. Rename them, choose a preset for each, and see battery
  (for devices that report it, otherwise “not reported”), when each was last used, and a note when a device came back and its
  settings came back with it. The tester shows which button, scroll or key you just pressed and from which device.
- **Scrolling:** reverse direction, speed per axis, smooth scrolling, acceleration, and sensitivity. Hold chosen keys to scroll
  sideways, or to scroll plainly with no smoothing.
- **Pointer:** pointer speed and acceleration presets, plus a precision mode for slow, careful movement.
- **Buttons:** give the middle button and extra buttons a job. Pick a button, optionally a modifier key, and an action: press keys,
  open an app or address, run a script or Shortcut, a window command, or any saved action.
  - *Clicked or Held:* a rule can fire on a normal click or on a hold (150–1500 ms, adjustable). A quick press is still passed on
    as an ordinary click.
  - *Double-click* a button runs a different action, and *holding a button while turning the wheel* gives two more.
- **Gestures:** hold a button and move up, down, left or right to run an action. Rocker gestures (two buttons) are supported.
  Set the distance and time limit so you never trigger one by accident.
- **Apps:** a preset can switch on automatically for chosen apps, and apps can be excluded.
- **Drag tab:** *drag to scroll* (hold a button and drag to move a page like a hand grab, with glide after you let go),
  *auto-scroll* (click a chosen button, then move the pointer: the further from where you clicked, the faster it scrolls; Escape,
  a click or the wheel stops it), and *window follows the pointer* (hold chosen keys and the window under the pointer follows it).
- **Presets menu:** import, export or restore defaults.

**Not available:** Logitech-specific features such as ratchet control, which need the maker's own protocol.

# Pointer effects

**Settings › Pointer Effects.** Four groups along the top, and one master switch “Use pointer effects”.

- **Everyday:** a *highlight* that follows the pointer (soft disc or ring, your colour, size and strength, optional slow
  breathing), a *ring at every click* (one colour for left clicks, one for the rest), and *find the pointer* (three rings spread
  from it; also double-tap Control or shake the mouse).
- **Presentation:**
  - *Presentation mode* turns the highlight and click rings on together, for a talk, demo or recording, even with the master
    switch off. Give it a shortcut here and press it to start and stop. Optionally it also turns on the spotlight.
  - *Spotlight* dims every display except a circle or rounded rectangle around the pointer. Choose its shape, size and
    darkness, and give it a shortcut.
  - *Your audience:* effects are normally hidden from screen sharing and recordings, so only you see them. Turn “show the effects
    to people watching” on if you want them to. Some sharing tools capture the whole screen regardless.
- **Accessibility:** a *magnifier* (a live zoomed view that follows the pointer; hold chosen keys to show it, zoom 1.5× to 8×),
  *hide the pointer while typing* and *when still* (it returns the moment you move), and *saved positions* (named spots on a
  display the pointer can jump to).
- **Advanced:** apps where the highlight and rings are never drawn.

Each effect is also a command, so it can go on a shortcut, a mouse button, a gesture or a hot corner.

# Keyboard

**Settings › Keyboard.**

- **Shortcuts:** run a command, a saved action, a workflow or insert a snippet from a key combination, everywhere or only in chosen
  apps. Kriya checks each new shortcut against macOS's own shortcuts, the rest of Kriya and your other shortcuts, and refuses a
  clash.
- **Text expansion:** type an abbreviation and it becomes longer text. Placeholders insert dates and times (with formats and
  offsets), the clipboard, the cursor position, values you are asked for, or a unique ID. Expansion never runs in password fields
  or while macOS secure input is on.
- **Keys (remapping):** a key can do one thing when tapped and another when held, or two keys together can act as one. Quick
  setups: Caps Lock as Hyper (Escape when tapped), Caps Lock as Control, Right ⌘ as Control. Off until you turn it on.
- **Shortcut Map** (sidebar): every shortcut, remapped key, mouse button, gesture, window button, hot corner and automation trigger
  in one list, with any that want the same thing flagged and explained.

# Windows

**Settings › Windows.** Tabs: Shortcuts, Options, Sizes, Layouts, Apps.

- **Snapping:** halves, thirds, quarters and sixths, maximize (without full screen), center, almost-maximize with a margin, and
  undo / restore original. Every one has a shortcut (Windows › Shortcuts), and dragging a window to an edge or corner snaps it
  with a preview. Move a window to the next display with or without keeping its proportions.
- **Sizes:** your own sizes, as a share of the display or in points.
- **Resizing:** bigger, smaller, wider, narrower, taller, shorter (optionally keeping the shape), and a width limit for ultrawide displays.
- **Arranging:** cascade or tile the windows on a display; focus the window to the left, right, above or below; move the pointer
  to the active window; *stash* a window at the screen edge (point at the sliver to bring it out); *todo mode* keeps one app in a
  narrow column while every layout uses the rest of the display.
- **Radial menu and keyboard grid:** a ring of eight places around the pointer, or place a window on a grid with the arrow keys
  (Shift extends, Return places).
- **Drop zones:** hold the chosen keys while dragging a window to see a saved layout's places and drop onto one.
- **Layouts:** *Save Current Windows* remembers where windows are, per display. *Draw a Layout* lets you drag boxes on a picture of
  a display and give each an app, then choose what happens to other windows (leave, minimize, hide or close) and whether apps
  that are not running should open. Restore with a click or a shortcut. Kriya also keeps its own snapshot for each set of displays
  and brings it back when those displays reconnect, and pulls off-screen windows back.
  - *Restore details:* after a restore, a report lists each window: placed, sent to another or the main display (its own display
    was not connected), or not found, with the reason (app not running, hidden, only minimized, no window, excluded, or a window
    that would not move). **Choose Window…** places a window you pick and remembers it for next time; **Try Again** repeats the restore.
  - *Window groups:* pick a few open windows, name the group (“Development setup”), and restore them together, bringing them
    forward and opening closed apps. **Move To** fits the whole group, keeping its shape, into a display or half of one. A group
    can have a shortcut: look for “Group: …” in Shortcuts.
- **Apps tab:** placement rules for apps (“Safari always goes on the left half of display 2”), applied when the app opens or
  every time it comes to the front.
- **Window switcher (⌥Tab):** hold ⌥ and tap Tab to step through your windows as cards with large previews, then let go to switch.
  ⌥⇧Tab goes backwards and ⌥` steps through the windows of the front app. While it is open: arrow keys or Tab move, Return picks,
  1–9 pick a card, typing filters by app or title, hovering selects a card and shows a close button, ⌘W closes the window, ⌘M
  minimizes it, ⌘H hides its app and ⌘Q quits it. Under Options you can choose cards or a searchable list, the card size, and
  whether it opens on the display the pointer is on.
- **Menu-bar panel:** a row of places (halves, maximize, center) for quick snapping.

**Workspaces** (sidebar): a named set of apps and web addresses that open together, optionally hiding everything else and
arranging windows in a saved layout. *Focus mode* keeps chosen apps visible and hides the rest. Commands: previous app, hide all
apps, quit all apps (asks first), relaunch the front app, and favorite windows 1–5.

**Window Buttons** (sidebar): give the red, yellow and green buttons different actions per modifier key and per app (close, quit,
hide, minimize, maximize, full screen, center, snap, a saved action, or nothing). A button that cannot be read, or an action that
fails, performs the normal click. Optional hover menu on the green button; a double-click on the title bar can run an action too.

**Displays & Corners** (sidebar): resolution and refresh rate per display, software dimming, saved display profiles that apply
again when the same displays reconnect, and hot corners that run a saved action.

**Not available:** moving windows between Spaces and always-on-top, which macOS only allows through private APIs.

# Finder

## Right-click menu

**Settings › Finder Actions.** Tabs: Actions, Templates, Apps, Pointer Menu, Setup.

1. Go to **Setup** and switch on “Kriya” under Finder extensions in System Settings, then restart the extension and relaunch Finder.
2. Right-click a file, a folder, or the empty space in a folder, and choose from the Kriya menu.
3. If it ever stops working, **Setup › Check the Right-Click Menu** tests each link between Finder and Kriya and says which one is broken.

- **Actions tab:** the list of actions in the order they appear in the menu (drag to reorder), each with an on/off switch. Built in:
  new file and new folder, new from a template, copy path (full, name, parent, shell-escaped), open in a terminal, open with a
  favorite app, duplicate, rename, batch rename (with a live preview), move to, copy to, compress, extract, convert (images,
  documents, audio, video), copy file info, make an alias, copy a checksum, remove the download warning, show hidden files, open
  the parent folder, and your own shell scripts, AppleScripts, Shortcuts and workflows. Add Common Actions adds folder tools: new
  folders from a list, find large files, and tidy up a folder (with Undo).
- **Recent file operations** (top of the Actions tab): every move, copy, rename, archive, extraction, alias and new file is listed
  with **Undo** (an item goes back only if its old place is free, and things an action made go to the Trash), **Show**, and the
  reason for anything that failed. A move or copy that fails for one item still does the rest. Kept for two weeks.
- **Move to / Copy to:** a chooser with your starred and recent folders first, search, ⌘1–⌘9, and “Choose Another Folder…”. Star a
  folder to keep it at the top.
- **Templates tab:** file and folder templates for the “new from template” actions.
- **Apps tab:** your favorite apps for Open With, the default terminal, whether actions ask first, and the menu layout.
- **Pointer Menu tab:** a menu that opens at the pointer from any shortcut, button or gesture, with your own items and the front
  app's own menu. ⌥ + right-click opens it.
- **Setup tab:** also *default apps by file type* (choose the app for each extension) and the *action launcher* (a search box for
  every action that fits what is selected in Finder, on a global shortcut).
- Safety: actions that change files ask first, nothing is overwritten (a taken name becomes “name 2”), and system folders are refused.
  The same actions are in Finder's **Services** menu, where you can give them keys in System Settings › Keyboard.

## Folder Rules

**Settings › Folder Rules.** Rules that look after a folder by themselves, like “move PDFs from Downloads to Documents”.

1. **Add Rule** (or start from “Tidy Downloads by Kind”, “Clear Old Installers”, “Screenshots to a Folder”).
2. Choose the folder to watch, add **conditions** (a kind of file, a file type, name contains or starts with, older than N days,
   larger or smaller than N MB; all must be true) and an **action** (move, copy, rename with a pattern, move to the Trash, or sort
   into folders by kind).
3. A new rule is **off**. Press **Preview** to see exactly which files it would change and where they would go, then switch it on.
   **Run Now** does it at once.

Rules check their folder every minute. They only touch files that have been still for a minute (so downloads in progress are left
alone), never folders or hidden files, never your home folder or system folders, and never overwrite. Everything a rule does is in
Finder Actions › Recent file operations, with Undo. Changing a rule's conditions switches it off again until you preview it.

# Clipboard

**Settings › Clipboard.**

- **History:** text, rich text, images, files and links, searchable, with pins, tags, collections and previews. Duplicates are
  merged, and retention and size limits clean up old items.
- **Quick paste window:** open it with its shortcut. Type to search, arrow keys and Return to paste, ⌘1–⌘9 to paste one directly, and
  ⌘P to pin. Drag the top bar to move it. Right-click an item: Paste, Paste as Plain Text, Copy, Pin, Save as Snippet, Show in
  Finder, Open Link, Apple Intelligence actions for text, and Delete. **Drag an item out** into any app, message or folder.
- **Paste as plain text** and **remove formatting** have their own shortcuts.
- **Paste stack:** turn it on, copy several things, then paste them one after another in the order you copied them.
- **Snippets:** saved text you can insert from the history or by abbreviation. Import and export are supported.
- **Privacy:** excluded apps (password managers by default), copies marked secret by apps, and text that looks like a password,
  key or card number are never recorded unless encryption is on, in which case they are saved shown as dots and can expire.
  - *Encrypted history:* seals the history with AES-256-GCM, with a key kept in your login Keychain. An optional Touch ID or
    password lock covers it and locks again on sleep.
  - *Pause* recording or *Clear* history at any time (cleared content is overwritten on disk).
- History is stored only on this Mac and is never part of a backup.

# Selection bar

**Settings › Selection Bar.** Select text anywhere and a small bar appears beside it with actions, or press the manual shortcut.

- Built-in actions: copy, cut, paste, paste plain, change case, trim, dedupe and sort lines, URL and HTML encoding, JSON format and
  validation, search the web, open links, dictionary, spelling, translate, copy as Markdown, count words, share, Base64, escape
  and unescape strings, and more. Group actions under one button, or build your own text pipelines (including regular
  expressions), shell scripts, AppleScripts or Shortcuts (each must be approved by its exact text).
- **Apple Intelligence** actions appear when it is available (see below).
- Per-app behavior, appearance and delay are settings. The bar never appears in password fields.

# Launcher

Press the launcher shortcut (set in **Settings › Launcher**; the menu-bar window's search uses the same results). A bar opens near the top of the screen and
grows as results appear. With nothing typed it shows your pinned items, what you used recently, and your open apps.

- **Keys:** ↑ ↓ move, Return opens, ⌘K shows more things to do with a result, ⌘P pins it, ⌘1–⌘9 open one directly, Esc closes.
- **Finds:** apps, open windows (switch to one), files and folders (Spotlight, only for what you type), clipboard history, snippets,
  saved actions, workflows, window layouts, Kriya and macOS settings, commands.
- **Calculator and timers:** type `12*8`, `15% of 200`, `timer 5m`.
- **Converters:** `5 km to mi`, `100 f in c`, `2.5 kg to lb`, `1 gb to mb`; `time in tokyo`, `3pm nyc in london`; a colour like
  `#ff8800` (shows hex, RGB, HSL); `base64 hello`, `base64 decode …`, `urlencode …`, `sha256 …`, `md5 …`, `upper …`, `slug …`,
  `count …`, `json {…}`, `timestamp 1700000000`.
- **Generators:** `uuid`, `password 24`, `lorem 2`, `qr some text` (copies a QR code picture), and “Pick a color from the screen”.
  Choosing a result copies it.
- **Currency** (turn on in Launcher settings): `100 usd to eur` uses daily reference rates from frankfurter.app. Only the two
  currency codes are sent.
- **Next meeting** (turn on in Launcher settings, allow Calendars): shows your next event, with a **Join** button when it has a
  Zoom, Meet, Teams or Webex link.
- **Web:** the last row searches the web for what you typed (choose Google, DuckDuckGo, Bing, Brave or Ecosia). Type an address
  like `apple.com` to open it. A short word picks a site: `yt` YouTube, `maps` Apple Maps, `gh` GitHub, `wiki` Wikipedia,
  `so` Stack Overflow, `ddg` DuckDuckGo, `g` Google.
- **Quicklinks:** your own saved addresses with `{query}` for your words. “gh swift” with `https://github.com/search?q={query}`
  searches GitHub. A few come ready (maps, translate, Amazon, npm); add, edit or remove them in Launcher settings.
- **Scripts:** your own zsh scripts as launcher commands. Type the keyword, and anything after it arrives as `$1`. Choose whether
  the output is shown, copied or ignored. Only add scripts you wrote or trust.
- **Ask Apple Intelligence:** type `ask` followed by a question.
- **Short names and pins:** in ⌘K, “Give It a Short Name” lets a few letters bring a result first (`ff` for Firefox). Choose
  which kinds of result are searched under *What it searches*.

# Apple Intelligence

**Settings › Apple Intelligence.** Uses the on-device model (macOS 26 or later, with Apple Intelligence turned on), never a cloud
model, so nothing leaves your Mac and what you select is not logged or kept.

- On the selection bar: summarize, key points, explain, fix grammar, make professional or friendly, shorten, expand, translate,
  or your own instruction. The result appears in a small window with **Replace Selection** (where the text can be replaced) and **Copy**.
- In the launcher: `ask …`, and actions on the clipboard text. In the clipboard history: a right-click submenu for text items
  (never for sensitive ones).
- The pane shows whether it is ready and how to fix it, where it is used, and the language of results. About 6000 characters go to
  the model; a longer text is cut and the result says so. Summarize on very short text tells you there is nothing to summarize.

# Screen capture

**Settings › Screen Capture** (needs Screen Recording). Capture a region, a window or the whole screen with the system tool, with
an optional delay, and copy or save the result.

- **Copy text from a region** with the Mac's own text recognition.
- **Hide private text:** blur or block emails, phone numbers, card numbers, addresses, keys and words you list.
- **Editor:** boxes, arrows, highlights, blocks, mosaic and notes.
- Nothing is uploaded. Scrolling capture is not available.

# Link routing and browsers

**Settings › Link Routing.** Make Kriya your default browser and it sends each link where your rules say.

- **Rules:** match a site (and its subdomains), an address prefix, text in the address or a regular expression, optionally by the app
  the link came from or keys held. Send it to a browser and profile (Chrome, Edge, Brave, Vivaldi, Chromium), ask which browser, or
  copy it. The first matching rule wins. A link is never lost: anything that cannot be done opens in Safari.
- **Cleaning:** removes tracking parameters (utm_*, fbclid, gclid and others) and replaces known redirect wrappers (Google, Facebook,
  LinkedIn, Slack, YouTube, DuckDuckGo, Outlook) with the real address. Nothing is fetched.
- **Log and test:** the last 200 links and what was done, and a box to try a link without opening it.
- **Browsers tab:** extensions for Chromium browsers and Firefox that send a link, page or selected text to Kriya. They ask for three
  permissions only, read no pages and use no network. Chromium needs “Load unpacked”; Firefox loads it temporarily. Safari is not covered.

# File shelf

**Settings › File Shelf.** A small panel that holds files, text and images while you move between windows. Shake the pointer while
dragging files to open it, or use its shortcut. Drag items back out into any app, preview with Quick Look, or zip them.

# Automation

- **Actions** (sidebar): saved, named actions that mouse buttons, gestures, shortcuts and hot corners can run: press keys, open an
  app or address, run a script or Shortcut, a window command, or a sequence of those. **Add Common Actions** saves ready-made ones
  (Back, Forward, Mission Control, desktops, tabs, lock screen, and more). **Record Keys** lets you press keys once and saves them
  as an action (a single key press or a timed sequence; only key codes are kept, and recording stops when the window closes).
- **Automation** (sidebar): *workflows* with a trigger, optional conditions and steps. Triggers include a shortcut, a mouse button, a
  gesture, a window being placed, something being copied, a hot corner, an app opening or quitting, and a display connecting. Steps
  include opening or quitting apps, running scripts, pressing keys, moving windows, changing text, switching a mouse preset, waiting
  and running another workflow. There is a visual builder, a dry run that lists what would happen, and import and export.
  - Safety: any step that runs code, presses keys or controls the system needs your authorization for that exact content. Imported
    workflows come in off and unauthorized. Runs have a time limit and a stop button, runaway loops are refused, and nothing starts
    by itself in safe mode.
- **App Profiles** (sidebar): settings that switch on automatically for chosen apps.

# Apps

**Settings › Apps.** Tabs: Installed, Install, Leftovers, Updates.

- **Installed:** every app, with version, size and when you last opened it. Search, sort, and remove an app together with the files
  it leaves in your Library (you see the list first, and it goes to the Trash).
- **Install:** search every app Homebrew offers as you type, see its description and version, and install it. You see the exact
  command and confirm first. With nothing typed it lists popular apps. *Save My Apps as a List* and *Reinstall from a List* move
  your Homebrew apps to another Mac. Needs Homebrew; Kriya never installs Homebrew itself.
- **Leftovers:** files left by apps that are already gone.
- **Updates:** apps with their own update feed and Homebrew apps. Kriya can upgrade outdated Homebrew apps one at a time by itself
  (switch it off here); apps that update themselves are only listed.

# System and general

- **General:** open Kriya at login, light / dark / system appearance, automatic updates, and the safety switch for a feature that
  crashes while starting.
  - *Menu bar icons:* turn on “Hide menu bar icons behind an arrow”. Two items appear, a thin divider and an arrow. Hold ⌘ and drag
    icons to the left of the divider, then click the arrow to hide or show them. Choose when they hide again. If macOS will not
    make room, Kriya says so and switches it off.
  - *Command line and Shortcuts:* see below.
- **Menu Bar Window:** what the quick panel shows: tiles, layouts, theme, and its search.
- **Sleep & Power:** *Keep Awake* in timed sessions, until turned off, only while chosen apps run, or until a battery level.
- **Backup & Restore:** back up all your settings to a file or to iCloud Drive, restore one, and protect backups with a passphrase
  (kept in your Keychain; another Mac asks for it). Clipboard history is never included. A restore saves your current settings
  first so you can undo it. With iCloud Drive on, if another Mac saved settings after this one, the pane offers them with
  **Review** and **Not Now**; nothing is applied by itself.
- **Permissions:** the state of each permission and a button to fix it.
- **Diagnostics:** *Health* (permissions, what each feature needs, secure-input status), *Trace* (what Kriya did for each shortcut,
  off until you start it and limited to five minutes, never recording text), *Timeline* (event speed), and support reports with
  your name, paths and keys removed.

## Command line, URL commands and the Shortcuts app

**Settings › General › Command line and Shortcuts → Install “kriya”** links a `kriya` command into `~/.local/bin` (add that folder to
your PATH to type just `kriya`).

```
kriya run window.left_half      run any Kriya command
kriya action <id>               run a saved action
kriya workflow <id>             run a workflow
kriya launcher [text]           open the launcher, with text typed if you give some
```

The same requests are `kriya://run`, `kriya://action`, `kriya://workflow` and `kriya://launcher` addresses, each carrying a secret
only your account can read, so a web page cannot trigger anything. In the **Shortcuts** app, search for Kriya to find *Open the
Kriya Launcher*, *Run a Kriya Command* and *Run a Saved Kriya Action*. Nothing here uses the network.

---

# What Kriya does by itself

Kriya has no check or scan buttons. These happen without you asking, and each can be turned off:

- **Kriya's own updates:** looks for a signed update at start and about every hour, and installs it (Settings › General › Updates).
- **Homebrew apps:** upgrades outdated ones one at a time, listed under Apps › Updates (turn off there).
- **Folder Rules:** only rules you switched on, and only on the folders you chose.
- **The apps list and leftovers:** follow your Applications folders. These only read.

Nothing else changes your files or apps by itself: removing an app, installing from the Install tab and every Finder action wait for you.

# Privacy

- No analytics and no account. Settings, clipboard history and everything else stay on this Mac.
- Network use is limited to: update checks (the app's version only), Homebrew searches you run, optional currency rates (currency
  codes only), and a web search or address when you press Return on it.
- What you type, copy or select is never written to the log. Passwords and secret copies are never recorded by the clipboard.

# Not available

Moving windows between Spaces and always-on-top (macOS allows them only through private APIs), multi-finger trackpad gestures,
a Safari extension, Logitech-specific device features, scrolling screen capture, and running JavaScript extensions from a catalog.

Building the app from source is described in `DEVELOPING.md`.
