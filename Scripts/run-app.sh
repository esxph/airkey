#!/bin/bash
set -euo pipefail
usage() {
    cat <<'HELP'
Usage: ./Scripts/run-app.sh [--no-open | --help]

Build, package, and locally sign .build/AirKey.app, then launch it.
Quit a running copy of AirKey before rebuilding.

  --no-open    Build the app without launching it.
  --help       Show this help without building.

Environment:
  CONFIGURATION            release (default) or debug
  DEVELOPER_DIR            Optional Xcode developer directory
  AIRKEY_SIGNING_IDENTITY   Optional Keychain signing identity; '-' for ad-hoc
HELP
}
if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --no-open|'') ;;
    *) usage >&2; exit 2 ;;
esac
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
case "$configuration" in
    release|debug) ;;
    *) printf 'CONFIGURATION must be release or debug.\n' >&2; exit 2 ;;
esac
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/.build/AirKey.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/airKey" "$app_dir/Contents/MacOS/airKey"
cp LICENSE "$app_dir/Contents/Resources/LICENSE.txt"
# SwiftPM uses .bundle with Swift Build and .resources with the native build system.
for resource in "$binary_dir/airKey_airKey.bundle" "$binary_dir/airKey_airKey.resources"; do
    if [ -d "$resource" ]; then
        name="$(basename "$resource")"
        mkdir -p "$app_dir/Contents/Resources/$name"
        ditto "$resource" "$app_dir/Contents/Resources/$name"
    fi
done
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>airKey</string>
<key>CFBundleIdentifier</key><string>com.oolix.airKey</string>
<key>CFBundleName</key><string>AirKey</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>10</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSCameraUsageDescription</key><string>AirKey uses your camera to track hand gestures for typing. Video stays on your Mac.</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# A certificate-backed identity keeps the designated requirement stable across
# builds, so Accessibility/Camera grants are not tied to each binary's cdhash.
signing_identity="${AIRKEY_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    signing_identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
fi
if [ -z "$signing_identity" ]; then
    signing_identity="-"
    printf 'No development signing identity found; ad-hoc builds may require granting permissions again.\n'
fi
codesign --force --deep --timestamp=none --sign "$signing_identity" "$app_dir"
if [ "${1:-}" != "--no-open" ]; then open "$app_dir"; fi
printf 'App ready: %s\n' "$app_dir"
