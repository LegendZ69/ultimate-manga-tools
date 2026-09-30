# Ultimate Manga Tools

A review-first workspace for turning manga page archives into English-lettered CBZs.
Import a ZIP or CBZ, translate the readable text, review the transcript, request an
image edit, compare it with the original, and export the approved pages in reading order.

This is a **new implementation inspired by the ChatGPT-assisted English-inpainting
workflow**. It is not a copy of ChatGPT's internal tools or a recovery of the
temporary scripts used for the earlier chapter deliveries. No manga pages, private
project files, API credentials, or paid models are included in this repository.

## What works locally

- Import PNG, JPEG, and WebP pages from ZIP/CBZ archives in natural filename order.
- Inspect originals and edited pages with zoom and comparison controls.
- Import an edited page from another tool and explicitly approve it.
- Keep an original page by an explicit per-page choice.
- Save and reopen an editable `.umt` project containing images and review state.
- Export a numbered CBZ only after every page has been reviewed, with metadata.

The AI workflow uses the included Python service. Translation and inpainting are
separate requests so the transcript can be corrected before lettering. A chapter
glossary keeps names and terminology available to each request. Only pages you
submit are sent to the configured service and its AI provider. Credentials remain
on the server; the app uses a separate service access token held for the session.

## First use

1. Open a ZIP or CBZ archive, or reopen a saved `.umt` project.
2. For AI processing, connect to your trusted service in the app's connection
   settings. Manual edit import, review, and CBZ export work without a service.
3. Set the chapter language and glossary, then translate a page.
4. Check the transcript and correct names or unreadable text before inpainting.
5. Compare the edited page against the original and approve it. Alternatively,
   import your own edit or explicitly keep the original.
6. Save a project checkpoint and export the reviewed chapter as a CBZ.

Image editing can change artwork, lettering, or page geometry. Review every result;
the app does not claim pixel-perfect preservation or verified translation accuracy.
Unreadable text should be marked rather than invented. Provider refusals are
reported, without automatic attempts to evade them. Correctly redacted pages can
be imported and reviewed manually.

## Source and builds

The native client is a Flutter project targeting Android, macOS, and iOS. The
`server/` directory contains the independent Python service and its tests. Release
automation lives in `.github/workflows/` and packaging helpers in `scripts/`.

See [the workflow provenance](docs/PROVENANCE.md) for what is known about the
earlier chapter-production process, and [release notes](docs/RELEASING.md) for
package trust and signing details.

## Development

Use the Flutter version pinned in the release workflow, then run:

```sh
flutter pub get
flutter analyze
flutter test
```

See [the service README](server/README.md) for service configuration, testing,
and deployment. AI access is separately configured and billed by the provider;
a ChatGPT conversation or subscription is not an embedded app credential.

## Privacy

Project archives contain the original and edited images and the transcript; treat
them as private files. Service credentials are excluded from projects and CBZs.
There is no analytics SDK or account system. Do not commit page archives or secret
configuration to the public repository. Use only material you have permission to
process and share.
