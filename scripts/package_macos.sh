#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Flutter 3.47 builds universal macOS releases by default. Verification below
# rejects an ARM-only build if the developer has enabled that Flutter setting.
flutter build macos --release
bundle="build/macos/Build/Products/Release/SyncTune.app"
# Re-seal the app after native-asset updates that Xcode may otherwise treat as
# an unchanged runner during incremental builds. Distribution is ad-hoc signed.
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$bundle"
python3 scripts/verify_macos_bundle.py "$bundle"
mkdir -p dist
archive="dist/SyncTune-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"
echo "Packaged $archive"
