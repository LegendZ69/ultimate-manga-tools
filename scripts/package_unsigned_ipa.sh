#!/usr/bin/env bash
set -euo pipefail

# An unsigned IPA is a re-signing input, not an installable App Store/TestFlight app.
version="${1:-0.1.0}"
app='build/ios/iphoneos/Runner.app'
output="$PWD/dist/Ultimate-Manga-Tools-${version}-ios-UNSIGNED.ipa"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS/Xcode is required.' >&2; exit 1; }
[[ -d "$app" ]] || { echo "Missing app bundle: $app" >&2; exit 1; }
mkdir -p dist
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/Runner.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Payload/Runner.app/Info.plist"
(cd "$stage" && ditto -c -k --sequesterRsrc --keepParent Payload "$output")
unzip -t "$output"
printf 'Packaged unsigned IPA (requires signing and provisioning): %s\n' "$output"
