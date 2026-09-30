// An offline smoke check that needs only the Dart VM, not Flutter or packages.
// dart --disable-dart-dev tool/core_smoke.dart [optional/input.cbz ...]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/models.dart';
import '../lib/services/archive_service.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main(List<String> arguments) {
  final archive = ArchiveService();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7WQAAAAASUVORK5CYII=',
  );
  final page = MangaPage(
    id: '1',
    sourceName: 'original.png',
    originalBytes: png,
    originalMimeType: 'image/png',
  );
  final project = MangaProject(
    title: 'Offline smoke',
    pages: [page],
    glossary: '名前 = Name',
  );
  var blocked = false;
  try {
    archive.exportCbz(project);
  } on StateError {
    blocked = true;
  }
  check(blocked, 'Unreviewed export was allowed.');
  page.setTranscript('Hello.');
  page.setEdited(
    Uint8List.fromList(png),
    'image/png',
    notes: 'Reviewed translation.',
  );
  page.markReviewed();
  final reopened = archive.openProject(archive.saveProject(project));
  check(reopened.exportReady, 'Review state was lost.');
  check(reopened.glossary == project.glossary, 'Glossary was lost.');
  check(reopened.pages.single.notes == page.notes, 'Notes were lost.');
  final result = archive.importCbz(archive.exportCbz(reopened));
  check(
    result.pages.single.sourceName == '0001.png',
    'Numbered export failed.',
  );
  check(naturalCompare('p2.png', 'p10.png') < 0, 'Natural order failed.');
  page.setTranscript('Changed.');
  check(!page.exportReady, 'Changing text did not invalidate review.');
  page.useOriginal(true);
  check(page.exportReady, 'Explicit keep-original was not recognized.');
  for (final path in arguments) {
    final imported = archive.importCbz(
      File(path).readAsBytesSync(),
      title: 'Roundtrip',
    );
    for (final page in imported.pages) {
      page.useOriginal(true);
    }
    final restored = archive.openProject(archive.saveProject(imported));
    final exported = archive.importCbz(archive.exportCbz(restored));
    check(
      exported.pages.length == imported.pages.length,
      'Page count changed.',
    );
    for (var i = 0; i < imported.pages.length; i++) {
      check(
        base64Encode(exported.pages[i].originalBytes) ==
            base64Encode(imported.pages[i].originalBytes),
        'Page bytes changed.',
      );
    }
    stdout.writeln(
      'Roundtrip passed: ${imported.pages.length} pages (${File(path).uri.pathSegments.last})',
    );
  }
  stdout.writeln('Offline core smoke checks passed.');
}
