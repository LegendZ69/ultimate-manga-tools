#!/usr/bin/env bash
set -euo pipefail

# Preview distribution only: ad-hoc signing does not establish Developer ID trust.
version="${1:-0.1.0}"
app="build/macos/Build/Products/Release/Ultimate Manga Tools.app"
output="dist/Ultimate-Manga-Tools-${version}-macos-preview.dmg"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS/Xcode is required.' >&2; exit 1; }
[[ -d "$app" ]] || { echo "Missing app bundle: $app" >&2; exit 1; }
mkdir -p dist
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
signing_details="$(codesign -dv "$app" 2>&1)"
printf '%s\n' "$signing_details"
[[ "$signing_details" == *'Signature=adhoc'* ]] || { echo 'Expected an ad-hoc preview signature.' >&2; exit 1; }
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
lipo -info "$app/Contents/MacOS/$executable"
ditto "$app" "$stage/Ultimate Manga Tools.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/INSTALL.txt" <<'EOF'
Ultimate Manga Tools — preview

Drag Ultimate Manga Tools.app into Applications.

This preview is ad-hoc signed and is NOT notarized with Apple. Gatekeeper may
block it. If you trust this source, use System Settings > Privacy & Security
> Open Anyway after attempting to open it. An organization-managed Mac may
not permit an override.

AI translation requires a separately running Ultimate Manga Tools bridge
and your own API key on that bridge. Local editing and CBZ export work offline.
EOF
hdiutil create -volname 'Ultimate Manga Tools' -srcfolder "$stage" -ov -format UDZO "$output"
hdiutil verify "$output"
printf 'Packaged preview DMG: %s\n' "$output"
