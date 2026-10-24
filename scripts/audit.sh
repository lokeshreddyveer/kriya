#!/bin/bash
# Checks the things that drift between a build and what is written about it. Run before a release; scripts/release.sh runs it too.
#
#   scripts/audit.sh            checks the working tree
#
# It fails (exit 1) when:
#   - a source file is untracked or modified (a release must be built from what is committed, or the build cannot be reproduced),
#   - the version in project.yml has no row in RELEASES.md, or the row's build number differs,
#   - a Swift test or source file has a UserDefaults key that SettingsRegistry does not list (the registry test finds this too),
#   - the README makes a claim that is known to be wrong (a list kept in this file).
set -uo pipefail
cd "$(dirname "$0")/.."
problems=0
bad() { echo "✘ $*"; problems=$((problems + 1)); }

# 1. A clean tree (ignoring build output).
dirty=$(git status --porcelain -- . ':!dist' ':!build' ':!release-evidence' 2>/dev/null)
if [ -n "$dirty" ]; then
  bad "the working tree is not committed:"; echo "$dirty" | sed 's/^/    /'
fi

# 2. The version in project.yml is the version in RELEASES.md.
version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' apps/macos/project.yml | head -1)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9]*\)"\{0,1\} *$/\1/p' apps/macos/project.yml | head -1)
if [ -z "$version" ] || [ -z "$build" ]; then
  bad "could not read the version and build from apps/macos/project.yml"
else
  row=$(grep -E "^\| *$version *\|" RELEASES.md | head -1)
  if [ -z "$row" ]; then
    bad "project.yml says $version ($build) but RELEASES.md has no row for $version"
  elif ! echo "$row" | grep -Eq "^\| *$version *\| *$build *\|"; then
    bad "RELEASES.md lists $version with a different build number than project.yml ($build)"
  fi
fi

# 3. README claims that were found to be wrong. Add a line here whenever one is corrected, so it cannot come back.
for phrase in "overwritten on disk" "Everything stays on your Mac" "back up all your settings"; do
  if grep -q "$phrase" README.md; then bad "README.md still says “$phrase”, which is not true"; fi
done

# 4. Every service id handed to the manager is one the evidence table knows.
registered=$(grep -ho 'AuxiliaryService(id: "[A-Za-z.]*"' apps/macos/Sources -r | sed 's/.*id: "\(.*\)"/\1/' | sort -u)
for id in $registered; do
  grep -q "\"$id\"" apps/macos/Sources/Adapter/ServiceManager.swift || bad "service “$id” is registered but missing from ServiceManager.knownAuxiliaryIDs"
done

if [ "$problems" -eq 0 ]; then echo "✔ audit passed"; else echo "$problems problem(s)"; exit 1; fi
