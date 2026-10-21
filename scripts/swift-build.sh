#!/bin/sh
# Regenerates the Xcode project and builds Debug, printing only errors.
set -eu
cd "$(dirname "$0")/../apps/macos"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate --spec project.yml >/dev/null
xcodebuild -project Kriya.xcodeproj -scheme Kriya -configuration Debug -derivedDataPath ../../build/debug -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
