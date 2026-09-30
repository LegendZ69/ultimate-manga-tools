import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ultimate_manga_tools/models.dart';
import 'package:ultimate_manga_tools/services/archive_service.dart';
import 'package:ultimate_manga_tools/services/backend_client.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7WQAAAAASUVORK5CYII=',
);

MangaPage makePage([String id = 'p1']) => MangaPage(
  id: id,
  sourceName: '$id.png',
  originalBytes: Uint8List.fromList(png),
  originalMimeType: 'image/png',
);

void main() {
  final archives = ArchiveService();

  test('natural order is numeric, stable, and safe with enormous numbers', () {
    final project = archives.importCbz(
      zip([
        ('chapter/page10.png', png),
        ('chapter/page2.png', png),
        ('chapter/page1.png', png),
        ('ignore.txt', Uint8List.fromList([1, 2])),
      ]),
    );
    expect(project.pages.map((p) => p.sourceName), [
      'chapter/page1.png',
      'chapter/page2.png',
      'chapter/page10.png',
    ]);
    expect(
      naturalCompare(
        'p999999999999999999999.png',
        'p1000000000000000000000.png',
      ),
      lessThan(0),
    );
  });

  test('stored and deflated ZIP files import identically', () {
    final entries = [('日本語/01.png', png)];
    expect(archives.importCbz(zip(entries)).pages.single.originalBytes, png);
    expect(
      archives
          .importCbz(zip(entries, deflate: true))
          .pages
          .single
          .originalBytes,
      png,
    );
  });

  test(
    'invalid ZIP, unsafe paths, duplicates, and empty page sets are rejected',
    () {
      expect(
        () => archives.importCbz(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      for (final path in [
        '../page.png',
        '/page.png',
        r'folder\page.png',
        'C:/page.png',
        'a//page.png',
      ]) {
        expect(
          () => archives.importCbz(zip([(path, png)])),
          throwsFormatException,
          reason: path,
        );
      }
      expect(
        () => archives.importCbz(zip([('a.png', png), ('A.PNG', png)])),
        throwsFormatException,
      );
      expect(
        () => archives.importCbz(zip([('notes.txt', png)])),
        throwsFormatException,
      );
    },
  );

  test(
    'archive bombs fail declared bounds or bounded inflation before image decode',
    () {
      expect(
        () => archives.importCbz(
          zip([('a.png', png)], declaredSize: ArchiveService.maxEntryBytes + 1),
        ),
        throwsFormatException,
      );
      expect(
        () => archives.importCbz(
          zip([('a.png', png)], deflate: true, declaredSize: 8),
        ),
        throwsFormatException,
      );
      final repeated = Uint8List(1024 * 1024);
      expect(
        () => archives.importCbz(zip([('a.png', repeated)], deflate: true)),
        throwsFormatException,
      );
    },
  );

  test('corruption and mismatched local filenames are rejected', () {
    final corrupt = zip([('a.png', png)]);
    corrupt[35] ^= 1;
    expect(() => archives.importCbz(corrupt), throwsFormatException);
    final mismatch = zip([('a.png', png)]);
    mismatch[30] = 'b'.codeUnitAt(0);
    expect(() => archives.importCbz(mismatch), throwsFormatException);
  });

  test('pixel bombs and extension spoofing are rejected', () {
    final oversized = Uint8List.fromList(png);
    ByteData.sublistView(oversized).setUint32(16, 100000);
    expect(() => imageMimeType(oversized), throwsFormatException);
    expect(
      () => archives.importCbz(zip([('a.jpg', png)])),
      throwsFormatException,
    );
  });

  test('export requires reviewed edits or an explicit original selection', () {
    final a = makePage('a'), b = makePage('b');
    final project = MangaProject(title: 'Review gate', pages: [a, b]);
    expect(project.exportReady, isFalse);
    expect(() => a.markReviewed(), throwsStateError);
    expect(() => archives.exportCbz(project), throwsStateError);
    a.setEdited(png, 'image/png');
    expect(() => archives.exportCbz(project), throwsStateError);
    a.markReviewed();
    b.useOriginal(true);
    expect(project.exportReady, isTrue);
    expect(project.reviewedCount, 2);
    final result = archives.exportCbz(project);
    expect(archives.importCbz(result).pages.map((p) => p.sourceName), [
      '0001.png',
      '0002.png',
    ]);
    expect(
      result,
      archives.exportCbz(project),
      reason: 'Export is deterministic.',
    );
    a.setTranscript('A changed translation');
    expect(
      project.exportReady,
      isFalse,
      reason: 'Changed text needs another review.',
    );
  });

  test(
    'checkpoint restores source, edits, text, notes, language, and review states',
    () {
      final edited =
          makePage('edited')
            ..setTranscript('An English line')
            ..setEdited(png, 'image/png', notes: 'Panel 2 dialogue redacted.')
            ..markReviewed();
      final original = makePage('original')..useOriginal(true);
      final project = MangaProject(
        title: 'Manga & notes',
        pages: [edited, original],
        glossary: '名前 = Name',
        sourceLanguage: 'ja',
        targetLanguage: 'en',
      );
      final restored = archives.openProject(archives.saveProject(project));
      expect(restored.title, project.title);
      expect(restored.glossary, project.glossary);
      expect(restored.exportReady, isTrue);
      expect(restored.pages.first.originalBytes, png);
      expect(restored.pages.first.editedBytes, png);
      expect(restored.pages.first.transcript, 'An English line');
      expect(restored.pages.first.notes, 'Panel 2 dialogue redacted.');
      expect(restored.pages.first.reviewed, isTrue);
      expect(restored.pages.last.keepOriginal, isTrue);
      final exportedText = latin1.decode(archives.exportCbz(restored));
      expect(exportedText, contains('ComicInfo.xml'));
      expect(exportedText, contains('Manga &amp; notes'));
      expect(exportedText, contains('translation-notes.json'));
      expect(exportedText, contains('Panel 2 dialogue redacted.'));
      expect(exportedText, contains('original_kept_explicitly'));
    },
  );

  test(
    'unreviewed checkpoints stay unreviewed and cannot masquerade as projects',
    () {
      final project = MangaProject(
        title: 'Draft',
        pages: [makePage()..setEdited(png, 'image/png')],
      );
      final restored = archives.openProject(archives.saveProject(project));
      expect(restored.exportReady, isFalse);
      expect(() => archives.exportCbz(restored), throwsStateError);
      expect(
        () => archives.openProject(zip([('01.png', png)])),
        throwsFormatException,
      );
    },
  );

  test('service URLs require HTTPS except explicit loopback development', () {
    for (final url in [
      'http://example.org',
      'ftp://example.org',
      'https://user:pass@example.org',
      'https://example.org?token=secret',
      'https://example.org#frag',
    ]) {
      expect(() => BackendClient.validateBaseUrl(url), throwsFormatException);
    }
    expect(
      BackendClient.validateBaseUrl('https://example.org/api/').path,
      '/api',
    );
    expect(BackendClient.validateBaseUrl('http://127.0.0.1:8787').port, 8787);
    expect(BackendClient.validateBaseUrl('http://[::1]:8787').port, 8787);
  });

  test(
    'service uses session auth, source bytes, translated text, and no redirects',
    () async {
      final page = makePage()..setTranscript('Hello!');
      final project = MangaProject(
        title: 'API test',
        pages: [page],
        glossary: 'Name = Name',
      );
      final calls = <String>[];
      final backend = BackendClient(
        baseUrl: 'https://service.example/api',
        token: 'session-only',
        client: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.headers['Authorization'], 'Bearer session-only');
          expect(request.followRedirects, isFalse);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['image_base64'], base64Encode(png));
          expect(body['glossary'], 'Name = Name');
          expect(body.containsKey('api_key'), isFalse);
          if (request.url.path.endsWith('/transcribe')) {
            return http.Response(jsonEncode({'transcript': 'Translated'}), 200);
          }
          expect(body['transcript'], 'Hello!');
          return http.Response(
            jsonEncode({
              'image_base64': base64Encode(png),
              'mime_type': 'image/png',
              'notes': ['Redacted panel 2.', 'Checked.'],
            }),
            200,
          );
        }),
      );
      expect(await backend.transcribe(page, project), 'Translated');
      final result = await backend.inpaint(page, project);
      expect(result.bytes, png);
      expect(result.notes, 'Redacted panel 2.\nChecked.');
      expect(calls, ['/api/v1/transcribe', '/api/v1/inpaint']);
      backend.close();
    },
  );

  test(
    'AI request limits reject locally before a paid request is sent',
    () async {
      var requests = 0;
      final backend = BackendClient(
        baseUrl: 'https://service.example',
        token: '',
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final page = makePage()..setTranscript('a' * 40001);
      final project = MangaProject(title: 'Limits', pages: [page]);
      await expectLater(
        backend.inpaint(page, project),
        throwsA(isA<BackendException>()),
      );
      expect(requests, 0);
      backend.close();
    },
  );

  test('service errors and malformed responses remain actionable', () async {
    final page = makePage(),
        project = MangaProject(title: 'Errors', pages: [makePage()]);
    final denied = BackendClient(
      baseUrl: 'https://service.example',
      token: 'x',
      client: MockClient(
        (_) async => http.Response('{"detail":"Invalid service token."}', 401),
      ),
    );
    await expectLater(
      denied.transcribe(page, project),
      throwsA(
        isA<BackendException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    denied.close();
    final malformed = BackendClient(
      baseUrl: 'https://service.example',
      token: '',
      client: MockClient((_) async => http.Response('not JSON', 200)),
    );
    await expectLater(malformed.health(), throwsA(isA<BackendException>()));
    malformed.close();
  });
}

/// Independent fixture writer supports method 8 and misleading declarations.
Uint8List zip(
  List<(String, Uint8List)> files, {
  bool deflate = false,
  int? declaredSize,
}) {
  final output = BytesBuilder(), directory = BytesBuilder();
  for (final file in files) {
    final name = utf8.encode(file.$1), data = file.$2;
    final compressed = deflate ? ZLibEncoder(raw: true).convert(data) : data;
    final size = declaredSize ?? data.length,
        crc = crc32(data),
        offset = output.length;
    final local =
        ByteData(30)
          ..setUint32(0, 0x04034b50, Endian.little)
          ..setUint16(4, 20, Endian.little)
          ..setUint16(6, 0x800, Endian.little)
          ..setUint16(8, deflate ? 8 : 0, Endian.little)
          ..setUint32(14, crc, Endian.little)
          ..setUint32(18, compressed.length, Endian.little)
          ..setUint32(22, size, Endian.little)
          ..setUint16(26, name.length, Endian.little);
    output.add(local.buffer.asUint8List());
    output.add(name);
    output.add(compressed);
    final central =
        ByteData(46)
          ..setUint32(0, 0x02014b50, Endian.little)
          ..setUint16(4, 20, Endian.little)
          ..setUint16(6, 20, Endian.little)
          ..setUint16(8, 0x800, Endian.little)
          ..setUint16(10, deflate ? 8 : 0, Endian.little)
          ..setUint32(16, crc, Endian.little)
          ..setUint32(20, compressed.length, Endian.little)
          ..setUint32(24, size, Endian.little)
          ..setUint16(28, name.length, Endian.little)
          ..setUint32(42, offset, Endian.little);
    directory.add(central.buffer.asUint8List());
    directory.add(name);
  }
  final directoryOffset = output.length, directorySize = directory.length;
  output.add(directory.takeBytes());
  final end =
      ByteData(22)
        ..setUint32(0, 0x06054b50, Endian.little)
        ..setUint16(8, files.length, Endian.little)
        ..setUint16(10, files.length, Endian.little)
        ..setUint32(12, directorySize, Endian.little)
        ..setUint32(16, directoryOffset, Endian.little);
  output.add(end.buffer.asUint8List());
  return output.takeBytes();
}

int crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
