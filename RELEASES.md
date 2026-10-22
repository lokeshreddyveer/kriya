# Releases

Each release is built with `scripts/release.sh <version> <build>`, which runs the Rust tests, builds a universal app,
signs it with a Developer ID certificate and has Apple notarize it. The Swift tests are run with `xcodebuild test`
before it. The evidence for a release (test result bundle, logs, Sparkle signature) is kept in `release-evidence/<version>/`
on the machine that built it; it is too large for this repository.

| Version | Build | DMG SHA-256 | Swift tests | Notes |
|---|---|---|---|---|
| 0.2.5 | 12 | `db7b6c5beb4c4eca801368cefb7b471c469333548b243f8f5e2b7dffed3286c9` | 115 passed, 0 failed | One shortcut registry for all hotkeys (fixes only the last feature's shortcuts firing), Shortcut Map pane, Homebrew install tab with app lists. Rust: 373 passed |
| 0.2.4 | 11 | `69503430273e4a99ea70ada43af73de6cdc323ef9b1d540918617b937091ab8d` | 99 passed, 0 failed | Text tools, Finder checksum/alias/download-warning actions, display warmth, focus follows mouse, hide pointer while typing, app sizes and last-used, Keep Awake until a time, link app rules |
| 0.2.1 | 8 | `e834c9032af872fcfcce4a9a68f56cb446d430370de03cffced2496a4d47c7c9` | 85 passed | First release in this repository |
