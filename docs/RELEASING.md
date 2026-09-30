# Releases and signing

The initial distribution is a preview. A successful workflow publishes built
assets and SHA-256 checksums to a GitHub prerelease. It does not claim App Store,
Google Play, Developer ID, or notarization approval.

| Package | Preview trust status | What it is for |
| --- | --- | --- |
| Android APK | Signed with a development/debug key | Direct installation for evaluation; later builds may require uninstalling if the key changes. |
| macOS DMG | Ad-hoc signed, not notarized | A built macOS app for evaluation. It is not a trusted Developer ID distribution. |
| iOS IPA | Unsigned | A device build packaged for a signing workflow. It cannot be installed as delivered. |

An unsigned IPA is not an installable iOS release. Distribution requires an
appropriate Apple signing identity, provisioning profile, bundle identifier,
and export method. No Apple signing material was supplied with this project.
The same applies to a trusted, notarized macOS release: Developer ID signing and
notarization must be configured before describing it that way.

The Android preview key is not a production signing identity. Preserve a securely
managed release key for stable Android upgrades before publishing a production
version. Do not commit keystores, certificates, provisioning profiles, passwords,
service access tokens, or provider API credentials.

## Build and publish

The workflow pins Flutter, runs client analysis/tests and service tests, and builds
native packages on the appropriate runners. Its publish job creates a prerelease
only after the required builds succeed. An existing release for another source
commit is not silently replaced.

For another version, update `pubspec.yaml`; the workflow derives its release tag
from that version. Review the source commit, build logs, package metadata, and checksum
manifest before making that version a stable public release.

## Validation boundaries

Compilation, archive integrity, unit tests, and layout tests are distinct from
device testing and live AI quality checks. Release notes should state which have
actually run. A missing AI credential must not be reported as a successful live
translation test. Before production use, test the complete import → translate →
inpaint → review → export flow on real target devices and a configured AI service.

Project archives use `.umt`; output comic archives use `.cbz`. Neither is an app
installer. Source archives generated automatically by GitHub are also not native
installers.
