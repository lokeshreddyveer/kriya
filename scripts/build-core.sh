#!/bin/sh
# Builds the Rust core as one universal (Apple Silicon + Intel) macOS static library, wraps it in an XCFramework and
# generates the Swift bindings the macOS app compiles.
#
#   scripts/build-core.sh          release build
#   scripts/build-core.sh test     run the core's tests and lints instead
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
OUT="$ROOT/apps/macos/Generated"
export PATH="$HOME/.cargo/bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MACOSX_DEPLOYMENT_TARGET=14.0
cd "$CORE"
# The first build creates Cargo.lock; after that it is locked so builds are reproducible.
LOCKED="--locked"; [ -f Cargo.lock ] || LOCKED=""

if [ "${1:-}" = "test" ]; then
  cargo test $LOCKED
  cargo clippy $LOCKED --all-targets -- -D warnings
  cargo fmt --check
  exit 0
fi

for t in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release $LOCKED -p kriya-core --target "$t"
done
rm -rf "$OUT" && mkdir -p "$OUT/headers" "$OUT/lib"
lipo -create \
  target/aarch64-apple-darwin/release/libkriya_core.a \
  target/x86_64-apple-darwin/release/libkriya_core.a \
  -output "$OUT/lib/libkriya_core.a"

cargo build -q $LOCKED -p kriya-core
cargo run -q $LOCKED -p kriya-core --bin uniffi-bindgen -- generate \
  --library target/debug/libkriya_core.dylib --language swift --out-dir "$OUT/bindings"
mv "$OUT/bindings/kriya_core.swift" "$OUT/kriya_core.swift"
mv "$OUT/bindings/kriya_coreFFI.h" "$OUT/headers/"
printf 'module kriya_coreFFI {\n    header "kriya_coreFFI.h"\n    export *\n}\n' > "$OUT/headers/module.modulemap"
rm -rf "$OUT/bindings"
xcodebuild -create-xcframework \
  -library "$OUT/lib/libkriya_core.a" -headers "$OUT/headers" \
  -output "$OUT/KriyaCore.xcframework"
rm -rf "$OUT/lib"

# What this framework was built from, so a release can show it was not left over from older sources.
( cd "$ROOT" && find core -path core/target -prune -o \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name 'rust-toolchain.toml' \) -type f -print | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1 ) > "$OUT/CORE_SOURCE_HASH"
rustc --version >> "$OUT/CORE_SOURCE_HASH"
echo "built $OUT"
