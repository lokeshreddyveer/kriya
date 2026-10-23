#!/bin/bash
# Checks everything that can be checked without a person: a clean tree, the Rust tests, formatting, and that the commit on
# the remote is the one being built. The Swift tests and the hardware list (docs/HARDWARE-TESTS.md) still need a Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Working tree"
if [ -n "$(git status --porcelain)" ]; then echo "Uncommitted changes:"; git status --short; exit 1; fi
git fetch -q origin main
local_commit=$(git rev-parse HEAD)
remote_commit=$(git rev-parse origin/main)
if [ "$local_commit" != "$remote_commit" ]; then echo "HEAD ($local_commit) is not origin/main ($remote_commit)"; exit 1; fi
echo "On origin/main at ${local_commit:0:8}"

echo "== Rust core"
./scripts/build-core.sh test

if [ "$(uname)" = "Darwin" ]; then
  echo "== Swift tests"
  ./scripts/swift-build.sh test
else
  echo "== Swift tests skipped: this is not a Mac. Run this script on the Mac you ship from."
fi

echo "== Next: tick every box in docs/HARDWARE-TESTS.md, then record it in Diagnostics."
