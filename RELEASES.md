# Releases

Each release is built with `scripts/release.sh <version> <build>`, which runs the Rust tests, builds a universal app,
signs it with a Developer ID certificate and has Apple notarize it. The Swift tests are run with `xcodebuild test`
before it. The evidence for a release (test result bundle, logs, Sparkle signature) is kept in `release-evidence/<version>/`
on the machine that built it; it is too large for this repository.

| Version | Build | DMG SHA-256 | Swift tests | Notes |
|---|---|---|---|---|
| 0.2.9 | 16 | `4ab5c50a1ad090f8827a954f12cbba6d9359e20e38c8d58550e55c2e620afd94` | 246 passed, 0 failed | Apple Intelligence (on-device only): selection bar actions, launcher ask and clipboard actions, settings pane. Rust: 396 passed |
| 0.2.8 | 15 | `d4f20bf5f51f61129bccf5984859ba6e9eead86255e6874eca189d758770ee6c` | 229 passed, 0 failed | Encrypted clipboard and protected backups, unified launcher, interaction map, layout editor, screen capture with text recognition and redaction, browser extensions, diagnostics. Rust: 389 passed |
| 0.2.7 | 14 | `cf8e428225907530309e32cdb763134fd0e536cf9f566c0ba3338530c5e4269e` | 120 passed, 0 failed | New quick-paste clipboard panel (day groups, tinted tiles, selected row opens up); a failed app-update check is no longer shown as done; README lists what Kriya does by itself. Rust: 373 passed |
| 0.2.6 | 13 | `68c8e9924414bc25c98f584565f72f3b2c20c53f8c29508073960659426392de` | 119 passed, 0 failed | Updates and scans run by themselves (no check buttons), tab bars fit their tabs, Homebrew upgrades serialized, Stop race and search-section fixes, shortcut registry made thread-safe. Rust: 373 passed |
| 0.2.5 | 12 | `db7b6c5beb4c4eca801368cefb7b471c469333548b243f8f5e2b7dffed3286c9` | 115 passed, 0 failed | One shortcut registry for all hotkeys (fixes only the last feature's shortcuts firing), Shortcut Map pane, Homebrew install tab with app lists. Rust: 373 passed |
| 0.2.4 | 11 | `69503430273e4a99ea70ada43af73de6cdc323ef9b1d540918617b937091ab8d` | 99 passed, 0 failed | Text tools, Finder checksum/alias/download-warning actions, display warmth, focus follows mouse, hide pointer while typing, app sizes and last-used, Keep Awake until a time, link app rules |
| 0.2.1 | 8 | `e834c9032af872fcfcce4a9a68f56cb446d430370de03cffced2496a4d47c7c9` | 85 passed | First release in this repository |
