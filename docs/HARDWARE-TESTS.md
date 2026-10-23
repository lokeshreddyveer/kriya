# Hardware and permission tests

These need a real Mac and cannot be proved by unit tests. Tick each on the Mac you ship from, then record it in
Settings › Diagnostics › Recorded on this build. Write what you saw, not just "ok".

## Mouse, trackpad, keyboard
- [ ] Each remapped button: click rule, hold rule, button + modifier, and that a plain click still works where no rule applies.
- [ ] Gestures: all four directions; the gesture button does not also fire its button rule.
- [ ] Mouse › Buttons › "If I press this…" agrees with what the real button does.
- [ ] Unplug and replug a USB mouse; connect and disconnect a Bluetooth one. Devices shows the timeline and health score.
- [ ] Two mice used together: the right preset applies to each.
- [ ] Key remapping: Caps Lock tap/hold, Hyper, a chord; shortcuts import (arrive off) then turn on.
- [ ] Secure input (a password field open): Kriya says text expansion is paused.
- [ ] Selection bar: Return/arrows/Tab/digits in keyboard mode (press the manual shortcut twice); VoiceOver reads the position.

## Windows, displays, workspaces
- [ ] Snap/layout restore on one display, then two; unplug the second and replug: the saved set comes back.
- [ ] Layout Preview matches what Restore does. A locked window does not move.
- [ ] A restore with an app closed: it opens (if allowed) and the retry list places its window.
- [ ] Layout History: change a layout, go back, go back again from the "before going back" version.
- [ ] Workspace: opens only missing apps; Undo quits only what it opened and shows only what it hid; its sound mode turns on.
- [ ] DDC brightness and input on a compatible monitor; a monitor that does not answer says so. Sleep and wake: brightness returns.
- [ ] HDR line on an HDR display and on a non-HDR one.

## Sound and MIDI
- [ ] Output/input rules on connecting AirPods and a USB device; "Put the sound back".
- [ ] Bluetooth audio reconnect after sleep.
- [ ] MIDI: unplug and replug mid-session, duplicate triggers on two channels, note-off, malformed bytes (use a MIDI monitor).
- [ ] Location audio: permission denied, services off, rapid switching.

## Capture
- [ ] Screen Recording permission denied, granted, then revoked while recording.
- [ ] Region, window, screen, menu, scrolling, previous area, mirror (a live copy that stays on top).
- [ ] Recording with microphone, system sound, keystrokes and the camera overlay; pause/resume; crash recovery after force-quit.
- [ ] OCR with a non-English language chosen; automatic.
- [ ] Windows that are blank or unavailable (DRM video, a minimised window) fail with a clear message.

## Files, apps, notes
- [ ] Shelf: groups, drag between groups, expiry reminder notification (allow notifications first).
- [ ] Finder actions: pause with two jobs queued; cancel a waiting one; undo from Recent file operations.
- [ ] Apps: Check Signature on a notarized app, a Mac App Store app, and an unsigned one.
- [ ] Homebrew: install one cask that needs a password → "Run in Terminal"; a failed upgrade is retried (1, 2, 4 minutes).
- [ ] Remove an app with "keep a zip": the zip opens; the app and files are in the Trash and can be put back.
- [ ] Notes: lock, quit Kriya, reopen: locked note reads; delete the Keychain item "notes.encryptionKey": locked notes cannot be read (expected).
- [ ] Notes: attach a file, trash the note, put it back from the Trash: attachments come with it.

## Safari and browsers
- [ ] Safari: enable the extension, grant website access for one site, "Summarize Page" on it and on a private window (refused).
- [ ] Chromium and Firefox extensions: page actions, private-window refusal.
- [ ] Link routing: profile choice, private-window option, Test button, fallback browser.

## AI
- [ ] A provider with a real key: Check connection, per-feature policy, local-only blocks it.
- [ ] Claude Desktop / Cursor against the loopback MCP server: connect, list tools, call a read-only tool, refuse a risky one, wrong token rejected, server stops with the app.
- [ ] Page AI: allow once / always / never for a site; a bank-looking site asks every time.

## Platform limits (nothing to test, just do not claim)
Other apps' always-on-top, moving other apps' windows between Spaces, switching Low Power Mode, a universal HDR toggle.
